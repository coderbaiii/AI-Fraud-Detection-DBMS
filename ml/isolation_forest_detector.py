"""
Project 11: AI-Based Fraudulent Transaction Detection Database
File: ml/isolation_forest_detector.py  (Person 3 - AI/ML & Demo Lead)

Purpose:
  1. Reads transaction records from Oracle Database (or CSV export fallback).
  2. Applies feature engineering (amount scaling, hour-of-day, location risk, channel).
  3. Trains an Isolation Forest unsupervised anomaly detection model.
  4. Generates normalized anomaly scores (0.0 to 1.0) and writes back to TRANSACTIONS.ANOMALY_SCORE.
  5. Evaluates model performance: Confusion Matrix, Precision, Recall, and F1-Score.
"""

import os
import sys
import numpy as np
import pandas as pd
from sklearn.ensemble import IsolationForest
from sklearn.metrics import classification_report, confusion_matrix, precision_score, recall_score, f1_score

# Configuration
CSV_FALLBACK_PATH = os.path.join(os.path.dirname(__file__), '..', 'plsql', 'data', 'transactions_export.csv')
OUTPUT_SCORES_SQL = os.path.join(os.path.dirname(__file__), 'update_anomaly_scores.sql')

# Database configuration (adjust for your Oracle setup)
DB_CONFIG = {
    'user': os.environ.get('DB_USER', 'system'),
    'password': os.environ.get('DB_PASSWORD', 'oracle'),
    'dsn': os.environ.get('DB_DSN', 'localhost:1521/XEPDB1')
}

def load_transactions():
    """Load transactions from Oracle database or fallback to CSV export."""
    try:
        import oracledb
        print("[INFO] Attempting to connect to Oracle database...")
        conn = oracledb.connect(
            user=DB_CONFIG['user'],
            password=DB_CONFIG['password'],
            dsn=DB_CONFIG['dsn']
        )
        query = "SELECT txn_id, account_id, amount, txn_time, merchant, location, channel, is_fraud FROM transactions"
        df = pd.read_sql(query, conn)
        conn.close()
        print(f"[SUCCESS] Loaded {len(df)} transactions from Oracle Database.")
        return df
    except Exception as e:
        print(f"[WARN] Database connection failed ({e}). Falling back to CSV export...")
        if os.path.exists(CSV_FALLBACK_PATH):
            df = pd.read_csv(CSV_FALLBACK_PATH)
            print(f"[SUCCESS] Loaded {len(df)} transactions from CSV export: {CSV_FALLBACK_PATH}")
            return df
        else:
            raise FileNotFoundError(f"Cannot find transactions export at {CSV_FALLBACK_PATH}")

def engineer_features(df):
    """Transform transaction data into feature vectors for Isolation Forest."""
    df_feat = df.copy()

    # 1. Parse timestamps
    df_feat['txn_time'] = pd.to_datetime(df_feat['txn_time'])
    df_feat['txn_hour'] = df_feat['txn_time'].dt.hour
    df_feat['is_night'] = df_feat['txn_hour'].apply(lambda h: 1 if 1 <= h <= 4 else 0)

    # 2. Location risk scoring
    foreign_hubs = {'LAGOS', 'MOSCOW', 'DUBAI', 'SINGAPORE', 'BUCHAREST', 'MANILA'}
    df_feat['is_foreign_location'] = df_feat['location'].str.upper().apply(lambda loc: 1 if loc in foreign_hubs else 0)

    # 3. Log amount to handle heavy-tailed distribution
    df_feat['log_amount'] = np.log1p(df_feat['amount'])

    # 4. One-hot encode channel
    channel_dummies = pd.get_dummies(df_feat['channel'], prefix='chan', drop_first=False)
    
    # Feature matrix
    feature_cols = ['log_amount', 'is_night', 'is_foreign_location', 'txn_hour']
    X = pd.concat([df_feat[feature_cols], channel_dummies], axis=1).fillna(0)

    return X, df_feat

def train_and_score(X, df_feat):
    """Train Isolation Forest and calculate normalized anomaly scores."""
    print("[INFO] Training Isolation Forest model...")
    # Contamination approximate to 5% fraud rate in sample data
    model = IsolationForest(
        n_estimators=150,
        contamination=0.05,
        random_state=42,
        n_jobs=-1
    )
    model.fit(X)

    # decision_function yields raw anomaly scores (lower = more abnormal)
    raw_scores = model.decision_function(X)
    
    # Invert and normalize to [0, 1] range: 1.0 = highly anomalous, 0.0 = completely normal
    min_score = raw_scores.min()
    max_score = raw_scores.max()
    normalized_scores = (max_score - raw_scores) / (max_score - min_score + 1e-8)
    
    df_feat['anomaly_score'] = np.round(normalized_scores, 4)
    df_feat['pred_anomaly'] = model.predict(X)  # -1 for anomaly, 1 for inlier
    df_feat['pred_fraud'] = df_feat['pred_anomaly'].apply(lambda p: 'Y' if p == -1 else 'N')

    return model, df_feat

def evaluate_model(df_scored):
    """Compute and display model evaluation metrics against true is_fraud labels."""
    print("\n" + "=" * 60)
    print("           MACHINE LEARNING EVALUATION METRICS              ")
    print("=" * 60)
    
    y_true = (df_scored['is_fraud'] == 'Y').astype(int)
    y_pred = (df_scored['anomaly_score'] >= 0.70).astype(int)

    cm = confusion_matrix(y_true, y_pred)
    tn, fp, fn, tp = cm.ravel()
    prec = precision_score(y_true, y_pred, zero_division=0)
    rec = recall_score(y_true, y_pred, zero_division=0)
    f1 = f1_score(y_true, y_pred, zero_division=0)

    print(f"Confusion Matrix:")
    print(f"  True Negatives (Normal detected Normal) : {tn}")
    print(f"  False Positives (Normal flagged Fraud)  : {fp}")
    print(f"  False Negatives (Fraud missed)          : {fn}")
    print(f"  True Positives (Fraud detected Fraud)   : {tp}")
    print("-" * 60)
    print(f"Precision : {prec * 100:.2f}%")
    print(f"Recall    : {rec * 100:.2f}%")
    print(f"F1-Score  : {f1 * 100:.2f}%")
    print("=" * 60)

def generate_update_sql(df_scored):
    """Generate SQL UPDATE file to write anomaly scores back to Oracle DB."""
    with open(OUTPUT_SCORES_SQL, 'w', encoding='utf-8') as f:
        f.write("-- Anomaly Scores generated by Person 3 Isolation Forest\n")
        f.write("BEGIN\n")
        for _, row in df_scored.iterrows():
            f.write(f"  UPDATE transactions SET anomaly_score = {row['anomaly_score']} WHERE txn_id = {row['txn_id']};\n")
        f.write("  COMMIT;\n")
        f.write("END;\n/\n")
    print(f"[SUCCESS] Wrote SQL update statements to: {OUTPUT_SCORES_SQL}")

def main():
    df = load_transactions()
    X, df_feat = engineer_features(df)
    model, df_scored = train_and_score(X, df_feat)
    evaluate_model(df_scored)
    generate_update_sql(df_scored)

if __name__ == '__main__':
    main()
