import 'package:flutter/material.dart';

class GibberTheme {
  // Baby Blue & Gold Palette (Light)
  static const Color babyBlue = Color(0xFF89BBFE);
  static const Color gold = Color(0xFFFFD700);
  
  // Magenta & Turquoise Palette (Dark)
  static const Color magenta = Color(0xFFE91E63);
  static const Color turquoise = Color(0xFF00BCD4);
  
  // Neutral Colors
  static const Color deepMidnight = Color(0xFF0F172A);
  static const Color slateBlue = Color(0xFF1E293B);

  static ThemeData get light {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: ColorScheme.light(
        primary: babyBlue,
        onPrimary: Colors.white,
        secondary: gold,
        onSecondary: Colors.black87,
        surface: Colors.white,
        onSurface: Colors.black87,
        surfaceContainerHighest: Colors.grey.shade100,
        onSurfaceVariant: Colors.black54,
        primaryContainer: Colors.blue.shade50,
        onPrimaryContainer: Colors.blue.shade900,
        outline: Colors.black12,
        error: Colors.red.shade700,
      ),
      scaffoldBackgroundColor: const Color(0xFFF8FAFC),
      appBarTheme: const AppBarTheme(
        backgroundColor: babyBlue,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: babyBlue,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
    );
  }

  static ThemeData get dark {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: const ColorScheme.dark(
        primary: magenta,
        onPrimary: Colors.white,
        secondary: turquoise,
        onSecondary: Colors.black,
        surface: deepMidnight,
        onSurface: Colors.white,
        surfaceContainerHighest: slateBlue,
        onSurfaceVariant: Colors.white70,
        primaryContainer: Color(0xFF1E293B), // slateBlue
        onPrimaryContainer: Colors.white,
        outline: Colors.white10,
        error: Color(0xFFCF6679),
      ),
      scaffoldBackgroundColor: deepMidnight,
      appBarTheme: const AppBarTheme(
        backgroundColor: slateBlue,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: magenta,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
    );
  }
}
