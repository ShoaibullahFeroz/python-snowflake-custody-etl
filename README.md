# Python Snowflake Custody ETL

Loads daily trades, positions, close prices, and corporate actions
into a Snowflake custodian data warehouse: staging with PUT/COPY,
then MERGE upserts into the target tables, plus a reconciliation view
that flags breaks between traded and booked positions.

## What it loads

- **Trades** — trade_id, account, CUSIP, side (BUY/SELL), quantity,
  price, trade date, settlement date, settlement cycle (T+1 / T+2).
  Natural key is `trade_id`: re-running a file updates rows instead
  of duplicating them.
- **Positions** — account, CUSIP, quantity, cost basis, as-of date.
  Natural key is account + CUSIP + as-of date.
- **Prices** — CUSIP, price date, close price. Natural key is
  CUSIP + price date. Used to value holdings for the NAV run; the
  `PRICE_MOVES` view in `prices_setup.sql` shows the daily change
  per CUSIP.
- **Corporate actions** — action_id, CUSIP, type (DIVIDEND, COUPON,
  SPLIT), ex date, record date, pay date, amount per share, currency.
  Natural key is `action_id`. For DIVIDEND / COUPON the amount is
  the cash paid per share; for SPLIT it is the split ratio (new
  shares per old share, e.g. 2.00 for a 2-for-1 split). The
  `INCOME_DUE` view in `corporate_actions_setup.sql` works out the
  cash each account is owed from its latest position on or before
  the record date.

## Setup

```bash
pip install -r requirements.txt
cp .env.example .env
# fill in SNOWFLAKE_ACCOUNT, SNOWFLAKE_USER, SNOWFLAKE_PASSWORD
export $(grep -v '^#' .env | xargs)
```

Run the warehouse setup once in Snowsight:

```sql
-- snowflake_setup.sql: warehouse, database, schema, staging and
-- target tables, MERGE statements, POSITION_RECONCILIATION view,
-- and UNSETTLED_TRADES view
-- prices_setup.sql: PRICES staging and target tables, MERGE, and
-- the PRICE_MOVES view (daily change per CUSIP)
-- corporate_actions_setup.sql: CORPORATE_ACTIONS staging and target
-- tables, MERGE, and the INCOME_DUE view (cash owed per account)
```

## Run

```bash
# Check a file without touching Snowflake
python3 etl.py trades sample_trades.csv --validate-only

# See exactly what would load
python3 etl.py trades sample_trades.csv --dry-run

# Load for real
python3 etl.py trades sample_trades.csv
python3 etl.py positions sample_positions.csv
python3 etl.py prices sample_prices.csv
python3 etl.py corporate_actions sample_corporate_actions.csv
```

## Validation

Every row is checked before loading: required columns, duplicate
trade_ids / positions / prices / action_ids, side must be BUY or
SELL, cycle must be T+1 or T+2, action type must be DIVIDEND, COUPON
or SPLIT, quantity positive, price not negative, dates in
YYYY-MM-DD format, settlement date on or after trade date, and for
corporate actions ex date on or before record date on or before pay
date. A bad row stops the run with an error — nothing is partially
loaded.

## Reconciliation

After a load, check `POSITION_RECONCILIATION` in Snowflake: it
compares each booked position against the quantity implied by
settled trades for that account and CUSIP. Any row with status
`BREAK` is a position break to investigate. `UNSETTLED_TRADES`
lists trades past their settlement date. `INCOME_DUE` shows the
dividend / coupon cash each account is owed, from its latest
position on or before each action's record date.
