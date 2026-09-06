import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

import 'DashboardScreen.dart';
import 'login_signup_page.dart';
import 'ThemeManager.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {

  @override
  void initState() {
    super.initState();
    _initApp();
  }

  /// 🔥 MAIN INITIALIZATION LOGIC
  Future<void> _initApp() async {
    await Future.delayed(const Duration(seconds: 2)); // splash delay

    final user = FirebaseAuth.instance.currentUser;

    if (user != null) {
      await _loadUserTheme(user.uid);

      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const DashboardScreen()),
      );
    } else {
      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const LoginSignupPage()),
      );
    }
  }

  /// 🔥 LOAD THEME FROM FIREBASE
  Future<void> _loadUserTheme(String uid) async {
    try {
      final ref = FirebaseDatabase.instance
          .ref("user_preferences/$uid");

      final snapshot = await ref.get();

      if (snapshot.exists) {
        final data = Map<String, dynamic>.from(snapshot.value as Map);

        bool isDark = data['darkMode'] ?? false;

        themeManager.setTheme(isDark);
      }
    } catch (e) {
      debugPrint("Theme load error: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color.fromARGB(244, 255, 255, 255),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [

            /// LOGO
            Image.asset(
              'assets/logo2.png',
              width: 300,
              height: 170,
            ),

            const SizedBox(height: 10),

            /// TAGLINE
            const Text(
              "A Smart Monitoring App",
              style: TextStyle(
                color: Color.fromARGB(255, 90, 90, 90),
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),

            const SizedBox(height: 30),

            /// LOADING INDICATOR
            const CircularProgressIndicator(),
          ],
        ),
      ),
    );
  }
}