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
        divider: AppColors.divider,
        brightness: Brightness.light,
      );

  /// Standard "Calm" Dark theme (Module 2) — picked during onboarding via
  /// [ThemePreference.dark]. Distinct from [highContrastDark]: this is the
  /// softer palette anyone gets, not the Low Vision accessibility variant.
  static ThemeData standardDark({double fontScale = 1.0}) => _build(
        fontScale: fontScale,
        background: AppColors.darkBackground,
        surface: AppColors.darkSurface,
        onBackground: AppColors.darkText,
        primary: AppColors.primaryLight,
        divider: AppColors.darkDivider,
        brightness: Brightness.dark,
      );

  /// Low Vision's high-contrast theme, dark half — paired with
  /// [ThemePreference.dark]. Maximum contrast (pure black/white) instead of
  /// the softer Standard Dark palette, on top of whatever [fontScale] was
  /// calibrated. See [highContrastLight] for the light half — Low Vision
  /// users pick Light/Dark same as anyone, this only swaps the palette.
  static ThemeData highContrastDark({double fontScale = 1.4}) => _build(
        fontScale: fontScale,
        background: AppColors.highContrastDarkBackground,
        surface: AppColors.highContrastDarkSurface,
        onBackground: AppColors.highContrastDarkText,
        primary: AppColors.highContrastDarkPrimary,
        divider: AppColors.highContrastDarkText,
        brightness: Brightness.dark,
      );

  /// Low Vision's high-contrast theme, light half — paired with
  /// [ThemePreference.light]. Pure white background, pure black text.
  static ThemeData highContrastLight({double fontScale = 1.4}) => _build(
        fontScale: fontScale,
        background: AppColors.highContrastLightBackground,
        surface: AppColors.highContrastLightSurface,
        onBackground: AppColors.highContrastLightText,
        primary: AppColors.highContrastLightPrimary,
        divider: AppColors.highContrastLightText,
        brightness: Brightness.light,
      );

  static ThemeData _build({
    required double fontScale,
    required Color background,
    required Color surface,
    required Color onBackground,
    required Color primary,
    required Color divider,
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

    // Not `textTheme.apply(fontSizeFactor: fontScale)` — that throws
    // ("fontSize != null || (fontSizeFactor == 1.0 && fontSizeDelta ==
    // 0.0)") the moment `fontScale != 1.0` if any style has a null
    // `fontSize`. That used to look like a rare edge case worth skipping
    // defensively — it isn't: on this Flutter SDK, `fontSize` comes back
    // null for *every* Material 3 text style by default (confirmed
    // directly: even plain `ThemeData.light().textTheme.bodyLarge?.fontSize`
    // is null here, google_fonts included — the framework resolves the
    // actual rendered size some other way that isn't exposed on the
    // `TextStyle` itself). The previous "skip scaling when null" guard
    // therefore made `fontScale` a silent no-op across literally the whole
    // app — the text-size slider/setting has never visibly done anything
    // outside of a screen-local preview hack. Fixed by always assigning an
    // explicit `fontSize`: honor whatever's already on the style if
    // non-null (respects the day this SDK starts populating it again), else
    // fall back to the documented Material 3 type-scale default for that
    // slot — then multiply by `fontScale` either way, so scaling always
    // actually applies.
    TextStyle? scaled(TextStyle? style, double materialDefaultSize) =>
        style?.copyWith(fontSize: (style.fontSize ?? materialDefaultSize) * fontScale);
    textTheme = TextTheme(
      displayLarge: scaled(textTheme.displayLarge, 57),
      displayMedium: scaled(textTheme.displayMedium, 45),
      displaySmall: scaled(textTheme.displaySmall, 36),
      headlineLarge: scaled(textTheme.headlineLarge, 32),
      headlineMedium: scaled(textTheme.headlineMedium, 28),
      headlineSmall: scaled(textTheme.headlineSmall, 24),
      titleLarge: scaled(textTheme.titleLarge, 22),
      titleMedium: scaled(textTheme.titleMedium, 16),
      titleSmall: scaled(textTheme.titleSmall, 14),
      bodyLarge: scaled(textTheme.bodyLarge, 16),
      bodyMedium: scaled(textTheme.bodyMedium, 14),
      bodySmall: scaled(textTheme.bodySmall, 12),
      labelLarge: scaled(textTheme.labelLarge, 14),
      labelMedium: scaled(textTheme.labelMedium, 12),
      labelSmall: scaled(textTheme.labelSmall, 11),
    );

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
          borderSide: BorderSide(color: divider),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      ),
      dividerColor: divider,
      sliderTheme: SliderThemeData(
        activeTrackColor: primary,
        thumbColor: primary,
      ),
    );
  }
}
