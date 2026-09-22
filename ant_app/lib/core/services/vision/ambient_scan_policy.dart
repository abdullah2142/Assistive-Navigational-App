import '../../config/vision_config.dart';
import 'vision_detection.dart';

/// Why an ambient scan was or was not taken.
///
/// An enum rather than a bool because "not now" has several reasons and they
/// are not interchangeable — one of them is a flat battery and another is the
/// user standing still, and only the first is worth telling anybody about.
enum AmbientDecision {
  /// Take a look.
  scan,

  /// The user has not moved far enough since the last scan.
  stationary,

  /// Not enough time has passed for the current pace.
  tooSoon,

  /// Battery is too low to spend on convenience scanning.
  batteryLow,

  /// This user did not ask for it, or can see well enough not to need it.
  notEnabled,
}

/// Decides when the app should look around without being asked.
///
/// ## Why this is a separate, pure class
///
/// Everything here is arithmetic over (profile, position, clock, battery),
/// and all of it decides how often a camera opens on somebody's phone for
/// hours at a time. That is exactly the sort of thing that must be testable
/// by feeding it a synthetic walk rather than by carrying a handset around
/// Dhaka for an afternoon — the same split `NavigationNarrator` has from
/// `NavigationController`, for the same reason.
///
/// The timer, the camera and the battery channel live in
/// `AmbientHazardScanner`. Nothing in this file can drain anything.
class AmbientScanPolicy {
  AmbientScanPolicy({
    this.interval = VisionConfig.ambientInterval,
    this.alertInterval = VisionConfig.ambientAlertInterval,
    this.calmInterval = VisionConfig.ambientCalmInterval,
    this.calmAfter = VisionConfig.ambientCalmAfter,
    this.minMovementMeters = VisionConfig.ambientMinMovementMeters,
    this.minBatteryPercent = VisionConfig.ambientMinBatteryPercent,
  });

  final Duration interval;
  final Duration alertInterval;
  final Duration calmInterval;
  final int calmAfter;
  final double minMovementMeters;
  final int minBatteryPercent;

  DateTime? _lastScanAt;
  int _consecutiveClear = 0;

  /// True while the user is near a reported hazard or an approaching
  /// crossing — set by the scanner from the live route.
  bool alert = false;

  /// How long to wait before the next look, given what the last few found.
  Duration get currentInterval {
    if (alert) return alertInterval;
    return _consecutiveClear >= calmAfter ? calmInterval : interval;
  }

  int get consecutiveClear => _consecutiveClear;

  /// Whether to scan now.
  ///
  /// [metersMoved] is distance since the last scan; [batteryPercent] null
  /// means the platform would not say, which is **not** treated as low — a
  /// device that will not report its battery must not silently lose the
  /// feature, and every other guard still applies.
  AmbientDecision decide({
    required bool enabled,
    required DateTime now,
    required double metersMoved,
    int? batteryPercent,
  }) {
    if (!enabled) return AmbientDecision.notEnabled;
    if (batteryPercent != null && batteryPercent < minBatteryPercent) {
      return AmbientDecision.batteryLow;
    }

    final last = _lastScanAt;
    if (last != null && now.difference(last) < currentInterval) {
      return AmbientDecision.tooSoon;
    }

    // Checked after the clock, so a stationary user is not re-evaluated every
    // tick — and *not* applied to the very first scan, which should happen as
    // soon as walking starts rather than after the first 8 metres.
    if (last != null && metersMoved < minMovementMeters) {
      return AmbientDecision.stationary;
    }

    return AmbientDecision.scan;
  }

  /// Records that a scan happened and what it found, which sets the pace for
  /// the next one.
  void recordScan(DateTime now, HazardVerdict verdict) {
    _lastScanAt = now;
    if (verdict.level == HazardLevel.clear) {
      _consecutiveClear++;
    } else {
      // Anything seen resets the pace to attentive. A street that produced
      // one hazard is a street likely to produce another, and backing off
      // there is the wrong moment to save battery.
      _consecutiveClear = 0;
    }
  }

  /// Forgets the pacing history — on a new journey, or when scanning is
  /// switched back on. Without this a walk that starts right after a calm
  /// stretch inherits the 60-second interval.
  void reset() {
    _lastScanAt = null;
    _consecutiveClear = 0;
    alert = false;
  }
}
