"""
ANOMALY DETECTION MODEL — for Currently project
================================================
Goal: Classify whether a 15-min reading is anomalous.

Key difference from teacher's approach:
  - We add "residual_kwh" (actual - expected) as a feature, which is the
    single strongest signal for catching deviations from normal behavior
  - We use class_weight="balanced" because anomalies are only ~6% of data
    (without this, model would just predict "normal" for everything and get 94% accuracy)

Model: HistGradientBoostingClassifier (supervised, because is_anomaly labels exist)
  - Precision, Recall, F1, ROC-AUC all evaluated
  - Chronological train/test split (same as prediction model, for consistency)

The prediction model (consumption_predictor.joblib) must be trained first
because we use it to generate "expected_kwh" as a feature here.
"""

import pandas as pd
import numpy as np
from sklearn.ensemble import HistGradientBoostingClassifier, HistGradientBoostingRegressor
from sklearn.metrics import (precision_score, recall_score,
                             f1_score, roc_auc_score, confusion_matrix)
import joblib

print("Loading dataset and prediction model...")
df = pd.read_csv("/home/claude/smart_home_energy_dataset.csv",
                 parse_dates=["timestamp"])

# Load the already-trained prediction model to generate "expected_kwh"
predictor = joblib.load("/home/claude/trained_models/consumption_predictor.joblib")

# ── Feature engineering ────────────────────────────────────────────────────
df["day_of_year"]  = df["timestamp"].dt.dayofyear
df["week_of_year"] = df["timestamp"].dt.isocalendar().week.astype(int)

CONTEXT_FEATURES = [
    "hour", "day_of_week", "month", "is_weekend",
    "outdoor_temp_c", "humidity_pct",
    "occupancy", "num_occupants",
    "day_of_year", "week_of_year",
]

# Generate expected consumption using the prediction model
df["expected_kwh"] = predictor.predict(df[CONTEXT_FEATURES])

# Residual: how much the actual reading deviates from expected
# This is the strongest anomaly signal (e.g. phantom load = reading >> expected)
df["residual_kwh"] = df["total_consumption_kwh"] - df["expected_kwh"] if "total_consumption_kwh" in df.columns else df["total_kwh"] - df["expected_kwh"]

# Also add voltage — voltage_fault anomaly type needs this
# Ratio of actual to expected — catches proportional deviations
df["consumption_ratio"] = df["total_kwh"] / (df["expected_kwh"] + 1e-6)

CLF_FEATURES = CONTEXT_FEATURES + [
    "total_kwh",        # actual reading
    "expected_kwh",     # what the model thought it should be
    "residual_kwh",     # difference — key anomaly signal
    "consumption_ratio",# ratio — catches proportional deviations
    "voltage",          # for voltage_fault detection
]

X = df[CLF_FEATURES]
y = df["is_anomaly"]

print(f"Total rows: {len(df):,}")
print(f"Anomalies: {y.sum():,} ({100*y.mean():.1f}%)")
print(f"Normal: {(y==0).sum():,} ({100*(y==0).mean():.1f}%)")

# ── Chronological split ────────────────────────────────────────────────────
split_idx = int(len(df) * 0.8)
X_train, X_test = X.iloc[:split_idx], X.iloc[split_idx:]
y_train, y_test = y.iloc[:split_idx], y.iloc[split_idx:]

print(f"\nTrain rows: {len(X_train):,}  |  Test rows: {len(X_test):,}")

# ── Train ──────────────────────────────────────────────────────────────────
print("\nTraining HistGradientBoostingClassifier...")
clf = HistGradientBoostingClassifier(
    max_iter=400,
    learning_rate=0.07,
    max_depth=8,
    random_state=42,
    early_stopping=True,
    validation_fraction=0.1,
    class_weight="balanced",  # critical — prevents model ignoring the 6% anomaly class
)
clf.fit(X_train, y_train)

# ── Evaluate ───────────────────────────────────────────────────────────────
pred   = clf.predict(X_test)
proba  = clf.predict_proba(X_test)[:, 1]

prec   = precision_score(y_test, pred)
rec    = recall_score(y_test, pred)
f1     = f1_score(y_test, pred)
auc    = roc_auc_score(y_test, proba)
cm     = confusion_matrix(y_test, pred)

print(f"\nAnomaly Detection Model Results:")
print(f"  Precision = {prec:.3f}  (of flagged anomalies, how many are real)")
print(f"  Recall    = {rec:.3f}  (of real anomalies, how many we catch)")
print(f"  F1        = {f1:.3f}  (balance of precision + recall)")
print(f"  ROC-AUC   = {auc:.4f}")
print(f"\nConfusion Matrix:")
print(f"  True Normal  flagged as Normal:  {cm[0][0]:,}")
print(f"  True Normal  flagged as Anomaly: {cm[0][1]:,}  (false alarms)")
print(f"  True Anomaly flagged as Normal:  {cm[1][0]:,}  (missed anomalies)")
print(f"  True Anomaly flagged as Anomaly: {cm[1][1]:,}  (correctly caught)")

# ── Save ───────────────────────────────────────────────────────────────────
joblib.dump(clf, "/home/claude/trained_models/anomaly_classifier.joblib")
print(f"\nSaved -> trained_models/anomaly_classifier.joblib")
print(f"Features used: {CLF_FEATURES}")
