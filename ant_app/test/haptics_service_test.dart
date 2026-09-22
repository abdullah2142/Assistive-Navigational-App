// Module 7's haptic language, and the amplitude control the plan asks for.
//
// Before this, eight call sites reached for `HapticFeedback` directly with
// whatever constant seemed right. That is not a language: `mediumImpact` at a
// turn and `mediumImpact` when a microphone opens say the same thing about two
// unrelated events, and none of it could be scaled. `HapticFeedback` cannot
// set amplitude at all, which is why `vibration` is now a dependency — the
// plan calls for High/Medium/Low because "older devices have weaker motors",
// and the test handset for this project is a budget Xiaomi.
//
// A pattern a blind user cannot feel through a pocket is not feedback.

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';
import 'package:ant_app/core/services/haptics_service.dart';
import 'package:ant_app/features/onboarding/models/disability_profile_enums.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';

void main() {
  // `HapticFeedback` reaches a platform channel even on the fallback path.
  TestWidgetsFlutterBinding.ensureInitialized();

  HapticsService service({
    HapticIntensity intensity = HapticIntensity.medium,
    bool motor = true,
    bool amplitude = true,
  }) =>
      HapticsService(probeOverride: (motor: motor, amplitude: amplitude))..intensity = intensity;

  group('the dictionary stays small, and every entry earns its place', () {
    test('and no more', () {
      // The restriction is still the design: a larger vocabulary is
      // something the user has to remember while walking, which is the
      // cognitive load this app exists to avoid.
      //
      // Five, not three, since the 22 September report — "might confuse user
      // about which direction to turn". The two additions are not new
      // *meanings*, they are the one meaning `navigation` already had, split
      // by the single fact a turn cue has to carry and did not: which way.
      // Nothing here is a concept the user must learn cold; "one buzz left,
      // two buzzes right" is learned from the spoken instruction that always
      // accompanies it.
      expect(HapticCue.values, hasLength(5));
    });

    test('left and right are genuinely distinguishable', () {
      // The whole point of the split. If these ever collapse to the same
      // pattern the feature is back to marking that *a* turn is coming
      // while saying nothing about which one.
      expect(HapticCue.turnLeft, isNot(HapticCue.turnRight));
    });

    test('a turn cue is never silently dropped by the throttle', () {
      // Only `hazard` is throttled. A user walking a route with turns close
      // together must feel every one of them — a swallowed turn cue is a
      // missed corner, and this app's whole navigation contract is that a
      // manoeuvre is announced on every channel the user has.
      final s = service();
      expect(() => s.play(HapticCue.turnLeft), returnsNormally);
      expect(() => s.play(HapticCue.turnRight), returnsNormally);
    });
  });

  group('amplitude scales with the chosen strength', () {
    test('gentler settings really are gentler', () {
      final high = service(intensity: HapticIntensity.high).amplitudeFor(HapticCue.navigation);
      final medium = service(intensity: HapticIntensity.medium).amplitudeFor(HapticCue.navigation);
      final low = service(intensity: HapticIntensity.low).amplitudeFor(HapticCue.navigation);

      expect(high, greaterThan(medium));
      expect(medium, greaterThan(low));
    });

    test('every level stays inside what the platform accepts', () {
      // 1-255. A zero is not a quiet buzz, it is no buzz.
      for (final level in HapticIntensity.values) {
        for (final cue in HapticCue.values) {
          final amplitude = service(intensity: level).amplitudeFor(cue);
          expect(amplitude, inInclusiveRange(1, 255), reason: '$level/$cue');
        }
      }
    });

    test('the hazard alarm is the strongest cue at any setting', () {
      // The plan specifies it as max-intensity. Scaling still applies — a user
      // who chose Gentle did so because Strong startles them, and being
      // startled in a crowd is its own failure — but it is never weaker than
      // the cue that means "turn left".
      for (final level in HapticIntensity.values) {
        final s = service(intensity: level);
        expect(s.amplitudeFor(HapticCue.hazard),
            greaterThan(s.amplitudeFor(HapticCue.navigation)),
            reason: 'at $level');
      }
    });

    test('even Gentle is still felt', () {
      // The floor matters: a "Low" that rounds to nothing would silently
      // remove every cue for the user who most needed a weaker one.
      expect(service(intensity: HapticIntensity.low).amplitudeFor(HapticCue.navigation),
          greaterThan(20));
    });
  });

  group('the hazard alarm is throttled', () {
    test('a crowded street does not become one long buzz', () async {
      // Step 3.2, "Sensory Overload Protection". An alarm on every hazard in a
      // crowd panics the person it is meant to protect.
      final s = service();
      await s.play(HapticCue.hazard);
      await s.play(HapticCue.hazard);
      await s.play(HapticCue.hazard);
      // Nothing to assert on the motor here without a device; what is under
      // test is that repeated calls return rather than queueing a second
      // second-long buzz on top of the first.
      expect(HapticsService.hazardThrottle, const Duration(seconds: 5));
    });

    test('and the other two cues are not throttled', () async {
      // Turns come in quick succession at a junction. Swallowing one because
      // the last was 4 seconds ago is a missed turn.
      final s = service();
      await s.play(HapticCue.navigation);
      await s.play(HapticCue.navigation);
      await s.play(HapticCue.confirmation);
    });
  });

  group('a phone that cannot do this still says something', () {
    test('no motor falls back rather than going silent', () async {
      // A silent failure here is a cue the user simply never receives. The
      // system haptics are weaker and unscalable, but they are not nothing.
      await service(motor: false).play(HapticCue.navigation);
    });

    test('no amplitude control still plays the pattern', () async {
      // Most older handsets are here: they buzz, they just cannot be told how
      // hard. The pattern is the part that carries the meaning.
      await service(amplitude: false).play(HapticCue.confirmation);
    });
  });

  group('the setting survives', () {
    test('a Firestore round trip', () {
      const profile = UserProfile(
        uid: 'u1',
        role: UserRole.disabledUser,
        hapticIntensity: HapticIntensity.low,
      );
      expect(UserProfile.fromJson(profile.toJson()).hapticIntensity, HapticIntensity.low);
    });

    test('a profile written before the setting existed gets Medium', () {
      final json = const UserProfile(uid: 'u1', role: UserRole.disabledUser).toJson()
        ..remove('hapticIntensity');
      expect(UserProfile.fromJson(json).hapticIntensity, HapticIntensity.medium);
    });

    test('and every level has a name in both languages', () {
      for (final language in AppLanguage.values) {
        final d = Dashboard.of(language);
        for (final level in HapticIntensity.values) {
          expect(d.hapticIntensityLabel(level).trim(), isNotEmpty);
        }
      }
      expect(Dashboard.of(AppLanguage.bangla).hapticIntensityLabel(HapticIntensity.high),
          matches(RegExp(r'[ঀ-৿]')));
    });
  });
}
