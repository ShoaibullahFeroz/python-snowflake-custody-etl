#!/usr/bin/env python3
"""Load daily trades, positions, and close prices into a Snowflake custodian warehouse.

Usage:
    python3 etl.py trades sample_trades.csv
    python3 etl.py positions sample_positions.csv
    python3 etl.py prices sample_prices.csv
    python3 etl.py trades trades.csv --dry-run
    python3 etl.py positions positions.csv --validate-only

Credentials come only from environment variables:
    SNOWFLAKE_ACCOUNT, SNOWFLAKE_USER, SNOWFLAKE_PASSWORD,
    SNOWFLAKE_WAREHOUSE, SNOWFLAKE_DATABASE, SNOWFLAKE_SCHEMA
See .env.example. The loader stages the file with PUT/COPY, then
MERGEs it into the target table on the natural key (trade_id for
trades, account_id + cusip + as_of_date for positions,
cusip + price_date for prices).
"""

import argparse
import csv
import os
import sys
from datetime import date

TRADE_FIELDS = [
    "trade_id", "account_id", "cusip", "side", "quantity",
    "price", "trade_date", "settlement_date", "settlement_cycle",
]
POSITION_FIELDS = [
    "account_id", "cusip", "quantity", "cost_basis", "as_of_date",
]
PRICE_FIELDS = [
    "cusip", "price_date", "close_price",
]

VALID_SIDES = {"BUY", "SELL"}
VALID_CYCLES = {"T+1", "T+2"}


def fail(message):
    print(f"Error: {message}", file=sys.stderr)
    return 1


def parse_args():
    parser = argparse.ArgumentParser(
        description="Load trades or positions into the Snowflake custodian warehouse."
    )
    parser.add_argument("kind", choices=["trades", "positions", "prices"])
    parser.add_argument("csv_file")
    parser.add_argument("--dry-run", action="store_true",
                        help="Validate and print what would load, without touching Snowflake")
    parser.add_argument("--validate-only", action="store_true",
                        help="Validate the file and exit")
    return parser.parse_args()


def read_rows(path, expected_fields):
    if not os.path.exists(path):
        raise FileNotFoundError(f"File not found: {path}")
    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        if reader.fieldnames != expected_fields:
            raise ValueError(
                f"Expected columns {expected_fields}, got {reader.fieldnames}"
            )
        return list(reader)


def validate_date(value, field):
    try:
        date.fromisoformat(value)
    except ValueError:
        raise ValueError(f"{field} is not a valid YYYY-MM-DD date: {value}")


def validate_number(value, field):
    try:
        float(value)
    except (TypeError, ValueError):
        raise ValueError(f"{field} is not a number: {value}")


def validate_trades(rows):
    seen = set()
    for i, row in enumerate(rows, start=2):
        for field in TRADE_FIELDS:
            if row.get(field) in (None, ""):
                raise ValueError(f"Row {i}: missing {field}")
        if row["trade_id"] in seen:
            raise ValueError(f"Row {i}: duplicate trade_id {row['trade_id']}")
        seen.add(row["trade_id"])
        if row["side"] not in VALID_SIDES:
            raise ValueError(f"Row {i}: side must be BUY or SELL, got {row['side']}")
        if row["settlement_cycle"] not in VALID_CYCLES:
            raise ValueError(f"Row {i}: settlement_cycle must be T+1 or T+2, got {row['settlement_cycle']}")
        validate_number(row["quantity"], "quantity")
        validate_number(row["price"], "price")
        if float(row["quantity"]) <= 0:
            raise ValueError(f"Row {i}: quantity must be positive")
        if float(row["price"]) < 0:
            raise ValueError(f"Row {i}: price must not be negative")
        validate_date(row["trade_date"], "trade_date")
        validate_date(row["settlement_date"], "settlement_date")
        if row["settlement_date"] < row["trade_date"]:
            raise ValueError(f"Row {i}: settlement_date before trade_date")
    return rows


def validate_positions(rows):
    seen = set()
    for i, row in enumerate(rows, start=2):
        for field in POSITION_FIELDS:
            if row.get(field) in (None, ""):
                raise ValueError(f"Row {i}: missing {field}")
        key = (row["account_id"], row["cusip"], row["as_of_date"])
        if key in seen:
            raise ValueError(f"Row {i}: duplicate position {key}")
        seen.add(key)
        validate_number(row["quantity"], "quantity")
        validate_number(row["cost_basis"], "cost_basis")
        validate_date(row["as_of_date"], "as_of_date")
    return rows


def validate_prices(rows):
    seen = set()
    for i, row in enumerate(rows, start=2):
        for field in PRICE_FIELDS:
            if row.get(field) in (None, ""):
                raise ValueError(f"Row {i}: missing {field}")
        key = (row["cusip"], row["price_date"])
        if key in seen:
            raise ValueError(f"Row {i}: duplicate price {key}")
        seen.add(key)
        validate_number(row["close_price"], "close_price")
        if float(row["close_price"]) < 0:
            raise ValueError(f"Row {i}: close_price must not be negative")
        validate_date(row["price_date"], "price_date")
    return rows


