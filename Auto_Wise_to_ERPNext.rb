#!/usr/bin/env ruby
# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require 'cgi'
require 'date'
require 'logger'
require 'set'
require 'dotenv'
require 'optparse'
require 'optparse/date'

require_relative 'src/utils'
require_relative 'src/wise'
require_relative 'src/erpnext'

options = {
  config_path: 'config.yaml',
  import: false,
  submit: false,
  year: false,
  quarter: false,
  month: false
}

option_parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby #{File.basename($PROGRAM_NAME)} [options]"
  opts.separator ''
  opts.separator 'Fetch Wise balance statements and import them into ERPNext as Bank'
  opts.separator 'Transactions. Without --import nothing is created (dry-run).'
  opts.separator ''
  opts.separator 'Options:'
  opts.on('-c', '--config PATH', 'Path to config.yaml (default: config.yaml)') do |value|
    options[:config_path] = value
  end
  opts.on('--from YYYY-MM-DD', Date,
          'Start date (default: date of last imported transaction') do |value|
    options[:from] = value.iso8601
  end
  opts.on('--to YYYY-MM-DD', Date, 'End date (default: today)') do |value|
    options[:to] = value.iso8601
  end
  opts.on('-t', '--type TYPE', 'Statement type: FLAT or COMPACT (default: FLAT)') do |value|
    options[:type] = value.to_s.upcase
  end
  opts.on('--days-back N', Integer,
          'Look back this many days when nothing imported yet (default: 180)') do |value|
    options[:days_back] = value
  end
  opts.on('--year', 'Save last year statements of all balances to files instead of importing') do
    options[:year] = true
  end
  opts.on('--quarter', 'Save last quarter statements of all balances to files instead of importing') do
    options[:quarter] = true
  end
  opts.on('--month', 'Save last month statements of all balances to files instead of importing') do
    options[:month] = true
  end
  opts.on('--import', 'Create Bank Transactions in ERPNext (default is dry-run)') do
    options[:import] = true
  end
  opts.on('--submit', 'Also submit the created/imported Bank Transactions') do
    options[:submit] = true
  end
  opts.on('-h', '--help', 'Show this help') do
    puts opts
    exit
  end
end

begin
  option_parser.parse!
rescue OptionParser::ParseError => e
  warn "Error: #{e.message}"
  puts option_parser
  exit 1
end

config_path   = options[:config_path]
from_override = options[:from]
to_override   = options[:to]
type_override = options[:type]
days_back     = options[:days_back]
dry_run       = !options[:import]
submit        = options[:submit]
year          = options[:year]
quarter       = options[:quarter]
month         = options[:month]

config = {}
if File.exist?(config_path)
  config = YAML.safe_load(File.read(config_path)) || {}
else
  warn "Warning: config file not found -- #{config_path}, using defaults/env"
end

wise_cfg    = config['wise'] || {}
erpnext_cfg = config['erpnext'] || {}

Dotenv.load(File.expand_path('.env'))

ERPNEXT_URL = ENV['ERPNEXT_URL'] || erpnext_cfg['url'].to_s
ERPNEXT_API_KEY = ENV['ERPNEXT_API_KEY']
ERPNEXT_API_SECRET = ENV['ERPNEXT_API_SECRET']

missing = []
missing << 'ERPNEXT_URL' unless ERPNEXT_URL
missing << 'ERPNEXT_API_KEY' unless ERPNEXT_API_KEY
missing << 'ERPNEXT_API_SECRET' unless ERPNEXT_API_SECRET
unless missing.empty?
  warn "Missing required setting(s): #{missing.join(', ')}"
  warn 'Provide ERPNEXT_URL in config.yaml and secrets via environment variables.'
  exit 1
end

statement_type = (type_override || wise_cfg['statement_type'] || 'FLAT').to_s.upcase
unless %w[FLAT COMPACT].include?(statement_type)
  warn "Invalid statement type: #{statement_type} (must be FLAT or COMPACT)"
  exit 1
end

days_back ||= (wise_cfg['days_back'] || 180).to_i
locale      = wise_cfg['locale'] || Wise::DEFAULT_LOCALE
profile_id  = wise_cfg['profile_id'].to_s
wise_domain = wise_cfg['domain'] || Wise::DOMAIN

def erp_bank_account(balance)
  bank_account = (balance['iban'] || balance['account_number'] || 'Wise Balance ' + balance['id'].to_s).gsub(' ', '')
  remap(bank_account, mappings, currency)
end

def statement_name(balance_id, from, to, format)
  if balance_id.is_a?(Array) && balance_id.length > 1
    "statement_#{from}_#{to}_#{format}.zip"
  else
    balance_id = balance_id.first if balance_id.is_a?(Array)
    "statement_#{balance_id}_#{from}_#{to}.#{format.to_s.downcase}"
  end
end

