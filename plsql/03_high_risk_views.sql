-- ============================================================
-- Project 11: AI-Based Fraudulent Transaction Detection Database
-- File: plsql/03_high_risk_views.sql  (Person 2 - PL/SQL Lead)
-- Purpose: Analytical and Operational Views for Fraud Analysts,
--          Investigation Queues, and Risk Profiling.
-- ============================================================

-- ------------------------------------------------------------
-- 1. v_high_risk_transactions
-- Core operational view showing all high-risk transactions:
-- (Flagged by rules OR High AI Anomaly Score OR Ground-Truth Fraud).
-- Joins transaction, account, customer, and alert details.
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_high_risk_transactions AS
SELECT
  t.txn_id,
  t.account_id,
  c.customer_id,
  c.full_name                      AS customer_name,
  c.city                           AS customer_home_city,
  a.account_type,
  a.balance                        AS account_balance,
  t.amount                         AS txn_amount,
  t.txn_time,
  t.merchant,
  t.location                       AS txn_location,
  t.channel,
  t.is_flagged,
  t.anomaly_score,
  t.is_fraud,
  fa.alert_id,
  fa.status                        AS alert_status,
  fa.alert_reason,
  CASE 
    WHEN UPPER(t.location) IN ('LAGOS','MOSCOW','DUBAI','SINGAPORE','BUCHAREST','MANILA') THEN 'Y'
    ELSE 'N'
  END                              AS is_foreign_location,
  CASE
    WHEN TO_NUMBER(TO_CHAR(t.txn_time, 'HH24')) BETWEEN 1 AND 4 THEN 'Y'
    ELSE 'N'
  END                              AS is_night_txn
FROM transactions t
JOIN accounts a ON t.account_id = a.account_id
JOIN customers c ON a.customer_id = c.customer_id
LEFT JOIN fraud_alerts fa ON t.txn_id = fa.txn_id
WHERE t.is_flagged = 'Y'
   OR t.is_fraud = 'Y'
   OR (t.anomaly_score IS NOT NULL AND t.anomaly_score >= 0.70)
   OR fa.alert_id IS NOT NULL;

-- ------------------------------------------------------------
-- 2. v_open_fraud_alerts
-- Dedicated investigator queue displaying all unreviewed / open alerts.
-- Sorted by urgency and alert timestamp.
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_open_fraud_alerts AS
SELECT
  fa.alert_id,
  fa.alert_time,
  ROUND((SYSDATE - CAST(fa.alert_time AS DATE)) * 24, 1) AS alert_age_hours,
  fa.status,
  fa.alert_reason,
  t.txn_id,
  t.amount                        AS txn_amount,
  t.txn_time,
  t.merchant,
  t.location                      AS txn_location,
  t.channel,
  t.anomaly_score,
  c.customer_id,
  c.full_name                     AS customer_name,
  c.email                         AS customer_email,
  c.city                          AS customer_home_city,
  a.account_id,
  a.account_type,
  a.balance                       AS current_balance,
  CASE
    WHEN t.amount >= 50000 THEN 'CRITICAL'
    WHEN t.amount >= 20000 THEN 'HIGH'
    ELSE 'MEDIUM'
  END                             AS urgency_level
FROM fraud_alerts fa
JOIN transactions t ON fa.txn_id = t.txn_id
JOIN accounts a ON t.account_id = a.account_id
JOIN customers c ON a.customer_id = c.customer_id
WHERE fa.status = 'OPEN';

-- ------------------------------------------------------------
-- 3. v_customer_risk_profile
-- Customer-level aggregated intelligence view.
-- Calculates risk metrics, fraud incidence, and classifies into risk tiers.
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_customer_risk_profile AS
SELECT
  c.customer_id,
  c.full_name                                                   AS customer_name,
  c.city                                                        AS home_city,
  COUNT(DISTINCT a.account_id)                                  AS total_accounts,
  NVL(SUM(DISTINCT a.balance), 0)                               AS total_balance,
  COUNT(t.txn_id)                                               AS total_transactions,
  NVL(SUM(t.amount), 0)                                         AS total_spent,
  NVL(ROUND(AVG(t.amount), 2), 0)                               AS avg_transaction_amount,
  COUNT(CASE WHEN t.is_flagged = 'Y' THEN 1 END)                AS flagged_transactions,
  COUNT(CASE WHEN t.is_fraud = 'Y' THEN 1 END)                  AS confirmed_fraud_txns,
  NVL(SUM(CASE WHEN t.is_fraud = 'Y' THEN t.amount ELSE 0 END), 0) AS total_fraud_amount,
  CASE
    WHEN COUNT(t.txn_id) > 0 THEN
      ROUND((COUNT(CASE WHEN t.is_flagged = 'Y' OR t.is_fraud = 'Y' THEN 1 END) / COUNT(t.txn_id)) * 100, 2)
    ELSE 0
  END                                                           AS risk_percentage,
  CASE
    WHEN COUNT(CASE WHEN t.is_fraud = 'Y' THEN 1 END) >= 1 THEN 'CRITICAL'
    WHEN COUNT(CASE WHEN t.is_flagged = 'Y' THEN 1 END) >= 2 THEN 'HIGH'
    WHEN COUNT(CASE WHEN t.is_flagged = 'Y' THEN 1 END) = 1 THEN 'MEDIUM'
    ELSE 'LOW'
  END                                                           AS customer_risk_tier
