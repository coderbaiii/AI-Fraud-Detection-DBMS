-- ============================================================
-- File: 02_sample_data.sql  (Person 1 - Database Lead)
-- Run AFTER 01_schema.sql. Run it BEFORE Person 2's trigger is created,
-- otherwise the trigger will fire on every sample row.
-- Creates 20 customers, 20 accounts, 200 normal transactions
-- and 10 obvious fraud transactions (is_fraud = 'Y').
-- ============================================================

DECLARE
  v_cities     sys.odcivarchar2list := sys.odcivarchar2list(
                 'Kolkata','Mumbai','Delhi','Bengaluru','Chennai','Hyderabad','Pune');
  v_merchants  sys.odcivarchar2list := sys.odcivarchar2list(
                 'Amazon','Flipkart','Swiggy','Zomato','BigBasket','IRCTC',
                 'Reliance Retail','Uber','Apollo Pharmacy','Cafe Coffee Day');
  v_channels   sys.odcivarchar2list := sys.odcivarchar2list('POS','ONLINE','ATM','UPI');
  v_foreign    sys.odcivarchar2list := sys.odcivarchar2list(
                 'Lagos','Moscow','Dubai','Singapore','Bucharest','Manila');
  v_cust   NUMBER;
  v_acc    NUMBER;
  v_city   VARCHAR2(50);
  v_base   NUMBER;   -- each customer's typical spend
BEGIN
  FOR i IN 1..20 LOOP
    v_city := v_cities(TRUNC(DBMS_RANDOM.VALUE(1, v_cities.COUNT + 1)));

    INSERT INTO customers (full_name, email, city)
    VALUES ('Customer ' || i, 'customer' || i || '@example.com', v_city)
    RETURNING customer_id INTO v_cust;

    INSERT INTO accounts (customer_id, account_type, balance)
    VALUES (v_cust,
            CASE WHEN MOD(i, 3) = 0 THEN 'CURRENT' ELSE 'SAVINGS' END,
            ROUND(DBMS_RANDOM.VALUE(20000, 500000), 2))
    RETURNING account_id INTO v_acc;

    v_base := ROUND(DBMS_RANDOM.VALUE(500, 3000));

    -- 10 normal transactions: usual amount range, home city, last 90 days
    FOR j IN 1..10 LOOP
      INSERT INTO transactions
        (account_id, amount, txn_time, merchant, location, channel, is_fraud)
      VALUES
        (v_acc,
         ROUND(v_base * DBMS_RANDOM.VALUE(0.3, 1.8), 2),
         CAST(SYSDATE - DBMS_RANDOM.VALUE(1, 90) AS TIMESTAMP),
         v_merchants(TRUNC(DBMS_RANDOM.VALUE(1, v_merchants.COUNT + 1))),
         v_city,
         v_channels(TRUNC(DBMS_RANDOM.VALUE(1, v_channels.COUNT + 1))),
         'N');
    END LOOP;

    -- 1 obvious fraud for the first 10 customers: huge amount, foreign city, 1-4 AM, online
    IF i <= 10 THEN
      INSERT INTO transactions
        (account_id, amount, txn_time, merchant, location, channel, is_fraud)
      VALUES
        (v_acc,
         ROUND(v_base * DBMS_RANDOM.VALUE(25, 60), 2),
         CAST(TRUNC(SYSDATE - TRUNC(DBMS_RANDOM.VALUE(1, 30)))
              + DBMS_RANDOM.VALUE(1, 4) / 24 AS TIMESTAMP),
         v_merchants(TRUNC(DBMS_RANDOM.VALUE(1, v_merchants.COUNT + 1))),
         v_foreign(TRUNC(DBMS_RANDOM.VALUE(1, v_foreign.COUNT + 1))),
         'ONLINE',
         'Y');
    END IF;
  END LOOP;
  COMMIT;
END;
/

-- ---------- Checks (run these and compare) ----------
-- Expect: 20 customers, 20 accounts, 210 transactions, 10 frauds
SELECT (SELECT COUNT(*) FROM customers)                          AS customers,
       (SELECT COUNT(*) FROM accounts)                           AS accounts,
       (SELECT COUNT(*) FROM transactions)                       AS transactions,
       (SELECT COUNT(*) FROM transactions WHERE is_fraud = 'Y')  AS frauds
FROM dual;

-- Frauds should stand out: much bigger amounts, foreign locations
SELECT is_fraud, COUNT(*) AS n, ROUND(AVG(amount), 2) AS avg_amount, MAX(amount) AS max_amount
FROM transactions
GROUP BY is_fraud;
