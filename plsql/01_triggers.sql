-- ============================================================
-- Project 11: AI-Based Fraudulent Transaction Detection Database
-- File: plsql/01_triggers.sql  (Person 2 - PL/SQL Lead)
-- Purpose: Automated Rule-Based & ML-Driven Fraud Detection Triggers
--          and Audit Logging.
-- Run AFTER sql/01_schema.sql (and sql/02_sample_data.sql).
-- ============================================================

-- ------------------------------------------------------------
-- 1. trg_txn_before_insert
-- Evaluates multi-heuristic rule checks before inserting a transaction.
-- If any high-risk anomaly is detected, sets is_flagged = 'Y'.
-- Heuristics checked:
--   a) Suspicious amount: >= 20,000 (normal spend in sample data is < 5,500)
--   b) Foreign / Unrecognized locations: Lagos, Moscow, Dubai, Bucharest, Manila, Singapore
--   c) Customer Home City mismatch
--   d) Off-hours transaction: between 01:00 AM and 04:59 AM
--   e) High ML anomaly score (if pre-populated during insert)
-- ------------------------------------------------------------
CREATE OR REPLACE TRIGGER trg_txn_before_insert
BEFORE INSERT ON transactions
FOR EACH ROW
DECLARE
  v_cust_city    customers.city%TYPE;
  v_is_foreign   BOOLEAN := FALSE;
  v_hour         NUMBER;
BEGIN
  -- Default to N if not explicitly passed
  IF :NEW.is_flagged IS NULL THEN
    :NEW.is_flagged := 'N';
  END IF;

  -- 1. Check known foreign / high-risk fraud locations
  IF UPPER(:NEW.location) IN ('LAGOS','MOSCOW','DUBAI','SINGAPORE','BUCHAREST','MANILA') THEN
    v_is_foreign := TRUE;
  END IF;

  -- 2. Lookup customer's registered home city
  BEGIN
    SELECT c.city
    INTO v_cust_city
    FROM accounts a
    JOIN customers c ON a.customer_id = c.customer_id
    WHERE a.account_id = :NEW.account_id;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      v_cust_city := NULL;
    WHEN OTHERS THEN
      v_cust_city := NULL;
  END;

  -- 3. Extract transaction hour
  BEGIN
    v_hour := TO_NUMBER(TO_CHAR(:NEW.txn_time, 'HH24'));
  EXCEPTION
    WHEN OTHERS THEN
      v_hour := -1;
  END;

  -- Rule A: Excessive transaction amount (>= 20,000)
  IF :NEW.amount >= 20000 THEN
    :NEW.is_flagged := 'Y';
  END IF;

  -- Rule B: Foreign location transaction
  IF v_is_foreign THEN
    :NEW.is_flagged := 'Y';
  END IF;

  -- Rule C: Location mismatch during off-hours (1 AM - 5 AM)
  IF v_cust_city IS NOT NULL 
     AND UPPER(:NEW.location) <> UPPER(v_cust_city)
     AND v_hour BETWEEN 1 AND 4 THEN
    :NEW.is_flagged := 'Y';
  END IF;

  -- Rule D: ML score threshold exceeded on insert
  IF :NEW.anomaly_score IS NOT NULL AND :NEW.anomaly_score >= 0.70 THEN
    :NEW.is_flagged := 'Y';
  END IF;
END trg_txn_before_insert;
/

-- ------------------------------------------------------------
-- 2. trg_txn_after_insert
-- Whenever a transaction is flagged (is_flagged = 'Y'), automatically
-- open a fraud alert in FRAUD_ALERTS with detailed reason rationale.
-- ------------------------------------------------------------
CREATE OR REPLACE TRIGGER trg_txn_after_insert
AFTER INSERT ON transactions
FOR EACH ROW
DECLARE
  v_reason       VARCHAR2(200);
  v_cust_city    customers.city%TYPE;
  v_hour         NUMBER;
