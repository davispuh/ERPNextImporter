# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require 'date'

module ERPNext
  class Error < StandardError; end

  class Client
    def initialize(url:, api_key:, api_secret:)
      @url       = url.sub(%r{/$}, '')
      @api_key   = api_key
      @api_secret = api_secret
    end

    def get(resource, params: {})
      uri = resource_uri(resource)
      uri.query = URI.encode_www_form(params) unless params.empty?
      resp = request(Net::HTTP::Get.new(uri))
      JSON.parse(resp)['data']
    end

    def post(resource, body = {})
      uri = resource_uri(resource)
      req = Net::HTTP::Post.new(uri)
      req['Content-Type'] = 'application/json'
      req.body = JSON.generate(body)
      JSON.parse(request(req))['data']
    end

    def put(resource, body = {})
      uri = resource_uri(resource)
      req = Net::HTTP::Put.new(uri)
      req['Content-Type'] = 'application/json'
      req.body = JSON.generate(body)
      JSON.parse(request(req))['data']
    end

    def submit(name, doctype = 'Bank Transaction')
      put("#{doctype}/#{name}", { docstatus: 1 })
    end

    def bank_transactions(bank_account, from = nil)
      filters = [['bank_account', '=', bank_account]]
      filters << ['date', '>=', from.to_s] if from
      fields = %w[name docstatus status date deposit withdrawal currency description reference_number transaction_id transaction_type party_type party bank_party_name bank_party_account_number bank_party_iban included_fee]
      get('Bank Transaction', params: {
        filters: JSON.generate(filters),
        fields: JSON.generate(fields),
        limit_page_length: 0
      })
    end

    def last_transaction_date(bank_account)
      rows = get('Bank Transaction', params: {
               filters: JSON.generate([['bank_account', '=', bank_account]]),
               fields: JSON.generate(%w[date]),
               order_by: 'date desc',
               limit_page_length: 1
      })
      rows&.first&.fetch('date', nil)
    end

    def bank_transaction_date_range(bank_account, days_back, from_override = nil, to_override = nil)
      today = Time.now.utc.to_date
      from = from_override && Date.parse(from_override)
      to   = to_override && Date.parse(to_override)
      if from.nil?
        last_date = last_transaction_date(bank_account)
        from = if last_date
          Date.parse(last_date)
        else
          today - days_back
        end
      end
      to = today if to.nil?
      to = today if to > today
      from = to if from > to
      [from, to]
    end

    def bank_account_exists?(name)
      get('Bank Account', params: {
        filters: JSON.generate([['name', '=', name]]),
        fields: JSON.generate(['name']),
        limit_page_length: 1
      }).any?
    end

    def save_bank_transaction(bank_transaction, submit = false)
      bank_transaction[:docstatus] = 1 if submit
      post('Bank Transaction', bank_transaction)
    end

    def save_bank_transaction_comment(name, content)
      content = content.join("\n") if content.is_a?(Array)
      return if content.strip.empty?
      erp_comments = comments(name, 'Bank Transaction')
      return if erp_comments.any? { |erp_comment| erp_comment['content'].to_s.include?(content) }
      add_comment(name, "<pre>#{content}</pre>", 'Bank Transaction')
    end

    def add_comment(reference_name, content, doctype)
      post('Comment', {
        comment_type: 'Comment',
        reference_doctype: doctype,
        reference_name: reference_name,
        content: content
      })
    end

    def comments(reference_name, doctype)
      get('Comment', params: {
        filters: JSON.generate([['reference_doctype', '=', doctype], ['reference_name', '=', reference_name], ['comment_type', '!=', 'Deleted']]),
        fields: JSON.generate(%w[comment_type subject name content]),
        limit_page_length: 0
      })
    end

    private

    def resource_uri(resource)
      path = resource.split('/').map { |seg| URI.encode_uri_component(seg) }.join('/')
      URI("#{@url}/api/resource/#{path}")
    end

    def request(req)
      uri = req.uri
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = 60
      http.read_timeout = 120
      req['Authorization'] = "Token #{@api_key}:#{@api_secret}"
      resp = http.request(req)
      code = resp.code.to_i
      unless code >= 200 && code < 300
        raise Error, "ERPNext error #{code} on #{uri.path}: #{resp.body.to_s[0, 500]}"
      end
      resp.body
    end
  end

end
