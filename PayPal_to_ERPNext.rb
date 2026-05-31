#!/usr/bin/env ruby
# frozen_string_literal: true

# PayPal_to_ERPNext.rb
#
# Converts a PayPal CSV export to an ERPNext bank statement CSV.
# Automatically detects and handles two PayPal export formats:
#
#   Balance statement  — comma-separated, date "6/2/2025", timezone as IANA name
#                        (e.g. "America/Los_Angeles"), has Description / Bank Name /
#                        Bank Account columns.
#
#   Activity statement — date "02/06/2025" (DD/MM/YYYY), timezone as
#                        abbreviation (e.g. "PDT"), has Type / Status / To Email /
#                        Balance Impact columns instead.
#
# Usage (single file — format auto-detected):
#   ruby PayPal_to_ERPNext.rb <input.csv> [output.csv] [--account "My PayPal"] [--currency EUR]
#
# Usage (merge mode — uses activity data, enriches party info from balance):
#   ruby PayPal_to_ERPNext.rb --merge <activity.csv> <balance.csv> [output.csv] [--account "My PayPal"] [--currency EUR]
#
# Options:
#   --account 'Name'      Value written to the Bank Account column (default: "My PayPal").
#   --currency 'Currency' Filter results only for specified currency
#   --merge               Merge mode: takes activity file then balance file as inputs.
#
# Optional mappings.yaml (place next to the script):
#   Maps any party name or account value to a canonical ERPNext name, e.g.:
#     "FIVERR INTERNATIONAL LTD.": "Fiverr"
#
# Activity deduplication:
#   PayPal activity exports repeat the same Transaction ID across multiple rows
#   when a transaction transitions through statuses (e.g. Pending -> Completed).
#   Only the latest record per Transaction ID (by date + time) is kept.

require 'csv'
require 'date'
require 'yaml'
require 'tzinfo'

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

args         = ARGV.dup
bank_account = 'My PayPal'
currency_filter = nil
merge_mode   = false

if (idx = args.index('--account'))
  bank_account = args.delete_at(idx + 1)
  args.delete_at(idx)
end

if (idx = args.index('--currency'))
  currency_filter = args.delete_at(idx + 1).to_s.upcase
  args.delete_at(idx)
end

if (idx = args.index('--merge'))
  merge_mode = true
  args.delete_at(idx)
end

if args.empty? || (merge_mode && args.size < 2)
  warn 'Usage:'
  warn '  ruby PayPal_to_ERPNext.rb <input.csv> [output.csv] [--account "My PayPal"] [--currency EUR]'
  warn '  ruby PayPal_to_ERPNext.rb --merge <activity.csv> <balance.csv> [output.csv] [--account "My PayPal"] [--currency EUR]'
  exit 1
end

output = nil
input = args[0]
if merge_mode
  balance_input = args[1]
  output = args[2] unless args[2].to_s.empty?
  unless File.exist?(balance_input)
    warn "Error: file not found -- #{balance_input}"
    exit 1
  end
else
  output = args[1] unless args[1].to_s.empty?
end

unless File.exist?(input)
  warn "Error: file not found -- #{input}"
  exit 1
end

postfix = ''
postfix = '_' + currency_filter if currency_filter
output = File.join(File.dirname(input), "#{File.basename(input, File.extname(input))}_erpnext#{postfix}.csv") if output.nil?

mappings = {}
mappings = Hash[YAML.load_file('mappings.yaml').map { |id, value| [id.to_s, value] }] if File.exist?('mappings.yaml')

# ---------------------------------------------------------------------------
# Format detection
# ---------------------------------------------------------------------------

def detect_format(raw)
  raise 'Unrecognized format!' unless raw.lines.first.to_s.include?('"Gross"')
  raw.lines.first.to_s.include?('"Type"') ? :activity : :balance
end

# ---------------------------------------------------------------------------
# Timezone helpers
# ---------------------------------------------------------------------------

TZ_ABBR_MAP = {
  'PDT' => 'America/Los_Angeles',
  'PST' => 'America/Los_Angeles'
}.freeze

def resolve_tz(tz_str)
  name = TZ_ABBR_MAP[tz_str] || tz_str
  TZInfo::Timezone.get(name)
end

def parse_datetime_utc(date_str, time_str, tz_str, date_fmt)
  raise 'Blank timezone' if tz_str.to_s.strip.empty?
  tz       = resolve_tz(tz_str.to_s.strip)
  combined = "#{date_str.strip} #{time_str.to_s.strip} +0000"
  fmt      = "#{date_fmt} %T %z"
  local    = Time.strptime(combined, fmt)
  tz.local_to_utc(local)
end

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

def parse_amount(str)
  return nil if str.to_s.strip.empty?
  str.to_f
end

def remap(value, mappings, currency = nil)
  if currency
    name = value.to_s + ' ' + currency
    return mappings[name] if mappings[name]
  end
  mappings[value] || value
end

def blank?(str)
  str.to_s.strip.empty?
end

