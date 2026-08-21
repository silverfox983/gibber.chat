import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/app_colors.dart';

class ThemeProvider extends ChangeNotifier {
  ThemeMode _themeMode = ThemeMode.system;

  static const Color _defaultSeedColor = AppColors.primary;
  static const String _defaultFontFamily = 'Outfit';

  Color _seedColor = _defaultSeedColor;
  bool _useDynamicColors = false;
  bool _amoledMode = false;
  String _fontFamily = _defaultFontFamily;

  final Completer<void> _initialized = Completer<void>();
  Future<void> get initialized => _initialized.future;

  ThemeProvider() {
    _loadAppearance();
  }

  ThemeMode get themeMode => _themeMode;

  bool get isDarkMode {
    if (_themeMode == ThemeMode.system) {
      final brightness = WidgetsBinding.instance.platformDispatcher.platformBrightness;
      return brightness == Brightness.dark;
    }
    return _themeMode == ThemeMode.dark;
  }

  Color get seedColor => _seedColor;
  bool get useDynamicColors => _useDynamicColors;
  bool get amoledMode => _amoledMode;
  String get fontFamily => _fontFamily;

  Future<void> _loadAppearance() async {
    final prefs = await SharedPreferences.getInstance();
    final mode = prefs.getString('theme_mode');
    if (mode == 'light') {
      _themeMode = ThemeMode.light;
    } else if (mode == 'dark') {
      _themeMode = ThemeMode.dark;
    } else {
      _themeMode = ThemeMode.system;
    }

    final seedColorValue = prefs.getInt('seed_color');
    if (seedColorValue != null) {
      _seedColor = Color(seedColorValue);
    }

    _useDynamicColors = prefs.getBool('use_dynamic_colors') ?? false;
    _amoledMode = prefs.getBool('amoled_mode') ?? false;

    final savedFont = prefs.getString('font_family');
    if (savedFont != null && savedFont.isNotEmpty) {
      _fontFamily = savedFont;
    }

    notifyListeners();

    if (!_initialized.isCompleted) {
      _initialized.complete();
    }
  }

  Future<void> toggleTheme() async {
    if (isDarkMode) {
      _themeMode = ThemeMode.light;
    } else {
      _themeMode = ThemeMode.dark;
    }
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('theme_mode', _themeMode == ThemeMode.light ? 'light' : 'dark');
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('theme_mode', mode.name);
  }

  Future<void> setSeedColor(Color color) async {
    _seedColor = color;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('seed_color', color.toARGB32());
  }

  Future<void> setUseDynamicColors(bool value) async {
    _useDynamicColors = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('use_dynamic_colors', value);
  }

  Future<void> setAmoledMode(bool value) async {
    _amoledMode = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('amoled_mode', value);
  }

  Future<void> setFontFamily(String fontFamily) async {
    _fontFamily = fontFamily;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('font_family', fontFamily);
  }

  Future<void> resetToDefaults() async {
    _themeMode = ThemeMode.system;
    _seedColor = _defaultSeedColor;
    _useDynamicColors = false;
    _amoledMode = false;
    _fontFamily = _defaultFontFamily;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('theme_mode', 'system');
    await prefs.remove('seed_color');
    await prefs.setBool('use_dynamic_colors', false);
    await prefs.setBool('amoled_mode', false);
    await prefs.setString('font_family', _defaultFontFamily);
  }
}
