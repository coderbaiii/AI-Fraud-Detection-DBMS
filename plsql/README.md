# Person 2: PL/SQL Component Documentation

## AI-Based Fraudulent Transaction Detection Database

**Folder:** `/plsql/`  
**Role:** Person 2 — PL/SQL Developer (Triggers, Alert Procedures, High-Risk Views, Report Procedure)

---

## 1. Overview

This module implements the core business logic, rule-based fraud detection engine, investigator workflow automation, lifecycle auditing, analytical risk views, and executive reporting for the AI-Based Fraud Detection System.

It seamlessly integrates with:
- **Person 1 (Database / Schema):** Runs on top of `customers`, `accounts`, `transactions`, `fraud_alerts`, and `alert_audit_log`.
- **Person 3 (AI/ML):** Listens to updates on `transactions.anomaly_score` written by the Isolation Forest model, automatically triggering alerts when the score exceeds the critical threshold (`>= 0.70`).

---

## 2. Directory Structure

```text
plsql/
├── 01_triggers.sql           # Rule-based detection & audit triggers
├── 02_alert_procedures.sql   # Alert management & batch evaluation procedures
├── 03_high_risk_views.sql    # Analytical & operational fraud views
├── 04_report_procedure.sql   # Executive fraud report generation procedure
├── 05_run_all.sql            # Master execution & verification script
├── README.md                 # Complete documentation (this file)
└── data/
    └── transactions_export.csv # Exported transaction dataset (210 records)
```

---

## 3. Component Details

### A. Triggers (`01_triggers.sql`)

1. **`trg_txn_before_insert`**:
   - Fires **BEFORE INSERT** on `transactions` for each row.
   - Evaluates multi-factor fraud detection heuristics:
     - **High Transaction Amount:** Flags transactions `>= 20,000` (normal spend is `< 5,500`).
     - **High-Risk Foreign Locations:** Flags transactions originating from foreign hubs (`Lagos`, `Moscow`, `Dubai`, `Singapore`, `Bucharest`, `Manila`).
     - **Location / Home City Mismatch:** Compares transaction location against the customer's registered home city.
     - **Off-Hours Activity:** Flags transactions taking place during late night hours (`01:00 AM – 04:59 AM`).
     - **Pre-computed ML Score:** Flags if `anomaly_score >= 0.70`.
   - Sets `:NEW.is_flagged := 'Y'` when any high-risk condition is met.

2. **`trg_txn_after_insert`**:
   - Fires **AFTER INSERT** on `transactions` for each row.
   - Whenever `:NEW.is_flagged = 'Y'`, automatically creates an alert in `FRAUD_ALERTS` with status `'OPEN'` and an explicit reason detailing the triggered rules.

3. **`trg_txn_before_update_score` & `trg_txn_after_update_score`**:
   - Fires when Person 3's ML script updates `anomaly_score`.
   - If `anomaly_score >= 0.70`, sets `is_flagged = 'Y'` and automatically opens a new fraud alert in `FRAUD_ALERTS` if one does not already exist.

4. **`trg_alert_audit_log`**:
   - Fires **AFTER INSERT OR UPDATE** on `FRAUD_ALERTS` for each row.
   - Automatically records audit events (`ALERT_CREATED`, `STATUS_OPEN_TO_REVIEWED`, `STATUS_REVIEWED_TO_CONFIRMED_FRAUD`, etc.) into `ALERT_AUDIT_LOG` along with timestamp and performing user identifier.

---

### B. Alert Procedures (`02_alert_procedures.sql`)

1. **`proc_create_fraud_alert(p_txn_id, p_alert_reason, p_alert_id OUT)`**:
   - Programmatically creates a fraud alert for a given transaction.
   - Ensures `is_flagged = 'Y'` on the transaction.
   - Prevents duplicate open alerts for the same transaction.

2. **`proc_update_alert_status(p_alert_id, p_new_status, p_performed_by, p_remarks)`**:
   - Transitions alert status through its operational lifecycle:
     `OPEN` $\rightarrow$ `REVIEWED` $\rightarrow$ `CONFIRMED_FRAUD` / `FALSE_ALARM`.
   - Validates status transitions and ensures data consistency (e.g., marks `is_fraud = 'Y'` on confirmed fraud).
   - Writes remarks and reviewer identity into `ALERT_AUDIT_LOG`.

