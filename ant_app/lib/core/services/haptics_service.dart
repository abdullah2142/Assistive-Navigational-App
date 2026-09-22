import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:vibration/vibration.dart';

import '../../features/onboarding/models/disability_profile_enums.dart';
import 'routing_service.dart' show ManeuverKind;

// The named parameters below are deliberately not initializing formals:
// they are named for the caller ('store', 'tts') while the fields are
// private ('_store', '_tts'), which is the convention across this
// codebase and what makes the constructors readable at the call site.
// ignore_for_file: prefer_initializing_formals

/// The three-pattern haptic language from `07_module_plan_haptics.md`.
///
/// The plan restricts the dictionary to exactly three patterns, on purpose —
/// a larger vocabulary is something the user has to remember while walking,
/// which is the cognitive load this whole app exists to avoid.
///
/// Before this, eight call sites reached for `HapticFeedback` directly with
/// whatever constant seemed right. That is not a language: `mediumImpact` at a
/// turn and `mediumImpact` when a mic opens say the same thing about two
/// unrelated events, and none of it could be scaled for a weak motor.
enum HapticCue {
  /// A navigation event whose direction is not left or right — setting off,
  /// carrying straight on, a re-plan. Always accompanied by a voice prompt.
  navigation,

  /// Turn **left**: one pulse.
  ///
  /// Reported from the 22 September session — "the haptics are out of sync"
  /// and "might confuse user about which direction to turn". Every turn, in
  /// either direction, played the identical single [navigation] buzz, so the
  /// haptic channel carried the *timing* of a turn and none of its content.
  /// A user walking with a cane, phone in a pocket, felt the same thing at a
  /// left as at a right and had only the speech to go on — and speech is the
  /// channel most easily lost to traffic noise, which is exactly when a
  /// pedestrian crossing needs it most.
  ///
  /// Encoded by **count**, one versus two, because count survives a weak
  /// motor and a thick pocket where a duration difference does not. Both
  /// turn cues use a faster pulse and a wider gap than [confirmation] so
  /// "turn right" and "that worked" are not the same two taps.
  ///
  /// Still never the sole carrier: the spoken instruction always names the
  /// direction too. This makes the haptic agree with it instead of being
  /// silent about it.
  turnLeft,

  /// Turn **right**: two pulses. See [turnLeft].
  turnRight,

  /// Positive reinforcement — arrival, an SOS that went out, a confirmed
  /// selection.
  confirmation,

  /// Immediate danger. Stop moving.
  hazard,
}

/// The turn cue for [kind], or [HapticCue.navigation] when the manoeuvre has
/// no left/right sense to encode.
///
/// Slight and sharp turns map onto their own side rather than to a fourth
/// and fifth pattern: the plan's point about a small dictionary stands, and
/// "which side" is the question the cue has to answer. How sharp it is, the
/// voice says.
HapticCue turnCueFor(ManeuverKind kind) => switch (kind) {
      ManeuverKind.slightLeft || ManeuverKind.left || ManeuverKind.sharpLeft => HapticCue.turnLeft,
      ManeuverKind.slightRight || ManeuverKind.right || ManeuverKind.sharpRight => HapticCue.turnRight,
      _ => HapticCue.navigation,
    };

/// Speaks the haptic language, at the strength the user asked for.
///
/// `HapticFeedback` cannot set amplitude, which is the whole reason the
/// `vibration` package is here: the plan calls for High/Medium/Low because
/// "older devices have weaker motors", and the test device for this project is
/// a budget Xiaomi. A pattern that a blind user cannot feel through a pocket
/// is not feedback.
class HapticsService {
  /// [probeOverride] lets a test decide what the motor can do without a
  /// platform channel — `vibration` has no injectable surface of its own, and
  /// the interesting logic here is the amplitude maths and the throttle, not
  /// the plugin call.
  HapticsService({@visibleForTesting ({bool motor, bool amplitude})? probeOverride})
      : _probeOverride = probeOverride;

  final ({bool motor, bool amplitude})? _probeOverride;

  /// Resolved once, lazily. Probing the platform costs a channel round trip
  /// and the answer does not change while the app is running.
  bool _hasAmplitudeControl = false;
  bool _hasVibrator = false;
  bool _probed = false;

  HapticIntensity intensity = HapticIntensity.medium;

  /// Last time the hazard alarm fired, for the throttle below.
  DateTime? _lastHazard;

  /// Step 3.2 of the plan, "Sensory Overload Protection": a crowded street can
  /// produce hazards continuously, and an alarm that fires on every one of
  /// them panics the person it is meant to protect. One every five seconds,
  /// and the assistant's voice carries the rest.
  static const Duration hazardThrottle = Duration(seconds: 5);

  /// Durations from the plan, in milliseconds.
  static const int _navigationMs = 100;
  static const int _confirmationGapMs = 50;
  static const int _hazardMs = 1000;

