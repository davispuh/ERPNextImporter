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
