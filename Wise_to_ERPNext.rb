#!/usr/bin/env ruby
# frozen_string_literal: true

# Wise_to_ERPNext.rb
#
# Converts a Wise (TransferWise) CSV statement export to an ERPNext bank
# statement CSV ready for Accounting -> Banking -> Bank Statement Import.
#
# Usage:
#   ruby Wise_to_ERPNext.rb <input.csv> [output.csv] [--account 'My Wise'] [--timezone "auto"]
#
# Options:
#   --account 'Name'    Value written to the Bank Account column (default: 'My Wise').
#   --timezone '+hh:mm' Timezone to use for fixing Wise time bug (default: try to guess automatically based on last record).
#
# Optional mappings.yaml (place next to the script):
#   Maps any party name to a canonical ERPNext name, e.g.:
#     "FIVERR INTERNATIONAL LTD.": "Fiverr"
#
# If output path is omitted the CSV is written next to the input file
# with the same base name suffixed with `_erpnext.csv`.

require 'csv'
require 'date'
require 'yaml'
require 'tzinfo'

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

args         = ARGV.dup
bank_account = 'My Wise'
timezone     = nil

if (idx = args.index('--account'))
  bank_account = args.delete_at(idx + 1)
  args.delete_at(idx)
end

if (idx = args.index('--timezone'))
  timezone = args.delete_at(idx + 1)
  args.delete_at(idx)
end

if args.empty?
  warn 'Usage: ruby Wise_to_ERPNext.rb <input.csv> [output.csv] [--account "My Wise"] [--timezone "auto"]'
  exit 1
end

input  = args[0]
output = args[1] || File.join(
  File.dirname(input),
  "#{File.basename(input, File.extname(input))}_erpnext.csv"
)

unless File.exist?(input)
  warn "Error: file not found -- #{input}"
  exit 1
end

mappings = {}
mappings = Hash[YAML.load_file('mappings.yaml').map { |id, value| [id.to_s, value] }] if File.exist?('mappings.yaml')

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def parse_datetime(dt_str)
  Time.strptime(dt_str + '+0000', '%d-%m-%Y %T.%N%z')
end

def build_id(row)
  id = row[:tx_id]
  id += (row[:deposit].nil? ? '-C-' : '-D-') + row[:currency] + '-' + row[:datetime].utc.to_i.to_s unless id.gsub('-', '').match?(/[0-9A-F]{32,}/i) # UUID should be fine
  id
end

# Wise statement export has a bug that it will use same UTC offset for whole export...
# This will cause wrong times depending for what period you export data
# For example period 2025-07-01 - 2025-07-31 will have all times with UTC +03:00 offset
# But period 2025-07-01 - 2025-11-30 will have all times with UTC +02:00 offset (even when such offset is not used at that time)
# It's not issue for CAMT.053 statements because UTC offset is always included so you can just convert it
# But CSV/XLSX doesn't include offset so you get wrong time
# I don't know if they use your timezone or always 'Europe/Tallinn' so this might work only for me...
def fix_datetime(rows, timezone)
  return if rows.empty?
  if timezone.nil? || timezone.to_s.downcase == 'auto'
    last_datetime = rows.max_by { |row| row[:datetime] }[:datetime]
    tz = TZInfo::Timezone.get('Europe/Tallinn')
    parts = last_datetime.to_a[0,6].reverse
    offset = tz.local_time(*parts).strftime('%z')
  else
    offset = timezone
  end
  rows.each do |row|
    parts = row[:datetime].to_a[0,6].reverse + [offset]
    row[:datetime] = Time.new(*parts)
    row[:id] = build_id(row)
  end
  rows
end

def blank?(str)
  str.to_s.strip.empty?
end

def remap(value, mappings, currency = nil)
  if currency
    name = value.to_s + ' ' + currency
    return mappings[name] if mappings[name]
  end
  mappings[value] || value
end

# ---------------------------------------------------------------------------
# Parse Wise CSV
# ---------------------------------------------------------------------------

raw  = File.read(input, encoding: 'bom|utf-8')
rows = []

CSV.parse(raw, headers: true, header_converters: :symbol) do |row|
  # --- IDs ---
  tx_id = row[:transferwise_id]
  raise 'Not valid Wise statement CSV' unless tx_id

  # --- Datetime ---
  datetime = parse_datetime(row[:date_time])

  # --- Amounts ---
  amount     = row[:amount].to_f           # signed; negative = debit

  deposit    = amount.positive? ? amount     : nil
  withdrawal = amount.negative? ? amount.abs : nil

  # --- Currency ---
  currency = row[:currency].upcase

  # --- Description & reference ---
  description = row[:description]
  ref_number  = row[:payment_reference]

  # --- Transaction type ---
  tx_type = row[:transaction_details_type]
  tx_type = tx_id.split('-').first if tx_type.upcase == 'UNKNOWN'

  # --- Counterparty ---
  if amount.negative?
    # Outgoing: payee
    party_name = row[:payee_name]
    party_acct = row[:payee_account_number]
  else
    # Incoming: payer
    party_name = row[:payer_name]
    party_acct = nil
  end

  party_name = row[:merchant] if blank?(party_name)
  party_name = 'Wise Europe SA' if tx_id.downcase.include?('fee-')
  party_name = 'Wise Assets Europe SA' if tx_type.upcase == 'ACCRUAL_CHARGE' && description.start_with?('Wise Assets Europe')

  if party_acct.to_s.gsub(' ', '').match?(/^[A-Z]{2}\d{2}[A-Z0-9]{11,}$/)
    party_iban = party_acct
    party_acct = nil
  end

  included_fee = row[:total_fees].to_f
  # When 'fee' is included in description it means we're parsing statement with seperate
  # fees entries so this fee is actually excluded one so we don't need to add it
  included_fee = 0.0 if description.include?('(fee: ')

  from_currency = row[:exchange_from]
  to_currency = row[:exchange_to]
  exchange_rate = row[:exchange_rate]

  rows << {
    id: nil, # filled in `fix_datetime`
    datetime: datetime,
    bank_account: remap(bank_account, mappings, currency),
    deposit: deposit,
    withdrawal: withdrawal,
    currency: currency,
    description: description,
    ref_number: ref_number,
    tx_id: tx_id,
    tx_type: tx_type,
    party_name: remap(party_name, mappings),
    party_acct: party_acct,
    party_iban: party_iban,
    included_fee: included_fee,
    from_currency: from_currency,
    to_currency: to_currency,
    exchange_rate: exchange_rate
  }
end

fix_datetime(rows, timezone)

# ---------------------------------------------------------------------------
# Write ERPNext CSV
# ---------------------------------------------------------------------------

CSV.open(output, 'w', force_quotes: false) do |csv|
  csv << [
    'ID',
    'Date',
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
    'Party IBAN (Bank Statement)',
    'Included Fee',
    'Timestamp',
    'From Currency',
    'To Currency',
    'Exchange Rate'
  ]

  rows.sort_by! { |r| r[:datetime] }
  rows.each do |r|
    csv << [
      r[:id],
      r[:datetime].utc.strftime('%F'),
      r[:bank_account],
      r[:deposit],
      r[:withdrawal],
      r[:currency],
      r[:description],
      r[:ref_number],
      r[:tx_id],
      r[:tx_type],
      r[:party_name],
      r[:party_acct],
      r[:party_iban],
      r[:included_fee],
      r[:datetime].utc.iso8601,
      r[:from_currency],
      r[:to_currency],
      r[:exchange_rate]
    ]
  end
end

puts "Converted #{rows.size} transaction(s) -> #{output}"
