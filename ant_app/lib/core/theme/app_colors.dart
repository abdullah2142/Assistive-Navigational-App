import 'package:flutter/material.dart';

/// "Accessible Calm" design system palette.
/// Do not use generic Material colors (Colors.red, Colors.blue, etc.) anywhere
/// in the app — always reference these tokens so the calming aesthetic and
/// contrast guarantees stay consistent.
class AppColors {
  AppColors._();

  // Primary brand.
  static const Color primary = Color(0xFF664D8F);
  static const Color primaryLight = Color(0xFF8B72B3);
  static const Color primaryDark = Color(0xFF453465);

  // Neutrals — Standard "Calm" Light theme. Exact hexes per the UI module
  // plan: soft cream background, deep slate text.
  static const Color background = Color(0xFFF8F7FA);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color textPrimary = Color(0xFF2D2A3B);
  static const Color textSecondary = Color(0xFF6B6377);
  static const Color divider = Color(0xFFE3DEEC);

  // Standard "Calm" Dark theme (Module 2) — deep plum/charcoal background,
  // soft off-white text, exact hexes per the UI module plan. Surface/divider/
  // secondary-text are derived tones within the same hue family (the plan
  // only specifies background + text for dark mode).
  static const Color darkBackground = Color(0xFF120F1D);
  static const Color darkSurface = Color(0xFF1E1930);
  static const Color darkText = Color(0xFFEAE8F2);
  static const Color darkTextSecondary = Color(0xFFB0A9C7);
  static const Color darkDivider = Color(0xFF34294D);

  // Semantic — kept desaturated to stay "calm," never alarm-red.
  static const Color success = Color(0xFF3E8E6B);
  static const Color caution = Color(0xFFC98A3B);
  static const Color danger = Color(0xFFB4534F);

  // Crowdsourced hazard flags (Module 5 terminology, defined here so the
  // palette stays centralized).
  static const Color flagYellow = Color(0xFFC98A3B);
  static const Color flagRed = Color(0xFFB4534F);

  // High Contrast theme — for Low Vision users (Visual Calibration, Module
  // 1 Step 2). This is an accessibility axis *independent* of the
  // Light/Dark theme choice, not a replacement for it: a Low Vision user
  // still picks Light or Dark like anyone else, and gets the matching
  // high-contrast variant below rather than one fixed combination.
  static const Color highContrastDarkBackground = Color(0xFF000000);
  static const Color highContrastDarkSurface = Color(0xFF0D0D0D);
  static const Color highContrastDarkText = Color(0xFFFFFFFF);
  static const Color highContrastDarkPrimary = Color(0xFFB6A3E0);

  static const Color highContrastLightBackground = Color(0xFFFFFFFF);
  static const Color highContrastLightSurface = Color(0xFFFFFFFF);
  static const Color highContrastLightText = Color(0xFF000000);
  static const Color highContrastLightPrimary = Color(0xFF4B2E83);

  // "Show Screen" Passerby Helper overlay (Module 2, Step 4) — solid bright
  // yellow with massive black text, per the UI module plan's exact hex.
  static const Color passerbyHelperBackground = Color(0xFFE5C05C);
  static const Color passerbyHelperText = Color(0xFF000000);
}
