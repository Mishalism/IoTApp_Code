import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

import 'firebase_options.dart';
import 'SplashScreen .dart';
import 'ThemeManager.dart';
import 'ApplianceMonitor.dart';
import 'UnitsAccumulatorService.dart';

/// 🔥 LOAD USER THEME BEFORE UI BUILDS
Future<void> loadUserTheme() async {
  try {
    final user = FirebaseAuth.instance.currentUser;

    if (user != null) {
      final ref =
      FirebaseDatabase.instance.ref("user_preferences/${user.uid}");

      // ⏱️ Add timeout so it doesn't hang forever
      final snapshot = await ref.get().timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw Exception("Theme load timed out"),
      );

      if (snapshot.exists) {
        final data = Map<String, dynamic>.from(snapshot.value as Map);
        bool isDark = data['darkMode'] ?? false;
        themeManager.setTheme(isDark);
      }
    }
  } catch (e) {
    // ✅ Silently fail — app will just use default theme
    debugPrint("loadUserTheme error: $e");
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ✅ Wrap Firebase init in try/catch
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (e) {
    debugPrint("Firebase init error: $e");
  }

  // ✅ Won't block or crash if it fails
  await loadUserTheme();

  // ✅ Wrap monitor in try/catch so it doesn't freeze main()
  try {
    ApplianceMonitor().startMonitoring();
  } catch (e) {
    debugPrint("ApplianceMonitor error: $e");
  }

  // ✅ Start the units accumulator here — app-wide, once — instead of
  // inside DashboardScreen. This is what keeps it running across screen
  // navigation instead of stopping every time Dashboard is disposed.
  try {
    unitsAccumulator.start();
  } catch (e) {
    debugPrint("UnitsAccumulatorService error: $e");
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: themeManager,
      builder: (context, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Smart Monitoring App',

          /// LIGHT THEME
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
            useMaterial3: true,
          ),

          /// DARK THEME
          darkTheme: ThemeData.dark(useMaterial3: true),

          /// 🔥 CONTROLLED BY FIREBASE
          themeMode:
          themeManager.isDark ? ThemeMode.dark : ThemeMode.light,

          home: const SplashScreen(),
        );
      },
    );
  }
}