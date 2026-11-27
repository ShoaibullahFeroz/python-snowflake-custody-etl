-- Snowflake corporate-actions setup for the custodian warehouse.
-- Run in Snowsight or with snowsql after snowflake_setup.sql.
-- The Python loader (etl.py corporate_actions) uses the same tables
-- and MERGE. Corporate actions drive income: dividends and coupons
-- are paid to holders of record, so the INCOME_DUE view joins each
-- action to the latest booked position on or before record date.

USE WAREHOUSE CUSTODY_WH;
USE DATABASE CUSTODY_DB;
USE SCHEMA CUSTODY;

-- Raw landing table. The ETL truncates and reloads this on every run,
-- so it always holds exactly the last file that was loaded.
CREATE OR REPLACE TABLE CORPORATE_ACTIONS_STAGING (
    action_id        VARCHAR(20)  NOT NULL,
    cusip            VARCHAR(9)   NOT NULL,
    action_type      VARCHAR(10)  NOT NULL,
    ex_date          DATE         NOT NULL,
    record_date      DATE         NOT NULL,
    pay_date         DATE         NOT NULL,
    amount_per_share NUMBER(18,6) NOT NULL,
    currency         VARCHAR(3)   NOT NULL DEFAULT 'USD'
);

-- Target table. action_id is the natural key: re-running the same
-- file updates existing rows instead of duplicating them.
-- action_type is DIVIDEND, COUPON, or SPLIT. amount_per_share is the
-- cash paid per share for DIVIDEND / COUPON, and the split ratio
-- (new shares per old share, e.g. 2.00 for a 2-for-1 split) for SPLIT.
CREATE TABLE IF NOT EXISTS CORPORATE_ACTIONS (
    action_id        VARCHAR(20)  NOT NULL,
    cusip            VARCHAR(9)   NOT NULL,
    action_type      VARCHAR(10)  NOT NULL,
    ex_date          DATE         NOT NULL,
    record_date      DATE         NOT NULL,
    pay_date         DATE         NOT NULL,
    amount_per_share NUMBER(18,6) NOT NULL,
    currency         VARCHAR(3)   NOT NULL DEFAULT 'USD',
    loaded_at        TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT pk_corporate_actions PRIMARY KEY (action_id)
);

-- The same MERGE the Python loader runs for corporate actions.
-- Useful to re-run by hand if a load was staged but not merged.
MERGE INTO CORPORATE_ACTIONS t USING CORPORATE_ACTIONS_STAGING s
    ON t.action_id = s.action_id
WHEN MATCHED THEN UPDATE SET
    t.cusip = s.cusip,
    t.action_type = s.action_type,
    t.ex_date = s.ex_date,
    t.record_date = s.record_date,
    t.pay_date = s.pay_date,
    t.amount_per_share = s.amount_per_share,
    t.currency = s.currency,
    t.loaded_at = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT
    (action_id, cusip, action_type, ex_date, record_date,
     pay_date, amount_per_share, currency)
VALUES
    (s.action_id, s.cusip, s.action_type, s.ex_date, s.record_date,
     s.pay_date, s.amount_per_share, s.currency);

-- Income due: cash each account is owed for every dividend / coupon,
-- from the latest booked position on or before the record date.
-- SPLIT actions pay no cash, so they are excluded here.
CREATE OR REPLACE VIEW INCOME_DUE AS
SELECT
    p.account_id,
    a.action_id,
    a.cusip,
    a.action_type,
    a.record_date,
    a.pay_date,
    p.quantity AS shares_held,
    a.amount_per_share,
    p.quantity * a.amount_per_share AS income_due,
    a.currency
FROM CORPORATE_ACTIONS a
JOIN POSITIONS p
    ON p.cusip = a.cusip
    AND p.as_of_date <= a.record_date
    AND a.action_type IN ('DIVIDEND', 'COUPON')
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY p.account_id, p.cusip, a.action_id
    ORDER BY p.as_of_date DESC
) = 1;
