// What the assistant says about a route, and what it can do when the user
// does not like it.
//
// Reported, in the user's own words: after "take me to Labaid" the only
// thing said was that the safest route passed a somewhat risky area — no
// mention of which way it was going, how far it was, or how to ask for a
// different one. The alternatives existed the whole time (`walkingRoutes`
// has always sent `computeAlternativeRoutes: true`); `RoutePlanningService`
// picked the safest and dropped the rest on the floor.

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';
import 'package:ant_app/core/services/function_call_executor.dart';
import 'package:ant_app/core/services/local_intent_matcher.dart';
import 'package:ant_app/core/services/route_planning_service.dart';
import 'package:ant_app/core/services/route_safety_service.dart';
import 'package:ant_app/core/services/routing_service.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';

void main() {
  const safe = SafetyVerdict(safe: true, riskScore: 1, threshold: 7, dangerousThanaNames: []);
  final profile = UserProfile(uid: 'u1', role: UserRole.disabledUser);

  group('street names on the Google backend', () {
    // Routes API has no street-name field, so every Google-planned route
    // spoke bare "turn left" — on the backend this app is migrating *to*.
    test('recovers the road from the instruction prose', () {
      expect(streetNameFromGoogleInstruction('Turn left onto Satmasjid Road'), 'Satmasjid Road');
      expect(streetNameFromGoogleInstruction('Continue onto Mirpur Road'), 'Mirpur Road');
      expect(streetNameFromGoogleInstruction('Head north on Road 27'), 'Road 27');
    });

    test('drops the destination note Routes API tacks on', () {
      expect(
        streetNameFromGoogleInstruction('Turn right onto Satmasjid Road, Destination will be on the left'),
        'Satmasjid Road',
      );
    });

    test('yields nothing rather than a wrong road', () {
      // "Turn left" on its own is a complete instruction; "turn left onto
      // the right" is nonsense being read to somebody who cannot see it.
      expect(streetNameFromGoogleInstruction('Turn left'), '');
      expect(streetNameFromGoogleInstruction('Destination will be on the right'), '');
      expect(streetNameFromGoogleInstruction(null), '');
      expect(streetNameFromGoogleInstruction(''), '');
    });
  });

  group('via summary', () {
    RouteStep step(String name, double metres) => RouteStep(
          location: const LatLng(23.75, 90.39),
          distanceMeters: metres,
          maneuver: ManeuverKind.straight,
          streetName: name,
        );

    test('picks the longest named stretch, not the first', () {
      // A route almost always starts on whichever lane the user is standing
      // in, which identifies nothing.
      expect(
        routeViaSummary([step('Lane 4', 40), step('Satmasjid Road', 900), step('Green Road', 200)]),
        'Satmasjid Road',
      );
    });

    test('adds up a road the route rejoins', () {
      expect(
        routeViaSummary([step('Mirpur Road', 300), step('Link Road', 400), step('Mirpur Road', 300)]),
        'Mirpur Road',
      );
    });

    test('is empty when nothing is named — normal in Dhaka', () {
      expect(routeViaSummary([step('', 500), step('', 200)]), '');
      expect(routeViaSummary(const []), '');
    });
  });

  group('spoken route shape', () {
    final d = Dashboard.of(AppLanguage.english);

    test('a total is a kilometre once it is past one', () {
      // `spokenDistance` is built for the next manoeuvre and answers "a few
      // steps" under 20 m; a whole walk is a different question.
      expect(d.spokenRouteLength(1240), '1.2 km');
      expect(d.spokenRouteLength(340), '340 metres');
    });

    test('duration is rounded to whole minutes, and hedged', () {
      expect(d.spokenWalkDuration(900), 'about 15 minutes');
      expect(d.spokenWalkDuration(20), 'under a minute');
    });

    test('the summary says which way, how far and how long', () {
      expect(
        d.routeSummary(via: 'Satmasjid Road', distanceMeters: 1240, durationSeconds: 900),
        'Via Satmasjid Road — 1.2 km, about 15 minutes.',
      );
    });

    test('an unnamed route still gets a summary', () {
      expect(d.routeSummary(via: '', distanceMeters: 340, durationSeconds: 250), '340 metres, about 4 minutes.');
    });
  });

  group('request_route now describes the route it chose', () {
    test('the risky-area warning carries the route with it', () async {
      // The exact reported sentence, plus what was missing from it.
      final executor = FunctionCallExecutor(
        routePlanning: _StubPlanning(
          verdict: const SafetyVerdict(safe: false, riskScore: 9, threshold: 7, dangerousThanaNames: ['X']),
          via: 'Satmasjid Road',
        ),
      );

      final turn = await executor.execute(
        name: 'request_route',
        args: const {'destination': 'Labaid'},
        profile: profile,
        location: _here(),
      );

      expect(turn.responseText, contains('passes through a somewhat risky area'));
      expect(turn.responseText, contains('Via Satmasjid Road'));
      expect(turn.responseText, contains('1.2 km'));
      expect(turn.responseText, contains('about 15 minutes'));
    });

    test('a plain route says which way too', () async {
      final executor = FunctionCallExecutor(
        routePlanning: _StubPlanning(verdict: safe, via: 'Green Road'),
      );

      final turn = await executor.execute(
        name: 'request_route',
        args: const {'destination': 'Labaid'},
        profile: profile,
        location: _here(),
      );

      expect(turn.responseText, contains('Showing the way to Labaid'));
      expect(turn.responseText, contains('Via Green Road'));
    });

    test('the alternatives are handed back rather than dropped', () async {
      final executor = FunctionCallExecutor(
        routePlanning: _StubPlanning(verdict: safe, via: 'Green Road', alternatives: 2),
      );

      final turn = await executor.execute(
        name: 'request_route',
        args: const {'destination': 'Labaid'},
        profile: profile,
        location: _here(),
      );

      expect(turn.routeAlternatives, hasLength(2));
    });
  });

  group('request_alternative_route', () {
    final active = RouteChoice(
      destinationLabel: 'Labaid',
      points: const [LatLng(23.75, 90.39), LatLng(23.76, 90.40)],
      distanceMeters: 1240,
      durationSeconds: 900,
      initialBearingDegrees: 40,
      viaSummary: 'Green Road',
      verdict: safe,
      wasRerouted: false,
    );

    test('switches to the next one and says what it is', () async {
      final planning = _StubPlanning(verdict: safe, via: 'Satmasjid Road');
      final executor = FunctionCallExecutor(routePlanning: planning);

      final turn = await executor.execute(
        name: 'request_alternative_route',
        args: const {},
        profile: profile,
        location: _here(),
        activeRoute: active,
        routeAlternatives: [_candidate('a'), _candidate('b')],
      );

      expect(turn.route, isNotNull);
      expect(turn.route!.viaSummary, 'Satmasjid Road');
      expect(turn.responseText, contains('Here is another way'));
      expect(turn.responseText, contains('Via Satmasjid Road'));
      // The one it just took is off the shelf; the other is still there.
      expect(turn.routeAlternatives, hasLength(1));
      expect(turn.responseText, contains('1 more'));
    });

    test('is honest when there is nothing else', () async {
      final executor = FunctionCallExecutor(routePlanning: _StubPlanning(verdict: safe));

      final turn = await executor.execute(
        name: 'request_alternative_route',
        args: const {},
        profile: profile,
        location: _here(),
        activeRoute: active,
        routeAlternatives: const [],
      );

      expect(turn.route, isNull);
      expect(turn.responseText, contains('only walking route'));
    });

    test('says so when there is no route to change', () async {
      final executor = FunctionCallExecutor(routePlanning: _StubPlanning(verdict: safe));

      final turn = await executor.execute(
        name: 'request_alternative_route',
        args: const {},
        profile: profile,
        location: _here(),
        routeAlternatives: [_candidate('a')],
      );

      expect(turn.responseText, contains('not following a route'));
    });

    test('safety-checks the alternative rather than trusting it', () async {
      // The whole point of picking the safest route is lost if switching
      // away from it skips the check.
      final planning = _StubPlanning(verdict: safe);
      final executor = FunctionCallExecutor(routePlanning: planning);

      await executor.execute(
        name: 'request_alternative_route',
        args: const {},
        profile: profile,
        location: _here(),
        activeRoute: active,
        routeAlternatives: [_candidate('a')],
      );

      expect(planning.promoteCalls, 1);
      expect(planning.planCalls, 0, reason: 'must not re-plan — that could return a different set');
    });
  });

  group('which alternative gets offered first', () {
    // `plan` stops checking at the first safe route, so anything after it
    // has no verdict at all — while anything before it was measured and
    // rejected. Handing back a route this method has *just* found dangerous
    // ahead of one it never looked at is the one order that cannot be
    // defended to somebody who cannot see where they are being sent.
    RouteCandidate candidate(String id) => _candidate(id);

    test('unchecked routes come before ones already found unsafe', () async {
      final unsafeFirst = candidate('risky');
      final safeSecond = candidate('safe');
      final untouched = candidate('untouched');
      final planning = RoutePlanningService(
        routing: _StubRouting([unsafeFirst, safeSecond, untouched]),
        safety: _StubSafety({'risky': 9}),
      );

      final result = await planning.plan(
        destinationQuery: 'Labaid',
        origin: const LatLng(23.74, 90.37),
        // Skips geocoding, which is a different call and not what this is
        // about.
        knownDestination: const LatLng(23.77, 90.40),
      );

      expect(result, isA<RoutePlanned>());
      final planned = result as RoutePlanned;
      expect(planned.choice.wasRerouted, isTrue);
      expect(planned.alternatives.map((c) => c.encodedPolyline), ['untouched', 'risky']);
    });

    test('switching to an unsafe alternative says it is unsafe', () async {
      final executor = FunctionCallExecutor(
        routePlanning: _StubPlanning(
          verdict: const SafetyVerdict(safe: false, riskScore: 9, threshold: 7, dangerousThanaNames: ['X']),
        ),
      );

      final turn = await executor.execute(
        name: 'request_alternative_route',
        args: const {},
        profile: profile,
        location: _here(),
        activeRoute: RouteChoice(
          destinationLabel: 'Labaid',
          points: const [LatLng(23.75, 90.39)],
          distanceMeters: 1240,
          durationSeconds: 900,
          initialBearingDegrees: 0,
          verdict: safe,
          wasRerouted: false,
        ),
        routeAlternatives: [candidate('a')],
      );

      expect(turn.responseText, contains('risky area'));
    });
  });

  group('replan_route', () {
    // `navigateOffRoute` tells a user who has drifted to say "re-route" and
    // promises the way will be found from where they are. Nothing matched
    // it, so the one command offered to somebody lost did nothing at all.
    final active = RouteChoice(
      destinationLabel: 'Labaid',
      points: const [LatLng(23.75, 90.39), LatLng(23.7712, 90.4001)],
      distanceMeters: 1240,
      durationSeconds: 900,
      initialBearingDegrees: 40,
      verdict: safe,
      wasRerouted: false,
    );

    test('"re-route" is recognized without a language model', () {
      expect(LocalIntentMatcher.match('re-route', AppLanguage.english)?.name, 'replan_route');
      expect(LocalIntentMatcher.match('reroute please', AppLanguage.english)?.name, 'replan_route');
      expect(LocalIntentMatcher.match('নতুন পথ', AppLanguage.bangla)?.name, 'replan_route');
    });

    test('re-plans to the same place from the current position', () async {
      final planning = _StubPlanning(verdict: safe, via: 'Green Road');
      final executor = FunctionCallExecutor(routePlanning: planning);

      final turn = await executor.execute(
        name: 'replan_route',
        args: const {},
        profile: profile,
        location: _here(),
        activeRoute: active,
      );

      expect(turn.route, isNotNull);
      expect(turn.responseText, contains('the way from here'));
      // The destination is the route's own end point, not a second geocode
      // of its label — which for "the hospital" could land somewhere else.
      expect(planning.lastKnownDestination, active.points.last);
      expect(planning.lastOrigin?.latitude, closeTo(23.7461, 0.0001));
    });

    test('says so when there is no route to re-plan', () async {
      final executor = FunctionCallExecutor(routePlanning: _StubPlanning(verdict: safe));

      final turn = await executor.execute(
        name: 'replan_route',
        args: const {},
        profile: profile,
        location: _here(),
      );

      expect(turn.responseText, contains('not following a route'));
    });
  });

  group('asking for a different route in words', () {
    for (final phrase in [
      'give me a different route',
      'another way please',
      'I don\'t like this route',
      'change the route',
    ]) {
      test('"$phrase" matches locally', () {
        expect(LocalIntentMatcher.match(phrase, AppLanguage.english)?.name, 'request_alternative_route');
      });
    }

    test('Bangla too', () {
      expect(LocalIntentMatcher.match('অন্য পথ দাও', AppLanguage.bangla)?.name, 'request_alternative_route');
    });

    test('does not hijack a fresh journey', () {
      // "Take me to Gulshan" must still plan a route, and naming a
      // destination alongside "another way" is a compound request that
      // belongs to Gemini, which has both tools and the conversation.
      expect(LocalIntentMatcher.match('take me to Gulshan', AppLanguage.english)?.name, 'request_route');
      expect(LocalIntentMatcher.match('another way to Gulshan', AppLanguage.english)?.name, isNot('request_alternative_route'));
    });
  });
}

