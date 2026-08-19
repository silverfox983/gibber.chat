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

  static TextTheme _getTextTheme(String fontFamily, TextTheme base, Brightness brightness) {
    Color primary;
    if (brightness == Brightness.dark) {
      primary = AppColors.textDarkPrimary;
    } else {
      primary = AppColors.textLightPrimary;
    }

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

    final textTheme = _getTextTheme(fontFamily, ThemeData(brightness: brightness).textTheme, brightness);

    ThemeData base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colorScheme.surface,
      textTheme: textTheme,
    );

    final titleColor = colorScheme.onSurface;

    return base.copyWith(
      appBarTheme: AppBarTheme(
        backgroundColor: colorScheme.surface,
        foregroundColor: titleColor,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: _getAppBarTitleStyle(fontFamily, titleColor),
        surfaceTintColor: Colors.transparent,
        iconTheme: IconThemeData(color: colorScheme.onSurface),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.5)),
        ),
        color: colorScheme.surfaceContainerHighest,
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colorScheme.surfaceContainerHighest,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.3)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colorScheme.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colorScheme.error),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          backgroundColor: colorScheme.primary,
          foregroundColor: colorScheme.onPrimary,
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
          side: BorderSide(color: colorScheme.outline),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: colorScheme.surface,
        indicatorColor: colorScheme.primaryContainer,
        selectedIconTheme: IconThemeData(color: colorScheme.onPrimaryContainer),
        unselectedIconTheme: IconThemeData(color: colorScheme.onSurfaceVariant),
        labelType: NavigationRailLabelType.all,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: colorScheme.surface,
        indicatorColor: colorScheme.primaryContainer,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurface,
            );
          }
          return TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: colorScheme.onSurfaceVariant,
          );
        }),
      ),
      dividerTheme: DividerThemeData(
        color: colorScheme.outlineVariant.withValues(alpha: 0.5),
        thickness: 1,
        space: 1,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colorScheme.surface,
        modalBackgroundColor: colorScheme.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: colorScheme.surface,
        elevation: 8,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        backgroundColor: colorScheme.inverseSurface,
        contentTextStyle: TextStyle(color: colorScheme.onInverseSurface),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: colorScheme.surfaceContainerHighest,
        selectedColor: colorScheme.primaryContainer,
        labelStyle: TextStyle(color: colorScheme.onSurface, fontSize: 13),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        side: BorderSide.none,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: colorScheme.inverseSurface,
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: TextStyle(color: colorScheme.onInverseSurface, fontSize: 12),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: colorScheme.surfaceContainerHigh,
        elevation: 8,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStateProperty.all(colorScheme.onSurface.withValues(alpha: 0.3)),
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
