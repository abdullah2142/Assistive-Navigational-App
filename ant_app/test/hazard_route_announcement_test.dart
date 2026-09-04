// Module 5, end of the chain: a crowdsourced hazard on the planned route
// has to reach the user's ears. Everything upstream of this — clustering,
// flag levels, the $w_2$ weight — is worth nothing if the assistant plans
// the route and says nothing about the open manhole on it.

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';
import 'package:ant_app/core/services/function_call_executor.dart';
import 'package:ant_app/core/services/local_intent_matcher.dart';
import 'package:ant_app/core/services/route_planning_service.dart';
import 'package:ant_app/core/services/route_safety_service.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';
import 'package:ant_app/features/onboarding/services/pairing_service.dart';

/// `implements`, not `extends` — both real services reach for Firebase in
/// their constructors, which throws with no initialized app.
class _FakePairing implements PairingService {
  @override
  Future<String> generateCode({required String caretakerUid}) async => '000000';
  @override
  Stream<String?> watchClaimedBy(String code) => const Stream.empty();
  @override
  Future<String> redeemCode({required String code, required String disabledUserUid}) async => 'caretaker';
}

class _RecordingRouteSafety implements RouteSafetyService {
  final List<String> resolved = [];

  @override
  Future<void> resolveHazard(String zoneId) async => resolved.add(zoneId);

  @override
  Future<SafetyVerdict> check({required String encodedPolyline, DateTime? at}) async =>
      throw UnimplementedError();
}

class _FakeRoutePlanning implements RoutePlanningService {
  _FakeRoutePlanning(this.verdict, {this.wasRerouted = false});
  final SafetyVerdict verdict;
  final bool wasRerouted;

  @override
  Future<RoutePlanResult> plan({
    required String destinationQuery,
    required LatLng origin,
    DateTime? at,
    LatLng? knownDestination,
    String? destinationLabel,
  }) async =>
      RoutePlanned(RouteChoice(
        destinationLabel: destinationLabel ?? destinationQuery,
        points: const [LatLng(23.81, 90.41), LatLng(23.82, 90.42)],
        distanceMeters: 1200,
        durationSeconds: 900,
        initialBearingDegrees: 45,
        verdict: verdict,
        wasRerouted: wasRerouted,
      ));
}

RouteHazard hazard(String subCategory, String flag) => RouteHazard(
      zoneId: 'z-$subCategory',
      category: 'roadHazard',
      subCategory: subCategory,
      flag: flag,
      reportCount: flag == 'red' ? 3 : 1,
    );

SafetyVerdict verdictWith({
  bool safe = true,
  List<RouteHazard> blocking = const [],
  List<RouteHazard> warnings = const [],
}) =>
    SafetyVerdict(
      safe: safe,
      riskScore: safe ? 2 : 9,
      threshold: 7,
      dangerousThanaNames: const [],
      blockingHazards: blocking,
      hazardWarnings: warnings,
    );

Future<String> routeReply(
  SafetyVerdict verdict, {
  AppLanguage language = AppLanguage.english,
  bool wasRerouted = false,
}) async {
  final executor = FunctionCallExecutor(
    pairingService: _FakePairing(),
    routePlanning: _FakeRoutePlanning(verdict, wasRerouted: wasRerouted),
  );
  final turn = await executor.execute(
    name: 'request_route',
    args: const {'destination': 'Gulshan 2'},
    profile: UserProfile(uid: 'u1', role: UserRole.disabledUser, language: language),
    location: Position(
      latitude: 23.81,
      longitude: 90.41,
      timestamp: DateTime.utc(2026, 9, 4),
      accuracy: 5,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    ),
  );
  return turn.responseText;
}

