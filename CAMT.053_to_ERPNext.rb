#!/usr/bin/env ruby
# frozen_string_literal: true

# CAMT.053_to_ERPNext.rb
#
# Converts a CAMT ISO 20022 camt.053 bank statement XML file to a CSV file
# compatible with ERPNext bank statement import.
#
# Usage:
#   ruby CAMT.053_to_ERPNext.rb <input.xml> [output.csv]
#
# If output path is omitted the CSV is written next to the input file
# with the same base name suffixed with `_erpnext.csv`.

require 'rexml/document'
require 'csv'
require 'date'
require 'yaml'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

EXPECTED_NS = 'urn:iso:std:iso:20022:tech:xsd:camt.053'

# Fetch the text of the first matching element (namespace-aware).
def txt(node, xpath)
  elements = REXML::XPath.match(node, xpath)
  return nil if elements.empty?
  text = ''
  elements.each do |el|
    text += el.is_a?(REXML::Attribute) ? el.value : el.text
  end
  text.strip
end

# Parse an ISO 8601 datetime string
def parse_date(str)
  return nil if str.to_s.strip.empty?
  Time.parse(str)
end

def remap(value, mappings)
  mappings[value] || value
end

# ---------------------------------------------------------------------------
# Main parser
# ---------------------------------------------------------------------------

