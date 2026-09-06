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

      // Build a combined on/off state map first — backend uses ALL
      // appliance states as context (not just the one being checked).
      int fanState = 0, fridgeState = 1, acState = 0, lightState = 0, tvState = 0;
      for (final entry in raw.entries) {
        if (entry.value is! Map) continue;
        final d = Map<String, dynamic>.from(entry.value);
        final on = (d["isOn"] ?? false) == true ? 1 : 0;
        switch (entry.key.toLowerCase()) {
          case "fan":    fanState    = on; break;
          case "fridge": fridgeState = on; break;
          case "ac":     acState     = on; break;
          case "light":  lightState  = on; break;
          case "tv":     tvState     = on; break;
        }
      }

      final found = <Map<String, dynamic>>[];

      for (final entry in raw.entries) {
        final name = entry.key;
        if (entry.value is! Map) continue;
        final data = Map<String, dynamic>.from(entry.value);

        final bool isOn = data["isOn"] ?? false;
        if (!isOn) continue;

        // Live wattage — CONFIRM this field name matches your Firebase schema
        final powerW = _parseDouble(data["power"]) ?? 0.0;
        // Model was trained on per-15-min-slot kWh, not cumulative totals —
        // derive the slot-equivalent reading from instantaneous power instead
        // of using the cumulative "units" field (which keeps growing over time
        // and would look like a huge fake spike every time it's checked).
        final totalKwhThisSlot = (powerW * 0.25) / 1000.0;
        // Voltage if available
        final voltage = _parseDouble(data["voltage"]) ?? 220.0;

        // Call anomaly endpoint with this appliance's current reading
        final result = await AIService.checkAnomaly(
          appliance:    name,
          actualPowerW: powerW,
          totalKwh:     totalKwhThisSlot,
          voltage:      voltage,
          fanState:     fanState,
          fridgeState:  fridgeState,
          acState:      acState,
          lightState:   lightState,
          tvState:      tvState,
        );

        if (result["is_anomaly"] == true) {
          found.add({
            "appliance":           name,
            "anomaly_type":        result["anomaly_type"],
            "anomaly_probability": result["anomaly_probability"],
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
    final name = a["appliance"];
    final type = a["anomaly_type"] ?? "unknown";
    final prob = (a["anomaly_probability"] as num).toDouble();

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
            Expanded(child: Text("$name — ${_labelFor(type)}",
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold,
                color: Colors.red.shade700))),
           
          ]),
          const SizedBox(height: 10),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.lightbulb_outline_rounded, size: 16, color: Colors.amber),
            const SizedBox(width: 5),
            Expanded(child: Text(
              _suggestionFor(name, type),
              style: TextStyle(fontSize: 13,
                color: isDark ? Colors.white60 : Colors.grey[800]))),
          ]),
        ]),
      ),
    );
  }

  String _labelFor(String type) {
    switch (type) {
      case "power_spike":   return "Power Spike Detected";
      case "phantom_load":  return "Phantom Load Detected";
      case "voltage_fault": return "Voltage Fault Detected";
      default:              return "Unusual Reading";
    }
  }

  String _suggestionFor(String name, String type) {
    switch (type) {
      case "power_spike":
        return "Check $name for a fault or damaged component causing excess power draw.";
      case "phantom_load":
        return "Check $name for phantom load — it may be silently drawing power while off.";
      case "voltage_fault":
        return "Check the mains voltage supply — it's outside the safe range.";
      default:
        return "Check $name for unusual usage.";
    }
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