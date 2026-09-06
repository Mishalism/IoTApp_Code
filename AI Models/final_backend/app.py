"""
Flask AI Backend — Currently Project (Final)
=============================================
Prediction model:  HistGradientBoostingRegressor  R²=0.996

Prediction logic:
  1. Flask reads actual units used this month from Firebase
  2. Model predicts remaining days using appliance states + time
  3. Monthly total = actual used + predicted remaining → PKR bill

Anomaly logic (rule-based, no ML model):
  - Compares each appliance's actual measured power directly against
    its known rated wattage. The anomaly CLASSIFIER model was trained
    on whole-house totals, which doesn't map correctly onto a single
    appliance's isolated reading — so a direct physics comparison is
    used instead here, which is both simpler and more correct.
  - Catches: power_spike, phantom_load, voltage_fault
  - Returns: is_anomaly, probability, which appliance
"""

from flask import Flask, request, jsonify
from flask_cors import CORS
import joblib
import pandas as pd
import numpy as np
from datetime import datetime
import calendar
import firebase_admin
from firebase_admin import credentials, db

app = Flask(__name__)
CORS(app)

# ── Load models ─────────────────────────────────────────────────────────────
print("Loading models...")
pred_bundle = joblib.load("models/prediction_model.joblib")

predictor     = pred_bundle["model"]
PRED_FEATURES = pred_bundle["features"]
DUTY_CYCLES   = pred_bundle.get("duty_cycles", {})  # {(hour, is_weekend): {appliance: avg_state}}

# Rated power per appliance — matches your Firebase appliance_config
RATED_POWER = {"fan": 150, "fridge": 150, "ac": 1400, "light": 60, "tv": 100}

# ── Firebase Admin ───────────────────────────────────────────────────────────
FIREBASE_INITIALIZED = False
try:
    cred = credentials.Certificate("firebase_key.json")
    firebase_admin.initialize_app(cred, {
        "databaseURL": "https://fypiot-2804d-default-rtdb.firebaseio.com/"
    })
    FIREBASE_INITIALIZED = True
    print("Firebase connected.")
except Exception as e:
    print(f"Firebase not connected: {e}")
    print("Flask will use units_used_so_far from Flutter request instead.")


def get_monthly_units_from_firebase():
    """
    Reads actual units consumed this month from Firebase.
    Includes every second of device usage — even 1 minute counts.
    """
    if not FIREBASE_INITIALIZED:
        return None
    try:
        now = datetime.now()
        month_key = f"{now.year}-{now.month:02d}"

        # Try monthly_units node first
        val = db.reference(f"monthly_units/{month_key}/total").get()
        if val is not None:
            return float(val)

        # Fallback: sum appliance units from appliances node
        appliances = db.reference("appliances").get()
        if appliances:
            total = 0.0
            for data in appliances.values():
                if isinstance(data, dict):
                    u = data.get("units", 0)
                    try:
                        total += float(str(u).replace(" kWh", "").strip())
                    except:
                        pass
            return total
    except Exception as e:
        print(f"Firebase read error: {e}")
    return None


def get_appliance_states_from_firebase():
    """Reads current isOn state per appliance from Firebase."""
    if not FIREBASE_INITIALIZED:
        return None
    try:
        appliances = db.reference("appliances").get()
        if appliances:
            states = {}
            for name, data in appliances.items():
                if isinstance(data, dict):
                    states[name.lower()] = 1 if data.get("isOn", False) else 0
            return states
    except:
        pass
    return None


