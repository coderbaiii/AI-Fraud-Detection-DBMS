# Person 3: AI/ML Component Documentation

## AI-Based Fraudulent Transaction Detection Database

**Folder:** `/ml/`  
**Role:** Person 3 — AI/ML and Demo Lead  

---

## 1. Overview

This module contains the Machine Learning anomaly detection engine for the DBMS project. It uses an **Isolation Forest** model to detect fraud patterns without requiring pre-labeled training data, then writes calculated anomaly scores (`0.0000` to `1.0000`) back to the database.

---

## 2. Directory Structure

```text
ml/
├── isolation_forest_detector.py  # Main ML model training and scoring script
├── requirements.txt              # Python dependencies
└── README.md                     # Documentation (this file)
```

---

## 3. How to Run

1. **Install Dependencies**:
   ```bash
   pip install -r ml/requirements.txt
   ```

2. **Execute Anomaly Detection**:
   ```bash
   python ml/isolation_forest_detector.py
   ```

3. **Output**:
   - Computes anomaly scores for every transaction.
   - Evaluates Precision, Recall, and Confusion Matrix against ground-truth labels.
   - Generates `ml/update_anomaly_scores.sql` to write scores back into Oracle `TRANSACTIONS.ANOMALY_SCORE`.