Position _here() => Position(
      latitude: 23.7461,
      longitude: 90.3742,
      timestamp: DateTime.utc(2026, 9, 9),
      accuracy: 5,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );

RouteCandidate _candidate(String id) => RouteCandidate(
      encodedPolyline: id,
      points: const [LatLng(23.75, 90.39), LatLng(23.77, 90.40)],
      distanceMeters: 1240,
      durationSeconds: 900,
      initialBearingDegrees: 40,
    );

/// Hands back a fixed set of candidates without a network call.
class _StubRouting implements RoutingService {
  _StubRouting(this.candidates);
  final List<RouteCandidate> candidates;

  @override
  Future<List<RouteCandidate>> walkingRoutes({
    required LatLng origin,
    required LatLng destination,
  }) async =>
      candidates;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// Risk by polyline id; anything not listed is safe.
class _StubSafety implements RouteSafetyService {
  _StubSafety(this.risks);
  final Map<String, int> risks;

  @override
  Future<SafetyVerdict> check({required String encodedPolyline, DateTime? at}) async {
    final risk = risks[encodedPolyline];
    return SafetyVerdict(
      safe: risk == null,
      riskScore: (risk ?? 0).toDouble(),
      threshold: 7,
      dangerousThanaNames: const [],
    );
  }

