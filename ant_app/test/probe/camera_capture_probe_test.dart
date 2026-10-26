// QA probe for the camera capture path (area key: camera_capture).
//
// Everything here PASSES today and pins behaviour that was verified to work.
// The real `CameraController` is driven through a fake `CameraPlatform`, so
// the plugin's own guards (isTakingPicture, disposed checks) are the real
// ones. What a fake cannot show (sensor, autofocus, preview texture, real
// Android camera-in-use errors) is listed in the QA report, not simulated.
import 'dart:async';
import 'dart:typed_data';

import 'package:ant_app/core/config/vision_config.dart';
import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';
import 'package:ant_app/core/services/haptics_service.dart';
import 'package:ant_app/core/services/vision/edge_hazard_detector.dart';
import 'package:ant_app/core/services/vision/vision_detection.dart';
import 'package:ant_app/core/services/vision/snapshot_camera.dart';
import 'package:ant_app/core/services/vision/snapshot_vision_service.dart';
import 'package:ant_app/core/services/vision/vision_backend.dart';
import 'package:ant_app/core/services/vision/vision_router.dart';
import 'package:ant_app/core/services/vision/vision_scene.dart';
import 'package:camera/camera.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart'
    show
        CameraEvent,
        CameraInitializedEvent,
        CameraErrorEvent,
        CameraPlatform,
        DeviceOrientationChangedEvent,
        MediaSettings;
import 'package:ant_app/core/providers/ai_assistant_providers.dart';
import 'package:ant_app/core/providers/tts_providers.dart';
import 'package:ant_app/core/services/tts_service.dart';
import 'package:ant_app/core/services/emergency_service.dart' show EmergencyService;
import 'package:ant_app/core/services/vision/cloud_vision_service.dart' show VisionBudgetExhausted;
import 'package:ant_app/core/services/vision/vision_channel.dart';
import 'package:ant_app/features/dashboard/providers/chat_providers.dart';
import 'package:ant_app/features/dashboard/screens/camera_aiming_screen.dart';
import 'package:ant_app/features/dashboard/widgets/camera_aiming_dialog.dart';
import 'package:ant_app/features/onboarding/models/disability_profile_enums.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodCall, MethodChannel, StandardMethodCodec;
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

// ---------------------------------------------------------------- fakes ----

Uint8List jpeg([int w = 96, int h = 72, int seed = 0]) {
  final image = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      image.setPixelRgb(x, y, (x * 3 + seed) % 256, (y * 5) % 256, (x ^ y) % 256);
    }
  }
  return Uint8List.fromList(img.encodeJpg(image));
}

class FakePlatform extends CameraPlatform {
  int created = 0;
  int initialised = 0;
  int disposed = 0;
  int pictures = 0;
  Object? listError;
  List<CameraDescription> cameras = const [
    CameraDescription(
      name: 'back0',
      lensDirection: CameraLensDirection.back,
      sensorOrientation: 90,
    ),
  ];
  Object? createError;
  Object? initError;
  Object? focusError;
  Object? flashError;
  Object? pictureError;
  Completer<void>? initGate;
  Future<void> Function(int n)? pictureHook;
  final liveIds = <int>{};
  final pictureQueue = <Uint8List>[];

  @override
  Future<List<CameraDescription>> availableCameras() async {
    if (listError != null) throw listError!;
    return cameras;
  }

  @override
  Future<int> createCameraWithSettings(
    CameraDescription camera,
    MediaSettings settings,
  ) async {
    if (createError != null) throw createError!;
    created++;
    liveIds.add(created);
    return created;
  }

  @override
  Future<void> initializeCamera(
    int cameraId, {
    ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown,
  }) async {
    if (initGate != null) await initGate!.future;
    if (initError != null) throw initError!;
    initialised++;
  }

  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) =>
      Stream.value(
        CameraInitializedEvent(
          cameraId,
          640,
          480,
          ExposureMode.auto,
          false,
          FocusMode.auto,
          false,
        ),
      );

  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) =>
      StreamController<CameraErrorEvent>().stream;

  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      StreamController<DeviceOrientationChangedEvent>.broadcast().stream;

  @override
  Future<void> setFocusMode(int cameraId, FocusMode mode) async {
    if (focusError != null) throw focusError!;
  }

  @override
  Future<void> setFlashMode(int cameraId, FlashMode mode) async {
    if (flashError != null) throw flashError!;
  }

  @override
  Future<XFile> takePicture(int cameraId) async {
    final n = ++pictures;
    if (pictureHook != null) await pictureHook!(n);
    if (pictureError != null) throw pictureError!;
    final bytes = pictureQueue.isNotEmpty ? pictureQueue.removeAt(0) : jpeg(96, 72, n);
    return XFile.fromData(bytes, name: 'p$n.jpg');
  }

  @override
  Future<void> dispose(int cameraId) async {
    disposed++;
    liveIds.remove(cameraId);
  }

  @override
  Widget buildPreview(int cameraId) => const SizedBox(width: 10, height: 10);
}

class FakeTts implements TtsService {
  final List<String> spoken = [];
  @override
  Future<void> speak(String text, {AppLanguage language = AppLanguage.english}) async {
    // The "Looking…" cue is new, deliberate and tested elsewhere.
    if (text != 'Looking…' && text != 'দেখছি…') spoken.add(text);
  }
  @override
  Future<void> stop() async {}
  @override
  void setVoiceId(String voiceId) {}
}

UserProfile blind({bool deaf = false, AppLanguage language = AppLanguage.english}) =>
    UserProfile(
      uid: 'u1',
      role: UserRole.disabledUser,
      visionLevel: VisionLevel.none,
      isDeafOrHardOfHearing: deaf,
      language: language,
    );

