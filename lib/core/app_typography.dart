import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTypography {
  AppTypography._();

  static const String _fontFamily = 'Outfit';

  static TextTheme textTheme({
    String fontFamily = _fontFamily,
    Color? textColor,
    Color? labelColor,
  }) {
    final base = ThemeData(brightness: Brightness.light).textTheme;

    Color primaryColor = textColor ?? const Color(0xFF111827);
    Color secondaryColor = labelColor ?? const Color(0xFF6B7280);

    switch (fontFamily) {
      case 'Inter':
        return _buildTextTheme(
          GoogleFonts.interTextTheme(base),
          primaryColor,
          secondaryColor,
        );
      case 'Roboto':
        return _buildTextTheme(
          GoogleFonts.robotoTextTheme(base),
          primaryColor,
          secondaryColor,
        );
      case 'Poppins':
        return _buildTextTheme(
          GoogleFonts.poppinsTextTheme(base),
          primaryColor,
          secondaryColor,
        );
      case 'Lato':
        return _buildTextTheme(
          GoogleFonts.latoTextTheme(base),
          primaryColor,
          secondaryColor,
        );
      case 'Source Sans 3':
        return _buildTextTheme(
          GoogleFonts.sourceSans3TextTheme(base),
          primaryColor,
          secondaryColor,
        );
      case 'Nunito':
        return _buildTextTheme(
          GoogleFonts.nunitoTextTheme(base),
          primaryColor,
          secondaryColor,
        );
      case 'Outfit':
      default:
        return _buildTextTheme(
          GoogleFonts.outfitTextTheme(base),
          primaryColor,
          secondaryColor,
        );
    }
  }

  static TextTheme _buildTextTheme(
    TextTheme base,
    Color primary,
    Color secondary,
  ) {
    return TextTheme(
      displayLarge: TextStyle(
        fontSize: 57,
        fontWeight: FontWeight.w400,
        letterSpacing: -0.25,
        height: 1.12,
        color: primary,
      ),
      displayMedium: TextStyle(
        fontSize: 45,
        fontWeight: FontWeight.w400,
        height: 1.16,
        color: primary,
      ),
      displaySmall: TextStyle(
        fontSize: 36,
        fontWeight: FontWeight.w400,
        height: 1.22,
        color: primary,
      ),
      headlineLarge: TextStyle(
        fontSize: 32,
        fontWeight: FontWeight.w700,
        height: 1.25,
        color: primary,
      ),
      headlineMedium: TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w600,
        height: 1.29,
        color: primary,
      ),
      headlineSmall: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        height: 1.33,
        color: primary,
      ),
      titleLarge: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        height: 1.27,
        color: primary,
      ),
      titleMedium: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.15,
        height: 1.5,
        color: primary,
      ),
      titleSmall: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.1,
        height: 1.43,
        color: primary,
      ),
      bodyLarge: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        letterSpacing: 0.5,
        height: 1.5,
        color: primary,
      ),
      bodyMedium: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        letterSpacing: 0.25,
        height: 1.43,
        color: primary,
      ),
      bodySmall: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        letterSpacing: 0.4,
        height: 1.33,
        color: secondary,
      ),
      labelLarge: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.1,
        height: 1.43,
        color: primary,
      ),
      labelMedium: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
        height: 1.33,
        color: secondary,
      ),
      labelSmall: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
        height: 1.45,
        color: secondary,
      ),
    );
  }

  static TextStyle monoStyle({
    double fontSize = 13,
    FontWeight fontWeight = FontWeight.w400,
    Color? color,
  }) {
    return GoogleFonts.jetBrainsMono(
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color,
      height: 1.5,
    );
  }

  static TextStyle displayLarge([Color? color]) => GoogleFonts.outfit(
        fontSize: 32,
        fontWeight: FontWeight.w800,
        height: 1.2,
        color: color,
      );

  static TextStyle headlineLarge([Color? color]) => GoogleFonts.outfit(
        fontSize: 28,
        fontWeight: FontWeight.w700,
        height: 1.25,
        color: color,
      );

  static TextStyle titleLarge([Color? color]) => GoogleFonts.outfit(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        height: 1.3,
        color: color,
      );

  static TextStyle titleMedium([Color? color]) => GoogleFonts.outfit(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        height: 1.4,
        color: color,
      );

  static TextStyle bodyLarge([Color? color]) => GoogleFonts.outfit(
        fontSize: 15,
        fontWeight: FontWeight.w400,
        height: 1.5,
        color: color,
      );

  static TextStyle bodyMedium([Color? color]) => GoogleFonts.outfit(
        fontSize: 13,
        fontWeight: FontWeight.w400,
        height: 1.5,
        color: color,
      );

  static TextStyle labelSmall([Color? color]) => GoogleFonts.outfit(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
        height: 1.4,
        color: color,
      );

  static const List<String> availableFonts = [
    'Outfit',
    'Inter',
    'Roboto',
    'Poppins',
    'Lato',
    'Source Sans 3',
    'Nunito',
  ];
}