def update_party_name(tx_type, party_name)
  tx_type.to_s.strip.downcase == 'general currency conversion' && blank?(party_name) ? 'PayPal' : party_name
end

# ---------------------------------------------------------------------------
# Row builders
# ---------------------------------------------------------------------------

# Column indices — used by merge enrichment to patch specific fields.
COL_TX_ID      = 0
COL_CURREMCY   = 6
COL_PARTY_NAME = 11
COL_PARTY_ACCT = 12

def build_row(tx_id, datetime, status, bank_account, gross, fee, currency,
              description, ref_number, tx_type, party_name, party_acct,
              party_country,
              custom_number, quantity, phone_number, mappings)
  deposit      = gross&.positive? ? gross     : nil
  withdrawal   = gross&.negative? ? gross.abs : nil
  excluded_fee = fee&.nonzero?    ? fee.abs   : nil

  [
    tx_id,                           # COL_TX_ID      = 0
    datetime.utc.strftime('%F'),
    status,
    remap(bank_account, mappings, currency),
    deposit,
    withdrawal,
    currency,                        # COL_CURREMCY   = 6
    description,
    ref_number,
    tx_id,
    tx_type,
    remap(party_name, mappings),     # COL_PARTY_NAME = 11
    party_acct,                      # COL_PARTY_ACCT = 12
    excluded_fee,
    datetime.utc.iso8601,
    party_country,
    custom_number,
    quantity,
    phone_number
  ]
end

# ---------------------------------------------------------------------------
# Format-specific row parsers
# ---------------------------------------------------------------------------

def parse_balance_row(row, bank_account, mappings)
  gross = parse_amount(row[:gross])
  fee   = parse_amount(row[:fee])

  datetime = parse_datetime_utc(row[:date], row[:time], row[:time_zone], '%m/%d/%Y')

  description = row[:description]&.strip
  tx_type     = description

  party_name = row[:name]&.strip
  party_name = row[:from_email_address]&.strip if blank?(party_name)
  party_name = row[:bank_name]&.strip          if blank?(party_name)
  party_name = update_party_name(tx_type, party_name)

  party_acct = row[:bank_account]&.strip
  if blank?(party_acct)
    party_acct = row[:from_email_address]&.strip
  elsif party_acct.length == 4 # When Debit/Credit card is used
    party_acct = party_name.split(' ').first.capitalize + ' Card - ' + party_acct
  end

  tx_id      = row[:transaction_id]&.strip
  ref_number = row[:reference_txn_id]&.strip
  invoice_id = row[:invoice_id]&.strip
  ref_number = invoice_id if blank?(ref_number) && !blank?(invoice_id)

  currency = row[:currency].to_s.strip.upcase

  build_row(tx_id, datetime, 'Settled', bank_account, gross, fee, currency,
            description, ref_number, tx_type, party_name, party_acct,
            nil, nil, nil, nil, mappings)
end

# Returns { datetime:, row_data: } so the caller can deduplicate before finalising.
def parse_activity_row(row, bank_account, mappings)
  # Drop balance non-impacting entries
  return nil if row[:balance_impact].to_s.strip.downcase == 'memo' || row[:type].to_s.strip.downcase == 'shopping cart item'

  gross = parse_amount(row[:gross])
  fee   = parse_amount(row[:fee])

  datetime = parse_datetime_utc(row[:date], row[:time], row[:timezone], '%d/%m/%Y')

  tx_type     = row[:type]&.strip
  description = blank?(row[:item_title]) ? tx_type : row[:item_title].to_s.strip
  description += "\n" + row[:note].to_s.strip unless blank?(row[:note])

  status = row[:status].to_s.strip.downcase == 'pending' ? 'Pending' : 'Settled'

  party_name = row[:name]&.strip
  party_acct =
    if row[:balance_impact].to_s.strip.downcase == 'credit'
      row[:from_email_address]&.strip
    else
      row[:to_email_address]&.strip
    end

  party_name = party_acct if blank?(party_name)
  party_name = update_party_name(tx_type, party_name)
  party_country = blank?(row[:transaction_buyer_country_code]) ? nil : row[:transaction_buyer_country_code]
  payment_source = row[:payment_source]
  if blank?(party_acct) && !blank?(payment_source)
    card_match = payment_source.match(/\[(\d{4})\]/)
    if card_match.is_a?(MatchData)
      party_acct = 'Card - ' + card_match[1]
    else
      party_acct = payment_source
    end
  end

  tx_id      = row[:transaction_id]&.strip
  ref_number = row[:reference_txn_id]&.strip
  invoice_id = (row[:invoice_number] || row[:invoice_id])&.strip
  ref_number = invoice_id if blank?(ref_number) && !blank?(invoice_id)

  custom_number = row[:custom_number]&.strip
  quantity      = row[:quantity]&.strip
  phone_number  = row[:contact_phone_number]&.strip

  currency = row[:currency].to_s.strip.upcase

  row_data = build_row(tx_id, datetime, status, bank_account, gross, fee,
                       currency, description, ref_number, tx_type,
                       party_name, party_acct, party_country, custom_number, quantity,
                       phone_number, mappings)

  { datetime: datetime, row_data: row_data }
