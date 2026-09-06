import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'AppDrawer.dart';

class ControlScreen extends StatefulWidget {
  const ControlScreen({super.key});

  @override
  State<ControlScreen> createState() => _ControlScreenState();
}

class _ControlScreenState extends State<ControlScreen> {
  final DatabaseReference dbRef =
      FirebaseDatabase.instance.ref("appliances");

  Map<String, dynamic> applianceData = {};

  StreamSubscription? _subscription;

  @override
  void initState() {
    super.initState();

    // 🔥 REAL-TIME LISTENER
    _subscription = dbRef.onValue.listen((event) {
      final data = event.snapshot.value;

      if (data != null && data is Map) {
        setState(() {
          applianceData = Map<String, dynamic>.from(data);
        });
      } else {
        setState(() {
          applianceData = {};
        });
      }
    });
  }

  @override
  void dispose() {
    _subscription?.cancel(); // prevent memory leaks
    super.dispose();
  }

  // Toggle ON/OFF
  void _toggleAppliance(String key, bool value) {
    if (applianceData.containsKey(key)) {
      dbRef.child(key).update({"isOn": value});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title:
            const Text("Control", style: TextStyle(color: Colors.white)),
        backgroundColor: const Color.fromARGB(255, 30, 58, 138),
        leading: Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
      ),
      drawer: const AppDrawer(currentIndex: 1),

      body: applianceData.isEmpty
          ? const Center(child: Text("No appliances found"))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                children: applianceData.keys.map((key) {
                  if (key == "hourly_power") {
                    return const SizedBox.shrink();
                  }

                  final raw = applianceData[key];

                  if (raw is! Map) {
                    return const SizedBox.shrink();
                  }

                  final data = Map<String, dynamic>.from(raw);
                  final isOn = data["isOn"] ?? false;

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 15),
                    child: _buildControlTile(
                      key,
                      isOn,
                      _getColorForAppliance(key),
                      _getIconForAppliance(key),
                      (val) => _toggleAppliance(key, val),
                      data,
                    ),
                  );
                }).toList(),
              ),
            ),
    );
  }

  // Colors
  Color _getColorForAppliance(String key) {
    switch (key) {
      case "Fan":
        return const Color.fromARGB(255, 21, 0, 255);
      case "Light":
        return Colors.yellow;
      case "AC":
        return Colors.blue;
      case "Fridge":
        return Colors.teal;
      case "TV":
        return Colors.purple;
      default:
        return Colors.grey;
    }
  }

  // Icons
  IconData _getIconForAppliance(String key) {
    switch (key) {
      case "Fan":
        return Icons.air;
      case "Light":
        return Icons.lightbulb;
      case "AC":
        return Icons.ac_unit;
      case "Fridge":
        return Icons.kitchen;
      case "TV":
        return Icons.tv;
      default:
        return Icons.device_unknown;
    }
  }

  Widget _buildControlTile(
    String title,
    bool value,
    Color activeColor,
    IconData icon,
    Function(bool) onChanged,
    Map<String, dynamic> data,
  ) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      child: Card(
        elevation: 4,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(15),
          side: BorderSide(color: Colors.grey.shade300, width: 1),
        ),
        child: Column(
          children: [
            SwitchListTile(
              title: Row(
                children: [
                  Icon(icon, color: activeColor),
                  const SizedBox(width: 10),
                  Text(title, style: const TextStyle(fontSize: 18)),
                ],
              ),
              value: value,
              activeColor: activeColor,
              onChanged: onChanged,
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 20, vertical: 10),
            ),

            // Show data when ON
            if (value) _buildDataRow(data, activeColor),
          ],
        ),
      ),
    );
  }

  Widget _buildDataRow(Map<String, dynamic> data, Color activeColor) {
    // Format units to 4 decimal places
    final rawUnits = data["units"];
    String unitsDisplay = "--";
    if (rawUnits != null) {
      final parsed = double.tryParse(rawUnits.toString());
      if (parsed != null) {
        unitsDisplay = parsed.toStringAsFixed(4);
      }
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: activeColor.withOpacity(0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: activeColor.withOpacity(0.4), width: 1),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _dataBox("Current", data["current"], activeColor),
          _dataBox("Voltage", data["voltage"], activeColor),
          _dataBox("Units", unitsDisplay, activeColor),   // 4 dp
          _dataBox("Power", data["power"], activeColor),
        ],
      ),
    );
  }

  Widget _dataBox(String label, dynamic value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.18),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Column(
        children: [
          Text(
            value?.toString() ?? "--",
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            style: const TextStyle(fontSize: 12, color: Colors.black87),
          ),
        ],
      ),
    );
  }
}