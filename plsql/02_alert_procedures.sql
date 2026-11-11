-- ============================================================
-- Project 11: AI-Based Fraudulent Transaction Detection Database
-- File: plsql/02_alert_procedures.sql  (Person 2 - PL/SQL Lead)
-- Purpose: Stored Procedures for Fraud Detection Rules:
--   1) proc_rule_amount_3stddev (Amount > 3 StdDev of Customer Average)
--   2) proc_rule_velocity_window (Burst transactions in short window)
--   3) proc_rule_new_location (Unseen / Foreign location anomaly)
--   4) proc_flag_and_alert (Flag transaction & insert into FRAUD_ALERTS)
--   5) proc_update_alert_status (Lifecycle transition & audit logging)
--   6) proc_evaluate_transaction (Composite single transaction check)
--   7) proc_evaluate_all_transactions (Batch scan of existing dataset)
-- ============================================================

-- ------------------------------------------------------------
-- RULE 1: proc_rule_amount_3stddev
-- Evaluates if a transaction amount exceeds 3 standard deviations
-- above the customer's historical average spend (3-Sigma Rule).
-- Formula: Threshold = Mean + 3 * StdDev
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE proc_rule_amount_3stddev (
  p_account_id    IN  transactions.account_id%TYPE,
  p_amount        IN  transactions.amount%TYPE,
  p_is_violation  OUT CHAR,
  p_threshold     OUT NUMBER,
  p_mean          OUT NUMBER,
  p_stddev        OUT NUMBER
) IS
  v_count NUMBER := 0;
BEGIN
  -- Compute mean and sample standard deviation of customer's normal historical spend
  SELECT COUNT(*), NVL(AVG(amount), 0), NVL(STDDEV(amount), 0)
  INTO v_count, p_mean, p_stddev
  FROM transactions
  WHERE account_id = p_account_id
    AND is_fraud = 'N';

  IF v_count >= 3 AND p_stddev > 0 THEN
    p_threshold := ROUND(p_mean + (3 * p_stddev), 2);
  ELSE
    -- Default heuristic threshold when insufficient transaction history exists
    p_threshold := 20000.00;
  END IF;

  IF p_amount > p_threshold THEN
    p_is_violation := 'Y';
  ELSE
    p_is_violation := 'N';
  END IF;
EXCEPTION
  WHEN OTHERS THEN
    p_is_violation := 'N';
    p_threshold := 20000.00;
    p_mean := 0;
    p_stddev := 0;
END proc_rule_amount_3stddev;
/

-- ------------------------------------------------------------
-- RULE 2: proc_rule_velocity_window
-- Detects rapid-fire/burst transactions: checks if customer has
-- exceeded a threshold number of transactions within a short time window.
-- E.g. >= 3 transactions within 10 minutes.
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE proc_rule_velocity_window (
  p_account_id     IN  transactions.account_id%TYPE,
  p_txn_time       IN  TIMESTAMP,
  p_window_minutes IN  NUMBER DEFAULT 10,
  p_max_txns       IN  NUMBER DEFAULT 3,
  p_is_violation   OUT CHAR,
  p_recent_count   OUT NUMBER
) IS
  v_ref_time TIMESTAMP;
BEGIN
  v_ref_time := NVL(p_txn_time, SYSTIMESTAMP);

  SELECT COUNT(*)
  INTO p_recent_count
  FROM transactions
  WHERE account_id = p_account_id
    AND txn_time BETWEEN (v_ref_time - NUMTODSINTERVAL(p_window_minutes, 'MINUTE'))
                     AND v_ref_time;

  -- Including the current transaction, if count exceeds or meets max allowed
  IF p_recent_count >= p_max_txns THEN
    p_is_violation := 'Y';
  ELSE
    p_is_violation := 'N';
  END IF;
EXCEPTION
  WHEN OTHERS THEN
    p_is_violation := 'N';
    p_recent_count := 0;
END proc_rule_velocity_window;
/

-- ------------------------------------------------------------
-- RULE 3: proc_rule_new_location
-- Detects location anomalies:
--   a) Location is a known international fraud haven (Lagos, Moscow, Bucharest, Dubai, Manila, Singapore)
--   b) Location has never been visited by this customer in past transactions AND differs from home city
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE proc_rule_new_location (
  p_account_id    IN  transactions.account_id%TYPE,
  p_location      IN  transactions.location%TYPE,
  p_is_violation  OUT CHAR,
  p_details       OUT VARCHAR2
) IS
  v_home_city     customers.city%TYPE;
  v_prev_matches  NUMBER := 0;
  v_is_foreign    BOOLEAN := FALSE;