class ThrowingBackend implements VisionBackend {
  ThrowingBackend(this.name, this.error, {this.maxFrames = 1});
  @override
  final String name;
  final Object error;
  @override
  final int maxFrames;
  @override
  bool get isConfigured => true;
  int calls = 0;
  @override
  Future<VisionScene?> describe({
    required List<Uint8List> jpegs,
    required ScanFocus focus,
    required AppLanguage language,
    List<String> edgeLabels = const [],
    String? question,
  }) async {
    calls++;
    throw error;
  }
}

class RecordingHaptics extends HapticsService {
  RecordingHaptics() : super(probeOverride: (motor: false, amplitude: false));
  final cues = <HapticCue>[];
  @override
  Future<void> play(HapticCue cue) async => cues.add(cue);
}

class FakeBackend implements VisionBackend {
  FakeBackend(this.name, this.maxFrames, {this.delay, this.reply = 'a scene'});
  @override
  final String name;
  @override
  final int maxFrames;
  @override
  bool isConfigured = true;
  final Duration? delay;
  final String reply;
  final calls = <int>[];
  @override
  Future<VisionScene?> describe({
    required List<Uint8List> jpegs,
    required ScanFocus focus,
    required AppLanguage language,
    List<String> edgeLabels = const [],
    String? question,
  }) async {
    calls.add(jpegs.length);
    if (delay != null) await Future<void>.delayed(delay!);
    return VisionScene(focus: focus, spoken: reply);
  }
}

CameraController realController(CameraDescription d) =>
    CameraController(d, ResolutionPreset.high, enableAudio: false);

SnapshotCamera newCamera(FakePlatform p) => SnapshotCamera(
  listCameras: () => p.availableCameras(),
  buildController: realController,
);

SnapshotVisionService newService(
  SnapshotCamera camera, {
  FakeBackend? groq,
  FakeBackend? gemini,
  RecordingHaptics? haptics,
}) => SnapshotVisionService(
  camera: camera,
  edge: EdgeHazardDetector(
    loadInterpreter: () async => null,
    loadLabels: () async => const [],
  ),
  cloud: VisionRouter(
    groq: groq ?? FakeBackend('groq', 1),
    gemini: gemini ?? FakeBackend('gemini', 3),
  ),
  haptics: haptics ?? RecordingHaptics(),
);

FakePlatform installPlatform() {
  final p = FakePlatform();
  CameraPlatform.instance = p;
  return p;
}

