// Saved places end to end: the executor must resolve "take me to work"
// from the user's own profile without a geocode, must refuse to guess
// between two similar places, and must be able to save where the user is
// standing right now.

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';
import 'package:ant_app/core/services/function_call_executor.dart';
import 'package:ant_app/core/services/route_planning_service.dart';
import 'package:ant_app/core/services/route_safety_service.dart';
import 'package:ant_app/core/services/routing_service.dart';
import 'package:ant_app/features/onboarding/models/saved_place.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';
import 'package:ant_app/features/onboarding/services/pairing_service.dart';

class _FakePairing implements PairingService {
  @override
  Future<String> generateCode({required String caretakerUid}) async => '000000';
  @override
  Stream<String?> watchClaimedBy(String code) => const Stream.empty();
  @override
  Future<String> redeemCode({required String code, required String disabledUserUid}) async => 'c';
}

/// Records exactly what routing was asked to do, so the test can assert
/// that a saved place skipped geocoding rather than merely producing the
/// right answer by a slower path.
class _RecordingRoutePlanning implements RoutePlanningService {
  String? lastQuery;
  LatLng? lastKnownDestination;
  String? lastLabel;
  int planCalls = 0;

  @override
  Future<RoutePlanResult> plan({
    required String destinationQuery,
    required LatLng origin,
    DateTime? at,
    LatLng? knownDestination,
    String? destinationLabel,
  }) async {
    planCalls++;
    lastQuery = destinationQuery;
    lastKnownDestination = knownDestination;
    lastLabel = destinationLabel;
    return RoutePlanned(RouteChoice(
      destinationLabel: destinationLabel ?? destinationQuery,
      points: const [LatLng(23.81, 90.41)],
      distanceMeters: 900,
      durationSeconds: 700,
      initialBearingDegrees: 0,
      verdict: const SafetyVerdict(safe: true, riskScore: 1, threshold: 7, dangerousThanaNames: []),
      wasRerouted: false,
    ));
  }

  @override
  Future<RouteChoice> promote(
    RouteCandidate candidate, {
    required String destinationLabel,
    DateTime? at,
  }) async =>
      throw UnimplementedError();
}

Position here() => Position(
      latitude: 23.7461,
      longitude: 90.3742,
      timestamp: DateTime.utc(2026, 9, 4),
      accuracy: 5,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );

