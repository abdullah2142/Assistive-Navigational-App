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

  // Neutrals.
  static const Color background = Color(0xFFF7F5FA);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color textPrimary = Color(0xFF2B2438);
  static const Color textSecondary = Color(0xFF6B6377);
  static const Color divider = Color(0xFFE3DEEC);

  // Semantic — kept desaturated to stay "calm," never alarm-red.
  static const Color success = Color(0xFF3E8E6B);
  static const Color caution = Color(0xFFC98A3B);
  static const Color danger = Color(0xFFB4534F);

  // Crowdsourced hazard flags (Module 5 terminology, defined here so the
  // palette stays centralized).
  static const Color flagYellow = Color(0xFFC98A3B);
  static const Color flagRed = Color(0xFFB4534F);

  // Low Vision Theme — captured during Visual Calibration (Module 1, Step 2).
  // Pure black/white + the same hue family, but at maximum contrast.
  static const Color lowVisionBackground = Color(0xFF000000);
  static const Color lowVisionSurface = Color(0xFF0D0D0D);
  static const Color lowVisionText = Color(0xFFFFFFFF);
  static const Color lowVisionPrimary = Color(0xFFB6A3E0);
}
