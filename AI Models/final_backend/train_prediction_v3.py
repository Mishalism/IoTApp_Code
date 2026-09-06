"""
PREDICTION MODEL — Currently Project (v2 dataset)
===================================================
Goal: Predict total_kwh per 15-min slot.
Flask uses this to predict remaining days of month,
then adds actual units already used from Firebase
to get projected monthly total → PKR bill.

Features used:
  - Time: hour, day_of_week, month, is_weekend, day_of_year, week_of_year
  - Occupancy: occupancy, num_occupants
  - Appliance states: fan_state, fridge_state, ac_state, light_state, tv_state
    (these come directly from Firebase isOn fields)

Trained only on non-anomalous rows so model learns normal usage.
Chronological 80/20 split — no future data leakage.
"""

import pandas as pd
import numpy as np
from sklearn.ensemble import HistGradientBoostingRegressor
from sklearn.metrics import mean_absolute_error, r2_score, mean_squared_error
import joblib

print("Loading dataset...")
df = pd.read_csv("/home/claude/smart_home_energy_dataset_v2.csv",
                 parse_dates=["timestamp"])

# Train only on normal rows
df_clean = df[df["is_anomaly"] == 0].copy()
print(f"Total rows: {len(df):,} | Normal rows used: {len(df_clean):,} | Anomalous excluded: {len(df)-len(df_clean):,}")

# Features — all directly available from your Firebase
FEATURES = [
    # Time
    "hour", "day_of_week", "month", "is_weekend",
    "day_of_year", "week_of_year",
    # Occupancy
    "occupancy", "num_occupants",
    # Appliance ON/OFF states — mirrors Firebase isOn per appliance
    "fan_state", "fridge_state", "ac_state", "light_state", "tv_state",
]

TARGET = "total_kwh"

X = df_clean[FEATURES]
y = df_clean[TARGET]

# Chronological split — model never sees future data during training
split_idx = int(len(df_clean) * 0.8)
X_train, X_test = X.iloc[:split_idx], X.iloc[split_idx:]
y_train, y_test = y.iloc[:split_idx], y.iloc[split_idx:]

print(f"\nTrain: {len(X_train):,} rows | Test: {len(X_test):,} rows")

print("\nTraining HistGradientBoostingRegressor...")
model = HistGradientBoostingRegressor(
    max_iter=400,
    learning_rate=0.07,
    max_depth=8,
    random_state=42,
    early_stopping=True,
    validation_fraction=0.1,
)
model.fit(X_train, y_train)

preds = model.predict(X_test)
mae   = mean_absolute_error(y_test, preds)
rmse  = mean_squared_error(y_test, preds) ** 0.5
r2    = r2_score(y_test, preds)

print(f"\nPrediction Model Results:")
print(f"  MAE  = {mae:.5f} kWh per 15-min slot")
print(f"  RMSE = {rmse:.5f} kWh")
print(f"  R²   = {r2:.4f}")

# Sanity check: simulate a full month prediction
avg_slot = float(preds.mean())
monthly  = avg_slot * 96 * 30
print(f"\nSanity check:")
print(f"  Avg predicted slot: {avg_slot:.5f} kWh")
print(f"  Full month (30 days x 96 slots): {monthly:.2f} kWh")
print(f"  200-unit threshold: {'EXCEEDED' if monthly > 200 else 'within limit'}")

# ── Historical duty-cycle profiles ──────────────────────────────────────
# Instead of assuming an appliance's CURRENT on/off state holds for the
# rest of the month, store how often each appliance is actually ON at
# each (hour, is_weekend) bucket. Flask uses these to simulate a
# realistic remaining month instead of freezing today's snapshot state.
appliance_cols = ["fan_state", "fridge_state", "ac_state", "light_state", "tv_state"]
duty_cycles = (
    df_clean.groupby(["hour", "is_weekend"])[appliance_cols]
    .mean()
    .to_dict(orient="index")
)
# duty_cycles: {(hour, is_weekend): {"fan_state": 0.34, "ac_state": 0.02, ...}}

joblib.dump(
    {"model": model, "features": FEATURES, "duty_cycles": duty_cycles},
    "/home/claude/trained_models_v2/prediction_model.joblib",
)
print(f"\nSaved -> trained_models_v2/prediction_model.joblib")
print(f"Features: {FEATURES}")
print(f"Duty-cycle buckets saved: {len(duty_cycles)}")