def convert(input_path, output_path, mappings)
  xml_src = File.read(input_path, encoding: 'UTF-8')
  doc     = REXML::Document.new(xml_src)
  unless doc.root.namespace('xmlns').start_with?(EXPECTED_NS)
    warn "Warning: unexpected XML namespace: #{doc.root.namespace('xmlns')}"
  end

  rows = []
  # There can be multiple <Stmt> blocks in one file.
  REXML::XPath.each(doc, '//BkToCstmrStmt/Stmt') do |stmt|
    # --- Statement-level fields ---
    bank_name    = txt(stmt, 'Acct/Svcr/FinInstnId/Nm')
    bank_account = txt(stmt, 'Acct/Id/IBAN') || txt(stmt, 'Acct/Id/Othr/Id')
    currency     = txt(stmt, 'Acct/Ccy')
    company      = txt(stmt, 'Acct/Ownr/Nm')

    # --- Iterate over every entry (transaction) ---
    REXML::XPath.each(stmt, 'Ntry') do |ntry|
      # Basic entry fields
      amount    = txt(ntry, 'Amt').to_f
      ccy       = (txt(ntry, 'Amt/@Ccy') || currency).upcase
      crdt_dbt  = txt(ntry, 'CdtDbtInd')   # CRDT or DBIT
      book_date = parse_date(txt(ntry, 'BookgDt/Dt') ||
                             txt(ntry, 'BookgDt/DtTm'))
      val_date  = parse_date(txt(ntry, 'ValDt/Dt') ||
                             txt(ntry, 'ValDt/DtTm'))
      datetime  = book_date || val_date

      # Entry-level references
      acct_svcr_ref = txt(ntry, 'AcctSvcrRef')
      ntry_ref      = txt(ntry, 'NtryRef')

      # Transaction type / bank transaction code
      domn_cd    = txt(ntry, 'BkTxCd/Domn/Cd')
      fmly_cd    = txt(ntry, 'BkTxCd/Domn/Fmly/Cd')
      sub_fmly   = txt(ntry, 'BkTxCd/Domn/Fmly/SubFmlyCd')
      prtry_cd   = txt(ntry, 'BkTxCd/Prtry/Cd')
      issuer     = txt(ntry, 'BkTxCd/Prtry/Issr')
      tx_type    = [domn_cd, fmly_cd, sub_fmly, prtry_cd].compact.join('/')
      tx_type    = tx_type.gsub(/\-\d+$/, '')
      tx_type    = nil if tx_type.empty?

      # Transaction details — camt.053 nests details under NtryDtls/TxDtls
      tx = REXML::XPath.first(ntry, 'NtryDtls/TxDtls')
      if tx
        tx_id      = txt(tx, 'Refs/TxId')   ||
                     txt(tx, 'Refs/PmtInfId') ||
                     txt(tx, 'Refs/InstrId') ||
                     acct_svcr_ref ||
                     prtry_cd
        end_to_end = txt(tx, 'Refs/EndToEndId')
        mandate_id = txt(tx, 'Refs/MndtId')
        cheq_nb    = txt(tx, 'Refs/ChqNb')

        ref_number = end_to_end || mandate_id || cheq_nb || ntry_ref

        # Description / remittance info
        ustrd      = txt(tx, 'RmtInf/Ustrd')
        strd_ref   = txt(tx, 'RmtInf/Strd/CdtrRefInf/Ref')
        description = ustrd || strd_ref || txt(ntry, 'AddtlNtryInf')

        # Counterparty — creditor for debits, debtor for credits
        if crdt_dbt == 'DBIT'
          party_name    = txt(tx, 'RltdPties/Cdtr/Nm') || txt(tx, 'RltdPties/Cdtr/Pty/Nm')
          party_address = txt(tx, 'RltdPties/Cdtr/PstlAdr/StrtNm')
          party_zip     = txt(tx, 'RltdPties/Cdtr/PstlAdr/PstCd')
          party_city    = txt(tx, 'RltdPties/Cdtr/PstlAdr/TwnNm')
          party_country = txt(tx, 'RltdPties/Cdtr/PstlAdr/Ctry')
          party_country = txt(tx, 'RltdPties/Cdtr/CtryOfRes') unless party_country
          party_acct    = txt(tx, 'RltdPties/CdtrAcct/Id/Othr/Id')
          party_iban    = txt(tx, 'RltdPties/CdtrAcct/Id/IBAN')
          swift         = txt(tx, 'RltdAgts/CdtrAgt/FinInstnId/BIC')
        else
          party_name    = txt(tx, 'RltdPties/Dbtr/Nm') || txt(tx, 'RltdPties/Dbtr/Pty/Nm')
          party_address = txt(tx, 'RltdPties/Dbtr/PstlAdr/StrtNm')
          party_zip     = txt(tx, 'RltdPties/Dbtr/PstlAdr/PstCd')
          party_city    = txt(tx, 'RltdPties/Dbtr/PstlAdr/TwnNm')
          party_country = txt(tx, 'RltdPties/Dbtr/PstlAdr/Ctry')
          party_country = txt(tx, 'RltdPties/Dbtr/CtryOfRes') unless party_country
          party_acct    = txt(tx, 'RltdPties/DbtrAcct/Id/Othr/Id')
          party_iban    = txt(tx, 'RltdPties/DbtrAcct/Id/IBAN')
          swift         = txt(tx, 'RltdAgts/DbtrAgt/FinInstnId/BIC')
        end
      else
        # Fallback: pull what we can from the entry itself
        tx_id         = acct_svcr_ref || prtry_cd
        ref_number    = ntry_ref
        description   = txt(ntry, 'AddtlNtryInf')
        party_acct    = nil
        party_iban    = nil
        swift         = nil
        party_address = nil
        party_zip     = nil
        party_city    = nil
        party_country = nil
      end
      party_name = issuer if !party_name && tx_type.end_with?('/CHRG/KOM')
      party_name = bank_name if !party_name && tx_type.downcase.include?('fee-')
      # Wise specific
      party_name = 'Wise Assets Europe SA' if !party_name && tx_type.start_with?('ACCRUAL_CHECKOUT') && description.start_with?('Wise Assets Europe')
      if !party_name
        merchant_match = description.match(/^Card transaction of [\d\.,]+ [\w]+ issued by ([^\(]+)(\(|$)/)
        party_name = merchant_match[1].strip if merchant_match.is_a?(MatchData)
      end
      if !party_iban && party_acct && party_acct.gsub(' ', '').match?(/^[A-Z]{2}[0-9]{2}[0-9A-Z]{4}[0-9]{4,30}$/i)
        party_iban = party_acct
        party_acct = nil
      end

      from_currency = txt(ntry, 'AmtDtls/TxAmt/CcyXchg/SrcCcy')
      to_currency   = txt(ntry, 'AmtDtls/TxAmt/CcyXchg/TrgtCcy')
      exchange_rate = txt(ntry, 'AmtDtls/TxAmt/CcyXchg/XchgRate')

      included_fee = txt(ntry, 'Chrgs/TtlChrgsAndTaxAmt')

      # Can't include Excluded Fee
      # because then ERPNext will convert it to Included Fee and update amount, causing double entries for it
      # fee_match = description.match(/\(fee: (\d+\.\d+) /)
      # excluded_fee = fee_match.is_a?(MatchData) ? fee_match[1] : nil

      # Deposit vs withdrawal
      deposit    = crdt_dbt == 'CRDT' ? amount : nil
      withdrawal = crdt_dbt == 'DBIT' ? amount : nil

      id = acct_svcr_ref
      if id.nil?
        id = prtry_cd
        id += (crdt_dbt == 'DBIT' ? '-C-' : '-D-') + ccy + '-' + datetime.utc.to_i.to_s unless id.gsub('-', '').match?(/[0-9A-F]{32,}/i) # UUID should be fine
      end

      rows << {
        id:            id,
        datetime:      datetime,
        bank_account:  remap(bank_account, mappings),
        company:       remap(company, mappings),
        deposit:       deposit,
        withdrawal:    withdrawal,
        currency:      ccy,
        description:   description,
        ref_number:    ref_number,
        tx_id:         tx_id,
        tx_type:       tx_type,
        party_name:    remap(party_name, mappings),
        party_acct:    party_acct,
        party_iban:    party_iban,
        included_fee:  included_fee,
        swift:         swift,
        party_address: party_address,
        party_city:    party_city,
        party_country: party_country,
        party_zip:     party_zip,
        from_currency: from_currency,
        to_currency:   to_currency,
        exchange_rate: exchange_rate
      }
    end
  end

  # ---------------------------------------------------------------------------
  # Write CSV
  # ---------------------------------------------------------------------------
  CSV.open(output_path, 'w', force_quotes: false) do |csv|
    csv << [
      'ID',
      'Date',
      'Bank Account',
      'Company',
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
      'SWIFT number',
      'Address Line 1',
      'City/Town',
      'Country',
      'Postal Code',
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
        r[:company],
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
        r[:swift],
        r[:party_address],
        r[:party_city],
        r[:party_zip],
        r[:party_country],
        r[:from_currency],
        r[:to_currency],
        r[:exchange_rate]
      ]
    end
  end

  puts "✓ Converted #{rows.size} transaction(s) → #{output_path}"
end

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if ARGV.empty?
  warn "Usage: ruby #{$0} <input.xml> [output.csv]"
  exit 1
end

input  = ARGV[0]
output = ARGV[1] || File.join(
  File.dirname(input),
  "#{File.basename(input, File.extname(input))}_erpnext.csv"
)

unless File.exist?(input)
  warn "Error: file not found — #{input}"
  exit 1
end

mappings = {}
if File.exist?('mappings.yaml')
  mappings = Hash[YAML.load_file('mappings.yaml').map { |id, value| [id.to_s, value] }]
end

convert(input, output, mappings)