3. **`proc_evaluate_transaction(p_txn_id, p_is_suspicious OUT, p_reason OUT)`**:
   - Evaluates a single transaction against rule-based heuristics and returns suspicion status and reason rationale.

4. **`proc_evaluate_all_transactions(p_flagged_count OUT, p_alerts_created OUT)`**:
   - Batch evaluation procedure.
   - Scans existing transactions (such as the 210 sample rows inserted by Person 1 prior to trigger deployment).
   - Flags all suspicious transactions and opens corresponding `FRAUD_ALERTS`.

---

### C. High-Risk Views (`03_high_risk_views.sql`)

1. **`v_high_risk_transactions`**:
   - Joins `transactions`, `accounts`, `customers`, and `fraud_alerts`.
   - Filters on `is_flagged = 'Y' OR is_fraud = 'Y' OR anomaly_score >= 0.70`.
   - Provides complete contextual intelligence for fraud analysts.

2. **`v_open_fraud_alerts`**:
   - Active investigation queue of unreviewed (`OPEN`) alerts with urgency rating (`CRITICAL`, `HIGH`, `MEDIUM`) and alert age in hours.

3. **`v_customer_risk_profile`**:
   - Aggregated metrics per customer: total balance, transaction volume, spend, flagged count, confirmed fraud count, risk percentage, and risk tier (`CRITICAL`, `HIGH`, `MEDIUM`, `LOW`).

4. **`v_suspicious_locations`**:
   - Geographical concentration analysis: transaction count, fraud count, total volume, and fraud rate percentage by city/location.

5. **`v_channel_fraud_summary`**:
   - Performance analysis by channel (`POS`, `ONLINE`, `ATM`, `UPI`).

6. **`v_alert_audit_trail`**:
   - End-to-end audit log view showing who changed which alert and when.

---

### D. Report Procedure (`04_report_procedure.sql`)

**`proc_generate_fraud_report(p_start_date IN DATE DEFAULT NULL, p_end_date IN DATE DEFAULT NULL)`**
- Generates an executive fraud management report directly in SQL*Plus / SQL Developer via `DBMS_OUTPUT`.
- Output sections include:
  1. Executive Summary & KPIs (Total Txns, Flagged Txns, Flag Rate %, Confirmed Frauds, Financial Volume At Risk).
  2. Detection Engine Performance (True Positives, False Positives, Precision %, Recall %).
  3. Alert Investigation Pipeline (OPEN, REVIEWED, CONFIRMED_FRAUD, FALSE_ALARM).
  4. Breakdown by Transaction Channel (POS, ONLINE, ATM, UPI).
  5. Top 5 High-Risk Customer Accounts.
  6. Top Geographic Fraud Hotspots.

---

## 4. How to Run & Verify

In SQL*Plus or Oracle SQL Developer, run:

```sql
-- Step 1: Run Person 1's scripts first (if not already done)
@sql/01_schema.sql
@sql/02_sample_data.sql

-- Step 2: Run all Person 2 PL/SQL scripts
@plsql/05_run_all.sql
```

Or run individual files in sequence:

```sql
@plsql/01_triggers.sql
@plsql/02_alert_procedures.sql
@plsql/03_high_risk_views.sql
@plsql/04_report_procedure.sql

-- Run batch evaluation on sample data
SET SERVEROUTPUT ON;
DECLARE
  v_flagged NUMBER;
  v_alerts  NUMBER;
BEGIN
  proc_evaluate_all_transactions(v_flagged, v_alerts);
END;
/

-- Generate report
EXEC proc_generate_fraud_report;
```

---

## 5. Dataset Export (`plsql/data/transactions_export.csv`)

Contains the complete export of the 210 generated transactions (200 normal transactions + 10 ground-truth frauds) matching the schema:
- Normal amounts: ₹200 – ₹5,280 across domestic cities.
- Fraud amounts: ₹36,000 – ₹94,000 originating from international destinations (Lagos, Moscow, Bucharest, Dubai, Manila) between 01:00 AM and 04:00 AM.