BEGIN
  IF :NEW.is_flagged = 'Y' THEN
    -- Retrieve customer city
    BEGIN
      SELECT c.city
      INTO v_cust_city
      FROM accounts a
      JOIN customers c ON a.customer_id = c.customer_id
      WHERE a.account_id = :NEW.account_id;
    EXCEPTION
      WHEN OTHERS THEN
        v_cust_city := 'UNKNOWN';
    END;

    -- Extract hour
    BEGIN
      v_hour := TO_NUMBER(TO_CHAR(:NEW.txn_time, 'HH24'));
    EXCEPTION
      WHEN OTHERS THEN
        v_hour := -1;
    END;

    -- Build explanatory alert reason
    IF :NEW.amount >= 20000 AND UPPER(:NEW.location) IN ('LAGOS','MOSCOW','DUBAI','SINGAPORE','BUCHAREST','MANILA') THEN
      v_reason := 'CRITICAL: High amount (Rs. ' || TO_CHAR(:NEW.amount, 'FM999,990.00') || ') at foreign location (' || :NEW.location || ')';
    ELSIF :NEW.amount >= 20000 THEN
      v_reason := 'HIGH AMOUNT: Transaction value (Rs. ' || TO_CHAR(:NEW.amount, 'FM999,990.00') || ') exceeds threshold';
    ELSIF UPPER(:NEW.location) IN ('LAGOS','MOSCOW','DUBAI','SINGAPORE','BUCHAREST','MANILA') THEN
      v_reason := 'GEOGRAPHIC ANOMALY: Transaction originating from high-risk location (' || :NEW.location || ')';
    ELSIF v_cust_city IS NOT NULL AND UPPER(:NEW.location) <> UPPER(v_cust_city) AND v_hour BETWEEN 1 AND 4 THEN
      v_reason := 'SUSPICIOUS ACTIVITY: Out-of-city txn at ' || TO_CHAR(v_hour) || ' hrs (Home: ' || v_cust_city || ', Txn: ' || :NEW.location || ')';
    ELSIF :NEW.anomaly_score IS NOT NULL AND :NEW.anomaly_score >= 0.70 THEN
      v_reason := 'AI/ML ANOMALY: Score ' || TO_CHAR(:NEW.anomaly_score, '0.9999') || ' exceeds critical threshold (0.70)';
    ELSE
      v_reason := 'SUSPICIOUS PATTERN: Flagged by automated risk assessment rules';
    END IF;

    -- Insert into FRAUD_ALERTS
    INSERT INTO fraud_alerts (txn_id, alert_reason, alert_time, status)
    VALUES (:NEW.txn_id, SUBSTR(v_reason, 1, 200), SYSTIMESTAMP, 'OPEN');
  END IF;
END trg_txn_after_insert;
/

-- ------------------------------------------------------------
-- 3. trg_txn_before_update_score
-- When Person 3's ML script writes anomaly_score:
-- Automatically flag transaction if score >= 0.70
-- ------------------------------------------------------------
CREATE OR REPLACE TRIGGER trg_txn_before_update_score
BEFORE UPDATE OF anomaly_score ON transactions
FOR EACH ROW
BEGIN
  IF :NEW.anomaly_score >= 0.70 THEN
    :NEW.is_flagged := 'Y';
  END IF;
END trg_txn_before_update_score;
/

-- ------------------------------------------------------------
-- 4. trg_txn_after_update_score
-- When Person 3's ML script writes anomaly_score >= 0.70:
-- Automatically ensure a FRAUD_ALERTS record exists for this transaction.
-- ------------------------------------------------------------
CREATE OR REPLACE TRIGGER trg_txn_after_update_score
AFTER UPDATE OF anomaly_score ON transactions
FOR EACH ROW
DECLARE
  v_alert_count  NUMBER;
  v_reason       VARCHAR2(200);
BEGIN
  IF :NEW.anomaly_score >= 0.70 THEN
    -- Check if alert already exists for this txn
    SELECT COUNT(*)
    INTO v_alert_count
    FROM fraud_alerts
    WHERE txn_id = :NEW.txn_id;

    IF v_alert_count = 0 THEN
      v_reason := 'AI/ML DETECTION: Isolation Forest anomaly score ' ||
                  TO_CHAR(:NEW.anomaly_score, '0.9999') || ' exceeds threshold (0.70)';

      INSERT INTO fraud_alerts (txn_id, alert_reason, alert_time, status)
      VALUES (:NEW.txn_id, SUBSTR(v_reason, 1, 200), SYSTIMESTAMP, 'OPEN');
    END IF;
  END IF;
END trg_txn_after_update_score;
/

-- ------------------------------------------------------------
-- 5. trg_alert_audit_log
-- Audit trigger on FRAUD_ALERTS:
-- Captures alert creation and every lifecycle status change into ALERT_AUDIT_LOG.
-- ------------------------------------------------------------
CREATE OR REPLACE TRIGGER trg_alert_audit_log
AFTER INSERT OR UPDATE ON fraud_alerts
FOR EACH ROW
DECLARE
  v_action        VARCHAR2(50);
  v_performed_by  VARCHAR2(50);
BEGIN
  -- Determine current operator / user
  v_performed_by := NVL(SYS_CONTEXT('USERENV', 'CLIENT_IDENTIFIER'), USER);

  IF INSERTING THEN
    v_action := 'ALERT_CREATED';
  ELSIF UPDATING THEN
    IF :OLD.status <> :NEW.status THEN
      v_action := SUBSTR('STATUS_' || :OLD.status || '_TO_' || :NEW.status, 1, 50);
    ELSE
      v_action := 'ALERT_UPDATED';
    END IF;
  END IF;

  INSERT INTO alert_audit_log (alert_id, action, action_time, performed_by)
  VALUES (:NEW.alert_id, v_action, SYSTIMESTAMP, v_performed_by);
END trg_alert_audit_log;
/
