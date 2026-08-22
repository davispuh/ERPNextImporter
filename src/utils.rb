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

def previous_year(date = Time.now.utc.to_date)
  year = date.prev_year.year
  [Date.new(year, 1, 1), Date.new(year, 12, 31)]
end

def previous_quarter(date = Time.now.utc.to_date)
  quarter = (date.month - 1) / 3 + 1
  prev_quarter = quarter - 1
  year = date.year

  if prev_quarter == 0
    prev_quarter = 4
    year -= 1
  end

  start_month = (prev_quarter - 1) * 3 + 1
  end_month = prev_quarter * 3

  start_date = Date.new(year, start_month, 1)
  end_date = Date.new(year, end_month, -1)

  [start_date, end_date]
end

def previous_month(date = Time.now.utc.to_date)
  prev_month = date.prev_month
  [Date.new(prev_month.year, prev_month.month, 1), Date.new(prev_month.year, prev_month.month, -1)]
end
