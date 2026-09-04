// Turn-by-turn narration is the highest-consequence thing this app says
// out loud — a missed turn leaves a blind user walking confidently in the
// wrong direction. These walk a synthetic GPS track past a synthetic route
// so the decision logic is checked without taking a phone outside.

import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';
import 'package:ant_app/core/services/navigation_narrator.dart';
import 'package:ant_app/core/services/routing_service.dart';

/// Dhanmondi. Everything below is offset from here in metres.
const _origin = LatLng(23.7461, 90.3742);

const _metresPerDegreeLat = 111320.0;
double get _metresPerDegreeLng => 111320.0 * 0.9166; // cos(23.75 deg)

/// A point [north] metres north and [east] metres east of [_origin].
LatLng at({double north = 0, double east = 0}) => LatLng(
      _origin.latitude + north / _metresPerDegreeLat,
      _origin.longitude + east / _metresPerDegreeLng,
    );

RouteStep step(LatLng location, ManeuverKind kind, {String street = '', double distance = 100}) =>
    RouteStep(location: location, distanceMeters: distance, maneuver: kind, streetName: street);

void main() {
  /// A straight 300 m walk north, then a left turn, then 100 m west.
  List<RouteStep> simpleRoute() => [
        step(at(north: 300), ManeuverKind.left, street: 'Satmasjid Road'),
        step(at(north: 300, east: -100), ManeuverKind.arrive),
      ];

  /// The same route's actual geometry, sampled every 25 m — what a real
  /// backend returns alongside the manoeuvres.
  List<LatLng> simpleRoutePoints() => [
        for (var n = 0.0; n <= 300; n += 25) at(north: n),
        for (var e = 0.0; e >= -100; e -= 25) at(north: 300, east: e),
      ];

  NavigationNarrator narratorFor(List<RouteStep> steps, {List<LatLng>? points}) =>
      NavigationNarrator(steps: steps, routePoints: points ?? simpleRoutePoints());

  group('announces each turn once per distance band', () {
    test('a turn is announced once per band, ending with the instruction itself', () {
      final narrator = narratorFor(simpleRoute());
      final cues = <NavigationCue>[];

      // Walk north in 10 m increments, stopping just short of the corner so
      // this only covers the approach to the first manoeuvre.
      for (var walked = 0.0; walked <= 280; walked += 10) {
        final cue = narrator.update(at(north: walked));
        if (cue != null) cues.add(cue);
      }

      expect(cues, hasLength(3), reason: 'one per band: approaching, near, imminent');
      expect(cues.map((c) => c.kind), [
        NavigationCueKind.turnAhead,
        NavigationCueKind.turnAhead,
        // The instruction itself. This was unreachable while the reached
        // radius sat above the imminent band — the user got both warnings
        // and then silence at the actual corner.
        NavigationCueKind.turnNow,
      ]);
      expect(cues.every((c) => c.step?.maneuver == ManeuverKind.left), isTrue);
      expect(cues.map((c) => c.distanceMeters), [
        lessThanOrEqualTo(200.0),
        lessThanOrEqualTo(50.0),
        lessThanOrEqualTo(25.0),
      ]);
    });

    test('passing the turn moves narration on to the final leg', () {
      final narrator = narratorFor(simpleRoute());
      for (var walked = 0.0; walked <= 280; walked += 10) {
        narrator.update(at(north: walked));
      }
      final afterTurn = narrator.update(at(north: 295));
      expect(narrator.currentStepIndex, 1);
      expect(afterTurn?.step?.maneuver, ManeuverKind.arrive);
      expect(afterTurn?.isFinalStep, isTrue);
    });

    test('standing still does not repeat the instruction', () {
      final narrator = narratorFor(simpleRoute());
      // Get to within the near band...
      narrator.update(at(north: 150));
      narrator.update(at(north: 260));
      // ...then stop walking. A user waiting at a crossing must not be
      // told to turn left over and over.
      final repeats = List.generate(20, (_) => narrator.update(at(north: 260))).whereType<NavigationCue>();
      expect(repeats, isEmpty);
    });

    test('GPS jitter backward does not re-issue an instruction already acted on', () {
      final narrator = narratorFor(simpleRoute());
      narrator.update(at(north: 260)); // near band
      // A fix that wobbles back out past the band boundary and in again.
      expect(narrator.update(at(north: 240)), isNull);
      expect(narrator.update(at(north: 255)), isNull);
    });
  });

  group('advancing through the route', () {
    test('reaching a turn advances to the next manoeuvre', () {
      final narrator = narratorFor(simpleRoute());
      narrator.update(at(north: 100));
      expect(narrator.currentStepIndex, 0);
      narrator.update(at(north: 300)); // at the turn
      expect(narrator.currentStepIndex, 1);
    });

    test('a GPS gap that skips several short steps resyncs instead of insisting', () {
      // Four closely-spaced turns; the fix drops and returns past all of them.
      final narrator = narratorFor(
        [
          step(at(north: 30), ManeuverKind.left),
          step(at(north: 60), ManeuverKind.right),
          step(at(north: 90), ManeuverKind.left),
          step(at(north: 400), ManeuverKind.arrive),
        ],
        points: [for (var n = 0.0; n <= 400; n += 20) at(north: n)],
      );
      narrator.update(_origin);
      narrator.update(at(north: 95));
      expect(narrator.currentStepIndex, 3, reason: 'guidance must resync to where the user actually is');
    });

    test('arrival is reported once and then stops', () {
      final narrator = narratorFor(simpleRoute());
      narrator.update(at(north: 300));
      final arrival = narrator.update(at(north: 300, east: -100));
      expect(arrival?.kind, NavigationCueKind.arrived);
      expect(narrator.hasArrived, isTrue);
      expect(narrator.update(at(north: 300, east: -100)), isNull);
    });

    test('the last manoeuvre is flagged so it can be phrased differently', () {
      final narrator = narratorFor(simpleRoute());
      narrator.update(at(north: 300)); // advance to the final step
      final cue = narrator.update(at(north: 300, east: -60));
      expect(cue?.isFinalStep, isTrue);
    });
  });

  group('off-route detection', () {
    test('walking the length of a straight leg is not off-route', () {
      // The manoeuvre point is 300 m away for the whole leg — distance to
      // it says nothing about whether the user is still on the road.
      final narrator = narratorFor(simpleRoute());
      for (var walked = 0.0; walked <= 280; walked += 20) {
        final cue = narrator.update(at(north: walked));
        expect(cue?.kind, isNot(NavigationCueKind.offRoute), reason: 'on the route at ${walked}m');
      }
    });

    test('normal GPS wobble beside the route is tolerated', () {
      final narrator = narratorFor(simpleRoute());
      for (final drift in [5.0, -10.0, 15.0, -20.0]) {
        final cue = narrator.update(at(north: 150, east: drift));
        expect(cue?.kind, isNot(NavigationCueKind.offRoute), reason: 'drift of ${drift}m');
      }
    });

    test('a genuinely missed turn is reported, and only once', () {
      final narrator = narratorFor(simpleRoute());
      narrator.update(at(north: 150));
      final cue = narrator.update(at(north: 150, east: 120));
      expect(cue?.kind, NavigationCueKind.offRoute);
      // Repeating "you are off route" every second at someone who already
      // knows is the noise failure this whole class is built to avoid.
      expect(narrator.update(at(north: 150, east: 125)), isNull);
    });
  });

  group('phrasing', () {
    for (final language in AppLanguage.values) {
      test('${language.name}: distance comes before the direction', () {
        final d = Dashboard.of(language);
        final phrase = d.navigateTurnAhead(kind: ManeuverKind.left, meters: 50);
        final direction = d.maneuverDirection(ManeuverKind.left);
        expect(phrase, contains(direction));
        expect(
          phrase.indexOf(d.spokenDistance(50)) < phrase.indexOf(direction),
          isTrue,
          reason: 'speech is linear — the listener needs urgency before instruction',
        );
      });

      test('${language.name}: an unnamed road is simply omitted', () {
        final d = Dashboard.of(language);
        expect(d.navigateTurnNow(kind: ManeuverKind.right), isNot(contains('null')));
        expect(d.navigateTurnNow(kind: ManeuverKind.right, streetName: 'Mirpur Road'),
            contains('Mirpur Road'));
      });

      test('${language.name}: distances are rounded to something walkable', () {
        final d = Dashboard.of(language);
        expect(d.spokenDistance(187), isNot(contains('187')));
        expect(d.spokenDistance(8), d.spokenDistance(12), reason: 'both are "a few steps"');
      });

      test('${language.name}: off-route tells the user to stop, not to turn around', () {
        // Telling a blind pedestrian on a Dhaka street to reverse direction
        // immediately, without being able to see what is behind them, is
        // not a safe instruction.
        final d = Dashboard.of(language);
        final text = d.navigateOffRoute.toLowerCase();
        expect(text, isNot(contains('u-turn')));
        expect(text, isNot(contains('turn around')));
      });

      test('${language.name}: every manoeuvre has real wording', () {
        final d = Dashboard.of(language);
        for (final kind in ManeuverKind.values) {
          final text = d.maneuverDirection(kind);
          expect(text.trim(), isNotEmpty);
          // "turn left" legitimately contains "left"; what must never
          // happen is the enum name leaking through as the whole string.
          expect(text, isNot(kind.name), reason: '$kind fell through to its enum name');
        }
      });
    }

    test('Bangla navigation is actually Bangla', () {
      final bn = Dashboard.of(AppLanguage.bangla);
      expect(bn.navigateTurnNow(kind: ManeuverKind.left), matches(RegExp(r'[ঀ-৿]')));
      expect(bn.navigateArrived, matches(RegExp(r'[ঀ-৿]')));
      expect(bn.spokenDistance(150), matches(RegExp(r'[ঀ-৿]')));
    });
  });

  test('the imminent band clears the reached radius', () {
    // If it does not, the narrator retires each manoeuvre before its
    // instruction can fire and "Now, turn left" becomes unreachable code.
    expect(
      NavigationNarrator.announceBands.last,
      greaterThan(NavigationNarrator.reachedRadiusMeters),
    );
  });

  test('a route with no steps narrates nothing rather than crashing', () {
    final narrator = NavigationNarrator(steps: const [], routePoints: const []);
    expect(narrator.update(_origin), isNull);
  });
}
