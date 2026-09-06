import 'dart:convert';
import 'package:http/http.dart' as http;

class AIService {
  static const String baseUrl = "http://10.0.2.2:5000"; // change for real device

  static Future<Map<String, dynamic>> getPrediction({
    int occupancy      = 1,
    int numOccupants   = 3,
    double unitsUsedSoFar = 0.0, // fallback if Firebase Admin unavailable
    int fanState    = 1,
    int fridgeState = 1,
    int acState     = 0,
    int lightState  = 1,
    int tvState     = 0,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/predict'),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({
        "occupancy":        occupancy,
        "num_occupants":    numOccupants,
        "units_used_so_far": unitsUsedSoFar,
        "fan_state":        fanState,
        "fridge_state":     fridgeState,
        "ac_state":         acState,
        "light_state":      lightState,
        "tv_state":         tvState,
      }),
    ).timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      throw Exception("Prediction failed: ${response.body}");
    }
    return jsonDecode(response.body);
  }

  static Future<Map<String, dynamic>> checkAnomaly({
    required String appliance,
    required double actualPowerW,
    required double totalKwh,
    required double voltage,
    int fanState    = 0,
    int fridgeState = 1,
    int acState     = 0,
    int lightState  = 0,
    int tvState     = 0,
    int occupancy   = 1,
    int numOccupants = 3,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/anomaly'),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({
        "appliance":      appliance,
        "actual_power_w": actualPowerW,
        "total_kwh":      totalKwh,
        "voltage":        voltage,
        "fan_state":      fanState,
        "fridge_state":   fridgeState,
        "ac_state":       acState,
        "light_state":    lightState,
        "tv_state":       tvState,
        "occupancy":      occupancy,
        "num_occupants":  numOccupants,
      }),
    ).timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) {
      throw Exception("Anomaly check failed: ${response.body}");
    }
    return jsonDecode(response.body);
  }

  static Future<List<dynamic>> getRecommendations({
    double projectedMonthlyUnits = 0,
    bool isAnomaly               = false,
    double anomalyProbability    = 0,
    String anomalyAppliance      = "a device",
    double userThreshold         = 200,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/recommend'),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({
        "projected_monthly_units": projectedMonthlyUnits,
        "is_anomaly":              isAnomaly,
        "anomaly_probability":     anomalyProbability,
        "anomaly_appliance":       anomalyAppliance,
        "user_threshold":          userThreshold,
      }),
    ).timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) {
      throw Exception("Recommendation failed: ${response.body}");
    }
    return jsonDecode(response.body)["suggestions"];
  }
}
