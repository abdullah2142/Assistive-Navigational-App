// Turn-by-turn guidance has to reach a user who cannot hear it.
//
// `NavigationController` has emitted every spoken cue on `spokenCues` since
// Module 4, with a doc comment saying the chat transcript would show them —
// and nothing ever subscribed. For a Deaf or hard-of-hearing user that is not
// a degraded experience: the app plans the route, announces it to an empty
// room, and says nothing they can perceive for the rest of the walk.
//
// The second thing here is arrival. `ChatController.clearRoute` existed and
// was never called, so a finished walk stayed "the active route" forever —
// the map kept drawing a line already walked, and `resolve_hazard` stayed
// scoped to a journey that ended hours ago.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';
import 'package:ant_app/core/providers/ai_assistant_providers.dart';
import 'package:ant_app/core/services/navigation_controller.dart';
import 'package:ant_app/core/services/route_planning_service.dart';
import 'package:ant_app/core/services/route_safety_service.dart';
import 'package:ant_app/core/services/routing_service.dart';
import 'package:ant_app/core/services/tts_service.dart';
import 'package:ant_app/features/dashboard/models/chat_message.dart';
import 'package:ant_app/features/dashboard/providers/chat_providers.dart';

void main() {
  // The controller buzzes the vibration motor alongside every cue, which is
  // a platform channel.
  TestWidgetsFlutterBinding.ensureInitialized();

  const origin = LatLng(23.7461, 90.3742);
  const metresPerDegreeLat = 111320.0;
  final metresPerDegreeLng = 111320.0 * 0.9166;

  LatLng at({double north = 0, double east = 0}) => LatLng(
        origin.latitude + north / metresPerDegreeLat,
        origin.longitude + east / metresPerDegreeLng,
      );

  Position fix(LatLng p) => Position(
        latitude: p.latitude,
        longitude: p.longitude,
        timestamp: DateTime.utc(2026, 9, 9),
        accuracy: 5,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 1.2,
        speedAccuracy: 0,
      );

  late StreamController<Position> positions;
  late NavigationController navigation;
  late ProviderContainer container;

  setUp(() {
    positions = StreamController<Position>.broadcast();
    navigation = NavigationController(tts: _SilentTts(), positionStream: positions.stream);
    container = ProviderContainer(
      overrides: [navigationControllerProvider.overrideWithValue(navigation)],
    );
  });

  tearDown(() {
    container.dispose();
    positions.close();
  });

  /// A straight 300 m walk north, then left, then 100 m west.
  RouteChoice route() => RouteChoice(
        destinationLabel: 'Gulshan 2',
        points: [
          for (var n = 0.0; n <= 300; n += 25) at(north: n),
          for (var e = 0.0; e >= -100; e -= 25) at(north: 300, east: e),
        ],
        distanceMeters: 400,
        durationSeconds: 320,
        initialBearingDegrees: 0,
        verdict: const SafetyVerdict(safe: true, riskScore: 1, threshold: 7, dangerousThanaNames: []),
        wasRerouted: false,
        steps: [
          RouteStep(
            location: at(north: 300),
            distanceMeters: 300,
            maneuver: ManeuverKind.left,
            streetName: 'Satmasjid Road',
          ),
          RouteStep(location: at(north: 300, east: -100), distanceMeters: 100, maneuver: ManeuverKind.arrive),
        ],
      );

  Future<void> walkTo(LatLng p) async {
    positions.add(fix(p));
    // The arrival branch speaks, tears the subscription down and updates the
    // progress notifier — several async hops past a single microtask.
    await pumpEventQueue();
  }

  List<String> assistantTextIn(ProviderContainer c) => c
      .read(chatControllerProvider)
      .messages
      .where((m) => m.sender == ChatSender.assistant)
      .map((m) => m.text)
      .toList();

  test('spoken turns also land in the chat as text', () async {
    // Subscribing is what `build()` does, so reading the state is enough to
    // start it.
    container.read(chatControllerProvider);
    await navigation.start(route(), language: AppLanguage.english);
    await walkTo(at(north: 150));

    final d = Dashboard.of(AppLanguage.english);
    expect(
      assistantTextIn(container),
      contains(d.navigateTurnAhead(kind: ManeuverKind.left, meters: 150, streetName: 'Satmasjid Road')),
    );
  });

  test('the whole spoken transcript is mirrored, in order', () async {
    final spoken = <String>[];
    final sub = navigation.spokenCues.listen(spoken.add);
    container.read(chatControllerProvider);

    await navigation.start(route(), language: AppLanguage.english);
    await walkTo(at(north: 150));
    await walkTo(at(north: 290));
    await sub.cancel();

    expect(assistantTextIn(container), spoken);
  });

  test('arriving retires the route instead of leaving it active forever', () async {
    container.read(chatControllerProvider);
    await navigation.start(route(), language: AppLanguage.english);
    // The chat holds the route the same way the executor would have set it.
    expect(container.read(chatControllerProvider).pendingRoute, isNull);

    for (final p in [at(north: 150), at(north: 300), at(north: 300, east: -100)]) {
      await walkTo(p);
    }
    // The arrival buzz is a double tap with a real 120 ms gap between the
    // two, which `pumpEventQueue` cannot fast-forward.
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(assistantTextIn(container), contains(Dashboard.of(AppLanguage.english).navigateArrived));
    expect(container.read(chatControllerProvider).pendingRoute, isNull);
    expect(navigation.progress.value?.arrived, isTrue,
        reason: 'the map has to be able to show arrival, not just a null');
  });

  test('cues are not spoken a second time on their way to the chat', () async {
    // The controller already said them. A user hearing every turn twice is
    // worse off than one who never saw the text.
    final tts = _RecordingTts();
    final counting = NavigationController(tts: tts, positionStream: positions.stream);
    final scope = ProviderContainer(
      overrides: [navigationControllerProvider.overrideWithValue(counting)],
    );
    addTearDown(scope.dispose);
    scope.read(chatControllerProvider);

    await counting.start(route(), language: AppLanguage.english);
    await walkTo(at(north: 150));

    expect(tts.spoken, assistantTextIn(scope));
  });
}

/// `implements`, not `extends` — `TtsService`'s constructor reaches straight
/// into the `flutter_tts` and `audioplayers` platform channels, which throw
/// in a plain unit test and fail it asynchronously, well away from whatever
/// assertion noticed.
class _SilentTts implements TtsService {
  @override
  Future<void> speak(String text, {AppLanguage language = AppLanguage.english}) async {}

  @override
  Future<void> stop() async {}

  @override
  void setVoiceId(String voiceId) {}
}

class _RecordingTts implements TtsService {
  final List<String> spoken = [];

  @override
  Future<void> speak(String text, {AppLanguage language = AppLanguage.english}) async => spoken.add(text);

  @override
  Future<void> stop() async {}

  @override
  void setVoiceId(String voiceId) {}
}