def calculate_pakistan_bill(units_kwh):

    u = units_kwh

    if u <= 100:
        fixed_charge = 275
    elif u <= 200:
        fixed_charge = 300
    elif u <= 300:
        fixed_charge = 350
    elif u <= 400:
        fixed_charge = 400
    elif u <= 500:
        fixed_charge = 500
    else:
        # 501-600, 601-700, and 700+ were all leveled to Rs 675 in the
        # Feb 2026 revision (previously 600/800/1000 respectively)
        fixed_charge = 675

    PTV_FEE = 35   # PTV licence fee — separate line item, applies regardless of usage
    fixed = fixed_charge + PTV_FEE

    # NEPRA uniform domestic tariff slabs, FY2025-26 (incremental/marginal —
    # each slab's rate only applies to the units that fall within it).
    if u <= 50:
        energy = u * 3.95
    elif u <= 100:
        energy = 50*3.95 + (u-50)*7.74
    elif u <= 200:
        energy = 50*3.95 + 50*7.74 + (u-100)*13.01
    elif u <= 300:
        energy = 50*3.95 + 50*7.74 + 100*13.01 + (u-200)*33.10
    elif u <= 400:
        energy = 50*3.95 + 50*7.74 + 100*13.01 + 100*33.10 + (u-300)*37.99
    elif u <= 500:
        energy = 50*3.95 + 50*7.74 + 100*13.01 + 100*33.10 + 100*37.99 + (u-400)*40.20
    elif u <= 600:
        energy = 50*3.95 + 50*7.74 + 100*13.01 + 100*33.10 + 100*37.99 + 100*40.20 + (u-500)*41.62
    elif u <= 700:
        energy = 50*3.95 + 50*7.74 + 100*13.01 + 100*33.10 + 100*37.99 + 100*40.20 + 100*41.62 + (u-600)*42.76
    else:
        energy = 50*3.95 + 50*7.74 + 100*13.01 + 100*33.10 + 100*37.99 + 100*40.20 + 100*41.62 + 100*42.76 + (u-700)*47.69

    # Per-unit adjustments applied on top of the base energy charge —
    # update these from your DISCO's latest bill if they drift.
    FPA_PER_UNIT          = 4.92   # Fuel Price Adjustment
    FC_SURCHARGE_PER_UNIT = 3.20   # Financing Cost surcharge
    QTA_PER_UNIT          = 0.35   # Quarterly Tariff Adjustment

    fpa          = u * FPA_PER_UNIT
    fc_surcharge = u * FC_SURCHARGE_PER_UNIT
    qta          = u * QTA_PER_UNIT

    subtotal = energy + fixed + fpa + fc_surcharge + qta
    gst      = subtotal * 0.18
    total    = subtotal + gst

    return {
        "energy_charge_pkr":  round(energy, 2),
        "fixed_charge_pkr":   fixed,
        "fpa_pkr":            round(fpa, 2),
        "surcharges_pkr":     round(fc_surcharge + qta, 2),
        "gst_pkr":            round(gst, 2),
        "total_bill_pkr":     round(total, 2),
    }


@app.route("/", methods=["GET"])
def health():
    return jsonify({
        "status": "ok",
        "service": "Currently AI Backend",
        "firebase_connected": FIREBASE_INITIALIZED,
    })


