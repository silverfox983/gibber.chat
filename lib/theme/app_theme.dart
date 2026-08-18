import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class GibberTheme {
  static const Color arcticBlue = Color(0xFF3B82F6);
  static const Color arcticSurface = Color(0xFFF9FAFB);
  static const Color arcticOutline = Color(0xFFE5E7EB);

  static const Color eclipsePurple = Color(0xFF8B5CF6);
  static const Color eclipseMidnight = Color(0xFF0F172A);
  static const Color eclipseDeep = Color(0xFF020617);
  static const Color eclipseSurface = Color(0xFF1E293B);

  static const List<String> availableFonts = [
    'Outfit',
    'Inter',
    'Roboto',
    'Poppins',
    'Lato',
    'Source Sans 3',
    'Nunito',
  ];

  static TextTheme _getTextTheme(String fontFamily, TextTheme base) {
    switch (fontFamily) {
      case 'Inter':
        return GoogleFonts.interTextTheme(base);
      case 'Roboto':
        return GoogleFonts.robotoTextTheme(base);
      case 'Poppins':
        return GoogleFonts.poppinsTextTheme(base);
      case 'Lato':
        return GoogleFonts.latoTextTheme(base);
      case 'Source Sans 3':
        return GoogleFonts.sourceSans3TextTheme(base);
      case 'Nunito':
        return GoogleFonts.nunitoTextTheme(base);
      case 'Outfit':
      default:
        return GoogleFonts.outfitTextTheme(base);
    }
  }

  static TextStyle _getAppBarTitleStyle(String fontFamily, Color color) {
    switch (fontFamily) {
      case 'Inter':
        return GoogleFonts.inter(fontSize: 20, fontWeight: FontWeight.w700, color: color);
      case 'Roboto':
        return GoogleFonts.roboto(fontSize: 20, fontWeight: FontWeight.w700, color: color);
      case 'Poppins':
        return GoogleFonts.poppins(fontSize: 20, fontWeight: FontWeight.w700, color: color);
      case 'Lato':
        return GoogleFonts.lato(fontSize: 20, fontWeight: FontWeight.w700, color: color);
      case 'Source Sans 3':
        return GoogleFonts.sourceSans3(fontSize: 20, fontWeight: FontWeight.w700, color: color);
      case 'Nunito':
        return GoogleFonts.nunito(fontSize: 20, fontWeight: FontWeight.w700, color: color);
      case 'Outfit':
      default:
        return GoogleFonts.outfit(fontSize: 20, fontWeight: FontWeight.w700, color: color);
    }
  }

  static ThemeData buildTheme({
    required Brightness brightness,
    required Color seedColor,
    required String fontFamily,
    bool amoledMode = false,
    ColorScheme? dynamicScheme,
  }) {
    ColorScheme colorScheme;

    if (dynamicScheme != null) {
      colorScheme = dynamicScheme;
    } else {
      colorScheme = ColorScheme.fromSeed(
        seedColor: seedColor,
        brightness: brightness,
      );
    }

    if (amoledMode && brightness == Brightness.dark) {
      colorScheme = ColorScheme(
        brightness: Brightness.dark,
        primary: colorScheme.primary,
        onPrimary: colorScheme.onPrimary,
        primaryContainer: colorScheme.primaryContainer,
        onPrimaryContainer: colorScheme.onPrimaryContainer,
        secondary: colorScheme.secondary,
        onSecondary: colorScheme.onSecondary,
        secondaryContainer: colorScheme.secondaryContainer,
        onSecondaryContainer: colorScheme.onSecondaryContainer,
        tertiary: colorScheme.tertiary,
        onTertiary: colorScheme.onTertiary,
        tertiaryContainer: colorScheme.tertiaryContainer,
        onTertiaryContainer: colorScheme.onTertiaryContainer,
        error: colorScheme.error,
        onError: colorScheme.onError,
        errorContainer: colorScheme.errorContainer,
        onErrorContainer: colorScheme.onErrorContainer,
        surface: Colors.black,
        onSurface: Colors.white,
        surfaceContainerHighest: const Color(0xFF1E293B),
        onSurfaceVariant: const Color(0xFF94A3B8),
        outline: const Color(0xFF334155),
        outlineVariant: const Color(0xFF1E293B),
        shadow: Colors.black,
        scrim: Colors.black,
        inverseSurface: Colors.white,
        onInverseSurface: Colors.black,
        inversePrimary: colorScheme.primary.withValues(alpha: 0.6),
        surfaceContainerLow: Colors.black,
        surfaceContainer: Colors.black,
        surfaceContainerHigh: const Color(0xFF0F0F0F),
      );
    }

    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: amoledMode && brightness == Brightness.dark
          ? Colors.black
          : colorScheme.surface,
    );

    final textTheme = _getTextTheme(fontFamily, base.textTheme);
    final appBarTitleColor = brightness == Brightness.dark
        ? (amoledMode ? Colors.white : colorScheme.onSurface)
        : colorScheme.onSurface;

    return base.copyWith(
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: amoledMode && brightness == Brightness.dark
            ? Colors.black
            : (brightness == Brightness.dark ? eclipseMidnight : Colors.white),
        foregroundColor: appBarTitleColor,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: _getAppBarTitleStyle(fontFamily, appBarTitleColor),
      ),
    );
  }

  static ThemeData get light => buildTheme(
        brightness: Brightness.light,
        seedColor: arcticBlue,
        fontFamily: 'Outfit',
      );

  static ThemeData get dark => buildTheme(
        brightness: Brightness.dark,
        seedColor: eclipsePurple,
        fontFamily: 'Outfit',
        amoledMode: false,
      );
}
