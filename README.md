# Tools for data import into ERPNext

Currently 4 scripts are implemented:

* `CAMT.053_to_ERPNext.rb` (for ISO 20022 `CAMT.053` XML, used by most European banks like Wise etc.)
* `PayPal_to_ERPNext.rb` (for PayPal Balance CSV or Activity TSV)
* `Wise_to_ERPNext.rb` (for Wise Statements CSV)
* `Auto_Wise_to_ERPNext.rb` (automatic Wise statement import)

Scripts will convert provided statements to CSV format expected by **ERPNext's Bank Statement Import**.

## Table of Contents

- [Installation](#Installation)
- [CAMT.053_to_ERPNext.rb](#CAMT.053_to_ERPNext.rb)
- [PayPal\_to\_ERPNext.rb](#PayPal_to_ERPNext.rb)
- [Wise\_to\_ERPNext.rb](#Wise_to_ERPNext.rb)
- [Auto_Wise\_to\_ERPNext.rb](#Auto_Wise_to_ERPNext.rb)
- [mappings.yaml](#mappings.yaml)
- [ERPNext Import](#ERPNext-Import)

## Installation

1. Install Ruby
2. Install `tzinfo`
```bash
gem install tzinfo
```
or you can use Bundler
```
bundle
```

## CAMT.053_to_ERPNext.rb

Parses ISO 20022 `camt.053.001` XML bank statements (e.g. exports from Wise and most European banks) and writes an ERPNext-compatible CSV.

For Wise, login and click on "Transactions" in left side, then on "Statements and reports" in right top side. Next click on "Statements" => "Create a statement".

Choose "XML (CAMT.053.001.10)" as "File format" and you can check "Display transactions with fees shown separately".

You can also use other CAMT formats like (CAMT.053.001.08 etc) - script supports all of them and you shouldn't see any difference in result output since Wise doesn't include much information.

### Usage

```bash
ruby CAMT.053_to_ERPNext.rb <input.xml> [output.csv]
```

If `output.csv` is omitted the result is written next to the input file with an `_erpnext.csv` suffix.

### Examples

```bash
# Output written to statement_erpnext.csv
ruby CAMT.053_to_ERPNext.rb statement.xml

# Explicit output path
ruby CAMT.053_to_ERPNext.rb 2026.xml 2026.csv
```

## PayPal_to_ERPNext.rb

Converts PayPal statement exports to ERPNext CSV.

Automatically detects which of the two PayPal export formats has been passed.

You can pass either `Balance statement` (CSV) or `Activity statement` (TSV)

Login PayPal, then in left side click on "Activity" and "All reports".

Then on "Payments" => "Statements - monthly and custom" => "Create Report" and select "CSV" File format for `Balance statement`.

For `Activity statement` go to "Activities" => "Activity report", select "Transaction type": "All transactions", Format: "TAB" and finally click on "Create Report".

### Usage

**Single file** — format is detected automatically:

```bash
ruby PayPal_to_ERPNext.rb <input.csv> [output.csv] [--account 'My PayPal']
```

**Merge mode** — combines both exports into one richer output:

```bash
ruby PayPal_to_ERPNext.rb --merge <activity.csv> <balance.csv> [output.csv] [--account 'My PayPal']
```

If `output.csv` is omitted the result is written next to the input file with an `_erpnext.csv` suffix.

### Options

| Option | Default | Description |
|---|---|---|
| `--account 'Name'` | `My PayPal` | Value written to the **Bank Account** column in every row |
| `--merge` | off | Merge mode (see below) |

### Examples

```bash
# Balance statement, default account name
ruby PayPal_to_ERPNext.rb YU-CSR-20260101000000-20261231235959-20260407120410.CSV

# Activity statement with a named account
ruby PayPal_to_ERPNext.rb Download.TXT out.csv --account 'PayPal EUR'

# Merge both exports into a single output
ruby PayPal_to_ERPNext.rb --merge Activity.csv Download.CSV merged.csv --account 'PayPal EUR'
```

### Merge mode

When `--merge` is passed the script expects the **activity file first**, then the **balance file**. The merge strategy is:

- All transaction data (amounts, description, status, type, custom fields) comes from the **activity** export.
- `Party Name` and `Party Account No.` are overwritten with values from the **balance** export when a matching Transaction ID is found there — because the balance export carries richer counterparty info (real names, bank names) compared to the email addresses in the activity export.


## Wise_to_ERPNext.rb

Wise has more information in CSV Statements than in XML CAMT. So you can use this script instead of XML.
But for ERPNext there shouldn't be any difference which one you use.

Only note that Wise CSV/XLSX Statements have a bug that it will use wrong timezone offset for all entries based on export time.
This means that due to Daylight Savings time (DST) there might be incorrect times.

Use `--timezone` to set timezone that Wise used for export to undo their wrong timezone offset.

### Usage

```bash
ruby Wise_to_ERPNext.rb <input.csv> [output.csv] [--account "My Wise"] [--timezone "auto"]
```

If `output.csv` is omitted the result is written next to the input file with an `_erpnext.csv` suffix.

### Examples

```bash
# Output written to statement_erpnext.csv
ruby Wise_to_ERPNext.rb --timezone '+02:00' statement.xml

# Explicit output path
ruby Wise_to_ERPNext.rb 2026.xml 2026.csv
```


## Auto_Wise_to_ERPNext.rb

Automatically imports Wise balance statements into ERPNext.

### Setup

1. Create an API key in ERPNext (Edit Profile => Settings => API Access).
2. Fill in non-secret settings in `config.yaml` and set
   secrets via environment variables:
3. Login Wise with your account

```bash
export ERPNEXT_API_KEY=...
export ERPNEXT_API_SECRET=...
```

### Usage

```bash
ruby Auto_Wise_to_ERPNext.rb [options]
```

### Options

| Option | Default | Description |
|---|---|---|
| `--config PATH` | `config.yaml` | Path to configuration file |
| `--from YYYY-MM-DD` | auto | Start date |
| `--to YYYY-MM-DD` | today | End date |
| `--type FLAT\|COMPACT` | FLAT | Statement type |
| `--days-back N` | 180 | Look back this many days when nothing imported yet |
| `--year` | off | Save last year statements of all balances to files instead of importing |
| `--quarter` | off | Save last quarter statements of all balances to files instead of importing |
| `--month` | off | Save last month statements of all balances to files instead of importing |
| `--import` | off | Create Bank Transactions in ERPNext |
| `--submit` | off | Also submit the created/imported Bank Transactions |
| `--help` | off | Show help |

## mappings.yaml

Scripts look for a `mappings.yaml` file in the **current working directory**.

If found, any matching party name or account value is replaced before writing to the CSV - useful for normalising counterparty names to the exact strings used in ERPNext.

```yaml
# mappings.yaml
"GOOGLE IRELAND LIMITED": "Google"
"paypal@fiverr.com": "Fiverr"
```

The file is optional. If it does not exist the scripts run normally without any substitutions.

## ERPNext Import

To import bank statements in ERPNext go to Accounting => Banking => "Bank Reconciliation" and click on "Upload Bank Statement" in top right.
