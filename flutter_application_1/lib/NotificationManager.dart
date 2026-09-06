import 'package:firebase_database/firebase_database.dart';
import 'AIService.dart';

class NotificationManager {
  static final NotificationManager _instance = NotificationManager._internal();
  factory NotificationManager() => _instance;
  NotificationManager._internal();

  final DatabaseReference notifRef = FirebaseDatabase.instance.ref("notifications");
  List<Map<String, String>> dynamicNotifications = [];

  // Tracks the last time we pushed AI recommendations
  // so we don't spam duplicate notifications on every screen visit
  DateTime? _lastPushedAt;
  static const _cooldownMinutes = 60; // only push once per hour

  // Getter for count
  int get count => dynamicNotifications.length;

  // Fetch notifications and listen for changes
  void fetchNotifications(void Function() onUpdate) {
    notifRef.onValue.listen((event) {
      final data = event.snapshot.value as Map<dynamic, dynamic>?;
      if (data != null) {
        final List<Map<String, String>> temp = [];
        data.forEach((key, value) {
          final Map<String, dynamic> val = Map<String, dynamic>.from(value);
          temp.add({
            "id": key,
            "title": val["title"] ?? "",
            "message": val["message"] ?? "",
            "time": val["time"] ?? "",
          });
        });
        temp.sort((a, b) => b["time"]!.compareTo(a["time"]!));
        dynamicNotifications = temp;
      } else {
        dynamicNotifications = [];
      }
      onUpdate();
    });
  }

  /// Calls the AI recommendation engine and pushes HIGH/MEDIUM priority
  /// suggestions into Firebase as real notifications.
  /// Has a cooldown — will not push again within _cooldownMinutes,
  /// preventing duplicate notifications every time the screen is visited.
  Future<void> generateAndPushRecommendations({
    required double predictedUnits,
    required double projectedMonthly,
    bool isAnomaly = false,
    String? anomalyAppliance,
    double userThreshold = 200,
  }) async {
    // Check cooldown — skip if we pushed recently
    if (_lastPushedAt != null) {
      final minutesSinceLast = DateTime.now().difference(_lastPushedAt!).inMinutes;
      if (minutesSinceLast < _cooldownMinutes) {
        print("Skipping notification push — cooldown active "
            "($minutesSinceLast min since last push, "
            "limit: $_cooldownMinutes min)");
        return;
      }
    }

    try {
      final suggestions = await AIService.getRecommendations(
      projectedMonthlyUnits: projectedMonthly,
      isAnomaly: isAnomaly,
      anomalyProbability: 0, // pass real probability here if you have it
      userThreshold: userThreshold,
    );

      bool pushedAtLeastOne = false;

      for (final s in suggestions) {
        final priority = s["priority"];
        final text = s["text"];

        // Skip "low" priority — no need to clutter notifications
        if (priority == "low") continue;

        await notifRef.push().set({
          "title": priority == "high" ? "AI Alert" : "AI Suggestion",
          "message": text,
          "time": DateTime.now().toIso8601String(),
          "priority": priority,
        });

        pushedAtLeastOne = true;
      }

      // Only update the cooldown timer if we actually pushed something
      if (pushedAtLeastOne) {
        _lastPushedAt = DateTime.now();
      }
    } catch (e) {
      print("Failed to generate recommendations: $e");
    }
  }
}
