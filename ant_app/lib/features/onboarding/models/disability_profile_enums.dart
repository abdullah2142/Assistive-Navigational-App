/// Step 2.1 — Vision Level. `low` triggers the Visual Calibration Phase.
enum VisionLevel {
  none,
  low,
  full;

  static VisionLevel fromFirestore(String? value) =>
      VisionLevel.values.firstWhere((v) => v.name == value, orElse: () => VisionLevel.full);
}

/// Step 2.2 — Mobility Aids. Drives the $w_2$ terrain routing weight
/// (zero-curb / ramp preference for wheelchair users).
enum MobilityAid {
  whiteCane,
  wheelchair,
  unassisted;

  static MobilityAid fromFirestore(String? value) =>
      MobilityAid.values.firstWhere((v) => v.name == value, orElse: () => MobilityAid.unassisted);
}

/// Step 3.1 — How "chatty" the conversational AI should be.
enum VerbosityLevel {
  minimalist,
  descriptive;

  static VerbosityLevel fromFirestore(String? value) => VerbosityLevel.values
      .firstWhere((v) => v.name == value, orElse: () => VerbosityLevel.descriptive);
}

/// Display theme preference (Module 2's UI core) — asked of every Disabled
/// User, including Low Vision. Independent of the high-contrast
/// accommodation Low Vision gets: that swaps the *palette* to maximum
/// contrast, this still picks which half (light or dark) of it applies
/// (see `AppTheme`/`theme_resolver.dart`).
enum ThemePreference {
  light,
  dark;

  static ThemePreference fromFirestore(String? value) =>
      ThemePreference.values.firstWhere((v) => v.name == value, orElse: () => ThemePreference.light);
}

/// Step 3.4 — Whether the paired Caretaker may trigger a Snapshot Request
/// (Module 6's Vision Engine captures/delivers one frame) without the
/// Disabled User's live, per-request consent. Defaults to [askEachTime] —
/// the most privacy-preserving choice — never [always].
enum SnapshotConsentPreference {
  always,
  askEachTime,
  never;

  static SnapshotConsentPreference fromFirestore(String? value) => SnapshotConsentPreference.values
      .firstWhere((v) => v.name == value, orElse: () => SnapshotConsentPreference.askEachTime);
}

/// How hard the haptic patterns should be.
///
/// `07_module_plan_haptics.md` step 3.1: "Older devices have weaker motors, so
/// the app will allow setting the default vibration amplitude to High, Medium
/// or Low." The test device for this project is a budget Xiaomi, and a pattern
/// a blind user cannot feel through a pocket is not feedback.
///
/// Low is not only for weak motors — it is also for a user who finds a strong
/// buzz startling, which for someone already anxious in a crowd is its own
/// kind of failure.
enum HapticIntensity {
  high,
  medium,
  low;

  static HapticIntensity fromFirestore(String? value) =>
      HapticIntensity.values.firstWhere((v) => v.name == value, orElse: () => HapticIntensity.medium);
}