BEGIN
  p_is_violation := 'N';
  p_details := 'Location verified';

  IF UPPER(p_location) IN ('LAGOS','MOSCOW','DUBAI','SINGAPORE','BUCHAREST','MANILA') THEN
    v_is_foreign := TRUE;
  END IF;

  -- Lookup customer home city
  BEGIN
    SELECT c.city
    INTO v_home_city
    FROM accounts a
    JOIN customers c ON a.customer_id = c.customer_id
    WHERE a.account_id = p_account_id;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      v_home_city := NULL;
  END;

  -- Check past transaction history for this location
  SELECT COUNT(*)
  INTO v_prev_matches
  FROM transactions
  WHERE account_id = p_account_id
    AND UPPER(location) = UPPER(p_location);

  IF v_is_foreign THEN
    p_is_violation := 'Y';
    p_details := 'High-risk foreign location (' || p_location || ')';
  ELSIF v_prev_matches = 0 AND v_home_city IS NOT NULL AND UPPER(p_location) <> UPPER(v_home_city) THEN
    p_is_violation := 'Y';
    p_details := 'Unseen location (' || p_location || '), home is ' || v_home_city;
  END IF;
EXCEPTION
  WHEN OTHERS THEN
    p_is_violation := 'N';
    p_details := 'Error in location evaluation: ' || SQLERRM;
END proc_rule_new_location;
/

-- ------------------------------------------------------------
-- 4. proc_flag_and_alert
-- Flags a transaction (is_flagged = 'Y') and creates an alert record
-- in FRAUD_ALERTS with status = 'OPEN'.
-- Prevents duplicate open alerts for the same transaction.
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE proc_flag_and_alert (
  p_txn_id       IN  transactions.txn_id%TYPE,
  p_alert_reason IN  fraud_alerts.alert_reason%TYPE,
  p_alert_id     OUT fraud_alerts.alert_id%TYPE
) IS
  v_existing_id NUMBER;
BEGIN
  -- 1. Flag transaction in TRANSACTIONS table
  UPDATE transactions
  SET is_flagged = 'Y'
  WHERE txn_id = p_txn_id AND is_flagged <> 'Y';

  -- 2. Check for duplicate open alert
  BEGIN
    SELECT alert_id
    INTO v_existing_id
    FROM fraud_alerts
    WHERE txn_id = p_txn_id AND status = 'OPEN' AND ROWNUM = 1;

    p_alert_id := v_existing_id;
    RETURN;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      NULL; -- Proceed to insert
  END;

  -- 3. Insert into FRAUD_ALERTS
  INSERT INTO fraud_alerts (txn_id, alert_reason, alert_time, status)
  VALUES (p_txn_id, SUBSTR(NVL(p_alert_reason, 'Suspicious Activity Detected'), 1, 200), SYSTIMESTAMP, 'OPEN')
  RETURNING alert_id INTO p_alert_id;

  DBMS_OUTPUT.PUT_LINE('Flagged Transaction ' || p_txn_id || ' -> Created Alert ID: ' || p_alert_id);
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('Error in proc_flag_and_alert: ' || SQLERRM);
    RAISE;
END proc_flag_and_alert;
/

-- Alias for backward compatibility
CREATE OR REPLACE PROCEDURE proc_create_fraud_alert (
  p_txn_id       IN  transactions.txn_id%TYPE,
  p_alert_reason IN  fraud_alerts.alert_reason%TYPE,
  p_alert_id     OUT fraud_alerts.alert_id%TYPE
) IS
BEGIN
  proc_flag_and_alert(p_txn_id, p_alert_reason, p_alert_id);
END proc_create_fraud_alert;
/

-- ------------------------------------------------------------
-- 5. proc_update_alert_status
-- Transitions alert status through its lifecycle:
-- OPEN -> REVIEWED -> CONFIRMED_FRAUD / FALSE_ALARM.
-- Validates statuses, updates is_fraud when confirmed, and triggers audit log.
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE proc_update_alert_status (
  p_alert_id     IN fraud_alerts.alert_id%TYPE,
  p_new_status   IN fraud_alerts.status%TYPE,
  p_performed_by IN VARCHAR2 DEFAULT NULL,
  p_remarks      IN VARCHAR2 DEFAULT NULL
) IS
  v_current_status  fraud_alerts.status%TYPE;
  v_txn_id          transactions.txn_id%TYPE;
  v_user            VARCHAR2(50);
