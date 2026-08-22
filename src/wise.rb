# frozen_string_literal: true

require 'csv'
require 'time'
require 'net/http'
require 'json'
require 'tmpdir'
require 'cookie_extractor'
require_relative 'utils'

module Wise
  DOMAIN = 'wise.com'
  API_VERSION = '2026Q3'
  LEGACY_VERSION = 'v1'
  ACCESS_TOKEN = 'Tr4n5f3rw153'
  DEFAULT_LOCALE = 'en'

  class Error < RuntimeError; end

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

  def self.cookies_from_browser(browser:, domain:)
    extractor =
      if browser.to_s.empty?
        CookieExtractor::BrowserDetector.guess
      else
        CookieExtractor::BrowserDetector.browser_extractor(browser)
      end

    want = { 'userToken' => nil, 'oauthToken' => nil }
    extractor.extract(format: false).each do |cookie|
      host = cookie[:domain].to_s
      next unless host == domain || host.end_with?(".#{domain}")
      want[cookie[:name]] = cookie[:value] if want.key?(cookie[:name])
    end
    [want['userToken'], want['oauthToken']]
  end

  class Client
    attr_writer :use_legacy

    def initialize(user_token: nil, oauth_token: nil, api_token: nil,
                   domain: DOMAIN, timeout: 60, max_retries: 8, logger: nil,
                   cookie_browser: nil)
      @user_token  = user_token
      @oauth_token = oauth_token
      @api_token   = api_token
      @domain      = domain
      @timeout     = timeout
      @max_retries = max_retries
      @logger      = logger
      @statement_requests = {}
      @ott = nil
      @use_legacy = false

      if blank?(@api_token) && (blank?(@user_token) || blank?(@oauth_token))
        user_token, oauth_token = Wise.cookies_from_browser(browser: cookie_browser, domain: @domain)
        if user_token && oauth_token
          @logger&.info('Wise: read session cookies from the browser')
          @user_token  = user_token
          @oauth_token = oauth_token
        else
          @logger&.warn('Wise: didn\'t find userToken/oauthToken; ' \
                        'log in Wise website in your browser first, then retry.')
        end
      end

      raise Error, 'No Wise credentials!' if blank?(@api_token) && (blank?(@user_token) || blank?(@oauth_token))
    end

    def profiles
      JSON.parse(api_get('/profiles'))
    end

    def balances(profile_id)
      JSON.parse(api_get("/profiles/#{profile_id}/balances", query: { types: 'STANDARD,SAVINGS' }))
    end

    def account_details(profile_id)
      JSON.parse(api_get("/profiles/#{profile_id}/account-details"))
    end

    def balances_details(profile_id)
      details = balances(profile_id)
      return details if details.empty?

      account_details(profile_id).each do |account|
        next unless account['balanceId']
        detail = details.find { |detail| detail['id'] == account['balanceId'] || (account['balanceId'] == -1 && account['currency']['code'] == detail['currency']) }
        next unless detail

        account['receiveOptions'].each do |options|
          item = options['details'].find { |detail| detail['type'] == 'ACCOUNT_NUMBER' }
          detail['account_number'] = item['body'] if item

          item = options['details'].find { |detail| detail['type'] == 'IBAN' }
          detail['iban'] = item['body'] if item
        end

        detail['account'] = account
      end

      details
    end

    def statement(profile_id, balance_id, from:, to:, type: 'FLAT', format: :json, locale: DEFAULT_LOCALE, refresh: false)
      if @use_legacy
        body = statement_request(profile_id, balance_id, from: from, to: to, type: type, format: format.to_s.upcase, locale: locale, refresh: refresh)
      else
        body = balance_statement(profile_id, balance_id, from: from, to: to, type: type, format: format.to_s.upcase, locale: locale)
      end
      if body.start_with?('{')
        JSON.parse(body)
      else
        body
      end
    end

    def balance_statement(profile_id, balance_id, from:, to:, type:, format:, locale:)
      if balance_id.is_a?(Array)
        raise Error, "Multiple balances at same time not supported!" if balance_id.length > 1
        balance_id = balance_id.first
      end

      start_s, end_s = interval_range(from, to)
      body = api_get("/profiles/#{profile_id}/balance-statements/#{balance_id}/statement.#{format.downcase}", query: {
        intervalStart: start_s,
        intervalEnd: end_s,
        type: type,
        statementLocale: locale
      },
      version: LEGACY_VERSION)
    end

    def statement_request(profile_id, balance_id, from:, to:, type:, format:, locale:, refresh:)
      balance_ids = balance_id.is_a?(Array) ? balance_id : [balance_id]
      request_id = find_or_create_statement_request(profile_id, balance_ids, from, to, type, format, locale, refresh)
      wait_for_statement_request(profile_id, request_id)
      statement_request_download(profile_id, request_id)
    end

    private

    def interval_range(from, to)
      [
        from.strftime('%Y-%m-%dT00:00:00.000Z'),
        (to + 1).strftime('%Y-%m-%dT00:00:00.000Z')
      ]
    end

    def statement_request_signature(profile_id, balance_ids, from, to, type, format, locale)
      [profile_id, balance_ids.sort, from.to_s, to.to_s, type, format, locale]
    end

    def find_or_create_statement_request(profile_id, balance_ids, from, to, type, format, locale, refresh)
      signature = statement_request_signature(profile_id, balance_ids, from, to, type, format, locale)
      request_id = @statement_requests[signature]
      return request_id if request_id

      unless refresh
        request_id = existing_statement_request(profile_id, signature)
        return request_id if request_id
      end

      request_id = create_statement_request(profile_id, balance_ids, from, to, type, format, locale)
      @statement_requests[signature] = request_id
      request_id
    end

    def forget_statement_request(profile_id, balance_ids, from, to, type, format, locale)
      signature = statement_request_signature(profile_id, balance_ids, from, to, type, format, locale)
      @statement_requests.delete(signature)
    end

    def existing_statement_request(profile_id, signature)
      statement_request_list(profile_id).each do |request|
        next unless ['AVAILABLE', 'PENDING'].include?(request['status'])
        next unless request['type'] == signature[4] && request['format'] == signature[5] && request['locale'] == signature[6]
        next unless interval_equal?(request['intervalStart'], request['intervalEnd'], signature[2], signature[3])
        next unless (statement_request_details(profile_id, request['id'])['balanceIds'] || []).sort == signature[1]

        request_id = request['id']
        wait_for_statement_request(profile_id, request_id) if request['status'] == 'PENDING'
        @logger&.info("Wise: reusing statement request #{request_id} (#{signature[4]}, #{signature[5]})")
        return request_id
      end
      nil
    end

    def interval_equal?(intervalStart, intervalEnd, from_str, to_str)
      Time.parse(intervalStart).to_date.to_s == from_str &&
      Time.parse(intervalEnd).to_date.to_s == to_str
    end

    def statement_request_list(profile_id)
      @statement_request_lists ||= {}
      @statement_request_lists[profile_id] ||= JSON.parse(api_get("/profiles/#{profile_id}/statement-requests", version: LEGACY_VERSION))
    end

    def statement_request_details(profile_id, request_id)
      @statement_request_details ||= {}
      @statement_request_details[request_id] ||= JSON.parse(api_get("/profiles/#{profile_id}/statement-requests/#{request_id}", version: LEGACY_VERSION))
    end

    def create_statement_request(profile_id, balance_ids, from, to, type, format, locale)
      start_s, end_s = interval_range(from, to)
      body = api_post(
        "/profiles/#{profile_id}/statement-requests",
        body: {
          balanceIds: balance_ids,
          intervalStart: start_s,
          intervalEnd: end_s,
          type: type,
          format: statement_format(format),
          locale: locale
        },
        version: LEGACY_VERSION
      )
      request = JSON.parse(body)
      raise Error, "Gateway rejected statement request: #{body.to_s[0, 300]}" unless request['id']

      @logger&.info("Wise: statement request #{request['id']} (#{type}, #{format})")
      request['id']
    end

    def wait_for_statement_request(profile_id, request_id, timeout: 180)
      deadline = Time.now + timeout
      loop do
        body = api_get("/profiles/#{profile_id}/statement-requests/#{request_id}", version: LEGACY_VERSION)
        request = JSON.parse(body)
        status = request['status']
        return request if status == 'AVAILABLE'
        if status == 'FAILED'
          raise Error, "Wise: statement request #{request_id} failed (interval: #{request['intervalStart']} .. #{request['intervalEnd']}, format: #{request['format']})"
        end
        raise Error, "Wise: statement request #{request_id} stuck in #{status}" if Time.now > deadline

        sleep 5
      end
    end

    def statement_request_download(profile_id, request_id)
      api_get("/profiles/#{profile_id}/statement-requests/#{request_id}/statement-file", version: LEGACY_VERSION)
    end

    def statement_format(format)
      if format.to_s.downcase.to_sym == :xml
        'CAMT_053_10'
      elsif format.to_s.downcase.to_sym == :pdf
        'PDF_WITH_STAMP'
      else
        format.to_s.upcase
      end
    end

    def ott_status(ott)
      @pending_ott = ott
      JSON.parse(api_get("/one-time-token/status", query: { viewType: :full }))
    end

    def ott_trigger(type, number)
      JSON.parse(api_post("/one-time-token/#{type.to_s.downcase}/trigger", body: { phoneNumberId: number }))
    end

    def ott_verify(type, otp)
      api_post("/one-time-token/#{type.to_s.downcase}/verify", body: { otpCode: otp }, raw: true)
    end

    def api_get(path, query: {}, version: API_VERSION, raw: false)
      api_request(:get, version, path, query: query, raw: raw)
    end

    def api_post(path, query: {}, body: nil, version: API_VERSION, raw: false)
      api_request(:post, version, path, query: query, body: body, raw: raw)
    end

    def api_request(method, version, path, query: {}, body: nil, raw: false)
      uri = URI("https://api.#{@domain}/#{version}#{path}")
      uri.query = URI.encode_www_form(query) unless query.empty?
      attempt = 0
      http = http(uri)
      loop do
        attempt += 1
        request = http_request(uri, method, body)
        response = http.request(request)

        @ott = nil if response['x-2fa-approval-result']

        return response if raw

        code = response.code.to_i
        return response.body if code.between?(200, 299)

        if code == 401
          raise Error, 'Wise API auth failed (401). Update token or refresh session cookies.'
        end

        if code == 403 && response['x-2fa-approval']
          if complete_challenge(response['x-2fa-approval'])
            next
          end
        end

        if [400, 404].include?(code)
          @logger&.info(uri.to_s)
          @logger&.info(body.to_s)
        end

        if retryable?(code) && attempt <= @max_retries
          wait = backoff(code, response, attempt)
          @logger&.warn("Wise API #{code} on #{path}, retry #{attempt}/#{@max_retries} in #{wait}s")
          sleep(wait)
          next
        end

        raise Error, "Wise API error #{code} on #{path}: #{response.body.to_s[0, 500]}"
      end
    end

    def complete_challenge(ott)
      status = ott_status(ott)
      challenge = status['oneTimeTokenProperties']['challenges'][0]['primaryChallenge']
      number = challenge['availablePhoneNumbers'].first['id']
      message = challenge['viewData'][number]['message']
      ott_trigger(challenge['type'], number)
      $stderr.puts(message)
      loop do
        $stderr.print("Code: ")
        code = $stdin.gets.chomp.strip
        if !code.to_s.empty?
          response = ott_verify(challenge['type'], code)
          body = JSON.parse(response.body)
          if response.code.to_i == 200
            result = body['oneTimeTokenProperties']
            @ott = result['oneTimeToken']
            @pending_ott = nil
            return result['validity'] > 0
          else
            puts body['message']
          end
        end
      end
    end

    def http(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = @timeout
      http.read_timeout = @timeout
      http
    end

    def http_request(uri, method, body)
      request = if method == :post
        Net::HTTP::Post.new(uri)
      else
        Net::HTTP::Get.new(uri)
      end
      request['Authorization'] = "Bearer #{@api_token}" if @api_token
      request['x-access-token'] = ACCESS_TOKEN
      request['Content-Type'] = 'application/json'
      request['User-Agent'] = 'Mozilla/5.0 Gecko/20100101 Firefox/153.0'
      request['Cookie'] = "userToken=#{@user_token}; oauthToken=#{@oauth_token}" if @user_token && @oauth_token
      request['one-time-token'] = @pending_ott if @pending_ott
      request['x-2fa-approval'] = @ott if @ott

      request.body = body.is_a?(String) ? body : JSON.generate(body) if body
      request
    end

    def retryable?(code)
      code == 429 || code >= 500
    end

    def backoff(code, response, attempt)
      if (retry_after = response['Retry-After'])
        return retry_after.to_f
      end
      # exponential: 1, 2, 4, 8 ... seconds
      2**(attempt - 1)
    end
  end

end
