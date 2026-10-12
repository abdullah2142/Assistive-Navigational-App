// A MANUAL, LIVE probe of the vision pipeline against real photographs —
// not part of the regular suite, same shape as live_gemini_probe_test.dart.
//
// There is no camera in this environment, so "can it identify a bus" has
// to be asked with real photographs instead of a live frame. These are
// real, freely-licensed photos pulled from Wikimedia Commons (Dhaka buses,
// a transit sign, three street scenes standing in for a sweep's
// left/ahead/right), fed through the exact GeminiVisionService.describe()
// call ScanFocus.vehicle/sign/ahead/surroundings use in the app.
//
// Costs real API calls. Does nothing without a key or without the images
// downloaded first — see the `_imagesDir` check. To run it:
//
//   flutter test --dart-define-from-file=dart_defines.local.json test/live_vision_probe_test.dart
//
// Findings are printed, not just asserted.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/config/gemini_config.dart';
import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/services/vision/gemini_vision_service.dart';
import 'package:ant_app/core/services/vision/vision_scene.dart';

const _imagesDir = '/tmp/claude-1000/vision_test_images';

void main() {
  if (!GeminiConfig.isConfigured) {
    test('skipped — no GEMINI_API_KEY configured', () {}, skip: true);
    return;
  }
  if (!Directory(_imagesDir).existsSync()) {
    test('skipped — no test images at $_imagesDir', () {}, skip: true);
    return;
  }

  setUp(() => Future<void>.delayed(const Duration(seconds: 13)));

  GeminiVisionService service() => GeminiVisionService(modelName: GeminiConfig.flashLite35);

  Uint8List load(String name) => File('$_imagesDir/$name').readAsBytesSync();

  void report(String label, VisionScene? scene) {
    if (scene == null) {
      // ignore: avoid_print
      print('--- $label --- NULL (not configured, cooling down, or budget exhausted)');
      return;
    }
    // ignore: avoid_print
    print(
      '--- $label ---\n'
      'spoken: ${scene.spoken}\n'
      'textFound: ${scene.textFound}\n'
      'vehicles: ${scene.vehicles.map((v) => '${v.kind} route=${v.routeNumber} dest=${v.destination} raw="${v.rawText}"').toList()}\n'
      'hazards: ${scene.hazards.map((h) => '${h.kind}(${h.severity}): ${h.description}').toList()}\n'
      'peopleEstimate: ${scene.peopleEstimate}  degraded: ${scene.degraded}\n',
    );
  }

  for (final bus in ['bus1.jpg', 'bus2.jpg', 'bus3.jpg', 'bus4.jpg']) {
    test('ScanFocus.vehicle on $bus — can it identify/read the bus', () async {
      final scene = await service().describe(
        jpegs: [load(bus)],
        focus: ScanFocus.vehicle,
        language: AppLanguage.english,
      );
      report('vehicle: $bus', scene);
      expect(scene, isNotNull, reason: 'a real photo of a real bus must get a real answer');
    }, timeout: const Timeout(Duration(seconds: 30)));
  }

  test('ScanFocus.sign on sign1.jpg — can it read the sign', () async {
    final scene = await service().describe(
      jpegs: [load('sign1.jpg')],
      focus: ScanFocus.sign,
      language: AppLanguage.english,
    );
    report('sign: sign1.jpg', scene);
    expect(scene, isNotNull);
    expect(scene!.textFound, isNotEmpty, reason: 'the sign has visible text — this must not come back empty');
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('ScanFocus.ahead on street_ahead.jpg — single frame, straight description', () async {
    final scene = await service().describe(
      jpegs: [load('street_ahead.jpg')],
      focus: ScanFocus.ahead,
      language: AppLanguage.english,
    );
    report('ahead: street_ahead.jpg', scene);
    expect(scene, isNotNull);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('ScanFocus.surroundings, 3 frames — the Stationary Sweep', () async {
    // sweep_left/ahead/right.jpg are three true directional crops of one
    // 360° panorama taken from a single standing point (Dhakeshwari
    // National Temple Complex courtyard) — unlike an earlier version of
    // this test, which used three unrelated street photos and got back
    // "I cannot tell": that result was ambiguous between "the sweep
    // doesn't work" and "three unrelated photos are not a fair sweep".
    // This settles which.
    final scene = await service().describe(
      jpegs: [
        load('sweep_left.jpg'),
        load('sweep_ahead.jpg'),
        load('sweep_right.jpg'),
      ],
      focus: ScanFocus.surroundings,
      language: AppLanguage.english,
    );
    report('surroundings: 3-frame sweep (true panorama crop)', scene);
    expect(scene, isNotNull, reason: 'all 3 frames must be accepted in one request — see maxFrames');
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('a specific question overrides the generic focus framing', () async {
    final scene = await service().describe(
      jpegs: [load('bus1.jpg')],
      focus: ScanFocus.ahead,
      language: AppLanguage.english,
      question: 'What route number is this bus, and where is it going?',
    );
    report('question override: bus1.jpg', scene);
    expect(scene, isNotNull);
  }, timeout: const Timeout(Duration(seconds: 30)));
}
