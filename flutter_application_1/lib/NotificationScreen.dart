import 'package:flutter/material.dart';
import 'AppDrawer.dart';
import 'NotificationManager.dart'; // Import your singleton manager

class NotificationScreen extends StatefulWidget {
  const NotificationScreen({super.key});

  // Static notifications
  static const List<Map<String, String>> staticNotifications = [
    {
      "title": "Power Restored",
      "message": "Electricity is back. All connected devices are stable.",
      "time": "3:10 PM"
    },
    {
      "title": "Appliance Turned Off",
      "message": "The system turned off your heater to save energy.",
      "time": "11:30 AM"
    },
    {
      "title": "Critical Alert",
      "message": "You crossed 200-unit threshold. Higher rates apply now.",
      "time": "9:00 PM"
    },
    {
      "title": "AI Suggestion",
      "message": "Shift ironing to after 9 PM to save Rs. 300/month.",
      "time": "4:45 PM"
    },
  ];

  @override
  State<NotificationScreen> createState() => _NotificationScreenState();
}

class _NotificationScreenState extends State<NotificationScreen> {
  final NotificationManager notificationManager = NotificationManager();

  // Colors for static notifications by title
  final Map<String, Color> staticCardColors = {
    "Power Restored": Colors.green[50]!,
    "Appliance Turned Off": Colors.purple[50]!,
    "Critical Alert": Colors.red[50]!,
    "AI Suggestion": Colors.cyan[50]!,
  };

  final Map<String, Color> staticTitleColors = {
    "Power Restored": Colors.green[900]!,
    "Appliance Turned Off": Colors.purple[900]!,
    "Critical Alert": Colors.red[900]!,
    "AI Suggestion": Colors.cyan[900]!,
  };

  @override
  void initState() {
    super.initState();
    // Start listening to dynamic notifications
    notificationManager.fetchNotifications(() {
      setState(() {}); // rebuild UI when notifications change
    });
  }

  void removeNotification(String id) {
    notificationManager.notifRef.child(id).remove();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Combine dynamic and static notifications
    final allNotifications = [
      ...notificationManager.dynamicNotifications,
      ...NotificationScreen.staticNotifications
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text("Notifications", style: TextStyle(color: Colors.white)),
        backgroundColor: const Color.fromARGB(255, 30, 58, 138),
      ),
      drawer: const AppDrawer(currentIndex: 3),
      backgroundColor: isDark ? Colors.grey[900] : Colors.white,
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            "Today",
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: isDark ? Colors.white : Colors.black87,
            ),
          ),
          const SizedBox(height: 15),
          ...allNotifications.map((notif) {
            final bool isDynamic = notif.containsKey("id");

            // Determine colors based on type
            Color cardColor;
            Color titleColor;
            Color iconColor;

            if (isDynamic) {
              cardColor = Colors.orange[50]!;
              titleColor = Colors.orange[900]!;
              iconColor = Colors.orange;
            } else {
              cardColor = staticCardColors[notif["title"]!] ?? Colors.blue[50]!;
              titleColor = staticTitleColors[notif["title"]!] ?? Colors.blue[900]!;
              iconColor = titleColor;
            }

            return Padding(
              padding: const EdgeInsets.only(bottom: 18),
              child: Stack(
                children: [
                  _buildNotificationCard(
                    icon: Icons.notifications,
                    iconColor: iconColor,
                    titleColor: titleColor,
                    cardColor: cardColor,
                    title: notif["title"]!,
                    message: notif["message"]!,
                    time: notif["time"]!,
                    isDark: isDark,
                  ),
                  if (isDynamic)
                    Positioned(
                      right: 0,
                      top: 0,
                      child: IconButton(
                        icon: const Icon(Icons.close, color: Colors.red),
                        onPressed: () => removeNotification(notif["id"]!),
                      ),
                    ),
                ],
              ),
            );
          }).toList(),
        ],
      ),
    );
  }

  Widget _buildNotificationCard({
    required IconData icon,
    required Color iconColor,
    required Color titleColor,
    required Color cardColor,
    required String title,
    required String message,
    required String time,
    required bool isDark,
  }) {
    return Card(
      elevation: 3,
      color: isDark ? Colors.grey[850] : cardColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(15),
        side: BorderSide(color: isDark ? Colors.grey.shade700 : Colors.white, width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: iconColor, size: 26),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(title,
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold, color: titleColor)),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(message, style: TextStyle(fontSize: 14, color: isDark ? Colors.white70 : Colors.black87)),
            const SizedBox(height: 8),
            Text(time, style: TextStyle(fontSize: 12, color: isDark ? Colors.white38 : Colors.grey[700])),
          ],
        ),
      ),
    );
  }
}