void main() {
  final d = Dashboard.of(AppLanguage.english);

  group('resolve_hazard — the only way a permanent block ever clears', () {
    Future<(String, _RecordingRouteSafety)> resolveWith(RouteChoice? activeRoute) async {
      final safety = _RecordingRouteSafety();
      final executor = FunctionCallExecutor(
        pairingService: _FakePairing(),
        routePlanning: _FakeRoutePlanning(verdictWith()),
        routeSafety: safety,
      );
      final turn = await executor.execute(
        name: 'resolve_hazard',
        args: const {},
        profile: UserProfile(uid: 'u1', role: UserRole.disabledUser),
        activeRoute: activeRoute,
      );
      return (turn.responseText, safety);
    }

    RouteChoice routeWith(List<RouteHazard> hazards) => RouteChoice(
          destinationLabel: 'Gulshan 2',
          points: const [LatLng(23.81, 90.41)],
          distanceMeters: 500,
          durationSeconds: 400,
          initialBearingDegrees: 0,
          verdict: verdictWith(blocking: hazards),
          wasRerouted: false,
        );

    test('clears every hazard on the route the user is walking', () async {
      final (reply, safety) = await resolveWith(routeWith([
        hazard('stairsOnly', 'red'),
        hazard('noCurbCut', 'yellow'),
      ]));
      expect(safety.resolved, ['z-stairsOnly', 'z-noCurbCut']);
      expect(reply, d.hazardResolvedConfirmation);
    });

    test('with no active route it says so instead of silently doing nothing', () async {
      final (reply, safety) = await resolveWith(null);
      expect(safety.resolved, isEmpty);
      expect(reply, d.hazardResolveNothingToClear);
    });

    test('"it is fixed" is recognised without an LLM, in both languages', () {
      expect(LocalIntentMatcher.match("it's fixed", AppLanguage.english)?.name, 'resolve_hazard');
      expect(LocalIntentMatcher.match('the ramp is fixed now', AppLanguage.english)?.name, 'resolve_hazard');
      expect(LocalIntentMatcher.match('ঠিক হয়ে গেছে', AppLanguage.bangla)?.name, 'resolve_hazard');
    });

    test('saying a hazard is fixed does not open a form to report it again', () {
      // "the broken ramp is fixed" names a hazard *and* resolves it. Only
      // one of those two readings is what anybody means by it.
      final intent = LocalIntentMatcher.match('the broken ramp is fixed', AppLanguage.english);
      expect(intent?.name, 'resolve_hazard');
    });
  });

  test('a clean route says nothing about hazards', () async {
    final reply = await routeReply(verdictWith());
    expect(reply, contains('Gulshan 2'));
    expect(reply, isNot(contains('reported')));
  });

  test('an unconfirmed hazard on the route is mentioned as somebody\'s report', () async {
    final reply = await routeReply(verdictWith(warnings: [hazard('pothole', 'yellow')]));
    expect(reply, contains(d.hazardWarningAhead(d.hazardSubCategoryLabel('pothole'))));
  });

  test('a confirmed hazard with no way around it is warned about explicitly', () async {
    // The single most important sentence this module produces: the user is
    // being walked toward something three people independently reported,
    // and no alternative route existed.
    final reply = await routeReply(
      verdictWith(safe: false, blocking: [hazard('openManhole', 'red')]),
    );
    expect(reply, contains(d.hazardConfirmedUnavoidable(d.hazardSubCategoryLabel('openManhole'))));
  });

  test('a confirmed hazard is reported even when the route was rerouted', () async {
    final reply = await routeReply(
      verdictWith(safe: false, blocking: [hazard('openManhole', 'red')]),
      wasRerouted: true,
    );
    expect(reply, contains(d.hazardSubCategoryLabel('openManhole')));
  });

  test('confirmed outranks unconfirmed when both are on the route', () async {
    final reply = await routeReply(verdictWith(
      safe: false,
      blocking: [hazard('openManhole', 'red')],
      warnings: [hazard('pothole', 'yellow')],
    ));
    expect(reply, contains(d.hazardSubCategoryLabel('openManhole')));
    expect(
      reply,
      isNot(contains(d.hazardWarningAhead(d.hazardSubCategoryLabel('pothole')))),
      reason: 'a spoken list of hazards is not something a walking user can hold onto',
    );
  });

  test('the warning is spoken in the user\'s own language', () async {
    final bn = Dashboard.of(AppLanguage.bangla);
    final reply = await routeReply(
      verdictWith(warnings: [hazard('pothole', 'yellow')]),
      language: AppLanguage.bangla,
    );
    expect(reply, contains(bn.hazardWarningAhead(bn.hazardSubCategoryLabel('pothole'))));
    expect(reply, matches(RegExp(r'[ঀ-৿]')));
  });
}
