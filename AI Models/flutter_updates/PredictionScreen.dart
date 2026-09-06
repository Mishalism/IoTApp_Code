import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'AppDrawer.dart';
import 'AIService.dart';
import 'NotificationManager.dart';

class PredictionScreen extends StatefulWidget {
  const PredictionScreen({super.key});
  @override
  State<PredictionScreen> createState() => _PredictionScreenState();
}

class _PredictionScreenState extends State<PredictionScreen> {
  bool loading = true;
  String? error;

  double? dailyUnits;
  double? monthlyUnits;
  double? unitsUsedSoFar;
  double? remainingUnits;
  int daysElapsed   = 0;
  int daysRemaining = 0;
  bool exceedsThreshold = false;
  Map<String, dynamic>? billBreakdown;
  List<dynamic> suggestions = [];
  String _dataSource = "";

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() { loading = true; error = null; });

    try {
      final now = DateTime.now();

      // ── Step 1: Read actual units used this month from Firebase ──────
      // Your Firebase already has monthly_units/2026-05/total
      double unitsThisMonth = 0.0;
      String monthKey =
          "${now.year}-${now.month.toString().padLeft(2, '0')}";

      try {
        final monthlySnap = await FirebaseDatabase.instance
            .ref("monthly_units/$monthKey/total")
            .get();
        if (monthlySnap.exists) {
          unitsThisMonth = _parseDouble(monthlySnap.value) ?? 0.0;
        }
      } catch (_) {}

      // Fallback: if monthly_units not populated, sum appliance units
      if (unitsThisMonth == 0.0) {
        try {
          final appSnap = await FirebaseDatabase.instance
              .ref("appliances")
              .get();
          if (appSnap.exists) {
            final apps =
                Map<String, dynamic>.from(appSnap.value as Map);
            for (final entry in apps.values) {
              if (entry is Map) {
                final u = _parseDouble(entry["units"]);
                if (u != null) unitsThisMonth += u;
              }
            }
          }
        } catch (_) {}
      }

      _dataSource = unitsThisMonth > 0
          ? "Actual usage this month: ${unitsThisMonth.toStringAsFixed(3)} kWh · "
            "Day ${now.day} of 30"
          : "No usage data found — using model prediction only";

      // ── Step 2: Call Flask with real units + current day ─────────────
      final result = await AIService.getPrediction(
        occupancy:         1,     // fixed — stable monthly prediction
        numOccupants:      3,
        unitsUsedSoFar:    unitsThisMonth,
        dayOfMonth:        now.day,
      );

      final monthly   = (result["predicted_monthly_units"]   as num).toDouble();
      final daily     = (result["predicted_daily_units"]     as num).toDouble();
      final remaining = (result["predicted_remaining_units"] as num).toDouble();
      final elapsed   = (result["days_elapsed"]              as num).toInt();
      final remaining_days = (result["days_remaining"]       as num).toInt();
      final bill      = Map<String, dynamic>.from(result["bill_breakdown"]);
      final exceeds   = result["exceeds_200_unit_threshold"] == true;

      // ── Step 3: Get suggestions ───────────────────────────────────────
      final recs = await AIService.getRecommendations(
        projectedMonthlyUnits: monthly,
        userThreshold: 200,
      );

      // ── Step 4: Push notifications (1-hour cooldown) ──────────────────
      NotificationManager().generateAndPushRecommendations(
        predictedUnits: monthly,
        projectedMonthly: monthly,
        userThreshold: 200,
      );

      setState(() {
        dailyUnits       = daily;
        monthlyUnits     = monthly;
        unitsUsedSoFar   = unitsThisMonth;
        remainingUnits   = remaining;
        daysElapsed      = elapsed;
        daysRemaining    = remaining_days;
        exceedsThreshold = exceeds;
        billBreakdown    = bill;
        suggestions      = recs;
        loading          = false;
      });
    } catch (e) {
      setState(() {
        error = "Could not reach prediction service.\n"
                "Make sure Flask server is running.\n\n$e";
        loading = false;
      });
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
        title: const Text("Prediction",
            style: TextStyle(color: Colors.white)),
        backgroundColor: const Color.fromARGB(255, 30, 58, 138),
        leading: Builder(builder: (ctx) => IconButton(
          icon: const Icon(Icons.menu),
          onPressed: () => Scaffold.of(ctx).openDrawer(),
        )),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      drawer: const AppDrawer(currentIndex: 2),

      body: loading
        ? const Center(child: CircularProgressIndicator())
        : error != null
          ? Center(child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.cloud_off, size: 48, color: Colors.grey),
                  const SizedBox(height: 12),
                  Text(error!, textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 14)),
                  const SizedBox(height: 20),
                  ElevatedButton.icon(
                    onPressed: _load,
                    icon: const Icon(Icons.refresh),
                    label: const Text("Retry"),
                  ),
                ],
              ),
            ))
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [

                  Text("Monthly Forecast",
                    style: TextStyle(fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white : Colors.black87)),
                  const SizedBox(height: 4),
                  Text("Based on actual usage + predicted remaining days",
                    style: TextStyle(fontSize: 13,
                      color: isDark ? Colors.white54 : Colors.grey[600])),

                  // Data source badge
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.green.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.green.shade300),
                    ),
                    child: Row(children: [
                      Icon(Icons.sensors, size: 14,
                          color: Colors.green.shade700),
                      const SizedBox(width: 6),
                      Expanded(child: Text(_dataSource,
                        style: TextStyle(fontSize: 12,
                          color: Colors.green.shade800))),
                    ]),
                  ),

                  const SizedBox(height: 20),

                  // Already used this month
                  _statCard(
                    icon: Icons.electric_meter,
                    iconColor: Colors.blue.shade600,
                    title: "Used So Far This Month",
                    value: "${unitsUsedSoFar!.toStringAsFixed(3)} units",
                    subtitle: "Day $daysElapsed of 30",
                    subtitleColor: Colors.blue.shade400,
                    isDark: isDark,
                  ),
                  const SizedBox(height: 14),

                  // Predicted remaining
                  _statCard(
                    icon: Icons.trending_up,
                    iconColor: Colors.orange.shade600,
                    title: "Predicted Remaining ($daysRemaining days left)",
                    value: "${remainingUnits!.toStringAsFixed(2)} units",
                    subtitle: "${dailyUnits!.toStringAsFixed(3)} units/day predicted",
                    subtitleColor: Colors.orange.shade400,
                    isDark: isDark,
                  ),
                  const SizedBox(height: 14),

                  // Total projected monthly
                  _statCard(
                    icon: Icons.calendar_month,
                    iconColor: exceedsThreshold ? Colors.red : Colors.green,
                    title: "Total Projected Monthly Usage",
                    value: "${monthlyUnits!.toStringAsFixed(1)} units",
                    subtitle: exceedsThreshold
                      ? "⚠  Exceeds 200-unit threshold"
                      : "✓  Within 200-unit threshold",
                    subtitleColor:
                        exceedsThreshold ? Colors.red : Colors.green,
                    isDark: isDark,
                  ),
                  const SizedBox(height: 14),

                  // Bill breakdown
                  _billCard(isDark),
                  const SizedBox(height: 24),

                  // Suggestions
                  Text("AI Suggestions",
                    style: TextStyle(fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white : Colors.black87)),
                  const SizedBox(height: 12),

                  ...suggestions.map((s) => _suggestionCard(
                    text: s["text"],
                    priority: s["priority"],
                    isDark: isDark,
                  )),
                ],
              ),
            ),
    );
  }

  Widget _billCard(bool isDark) {
    if (billBreakdown == null) return const SizedBox.shrink();
    return Card(
      elevation: 3,
      color: isDark ? Colors.grey[850] : Colors.indigo.shade50,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(15),
        side: BorderSide(color: Colors.indigo.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          Row(children: [
            const Icon(Icons.receipt_long, color: Colors.indigo),
            const SizedBox(width: 8),
            Text("Estimated Monthly Bill (PKR)",
              style: TextStyle(fontSize: 16,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : Colors.indigo.shade900)),
          ]),
          const SizedBox(height: 16),
          _billRow("Energy Charges",
            "Rs. ${_fmt(billBreakdown!['energy_charge_pkr'])}", isDark),
          _billRow("Fixed Charge",
            "Rs. ${_fmt(billBreakdown!['fixed_charge_pkr'])}", isDark),
          _billRow("GST (18%)",
            "Rs. ${_fmt(billBreakdown!['gst_pkr'])}", isDark),
          const Divider(height: 20),
          _billRow("Total Estimated Bill",
            "Rs. ${_fmt(billBreakdown!['total_bill_pkr'])}",
            isDark, bold: true),
        ]),
      ),
    );
  }

  String _fmt(dynamic v) =>
    (v as num).toStringAsFixed(0).replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},');

  Widget _billRow(String label, String value, bool isDark,
      {bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
        Text(label, style: TextStyle(fontSize: 14,
          fontWeight: bold ? FontWeight.bold : FontWeight.normal,
          color: isDark ? Colors.white70 : Colors.black87)),
        Text(value, style: TextStyle(fontSize: 14,
          fontWeight: bold ? FontWeight.bold : FontWeight.normal,
          color: isDark ? Colors.white : Colors.black87)),
      ]),
    );
  }

  Widget _statCard({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String value,
    String? subtitle,
    Color? subtitleColor,
    required bool isDark,
  }) {
    return Card(
      elevation: 3,
      color: isDark ? Colors.grey[850] : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(15),
        side: BorderSide(
          color: isDark ? Colors.grey.shade700 : Colors.grey.shade200)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(children: [
          Icon(icon, color: iconColor, size: 36),
          const SizedBox(width: 16),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: TextStyle(fontSize: 13,
                color: isDark ? Colors.white70 : Colors.grey[700])),
              const SizedBox(height: 4),
              Text(value, style: TextStyle(fontSize: 22,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : Colors.black87)),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(subtitle, style: TextStyle(fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: subtitleColor ?? Colors.grey)),
              ],
            ],
          )),
        ]),
      ),
    );
  }

  Widget _suggestionCard({
    required String text,
    required String priority,
    required bool isDark,
  }) {
    Color color; IconData icon;
    switch (priority) {
      case "high":   color = Colors.red;    icon = Icons.priority_high;       break;
      case "medium": color = Colors.orange; icon = Icons.info_outline;        break;
      default:       color = Colors.green;  icon = Icons.check_circle_outline;
    }
    return Card(
      elevation: 2,
      color: isDark ? Colors.grey[850] : color.withOpacity(0.06),
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: color.withOpacity(0.4))),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: TextStyle(fontSize: 14,
            color: isDark ? Colors.white70 : Colors.black87))),
        ]),
      ),
    );
  }
}
