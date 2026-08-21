import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../core/app_colors.dart';

class GibberTheme {
  static const List<String> availableFonts = [
    'Outfit',
    'Inter',
    'Roboto',
    'Poppins',
    'Lato',
    'Source Sans 3',
    'Nunito',
  ];

  static TextTheme _getTextTheme(String fontFamily, TextTheme base, ColorScheme colorScheme) {
    final primary = colorScheme.onSurface;

    switch (fontFamily) {
      case 'Inter':
        return GoogleFonts.interTextTheme(base).apply(
          bodyColor: primary,
          displayColor: primary,
        );
      case 'Roboto':
        return GoogleFonts.robotoTextTheme(base).apply(
          bodyColor: primary,
          displayColor: primary,
        );
      case 'Poppins':
        return GoogleFonts.poppinsTextTheme(base).apply(
          bodyColor: primary,
          displayColor: primary,
        );
      case 'Lato':
        return GoogleFonts.latoTextTheme(base).apply(
          bodyColor: primary,
          displayColor: primary,
        );
      case 'Source Sans 3':
        return GoogleFonts.sourceSans3TextTheme(base).apply(
          bodyColor: primary,
          displayColor: primary,
        );
      case 'Nunito':
        return GoogleFonts.nunitoTextTheme(base).apply(
          bodyColor: primary,
          displayColor: primary,
        );
      case 'Outfit':
      default:
        return GoogleFonts.outfitTextTheme(base).apply(
          bodyColor: primary,
          displayColor: primary,
        );
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
    Color? seedColor,
    String fontFamily = 'Outfit',
    bool amoledMode = false,
    ColorScheme? dynamicScheme,
  }) {
    final colorScheme = dynamicScheme ??
        (brightness == Brightness.dark
            ? AppColors.darkColorScheme(seed: seedColor)
            : AppColors.lightColorScheme(seed: seedColor));

    final effectiveScheme = (amoledMode && brightness == Brightness.dark)
        ? colorScheme.copyWith(
            surface: Colors.black,
            surfaceContainerLow: const Color(0xFF050505),
            surfaceContainer: const Color(0xFF0A0A0A),
            surfaceContainerHigh: const Color(0xFF111111),
            surfaceContainerHighest: const Color(0xFF1A1A1A),
            surfaceContainerLowest: Colors.black,
            inverseSurface: const Color(0xFF1A1A1A),
          )
        : colorScheme;

    final textTheme = _getTextTheme(fontFamily, ThemeData(brightness: brightness).textTheme, effectiveScheme);

    ThemeData base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: effectiveScheme,
      scaffoldBackgroundColor: effectiveScheme.surface,
      textTheme: textTheme,
    );

    final titleColor = effectiveScheme.onSurface;

    return base.copyWith(
      appBarTheme: AppBarTheme(
        backgroundColor: effectiveScheme.surface,
        foregroundColor: titleColor,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: _getAppBarTitleStyle(fontFamily, titleColor),
        surfaceTintColor: Colors.transparent,
        iconTheme: IconThemeData(color: effectiveScheme.onSurface),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: effectiveScheme.outlineVariant.withValues(alpha: 0.5)),
        ),
        color: effectiveScheme.surfaceContainerHighest,
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: effectiveScheme.surfaceContainerHighest,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: effectiveScheme.outlineVariant.withValues(alpha: 0.3)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: effectiveScheme.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: effectiveScheme.error),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          backgroundColor: effectiveScheme.primary,
          foregroundColor: effectiveScheme.onPrimary,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          side: BorderSide(color: effectiveScheme.outline),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: effectiveScheme.surface,
        indicatorColor: effectiveScheme.primaryContainer,
        selectedIconTheme: IconThemeData(color: effectiveScheme.onPrimaryContainer),
        unselectedIconTheme: IconThemeData(color: effectiveScheme.onSurfaceVariant),
        labelType: NavigationRailLabelType.all,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: effectiveScheme.surface,
        indicatorColor: effectiveScheme.primaryContainer,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: effectiveScheme.onSurface,
            );
          }
          return TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: effectiveScheme.onSurfaceVariant,
          );
        }),
      ),
      dividerTheme: DividerThemeData(
        color: effectiveScheme.outlineVariant.withValues(alpha: 0.5),
        thickness: 1,
        space: 1,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: effectiveScheme.surface,
        modalBackgroundColor: effectiveScheme.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: effectiveScheme.surface,
        elevation: 8,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        backgroundColor: effectiveScheme.inverseSurface,
        contentTextStyle: TextStyle(color: effectiveScheme.onInverseSurface),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: effectiveScheme.surfaceContainerHighest,
        selectedColor: effectiveScheme.primaryContainer,
        labelStyle: TextStyle(color: effectiveScheme.onSurface, fontSize: 13),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        side: BorderSide.none,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: effectiveScheme.inverseSurface,
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: TextStyle(color: effectiveScheme.onInverseSurface, fontSize: 12),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: effectiveScheme.surfaceContainerHigh,
        elevation: 8,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStateProperty.all(effectiveScheme.onSurface.withValues(alpha: 0.3)),
        radius: const Radius.circular(4),
        thickness: WidgetStateProperty.all(6),
      ),
    );
  }

  static ThemeData get light => buildTheme(
        brightness: Brightness.light,
        seedColor: AppColors.primary,
        fontFamily: 'Outfit',
      );

  static ThemeData get dark => buildTheme(
        brightness: Brightness.dark,
        seedColor: AppColors.primary,
        fontFamily: 'Outfit',
      );

  static ThemeData darkAmoled([String fontFamily = 'Outfit']) => buildTheme(
        brightness: Brightness.dark,
        seedColor: AppColors.primary,
        fontFamily: fontFamily,
        amoledMode: true,
      );

  // Legacy theme colors (for auth_layout compatibility)
  static const Color eclipseMidnight = AppColors.eclipseMidnight;
  static const Color eclipseDeep = AppColors.eclipseDeep;
  static const Color eclipsePurple = AppColors.eclipsePurple;
  static const Color arcticBlue = AppColors.arcticBlue;
  static const Color eclipseSurface = AppColors.eclipseSurface;
}