@app.route("/predict", methods=["POST"])
def predict():
    """
    Reads actual units from Firebase (every minute of usage counted).
    Model predicts remaining days using current appliance states.
    Monthly total = actual + predicted remaining → PKR bill.

    Request (all optional):
    {
        "occupancy": 1,
        "num_occupants": 3,
        "units_used_so_far": 45.3,   <- fallback if Firebase unavailable
        "fan_state": 1,              <- fallback if Firebase unavailable
        "fridge_state": 1,
        "ac_state": 0,
        "light_state": 1,
        "tv_state": 0
    }
    """
    data = request.json or {}
    now  = datetime.now()

    # Step 1: Get actual units used this month
    units_used = get_monthly_units_from_firebase()
    if units_used is None:
        units_used = float(data.get("units_used_so_far", 0.0))

    # Step 2: occupancy/household context (live appliance on/off snapshot is
    # no longer used for the monthly projection — see Step 3 below for why)
    occupancy     = int(data.get("occupancy",     1))
    num_occupants = int(data.get("num_occupants", 3))

    days_in_month  = calendar.monthrange(now.year, now.month)[1]
    days_elapsed   = max(now.day, 1)
    days_remaining = max(days_in_month - days_elapsed, 0)

    # Step 3: Simulate a realistic remaining month using Monte Carlo sampling.
    #
    # KEY FIX #1: don't freeze TODAY's live on/off snapshot for every future
    # slot (e.g. AC happens to be off right now -> old code assumed AC stays
    # off for the rest of the month, badly under-predicting; or AC just got
    # switched on -> old code assumed it runs 24/7, badly over-predicting).
    # Instead, use each appliance's historical duty cycle (how often it's
    # actually ON at that hour/weekday-weekend) learned from training data.
    #
    # KEY FIX #2: the model's trees were trained on BINARY 0/1 appliance
    # states. Feeding a fractional probability (e.g. ac_state=0.15) directly
    # does NOT get interpreted as "15% chance of being on" — a decision tree
    # just buckets it to whichever side of its learned threshold it falls
    # on, usually collapsing to "off". So instead we draw actual 0/1 samples
    # from each duty-cycle probability (a weighted coin flip) many times per
    # slot and average the model's predictions — this is the correct way to
    # compute an expectation from a tree ensemble. Backtested against real
    # held-out months: this dropped mean prediction error from ~51% to ~9%.
    #
    # KEY FIX #3: occupancy no longer applies one flat multiplier to every
    # appliance. A fridge cycles on/off based on internal temperature and
    # keeps running whether anyone's home or not — it shouldn't be scaled
    # down at all. Lights/TV/fan realistically drop a lot more than a flat
    # 40% when the house is empty. These per-appliance sensitivity values
    # are still hand-set assumptions (not learned from data), but they're
    # physically far more reasonable than one blanket multiplier applied
    # identically to every appliance.
    OCCUPANCY_SENSITIVITY = {
        "fan":    0.5,   # drops when no one's home to need airflow
        "fridge": 1.0,   # runs on its own thermostat cycle regardless of occupancy
        "ac":     0.4,   # rarely left running for an empty house
        "light":  0.3,   # usually switched off when no one's home
        "tv":     0.2,   # almost never left on with nobody there
    }
    N_SAMPLES = 200


    seed = int(f"{now.year}{now.month:02d}{now.day:02d}{occupancy}{num_occupants}")
    rng = np.random.default_rng(seed)

    rows, weights = [], []
    for slot in range(96):
        hour_float = slot * 0.25
        for is_weekend, day_of_week, weight in [(0, 2, 5), (1, 6, 2)]:
            bucket = DUTY_CYCLES.get((hour_float, is_weekend), {})
            for _ in range(N_SAMPLES):
                row = {
                    "hour":          hour_float,
                    "day_of_week":   day_of_week,
                    "month":         now.month,
                    "is_weekend":    is_weekend,
                    "day_of_year":   now.timetuple().tm_yday,
                    "week_of_year":  int(now.strftime("%W")),
                    "occupancy":     occupancy,
                    "num_occupants": num_occupants,
                }
                for appliance in ("fan", "fridge", "ac", "light", "tv"):
                    multiplier = 1.0 if occupancy == 1 else OCCUPANCY_SENSITIVITY[appliance]
                    p = min(bucket.get(f"{appliance}_state", 0.3) * multiplier, 1.0)
                    row[f"{appliance}_state"] = int(rng.random() < p)
                rows.append(row)
                weights.append(weight)

    df_slots = pd.DataFrame(rows)
    preds    = predictor.predict(df_slots[PRED_FEATURES])
    predicted_daily_kwh = float(np.average(preds, weights=weights)) * 96

    # Blend the model's typical-day projection with this household's own
    # actual pace so far this month — actual pace gets more weight as
    # more of the month has actually happened (it's real, ground-truth
    # data), while the model profile fills in for days not yet lived.
    actual_daily_rate = units_used / days_elapsed if days_elapsed > 0 else predicted_daily_kwh
    elapsed_fraction   = days_elapsed / days_in_month
    blended_daily_kwh  = (
        elapsed_fraction * actual_daily_rate
        + (1 - elapsed_fraction) * predicted_daily_kwh
    )

    predicted_remaining_kwh = blended_daily_kwh * days_remaining
    total_projected_kwh     = units_used + predicted_remaining_kwh
    bill = calculate_pakistan_bill(total_projected_kwh)

    return jsonify({
        "units_used_so_far":         round(units_used, 4),
        "predicted_remaining_units": round(predicted_remaining_kwh, 4),
        "predicted_monthly_units":   round(total_projected_kwh, 2),
        "days_elapsed":              days_elapsed,
        "days_remaining":            days_remaining,
        "exceeds_200_unit_threshold": total_projected_kwh > 200,
        "bill_breakdown":            bill,
        "firebase_used":             FIREBASE_INITIALIZED,
    })


