import 'package:flutter/material.dart';
import 'DashboardScreen.dart';
import 'Control Screen.dart';
import 'PredictionScreen.dart';
import 'NotificationScreen.dart';
import 'SettingsScreen.dart';
import 'AnomalyScreen.dart';

class AppDrawer extends StatelessWidget {
  final int currentIndex;
  const AppDrawer({super.key, required this.currentIndex});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    Widget buildTile(int index, IconData icon, String title, Widget screen) {
      final selected = currentIndex == index;
      Color bgColor = selected
          ? Colors.indigo
          : isDark
              ? Colors.grey[850]!
              : Colors.white;
      Color iconColor = selected
          ? Colors.white
          : isDark
              ? Colors.white70
              : Colors.black54;
      Color textColor = selected
          ? Colors.white
          : isDark
              ? Colors.white70
              : Colors.black87;

      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(12),
        ),
        child: ListTile(
          leading: Icon(icon, color: iconColor),
          title: Text(title, style: TextStyle(color: textColor, fontWeight: FontWeight.w500)),
          onTap: () {
            if (!selected) {
              Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => screen));
            } else {
              Navigator.pop(context);
            }
          },
        ),
      );
    }

    return Drawer(
      child: Container(
        color: isDark ? Colors.grey[900] : Colors.grey[200],
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
           DrawerHeader(
  decoration: BoxDecoration(
    color: isDark ? Colors.grey[900] : Colors.white,
  ),
  child: Center(
    child: Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white, // keeps picture visible
        shape: BoxShape.circle,
      ),
      child: Image.asset('assets/logo2.png', width: 120, height: 120),
    ),
  ),
),
            buildTile(0, Icons.dashboard, 'Dashboard', DashboardScreen()),
            buildTile(1, Icons.settings, 'Control',  const ControlScreen()),
            buildTile(2, Icons.analytics, 'Prediction', const PredictionScreen()),
            buildTile(3, Icons.notifications, 'Notifications', const NotificationScreen()),
            buildTile(4, Icons.settings, 'Settings', const SettingsScreen()),
            buildTile(5, Icons.warning, 'Anomaly', const AnomalyScreen()),
          ],
        ),
      ),
    );
  }
}