def connect():
    try:
        import snowflake.connector
    except ImportError:
        print("Error: snowflake-connector-python is not installed. "
              "Run: pip install -r requirements.txt", file=sys.stderr)
        sys.exit(1)
    required = ["SNOWFLAKE_ACCOUNT", "SNOWFLAKE_USER", "SNOWFLAKE_PASSWORD",
                "SNOWFLAKE_WAREHOUSE", "SNOWFLAKE_DATABASE", "SNOWFLAKE_SCHEMA"]
    missing = [name for name in required if not os.environ.get(name)]
    if missing:
        print(f"Error: missing environment variables: {', '.join(missing)}",
              file=sys.stderr)
        sys.exit(1)
    return snowflake.connector.connect(
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        user=os.environ["SNOWFLAKE_USER"],
        password=os.environ["SNOWFLAKE_PASSWORD"],
        warehouse=os.environ["SNOWFLAKE_WAREHOUSE"],
        database=os.environ["SNOWFLAKE_DATABASE"],
        schema=os.environ["SNOWFLAKE_SCHEMA"],
    )


def load(conn, kind, csv_file, rows):
    staging = {
        "trades": "TRADES_STAGING",
        "positions": "POSITIONS_STAGING",
        "prices": "PRICES_STAGING",
    }[kind]
    target = kind.upper()
    cur = conn.cursor()
    try:
        cur.execute(f"TRUNCATE TABLE {staging}")
        cur.execute(f"PUT file://{os.path.abspath(csv_file)} @%{staging}")
        cur.execute(
            f"COPY INTO {staging} FILE_FORMAT = "
            "(TYPE = CSV SKIP_HEADER = 1 FIELD_OPTIONALLY_ENCLOSED_BY = '\"')"
        )
        if kind == "trades":
            cur.execute("""
                MERGE INTO TRADES t USING TRADES_STAGING s
                    ON t.trade_id = s.trade_id
                WHEN MATCHED THEN UPDATE SET
                    t.account_id = s.account_id, t.cusip = s.cusip,
                    t.side = s.side, t.quantity = s.quantity,
                    t.price = s.price, t.trade_date = s.trade_date,
                    t.settlement_date = s.settlement_date,
                    t.settlement_cycle = s.settlement_cycle,
                    t.loaded_at = CURRENT_TIMESTAMP()
                WHEN NOT MATCHED THEN INSERT
                    (trade_id, account_id, cusip, side, quantity, price,
                     trade_date, settlement_date, settlement_cycle)
                VALUES
                    (s.trade_id, s.account_id, s.cusip, s.side, s.quantity,
                     s.price, s.trade_date, s.settlement_date, s.settlement_cycle)
            """)
        elif kind == "positions":
            cur.execute("""
                MERGE INTO POSITIONS t USING POSITIONS_STAGING s
                    ON t.account_id = s.account_id
                    AND t.cusip = s.cusip
                    AND t.as_of_date = s.as_of_date
                WHEN MATCHED THEN UPDATE SET
                    t.quantity = s.quantity, t.cost_basis = s.cost_basis,
                    t.loaded_at = CURRENT_TIMESTAMP()
                WHEN NOT MATCHED THEN INSERT
                    (account_id, cusip, quantity, cost_basis, as_of_date)
                VALUES
                    (s.account_id, s.cusip, s.quantity, s.cost_basis, s.as_of_date)
            """)
        else:
            cur.execute("""
                MERGE INTO PRICES t USING PRICES_STAGING s
                    ON t.cusip = s.cusip
                    AND t.price_date = s.price_date
                WHEN MATCHED THEN UPDATE SET
                    t.close_price = s.close_price,
                    t.loaded_at = CURRENT_TIMESTAMP()
                WHEN NOT MATCHED THEN INSERT
                    (cusip, price_date, close_price)
                VALUES
                    (s.cusip, s.price_date, s.close_price)
            """)
        print(f"Loaded {len(rows)} {kind} rows into {target} "
              f"({cur.rowcount} rows merged).")
    finally:
        cur.close()


def main():
    args = parse_args()
    fields = {
        "trades": TRADE_FIELDS,
        "positions": POSITION_FIELDS,
        "prices": PRICE_FIELDS,
    }[args.kind]
    validate = {
        "trades": validate_trades,
        "positions": validate_positions,
        "prices": validate_prices,
    }[args.kind]
    try:
        rows = validate(read_rows(args.csv_file, fields))
    except (FileNotFoundError, ValueError) as exc:
        return fail(str(exc))
    print(f"Validated {len(rows)} {args.kind} rows from {args.csv_file}.")
    if args.validate_only:
        return 0
    if args.dry_run:
        for row in rows:
            print(row)
        print(f"Dry run: would load {len(rows)} rows, no Snowflake calls made.")
        return 0
    conn = connect()
    try:
        load(conn, args.kind, args.csv_file, rows)
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
