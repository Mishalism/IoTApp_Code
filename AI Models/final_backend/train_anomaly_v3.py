"""
ANOMALY DETECTION MODEL — Currently Project (v2 dataset)
=========================================================
Goal: Detect anomalous appliance readings.

Key advantage of v2 dataset:
  - Has anomaly_appliance column — knows WHICH appliance is anomalous
  - Has rated_w per appliance — can calculate power deviation
  - Has actual power_w per appliance — direct comparison to rated

Features include:
  - Per-appliance power deviation (actual vs rated) — strongest signal
  - Time context
  - Voltage — catches voltage_fault type anomalies
  - Appliance states

Two outputs:
  1. is_anomaly: bool
  2. anomaly_probability: 0-1 confidence

Trained on ALL rows (normal + anomalous) with class_weight=balanced.
Chronological split — no future leakage.
"""

import pandas as pd
import numpy as np
from sklearn.ensemble import HistGradientBoostingClassifier
from sklearn.metrics import (precision_score, recall_score,
                             f1_score, roc_auc_score, confusion_matrix)
import joblib

print("Loading dataset and prediction model...")
df = pd.read_csv("/home/claude/smart_home_energy_dataset_v2.csv",
                 parse_dates=["timestamp"])

# Load prediction model to generate expected_kwh feature
pred_bundle = joblib.load("/home/claude/trained_models_v2/prediction_model.joblib")
predictor   = pred_bundle["model"]
PRED_FEATURES = pred_bundle["features"]

# Generate expected consumption
df["expected_kwh"]      = predictor.predict(df[PRED_FEATURES])
df["residual_kwh"]      = df["total_kwh"] - df["expected_kwh"]
df["consumption_ratio"] = df["total_kwh"] / (df["expected_kwh"] + 1e-6)

# Per-appliance power deviation features
# These are the most direct anomaly signals:
# If fan is on but drawing 3x its rated power → anomaly
for app in ["fan", "fridge", "ac", "light", "tv"]:
    power_col = f"{app}_power_w"
    rated_col = f"{app}_rated_w"
    state_col = f"{app}_state"
    df[f"{app}_power_ratio"] = (
        df[power_col] / (df[rated_col] + 1e-6)
    ).where(df[state_col] == 1, 0)  # 0 when off — not anomalous to draw nothing when off
    df[f"{app}_deviation_w"] = (
        (df[power_col] - df[rated_col]).abs()
    ).where(df[state_col] == 1, 0)

CLF_FEATURES = [
    # Time
    "hour", "day_of_week", "month", "is_weekend",
    # Occupancy
    "occupancy", "num_occupants",
    # Appliance states
    "fan_state", "fridge_state", "ac_state", "light_state", "tv_state",
    # Total consumption vs expected
    "total_kwh", "expected_kwh", "residual_kwh", "consumption_ratio",
    # Voltage — catches voltage_fault
    "voltage",
    # Per-appliance deviation — strongest anomaly signals
    "fan_power_ratio", "fridge_power_ratio", "ac_power_ratio",
    "light_power_ratio", "tv_power_ratio",
    "fan_deviation_w", "fridge_deviation_w", "ac_deviation_w",
    "light_deviation_w", "tv_deviation_w",
]

X = df[CLF_FEATURES]
y = df["is_anomaly"]

print(f"Total rows: {len(df):,}")
print(f"Anomalies: {y.sum():,} ({y.mean()*100:.1f}%)")
print(f"Normal:    {(y==0).sum():,} ({(y==0).mean()*100:.1f}%)")

# Chronological split
split_idx = int(len(df) * 0.8)
X_train, X_test = X.iloc[:split_idx], X.iloc[split_idx:]
y_train, y_test = y.iloc[:split_idx], y.iloc[split_idx:]
print(f"\nTrain: {len(X_train):,} | Test: {len(X_test):,}")

print("\nTraining HistGradientBoostingClassifier...")
clf = HistGradientBoostingClassifier(
    max_iter=400,
    learning_rate=0.07,
    max_depth=8,
    random_state=42,
    early_stopping=True,
    validation_fraction=0.1,
    class_weight="balanced",
)
clf.fit(X_train, y_train)

proba  = clf.predict_proba(X_test)[:, 1]
pred   = (proba >= 0.3).astype(int)

prec   = precision_score(y_test, pred)
rec    = recall_score(y_test, pred)
f1     = f1_score(y_test, pred)
auc    = roc_auc_score(y_test, proba)
cm     = confusion_matrix(y_test, pred)
tn, fp, fn, tp = cm.ravel()

print(f"\nAnomaly Detection Results (threshold=0.3):")
print(f"  Precision = {prec:.3f}")
print(f"  Recall    = {rec:.3f}")
print(f"  F1        = {f1:.3f}")
print(f"  ROC-AUC   = {auc:.4f}")
print(f"\nConfusion Matrix:")
print(f"  True Normal  → Normal:  {tn:,}")
print(f"  True Normal  → Anomaly: {fp:,}  (false alarms)")
print(f"  True Anomaly → Normal:  {fn:,}  (missed)")
print(f"  True Anomaly → Anomaly: {tp:,}  (correctly caught)")

# Show results at different thresholds so user can compare
print("\nThreshold comparison:")
print(f"{'Threshold':<12}{'False Alarms':<15}{'Missed':<12}{'Caught':<12}{'Recall':<10}{'Precision'}")
for t in [0.2, 0.3, 0.4, 0.5]:
    p = (proba >= t).astype(int)
    c = confusion_matrix(y_test, p).ravel()
    tn2,fp2,fn2,tp2 = c
    print(f"{t:<12}{fp2:<15}{fn2:<12}{tp2:<12}"
          f"{recall_score(y_test,p):<10.3f}"
          f"{precision_score(y_test,p):.3f}")

joblib.dump({"model": clf, "features": CLF_FEATURES},
            "/home/claude/trained_models_v2/anomaly_model.joblib")
print(f"\nSaved → trained_models_v2/anomaly_model.joblib")
