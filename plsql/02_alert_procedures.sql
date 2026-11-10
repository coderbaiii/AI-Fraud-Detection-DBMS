-- ============================================================
-- Project 11: AI-Based Fraudulent Transaction Detection Database
-- File: plsql/02_alert_procedures.sql  (Person 2 - PL/SQL Lead)
-- Purpose: Stored Procedures for Fraud Alert Management, Status
--          Transitions, and Batch Transaction Evaluation.
-- ============================================================

-- ------------------------------------------------------------
-- 1. proc_create_fraud_alert
-- Manually or programmatically creates a fraud alert for a transaction.
-- Flags the transaction if not already flagged.
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE proc_create_fraud_alert (
  p_txn_id       IN  transactions.txn_id%TYPE,
  p_alert_reason IN  fraud_alerts.alert_reason%TYPE,
  p_alert_id     OUT fraud_alerts.alert_id%TYPE
) IS
  v_txn_exists   NUMBER;
  v_existing_id  NUMBER;
BEGIN
  -- Verify transaction exists
  SELECT COUNT(*)
  INTO v_txn_exists
  FROM transactions
  WHERE txn_id = p_txn_id;

  IF v_txn_exists = 0 THEN
    RAISE_APPLICATION_ERROR(-20001, 'Transaction ID ' || p_txn_id || ' does not exist.');
  END IF;

  -- Ensure transaction is marked as flagged
  UPDATE transactions
  SET is_flagged = 'Y'
  WHERE txn_id = p_txn_id AND is_flagged <> 'Y';

  -- Check if an active open alert already exists
  BEGIN
    SELECT alert_id
    INTO v_existing_id
    FROM fraud_alerts
    WHERE txn_id = p_txn_id AND status = 'OPEN' AND ROWNUM = 1;

    p_alert_id := v_existing_id;
    DBMS_OUTPUT.PUT_LINE('Transaction ' || p_txn_id || ' already has an OPEN alert ID: ' || v_existing_id);
    RETURN;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      NULL; -- Proceed to create
  END;

  -- Insert new alert
  INSERT INTO fraud_alerts (txn_id, alert_reason, alert_time, status)
  VALUES (p_txn_id, NVL(p_alert_reason, 'Manual Investigation Required'), SYSTIMESTAMP, 'OPEN')
  RETURNING alert_id INTO p_alert_id;

  DBMS_OUTPUT.PUT_LINE('Created Fraud Alert ID ' || p_alert_id || ' for Transaction ' || p_txn_id);
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('Error in proc_create_fraud_alert: ' || SQLERRM);
    RAISE;
END proc_create_fraud_alert;
/