def save_statements(wise, profile_id, balance_id, from:, to:, type:, locale:, logger:)
  balance_ids = balance_id.is_a?(Array) ? balance_id : [balance_id]
  [:json, :pdf, :xlsx, :csv, :xml].each do |format|
    logger.info("#{balance_id.join(',')}: saving #{from} -> #{to} (#{format})")
    statement = wise.statement(profile_id, balance_id, from: from, to: to, type: type, format: format, locale: locale)
    statement = JSON.pretty_generate(statement) unless statement.is_a?(String)
    File.write(statement_name(balance_id, from, to, format), statement)
  end
end

def erpnext_transactions(statement, bank_account, mappings)
  bank_transactions = []
  transactions = (statement['transactions'] || []).sort_by { |transaction| Time.parse(transaction['date']) }
  transactions.map do |transaction|
    datetime = Time.parse(transaction['date'])
    if transaction['amount']['value'].negative?
      deposit = nil
      withdrawal = transaction['amount']['value'].abs
      party_name = transaction['details'].dig('recipient', 'name')
      iban, account = Wise.iban_account(transaction['details'].dig('recipient', 'bankAccount'))
    else
      deposit = transaction['amount']['value']
      withdrawal = nil
      party_name = transaction['details']['senderName']
      iban, account = Wise.iban_account(transaction['details']['senderAccount'])
    end
    name = Wise.build_id(transaction['referenceNumber'], deposit, transaction['amount']['currency'], datetime).chop
    bank_transaction = {
      naming_series: name + '.#',
      name: name,
      date: datetime.utc.to_date.to_s,
      bank_account: bank_account,
      deposit: deposit,
      withdrawal: withdrawal,
      currency: transaction['amount']['currency'],
      description: transaction['details']['description'],
      reference_number: transaction['details']['paymentReference'],
      transaction_id: transaction['referenceNumber'],
      transaction_type: Wise.transaction_type(transaction['details']['type'], transaction['referenceNumber']),
      bank_party_name: party_name,
      bank_party_account_number: account,
      bank_party_iban: iban,
      included_fee: transaction['totalFees']['value'].to_f,
      comments: []
    }
    bank_transaction[:included_fee] = 0.0 if bank_transaction[:description].include?('(fee: ')
    bank_transaction[:bank_party_name] = Wise.bank_party_name(bank_transaction[:bank_party_name], transaction['details'].dig('merchant', 'name'), transaction['details'].dig('merchant', 'city'), bank_transaction[:transaction_id], bank_transaction[:transaction_type], bank_transaction[:description])
    bank_transaction[:bank_party_name] = remap(bank_transaction[:bank_party_name], mappings)
    unless transaction['activityAssetAttributions'].to_a.empty?
      transaction['activityAssetAttributions'].each do |activity|
        asset_id = activity['assetId']['value']
        bank_transaction[:comments] << "#{Time.parse(activity['tradeTime']).utc.to_s} - #{activity['tradeSide']} #{activity['tradedUnits']} #{asset_id} at #{activity['assetPrice']['value']} #{activity['assetPrice']['currency']}"
      end
    end
    if transaction['exchangeDetails']
      from_amount = transaction['exchangeDetails']['fromAmount']['value']
      from_currency = transaction['exchangeDetails']['fromAmount']['currency']
      to_amount = transaction['exchangeDetails']['toAmount']['value']
      to_currency = transaction['exchangeDetails']['toAmount']['currency']
      rate = transaction['exchangeDetails']['rate']
      bank_transaction[:comments] << "#{datetime.utc.to_s} - Exchanged #{from_amount} #{from_currency} to #{to_amount} #{to_currency} at #{rate}"
    end
    if transaction['details']['cardLastFourDigits']
      bank_transaction[:comments] << "Card *#{transaction['details']['cardLastFourDigits']}"
    end
    bank_transactions << bank_transaction
  end
  bank_transactions
end

logger = Logger.new($stderr)
logger.level = Logger::INFO

erp = ERPNext::Client.new(url: ERPNEXT_URL, api_key: ERPNEXT_API_KEY, api_secret: ERPNEXT_API_SECRET)
wise = Wise::Client.new(
  user_token: ENV['WISE_USER_TOKEN'], oauth_token: ENV['WISE_OAUTH_TOKEN'], api_token: ENV['WISE_API_TOKEN'],
  domain: wise_domain, logger: logger,
  cookie_browser: wise_cfg['cookie_browser']
)

if profile_id.empty?
  profiles = wise.profiles
  raise Wise::Error, 'No Wise profiles found for this token' if profiles.empty?
  puts 'Profiles:'
  profiles.each do |profile|
    puts "#{profile['id']} - #{profile['fullName']}"
  end
  profile_id = profiles.first['id']
  logger.info("Using Wise profile #{profile_id} (#{profiles.first['fullName']})")
end

balances_details = wise.balances_details(profile_id)
if balances_details.empty?
  warn 'No balances found for the profile'
  exit 1
end

all_stats = {}
mappings = load_mappings
balance_ids = balances_details.map { |balance| balance['id'] }

