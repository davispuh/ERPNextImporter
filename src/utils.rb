# frozen_string_literal: true

# utils.rb
#
# Shared helpers used by the ERPNext importer scripts
# (Wise_to_ERPNext.rb, Wise_to_ERPNext_API.rb, ...).
#
# Requires:
#   ruby -e 'require "tzinfo"'

require 'time'
require 'yaml'
require 'tzinfo'


def load_mappings(path = 'mappings.yaml')
  return {} unless File.exist?(path)
  Hash[YAML.load_file(path).map { |id, value| [id.to_s, value] }]
end

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
    parts = last_datetime.to_a[0, 6].reverse
    offset = tz.local_time(*parts).strftime('%z')
  else
    offset = timezone
  end
  rows.each do |row|
    parts = row[:datetime].to_a[0, 6].reverse + [offset]
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

def iban_acct(acct)
  iban = acct.to_s.gsub(' ', '')
  return [iban, nil] if iban.match?(/^[A-Z]{2}\d{2}[A-Z0-9]{11,}$/)
  [nil, acct]
end
