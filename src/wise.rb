# frozen_string_literal: true

require 'csv'
require 'time'
require_relative 'utils'

module Wise

  def self.parse_csv(data, bank_account, timezone, mappings)
    rows = []
    CSV.parse(data, headers: true, header_converters: :symbol) do |row|
      # --- IDs ---
      tx_id = row[:transferwise_id]
      raise 'Not valid Wise statement CSV' unless tx_id

      datetime = parse_datetime(row[:date_time])
      amount     = row[:amount].to_f
      deposit    = amount.positive? ? amount     : nil
      withdrawal = amount.negative? ? amount.abs : nil
      currency = row[:currency].upcase
      description = row[:description]
      ref_number  = row[:payment_reference]
      tx_type = transaction_type(row[:transaction_details_type], tx_id)

      if amount.negative?
        party_name = row[:payee_name]
        party_acct = row[:payee_account_number]
      else
        party_name = row[:payer_name]
        party_acct = nil
      end

      party_name = bank_party_name(party_name, row[:merchant], nil, tx_id, tx_type, description)
      party_iban, party_acct = iban_account(party_acct)

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
    rows
  end

  # Wise statement export has a bug that it will use same UTC offset for whole export...
  # This will cause wrong times depending for what period you export data
  # For example period 2025-07-01 - 2025-07-31 will have all times with UTC +03:00 offset
  # But period 2025-07-01 - 2025-11-30 will have all times with UTC +02:00 offset (even when such offset is not used at that time)
  # It's not issue for CAMT.053 statements because UTC offset is always included so you can just convert it
  # But CSV/XLSX doesn't include offset so you get wrong time
  # I don't know if they use your timezone or always 'Europe/Tallinn' so this might work only for me...
  def self.fix_datetime(rows, timezone)
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
      row[:id] = build_id(row[:tx_id], row[:deposit], row[:currency], row[:datetime])
    end
    rows
  end

  def self.build_id(transaction_id, deposit, currency, datetime)
    id = transaction_id
    id += (deposit.nil? ? '-C-' : '-D-') + currency + '-' + datetime.utc.to_i.to_s unless id.gsub('-', '').match?(/[0-9A-F]{32,}/i) # UUID should be fine
    id
  end

  def self.transaction_type(type, transaction_id)
    tx_type = type.upcase
    tx_type = transaction_id.split('-').first.upcase if tx_type == 'UNKNOWN'
    tx_type = 'FEE-' + tx_type if transaction_id.upcase.start_with?('FEE-') && !tx_type.start_with?('FEE')
    tx_type
  end

  def self.bank_party_name(name, merchant_name, merchant_city, transaction_id, transaction_type, description)
    unless name
      name = merchant_name
      name += " #{merchant_city}" if merchant_city
    end
    name = 'Wise Europe SA' if transaction_id.downcase.include?('fee-')
    name = 'Wise Assets Europe SA' if transaction_type.upcase == 'ACCRUAL_CHARGE' && description.start_with?('Wise Assets Europe')
    name
  end

  def self.iban_account(bank_account)
    return [nil, nil] if bank_account.to_s.strip.empty?

    return [bank_account, nil] if bank_account.match?(/^[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){2}(?:(?: ?[A-Z0-9])[A-Z0-9]{0,3}){1,}$/)
    return [Regexp.last_match.to_s, bank_account] if bank_account.match(/[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){2}(?:(?: ?[A-Z0-9])[A-Z0-9]{0,3}){1,}$/)
    [nil, bank_account]
  end

end