if year
  from, to = previous_year
  wise.use_legacy = true
  save_statements(wise, profile_id, balance_ids, from: from, to: to, type: statement_type, locale: locale, logger: logger)
end

if quarter
  from, to = previous_quarter
  wise.use_legacy = true
  save_statements(wise, profile_id, balance_ids, from: from, to: to, type: statement_type, locale: locale, logger: logger)
end

if month
  from, to = previous_month
  wise.use_legacy = true
  save_statements(wise, profile_id, balance_ids, from: from, to: to, type: statement_type, locale: locale, logger: logger)
end

if !year && !quarter && !month
  wise.use_legacy = false
  balances_details.each do |balance|
    balance_id = balance['id']
    bank_account = (balance['iban'] || balance['account_number'])&.gsub(' ', '') || "Wise Balance #{balance_id}"
    currency = balance['currency']

    erp_bank_account = remap(bank_account, mappings, currency)

    unless erp.bank_account_exists?(erp_bank_account)
      logger.warn("#{balance_id} #{currency}: skipping - Bank Account '#{erp_bank_account}' not found in ERPNext, can't import without it")
      all_stats["#{balance_id} #{currency}"] = { fetched: 0, created: 0, submitted: 0, skipped: 0 }
      next
    end

    from, to = erp.bank_transaction_date_range(erp_bank_account, days_back, from_override, to_override)

    logger.info("#{balance_id} #{currency}: fetching #{from} -> #{to} (ERPNext bank account: #{erp_bank_account})")

    statement = wise.statement(profile_id, balance_id, from: from, to: to, type: statement_type, format: :json, locale: locale)
    transactions = erpnext_transactions(statement, erp_bank_account, mappings)
    logger.info("#{balance_id} #{currency}: #{transactions.size} transactions")

    created = 0
    skipped = 0
    submitted = 0

    erp_transactions = erp.bank_transactions(erp_bank_account, from - 10)
    transactions.each do |transaction|
      erp_transaction = erp_transactions.find { |erp_transaction| erp_transaction['name'].chop == transaction[:name] && erp_transaction['docstatus'] != 2 }
      candidates = erp_transactions.find_all { |erp_transaction| erp_transaction['transaction_id'] == transaction[:transaction_id] && erp_transaction['docstatus'] != 2 }
      erp_transaction = candidates.first if erp_transaction.nil? && candidates.length == 1
      is_new = erp_transaction.nil? && candidates.empty?
      if is_new
        amount_str = transaction[:deposit].nil? ? "-#{transaction[:withdrawal]}" : "+#{transaction[:deposit]}"
        party_name = ''
        party_name = " (#{transaction[:bank_party_name]})" if transaction[:bank_party_name]
        if dry_run
          logger.info("#{balance_id} #{currency}: DRY-RUN would create#{submit ? ' + submit' : ''} #{transaction[:date]} #{transaction[:transaction_id]} #{amount_str} #{currency}#{party_name}")
          submitted += 1 if submit
        else
          document = erp.save_bank_transaction(transaction, submit)
          erp.save_bank_transaction_comment(document['name'], transaction[:comments])
          if submit
            submitted += 1
            logger.info("#{balance_id} #{currency}: created + submitted #{document['name']} #{transaction[:date]} #{transaction[:transaction_id]} #{amount_str} #{currency}#{party_name}")
          else
            logger.info("#{balance_id} #{currency}: created (not submitted) #{document['name']} #{transaction[:date]} #{transaction[:transaction_id]} #{amount_str} #{currency}#{party_name}")
          end
        end
        created += 1
      else
        if erp_transaction && submit
          unless dry_run
            erp.save_bank_transaction_comment(erp_transaction['name'], transaction[:comments])
          end
          if erp_transaction['docstatus'].to_i.zero?
            if dry_run
              logger.info("#{balance_id} #{currency}: DRY-RUN would submit (already created) #{erp_transaction['date']} #{transaction[:transaction_id]}")
            else
              document = erp.submit(erp_transaction['name'])
              logger.info("#{balance_id} #{currency}: already created, submitted #{document['name']} #{erp_transaction['date']} #{transaction[:transaction_id]}")
            end
            submitted += 1
          else
            logger.info("#{balance_id} #{currency}: skipped (already submitted) #{erp_transaction['name']} #{erp_transaction['date']} #{transaction[:transaction_id]}")
            skipped += 1
          end
        else
          logger.info("#{balance_id} #{currency}: skipped (already present) #{transaction[:transaction_id]}")
          skipped += 1
        end
      end
    end
    all_stats["#{balance_id} #{currency}"] = { fetched: transactions.size, created: created, submitted: submitted, skipped: skipped }
  end
end

puts "\nSummary:"
all_stats.each do |balance_id, stats|
  puts format('  %-4s fetched=%d created=%d submitted=%d skipped=%d',
              balance_id, stats[:fetched], stats[:created], stats[:submitted], stats[:skipped])
end
