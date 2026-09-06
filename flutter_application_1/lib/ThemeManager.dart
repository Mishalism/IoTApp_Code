import 'package:flutter/material.dart';

class ThemeManager extends ChangeNotifier {
  bool isDark = false;

  void toggleTheme(bool value) {
    isDark = value;
    notifyListeners();
  }

  void setTheme(bool value) {
    isDark = value;
    notifyListeners();
  }
}

ThemeManager themeManager = ThemeManager();