BEGIN
  -- Validate target status
  IF UPPER(p_new_status) NOT IN ('OPEN', 'REVIEWED', 'CONFIRMED_FRAUD', 'FALSE_ALARM') THEN
    RAISE_APPLICATION_ERROR(-20002, 'Invalid status: ' || p_new_status || 
      '. Allowed values: OPEN, REVIEWED, CONFIRMED_FRAUD, FALSE_ALARM');
  END IF;

  -- Fetch current alert details
  BEGIN
    SELECT status, txn_id
    INTO v_current_status, v_txn_id
    FROM fraud_alerts
    WHERE alert_id = p_alert_id;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20003, 'Alert ID ' || p_alert_id || ' not found.');
  END;

  v_user := NVL(p_performed_by, USER);

  -- Set client identifier for audit trigger
  IF p_performed_by IS NOT NULL THEN
    DBMS_SESSION.SET_IDENTIFIER(p_performed_by);
  END IF;

  -- Update alert status
  UPDATE fraud_alerts
  SET status = UPPER(p_new_status)
  WHERE alert_id = p_alert_id;

  -- Cascade business logic
  IF UPPER(p_new_status) = 'CONFIRMED_FRAUD' THEN
    UPDATE transactions
    SET is_fraud = 'Y', is_flagged = 'Y'
    WHERE txn_id = v_txn_id;
    DBMS_OUTPUT.PUT_LINE('Alert ' || p_alert_id || ' -> CONFIRMED_FRAUD. Transaction ' || v_txn_id || ' confirmed.');
  ELSIF UPPER(p_new_status) = 'FALSE_ALARM' THEN
    DBMS_OUTPUT.PUT_LINE('Alert ' || p_alert_id || ' -> Closed as FALSE_ALARM.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('Alert ' || p_alert_id || ' -> Transitioned to ' || UPPER(p_new_status));
  END IF;

  -- Record reviewer remarks in audit log if provided
  IF p_remarks IS NOT NULL THEN
    INSERT INTO alert_audit_log (alert_id, action, action_time, performed_by)
    VALUES (p_alert_id, SUBSTR('REMARKS: ' || p_remarks, 1, 50), SYSTIMESTAMP, v_user);
  END IF;

  IF p_performed_by IS NOT NULL THEN
    DBMS_SESSION.CLEAR_IDENTIFIER;
  END IF;

  COMMIT;
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    DBMS_OUTPUT.PUT_LINE('Error in proc_update_alert_status: ' || SQLERRM);
    RAISE;
END proc_update_alert_status;
/

-- ------------------------------------------------------------
-- 6. proc_evaluate_transaction
-- Composite evaluator: executes the 3 rule procedures and checks ML score.
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE proc_evaluate_transaction (
  p_txn_id         IN  transactions.txn_id%TYPE,
  p_is_suspicious  OUT CHAR,
  p_reason         OUT VARCHAR2
) IS
  v_acc_id         transactions.account_id%TYPE;
  v_amount         transactions.amount%TYPE;
  v_location       transactions.location%TYPE;
  v_txn_time       transactions.txn_time%TYPE;
  v_score          transactions.anomaly_score%TYPE;

  -- Rule output variables
  v_r1_violation   CHAR(1);
  v_threshold      NUMBER;
  v_mean           NUMBER;
  v_stddev         NUMBER;

  v_r2_violation   CHAR(1);
  v_recent_cnt     NUMBER;

  v_r3_violation   CHAR(1);
  v_loc_details    VARCHAR2(200);

  v_reasons        VARCHAR2(1000) := '';
BEGIN
  SELECT account_id, amount, location, txn_time, anomaly_score
  INTO v_acc_id, v_amount, v_location, v_txn_time, v_score
  FROM transactions
  WHERE txn_id = p_txn_id;

  -- Rule 1: 3 StdDev check
  proc_rule_amount_3stddev(v_acc_id, v_amount, v_r1_violation, v_threshold, v_mean, v_stddev);
  IF v_r1_violation = 'Y' THEN
    v_reasons := v_reasons || 'Amount Rs. ' || TO_CHAR(v_amount, 'FM999,990.00') || 
                 ' exceeds 3-Sigma threshold (Rs. ' || TO_CHAR(v_threshold, 'FM999,990.00') || '); ';
  END IF;

  -- Rule 2: Velocity check (past 15 mins, max 3 txns)
  proc_rule_velocity_window(v_acc_id, v_txn_time, 15, 3, v_r2_violation, v_recent_cnt);
  IF v_r2_violation = 'Y' THEN
    v_reasons := v_reasons || 'High velocity: ' || v_recent_cnt || ' txns in short window; ';
  END IF;

  -- Rule 3: New / foreign location
  proc_rule_new_location(v_acc_id, v_location, v_r3_violation, v_loc_details);
  IF v_r3_violation = 'Y' THEN
    v_reasons := v_reasons || v_loc_details || '; ';
  END IF;

  -- Rule 4: Machine Learning Anomaly Score
  IF v_score IS NOT NULL AND v_score >= 0.70 THEN
    v_reasons := v_reasons || 'Isolation Forest Score (' || TO_CHAR(v_score, '0.9999') || ') >= 0.70; ';
  END IF;

  IF v_r1_violation = 'Y' OR v_r2_violation = 'Y' OR v_r3_violation = 'Y' OR (v_score >= 0.70) THEN
    p_is_suspicious := 'Y';
    p_reason := SUBSTR(RTRIM(v_reasons, '; '), 1, 200);
  ELSE
    p_is_suspicious := 'N';
    p_reason := 'Normal Transaction';
  END IF;
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    p_is_suspicious := 'N';
    p_reason := 'Transaction not found';
  WHEN OTHERS THEN
    p_is_suspicious := 'N';
    p_reason := 'Error: ' || SQLERRM;
END proc_evaluate_transaction;
/

-- ------------------------------------------------------------
-- 7. proc_evaluate_all_transactions
-- Batch evaluator: scans all transactions and flags violations.
-- Bridges sample data to the alert system.
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE proc_evaluate_all_transactions (
  p_flagged_count  OUT NUMBER,
  p_alerts_created OUT NUMBER
) IS
  v_is_suspicious  CHAR(1);
  v_reason         VARCHAR2(200);
  v_alert_id       NUMBER;
  v_flag_cnt       NUMBER := 0;
  v_alert_cnt      NUMBER := 0;
BEGIN
  DBMS_OUTPUT.PUT_LINE('=== Starting Batch Fraud Rule Evaluation ===');

  FOR rec IN (
    SELECT txn_id, is_flagged, is_fraud
    FROM transactions
    ORDER BY txn_id
  ) LOOP
    proc_evaluate_transaction(rec.txn_id, v_is_suspicious, v_reason);

    IF rec.is_fraud = 'Y' THEN
      v_is_suspicious := 'Y';
      IF v_reason = 'Normal Transaction' THEN
        v_reason := 'GROUND TRUTH: Confirmed Fraudulent Pattern';
      END IF;
    END IF;

    IF v_is_suspicious = 'Y' THEN
      IF rec.is_flagged <> 'Y' THEN
        UPDATE transactions
        SET is_flagged = 'Y'
        WHERE txn_id = rec.txn_id;
        v_flag_cnt := v_flag_cnt + 1;
      END IF;

      BEGIN
        SELECT alert_id INTO v_alert_id
        FROM fraud_alerts
        WHERE txn_id = rec.txn_id AND ROWNUM = 1;
      EXCEPTION
        WHEN NO_DATA_FOUND THEN
          INSERT INTO fraud_alerts (txn_id, alert_reason, alert_time, status)
          VALUES (rec.txn_id, v_reason, SYSTIMESTAMP, 'OPEN')
          RETURNING alert_id INTO v_alert_id;
          v_alert_cnt := v_alert_cnt + 1;
      END;
    END IF;
  END LOOP;

  COMMIT;

  p_flagged_count := v_flag_cnt;
  p_alerts_created := v_alert_cnt;

  DBMS_OUTPUT.PUT_LINE('Batch Evaluation Finished:');
  DBMS_OUTPUT.PUT_LINE('  - Newly Flagged Transactions: ' || v_flag_cnt);
  DBMS_OUTPUT.PUT_LINE('  - Fraud Alerts Created:       ' || v_alert_cnt);
  DBMS_OUTPUT.PUT_LINE('============================================');
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    DBMS_OUTPUT.PUT_LINE('Error in proc_evaluate_all_transactions: ' || SQLERRM);
    RAISE;
END proc_evaluate_all_transactions;
/
