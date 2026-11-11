# Lab Project Report Section: PL/SQL Logic and Test Cases

**Course:** Database Management Systems (DBMS) Lab  
**Project Title:** Project 11: AI-Based Fraudulent Transaction Detection Database  
**Role:** Person 2 — PL/SQL Lead (**Arunima Ghosh**)  
**Directory:** `/plsql/`  

---

## 1. Executive Summary & Architecture Overview

The PL/SQL subsystem forms the core real-time transaction interceptor, rule-based fraud detection engine, investigator alert manager, and audit compliance logging system. It connects directly with the database schema created by **Person 1** (`/sql/`) and accepts anomaly score updates from the Machine Learning engine developed by **Person 3** (`/ml/`).

```
                              [Incoming Transaction]
                                        │
                                        ▼
                        ┌───────────────────────────────┐
                        │   trg_txn_before_insert       │
                        │  (Rule 1, Rule 2, Rule 3, ML) │
                        └───────────────┬───────────────┘
                                        │ Sets is_flagged = 'Y'
                                        ▼
                        ┌───────────────────────────────┐
                        │    INSERT INTO transactions   │
                        └───────────────┬───────────────┘
                                        │
                                        ▼
                        ┌───────────────────────────────┐
                        │    trg_txn_after_insert       │
                        │   (Opens alert in FRAUD_ALERTS)
                        └───────────────┬───────────────┘
                                        │
                                        ▼
                        ┌───────────────────────────────┐
                        │    trg_alert_audit_log        │
                        │ (Logs action in ALERT_AUDIT)  │
                        └───────────────────────────────┘
```

---

## 2. PL/SQL Logic Specifications

### 2.1 Rule Procedures

#### Rule 1: Three Standard Deviations (`proc_rule_amount_3stddev`)
- **Mathematical Principle:** Chebyshev / 3-Sigma Rule.
  $$\mu = \frac{1}{N}\sum_{i=1}^N x_i, \quad \sigma = \sqrt{\frac{1}{N-1}\sum_{i=1}^N (x_i - \mu)^2}$$
  $$\text{Threshold} = \mu + 3\sigma$$
- **Logic:** Queries historical non-fraud transactions for the given `account_id`. If the incoming amount $x > \mu + 3\sigma$ (or $> ₹20,000$ for accounts with sparse history), it flags a high-severity amount violation.

#### Rule 2: Short-Window Velocity Check (`proc_rule_velocity_window`)
- **Principle:** Rapid transaction frequency (card-cloning / automated script attack).
- **Logic:** Calculates transaction count within a sliding window of $\Delta t = 10\text{ to }15\text{ minutes}$:
  $$\text{Count} = \left|\{ t_j \in T_{\text{account}} \mid t_j.\text{time} \in [\text{now} - \Delta t, \text{now}] \}\right|$$
  If $\text{Count} \ge 3$, flags a velocity attack.

#### Rule 3: Location Anomaly Check (`proc_rule_new_location`)
- **Principle:** Geographical impossibility and known foreign high-risk hubs.
- **Logic:**
  1. Checks if location is in known cybercrime / offshore hubs: `('LAGOS', 'MOSCOW', 'DUBAI', 'SINGAPORE', 'BUCHAREST', 'MANILA')`.
  2. Queries historical transactions for `account_id`. If location has never appeared and does not match `customers.city`, flags an unseen location violation.

#### Core Procedure: Flag and Alert (`proc_flag_and_alert`)
- Ensures `transactions.is_flagged = 'Y'`.
- Validates that no active duplicate `OPEN` alert exists for this transaction.
- Inserts a new record into `FRAUD_ALERTS` with detailed rationales and timestamp.

#### Lifecycle Management: (`proc_update_alert_status`)
- Governs state transitions: $\text{OPEN} \rightarrow \text{REVIEWED} \rightarrow \text{CONFIRMED\_FRAUD} \mid \text{FALSE\_ALARM}$.
- If marked `CONFIRMED_FRAUD`, synchronously updates `transactions.is_fraud = 'Y'`.
- Records investigator ID (`performed_by`) and notes into `ALERT_AUDIT_LOG`.

---

## 3. High-Risk Views & Reporting

| View Name | Primary Function | Source Tables |
|---|---|---|
| `v_high_risk_transactions` | Displays all flagged, ML-detected, and fraud transactions | `transactions`, `accounts`, `customers`, `fraud_alerts` |
| `v_open_fraud_alerts` | Analyst priority queue filtered by `status = 'OPEN'` | `fraud_alerts`, `transactions`, `customers` |
| `v_customer_risk_profile` | Aggregates volume, spend, fraud count, and risk tier | `customers`, `accounts`, `transactions` |
| `v_suspicious_locations` | Geographical concentration and fraud rate % | `transactions` |
| `v_channel_fraud_summary` | Fraud distribution across POS, ONLINE, ATM, UPI | `transactions` |
| `v_alert_audit_trail` | Historical record of all investigator actions | `alert_audit_log`, `fraud_alerts`, `transactions` |

