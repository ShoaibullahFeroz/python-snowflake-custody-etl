-- Snowflake custodian warehouse setup.
-- Run in Snowsight or with snowsql after setting your role.
-- The Python loader (etl.py) uses the same tables and MERGE statements.

CREATE WAREHOUSE IF NOT EXISTS CUSTODY_WH
    WAREHOUSE_SIZE = 'XSMALL'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE;

CREATE DATABASE IF NOT EXISTS CUSTODY_DB;

CREATE SCHEMA IF NOT EXISTS CUSTODY_DB.CUSTODY;

USE WAREHOUSE CUSTODY_WH;
USE DATABASE CUSTODY_DB;
USE SCHEMA CUSTODY;

-- Reference data: securities held in custody, keyed by CUSIP.
CREATE TABLE IF NOT EXISTS SECURITIES (
    cusip        VARCHAR(9)   NOT NULL,
    isin         VARCHAR(12),
    ticker       VARCHAR(20)  NOT NULL,
    security_name VARCHAR(200) NOT NULL,
    asset_class  VARCHAR(40)  NOT NULL,
    currency     VARCHAR(3)   NOT NULL DEFAULT 'USD',
    CONSTRAINT pk_securities PRIMARY KEY (cusip)
);

-- Raw landing tables. The ETL truncates and reloads these on every run,
-- so each holds exactly the last file that was loaded.
CREATE OR REPLACE TABLE TRADES_STAGING (
    trade_id         VARCHAR(20)  NOT NULL,
    account_id       VARCHAR(20)  NOT NULL,
    cusip            VARCHAR(9)   NOT NULL,
    side             VARCHAR(4)   NOT NULL,
    quantity         NUMBER(18,6) NOT NULL,
    price            NUMBER(18,6) NOT NULL,
    trade_date       DATE         NOT NULL,
    settlement_date  DATE         NOT NULL,
    settlement_cycle VARCHAR(5)   NOT NULL
);

CREATE OR REPLACE TABLE POSITIONS_STAGING (
    account_id VARCHAR(20)  NOT NULL,
    cusip      VARCHAR(9)   NOT NULL,
    quantity   NUMBER(18,6) NOT NULL,
    cost_basis NUMBER(18,2) NOT NULL,
    as_of_date DATE         NOT NULL
);

-- Target tables. trade_id is the natural key for trades; re-running the
-- same file updates existing rows instead of duplicating them.
CREATE TABLE IF NOT EXISTS TRADES (
    trade_id         VARCHAR(20)  NOT NULL,
    account_id       VARCHAR(20)  NOT NULL,
    cusip            VARCHAR(9)   NOT NULL,
    side             VARCHAR(4)   NOT NULL,
    quantity         NUMBER(18,6) NOT NULL,
    price            NUMBER(18,6) NOT NULL,
    trade_date       DATE         NOT NULL,
    settlement_date  DATE         NOT NULL,
    settlement_cycle VARCHAR(5)   NOT NULL,
    loaded_at        TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT pk_trades PRIMARY KEY (trade_id)
);

CREATE TABLE IF NOT EXISTS POSITIONS (
    account_id VARCHAR(20)  NOT NULL,
    cusip      VARCHAR(9)   NOT NULL,
    quantity   NUMBER(18,6) NOT NULL,
    cost_basis NUMBER(18,2) NOT NULL,
    as_of_date DATE         NOT NULL,
    loaded_at  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT pk_positions PRIMARY KEY (account_id, cusip, as_of_date)
);

-- The same MERGE the Python loader runs for trades. Useful to re-run
-- by hand if a load was staged but not merged.
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
     s.price, s.trade_date, s.settlement_date, s.settlement_cycle);

-- The same MERGE the Python loader runs for positions.
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
    (s.account_id, s.cusip, s.quantity, s.cost_basis, s.as_of_date);

-- Reconciliation: positions implied by trades vs positions actually booked.
-- Every trade settles into a position change, so a booked position that
-- does not match the traded quantity is a break to investigate.
CREATE OR REPLACE VIEW POSITION_RECONCILIATION AS
SELECT
    p.account_id,
    p.cusip,
    p.quantity AS booked_quantity,
    COALESCE(SUM(
        CASE WHEN t.side = 'BUY' THEN t.quantity
             WHEN t.side = 'SELL' THEN -t.quantity
             ELSE 0 END
    ), 0) AS traded_quantity,
    p.quantity - COALESCE(SUM(
        CASE WHEN t.side = 'BUY' THEN t.quantity
             WHEN t.side = 'SELL' THEN -t.quantity
             ELSE 0 END
    ), 0) AS difference,
    CASE
        WHEN p.quantity - COALESCE(SUM(
            CASE WHEN t.side = 'BUY' THEN t.quantity
                 WHEN t.side = 'SELL' THEN -t.quantity
                 ELSE 0 END
        ), 0) = 0 THEN 'MATCHED'
        ELSE 'BREAK'
    END AS status
FROM POSITIONS p
LEFT JOIN TRADES t
    ON t.account_id = p.account_id
    AND t.cusip = p.cusip
    AND t.settlement_date <= p.as_of_date
GROUP BY p.account_id, p.cusip, p.quantity;

-- Unsettled trades: executed trades past settlement date with no
-- settlement record yet — the daily fails report.
CREATE OR REPLACE VIEW UNSETTLED_TRADES AS
SELECT
    trade_id, account_id, cusip, side, quantity, price,
    trade_date, settlement_date, settlement_cycle
FROM TRADES
WHERE settlement_date < CURRENT_DATE();
