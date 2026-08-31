import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app_colors.dart';

/// Builds the app's ThemeData.
///
/// [fontScale] and [highContrast] are driven by the Visual Calibration step
/// (Module 1) so a Low Vision user's chosen legibility settings apply
/// app-wide, not just on the calibration screen itself.
class AppTheme {
  AppTheme._();

  static ThemeData standard({double fontScale = 1.0}) => _build(
        fontScale: fontScale,
        background: AppColors.background,
        surface: AppColors.surface,
        onBackground: AppColors.textPrimary,
        primary: AppColors.primary,
        brightness: Brightness.light,
      );

  static ThemeData lowVision({double fontScale = 1.4}) => _build(
        fontScale: fontScale,
        background: AppColors.lowVisionBackground,
        surface: AppColors.lowVisionSurface,
        onBackground: AppColors.lowVisionText,
        primary: AppColors.lowVisionPrimary,
        brightness: Brightness.dark,
      );

  static ThemeData _build({
    required double fontScale,
    required Color background,
    required Color surface,
    required Color onBackground,
    required Color primary,
    required Brightness brightness,
  }) {
    final headlineFont = GoogleFonts.plusJakartaSansTextTheme();
    final bodyFont = GoogleFonts.interTextTheme();

    TextTheme textTheme = bodyFont.copyWith(
      displayLarge: headlineFont.displayLarge?.copyWith(color: onBackground),
      displayMedium: headlineFont.displayMedium?.copyWith(color: onBackground),
      displaySmall: headlineFont.displaySmall?.copyWith(color: onBackground),
      headlineLarge: headlineFont.headlineLarge?.copyWith(color: onBackground),
      headlineMedium: headlineFont.headlineMedium?.copyWith(color: onBackground),
      headlineSmall: headlineFont.headlineSmall?.copyWith(color: onBackground),
      titleLarge: headlineFont.titleLarge?.copyWith(color: onBackground),
      titleMedium: headlineFont.titleMedium?.copyWith(color: onBackground),
      titleSmall: headlineFont.titleSmall?.copyWith(color: onBackground),
      bodyLarge: bodyFont.bodyLarge?.copyWith(color: onBackground),
      bodyMedium: bodyFont.bodyMedium?.copyWith(color: onBackground),
      bodySmall: bodyFont.bodySmall?.copyWith(color: onBackground.withValues(alpha: 0.75)),
      labelLarge: bodyFont.labelLarge?.copyWith(color: onBackground),
    );

    textTheme = textTheme.apply(fontSizeFactor: fontScale);

    final colorScheme = ColorScheme(
      brightness: brightness,
      primary: primary,
      onPrimary: brightness == Brightness.dark ? Colors.black : Colors.white,
      secondary: AppColors.primaryLight,
      onSecondary: Colors.white,
      error: AppColors.danger,
      onError: Colors.white,
      surface: surface,
      onSurface: onBackground,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: background,
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        foregroundColor: onBackground,
        elevation: 0,
        centerTitle: false,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: brightness == Brightness.dark ? Colors.black : Colors.white,
          minimumSize: const Size.fromHeight(56),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: bodyFont.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primary,
          minimumSize: const Size.fromHeight(56),
          side: BorderSide(color: primary, width: 1.5),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: AppColors.divider),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      ),
      dividerColor: AppColors.divider,
      sliderTheme: SliderThemeData(
        activeTrackColor: primary,
        thumbColor: primary,
      ),
    );
  }
}
