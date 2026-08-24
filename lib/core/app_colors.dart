import 'package:flutter/material.dart';

class AppColors {
  AppColors._();

  // Brand / Primary
  static const Color primary = Color(0xFF8B5CF6);
  static const Color primaryLight = Color(0xFFA78BFA);
  static const Color primaryDark = Color(0xFF7C3AED);
  static const Color primarySurface = Color(0xFF1E1630);

  // Accent / Secondary
  static const Color accent = Color(0xFF06D6A0);
  static const Color accentLight = Color(0xFF34D399);
  static const Color accentDark = Color(0xFF059669);

  // Semantic
  static const Color success = Color(0xFF06D6A0);
  static const Color successLight = Color(0xFF34D399);
  static const Color successDark = Color(0xFF059669);

  static const Color warning = Color(0xFFFBBF24);
  static const Color warningLight = Color(0xFFFCD34D);
  static const Color warningDark = Color(0xFFD97706);

  static const Color danger = Color(0xFFEF4444);
  static const Color dangerLight = Color(0xFFF87171);
  static const Color dangerDark = Color(0xFFDC2626);

  static const Color info = Color(0xFF3B82F6);
  static const Color infoLight = Color(0xFF60A5FA);
  static const Color infoDark = Color(0xFF2563EB);

  // Platform colors
  static const Color telegram = Color(0xFF26A5E4);
  static const Color discord = Color(0xFF5865F2);
  static const Color irc = Color(0xFF7B68EE);
  static const Color matrix = Color(0xFF0DBD8B);
  static const Color whatsapp = Color(0xFF25D366);
  static const Color steam = Color(0xFF1B2838);

  // Preset seed colors (used in appearance settings)
  static const Color presetEmerald = Color(0xFF10B981);
  static const Color presetSunsetOrange = Color(0xFFF97316);
  static const Color presetOceanTeal = Color(0xFF06B6D4);
  static const Color presetRose = Color(0xFFF43F5E);
  static const Color presetIndigo = Color(0xFF6366F1);

  // Legacy theme colors (for auth_layout compatibility)
  static const Color eclipseMidnight = Color(0xFF0F172A);
  static const Color eclipseDeep = Color(0xFF020617);
  static const Color eclipsePurple = Color(0xFF8B5CF6);
  static const Color arcticBlue = Color(0xFF3B82F6);
  static const Color eclipseSurface = Color(0xFF1E293B);

  // Dark theme surfaces (primary theme)
  static const Color darkBackground = Color(0xFF0A0B14);
  static const Color darkSurface = Color(0xFF111827);
  static const Color darkSurfaceRaised = Color(0xFF1F2937);
  static const Color darkSurfaceOverlay = Color(0xFF2D3748);
  static const Color darkSurfaceHover = Color(0xFF374151);

  // Light theme surfaces
  static const Color lightBackground = Color(0xFFF9FAFB);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightSurfaceRaised = Color(0xFFF3F4F6);
  static const Color lightSurfaceOverlay = Color(0xFFE5E7EB);
  static const Color lightSurfaceHover = Color(0xFFD1D5DB);

  // Borders
  static const Color borderDark = Color(0xFF374151);
  static const Color borderDarkSubtle = Color(0xFF1F2937);
  static const Color borderLight = Color(0xFFE5E7EB);
  static const Color borderLightSubtle = Color(0xFFF3F4F6);

  // Text
  static const Color textDarkPrimary = Color(0xFFF9FAFB);
  static const Color textDarkSecondary = Color(0xFF9CA3AF);
  static const Color textDarkTertiary = Color(0xFF6B7280);
  static const Color textLightPrimary = Color(0xFF111827);
  static const Color textLightSecondary = Color(0xFF6B7280);
  static const Color textLightTertiary = Color(0xFF9CA3AF);

  // Overlay / Glass
  static const Color overlayDark = Color(0xCC0A0B14);
  static const Color overlayLight = Color(0xCCFFFFFF);

  static ColorScheme darkColorScheme({Color? seed}) {
    final primaryColor = seed ?? primary;
    return ColorScheme(
      brightness: Brightness.dark,
      primary: primaryColor,
      onPrimary: Colors.white,
      primaryContainer: primarySurface,
      onPrimaryContainer: primaryLight,
      secondary: accent,
      onSecondary: Colors.black,
      secondaryContainer: accentDark,
      onSecondaryContainer: accentLight,
      tertiary: info,
      onTertiary: Colors.white,
      tertiaryContainer: infoDark,
      onTertiaryContainer: infoLight,
      error: danger,
      onError: Colors.white,
      errorContainer: dangerDark,
      onErrorContainer: dangerLight,
      surface: darkSurface,
      onSurface: textDarkPrimary,
      surfaceContainerHighest: darkSurfaceRaised,
      onSurfaceVariant: textDarkSecondary,
      outline: borderDark,
      outlineVariant: borderDarkSubtle,
      shadow: Colors.black,
      scrim: Colors.black,
      inverseSurface: lightSurface,
      onInverseSurface: textLightPrimary,
      inversePrimary: primaryDark,
      surfaceContainerLow: darkBackground,
      surfaceContainer: darkBackground,
      surfaceContainerHigh: darkSurfaceRaised,
    );
  }

  static ColorScheme lightColorScheme({Color? seed}) {
    final primaryColor = seed ?? primary;
    return ColorScheme(
      brightness: Brightness.light,
      primary: primaryColor,
      onPrimary: Colors.white,
      primaryContainer: const Color(0xFFE8E0FF),
      onPrimaryContainer: primaryDark,
      secondary: accentDark,
      onSecondary: Colors.white,
      secondaryContainer: const Color(0xFFD1FAE5),
      onSecondaryContainer: accentDark,
      tertiary: infoDark,
      onTertiary: Colors.white,
      tertiaryContainer: const Color(0xFFDBEAFE),
      onTertiaryContainer: infoDark,
      error: dangerDark,
      onError: Colors.white,
      errorContainer: const Color(0xFFFEE2E2),
      onErrorContainer: dangerDark,
      surface: lightSurface,
      onSurface: textLightPrimary,
      surfaceContainerHighest: lightSurfaceRaised,
      onSurfaceVariant: textLightSecondary,
      outline: borderLight,
      outlineVariant: borderLightSubtle,
      shadow: Colors.black,
      scrim: Colors.black,
      inverseSurface: darkSurface,
      onInverseSurface: textDarkPrimary,
      inversePrimary: primaryLight,
      surfaceContainerLow: lightBackground,
      surfaceContainer: lightBackground,
      surfaceContainerHigh: lightSurfaceRaised,
    );
  }
}
