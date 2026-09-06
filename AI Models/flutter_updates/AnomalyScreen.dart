import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'AppDrawer.dart';
import 'AIService.dart';
import 'NotificationManager.dart';

class AnomalyScreen extends StatefulWidget {
  const AnomalyScreen({super.key});
  @override
  State<AnomalyScreen> createState() => _AnomalyScreenState();
}

class _AnomalyScreenState extends State<AnomalyScreen> {
  bool loading = true;
  String? error;
  List<Map<String, dynamic>> anomalies = [];

  @override
  void initState() { super.initState(); _check(); }

  Future<void> _check() async {
    setState(() { loading = true; error = null; });
    try {
      // Pull current appliance snapshot from Firebase
      final snapshot = await FirebaseDatabase.instance.ref("appliances").get();
      if (!snapshot.exists) {
        setState(() { anomalies = []; loading = false; });
        return;
      }

      final raw = Map<String, dynamic>.from(snapshot.value as Map);
      final found = <Map<String, dynamic>>[];

      for (final entry in raw.entries) {
        final name = entry.key;
        if (entry.value is! Map) continue;
        final data = Map<String, dynamic>.from(entry.value);

        final bool isOn = data["isOn"] ?? false;
        if (!isOn) continue;

        // Get total kWh from Firebase units field (already tracked per appliance)
        final units = _parseDouble(data["units"]) ?? 0.0;
        // Get voltage if available
        final voltage = _parseDouble(data["voltage"]) ?? 220.0;

        // Call anomaly endpoint with this appliance's current reading
        final result = await AIService.checkAnomaly(
          totalKwh: units,
          voltage: voltage,
        );

        if (result["is_anomaly"] == true) {
          found.add({
            "appliance":         name,
            "total_kwh":         units,
            "expected_kwh":      result["expected_kwh"],
            "residual_kwh":      result["residual_kwh"],
            "anomaly_probability": result["anomaly_probability"],
            "consumption_ratio": result["consumption_ratio"],
          });

          // Push alert notification (with cooldown)
          NotificationManager().generateAndPushRecommendations(
            predictedUnits: 0,
            projectedMonthly: 0,
            isAnomaly: true,
            anomalyAppliance: name,
          );
        }
      }

      setState(() { anomalies = found; loading = false; });
    } catch (e) {
      setState(() { error = "Could not reach anomaly service.\n$e"; loading = false; });
    }
  }

  double? _parseDouble(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    if (v is String) {
      final m = RegExp(r"[\d.]+").firstMatch(v);
      return m != null ? double.tryParse(m.group(0)!) : null;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: const Text("Anomalies", style: TextStyle(color: Colors.white)),
        backgroundColor: const Color.fromARGB(255, 30, 58, 138),
        leading: Builder(builder: (ctx) => IconButton(
          icon: const Icon(Icons.menu),
          onPressed: () => Scaffold.of(ctx).openDrawer(),
        )),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _check)],
      ),
      drawer: const AppDrawer(currentIndex: 5),
      body: loading
        ? const Center(child: CircularProgressIndicator())
        : error != null
          ? Center(child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Icon(Icons.cloud_off, size: 48, color: Colors.grey),
                const SizedBox(height: 12),
                Text(error!, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                ElevatedButton(onPressed: _check, child: const Text("Retry")),
              ]),
            ))
          : RefreshIndicator(
              onRefresh: _check,
              child: anomalies.isEmpty
                ? ListView(children: [Padding(
                    padding: const EdgeInsets.only(top: 100),
                    child: Column(children: [
                      Icon(Icons.check_circle_outline, size: 56, color: Colors.green.shade400),
                      const SizedBox(height: 12),
                      Text("No anomalies detected",
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600,
                          color: isDark ? Colors.white70 : Colors.black54)),
                    ]),
                  )])
                : ListView(
                    padding: const EdgeInsets.all(20),
                    children: [
                      Text("Detected Anomalies",
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white : Colors.black87)),
                      const SizedBox(height: 20),
                      ...anomalies.map((a) => Padding(
                        padding: const EdgeInsets.only(bottom: 18),
                        child: _card(a, isDark),
                      )),
                    ],
                  ),
            ),
    );
  }

  Widget _card(Map<String, dynamic> a, bool isDark) {
    final name     = a["appliance"];
    final actual   = (a["total_kwh"] as num).toDouble();
    final expected = (a["expected_kwh"] as num).toDouble();
    final residual = (a["residual_kwh"] as num).toDouble();
    final prob     = (a["anomaly_probability"] as num).toDouble();
    final ratio    = (a["consumption_ratio"] as num).toDouble();

    return Card(
      elevation: 3,
      color: isDark ? Colors.grey[850] : Colors.red.shade50,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(15),
        side: BorderSide(color: isDark ? Colors.grey.shade700 : Colors.white)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(_iconFor(name), color: Colors.red.shade400, size: 28),
            const SizedBox(width: 10),
            Expanded(child: Text("$name — Unusual Reading",
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold,
                color: Colors.red.shade700))),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.red.shade100,
                borderRadius: BorderRadius.circular(8)),
              child: Text("${(prob * 100).toStringAsFixed(0)}% confidence",
                style: TextStyle(fontSize: 12, color: Colors.red.shade800,
                  fontWeight: FontWeight.bold)),
            ),
          ]),
          const SizedBox(height: 12),
          _row("Actual reading", "${actual.toStringAsFixed(4)} kWh", isDark),
          _row("Expected reading", "${expected.toStringAsFixed(4)} kWh", isDark),
          _row("Deviation", "${residual > 0 ? '+' : ''}${residual.toStringAsFixed(4)} kWh", isDark),
          _row("Consumption ratio", "${ratio.toStringAsFixed(2)}x normal", isDark),
          const SizedBox(height: 10),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.lightbulb_outline_rounded, size: 16, color: Colors.amber),
            const SizedBox(width: 5),
            Expanded(child: Text(
              "Suggestion: Check $name for phantom load, faulty component, or unusual usage.",
              style: TextStyle(fontSize: 13,
                color: isDark ? Colors.white60 : Colors.grey[800]))),
          ]),
        ]),
      ),
    );
  }

  Widget _row(String label, String value, bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(label, style: TextStyle(fontSize: 13,
          color: isDark ? Colors.white60 : Colors.grey[600])),
        Text(value, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
          color: isDark ? Colors.white : Colors.black87)),
      ]),
    );
  }

  IconData _iconFor(String name) {
    switch (name) {
      case "Fan":    return Icons.air;
      case "Light":  return Icons.lightbulb;
      case "AC":     return Icons.ac_unit;
      case "Fridge": return Icons.kitchen;
      case "TV":     return Icons.tv;
      default:       return Icons.device_unknown;
    }
  }
}
