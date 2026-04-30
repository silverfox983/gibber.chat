import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class GibberTheme {
  // Premium Palette - Light (Arctic Mist)
  static const Color arcticBlue = Color(0xFF3B82F6);
  static const Color arcticSurface = Color(0xFFF9FAFB);
  static const Color arcticOutline = Color(0xFFE5E7EB);
  
  // Premium Palette - Dark (Midnight Eclipse)
  static const Color eclipsePurple = Color(0xFF8B5CF6);
  static const Color eclipseMidnight = Color(0xFF0F172A);
  static const Color eclipseDeep = Color(0xFF020617);
  static const Color eclipseSurface = Color(0xFF1E293B);

  static ThemeData get light {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: ColorScheme.light(
        primary: arcticBlue,
        onPrimary: Colors.white,
        secondary: const Color(0xFF10B981), // Emerald
        onSecondary: Colors.white,
        surface: Colors.white,
        onSurface: const Color(0xFF111827),
        surfaceContainerHighest: const Color(0xFFF3F4F6),
        onSurfaceVariant: const Color(0xFF4B5563),
        primaryContainer: const Color(0xFFDBEAFE),
        onPrimaryContainer: const Color(0xFF1E40AF),
        outline: arcticOutline,
        error: const Color(0xFFEF4444),
      ),
      scaffoldBackgroundColor: arcticSurface,
    );
    
    return base.copyWith(
      textTheme: GoogleFonts.outfitTextTheme(base.textTheme),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF111827),
        elevation: 0,
        centerTitle: false,
        titleTextStyle: GoogleFonts.outfit(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: const Color(0xFF111827),
        ),
      ),
    );
  }

  static ThemeData get dark {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: const ColorScheme.dark(
        primary: eclipsePurple,
        onPrimary: Colors.white,
        secondary: Color(0xFF06B6D4), // Cyan
        onSecondary: Colors.black,
        surface: eclipseMidnight,
        onSurface: Colors.white,
        surfaceContainerHighest: eclipseSurface,
        onSurfaceVariant: Color(0xFF94A3B8),
        primaryContainer: Color(0xFF4C1D95),
        onPrimaryContainer: Colors.white,
        outline: Color(0xFF334155),
        error: Color(0xFFF87171),
      ),
      scaffoldBackgroundColor: eclipseDeep,
    );

    return base.copyWith(
      textTheme: GoogleFonts.outfitTextTheme(base.textTheme),
      appBarTheme: AppBarTheme(
        backgroundColor: eclipseMidnight,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: GoogleFonts.outfit(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    );
  }
}