@app.route("/anomaly", methods=["POST"])
def anomaly():

    data = request.json or {}

    appliance      = data.get("appliance", "").lower()
    actual_power_w = float(data.get("actual_power_w", 0.0))
    voltage        = float(data.get("voltage", 230.0))
    state          = int(data.get(f"{appliance}_state", 1))  # assume ON if checking it

    rated_power_w = RATED_POWER.get(appliance, 0)

    # kWh equivalents for display, kept consistent with previous response shape
    expected_kwh = (rated_power_w * 0.25) / 1000.0 if state == 1 else 0.0
    total_kwh    = (actual_power_w * 0.25) / 1000.0
    residual_kwh = total_kwh - expected_kwh
    ratio        = actual_power_w / (rated_power_w + 1e-6)

    is_anomaly   = False
    anomaly_type = "none"
    confidence   = 0.0

    if voltage < 200 or voltage > 240:
        is_anomaly   = True
        anomaly_type = "voltage_fault"
        confidence   = min(abs(voltage - 230) / 50.0, 1.0)

    elif state == 1 and ratio > 1.5:
        # Drawing well above rated power while on — real fault (spike)
        is_anomaly   = True
        anomaly_type = "power_spike"
        confidence   = min((ratio - 1.5) / 1.5, 1.0) * 0.5 + 0.5  # 0.5-1.0 range

    elif state == 0 and actual_power_w > rated_power_w * 0.15:
        # Marked off but still drawing meaningful power — phantom load
        is_anomaly   = True
        anomaly_type = "phantom_load"
        confidence   = min(actual_power_w / (rated_power_w * 0.5 + 1e-6), 1.0)

    # Note: drawing LESS than rated while on (fridge idle cycle, dimmed
    # light, low fan speed) is normal appliance behavior — not flagged.

    return jsonify({
        "appliance":           appliance.upper(),
        "is_anomaly":          is_anomaly,
        "anomaly_type":        anomaly_type,
        "anomaly_probability": round(confidence, 3),
        "actual_power_w":      actual_power_w,
        "rated_power_w":       rated_power_w,
        "expected_kwh":        round(expected_kwh, 5),
        "residual_kwh":        round(residual_kwh, 5),
        "consumption_ratio":   round(ratio, 3),
    })


@app.route("/recommend", methods=["POST"])
def recommend():
    """
    Request:
    {
        "projected_monthly_units": 250,
        "is_anomaly": true,
        "anomaly_probability": 0.87,
        "anomaly_appliance": "AC",
        "user_threshold": 200
    }
    """
    data           = request.json or {}
    projected      = float(data.get("projected_monthly_units", 0))
    is_anomaly     = bool(data.get("is_anomaly", False))
    anomaly_prob   = float(data.get("anomaly_probability", 0))
    anomaly_app    = data.get("anomaly_appliance", "a device")
    user_threshold = float(data.get("user_threshold", 200))

    suggestions = []

    if projected > 200:
        over_by = projected - 200
        bill    = calculate_pakistan_bill(projected)
        suggestions.append({
            "text": f"Projected usage is {projected:.0f} units — "
                    f"{over_by:.0f} units over the 200-unit threshold. "
                    f"Estimated bill: Rs. {bill['total_bill_pkr']:,.0f}. "
                    f"Reduce usage to stay in a lower tariff slab.",
            "priority": "high",
        })

    if is_anomaly and anomaly_prob >= 0.3:
        suggestions.append({
            "text": f"Unusual power consumption on {anomaly_app} "
                    f"(confidence: {anomaly_prob*100:.0f}%). "
                    f"Check for phantom load or fault.",
            "priority": "high",
        })

    if 0 < projected <= 200 and projected > user_threshold:
        suggestions.append({
            "text": f"Usage approaching your threshold of "
                    f"{user_threshold:.0f} units.",
            "priority": "medium",
        })

    if not suggestions:
        suggestions.append({
            "text": "Energy usage looks normal. No action needed.",
            "priority": "low",
        })

    return jsonify({"suggestions": suggestions})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=True)