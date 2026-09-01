import 'package:flutter/material.dart';

import '../../features/onboarding/models/disability_profile_enums.dart';
import '../../features/onboarding/models/user_profile.dart';
import 'app_theme.dart';

/// Resolves which [ThemeData] a signed-in user should see, given their
/// profile — the single source of truth `MaterialApp.theme` reads from
/// (see `main.dart`), so it applies uniformly to *every* route on the app's
/// Navigator, including ones reached via `Navigator.push` (a screen-local
/// `Theme(...)` wrap only covers its own route's build output, not routes
/// pushed on top of it — that gap is what sent [MySettingsScreen] to app
/// bar's dark toggle looking light before this existed).
///
/// Onboarding itself always stays on the standard light theme regardless of
/// answers given so far — [UserProfile.onboardingComplete] gates the
/// switch, so a mid-flow Low Vision or Dark pick doesn't retheme onboarding
/// screens that were never audited for it (they use the same shared
/// building blocks, but haven't been checked against every theme).
ThemeData resolveThemeForProfile(UserProfile? profile) {
  if (profile == null || !profile.onboardingComplete) return AppTheme.standard();
  final dark = profile.themePreference == ThemePreference.dark;
  // Low Vision and Light/Dark are independent axes: a Low Vision user still
  // picks Light or Dark like anyone else (asked in onboarding, changeable in
  // Settings), and gets the matching high-contrast variant rather than one
  // theme forced regardless of preference.
  if (profile.visionLevel == VisionLevel.low) {
    return dark
        ? AppTheme.highContrastDark(fontScale: profile.fontScale)
        : AppTheme.highContrastLight(fontScale: profile.fontScale);
  }
  return dark ? AppTheme.standardDark(fontScale: profile.fontScale) : AppTheme.standard(fontScale: profile.fontScale);
}