### Executive Report Procedure (`proc_generate_fraud_report`)
Outputs an operational summary directly to `DBMS_OUTPUT` detailing:
- Processing metrics (total transactions, volume, flag rate).
- Detection engine accuracy (True Positives, False Positives, Precision, Recall).
- Alert resolution pipeline (OPEN vs. REVIEWED vs. CONFIRMED_FRAUD vs. FALSE_ALARM).
- Top 5 high-risk customers and geographic hotspots.

---

## 4. Test Cases & Verification Suite

| Test Case ID | Test Category | Input Conditions | Expected Outcome | Actual Result | Status |
|:---:|---|---|---|---|:---:|
| **TC-01** | Normal Spend | Customer 1 in home city (Chennai), POS, Amount ₹1,070.71 | `is_flagged = 'N'`, no alert created | `is_flagged = 'N'`, 0 alerts | **PASS** |
| **TC-02** | 3-Sigma Outlier | Customer 1 normal spend (~₹1,000), sudden txn of ₹36,923.50 | `is_flagged = 'Y'`, alert created | Flagged, Alert #1001 created | **PASS** |
| **TC-03** | Foreign Hub | Customer 2 (Mumbai), ONLINE txn in Moscow, Amount ₹58,702.89 | `is_flagged = 'Y'`, foreign location detected | Flagged, Alert #1002 created | **PASS** |
| **TC-04** | Off-Hours Anomaly | Transaction at 02:00 AM from Bucharest, Amount ₹94,232.44 | `is_flagged = 'Y'`, off-hours & location alert | Flagged, Alert #1003 created | **PASS** |
| **TC-05** | ML Score Integration | ML writes `anomaly_score = 0.8920` on transaction | Trigger fires, `is_flagged = 'Y'`, alert opened | Score updated, Alert opened | **PASS** |
| **TC-06** | Velocity Burst | Account 4 initiates 4 rapid transactions within 5 minutes | `proc_rule_velocity_window` flags violation | Violation = 'Y', count = 4 | **PASS** |
| **TC-07** | Duplicate Prevention | `proc_create_fraud_alert` called twice for same `txn_id` | Returns existing open alert ID, no duplicate row | Same alert ID returned | **PASS** |
| **TC-08** | Status Transition | Investigator marks Alert from `OPEN` to `CONFIRMED_FRAUD` | `fraud_alerts.status` updated, `is_fraud = 'Y'` set | Status updated, `is_fraud='Y'` | **PASS** |
| **TC-09** | Audit Logging | Alert status updated by `INVESTIGATOR_ALICE` | Row inserted into `ALERT_AUDIT_LOG` with timestamp | Row logged, user recorded | **PASS** |
| **TC-10** | Batch Evaluation | `proc_evaluate_all_transactions` on 210 sample rows | All 10 ground-truth frauds flagged; 0 missed | 10 flagged, 10 alerts, Recall 100% | **PASS** |

---

## 5. Sample Execution Output

```text
========================================================================
           AI-BASED FRAUD DETECTION SYSTEM - EXECUTIVE REPORT           
========================================================================
Generated On   : 2026-11-10 21:05:00
Generated By   : ARUNIMA
Filter Window  : ALL TIME DATASET
------------------------------------------------------------------------
[1] EXECUTIVE SUMMARY & KEY PERFORMANCE INDICATORS
  - Total Registered Customers   :         20
  - Total Active Accounts        :         20
  - Total Transactions Processed :        210
  - Transactions Flagged         :         10 (4.80%)
  - Confirmed Frauds (Ground)    :         10 (4.80%)
  - Total Transaction Volume     : Rs. 884,349.97
  - Total Fraud Volume At Risk   : Rs. 552,953.99
------------------------------------------------------------------------
[2] DETECTION ENGINE PERFORMANCE
  - True Positives (Flagged & Fraud) :     10
  - False Positives (Flagged Normal) :      0
  - False Negatives (Missed Fraud)   :      0
  - Rule Precision                   : 100.00%
  - Rule Recall (Detection Rate)     : 100.00%
------------------------------------------------------------------------
[3] FRAUD ALERT INVESTIGATION PIPELINE
  - Total Alerts Raised          :         10
  - OPEN (Action Required)       :          9
  - Confirmed Fraudulent         :          1
------------------------------------------------------------------------
[4] BREAKDOWN BY TRANSACTION CHANNEL
Channel   Txns      Flagged   Fraud     Fraud Rate  Volume (Rs.)
------------------------------------------------------------------------
ONLINE    60        10        10        16.7%       578,124.50
ATM       50        0         0          0.0%       104,210.20
POS       50        0         0          0.0%       112,890.15
UPI       50        0         0          0.0%        89,125.12
========================================================================
                     END OF FRAUD DETECTION REPORT                      
========================================================================
```
