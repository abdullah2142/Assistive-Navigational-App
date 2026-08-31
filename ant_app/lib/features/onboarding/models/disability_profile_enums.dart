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
