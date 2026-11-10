-- ============================================================
-- Project 11: AI-Based Fraudulent Transaction Detection Database
-- File: plsql/05_run_all.sql  (Person 2 - PL/SQL Lead)
-- Purpose: Master Script to Compile All PL/SQL Objects & Run
--          Verification and Sample Report.
-- Usage in SQL*Plus / SQL Developer:
--   SET SERVEROUTPUT ON SIZE UNLIMITED;
--   @plsql/05_run_all.sql
-- ============================================================

SET SERVEROUTPUT ON SIZE UNLIMITED;
SET LINESIZE 160;
SET PAGESIZE 50;
SET FEEDBACK ON;

PROMPT ============================================================
PROMPT  Compiling Person 2 PL/SQL Objects...
PROMPT ============================================================

PROMPT [1/4] Compiling Triggers (01_triggers.sql)...
@@01_triggers.sql

PROMPT [2/4] Compiling Alert Procedures (02_alert_procedures.sql)...
@@02_alert_procedures.sql

PROMPT [3/4] Compiling High-Risk Views (03_high_risk_views.sql)...
@@03_high_risk_views.sql

PROMPT [4/4] Compiling Report Procedure (04_report_procedure.sql)...
@@04_report_procedure.sql

PROMPT
PROMPT ============================================================
PROMPT  Verifying Compilation Errors (if any)...
PROMPT ============================================================
SELECT object_name, object_type, status
FROM user_objects
WHERE object_name IN (
  'TRG_TXN_BEFORE_INSERT', 'TRG_TXN_AFTER_INSERT',
  'TRG_TXN_BEFORE_UPDATE_SCORE', 'TRG_TXN_AFTER_UPDATE_SCORE',
  'TRG_ALERT_AUDIT_LOG',
  'PROC_CREATE_FRAUD_ALERT', 'PROC_UPDATE_ALERT_STATUS',
  'PROC_EVALUATE_TRANSACTION', 'PROC_EVALUATE_ALL_TRANSACTIONS',
  'V_HIGH_RISK_TRANSACTIONS', 'V_OPEN_FRAUD_ALERTS',
  'V_CUSTOMER_RISK_PROFILE', 'V_SUSPICIOUS_LOCATIONS',
  'V_CHANNEL_FRAUD_SUMMARY', 'V_ALERT_AUDIT_TRAIL',
  'PROC_GENERATE_FRAUD_REPORT'
)
ORDER BY object_type, object_name;

PROMPT
PROMPT ============================================================
PROMPT  Executing Batch Evaluation on Existing Sample Data...
PROMPT ============================================================
DECLARE
  v_flagged NUMBER;
  v_alerts  NUMBER;
BEGIN
  proc_evaluate_all_transactions(v_flagged, v_alerts);
END;
/

PROMPT
PROMPT ============================================================
PROMPT  Demonstrating Alert Status Lifecycle & Audit Log...
PROMPT ============================================================
DECLARE
  v_first_alert_id NUMBER;
BEGIN
  -- Grab first open alert ID
  SELECT MIN(alert_id) INTO v_first_alert_id
  FROM fraud_alerts
  WHERE status = 'OPEN';

  IF v_first_alert_id IS NOT NULL THEN
    DBMS_OUTPUT.PUT_LINE('Simulating investigator review for Alert ID ' || v_first_alert_id);
    proc_update_alert_status(v_first_alert_id, 'REVIEWED', 'INVESTIGATOR_ALICE', 'Under investigation: Foreign IP matched');
    proc_update_alert_status(v_first_alert_id, 'CONFIRMED_FRAUD', 'SUPERVISOR_BOB', 'Customer confirmed unauthorized transaction');
  END IF;
END;
/

PROMPT
PROMPT ============================================================
PROMPT  Generating Executive Fraud Detection Report...
PROMPT ============================================================
EXEC proc_generate_fraud_report;

PROMPT
PROMPT ============================================================
PROMPT  Top 10 High-Risk Transactions (from View)
PROMPT ============================================================
SELECT txn_id, customer_name, txn_amount, txn_location, channel, is_flagged, is_fraud, alert_status
FROM v_high_risk_transactions
WHERE ROWNUM <= 10;

PROMPT
PROMPT ============================================================
PROMPT  Audit Trail Records (from View)
PROMPT ============================================================
SELECT log_id, alert_id, customer_name, logged_action, performed_by, action_time
FROM v_alert_audit_trail
WHERE ROWNUM <= 10;

PROMPT ============================================================
PROMPT  Person 2 PL/SQL Setup and Execution Completed Successfully!
PROMPT ============================================================