  /// Turn cues: shorter pulse, wider gap than [_navigationMs]/
  /// [_confirmationGapMs], so two-pulse "right" cannot be mistaken for
  /// two-pulse "confirmed". See [HapticCue.turnLeft].
  static const int _turnMs = 70;
  static const int _turnGapMs = 90;

  /// Probes the motor once. The answer does not change while the app runs,
  /// and each probe is a platform channel round trip on the path of a cue
  /// that is meant to be instant.
  Future<void> _probe() async {
    if (_probed) return;
    _probed = true;
    final override = _probeOverride;
    if (override != null) {
      _hasVibrator = override.motor;
      _hasAmplitudeControl = override.amplitude;
      return;
    }
    _hasVibrator = await _guard(() => Vibration.hasVibrator(), orElse: false);
    if (!_hasVibrator) return;
    _hasAmplitudeControl = await _guard(() => Vibration.hasAmplitudeControl(), orElse: false);
  }

  /// The amplitude a cue would be played at, for tests and for the settings
  /// screen's preview.
  @visibleForTesting
  int amplitudeFor(HapticCue cue) => _amplitudeFor(cue)!;


  Future<T> _guard<T>(Future<T> Function() probe, {required T orElse}) async {
    try {
      return await probe();
    } catch (e) {
      debugPrint('[Haptics] capability probe failed: $e');
      return orElse;
    }
  }

  /// 1-255, or `null` when this device cannot scale and the pattern has to be
  /// played at whatever strength the motor gives.
  int? _amplitudeFor(HapticCue cue) {
    final base = switch (intensity) {
      HapticIntensity.high => 1.0,
      HapticIntensity.medium => 0.6,
      HapticIntensity.low => 0.3,
    };
    // The hazard alarm is specified as max-intensity. Scaling still applies —
    // a user who set Low did so because High hurts or startles — but it is
    // always the strongest of the three.
    final weight = cue == HapticCue.hazard ? 1.0 : 0.75;
    return ((base * weight) * 255).round().clamp(1, 255);
  }

  Future<void> play(HapticCue cue) async {
    if (cue == HapticCue.hazard) {
      final last = _lastHazard;
      if (last != null && DateTime.now().difference(last) < hazardThrottle) {
        debugPrint('[Haptics] hazard alarm throttled');
        return;
      }
      _lastHazard = DateTime.now();
    }

    await _probe();
    if (!_hasVibrator) {
      // No motor, or a platform that will not say. The system haptics are
      // weaker and unscalable but they are not nothing, and a silent failure
      // here is a cue the user simply never receives.
      await _fallback(cue);
      return;
    }

    final amplitude = _hasAmplitudeControl ? _amplitudeFor(cue) : null;
    try {
      switch (cue) {
        case HapticCue.navigation:
          await Vibration.vibrate(duration: _navigationMs, amplitude: amplitude ?? -1);
        case HapticCue.turnLeft:
          await Vibration.vibrate(duration: _turnMs, amplitude: amplitude ?? -1);
        case HapticCue.turnRight:
          await Vibration.vibrate(
            pattern: const [0, _turnMs, _turnGapMs, _turnMs],
            intensities: amplitude == null ? const [] : [0, amplitude, 0, amplitude],
          );
        case HapticCue.confirmation:
          await Vibration.vibrate(
            pattern: const [0, _navigationMs, _confirmationGapMs, _navigationMs],
            intensities: amplitude == null ? const [] : [0, amplitude, 0, amplitude],
          );
        case HapticCue.hazard:
          await Vibration.vibrate(duration: _hazardMs, amplitude: amplitude ?? -1);
      }
    } catch (e) {
      debugPrint('[Haptics] vibrate failed, falling back: $e');
      await _fallback(cue);
    }
  }

  /// Guarded like everything else here. A cue is an accompaniment — it rides
  /// alongside a spoken instruction and never carries meaning on its own — so
  /// a platform that refuses to buzz must not take the turn announcement, the
  /// arrival, or the SOS down with it.
  Future<void> _fallback(HapticCue cue) async {
    try {
      await _playFallback(cue);
    } catch (e) {
      debugPrint('[Haptics] no haptics available at all: $e');
    }
  }

  Future<void> _playFallback(HapticCue cue) async {
    switch (cue) {
      case HapticCue.navigation:
      case HapticCue.turnLeft:
        await HapticFeedback.selectionClick();
      case HapticCue.turnRight:
        // The count is the signal, so it has to survive the fallback path
        // too — a platform without an amplitude-capable motor still gets one
        // tap for left and two for right.
        await HapticFeedback.selectionClick();
        await Future<void>.delayed(const Duration(milliseconds: _turnGapMs));
        await HapticFeedback.selectionClick();
      case HapticCue.confirmation:
        await HapticFeedback.mediumImpact();
      case HapticCue.hazard:
        await HapticFeedback.heavyImpact();
    }
  }
}