end

# ---------------------------------------------------------------------------
# Deduplication
#
# PayPal activity exports can repeat the same Transaction ID when a transaction
# moves through status changes (Pending -> Completed). We keep only the entry
# with the latest UTC timestamp so the final CSV reflects the settled state.
# ---------------------------------------------------------------------------

def deduplicate_activity(entries)
  entries.group_by { |e| e[:row_data][COL_TX_ID] }
         .map do |_tx_id, group|
    group.max_by { |e| e[:datetime] }[:row_data]
  end
end

# ---------------------------------------------------------------------------
# File-level parsers
# ---------------------------------------------------------------------------

def parse_file_as_activity(raw, bank_account, currency_filter, mappings)
  entries = []
  col_sep = raw.lines.first.to_s.include?("\t") ? "\t" : ','
  CSV.parse(raw, headers: true, header_converters: :symbol, col_sep: col_sep) do |row|
    entry = parse_activity_row(row, bank_account, mappings)
    entries << entry if entry && (currency_filter.nil? || entry[:row_data][COL_CURREMCY] == currency_filter)
  end
  deduplicate_activity(entries)
end

def parse_file_as_balance(raw, bank_account, currency_filter, mappings)
  rows = []
  col_sep = raw.lines.first.to_s.include?("\t") ? "\t" : ','
  CSV.parse(raw, headers: true, header_converters: :symbol, col_sep: col_sep) do |row|
    row = parse_balance_row(row, bank_account, mappings)
    rows << row if currency_filter.nil? || row[COL_CURREMCY] == currency_filter
  end
  rows
end

# ---------------------------------------------------------------------------
# Merge helpers
# ---------------------------------------------------------------------------

# Build a lookup { tx_id => { party_name:, party_acct: } } from balance rows.
def balance_party_lookup(balance_rows)
  balance_rows.each_with_object({}) do |row, h|
    tx_id = row[COL_TX_ID].to_s
    h[tx_id] = { party_name: row[COL_PARTY_NAME], party_acct: row[COL_PARTY_ACCT] }
  end
end

# Overwrite party_name / party_acct in activity rows with balance data where
# available. The balance statement carries richer counterparty info (real name,
# bank name) vs. the email addresses in the activity export.
def enrich_from_balance(activity_rows, party_lookup)
  enriched = 0
  activity_rows.map do |row|
    party = party_lookup[row[COL_TX_ID].to_s]
    next row unless party

    unless blank?(party[:party_name])
      row[COL_PARTY_NAME] = party[:party_name]
      enriched += 1
    end
    row[COL_PARTY_ACCT] = party[:party_acct] unless blank?(party[:party_acct])
    row
  end.tap { puts "  Enriched #{enriched} transaction(s) with balance party info." }
end

# ---------------------------------------------------------------------------
# Main logic
# ---------------------------------------------------------------------------

rows =
  if merge_mode
    activity_raw = File.read(input, encoding: 'bom|utf-8')
    balance_raw  = File.read(balance_input,  encoding: 'bom|utf-8')

    unless detect_format(activity_raw) == :activity
      warn 'Error: first file in --merge mode must be the activity (tab-separated) export.'
      exit 1
    end
    unless detect_format(balance_raw) == :balance
      warn 'Error: second file in --merge mode must be the balance (comma-separated) export.'
      exit 1
    end

    puts 'Merge mode: parsing activity statement...'
    activity_rows = parse_file_as_activity(activity_raw, bank_account, currency_filter, mappings)
    puts "  #{activity_rows.size} unique transaction(s) after deduplication."

    puts 'Merge mode: parsing balance statement...'
    balance_rows = parse_file_as_balance(balance_raw, bank_account, currency_filter, mappings)
    puts "  #{balance_rows.size} transaction(s) in balance statement."

    puts 'Merging party info from balance into activity rows...'
    enrich_from_balance(activity_rows, balance_party_lookup(balance_rows))

  else
    raw    = File.read(input, encoding: 'bom|utf-8')
    format = detect_format(raw)
    puts "Detected format: #{format}"

    case format
    when :activity then parse_file_as_activity(raw, bank_account, currency_filter, mappings)
    else                parse_file_as_balance(raw,  bank_account, currency_filter, mappings)
    end
  end

# ---------------------------------------------------------------------------
# Write ERPNext CSV
# ---------------------------------------------------------------------------

CSV.open(output, 'w', force_quotes: false) do |csv|
  csv << [
    'ID',
    'Date',
    'Status',
    'Bank Account',
    'Deposit',
    'Withdrawal',
    'Currency',
    'Description',
    'Reference Number',
    'Transaction ID',
    'Transaction Type',
    'Party Name/Account Holder (Bank Statement)',
    'Party Account No. (Bank Statement)',
    'Excluded Fee',
    'Timestamp',
    'Country',
    'Custom Number',
    'Quantity',
    'Contact Phone Number'
  ]

  rows.each { |r| csv << r }
end

puts "Converted #{rows.size} transaction(s) -> #{output}"