-- ------------------------------------------------------------
-- 2. proc_update_alert_status
-- Transitions alert status through its lifecycle:
-- OPEN -> REVIEWED -> CONFIRMED_FRAUD / FALSE_ALARM.
-- Validates statuses and logs investigator details.
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

  -- Set client identifier for audit trigger if provided
  IF p_performed_by IS NOT NULL THEN
    DBMS_SESSION.SET_IDENTIFIER(p_performed_by);
  END IF;

  -- Update alert status
  UPDATE fraud_alerts
  SET status = UPPER(p_new_status)
  WHERE alert_id = p_alert_id;

  -- Business logic based on outcome:
  IF UPPER(p_new_status) = 'CONFIRMED_FRAUD' THEN
    UPDATE transactions
    SET is_fraud = 'Y', is_flagged = 'Y'
    WHERE txn_id = v_txn_id;
    DBMS_OUTPUT.PUT_LINE('Alert ' || p_alert_id || ' marked as CONFIRMED_FRAUD. Transaction ' || v_txn_id || ' confirmed fraud.');
  ELSIF UPPER(p_new_status) = 'FALSE_ALARM' THEN
    DBMS_OUTPUT.PUT_LINE('Alert ' || p_alert_id || ' marked as FALSE_ALARM.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('Alert ' || p_alert_id || ' transitioned from ' || v_current_status || ' to ' || UPPER(p_new_status));
  END IF;

  -- If custom remarks provided, append extra audit record
  IF p_remarks IS NOT NULL THEN
    INSERT INTO alert_audit_log (alert_id, action, action_time, performed_by)
    VALUES (p_alert_id, SUBSTR('REMARKS: ' || p_remarks, 1, 50), SYSTIMESTAMP, v_user);
  END IF;

  -- Clear client identifier
  IF p_performed_by IS NOT NULL THEN
    DBMS_SESSION.CLEAR_IDENTIFIER;
  END IF;

  COMMIT;
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('Error in proc_update_alert_status: ' || SQLERRM);
    ROLLBACK;
    RAISE;
END proc_update_alert_status;
/

-- ------------------------------------------------------------
-- 3. proc_evaluate_transaction
-- Evaluates an individual transaction against fraud rule criteria.
-- Returns suspicion flag and formatted reason.
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE proc_evaluate_transaction (
  p_txn_id         IN  transactions.txn_id%TYPE,
  p_is_suspicious  OUT CHAR,
  p_reason         OUT VARCHAR2
) IS
  v_amount        transactions.amount%TYPE;
  v_location      transactions.location%TYPE;
  v_channel       transactions.channel%TYPE;
  v_score         transactions.anomaly_score%TYPE;
  v_txn_time      transactions.txn_time%TYPE;
  v_cust_city     customers.city%TYPE;
  v_hour          NUMBER;
  v_is_foreign    BOOLEAN := FALSE;
  v_reasons       VARCHAR2(500) := '';
BEGIN
  -- Retrieve transaction and customer details
  SELECT t.amount, t.location, t.channel, t.anomaly_score, t.txn_time, c.city
  INTO v_amount, v_location, v_channel, v_score, v_txn_time, v_cust_city
  FROM transactions t
  JOIN accounts a ON t.account_id = a.account_id
  JOIN customers c ON a.customer_id = c.customer_id
  WHERE t.txn_id = p_txn_id;

  -- Extract hour
  v_hour := TO_NUMBER(TO_CHAR(v_txn_time, 'HH24'));

  -- Check foreign location
  IF UPPER(v_location) IN ('LAGOS','MOSCOW','DUBAI','SINGAPORE','BUCHAREST','MANILA') THEN
    v_is_foreign := TRUE;
  END IF;

  p_is_suspicious := 'N';

  -- Rule 1: High transaction amount
  IF v_amount >= 20000 THEN
    p_is_suspicious := 'Y';
    v_reasons := v_reasons || 'High Amount (Rs. ' || TO_CHAR(v_amount, 'FM999,990.00') || '); ';
  END IF;

  -- Rule 2: Foreign location
  IF v_is_foreign THEN
    p_is_suspicious := 'Y';
    v_reasons := v_reasons || 'Foreign Location (' || v_location || '); ';
  END IF;

  -- Rule 3: Off-hours transaction
  IF v_hour BETWEEN 1 AND 4 THEN
    IF v_is_foreign OR v_amount > 10000 OR (v_cust_city IS NOT NULL AND UPPER(v_location) <> UPPER(v_cust_city)) THEN
      p_is_suspicious := 'Y';
      v_reasons := v_reasons || 'Off-Hours Txn (' || TO_CHAR(v_hour) || ':00 hrs); ';
    END IF;
  END IF;

  -- Rule 4: ML Anomaly Score
  IF v_score IS NOT NULL AND v_score >= 0.70 THEN
    p_is_suspicious := 'Y';
    v_reasons := v_reasons || 'ML Anomaly Score (' || TO_CHAR(v_score, '0.9999') || '); ';
  END IF;

  IF p_is_suspicious = 'Y' THEN
    p_reason := SUBSTR(RTRIM(v_reasons, '; '), 1, 200);
  ELSE
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
-- 4. proc_evaluate_all_transactions
-- Batch evaluator: Scans transactions and applies rule-based
-- detection. Essential for evaluating sample data or backlogged records.
-- Updates is_flagged = 'Y' and creates alerts for newly flagged rows.
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
  DBMS_OUTPUT.PUT_LINE('=== Starting Batch Fraud Evaluation ===');

  FOR rec IN (
    SELECT txn_id, amount, location, channel, is_flagged, is_fraud, anomaly_score
    FROM transactions
    ORDER BY txn_id
  ) LOOP
    proc_evaluate_transaction(rec.txn_id, v_is_suspicious, v_reason);

    -- Also respect ground-truth is_fraud = 'Y' in sample dataset
    IF rec.is_fraud = 'Y' THEN
      v_is_suspicious := 'Y';
      IF v_reason = 'Normal Transaction' THEN
        v_reason := 'GROUND TRUTH: Confirmed Fraudulent Pattern';
      END IF;
    END IF;

    IF v_is_suspicious = 'Y' THEN
      -- Flag transaction if not already flagged
      IF rec.is_flagged <> 'Y' THEN
        UPDATE transactions
        SET is_flagged = 'Y'
        WHERE txn_id = rec.txn_id;
        v_flag_cnt := v_flag_cnt + 1;
      END IF;

      -- Create alert if not already existing
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
  DBMS_OUTPUT.PUT_LINE('  - New Fraud Alerts Created:   ' || v_alert_cnt);
  DBMS_OUTPUT.PUT_LINE('=======================================');
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    DBMS_OUTPUT.PUT_LINE('Error in proc_evaluate_all_transactions: ' || SQLERRM);
    RAISE;
END proc_evaluate_all_transactions;
/