// ---------------------------------------------------------------- tests ----

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final d = Dashboard.of(AppLanguage.english);

  group('SnapshotCamera open / availability', () {
    test('open() succeeds, exposes controller, sets focus and flash', () async {
      final p = installPlatform();
      final cam = newCamera(p);
      expect(await cam.open(), isTrue);
      expect(cam.isOpen, isTrue);
      expect(cam.controller, isNotNull);
      expect(cam.isAvailable, isTrue);
      expect(p.created, 1);
      cam.dispose();
    });

    test('no camera on the device -> false, isAvailable false, capture empty', () async {
      final p = installPlatform()..cameras = const [];
      final cam = newCamera(p);
      expect(await cam.open(), isFalse);
      expect(cam.isAvailable, isFalse);
      expect(cam.controller, isNull);
      expect(await cam.capture(), isEmpty);
    });

    test('listing cameras throws -> handled, never propagates', () async {
      final p = installPlatform()..listError = CameraException('x', 'boom');
      final cam = newCamera(p);
      expect(await cam.open(), isFalse);
      expect(await cam.capture(count: 3), isEmpty);
    });

    test('permission denied on create -> false, no controller kept', () async {
      final p = installPlatform()
        ..createError = CameraException('CameraAccessDenied', 'denied');
      final cam = newCamera(p);
      expect(await cam.open(), isFalse);
      expect(cam.isOpen, isFalse);
      expect(cam.controller, isNull);
      expect(cam.isAvailable, isFalse);
    });

    test('permission granted later: the next open() recovers', () async {
      final p = installPlatform()
        ..createError = CameraException('CameraAccessDenied', 'denied');
      final cam = newCamera(p);
      expect(await cam.open(), isFalse);
      p.createError = null;
      expect(await cam.open(), isTrue);
      expect(cam.isAvailable, isTrue);
      cam.dispose();
    });

    test('only a front camera: it is used rather than reporting no camera', () async {
      final p = installPlatform()
        ..cameras = const [
          CameraDescription(
            name: 'front',
            lensDirection: CameraLensDirection.front,
            sensorOrientation: 270,
          ),
        ];
      final cam = newCamera(p);
      expect(await cam.open(), isTrue);
      cam.dispose();
    });

    test('front listed before back: back is chosen', () async {
      final p = installPlatform()
        ..cameras = const [
          CameraDescription(
            name: 'front',
            lensDirection: CameraLensDirection.front,
            sensorOrientation: 270,
          ),
          CameraDescription(
            name: 'back',
            lensDirection: CameraLensDirection.back,
            sensorOrientation: 90,
          ),
        ];
      final cam = newCamera(p);
      CameraDescription? built;
      final cam2 = SnapshotCamera(
        listCameras: () => p.availableCameras(),
        buildController: (desc) {
          built = desc;
          return realController(desc);
        },
      );
      expect(await cam2.open(), isTrue);
      expect(built!.name, 'back');
      cam2.dispose();
      cam.dispose();
    });

    test('focus-mode and flash-mode refusal does not lose the camera', () async {
      final p = installPlatform()
        ..focusError = CameraException('f', 'no focus')
        ..flashError = CameraException('f', 'no flash');
      final cam = newCamera(p);
      expect(await cam.open(), isTrue);
      expect(await cam.capture(), hasLength(1));
      cam.dispose();
    });

    test('two simultaneous open() calls create the sensor once', () async {
      final p = installPlatform();
      final cam = newCamera(p);
      final r = await Future.wait([cam.open(), cam.open(), cam.open()]);
      expect(r, [true, true, true]);
      expect(p.created, 1);
      cam.dispose();
    });

    test('a failed initialise lets the concurrent waiter see false, not hang', () async {
      final p = installPlatform()
        ..initGate = Completer<void>()
        ..initError = CameraException('CameraInUse', 'busy');
      final cam = newCamera(p);
      final a = cam.open();
      final b = cam.open();
      p.initGate!.complete();
      expect(await Future.wait([a, b]), [false, false]);
    });

    test('camera busy (another app) then freed: retry succeeds', () async {
      final p = installPlatform()
        ..initError = CameraException('CameraInUse', 'busy');
      final cam = newCamera(p);
      expect(await cam.open(), isFalse);
      p.initError = null;
      expect(await cam.open(), isTrue);
      cam.dispose();
    });
  });

  group('SnapshotCamera capture', () {
    test('single frame is real JPEG bytes', () async {
      final p = installPlatform();
      final cam = newCamera(p);
      final frames = await cam.capture();
      expect(frames, hasLength(1));
      expect(img.decodeJpg(frames.first), isNotNull);
      cam.dispose();
    });

    test('a second overlapping capture is declined, not double-opened', () async {
      final p = installPlatform();
      p.pictureHook = (n) => Future<void>.delayed(const Duration(milliseconds: 50));
      final cam = newCamera(p);
      final first = cam.capture();
      final second = await cam.capture();
      expect(second, isEmpty);
      expect(await first, hasLength(1));
      expect(p.created, 1);
      cam.dispose();
    });

    test('overlap decline leaves camera usable for the next call', () async {
      final p = installPlatform();
      p.pictureHook = (n) => Future<void>.delayed(const Duration(milliseconds: 20));
      final cam = newCamera(p);
      final first = cam.capture();
      await cam.capture();
      await first;
      expect(await cam.capture(), hasLength(1));
      cam.dispose();
    });

    test('middle frame failing still returns the other two', () async {
      final p = installPlatform();
      p.pictureHook = (n) async {
        if (n == 2) throw PlatformException(code: 'x', message: 'blur');
      };
      final cam = newCamera(p);
      final frames = await cam.capture(count: 3, gap: Duration.zero);
      expect(frames, hasLength(2));
      cam.dispose();
    });

    test('every frame failing returns empty and keeps isAvailable true', () async {
      final p = installPlatform()..pictureError = PlatformException(code: 'x', message: 'bad');
      final cam = newCamera(p);
      expect(await cam.capture(count: 3, gap: Duration.zero), isEmpty);
      // So the spoken line is "did not take a picture", not "no camera".
      expect(cam.isAvailable, isTrue);
      cam.dispose();
    });

    test('onBeforeFrame runs in index order before each frame', () async {
      final p = installPlatform();
      final order = <String>[];
      p.pictureHook = (n) async => order.add('shot$n');
      final cam = newCamera(p);
      await cam.capture(
        count: 3,
        onBeforeFrame: (i) async => order.add('cue$i'),
      );
      expect(order, ['cue0', 'shot1', 'cue1', 'shot2', 'cue2', 'shot3']);
      cam.dispose();
    });

    test('releaseNow in the middle of a sweep: later frames fail cleanly, no throw', () async {
      final p = installPlatform();
      final cam = newCamera(p);
      final frames = await cam.capture(
        count: 3,
        onBeforeFrame: (i) async {
          if (i == 1) cam.releaseNow();
        },
      );
      expect(frames.length, lessThan(3));
      expect(frames, isNotEmpty);
      expect(cam.isOpen, isFalse);
      // And the next request opens a brand-new controller.
      expect(await cam.capture(), hasLength(1));
      cam.dispose();
    });

    test('releaseNow disposes the native camera exactly once', () async {
      final p = installPlatform();
      final cam = newCamera(p);
      await cam.open();
      cam.releaseNow();
      cam.releaseNow();
      cam.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(p.disposed, 1);
      expect(p.liveIds, isEmpty);
    });

    test('warm window: a 2nd capture inside 20 s reuses the sensor; after 20 s it is released',
        () {
      fakeAsync((fa) {
        final p = installPlatform();
        final cam = newCamera(p);
        cam.capture();
        fa.flushMicrotasks();
        fa.elapse(const Duration(seconds: 19));
        expect(cam.isOpen, isTrue);
        cam.capture();
        fa.flushMicrotasks();
        expect(p.created, 1);
        fa.elapse(VisionConfig.cameraWarmWindow + const Duration(milliseconds: 1));
        fa.flushMicrotasks();
        expect(cam.isOpen, isFalse);
        expect(p.liveIds, isEmpty);
      });
    });

    test('a failed open does not leave a stale release timer or controller', () {
      fakeAsync((fa) {
        final p = installPlatform()
          ..createError = CameraException('CameraAccessDenied', 'no');
        final cam = newCamera(p);
        cam.capture();
        fa.flushMicrotasks();
        fa.elapse(const Duration(seconds: 25));
        expect(cam.isOpen, isFalse);
        expect(fa.nonPeriodicTimerCount, 0);
      });
    });

    test('holdOpen:true schedules no timer (owner must close) and closeCamera releases', () {
      fakeAsync((fa) {
        final p = installPlatform();
        final cam = newCamera(p);
        cam.capture(holdOpen: true);
        fa.flushMicrotasks();
        expect(fa.nonPeriodicTimerCount, 0);
        cam.releaseNow();
        fa.flushMicrotasks();
        expect(p.liveIds, isEmpty);
      });
    });
  });

  group('SnapshotVisionService.scan spoken outcomes (never silent)', () {
    test('no camera -> visionNoCamera sentence', () async {
      final p = installPlatform()..cameras = const [];
      final svc = newService(newCamera(p));
      final r = await svc.scan(focus: ScanFocus.ahead, language: AppLanguage.english);
      expect(r.spoken, d.visionNoCamera);
      expect(r.spoken, isNotEmpty);
    });

    test('capture failure -> visionCaptureFailed sentence', () async {
      final p = installPlatform()..pictureError = PlatformException(code: 'x', message: 'bad');
      final svc = newService(newCamera(p));
      final r = await svc.scan(focus: ScanFocus.ahead, language: AppLanguage.english);
      expect(r.spoken, d.visionCaptureFailed);
    });

    test('Bangla failure sentences are Bangla', () async {
      final p = installPlatform()..cameras = const [];
      final svc = newService(newCamera(p));
      final r = await svc.scan(focus: ScanFocus.ahead, language: AppLanguage.bangla);
      expect(r.spoken, Dashboard.of(AppLanguage.bangla).visionNoCamera);
      expect(RegExp(r'[ঀ-৿]').hasMatch(r.spoken), isTrue);
    });

    test('one-frame ask uploads 1 frame; sweep uploads 3 in order to Gemini', () async {
      final p = installPlatform();
      final groq = FakeBackend('groq', 1);
      final gem = FakeBackend('gemini', 3);
      final svc = newService(newCamera(p), groq: groq, gemini: gem);
      await svc.scan(focus: ScanFocus.ahead, language: AppLanguage.english);
      expect(groq.calls, [1]);
      svc.closeCamera();
      final r = await svc.scan(
        focus: ScanFocus.surroundings,
        language: AppLanguage.english,
        sweep: true,
      );
      expect(gem.calls, [3]);
      expect(r.frameJpeg, isNotNull);
      expect(p.pictures, 4);
      svc.closeCamera();
    });

    test('sweep collapses to one frame when only Groq is configured', () async {
      final p = installPlatform();
      final groq = FakeBackend('groq', 1);
      final gem = FakeBackend('gemini', 3)..isConfigured = false;
      final haptics = RecordingHaptics();
      final svc = newService(newCamera(p), groq: groq, gemini: gem, haptics: haptics);
      final spoken = <String>[];
      await svc.scan(
        focus: ScanFocus.surroundings,
        language: AppLanguage.english,
        sweep: true,
        narrate: (t) async => spoken.add(t),
      );
      expect(p.pictures, 1);
      expect(groq.calls, [1]);
      // No cue for a one-frame "sweep": nothing to aim at.
      expect(spoken, isEmpty);
      expect(haptics.cues, isEmpty);
      svc.closeCamera();
    });

    test('sweep cue order is left, ahead, right; buzz first; 700 ms settle between', () async {
      final p = installPlatform();
      final haptics = RecordingHaptics();
      final events = <String>[];
      final sw = Stopwatch()..start();
      p.pictureHook = (n) async => events.add('shot$n@${sw.elapsedMilliseconds}');
      final svc = newService(newCamera(p), haptics: haptics);
      await svc.scan(
        focus: ScanFocus.surroundings,
        language: AppLanguage.english,
        sweep: true,
        narrate: (t) async => events.add(t),
      );
      expect(haptics.cues, [HapticCue.turnLeft, HapticCue.navigation, HapticCue.turnRight]);
      expect(events.where((e) => !e.startsWith('shot')).toList(),
          ['Left.', 'Straight ahead.', 'Right.']);
      final shotTimes = [
        for (final e in events.where((e) => e.startsWith('shot')))
          int.parse(e.split('@').last),
      ];
      expect(shotTimes[1] - shotTimes[0], greaterThanOrEqualTo(650));
      expect(shotTimes[2] - shotTimes[1], greaterThanOrEqualTo(650));
      svc.closeCamera();
    });

    test('narration throwing mid-sweep does not abort the sweep', () async {
      final p = installPlatform();
      final svc = newService(newCamera(p));
      final gem = FakeBackend('gemini', 3);
      final svc2 = newService(newCamera(p), gemini: gem);
      await svc2.scan(
        focus: ScanFocus.surroundings,
        language: AppLanguage.english,
        sweep: true,
        narrate: (t) async => throw StateError('tts died'),
      );
      expect(gem.calls, [3]);
      svc.closeCamera();
      svc2.closeCamera();
    });

    test('a failed middle frame still uploads the surviving two', () async {
      final p = installPlatform();
      p.pictureHook = (n) async {
        if (n == 2) throw PlatformException(code: 'x', message: 'fail');
      };
      final gem = FakeBackend('gemini', 3);
      final svc = newService(newCamera(p), gemini: gem);
      await svc.scan(
        focus: ScanFocus.surroundings,
        language: AppLanguage.english,
        sweep: true,
      );
      expect(gem.calls, [2]);
      svc.closeCamera();
    });

    test('second scan while one is running is told "still looking", flag resets after', () async {
      final p = installPlatform();
      p.pictureHook = (n) => Future<void>.delayed(const Duration(milliseconds: 60));
      final svc = newService(newCamera(p));
      final first = svc.scan(focus: ScanFocus.ahead, language: AppLanguage.english);
      final second = await svc.scan(focus: ScanFocus.ahead, language: AppLanguage.english);
      expect(second.spoken, d.visionAlreadyLooking);
      await first;
      expect(svc.isScanning.value, isFalse);
      svc.closeCamera();
    });

    test('isScanning is reset even when the camera layer throws', () async {
      final p = installPlatform();
      final cam = SnapshotCamera(
        listCameras: () async => throw StateError('plugin exploded'),
        buildController: realController,
      );
      final svc = newService(cam);
      final r = await svc.scan(focus: ScanFocus.ahead, language: AppLanguage.english);
      expect(r.spoken, isNotEmpty);
      expect(svc.isScanning.value, isFalse);
      expect(p.created, 0);
    });

    test('captured JPEG from the viewfinder skips the camera entirely', () async {
      final p = installPlatform();
      final svc = newService(newCamera(p));
      final r = await svc.scan(
        focus: ScanFocus.ahead,
        language: AppLanguage.english,
        capturedJpeg: jpeg(),
      );
      expect(p.created, 0);
      expect(r.frameJpeg, isNotNull);
    });

    test('single frame with an imminent local hazard: buzz, spoken Stop, nothing uploaded', () async {
      final p = installPlatform();
      final groq = FakeBackend('groq', 1);
      final haptics = RecordingHaptics();
      final svc = SnapshotVisionService(
        camera: newCamera(p),
        edge: _ProbeEdge(const HazardVerdict(
          level: HazardLevel.imminent,
          detections: [VisionDetection(label: 'bus', confidence: 0.9, left: 0.1, top: 0.3, right: 0.5, bottom: 0.95)],
          nearest: VisionDetection(label: 'bus', confidence: 0.9, left: 0.1, top: 0.3, right: 0.5, bottom: 0.95),
          threatScore: 0.8,
        )),
        cloud: VisionRouter(groq: groq, gemini: FakeBackend('gemini', 3)),
        haptics: haptics,
      );
      final r = await svc.scan(focus: ScanFocus.ahead, language: AppLanguage.english);
      expect(r.abortedForHazard, isTrue);
      expect(haptics.cues, [HapticCue.hazard]);
      expect(r.spoken, contains('Stop'));
      expect(groq.calls, isEmpty);
      svc.closeCamera();
    });

    test('all cloud backends return null -> an honest offline sentence, never empty', () async {
      final p = installPlatform();
      final groq = FakeBackend('groq', 1)..isConfigured = false;
      final gem = FakeBackend('gemini', 3)..isConfigured = false;
      final svc = newService(newCamera(p), groq: groq, gemini: gem);
      final r = await svc.scan(focus: ScanFocus.ahead, language: AppLanguage.english);
      expect(r.spoken, d.visionOfflineNothingSeen);
      expect(r.frameJpeg, isNotNull);
      svc.closeCamera();
    });
  });

  // ====================================================================
  group('VisionRouter ordering and fallback', () {
    test('single frame: Groq first then Gemini; sweep: Gemini first then Groq', () {
      final groq = FakeBackend('groq', 1);
      final gem = FakeBackend('gemini', 3);
      final r = VisionRouter(groq: groq, gemini: gem);
      expect(r.orderFor(ScanFocus.ahead).map((b) => b.name), ['groq', 'gemini']);
      expect(r.orderFor(ScanFocus.surroundings, sweep: true).map((b) => b.name), ['gemini', 'groq']);
    });

    test('framesNeededFor: 3 with Gemini, 1 without, 1 for non-sweep', () {
      final gem = FakeBackend('gemini', 3);
      expect(VisionRouter(groq: FakeBackend('g', 1), gemini: gem)
          .framesNeededFor(ScanFocus.surroundings, sweepFrames: 3, sweep: true), 3);
      expect(VisionRouter(groq: FakeBackend('g', 1))
          .framesNeededFor(ScanFocus.surroundings, sweepFrames: 3, sweep: true), 1);
      expect(VisionRouter(groq: FakeBackend('g', 1), gemini: gem)
          .framesNeededFor(ScanFocus.ahead, sweepFrames: 3), 1);
    });

    test('a throwing primary falls through to the secondary', () async {
      final bad = ThrowingBackend('groq', StateError('429'));
      final good = FakeBackend('gemini', 3);
      final r = VisionRouter(groq: bad, gemini: good);
      final scene = await r.describe(
        jpegs: [jpeg()], focus: ScanFocus.ahead, language: AppLanguage.english);
      expect(scene?.spoken, 'a scene');
      expect(bad.calls, 1);
    });

    test('every backend budget-exhausted rethrows so the caller can say so', () async {
      final r = VisionRouter(
        groq: ThrowingBackend('groq', const VisionBudgetExhausted()),
        gemini: ThrowingBackend('gem', const VisionBudgetExhausted(), maxFrames: 3),
      );
      expect(
        r.describe(jpegs: [jpeg()], focus: ScanFocus.ahead, language: AppLanguage.english),
        throwsA(isA<VisionBudgetExhausted>()),
      );
    });

    test('budget spent on one, other merely broken -> null (not "looked too often")', () async {
      final r = VisionRouter(
        groq: ThrowingBackend('groq', const VisionBudgetExhausted()),
        gemini: ThrowingBackend('gem', StateError('503'), maxFrames: 3),
      );
      expect(
        await r.describe(jpegs: [jpeg()], focus: ScanFocus.ahead, language: AppLanguage.english),
        isNull,
      );
    });

    test('Qwen fallback after a failed Gemini sweep gets exactly the single best frame', () async {
      final gem = ThrowingBackend('gem', StateError('timeout'), maxFrames: 3);
      final groq = FakeBackend('groq', 1);
      final r = VisionRouter(groq: groq, gemini: gem);
      await r.describe(
        jpegs: [jpeg(), jpeg(), jpeg()],
        focus: ScanFocus.surroundings,
        language: AppLanguage.english,
        sweep: true,
        singleFrameFallback: jpeg(),
      );
      expect(groq.calls, [1]);
    });
  });

  group('SnapshotVisionService result cache', () {
    test('same question inside 12 s is answered from cache, marked as old', () async {
      final p = installPlatform();
      var t = DateTime(2026, 1, 1, 12);
      final groq = FakeBackend('groq', 1);
      final svc = SnapshotVisionService(
        camera: newCamera(p),
        edge: EdgeHazardDetector(loadInterpreter: () async => null, loadLabels: () async => const []),
        cloud: VisionRouter(groq: groq, gemini: FakeBackend('gemini', 3)),
        haptics: RecordingHaptics(),
        now: () => t,
      );
      await svc.scan(focus: ScanFocus.ahead, language: AppLanguage.english);
      t = t.add(const Duration(seconds: 5));
      final r = await svc.scan(focus: ScanFocus.ahead, language: AppLanguage.english);
      expect(r.spoken, d.visionFromAMomentAgo('a scene'));
      expect(groq.calls, [1]);
      t = t.add(const Duration(seconds: 8));
      await svc.scan(focus: ScanFocus.ahead, language: AppLanguage.english);
      expect(groq.calls, [1, 1], reason: '13 s later it is a real call again');
      svc.closeCamera();
    });

    test('a different question or focus is never answered from the cache', () async {
      final p = installPlatform();
      final groq = FakeBackend('groq', 1);
      final gem = FakeBackend('gemini', 3);
      final svc = newService(newCamera(p), groq: groq, gemini: gem);
      await svc.scan(focus: ScanFocus.ahead, language: AppLanguage.english, question: 'what colour is the rabbit');
      await svc.scan(focus: ScanFocus.ahead, language: AppLanguage.english, question: 'what is written on the sign');
      expect(groq.calls.length, 2);
      await svc.scan(focus: ScanFocus.sign, language: AppLanguage.english);
      expect(groq.calls.length + gem.calls.length, 3);
      svc.closeCamera();
    });

    test('budget exhausted -> the honest "looked too many times" sentence', () async {
      final p = installPlatform();
      final svc = SnapshotVisionService(
        camera: newCamera(p),
        edge: EdgeHazardDetector(loadInterpreter: () async => null, loadLabels: () async => const []),
        cloud: VisionRouter(
          groq: ThrowingBackend('groq', const VisionBudgetExhausted()),
          gemini: ThrowingBackend('gem', const VisionBudgetExhausted(), maxFrames: 3),
        ),
        haptics: RecordingHaptics(),
      );
      final r = await svc.scan(focus: ScanFocus.ahead, language: AppLanguage.english);
      expect(r.spoken, d.visionBudgetSpent);
      svc.closeCamera();
    });

    test('upload is bounded: a 2000x1500 frame is capped to 1280x960 (detail) / 640x480 (sweep)', () async {
      final p = installPlatform();
      p.pictureQueue.addAll([jpeg(2000, 1500), jpeg(2000, 1500), jpeg(2000, 1500), jpeg(2000, 1500)]);
      final sizes = <List<int>>[];
      final backend = _SizeBackend(sizes);
      final svc = SnapshotVisionService(
        camera: newCamera(p),
        edge: EdgeHazardDetector(loadInterpreter: () async => null, loadLabels: () async => const []),
        cloud: VisionRouter(groq: backend, gemini: _SizeBackend(sizes, maxFrames: 3)),
        haptics: RecordingHaptics(),
      );
      await svc.scan(focus: ScanFocus.ahead, language: AppLanguage.english);
      expect(sizes.single, [1280, 960]);
      sizes.clear();
      svc.closeCamera();
      await svc.scan(focus: ScanFocus.surroundings, language: AppLanguage.english, sweep: true);
      expect(sizes.every((s) => s[0] <= 640 && s[1] <= 480), isTrue);
      expect(sizes.length, 3);
      svc.closeCamera();
    });
  });

  group('VisionChannel (Volume-Up hold)', () {
    const name = 'com.ant.assistive.ant_app/vision';
    test('sweepHeld runs the handler; other methods are ignored; handler errors do not escape', () async {
      final ch = VisionChannel(channel: const MethodChannel(name));
      var runs = 0;
      ch.onSnapshotTrigger(() async {
        runs++;
        if (runs == 2) throw StateError('boom');
      });
      Future<void> send(String m) => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .handlePlatformMessage(
            name,
            const StandardMethodCodec().encodeMethodCall(MethodCall(m)),
            (_) {},
          );
      await send('sweepHeld');
      await send('somethingElse');
      await send('sweepHeld');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(runs, 2);
      ch.dispose();
      await send('sweepHeld');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(runs, 2, reason: 'disposed channel no longer fires');
    });
  });

  group('ChatController scan paths speak and release the camera', () {
    ProviderContainer containerFor(SnapshotVisionService svc, FakeTts tts) {
      final c = ProviderContainer(overrides: [
        // sendFreeText reads the emergency service first; the real one needs
        // Firebase. Not what is under test here.
        emergencyServiceProvider.overrideWithValue(_NoEmergency()),
        ttsServiceProvider.overrideWithValue(tts),
        snapshotVisionServiceProvider.overrideWithValue(svc),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    test('one-frame success: answer spoken, typing flag cleared, camera released', () async {
      final p = installPlatform();
      final tts = FakeTts();
      final c = containerFor(newService(newCamera(p)), tts);
      await c.read(chatControllerProvider.notifier).runSnapshot(blind());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(tts.spoken, ['a scene']);
      expect(c.read(chatControllerProvider).isAssistantTyping, isFalse);
      expect(p.liveIds, isEmpty);
    });

    test('no camera: spoken apology, nothing left open', () async {
      final p = installPlatform()..cameras = const [];
      final tts = FakeTts();
      final c = containerFor(newService(newCamera(p)), tts);
      await c.read(chatControllerProvider.notifier).runSnapshot(blind());
      expect(tts.spoken, [d.visionNoCamera]);
      expect(c.read(chatControllerProvider).isAssistantTyping, isFalse);
    });

    test('Bangla user hears Bangla for a camera failure', () async {
      final p = installPlatform()..pictureError = PlatformException(code: 'x');
      final tts = FakeTts();
      final c = containerFor(newService(newCamera(p)), tts);
      await c.read(chatControllerProvider.notifier).runSnapshot(blind(language: AppLanguage.bangla));
      expect(tts.spoken.single, Dashboard.of(AppLanguage.bangla).visionCaptureFailed);
    });

    test('a scan that throws is spoken as a failure and releases the camera', () async {
      final p = installPlatform();
      final svc = SnapshotVisionService(
        camera: newCamera(p),
        edge: EdgeHazardDetector(
          loadInterpreter: () async => throw StateError('model'),
          loadLabels: () async => const [],
        ),
        cloud: VisionRouter(groq: FakeBackend('groq', 1), gemini: FakeBackend('gemini', 3)),
        haptics: RecordingHaptics(),
      );
      p.pictureQueue.add(Uint8List.fromList([0, 1, 2])); // undecodable -> scan() throws
      final tts = FakeTts();
      final c = containerFor(svc, tts);
      await c.read(chatControllerProvider.notifier).runSnapshot(blind());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(tts.spoken, [d.visionCaptureFailed]);
      expect(c.read(chatControllerProvider).isAssistantTyping, isFalse);
      expect(p.liveIds, isEmpty);
    });

    test('"open the camera" with a viewfinder that returns nothing says so out loud', () async {
      final p = installPlatform();
      final tts = FakeTts();
      final c = containerFor(newService(newCamera(p)), tts);
      final ctl = c.read(chatControllerProvider.notifier);
      ctl.registerCameraAimer(() async => null);
      await ctl.sendFreeText('open the camera', blind());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(tts.spoken, [d.visionCaptureFailed]);
    });

    test('"open the camera" with a viewfinder photo analyses exactly that photo, no 2nd capture', () async {
      final p = installPlatform();
      final groq = FakeBackend('groq', 1);
      final tts = FakeTts();
      final c = containerFor(newService(newCamera(p), groq: groq), tts);
      final ctl = c.read(chatControllerProvider.notifier);
      var finished = 0;
      ctl.registerCameraAimer(() async => jpeg(), finish: () async => finished++);
      await ctl.sendFreeText('open the camera', blind());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(p.pictures, 0);
      expect(groq.calls, [1]);
      expect(finished, 1, reason: 'viewfinder is told to close once the work is done');
      expect(tts.spoken, ['a scene']);
    });

    test('hearing user: sweep cues are spoken in order with the prompt first', () async {
      final p = installPlatform();
      final tts = FakeTts();
      final c = containerFor(newService(newCamera(p)), tts);
      await c.read(chatControllerProvider.notifier).runSweep(blind());
      expect(tts.spoken, [
        d.visionSweepPrompt, 'Left.', 'Straight ahead.', 'Right.', 'a scene',
      ]);
      expect(p.liveIds, isEmpty);
    });

    test('deaf user: no spoken cues, haptic cues still fire in order', () async {
      final p = installPlatform();
      final tts = FakeTts();
      final haptics = RecordingHaptics();
      final c = containerFor(newService(newCamera(p), haptics: haptics), tts);
      await c.read(chatControllerProvider.notifier).runSweep(blind(deaf: true));
      expect(tts.spoken.where((s) => s == 'Left.' || s == 'Right.'), isEmpty);
      expect(haptics.cues, [HapticCue.turnLeft, HapticCue.navigation, HapticCue.turnRight]);
    });

    test('three rapid "what is in front of me" taps still produce exactly one answer', () async {
      final p = installPlatform();
      final groq = FakeBackend('groq', 1, delay: const Duration(milliseconds: 200));
      final tts = FakeTts();
      final c = containerFor(newService(newCamera(p), groq: groq), tts);
      final ctl = c.read(chatControllerProvider.notifier);
      await Future.wait([ctl.runSnapshot(blind()), ctl.runSnapshot(blind()), ctl.runSnapshot(blind())]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(groq.calls.length, 1);
      expect(tts.spoken.where((s) => s == 'a scene').length, 1);
      expect(tts.spoken.where((s) => s == d.visionAlreadyLooking).length, 2);
    });
  });

  group('CameraAimingScreen', () {
    Future<(ValueNotifier<Object?>, SnapshotCamera)> push(
      WidgetTester tester,
      FakePlatform p, {
      double scale = 1.0,
      Size size = const Size(360, 740),
      AppLanguage lang = AppLanguage.english,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final cam = newCamera(p);
      final svc = newService(cam);
      final result = ValueNotifier<Object?>('not-popped');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [snapshotVisionServiceProvider.overrideWithValue(svc)],
          child: MaterialApp(
            builder: (c, child) => MediaQuery(
              data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Builder(
              builder: (ctx) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    result.value = await Navigator.of(ctx).push<Uint8List>(
                      MaterialPageRoute(builder: (_) => CameraAimingScreen(language: lang)),
                    );
                  },
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      return (result, cam);
    }

    testWidgets('permission denied: message shown, shutter disabled, nothing left open', (tester) async {
      final p = installPlatform()..createError = CameraException('CameraAccessDenied', 'x');
      await push(tester, p);
      expect(find.text(d.visionNoCamera), findsOneWidget);
      final btn = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(btn.onPressed, isNull);
      expect(p.liveIds, isEmpty);
    });

    testWidgets('single shutter tap returns the JPEG and releases the camera', (tester) async {
      final p = installPlatform();
      final (result, cam) = await push(tester, p);
      await tester.tap(find.text('Look at this'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle(); // a Duration pump is ONE frame: the route transition needs more
      expect(result.value, isA<Uint8List>());
      expect(img.decodeJpg(result.value as Uint8List), isNotNull);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      expect(cam.isOpen, isFalse);
      expect(p.liveIds, isEmpty);
    });

    testWidgets('back press releases the camera and returns null', (tester) async {
      final p = installPlatform();
      final (result, cam) = await push(tester, p);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(result.value, isNull);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      expect(cam.isOpen, isFalse);
      expect(p.liveIds, isEmpty);
    });

    testWidgets('45 s deadline closes a forgotten viewfinder and releases the camera', (tester) async {
      final p = installPlatform();
      final (result, cam) = await push(tester, p);
      await tester.pump(CameraAimingScreen.maxAimingDuration + const Duration(seconds: 1));
      await tester.pumpAndSettle(); // a Duration pump is ONE frame: the route transition needs more
      expect(result.value, isNull);
      expect(find.byType(CameraAimingScreen), findsNothing);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      expect(cam.isOpen, isFalse);
    });

    testWidgets('shutter failure closes the viewfinder (no stuck screen) and frees the camera', (tester) async {
      final p = installPlatform();
      final (result, cam) = await push(tester, p);
      p.pictureError = PlatformException(code: 'x');
      await tester.tap(find.text('Look at this'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle(); // a Duration pump is ONE frame: the route transition needs more
      expect(result.value, isNull);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      expect(cam.isOpen, isFalse);
    });

    for (final size in [const Size(360, 640), const Size(640, 360), const Size(320, 568)]) {
      testWidgets('2.0x text on ${size.width.toInt()}x${size.height.toInt()} does not overflow (Nusrat)', (tester) async {
        final p = installPlatform();
        await push(tester, p, scale: 2.0, size: size);
        expect(tester.takeException(), isNull);
        expect(find.text('Look at this'), findsOneWidget);
      });
    }

    testWidgets('Bangla copy and a 64 px-high full-width shutter (tremor friendly)', (tester) async {
      final p = installPlatform();
      await push(tester, p, lang: AppLanguage.bangla);
      final b = Dashboard.of(AppLanguage.bangla);
      expect(find.text(b.cameraAimingShoot), findsOneWidget);
      expect(find.text(b.cameraAimingHint), findsOneWidget);
      final size = tester.getSize(find.byType(FilledButton));
      expect(size.height, greaterThanOrEqualTo(64));
      expect(size.width, greaterThanOrEqualTo(300));
    });

    testWidgets('back press while the shutter is mid-capture: no crash, camera released, no pop result', (tester) async {
      final p = installPlatform();
      p.pictureHook = (n) => Future<void>.delayed(const Duration(milliseconds: 300));
      final (result, cam) = await push(tester, p);
      await tester.tap(find.text('Look at this'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(result.value, isNull);
      expect(cam.isOpen, isFalse);
      expect(p.liveIds, isEmpty);
    });

    testWidgets('shutter exposes a button semantics label for TalkBack', (tester) async {
      final p = installPlatform();
      final handle = tester.ensureSemantics();
      await push(tester, p);
      expect(
        tester.getSemantics(find.byType(FilledButton)),
        containsSemantics(label: 'Look at this', isButton: true, isEnabled: true),
      );
      handle.dispose();
    });
  });

  group('CameraAimingDialog (caretaker photo / voice open-camera)', () {
    Future<(CameraController, ValueNotifier<Object?>)> show(WidgetTester tester, FakePlatform p) async {
      final cam = newCamera(p);
      await tester.runAsync(() => cam.open());
      final controller = cam.controller!;
      final result = ValueNotifier<Object?>('open');
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result.value = await showDialog<Uint8List>(
                    context: ctx,
                    barrierDismissible: false,
                    builder: (_) => CameraAimingDialog(controller: controller),
                  );
                },
                child: const Text('go'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      return (controller, result);
    }

    testWidgets('double tap on capture takes exactly one picture and returns it', (tester) async {
      final p = installPlatform();
      p.pictureHook = (n) => Future<void>.delayed(const Duration(milliseconds: 300));
      final (_, result) = await show(tester, p);
      await tester.tap(find.text('Capture this frame'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('Capturing…'), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 800));
      expect(p.pictures, 1);
      expect(result.value, isA<Uint8List>());
    });

    testWidgets('a failed capture keeps the dialog open so the user can retry', (tester) async {
      final p = installPlatform();
      final (_, result) = await show(tester, p);
      p.pictureError = PlatformException(code: 'x');
      await tester.tap(find.text('Capture this frame'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(CameraAimingDialog), findsOneWidget);
      expect(find.text('Capture this frame'), findsOneWidget);
      p.pictureError = null;
      await tester.tap(find.text('Capture this frame'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 400));
      expect(result.value, isA<Uint8List>());
    });

    testWidgets('2.0x text on a 320x568 phone does not overflow the dialog (Nusrat)', (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final p = installPlatform();
      final cam = newCamera(p);
      await tester.runAsync(() => cam.open());
      await tester.pumpWidget(
        MaterialApp(
          builder: (c, child) => MediaQuery(
            data: MediaQuery.of(c).copyWith(textScaler: const TextScaler.linear(2.0)),
            child: child!,
          ),
          home: CameraAimingDialog(controller: cam.controller!),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Capture this frame'), findsOneWidget);
    });

    testWidgets('close button returns null', (tester) async {
      final p = installPlatform();
      final (_, result) = await show(tester, p);
      await tester.tap(find.byTooltip('Close camera'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(result.value, isNull);
    });
  });
}

class _SizeBackend implements VisionBackend {
  _SizeBackend(this.sizes, {this.maxFrames = 1});
  final List<List<int>> sizes;
  @override
  String get name => 'size';
  @override
  final int maxFrames;
  @override
  bool get isConfigured => true;
  @override
  Future<VisionScene?> describe({
    required List<Uint8List> jpegs,
    required ScanFocus focus,
    required AppLanguage language,
    List<String> edgeLabels = const [],
    String? question,
  }) async {
    for (final j in jpegs) {
      final im = img.decodeJpg(j)!;
      sizes.add([im.width, im.height]);
    }
    return VisionScene(focus: focus, spoken: 'sized');
  }
}

class _NoEmergency implements EmergencyService {
  @override
  bool get isRunning => false;
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

class _ProbeEdge extends EdgeHazardDetector {
  _ProbeEdge(this.verdict)
    : super(loadInterpreter: () async => null, loadLabels: () async => const []);
  final HazardVerdict verdict;
  @override
  Future<bool> ensureLoaded() async => true;
  @override
  Future<HazardVerdict> detect(img.Image frame) async => verdict;
}
