-- Snowflake close-prices setup for the custodian warehouse.
-- Run in Snowsight or with snowsql after snowflake_setup.sql.
-- The Python loader (etl.py prices) uses the same tables and MERGE.

USE WAREHOUSE CUSTODY_WH;
USE DATABASE CUSTODY_DB;
USE SCHEMA CUSTODY;

-- Raw landing table. The ETL truncates and reloads this on every run,
-- so it always holds exactly the last file that was loaded.
CREATE OR REPLACE TABLE PRICES_STAGING (
    cusip       VARCHAR(9)   NOT NULL,
    price_date  DATE         NOT NULL,
    close_price NUMBER(18,6) NOT NULL
);

-- Target table. cusip + price_date is the natural key: re-running the
-- same file updates existing rows instead of duplicating them.
CREATE TABLE IF NOT EXISTS PRICES (
    cusip       VARCHAR(9)   NOT NULL,
    price_date  DATE         NOT NULL,
    close_price NUMBER(18,6) NOT NULL,
    loaded_at   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT pk_prices PRIMARY KEY (cusip, price_date)
);

-- The same MERGE the Python loader runs for prices. Useful to re-run
-- by hand if a load was staged but not merged.
MERGE INTO PRICES t USING PRICES_STAGING s
    ON t.cusip = s.cusip
    AND t.price_date = s.price_date
WHEN MATCHED THEN UPDATE SET
    t.close_price = s.close_price,
    t.loaded_at = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT
    (cusip, price_date, close_price)
VALUES
    (s.cusip, s.price_date, s.close_price);

-- Daily price change per CUSIP: today's close vs the previous close,
-- with the absolute and percentage move. Used to value holdings and
-- to spot stale or missing prices before the NAV run.
CREATE OR REPLACE VIEW PRICE_MOVES AS
SELECT
    cusip,
    price_date,
    close_price,
    LAG(close_price) OVER (PARTITION BY cusip ORDER BY price_date) AS prev_close,
    close_price - LAG(close_price) OVER (PARTITION BY cusip ORDER BY price_date) AS price_change,
    CASE
        WHEN LAG(close_price) OVER (PARTITION BY cusip ORDER BY price_date) IS NULL
            OR LAG(close_price) OVER (PARTITION BY cusip ORDER BY price_date) = 0
        THEN NULL
        ELSE (close_price - LAG(close_price) OVER (PARTITION BY cusip ORDER BY price_date))
            / LAG(close_price) OVER (PARTITION BY cusip ORDER BY price_date) * 100
    END AS pct_change
FROM PRICES;