  @override
  Future<void> resolveHazard(String zoneId) async {}
}

/// A planner that answers instantly and records what it was asked, so the
/// tests can assert the *shape* of the request as well as the reply.
class _StubPlanning implements RoutePlanningService {
  _StubPlanning({required this.verdict, this.via = '', this.alternatives = 0});

  final SafetyVerdict verdict;
  final String via;
  final int alternatives;

  int planCalls = 0;
  int promoteCalls = 0;
  LatLng? lastKnownDestination;
  LatLng? lastOrigin;

  RouteChoice _choice(String label) => RouteChoice(
        destinationLabel: label,
        points: const [LatLng(23.75, 90.39), LatLng(23.77, 90.40)],
        distanceMeters: 1240,
        durationSeconds: 900,
        initialBearingDegrees: 40,
        viaSummary: via,
        verdict: verdict,
        wasRerouted: false,
      );

  @override
  Future<RoutePlanResult> plan({
    required String destinationQuery,
    required LatLng origin,
    DateTime? at,
    LatLng? knownDestination,
    String? destinationLabel,
  }) async {
    planCalls++;
    lastKnownDestination = knownDestination;
    lastOrigin = origin;
    return RoutePlanned(
      _choice(destinationLabel ?? destinationQuery),
      alternatives: [for (var i = 0; i < alternatives; i++) _candidate('alt-$i')],
    );
  }

  @override
  Future<RouteChoice> promote(
    RouteCandidate candidate, {
    required String destinationLabel,
    DateTime? at,
  }) async {
    promoteCalls++;
    return _choice(destinationLabel);
  }
}
