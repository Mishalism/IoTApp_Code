import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

import 'AppDrawer.dart';
import 'ThemeManager.dart';
import 'Login_Signup_Page.dart';
import 'ProfileScreen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late bool darkMode;

  double _threshold = 200;
  double _autoOffDelay = 60;

  final user = FirebaseAuth.instance.currentUser;
  late DatabaseReference ref;

  final double minThreshold = 0;
  final double maxThreshold = 200;

  

    final List<int> delayOptions = [
  5,
  10,
  15,
  30,
  60,
  120,
  300,
  600,
  900,
  1200,
  1500,
  1800,
];

  bool loaded = false;

  @override
  void initState() {
    super.initState();
    darkMode = themeManager.isDark;

    if (user != null) {
      ref = FirebaseDatabase.instance.ref("user_preferences/${user!.uid}");
      loadPreferences();
    }
  }

  // ================= LOAD =================
  void loadPreferences() async {
    final snapshot = await ref.get();

    if (snapshot.exists) {
      final data = Map<String, dynamic>.from(snapshot.value as Map);

      // ✅ FIX: clamp loaded values so they never exceed slider min/max
      double loadedThreshold = (data['threshold'] ?? 200).toDouble();
      double loadedDelay = (data['autoOffDelay'] ?? 60).toDouble();
      if (!delayOptions.contains(loadedDelay.toInt())) {
  loadedDelay = 60;
}

setState(() {
  _autoOffDelay = loadedDelay;
});
      print("Loaded delay: $loadedDelay");

      setState(() {
        darkMode = data['darkMode'] ?? darkMode;
        _threshold = loadedThreshold.clamp(minThreshold, maxThreshold);
        _autoOffDelay = loadedDelay;
        loaded = true;
      });

      themeManager.toggleTheme(darkMode);
    } else {
      setState(() => loaded = true);
    }
  }

  // ================= SAVE =================
  void savePreferences() async {
    if (user == null) return;

    await ref.set({
      "darkMode": darkMode,
      "threshold": _threshold,
      "autoOffDelay": _autoOffDelay,
    });
  }
  String formatDelay(double seconds) {
  if (seconds < 60) {
    return "${seconds.toInt()} sec";
  }

  if (seconds == 60) {
    return "1 min";
  }

  return "${(seconds / 60).toInt()} min";
}

  // ================= COMMON SLIDER =================
  Widget buildSlider({
    required double value,
    required double min,
    required double max,
    required Function(double) onChanged,
    required Function(double) onChangeEnd,
    required String label,
  }) {
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        activeTrackColor: const Color(0xFF1E3A8A),
        inactiveTrackColor: Colors.grey.shade300,
        thumbColor: const Color(0xFF1E3A8A),
        overlayColor: const Color(0xFF1E3A8A).withOpacity(0.2),
        trackHeight: 4,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10),
      ),
      child: Slider(
        value: value.clamp(min, max), // ✅ FIX: safety clamp on the slider itself
        min: min,
        max: max,
        label: label,
        onChanged: onChanged,
        onChangeEnd: onChangeEnd,
      ),
    );
  }

  // ================= UI =================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Settings", style: TextStyle(color: Colors.white)),
        backgroundColor: const Color(0xFF1E3A8A),
        leading: Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
      ),
      drawer: const AppDrawer(currentIndex: 4),

      body: !loaded
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [

                  /// DARK MODE
                  Card(
                    elevation: 3,
                    child: SwitchListTile(
                      title: const Text("Dark Mode"),
                      value: darkMode,
                      onChanged: (val) {
                        setState(() => darkMode = val);
                        themeManager.toggleTheme(val);
                        savePreferences();
                      },
                    ),
                  ),

                  const SizedBox(height: 15),

                  /// PROFILE
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.person),
                      title: const Text("User Profile"),
                      trailing: const Icon(Icons.arrow_forward_ios),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const ProfileScreen(),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 15),

                  /// THRESHOLD
                  Card(
                    elevation: 3,
                    child: Padding(
                      padding: const EdgeInsets.all(15),
                      child: Column(
                        children: [
                          const Text(
                            "Energy Threshold",
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 10),

                          Text(
                            "${_threshold.toStringAsFixed(0)} kWh",
                            style: const TextStyle(fontSize: 18),
                          ),

                          buildSlider(
                            value: _threshold,
                            min: minThreshold,
                            max: maxThreshold,
                            label: "${_threshold.toStringAsFixed(0)}",
                            onChanged: (val) =>
                                setState(() => _threshold = val),
                            onChangeEnd: (_) => savePreferences(),
                          ),

                          const SizedBox(height: 5),

                          Text(
                            "Alert when usage reaches ${_threshold.toStringAsFixed(0)} kWh",
                            style: const TextStyle(
                                fontSize: 12, color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 15),

                  /// AUTO OFF DELAY
                  Card(
                    elevation: 3,
                    child: Padding(
                      padding: const EdgeInsets.all(15),
                      child: Column(
                        children: [
                          const Text(
                            "Auto Turn Off Delay",
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 10),

                          Text(
                            formatDelay(_autoOffDelay),
                            style: const TextStyle(fontSize: 18),
                          ),

                         DropdownButtonFormField<double>(
  value: _autoOffDelay,
  decoration: const InputDecoration(
    border: OutlineInputBorder(),
  ),
  items: delayOptions.map((seconds) {
    return DropdownMenuItem<double>(
      value: seconds.toDouble(),
      child: Text(formatDelay(seconds.toDouble())),
    );
  }).toList(),
  onChanged: (value) {
    if (value == null) return;

    setState(() {
      _autoOffDelay = value;
    });

    savePreferences();
  },
),

                          const SizedBox(height: 5),

                          Text(
                            "Turns off after ${formatDelay(_autoOffDelay)} of no human detected",
                            style: const TextStyle(
                                fontSize: 12, color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 15),

                  /// LOGOUT
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.logout, color: Colors.red),
                      title: const Text("Logout"),
                      onTap: () async {
                        await FirebaseAuth.instance.signOut();

                        Navigator.pushAndRemoveUntil(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const LoginSignupPage()),
                          (route) => false,
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}