"""
PREDICTION MODEL — for Currently project
========================================
Goal: Predict total_kwh for a 15-min slot given time + context features.
The Flask API will use this to:
  1. Predict expected kWh for the current 15-min window
  2. Project monthly units (kWh) by scaling up
  3. Calculate estimated monthly bill using Pakistan slab tariff

Model: HistGradientBoostingRegressor (scikit-learn built-in)
  - Handles missing values natively
  - No need to normalize features
  - Fast, accurate, easy to pickle

Train/test split: CHRONOLOGICAL (first 80% of days = train, last 20% = test)
  - Correct for time-series: model never sees "future" data during training
  - More realistic evaluation than random split
"""

import pandas as pd
import numpy as np
from sklearn.ensemble import HistGradientBoostingRegressor
from sklearn.metrics import mean_absolute_error, r2_score, mean_squared_error
import joblib

# ── Pakistan slab tariff (NEPRA 2024-25, residential) ──────────────────────
def calculate_pakistan_bill(units_kwh):
    """
    Calculates monthly electricity bill in PKR using Pakistan's
    residential slab-based tariff system.
    Returns dict with breakdown.
    """
    u = units_kwh
    bill = 0

    if u <= 50:
        bill = u * 3.95
    elif u <= 100:
        bill = 50 * 3.95 + (u - 50) * 7.74
    elif u <= 200:
        bill = 50 * 3.95 + 50 * 7.74 + (u - 100) * 10.06
    elif u <= 300:
        bill = 50 * 3.95 + 50 * 7.74 + 100 * 10.06 + (u - 200) * 12.15
    elif u <= 400:
        bill = 50 * 3.95 + 50 * 7.74 + 100 * 10.06 + 100 * 12.15 + (u - 300) * 17.59
    elif u <= 500:
        bill = 50 * 3.95 + 50 * 7.74 + 100 * 10.06 + 100 * 12.15 + 100 * 17.59 + (u - 400) * 20.84
    elif u <= 600:
        bill = 50 * 3.95 + 50 * 7.74 + 100 * 10.06 + 100 * 12.15 + 100 * 17.59 + 100 * 20.84 + (u - 500) * 22.65
    elif u <= 700:
        bill = 50 * 3.95 + 50 * 7.74 + 100 * 10.06 + 100 * 12.15 + 100 * 17.59 + 100 * 20.84 + 100 * 22.65 + (u - 600) * 23.17
    else:
        bill = 50 * 3.95 + 50 * 7.74 + 100 * 10.06 + 100 * 12.15 + 100 * 17.59 + 100 * 20.84 + 100 * 22.65 + 100 * 23.17 + (u - 700) * 24.16

    # Fixed charges + taxes (FC + GST 18% + FCA estimate)
    fixed_charge = 75
    gst = bill * 0.18
    total = bill + fixed_charge + gst
    return {
        "energy_charge_pkr": round(bill, 2),
        "fixed_charge_pkr": fixed_charge,
        "gst_pkr": round(gst, 2),
        "total_bill_pkr": round(total, 2)
    }


print("Loading dataset...")
df = pd.read_csv("/home/claude/smart_home_energy_dataset.csv",
                 parse_dates=["timestamp"])

# ── Feature engineering ────────────────────────────────────────────────────
# Use only NON-anomalous rows for training the regressor
# so it learns "normal expected consumption", not corrupted readings
df_clean = df[df["is_anomaly"] == 0].copy()

df_clean["day_of_year"] = df_clean["timestamp"].dt.dayofyear
df_clean["week_of_year"] = df_clean["timestamp"].dt.isocalendar().week.astype(int)

FEATURES = [
    "hour",           # 0.0–23.75 (float because 15-min intervals)
    "day_of_week",    # 0=Mon ... 6=Sun
    "month",          # 1–12
    "is_weekend",     # 0 or 1
    "outdoor_temp_c", # ambient temperature — big driver of HVAC usage
    "humidity_pct",   # affects AC load
    "occupancy",      # 0/1 whether anyone is home
    "num_occupants",  # number of people home
    "day_of_year",    # captures seasonal drift
    "week_of_year",   # smoother seasonal signal
]

TARGET = "total_kwh"

X = df_clean[FEATURES]
y = df_clean[TARGET]

# ── Chronological train/test split ─────────────────────────────────────────
# Sort by timestamp, take first 80% as train, last 20% as test
# This prevents future data leaking into training (correct for time-series)
split_idx = int(len(df_clean) * 0.8)
X_train, X_test = X.iloc[:split_idx], X.iloc[split_idx:]
y_train, y_test = y.iloc[:split_idx], y.iloc[split_idx:]

print(f"Training rows: {len(X_train):,}  |  Test rows: {len(X_test):,}")

# ── Train model ────────────────────────────────────────────────────────────
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

# ── Evaluate ───────────────────────────────────────────────────────────────
preds = model.predict(X_test)
mae  = mean_absolute_error(y_test, preds)
rmse = mean_squared_error(y_test, preds) ** 0.5
r2   = r2_score(y_test, preds)

print(f"\nPrediction Model Results:")
print(f"  MAE  = {mae:.4f} kWh per 15-min slot")
print(f"  RMSE = {rmse:.4f} kWh")
print(f"  R²   = {r2:.4f}")

# ── Monthly projection sanity check ────────────────────────────────────────
# A 15-min slot * 96 slots/day * 30 days = monthly total
avg_slot_kwh = float(preds.mean())
projected_monthly_units = avg_slot_kwh * 96 * 30
bill = calculate_pakistan_bill(projected_monthly_units)

print(f"\nSanity check (using average predicted slot):")
print(f"  Avg predicted per slot: {avg_slot_kwh:.4f} kWh")
print(f"  Projected monthly units: {projected_monthly_units:.1f} kWh")
print(f"  Estimated bill (PKR): {bill['total_bill_pkr']:,.0f}")
print(f"  (200-unit threshold: {'EXCEEDED' if projected_monthly_units > 200 else 'within limit'})")

# ── Save ───────────────────────────────────────────────────────────────────
joblib.dump(model, "/home/claude/trained_models/consumption_predictor.joblib")
print(f"\nSaved -> trained_models/consumption_predictor.joblib")
print(f"Features used: {FEATURES}")
