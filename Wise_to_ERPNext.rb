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

require_relative 'src/utils'
require_relative 'src/wise'

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

# ---------------------------------------------------------------------------
# Parse Wise CSV
# ---------------------------------------------------------------------------

raw  = File.read(input, encoding: 'bom|utf-8')
rows = Wise.parse_csv(raw, bank_account, timezone, load_mappings)

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
