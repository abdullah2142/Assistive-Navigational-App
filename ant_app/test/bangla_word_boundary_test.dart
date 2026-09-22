import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/services/haptics_service.dart';
import 'package:ant_app/core/services/local_intent_matcher.dart';
import 'package:ant_app/core/services/routing_service.dart' show ManeuverKind;
import 'package:ant_app/core/utils/text_scale_levels.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regressions from the 22 September device log.
void main() {
  group('a Bangla verb must not match inside a place name', () {
    // `ল্যাব` ("lab") is ল + ্ + য + া + ব — its last three characters are
    // exactly `যাব` ("will go"). The log line this reproduces is:
    //   [Chat] local match: request_route {destination: ধানমন্ডি ল্}
    test('Labaid survives — the exact destination the log truncated', () {
      final intent = LocalIntentMatcher.match('ধানমন্ডি ল্যাব এইড যেতে চাই', AppLanguage.bangla);
      expect(intent?.name, 'request_route');
      expect(intent!.args['destination'], 'ধানমন্ডি ল্যাব এইড');
    });

    test('and with the other go-verb', () {
      final intent = LocalIntentMatcher.match('আমি ল্যাব এইড যাব', AppLanguage.bangla);
      expect(intent?.name, 'request_route');
      expect(intent!.args['destination'], 'ল্যাব এইড');
    });

    test('an ordinary destination still routes', () {
      expect(LocalIntentMatcher.match('গুলশান যেতে চাই', AppLanguage.bangla)?.args['destination'], 'গুলশান');
      expect(LocalIntentMatcher.match('মিরপুর যাব', AppLanguage.bangla)?.args['destination'], 'মিরপুর');
    });

    test('যাবো is not clipped to যাব, leaving a stranded vowel sign', () {
      final intent = LocalIntentMatcher.match('আমি অফিসে যাবো', AppLanguage.bangla);
      expect(intent?.name, 'request_route');
      expect(intent!.args['destination'], isNot(contains('ো')));
    });

    test('containsBnWord is substring-safe in both directions', () {
      expect(LocalIntentMatcher.containsBnWord('আমি মিরপুর যাব', 'যাব'), isTrue);
      expect(LocalIntentMatcher.containsBnWord('ল্যাব এইড', 'যাব'), isFalse);
      expect(LocalIntentMatcher.containsBnWord('যাবো', 'যাব'), isFalse);
    });
  });

  group('turn haptics carry the direction', () {
    test('left and right are different cues', () {
      expect(turnCueFor(ManeuverKind.left), HapticCue.turnLeft);
      expect(turnCueFor(ManeuverKind.right), HapticCue.turnRight);
      expect(turnCueFor(ManeuverKind.left), isNot(turnCueFor(ManeuverKind.right)));
    });

    test('slight and sharp turns keep their side', () {
      expect(turnCueFor(ManeuverKind.slightLeft), HapticCue.turnLeft);
      expect(turnCueFor(ManeuverKind.sharpLeft), HapticCue.turnLeft);
      expect(turnCueFor(ManeuverKind.slightRight), HapticCue.turnRight);
      expect(turnCueFor(ManeuverKind.sharpRight), HapticCue.turnRight);
    });

    test('a manoeuvre with no side falls back to the plain cue', () {
      expect(turnCueFor(ManeuverKind.straight), HapticCue.navigation);
      expect(turnCueFor(ManeuverKind.depart), HapticCue.navigation);
      expect(turnCueFor(ManeuverKind.uTurn), HapticCue.navigation);
    });
  });

  group('text size is a ladder, not a continuum', () {
    test('every step is a visible jump', () {
      for (var i = 1; i < textScaleLevels.length; i++) {
        expect(textScaleLevels[i] - textScaleLevels[i - 1], greaterThan(0.19));
      }
    });

    test('stepping by voice lands on the ladder the slider shows', () {
      expect(stepScale(1.0, 1), 1.25);
      expect(stepScale(1.25, 1), 1.5);
      expect(stepScale(1.0, -1), 0.8);
    });

    test('stepping past either end stays on the ladder', () {
      expect(stepScale(2.0, 1), 2.0);
      expect(stepScale(0.8, -1), 0.8);
    });

    test('an off-ladder value from an older profile snaps to a real step', () {
      expect(textScaleLevels, contains(snapToLevel(1.15)));
      expect(textScaleLevels, contains(snapToLevel(1.45)));
      expect(snapToLevel(1.0), 1.0);
    });

    test('"bigger" three times from normal is three visible changes', () {
      var s = normalScale;
      final seen = <double>[s];
      for (var i = 0; i < 3; i++) {
        s = stepScale(s, 1);
        seen.add(s);
      }
      expect(seen.toSet().length, 4, reason: 'each request changed something');
    });
  });
}