void main() {
  final d = Dashboard.of(AppLanguage.english);

  UserProfile profileWith(List<SavedPlace> places) =>
      UserProfile(uid: 'u1', role: UserRole.disabledUser, savedPlaces: places);

  Future<(String, _RecordingRoutePlanning, UserProfile?)> run(
    String name,
    Map<String, Object?> args,
    UserProfile profile, {
    // Sentinel-free: `location: null` has to mean "no GPS fix", which a
    // `location ?? here()` default silently made unrepresentable.
    bool hasLocation = true,
  }) async {
    final planning = _RecordingRoutePlanning();
    final executor = FunctionCallExecutor(pairingService: _FakePairing(), routePlanning: planning);
    final turn = await executor.execute(
      name: name,
      args: args,
      profile: profile,
      location: hasLocation ? here() : null,
    );
    return (turn.responseText, planning, turn.updatedProfile);
  }

  group('routing to a saved place', () {
    test('uses stored coordinates and never geocodes', () async {
      final profile = profileWith([
        const SavedPlace(label: 'work', kind: SavedPlaceKind.work, lat: 23.79, lng: 90.40),
      ]);
      final (reply, planning, _) = await run('request_route', {'destination': 'work'}, profile);

      expect(planning.lastKnownDestination?.latitude, 23.79);
      expect(planning.lastLabel, 'work');
      expect(reply, contains('work'));
    });

    test('a synonym the user never used as a label still resolves', () async {
      final profile = profileWith([
        const SavedPlace(label: 'work', kind: SavedPlaceKind.work, lat: 23.79, lng: 90.40),
      ]);
      final (_, planning, _) = await run('request_route', {'destination': 'the office'}, profile);
      expect(planning.lastKnownDestination, isNotNull);
    });

    test('a saved place with only an address routes on the address, not the label', () async {
      // "Ma's house" is not geocodable; the stored address is.
      final profile = profileWith([
        const SavedPlace(label: "Ma's house", kind: SavedPlaceKind.family, address: 'Dhanmondi 27'),
      ]);
      final (_, planning, _) = await run('request_route', {'destination': "ma's house"}, profile);
      expect(planning.lastQuery, 'Dhanmondi 27');
      expect(planning.lastLabel, "Ma's house", reason: 'the user hears their own name for it');
    });

    test('an unsaved destination falls through to normal geocoding', () async {
      final (_, planning, _) =
          await run('request_route', {'destination': 'Gulshan 2'}, profileWith(const []));
      expect(planning.lastKnownDestination, isNull);
      expect(planning.lastQuery, 'Gulshan 2');
    });

    test('an ambiguous reference asks instead of guessing', () async {
      final profile = profileWith([
        const SavedPlace(label: "Ma's house", kind: SavedPlaceKind.family, address: 'a'),
        const SavedPlace(label: "Bhai's house", kind: SavedPlaceKind.family, address: 'b'),
      ]);
      final (reply, planning, _) = await run('request_route', {'destination': 'my relative'}, profile);

      expect(planning.planCalls, 0, reason: 'must not start walking anywhere while ambiguous');
      expect(reply, d.savedPlaceAmbiguous(["Ma's house", "Bhai's house"]));
      expect(reply, contains("Ma's house"));
      expect(reply, contains("Bhai's house"));
    });
  });

  group('saving and removing places', () {
    test('saves the current location when no address is given', () async {
      final (reply, _, updated) =
          await run('save_place', {'label': 'the clinic', 'kind': 'medical'}, profileWith(const []));

      expect(updated?.savedPlaces, hasLength(1));
      final saved = updated!.savedPlaces.single;
      expect(saved.label, 'the clinic');
      expect(saved.lat, 23.7461);
      expect(saved.kind, SavedPlaceKind.medical);
      expect(reply, contains('the clinic'));
    });

    test('saving over an existing label moves it instead of duplicating', () async {
      // Two places called "work" would then resolve ambiguously forever.
      final profile = profileWith([
        const SavedPlace(label: 'work', kind: SavedPlaceKind.work, lat: 1, lng: 1),
      ]);
      final (_, _, updated) = await run('save_place', {'label': 'work'}, profile);
      expect(updated?.savedPlaces, hasLength(1));
      expect(updated!.savedPlaces.single.lat, 23.7461);
    });

    test('saving without a location and without an address says why', () async {
      final (reply, _, updated) =
          await run('save_place', {'label': 'work'}, profileWith(const []), hasLocation: false);
      expect(updated, isNull, reason: 'nothing should have been saved');
      expect(reply, d.savedPlaceNeedsLocation);
    });

    test('removing a place works by synonym too', () async {
      final profile = profileWith([
        const SavedPlace(label: 'work', kind: SavedPlaceKind.work, lat: 1, lng: 1),
        const SavedPlace(label: 'school', kind: SavedPlaceKind.school, lat: 2, lng: 2),
      ]);
      final (reply, _, updated) = await run('remove_place', {'label': 'the office'}, profile);
      expect(updated?.savedPlaces.map((p) => p.label), ['school']);
      expect(reply, contains('work'));
    });

    test('removing something not saved says so rather than removing at random', () async {
      final profile = profileWith([
        const SavedPlace(label: 'work', kind: SavedPlaceKind.work, lat: 1, lng: 1),
      ]);
      final (reply, _, updated) = await run('remove_place', {'label': 'the airport'}, profile);
      expect(updated, isNull);
      expect(reply, d.savedPlaceUnknown);
    });
  });

  test('saved places survive a Firestore round trip', () {
    final profile = profileWith([
      const SavedPlace(label: 'work', kind: SavedPlaceKind.work, lat: 23.79, lng: 90.40),
      const SavedPlace(label: "Ma's house", kind: SavedPlaceKind.family, address: 'Dhanmondi 27'),
    ]);
    final restored = UserProfile.fromJson(profile.toJson());
    expect(restored.savedPlaces, hasLength(2));
    expect(restored.savedPlaces.first.lat, 23.79);
    expect(restored.savedPlaces.last.address, 'Dhanmondi 27');
    expect(restored.savedPlaces.last.kind, SavedPlaceKind.family);
  });

  test('a profile saved before this feature existed still loads', () {
    final legacy = UserProfile(uid: 'u1', role: UserRole.disabledUser).toJson()..remove('savedPlaces');
    expect(UserProfile.fromJson(legacy).savedPlaces, isEmpty);
  });
}
