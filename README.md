# Python Snowflake Custody ETL

Loads daily trades, positions, and close prices into a Snowflake
custodian data warehouse: staging with PUT/COPY, then MERGE upserts
into the target tables, plus a reconciliation view that flags breaks
between traded and booked positions.

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
```

## Validation

Every row is checked before loading: required columns, duplicate
trade_ids / positions / prices, side must be BUY or SELL, cycle must
be T+1 or T+2, quantity positive, price not negative, dates in
YYYY-MM-DD format, and settlement date on or after trade date. A bad
row stops the run with an error — nothing is partially loaded.

## Reconciliation

After a load, check `POSITION_RECONCILIATION` in Snowflake: it
compares each booked position against the quantity implied by
settled trades for that account and CUSIP. Any row with status
`BREAK` is a position break to investigate. `UNSETTLED_TRADES`
lists trades past their settlement date.
