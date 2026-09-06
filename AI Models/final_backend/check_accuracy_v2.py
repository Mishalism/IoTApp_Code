"""
Accuracy check for the CURRENT v2 models (no retraining):
  models/prediction_model.joblib   (bundle: {"model", "features"})
  models/anomaly_model.joblib      (bundle: {"model", "features"})

Reproduces the exact same feature engineering + chronological 80/20
split used in train_prediction_v3.py and train_anomaly_v3.py.
"""
import pandas as pd
import joblib
from sklearn.metrics import (
    mean_absolute_error, mean_squared_error, r2_score,
    precision_score, recall_score, f1_score, roc_auc_score, confusion_matrix
)

CSV_PATH = "smart_home_energy_dataset_v2.csv"   # must be in this same folder
PRED_MODEL_PATH = "models/prediction_model.joblib"
ANOM_MODEL_PATH = "models/anomaly_model.joblib"

print("Loading dataset...")
df = pd.read_csv(CSV_PATH, parse_dates=["timestamp"])

pred_bundle = joblib.load(PRED_MODEL_PATH)
predictor      = pred_bundle["model"]
PRED_FEATURES  = pred_bundle["features"]

anom_bundle = joblib.load(ANOM_MODEL_PATH)
clf            = anom_bundle["model"]
CLF_FEATURES   = anom_bundle["features"]

# ── 1. Prediction model accuracy ────────────────────────────────────────
df_clean = df[df["is_anomaly"] == 0].copy()
X = df_clean[PRED_FEATURES]
y = df_clean["total_kwh"]

split_idx = int(len(df_clean) * 0.8)
X_test = X.iloc[split_idx:]
y_test = y.iloc[split_idx:]

preds = predictor.predict(X_test)
mae   = mean_absolute_error(y_test, preds)
rmse  = mean_squared_error(y_test, preds) ** 0.5
r2    = r2_score(y_test, preds)

print("\n=== Prediction Model ===")
print(f"Test rows: {len(X_test):,}")
print(f"MAE  = {mae:.5f} kWh per 15-min slot")
print(f"RMSE = {rmse:.5f} kWh")
print(f"R2   = {r2:.4f}  (closer to 1.0 is better)")

# ── 2. Anomaly model accuracy ────────────────────────────────────────────
df["expected_kwh"]      = predictor.predict(df[PRED_FEATURES])
df["residual_kwh"]      = df["total_kwh"] - df["expected_kwh"]
df["consumption_ratio"] = df["total_kwh"] / (df["expected_kwh"] + 1e-6)

for app in ["fan", "fridge", "ac", "light", "tv"]:
    power_col = f"{app}_power_w"
    rated_col = f"{app}_rated_w"
    state_col = f"{app}_state"
    df[f"{app}_power_ratio"] = (
        df[power_col] / (df[rated_col] + 1e-6)
    ).where(df[state_col] == 1, 0)
    df[f"{app}_deviation_w"] = (
        (df[power_col] - df[rated_col]).abs()
    ).where(df[state_col] == 1, 0)

Xc = df[CLF_FEATURES]
yc = df["is_anomaly"]

split_idx_c = int(len(df) * 0.8)
Xc_test = Xc.iloc[split_idx_c:]
yc_test = yc.iloc[split_idx_c:]

proba = clf.predict_proba(Xc_test)[:, 1]
pred  = (proba >= 0.3).astype(int)   # matches app.py's threshold

prec = precision_score(yc_test, pred)
rec  = recall_score(yc_test, pred)
f1   = f1_score(yc_test, pred)
auc  = roc_auc_score(yc_test, proba)
cm   = confusion_matrix(yc_test, pred)
tn, fp, fn, tp = cm.ravel()

print("\n=== Anomaly Model (threshold=0.3, matches app.py) ===")
print(f"Test rows: {len(Xc_test):,}")
print(f"Precision = {prec:.3f}")
print(f"Recall    = {rec:.3f}")
print(f"F1        = {f1:.3f}")
print(f"ROC-AUC   = {auc:.4f}")
print("\nConfusion Matrix:")
print(f"  True Normal  -> Normal:  {tn:,}")
print(f"  True Normal  -> Anomaly: {fp:,}  (false alarms)")
print(f"  True Anomaly -> Normal:  {fn:,}  (missed)")
print(f"  True Anomaly -> Anomaly: {tp:,}  (correctly caught)")

print("\nThreshold comparison:")
print(f"{'Threshold':<12}{'FalseAlarms':<14}{'Missed':<10}{'Caught':<10}{'Recall':<10}{'Precision'}")
for t in [0.2, 0.3, 0.4, 0.5]:
    p = (proba >= t).astype(int)
    c = confusion_matrix(yc_test, p).ravel()
    tn2, fp2, fn2, tp2 = c
    print(f"{t:<12}{fp2:<14}{fn2:<10}{tp2:<10}"
          f"{recall_score(yc_test, p):<10.3f}"
          f"{precision_score(yc_test, p):.3f}")
