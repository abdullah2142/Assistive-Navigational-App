// The narrator decides what to say; this decides that it actually gets
// said. Driven by a synthetic position stream so the whole chain — GPS in,
// spoken Bangla/English out — runs without a device.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';
import 'package:ant_app/core/services/navigation_controller.dart';
import 'package:ant_app/core/services/route_planning_service.dart';
import 'package:ant_app/core/services/route_safety_service.dart';
import 'package:ant_app/core/services/routing_service.dart';
import 'package:ant_app/core/services/tts_service.dart';

/// `implements`, not `extends` — `TtsService`'s constructor immediately
/// calls into the `flutter_tts` and `audioplayers` platform channels, which
/// throw `MissingPluginException` in a plain unit test and fail it
/// asynchronously, well away from the assertion that noticed.
class _RecordingTts implements TtsService {
  final List<String> spoken = [];

  @override
  Future<void> speak(String text, {AppLanguage language = AppLanguage.english}) async {
    spoken.add(text);
  }

  @override
  Future<void> stop() async {}

  @override
  void setVoiceId(String voiceId) {}
}

const _origin = LatLng(23.7461, 90.3742);
const _metresPerDegreeLat = 111320.0;
double get _metresPerDegreeLng => 111320.0 * 0.9166;

LatLng at({double north = 0, double east = 0}) => LatLng(
      _origin.latitude + north / _metresPerDegreeLat,
      _origin.longitude + east / _metresPerDegreeLng,
    );

Position fix(LatLng p, {double accuracy = 5}) => Position(
      latitude: p.latitude,
      longitude: p.longitude,
      timestamp: DateTime.utc(2026, 9, 4),
      accuracy: accuracy,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 1.2,
      speedAccuracy: 0,
    );

RouteChoice routeTo({List<RouteStep>? steps, String label = 'Gulshan 2'}) => RouteChoice(
      destinationLabel: label,
      points: [
        for (var n = 0.0; n <= 300; n += 25) at(north: n),
        for (var e = 0.0; e >= -100; e -= 25) at(north: 300, east: e),
      ],
      distanceMeters: 400,
      durationSeconds: 320,
      initialBearingDegrees: 0,
      verdict: const SafetyVerdict(safe: true, riskScore: 1, threshold: 7, dangerousThanaNames: []),
      wasRerouted: false,
      steps: steps ??
          [
            RouteStep(
              location: at(north: 300),
              distanceMeters: 300,
              maneuver: ManeuverKind.left,
              streetName: 'Satmasjid Road',
            ),
            RouteStep(
              location: at(north: 300, east: -100),
              distanceMeters: 100,
              maneuver: ManeuverKind.arrive,
            ),
          ],
    );

void main() {
  // `HapticFeedback` goes through a system channel, which needs a binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RecordingTts tts;
  late StreamController<Position> positions;
  late NavigationController controller;

  setUp(() {
    tts = _RecordingTts();
    positions = StreamController<Position>.broadcast();
    controller = NavigationController(tts: tts, positionStream: positions.stream);
  });

  tearDown(() async {
    await controller.stop(silent: true);
    await positions.close();
  });

  /// Feeds a position and lets the async announcement settle.
  Future<void> walkTo(LatLng p, {double accuracy = 5}) async {
    positions.add(fix(p, accuracy: accuracy));
    await Future<void>.delayed(Duration.zero);
  }

  /// Longer settle, for the arrival cue — it buzzes twice with a real gap
  /// between the buzzes before it speaks, so a zero-duration yield lands
  /// while the announcement is still in flight.
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 250));

  test('announces the journey, then each turn, then arrival', () async {
    final d = Dashboard.of(AppLanguage.english);
    await controller.start(routeTo(), language: AppLanguage.english);

    expect(controller.isNavigating, isTrue);
    expect(tts.spoken.single, contains('Gulshan 2'));

    for (var n = 0.0; n <= 280; n += 20) {
      await walkTo(at(north: n));
    }
    // Both warnings and the instruction itself.
    expect(tts.spoken.where((t) => t.contains(d.maneuverDirection(ManeuverKind.left))), hasLength(3));
    expect(tts.spoken.any((t) => t.contains('Satmasjid Road')), isTrue);

    await walkTo(at(north: 300));
    await walkTo(at(north: 300, east: -100));
    await settle();
    expect(tts.spoken.last, d.navigateArrived);
    expect(controller.isNavigating, isFalse, reason: 'arriving ends the session');
  });

  test('an imprecise fix is ignored rather than acted on', () async {
    await controller.start(routeTo(), language: AppLanguage.english);
    final beforeCount = tts.spoken.length;

    // A 120 m accuracy reading under a flyover looks exactly like the user
    // having wandered far off route. Announcing that is worse than silence.
    await walkTo(at(north: 150, east: 400), accuracy: 120);
    expect(tts.spoken.length, beforeCount);
  });

  test('every spoken cue is also emitted for the transcript', () async {
    // A Deaf-blind user, or one with the voice muted, still needs the
    // directions in text.
    final seen = <String>[];
    final sub = controller.spokenCues.listen(seen.add);
    await controller.start(routeTo(), language: AppLanguage.english);
    await walkTo(at(north: 150));
    await sub.cancel();
    expect(seen, tts.spoken);
  });

  test('a route with no manoeuvres says so instead of going silent', () async {
    final d = Dashboard.of(AppLanguage.english);
    await controller.start(routeTo(steps: const []), language: AppLanguage.english);

    expect(controller.isNavigating, isFalse);
    expect(tts.spoken.single, d.navigateNoStepsFallback(destination: 'Gulshan 2', meters: 400));
  });

  test('starting a second route replaces the first silently', () async {
    await controller.start(routeTo(), language: AppLanguage.english);
    await controller.start(routeTo(label: 'New Market'), language: AppLanguage.english);

    expect(controller.activeRoute?.destinationLabel, 'New Market');
    // No "navigation stopped" between the two — the user asked for a new
    // route, not to stop.
    expect(tts.spoken.any((t) => t == Dashboard.of(AppLanguage.english).navigateStopped), isFalse);
  });

  test('navigating in Bangla speaks Bangla', () async {
    await controller.start(routeTo(), language: AppLanguage.bangla);
    for (var n = 0.0; n <= 280; n += 20) {
      await walkTo(at(north: n));
    }
    expect(tts.spoken.every((t) => RegExp(r'[ঀ-৿]').hasMatch(t)), isTrue,
        reason: 'spoken: ${tts.spoken}');
  });

  test('stopping ends the session and says so', () async {
    final d = Dashboard.of(AppLanguage.english);
    await controller.start(routeTo(), language: AppLanguage.english);
    await controller.stop();
    expect(controller.isNavigating, isFalse);
    expect(tts.spoken.last, d.navigateStopped);

    // And no further positions produce speech.
    final count = tts.spoken.length;
    await walkTo(at(north: 250));
    expect(tts.spoken.length, count);
  });
}
