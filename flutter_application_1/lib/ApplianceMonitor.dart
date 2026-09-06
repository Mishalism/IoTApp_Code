import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

class ApplianceMonitor {
  static final ApplianceMonitor _instance = ApplianceMonitor._internal();
  factory ApplianceMonitor() => _instance;
  ApplianceMonitor._internal();

  bool isMonitoring = false;

  /// Stores when each appliance was first detected ON without a human
  final Map<String, DateTime> offTimers = {};

  /// Timer to continuously check conditions
  Timer? _timer;

  /// Delay in SECONDS — loaded from Firebase user preferences.
  /// Matches SettingsScreen.dart's delayOptions (5s .. 1800s / 30min).
  /// Default is 60 seconds if nothing is saved yet.
  int _delaySeconds = 60;

  void startMonitoring() {
    if (isMonitoring) return;
    isMonitoring = true;

    print("Appliance Monitoring Started");

    // Load user's preferred delay first, then start the check loop
    _loadDelayFromFirebase();

    // Run check every 5 seconds so short delays (e.g. 5s) are actually
    // detectable — checking every 10s meant a 5s delay could take up to
    // ~10s to fire, which is fine, but anything checked less often than
    // the shortest selectable delay would silently under-fire.
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      _loadDelayFromFirebase(); // refresh delay in case user changed it
      _checkAppliances();
    });
  }

  /// Reads autoOffDelay (in SECONDS) from Firebase user preferences.
  Future<void> _loadDelayFromFirebase() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final snapshot = await FirebaseDatabase.instance
        .ref("user_preferences/${user.uid}/autoOffDelay")
        .get();

    if (snapshot.exists) {
      final value = snapshot.value;
      if (value != null) {
        // clamp to match SettingsScreen.dart's delayOptions range (5s .. 1800s)
        _delaySeconds = (double.tryParse(value.toString()) ?? 60)
            .clamp(5, 1800)
            .toInt();
        print("Auto off delay loaded: $_delaySeconds seconds");
      }
    }
  }

  /// MAIN LOGIC — checks appliances and turns off if no human detected.
  /// NOTE: Fridge is excluded from auto-off and will never be turned off automatically.
  Future<void> _checkAppliances() async {
    final ref = FirebaseDatabase.instance.ref("appliances");
    final snapshot = await ref.get();
    if (!snapshot.exists) return;

    final appliances = Map<String, dynamic>.from(snapshot.value as Map);

    // Get human status from IoT sensor
    final humanSnap = await FirebaseDatabase.instance
        .ref("IoT_Sensors/HumanStatus")
        .get();

    bool humanDetected = humanSnap.value == true;
    print("Human Detected: $humanDetected | Delay: $_delaySeconds sec");

    for (String appliance in appliances.keys) {
      // Fridge should never be turned off automatically — skip it entirely
      if (appliance == "Fridge") continue;

      final raw = appliances[appliance];
      if (raw is! Map) continue;

      final data = Map<String, dynamic>.from(raw);
      bool isOn = data["isOn"] ?? false;

      /// CASE 1: Appliance ON & no human detected
      if (isOn && !humanDetected) {
        // Start timer if not already started for this appliance
        offTimers.putIfAbsent(appliance, () {
          print("Started timer for $appliance");
          return DateTime.now();
        });

        final startTime = offTimers[appliance]!;
        final elapsed = DateTime.now().difference(startTime);

        print("$appliance running without human for ${elapsed.inSeconds}s "
            "(limit: ${_delaySeconds}s)");

        // If user-defined delay has passed → turn off
        if (elapsed.inSeconds >= _delaySeconds) {
          print("Turning OFF $appliance after $_delaySeconds sec");

          // Turn off the appliance in Firebase
          await ref.child(appliance).update({"isOn": false});

          // Send notification
          final notifRef =
              FirebaseDatabase.instance.ref("notifications").push();

          await notifRef.set({
            "title": "Auto Turn OFF",
            "message":
                "$appliance turned OFF automatically after $_delaySeconds sec (no human detected)",
            "time": DateTime.now().toIso8601String(),
          });

          // Remove timer for this appliance
          offTimers.remove(appliance);
        }
      }

      /// CASE 2: Human returned OR appliance already OFF — reset timer
      else {
        if (offTimers.containsKey(appliance)) {
          print("Reset timer for $appliance");
          offTimers.remove(appliance);
        }
      }

  }}

  /// Stop monitoring (optional)
  void stopMonitoring() {
    _timer?.cancel();
    isMonitoring = false;
  }
}