FROM customers c
LEFT JOIN accounts a ON c.customer_id = a.customer_id
LEFT JOIN transactions t ON a.account_id = t.account_id
GROUP BY c.customer_id, c.full_name, c.city;

-- ------------------------------------------------------------
-- 4. v_suspicious_locations
-- Geographical fraud concentration analysis.
-- Identifies hotspot locations with abnormal volume and fraud rates.
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_suspicious_locations AS
SELECT
  t.location,
  CASE
    WHEN UPPER(t.location) IN ('LAGOS','MOSCOW','DUBAI','SINGAPORE','BUCHAREST','MANILA') THEN 'Y'
    ELSE 'N'
  END                                                          AS is_foreign_location,
  COUNT(t.txn_id)                                              AS total_transactions,
  COUNT(CASE WHEN t.is_flagged = 'Y' THEN 1 END)               AS flagged_transactions,
  COUNT(CASE WHEN t.is_fraud = 'Y' THEN 1 END)                 AS confirmed_fraud_txns,
  NVL(ROUND(SUM(t.amount), 2), 0)                              AS total_volume,
  NVL(ROUND(AVG(t.amount), 2), 0)                              AS avg_amount,
  NVL(ROUND(MAX(t.amount), 2), 0)                              AS max_amount,
  CASE
    WHEN COUNT(t.txn_id) > 0 THEN
      ROUND((COUNT(CASE WHEN t.is_fraud = 'Y' THEN 1 END) / COUNT(t.txn_id)) * 100, 2)
    ELSE 0
  END                                                          AS fraud_rate_percentage
FROM transactions t
GROUP BY t.location;

-- ------------------------------------------------------------
-- 5. v_channel_fraud_summary
-- Summary of fraud distribution across payment channels
-- (POS, ONLINE, ATM, UPI).
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_channel_fraud_summary AS
SELECT
  t.channel,
  COUNT(t.txn_id)                                              AS total_transactions,
  NVL(ROUND(SUM(t.amount), 2), 0)                              AS total_volume,
  COUNT(CASE WHEN t.is_flagged = 'Y' THEN 1 END)               AS flagged_transactions,
  COUNT(CASE WHEN t.is_fraud = 'Y' THEN 1 END)                 AS confirmed_fraud_txns,
  NVL(ROUND(SUM(CASE WHEN t.is_fraud = 'Y' THEN t.amount ELSE 0 END), 2), 0) AS fraud_volume,
  CASE
    WHEN COUNT(t.txn_id) > 0 THEN
      ROUND((COUNT(CASE WHEN t.is_fraud = 'Y' THEN 1 END) / COUNT(t.txn_id)) * 100, 2)
    ELSE 0
  END                                                          AS fraud_rate_percentage
FROM transactions t
GROUP BY t.channel;

-- ------------------------------------------------------------
-- 6. v_alert_audit_trail
-- Complete lifecycle audit view for investigative tracking.
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_alert_audit_trail AS
SELECT
  aal.log_id,
  aal.alert_id,
  fa.txn_id,
  c.full_name                      AS customer_name,
  t.amount                         AS txn_amount,
  fa.status                        AS current_alert_status,
  aal.action                       AS logged_action,
  aal.action_time,
  aal.performed_by
FROM alert_audit_log aal
JOIN fraud_alerts fa ON aal.alert_id = fa.alert_id
JOIN transactions t ON fa.txn_id = t.txn_id
JOIN accounts a ON t.account_id = a.account_id
JOIN customers c ON a.customer_id = c.customer_id;
