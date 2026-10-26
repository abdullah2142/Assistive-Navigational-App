import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';
import 'package:ant_app/core/services/haptics_service.dart';
import 'package:ant_app/core/services/vision/bus_route_directory.dart';
import 'package:ant_app/core/services/vision/cloud_vision_service.dart'
    show VisionBudgetExhausted;
import 'package:ant_app/core/services/vision/edge_hazard_detector.dart';
import 'package:ant_app/core/services/vision/snapshot_camera.dart';
import 'package:ant_app/core/services/vision/snapshot_vision_service.dart';
import 'package:ant_app/core/services/vision/vision_backend.dart';
import 'package:ant_app/core/services/vision/vision_router.dart';
import 'package:ant_app/core/services/vision/vision_scene.dart';
import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

/// image_pipeline regression probes: behaviours verified to WORK today.
/// Offline and deterministic: fake camera, fake TFLite interpreter, fake
/// cloud backends. Defects found in the same area live in
/// probe_bugs/image_pipeline_bugs_test.dart.

// ------------------------------------------------------------------ fakes

class FakeBackend implements VisionBackend {
  FakeBackend(
    this.name, {
    this.maxFrames = 1,
    this.say = 'ok',
    this.fail = false,
    this.throwBudget = false,
    this.throwError = false,
  });
  @override
  final String name;
  @override
  final int maxFrames;
  final String say;
  final bool fail;
  final bool throwBudget;
  final bool throwError;
  @override
  bool get isConfigured => true;
  final List<List<Uint8List>> calls = [];
  @override
  Future<VisionScene?> describe({
    required List<Uint8List> jpegs,
    required ScanFocus focus,
    required AppLanguage language,
    List<String> edgeLabels = const [],
    String? question,
  }) async {
    calls.add(jpegs);
    if (throwBudget) throw const VisionBudgetExhausted();
    if (throwError) throw StateError('backend exploded');
    if (fail) return null;
    return VisionScene(focus: focus, spoken: say, capturedAt: DateTime.now());
  }
}

/// Stands in for the native TFLite interpreter. `implements` is enough
/// because `Interpreter`'s only constructor is private and these tests never
/// touch the native library.
class FakeInterpreter implements Interpreter {
  FakeInterpreter({this.detectionsPerRun = const [], this.throwOnRun = false});
  final List<List<FakeDet>> detectionsPerRun;
  final bool throwOnRun;
  final List<Uint8List> inputs = [];
  int runs = 0;

  @override
  void runForMultipleInputs(List<Object> inputs, Map<int, Object> outputs) {
    if (throwOnRun) throw StateError('tflite exploded');
    this.inputs.add(inputs.first as Uint8List);
    final dets = runs < detectionsPerRun.length
        ? detectionsPerRun[runs]
        : const <FakeDet>[];
    runs++;
    final boxes = outputs[0] as List;
    final classes = outputs[1] as List;
    final scores = outputs[2] as List;
    final count = outputs[3] as List;
    for (var i = 0; i < dets.length; i++) {
      (boxes[0] as List)[i] = [
        dets[i].top,
        dets[i].left,
        dets[i].bottom,
        dets[i].right,
      ];
      (classes[0] as List)[i] = dets[i].classIndex.toDouble();
      (scores[0] as List)[i] = dets[i].score;
    }
    count[0] = dets.length.toDouble();
  }

  @override
  void close() {}
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class FakeDet {
  const FakeDet(
    this.classIndex,
    this.score,
    this.top,
    this.left,
    this.bottom,
    this.right,
  );
  final int classIndex;
  final double score;
  final double top, left, bottom, right;
}

const cocoLabels = [
  '???',
  'person',
  'bicycle',
  'car',
  'motorcycle',
  'airplane',
  'bus',
];
const busFillingFrame = FakeDet(6, 0.9, 0.25, 0.2, 0.95, 0.8);

class FakeController extends CameraController {
  FakeController(this.queue, {this.dir})
    : super(
        const CameraDescription(
          name: 'fake',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.high,
        enableAudio: false,
      );
  final List<Object> queue; // Uint8List or Exception
  final Directory? dir; // when set, pictures are real files like the plugin's
  final List<File> files = [];
  @override
  Future<void> initialize() async {
    value = value.copyWith(isInitialized: true);
  }

  @override
  Future<void> setFocusMode(FocusMode mode) async {}
  @override
  Future<void> setFlashMode(FlashMode mode) async {}
  @override
  Future<XFile> takePicture() async {
    final next = queue.removeAt(0);
    if (next is Exception) throw next;
    final bytes = next as Uint8List;
    if (dir == null) return XFile.fromData(bytes);
    final f = File('${dir!.path}/CAP${files.length}.jpg')
      ..writeAsBytesSync(bytes);
    files.add(f);
    return XFile(f.path);
  }

  @override
  Future<void> dispose() async {}
}

const fakeCamera = CameraDescription(
  name: 'fake',
  lensDirection: CameraLensDirection.back,
  sensorOrientation: 90,
);

SnapshotCamera buildCamera(
  List<Object> frames, {
  Directory? dir,
  FakeController? holder,
}) => SnapshotCamera(
  listCameras: () async => const [fakeCamera],
  buildController: (_) => FakeController(List.of(frames), dir: dir),
);

Uint8List jpegOf(img.Image im, {int quality = 90}) =>
    Uint8List.fromList(img.encodeJpg(im, quality: quality));

img.Image solid(int w, int h, int r, int g, int b) {
  final im = img.Image(width: w, height: h);
  img.fill(im, color: img.ColorRgb8(r, g, b));
  return im;
}

/// A scene-like frame with real high-frequency content: a checkerboard.
img.Image checker(int w, int h, int cell) {
  final im = img.Image(width: w, height: h);
  for (final p in im) {
    final v = ((p.x ~/ cell) + (p.y ~/ cell)) % 2 == 0 ? 255 : 0;
    p
      ..r = v
      ..g = v
      ..b = v;
  }
  return im;
}

/// Cheap photo stand-in with real edges (solid ground, blocks and a diagonal).
img.Image gradient(int w, int h) {
  final im = solid(w, h, 120, 140, 160);
  img.fillRect(im, x1: w ~/ 8, y1: h ~/ 8, x2: w ~/ 2, y2: h ~/ 2, color: img.ColorRgb8(200, 60, 40));
  img.fillRect(im, x1: w ~/ 2, y1: h ~/ 2, x2: w * 7 ~/ 8, y2: h * 7 ~/ 8, color: img.ColorRgb8(30, 90, 200));
  img.drawLine(im, x1: 0, y1: 0, x2: w - 1, y2: h - 1, color: img.ColorRgb8(255, 255, 255), thickness: 3);
  return im;
}

SnapshotVisionService build({
  required List<VisionBackend?> backends, // [groq, gemini?]
  List<Object> frames = const [],
  FakeInterpreter? interp,
  DateTime Function()? now,
  Directory? dir,
}) {
  final router = VisionRouter(
    groq: backends[0],
    gemini: backends.length > 1 ? backends[1] : null,
  );
  return SnapshotVisionService(
    camera: buildCamera(frames, dir: dir),
    edge: EdgeHazardDetector(
      loadInterpreter: () async => interp,
      loadLabels: () async => cocoLabels,
    ),
    cloud: router,
    haptics: HapticsService(probeOverride: (motor: false, amplitude: false)),
    routes: BusRouteDirectory(seed: const []),
    now: now,
  );
}

Future<ScanResult> scanBytes(
  SnapshotVisionService svc,
  Uint8List bytes, {
  ScanFocus focus = ScanFocus.ahead,
  String? question,
}) => svc.scan(
  focus: focus,
  language: AppLanguage.english,
  capturedJpeg: bytes,
  question: question,
);

img.Image decodeOut(ScanResult r) => img.decodeJpg(r.frameJpeg!)!;

double meanR(Uint8List jpg) {
  final im = img.decodeJpg(jpg)!;
  var s = 0.0;
  for (final p in im) {
    s += p.r;
  }
  return s / (im.width * im.height);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ============================================================ upload sizing
  group('upload encode: letterbox / downscale maths', () {
    Future<img.Image> uploaded(
      int w,
      int h,
      ScanFocus focus, {
      img.Image? src,
    }) async {
      final svc = build(backends: [FakeBackend('groq')]);
      final r = await scanBytes(
        svc,
        jpegOf(src ?? gradient(w, h)),
        focus: focus,
      );
      return decodeOut(r);
    }

    test('detail focus (ahead) caps a 4:3 frame at 1280x960', () async {
      final o = await uploaded(2560, 1920, ScanFocus.ahead);
      expect((o.width, o.height), (1280, 960));
    });

    test('broad focus (surroundings) caps at 640x480', () async {
      final o = await uploaded(2560, 1920, ScanFocus.surroundings);
      expect((o.width, o.height), (640, 480));
    });

    test('sign focus also gets the 1280x960 cap', () async {
      final o = await uploaded(2000, 1500, ScanFocus.sign);
      expect((o.width, o.height), (1280, 960));
    });

    test('never upscales a small frame, for any cap', () async {
      for (final focus in [
        ScanFocus.ahead,
        ScanFocus.surroundings,
        ScanFocus.hazard,
      ]) {
        final o = await uploaded(320, 240, focus);
        expect((o.width, o.height), (320, 240), reason: focus.name);
      }
    });

    test('frame exactly on the cap is untouched; one pixel over is brought inside it', () async {
      final exact = await uploaded(1280, 960, ScanFocus.ahead);
      expect((exact.width, exact.height), (1280, 960));
      final over = await uploaded(1281, 961, ScanFocus.ahead);
      expect(over.width, lessThanOrEqualTo(1280));
      expect(over.height, lessThanOrEqualTo(960));
      expect(over.width, greaterThanOrEqualTo(1279));
      final over2 = await uploaded(641, 481, ScanFocus.surroundings);
      expect(over2.width, lessThanOrEqualTo(640));
      expect(over2.height, lessThanOrEqualTo(480));
    });

    test('aspect ratio is preserved within one pixel for 16:9, portrait and odd sizes', () async {
      for (final (w, h) in [
        (1920, 1080),
        (1080, 1920),
        (1001, 751),
        (1999, 1333),
        (4000, 1000),
      ]) {
        final o = await uploaded(w, h, ScanFocus.ahead);
        final expectedH = o.width * h / w;
        expect(
          (o.height - expectedH).abs(),
          lessThan(1.5),
          reason: '${w}x$h -> ${o.width}x${o.height}',
        );
        expect(o.width, lessThanOrEqualTo(1280));
        expect(o.height, lessThanOrEqualTo(960));
      }
    });

    test('degenerate shapes 1x1, 1x10000 and 10000x1 produce a decodable upload inside the cap', () async {
      for (final (w, h) in [(1, 1), (1, 10000), (10000, 1)]) {
        final o = await uploaded(
          w,
          h,
          ScanFocus.ahead,
          src: solid(w, h, 90, 120, 150),
        );
        expect(o.width, greaterThanOrEqualTo(1));
        expect(o.height, greaterThanOrEqualTo(1));
        expect(o.width, lessThanOrEqualTo(1280));
        expect(o.height, lessThanOrEqualTo(960));
      }
    });

    test(
      'upload re-decodes and is much smaller than the raw pixels (quality 86)',
      () async {
        final svc = build(backends: [FakeBackend('groq')]);
        final r = await scanBytes(svc, jpegOf(gradient(1280, 960)));
        expect(r.frameJpeg!.length, lessThan(1280 * 960 * 3 ~/ 4));
        expect(r.frameJpeg!.length, greaterThan(200));
        expect(img.decodeJpg(r.frameJpeg!), isNotNull);
      },
    );

    test(
      'the frame returned to the caller is exactly the bytes sent to the cloud',
      () async {
        final groq = FakeBackend('groq');
        final svc = build(backends: [groq]);
        final r = await scanBytes(svc, jpegOf(gradient(900, 600)));
        expect(r.frameJpeg, orderedEquals(groq.calls.single.single));
      },
    );

    test(
      'bytes with trailing garbage after the JPEG end marker still decode',
      () async {
        final good = jpegOf(gradient(200, 150));
        final svc = build(backends: [FakeBackend('groq')]);
        final r = await scanBytes(
          svc,
          Uint8List.fromList([...good, ...List.filled(500, 7)]),
        );
        expect(r.frameJpeg, isNotNull);
      },
    );
  });

  // ============================================================ formats
  group('JPEG variants and EXIF orientation', () {
    test(
      'EXIF orientations 1..8 all come out upright (w/h swapped for 5..8)',
      () async {
        for (var o = 1; o <= 8; o++) {
          final im = img.Image(width: 64, height: 32);
          img.fill(im, color: img.ColorRgb8(0, 0, 255));
          img.fillRect(
            im,
            x1: 0,
            y1: 0,
            x2: 31,
            y2: 31,
            color: img.ColorRgb8(255, 0, 0),
          );
          im.exif.imageIfd.orientation = o;
          final svc = build(backends: [FakeBackend('groq')]);
          final r = await scanBytes(svc, jpegOf(im, quality: 95));
          final out = decodeOut(r);
          final portrait = o >= 5;
          expect(out.width, portrait ? 32 : 64, reason: 'orientation $o');
          expect(out.height, portrait ? 64 : 32, reason: 'orientation $o');
        }
      },
    );

    test('an EXIF-rotated phone portrait reaches the SSD letterbox upright and pillarboxed', () async {
      final im = img.Image(width: 64, height: 32); // sensor-landscape
      img.fill(im, color: img.ColorRgb8(255, 0, 0));
      im.exif.imageIfd.orientation = 6;
      final interp = FakeInterpreter();
      final svc = build(backends: [FakeBackend('groq')], interp: interp);
      await scanBytes(svc, jpegOf(im, quality: 95));
      final t = interp.inputs.single;
      int r(int x, int y) => t[(y * 300 + x) * 3];
      // upright 32x64 -> 150x300 centred: columns 75..224 hold content
      expect(r(10, 150), 128, reason: 'left bar is grey');
      expect(r(290, 150), 128, reason: 'right bar is grey');
      expect(r(150, 5), greaterThan(200), reason: 'content reaches the top');
      expect(
        r(150, 295),
        greaterThan(200),
        reason: 'content reaches the bottom',
      );
    });

    test('progressive, grayscale and CMYK JPEGs decode and upload as 3-channel images', () async {
      for (final (name, b64) in [
        (
          'progressive',
          '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBT/wgARCAAgAEADASIAAhEBAxEB/8QAFgABAQEAAAAAAAAAAAAAAAAAAAYH/8QAFgEBAQEAAAAAAAAAAAAAAAAAAAgG/9oADAMBAAIQAxAAAAHORhapAgRccdAXwhyxQIEXHHQH/8QAFBABAAAAAAAAAAAAAAAAAAAAUP/aAAgBAQABBQID/8QAFBEBAAAAAAAAAAAAAAAAAAAAMP/aAAgBAwEBPwEP/8QAFBEBAAAAAAAAAAAAAAAAAAAAMP/aAAgBAgEBPwEP/8QAFBABAAAAAAAAAAAAAAAAAAAAUP/aAAgBAQAGPwID/8QAFBABAAAAAAAAAAAAAAAAAAAAUP/aAAgBAQABPyED/9oADAMBAAIAAwAAABD/APCC/wDwgv/EABQRAQAAAAAAAAAAAAAAAAAAADD/2gAIAQMBAT8QD//EABQRAQAAAAAAAAAAAAAAAAAAADD/2gAIAQIBAT8QD//EABQQAQAAAAAAAAAAAAAAAAAAAFD/2gAIAQEAAT8QA//Z',
        ),
        (
          'gray',
          '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/wAALCAAgAEABAREA/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/9oACAEBAAA/APnSiiivAqKKK99ooorwKiiivfaKKK8Cooor32iiivAqKKK//9k=',
        ),
        (
          'cmyk',
          '/9j/7gAOQWRvYmUAZAAAAAAA/9sAQwADAgIDAgIDAwMDBAMDBAUIBQUEBAUKBwcGCAwKDAwLCgsLDQ4SEA0OEQ4LCxAWEBETFBUVFQwPFxgWFBgSFBUU/8AAFAgAIABABEMRAE0RAFkRAEsRAP/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKC//EALUQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+v/aAA4EQwBNAFkASwAAPwD9U6/Kqvyqr9U6KKKKKKKKKKKK/lXor+qiiiiiiiiiiiiiiv6qKK/lXooooooooooooor+Veiv6qKKKKKKKKKKKKKK/qoor+Veiiiiiiiiiiiiiv5V6K/qoooooooooooooor+qiiv5V6KKKKKKKKKKKKK/lXor+qiiiiiiiiiiiiiiv/Z',
        ),
      ]) {
        final interp = FakeInterpreter();
        final svc = build(backends: [FakeBackend('groq')], interp: interp);
        final r = await scanBytes(svc, base64Decode(b64));
        final o = decodeOut(r);
        expect((o.width, o.height), (64, 32), reason: name);
        expect(interp.inputs.single.length, 300 * 300 * 3, reason: name);
        // gray must not turn into a red/blue tinted tensor: r==g==b everywhere
        if (name == 'gray') {
          final t = interp.inputs.single;
          for (var i = 0; i < t.length; i += 3 * 997) {
            expect(t[i], t[i + 1]);
            expect(t[i + 1], t[i + 2]);
          }
        }
      }
    });
  });

  // ============================================================ SSD input tensor
  group('EdgeHazardDetector input tensor (letterbox)', () {
    int px(Uint8List t, int x, int y, int c) => t[(y * 300 + x) * 3 + c];

    Future<Uint8List> tensorFor(img.Image frame) async {
      final interp = FakeInterpreter();
      final svc = build(backends: [FakeBackend('groq')], interp: interp);
      await scanBytes(svc, jpegOf(frame, quality: 95));
      expect(interp.inputs, hasLength(1));
      return interp.inputs.single;
    }

    test('landscape 4:3 is letterboxed, not stretched: 300x225 content, grey (128) bars, not black', () async {
      final t = await tensorFor(solid(640, 480, 255, 0, 0));
      expect(t.length, 300 * 300 * 3);
      // (300-225)~/2 = 37 -> content rows 37..261
      for (final y in [0, 10, 36, 262, 280, 299]) {
        expect(
          [px(t, 150, y, 0), px(t, 150, y, 1), px(t, 150, y, 2)],
          [128, 128, 128],
          reason: 'bar row $y',
        );
      }
      for (final y in [38, 150, 260]) {
        expect(px(t, 150, y, 0), greaterThan(240), reason: 'content row $y');
        expect(px(t, 150, y, 1), lessThan(15));
      }
      for (final x in [0, 150, 299]) {
        expect(
          px(t, x, 150, 0),
          greaterThan(240),
          reason: 'full width used, col $x',
        );
      }
    });

    test('portrait is pillarboxed and a square fills the tensor', () async {
      final p = await tensorFor(solid(480, 640, 0, 255, 0));
      expect(px(p, 5, 150, 0), 128);
      expect(px(p, 294, 150, 0), 128);
      expect(px(p, 150, 150, 1), greaterThan(240));
      final s = await tensorFor(solid(500, 500, 0, 0, 255));
      expect(px(s, 0, 0, 2), greaterThan(240));
      expect(px(s, 299, 299, 2), greaterThan(240));
    });

    test('odd and extreme sizes still produce a full-length tensor (301x300, 1x1, 1x10000, 10000x1)', () async {
      for (final (w, h) in [(301, 300), (1, 1), (1, 10000), (10000, 1)]) {
        final t = await tensorFor(solid(w, h, 200, 100, 50));
        expect(t.length, 300 * 300 * 3, reason: '${w}x$h');
      }
    });

    test('a tiny frame is enlarged to the model input (the model needs 300px), the cloud upload is not', () async {
      final interp = FakeInterpreter();
      final groq = FakeBackend('groq');
      final svc = build(backends: [groq], interp: interp);
      final r = await scanBytes(svc, jpegOf(solid(30, 30, 255, 0, 0)));
      expect(px(interp.inputs.single, 0, 0, 0), greaterThan(240));
      expect(decodeOut(r).width, 30);
    });
  });

  // ============================================================ hazard abort / detector faults
  group('edge detector decisions and faults', () {
    test('an imminent bus aborts before any upload with a buzz, a spoken sentence and no frame', () async {
      final groq = FakeBackend('groq');
      final interp = FakeInterpreter(
        detectionsPerRun: [
          [busFillingFrame],
        ],
      );
      final svc = build(backends: [groq], interp: interp);
      final r = await scanBytes(svc, jpegOf(gradient(640, 480)));
      expect(r.abortedForHazard, isTrue);
      expect(groq.calls, isEmpty);
      expect(r.spoken.trim(), isNotEmpty);
      expect(r.verdict.isImminent, isTrue);
    });

    test(
      'a far-away small bus does not abort; the scan goes on to the cloud',
      () async {
        final groq = FakeBackend('groq');
        final interp = FakeInterpreter(
          detectionsPerRun: [
            [const FakeDet(6, 0.9, 0.44, 0.46, 0.52, 0.54)],
          ],
        );
        final svc = build(backends: [groq], interp: interp);
        final r = await scanBytes(svc, jpegOf(gradient(640, 480)));
        expect(r.abortedForHazard, isFalse);
        expect(groq.calls, hasLength(1));
      },
    );

    test('a hazard visible in only the last of three sweep frames still aborts the sweep', () async {
      final f = jpegOf(gradient(320, 240));
      final gemini = FakeBackend('gemini', maxFrames: 3);
      final interp = FakeInterpreter(
        detectionsPerRun: [
          [],
          [],
          [busFillingFrame],
        ],
      );
      final svc = build(
        backends: [FakeBackend('groq'), gemini],
        frames: [f, f, f],
        interp: interp,
      );
      final r = await svc.scan(
        focus: ScanFocus.surroundings,
        language: AppLanguage.english,
        sweep: true,
      );
      expect(interp.runs, 3, reason: 'every sweep frame gets the local check');
      expect(r.abortedForHazard, isTrue);
      expect(gemini.calls, isEmpty);
    });

    test('a throwing interpreter does not take the scan down; the cloud still answers', () async {
      final groq = FakeBackend('groq', say: 'A bus.');
      final svc = build(
        backends: [groq],
        interp: FakeInterpreter(throwOnRun: true),
      );
      final r = await scanBytes(svc, jpegOf(gradient(320, 240)));
      expect(r.spoken, 'A bus.');
    });

    test(
      'a missing model file (interpreter null) leaves the cloud path working',
      () async {
        final groq = FakeBackend('groq', say: 'Footpath.');
        final svc = build(backends: [groq], interp: null);
        final r = await scanBytes(svc, jpegOf(gradient(320, 240)));
        expect(r.spoken, 'Footpath.');
      },
    );
  });

  // ============================================================ sweep
  group('three-frame sweep', () {
    Future<ScanResult> sweep(SnapshotVisionService s) => s.scan(
      focus: ScanFocus.surroundings,
      language: AppLanguage.english,
      sweep: true,
    );

    test('left / centre / right order is preserved all the way to Gemini, each frame inside 640x480', () async {
      final f = [
        jpegOf(solid(1280, 720, 40, 40, 40)),
        jpegOf(solid(1280, 720, 120, 40, 40)),
        jpegOf(solid(1280, 720, 220, 40, 40)),
      ];
      final gemini = FakeBackend('gemini', maxFrames: 3);
      final groq = FakeBackend('groq');
      await sweep(build(backends: [groq, gemini], frames: f));
      expect(groq.calls, isEmpty);
      final sent = gemini.calls.single;
      final means = sent.map(meanR).toList();
      expect(means[0], lessThan(means[1]));
      expect(means[1], lessThan(means[2]));
      for (final j in sent) {
        final o = img.decodeJpg(j)!;
        expect(o.width, lessThanOrEqualTo(640));
        expect(o.height, lessThanOrEqualTo(480));
        expect(o.width * 9, o.height * 16, reason: '16:9 preserved');
      }
    });

    test('Gemini failing hands Qwen only the sharpest frame, wherever it sits in the sweep', () async {
      for (final sharpIndex in [0, 1, 2]) {
        final blurred = img.gaussianBlur(checker(320, 240, 4), radius: 3);
        final frames = [
          for (var i = 0; i < 3; i++)
            jpegOf(
              i == sharpIndex ? checker(320, 240, 4) : img.Image.from(blurred),
              quality: 95,
            ),
        ];
        final gemini = FakeBackend('gemini', maxFrames: 3, fail: true);
        final groq = FakeBackend('groq');
        final r = await sweep(build(backends: [groq, gemini], frames: frames));
        final got = groq.calls.single.single;
        expect(
          SnapshotVisionService.sharpness(img.decodeJpg(got)!),
          greaterThan(
            SnapshotVisionService.sharpness(
              img.decodeJpg(frames[(sharpIndex + 1) % 3])!,
            ),
          ),
          reason: 'sharp frame at index $sharpIndex',
        );
        expect(
          r.frameJpeg,
          orderedEquals(got),
          reason: 'caller is shown the frame that was used',
        );
      }
    });

    test(
      'one takePicture failure in the middle leaves two frames, no crash',
      () async {
        final f = jpegOf(solid(320, 240, 200, 20, 20));
        final gemini = FakeBackend('gemini', maxFrames: 3);
        final r = await sweep(
          build(
            backends: [FakeBackend('groq'), gemini],
            frames: [f, Exception('shutter'), f],
          ),
        );
        expect(gemini.calls.single, hasLength(2));
        expect(r.spoken, 'ok');
      },
    );

    test('identical, all-black and single-frame sweeps never crash and pick a frame deterministically', () async {
      final f = jpegOf(solid(320, 240, 77, 77, 77));
      final black = jpegOf(solid(320, 240, 0, 0, 0));
      // An all-black sweep is now answered "the camera view is dark" before
      // any upload, so it is checked on its own below.
      for (final frames in [
        [f, f, f],
        [f],
      ]) {
        final gemini = FakeBackend('gemini', maxFrames: 3, fail: true);
        final groq = FakeBackend('groq');
        final r = await sweep(build(backends: [groq, gemini], frames: frames));
        expect(groq.calls.single, hasLength(1));
        expect(r.frameJpeg, isNotNull);
      }
      final dark = await sweep(
        build(backends: [FakeBackend('groq'), FakeBackend('gemini', maxFrames: 3)], frames: [black, black, black]),
      );
      expect(dark.spoken, Dashboard.of(AppLanguage.english).visionTooDark);
    });

    test('all shots failing speaks the capture-failed sentence; no camera speaks the no-camera one', () async {
      final d = Dashboard.of(AppLanguage.english);
      final r = await sweep(
        build(
          backends: [FakeBackend('groq'), FakeBackend('gemini', maxFrames: 3)],
          frames: [Exception('a'), Exception('b'), Exception('c')],
        ),
      );
      expect(r.spoken, d.visionCaptureFailed);

      final noCam = SnapshotVisionService(
        camera: SnapshotCamera(listCameras: () async => const []),
        edge: EdgeHazardDetector(
          loadInterpreter: () async => null,
          loadLabels: () async => cocoLabels,
        ),
        cloud: VisionRouter(groq: FakeBackend('groq')),
        haptics: HapticsService(
          probeOverride: (motor: false, amplitude: false),
        ),
        routes: BusRouteDirectory(seed: const []),
      );
      final r2 = await noCam.scan(
        focus: ScanFocus.ahead,
        language: AppLanguage.english,
      );
      expect(r2.spoken, d.visionNoCamera);
    });
  });

  // ============================================================ round 2: real photographs
  // Photos fetched from the Wikimedia Commons API (see the task notes); the
  // group is skipped, not failed, on a machine that does not have them.
  group('real photographs through the pure-Dart pipeline', () {
    const dirPath =
        '/tmp/claude-1000/-home-abdullah-Downloads-Assistive-Navigational-App/'
        'd33bbf06-697d-4fbd-a8c7-e9bdc0de5987/scratchpad/pipeline_images';
    final dir = Directory(dirPath);
    final have = dir.existsSync();
    // 16 MP and 33 MP originals are measured by hand (several seconds each in
    // the JIT) rather than in the suite.
    final names = [
      'dhaka_street',
      'dhaka_bus',
      'dhaka_night',
      'dark_alley',
      'backlit',
      'motion_blur',
      'tilted',
      'tiny',
    ];

    double lumaOf(img.Image im, {bool top = true}) {
      var s = 0.0;
      var n = 0;
      final y0 = top ? 0 : im.height ~/ 2;
      final y1 = top ? im.height ~/ 2 : im.height;
      for (var y = y0; y < y1; y += 2) {
        for (var x = 0; x < im.width; x += 2) {
          final p = im.getPixel(x, y);
          s += 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
          n++;
        }
      }
      return s / n;
    }

    for (final name in names) {
      test('$name.jpg: decodes, stays inside both caps, keeps colour and orientation', () async {
        final src = File('$dirPath/$name.jpg').readAsBytesSync();
        final srcIm = img.decodeJpg(src)!;
        for (final focus in [ScanFocus.ahead, ScanFocus.surroundings]) {
          final interp = FakeInterpreter();
          final svc = build(backends: [FakeBackend('groq')], interp: interp);
          final r = await scanBytes(svc, src, focus: focus);
          final out = decodeOut(r);
          final capW = focus == ScanFocus.ahead ? 1280 : 640;
          final capH = focus == ScanFocus.ahead ? 960 : 480;
          expect(out.width, lessThanOrEqualTo(capW), reason: '$name $focus');
          expect(out.height, lessThanOrEqualTo(capH), reason: '$name $focus');
          if (srcIm.width <= capW && srcIm.height <= capH) {
            expect((out.width, out.height), (srcIm.width, srcIm.height),
                reason: 'never upscaled / never shrunk when it fits');
          }
          expect(
            (out.height - out.width * srcIm.height / srcIm.width).abs(),
            lessThan(1.5),
            reason: '$name aspect ratio',
          );
          expect(r.frameJpeg!.length, lessThanOrEqualTo(700 * 1024),
              reason: '$name stays inside the 700 KB photo-share limit');
          // Channel order / orientation sanity: mean luma of the top and
          // bottom halves must match the source within a few levels.
          expect((lumaOf(out) - lumaOf(srcIm)).abs(), lessThan(8), reason: '$name top half');
          expect((lumaOf(out, top: false) - lumaOf(srcIm, top: false)).abs(), lessThan(8),
              reason: '$name bottom half (no vertical flip)');
          expect(meanR(r.frameJpeg!), closeTo(
              () {
                var s = 0.0;
                for (final p in srcIm) {
                  s += p.r;
                }
                return s / (srcIm.width * srcIm.height);
              }(), 8), reason: '$name red channel (no R/B swap)');
          expect(interp.inputs.single.length, 300 * 300 * 3);
        }
      }, skip: have ? false : 'sample photos not present on this machine');
    }

    test('a 7 MP panorama (3840x1920) is brought inside the cap with its 2:1 shape', () async {
      final src = File('$dirPath/panorama.jpg').readAsBytesSync();
      final svc = build(backends: [FakeBackend('groq')]);
      final out = decodeOut(await scanBytes(svc, src));
      expect((out.width, out.height), (1280, 640));
    }, skip: have ? false : 'sample photos not present on this machine',
        timeout: const Timeout(Duration(seconds: 90)));

    test('a real sweep of three different photos reaches Gemini in order, each inside 640x480', () async {
      final order = ['dhaka_night', 'dhaka_street', 'dhaka_bus'];
      final frames = [for (final n in order) File('$dirPath/$n.jpg').readAsBytesSync()];
      final gemini = FakeBackend('gemini', maxFrames: 3);
      final svc = build(backends: [FakeBackend('groq'), gemini], frames: frames);
      await svc.scan(
        focus: ScanFocus.surroundings,
        language: AppLanguage.english,
        sweep: true,
      );
      final sent = gemini.calls.single.map((j) => img.decodeJpg(j)!).toList();
      expect(sent.map((i) => i.height).toList(), [480, 365, 480],
          reason: '4:3, 16:9.6 and 4:3 sources keep their own shapes, in capture order');
      // night (dark) < street (bright) mean luma, in that order => not reordered
      expect(lumaOf(sent[0]), lessThan(lumaOf(sent[1])));
    }, skip: have ? false : 'sample photos not present on this machine');
  });

  // ============================================================ round 2: synthetic guards
  group('sharpness measure and dark-but-valid scenes', () {
    test('sharpness ranks sharp > mild blur > heavy blur > solid, and tiny frames never crash', () {
      final sharp = SnapshotVisionService.sharpness(checker(640, 480, 8));
      final mild = SnapshotVisionService.sharpness(
        img.gaussianBlur(checker(640, 480, 8), radius: 2),
      );
      final heavy = SnapshotVisionService.sharpness(
        img.gaussianBlur(checker(640, 480, 8), radius: 8),
      );
      final flat = SnapshotVisionService.sharpness(solid(640, 480, 90, 90, 90));
      expect(sharp, greaterThan(mild));
      expect(mild, greaterThan(heavy));
      expect(heavy, greaterThan(flat));
      expect(flat, 0);
      for (final (w, h) in [(1, 1), (2, 2), (3, 3), (5000, 3)]) {
        final s = SnapshotVisionService.sharpness(solid(w, h, 10, 20, 30));
        expect(s.isFinite, isTrue, reason: '${w}x$h');
        expect(s, 0);
      }
    });

    test('a dim but textured night scene (mean luma ~25) is still uploaded and described', () async {
      // Guards the future "covered lens" gate: a real night street is dark but
      // is not a black frame, and must not be refused.
      final night = gradient(640, 480);
      for (final p in night) {
        p
          ..r = p.r * 0.12
          ..g = p.g * 0.12
          ..b = p.b * 0.12;
      }
      final groq = FakeBackend('groq', say: 'A dim street.');
      final r = await scanBytes(build(backends: [groq]), jpegOf(night));
      expect(groq.calls, hasLength(1));
      expect(r.spoken, 'A dim street.');
    });

    test('every upload is a plain baseline-readable JPEG: SOI first, EOI last, no EXIF block', () async {
      final im = gradient(400, 300);
      im.exif.imageIfd.orientation = 6;
      final r = await scanBytes(build(backends: [FakeBackend('groq')]), jpegOf(im));
      final b = r.frameJpeg!;
      expect(b.sublist(0, 2), [0xFF, 0xD8]);
      expect(b.sublist(b.length - 2), [0xFF, 0xD9]);
      // an APP1 "Exif" marker would make the cloud rotate the already-upright pixels a second time
      final head = String.fromCharCodes(b.sublist(0, 64));
      expect(head.contains('Exif'), isFalse);
    });
  });

  // ============================================================ cloud-side behaviour
  group('cooldown cache, failures and offline wording', () {
    test('a repeat of the same question inside the cooldown is answered from cache, marked as old, with no second call', () async {
      var t = DateTime(2026, 1, 1, 12);
      final groq = FakeBackend('groq', say: 'A rickshaw.');
      final svc = build(backends: [groq], now: () => t);
      await scanBytes(
        svc,
        jpegOf(gradient(200, 150)),
        question: 'what is this',
      );
      t = t.add(const Duration(seconds: 3));
      final r = await scanBytes(
        svc,
        jpegOf(gradient(200, 150)),
        question: '  What is THIS ',
      );
      expect(r.spoken, startsWith('A moment ago'));
      expect(groq.calls, hasLength(1));
    });

    test(
      'a different question, or an expired cooldown, always costs a real call',
      () async {
        var t = DateTime(2026, 1, 1, 12);
        final groq = FakeBackend('groq');
        final svc = build(backends: [groq], now: () => t);
        await scanBytes(
          svc,
          jpegOf(gradient(200, 150)),
          question: 'what colour is it',
        );
        t = t.add(const Duration(seconds: 2));
        await scanBytes(
          svc,
          jpegOf(gradient(200, 150)),
          question: 'what is written on it',
        );
        expect(groq.calls, hasLength(2));
        t = t.add(const Duration(seconds: 13));
        await scanBytes(
          svc,
          jpegOf(gradient(200, 150)),
          question: 'what is written on it',
        );
        expect(groq.calls, hasLength(3));
      },
    );

    test('budget exhaustion is spoken as "looked too many times", not as a camera fault', () async {
      final svc = build(backends: [FakeBackend('groq', throwBudget: true)]);
      final r = await scanBytes(svc, jpegOf(gradient(200, 150)));
      expect(r.spoken, Dashboard.of(AppLanguage.english).visionBudgetSpent);
    });

    test('backend returning null, throwing, or absent all end in an offline sentence that names the limitation', () async {
      final d = Dashboard.of(AppLanguage.english);
      for (final backends in [
        <VisionBackend?>[FakeBackend('groq', fail: true)],
        <VisionBackend?>[FakeBackend('groq', throwError: true)],
        <VisionBackend?>[null],
      ]) {
        final svc = build(backends: backends);
        final r = await scanBytes(svc, jpegOf(gradient(200, 150)));
        expect(r.spoken, d.visionOfflineNothingSeen);
        expect(r.spoken, contains('internet'));
        expect(
          r.frameJpeg,
          isNotNull,
          reason: 'the user/caretaker can still be shown what was looked at',
        );
      }
    });

    test('offline with local detections says what the local model saw and that signs cannot be read', () async {
      final interp = FakeInterpreter(
        detectionsPerRun: [
          [
            const FakeDet(1, 0.8, 0.3, 0.1, 0.6, 0.2),
            const FakeDet(1, 0.8, 0.3, 0.7, 0.6, 0.8),
          ],
        ],
      );
      final svc = build(
        backends: [FakeBackend('groq', fail: true)],
        interp: interp,
      );
      final r = await scanBytes(svc, jpegOf(gradient(200, 150)));
      expect(r.spoken, contains('internet'));
      expect(
        r.spoken,
        isNot(Dashboard.of(AppLanguage.english).visionOfflineNothingSeen),
      );
    });

    test('a second scan while one is running gets the "already looking" sentence and isScanning resets afterwards', () async {
      final f = jpegOf(solid(160, 120, 5, 5, 5));
      final svc = build(
        backends: [FakeBackend('groq'), FakeBackend('gemini', maxFrames: 3)],
        frames: [f, f, f],
      );
      final first = svc.scan(
        focus: ScanFocus.surroundings,
        language: AppLanguage.english,
        sweep: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(svc.isScanning.value, isTrue);
      final second = await svc.scan(
        focus: ScanFocus.ahead,
        language: AppLanguage.english,
        capturedJpeg: f,
      );
      expect(
        second.spoken,
        Dashboard.of(AppLanguage.english).visionAlreadyLooking,
      );
      await first;
      expect(svc.isScanning.value, isFalse);
    });

    test('isScanning is released even when decoding throws (no permanently "busy" scanner)', () async {
      final svc = build(backends: [FakeBackend('groq')]);
      await expectLater(scanBytes(svc, Uint8List(0)), throwsA(anything));
      expect(svc.isScanning.value, isFalse);
      final r = await scanBytes(svc, jpegOf(gradient(100, 100)));
      expect(r.spoken, 'ok');
    });
  });

  // ============================================================ incoming pictures
  group('describeIncomingImage / follow-up', () {
    test(
      'forwards the caretaker photo untouched and returns the description',
      () async {
        final groq = FakeBackend('groq', say: 'A dog.');
        final svc = build(backends: [groq]);
        final bytes = jpegOf(gradient(100, 80));
        expect(
          await svc.describeIncomingImage(bytes, AppLanguage.english),
          'A dog.',
        );
        expect(groq.calls.single.single, orderedEquals(bytes));
      },
    );

    test('hostile bytes or a throwing backend yield null (spoken as "unreadable"), never an exception', () async {
      final svc = build(backends: [FakeBackend('groq', throwError: true)]);
      expect(
        await svc.describeIncomingImage(Uint8List(0), AppLanguage.english),
        isNull,
      );
      expect(
        await svc.describeIncomingImage(
          Uint8List.fromList([1, 2, 3]),
          AppLanguage.english,
        ),
        isNull,
      );
    });
  });

  // ============================================================ round 3
  group('round 3: JPEG flavours, EXIF oddities, colour fidelity', () {
    // 96x64 frame made with Pillow: left half red, right half blue, white
    // block at x 60..80. Encoded in four ways phone cameras and other
    // encoders actually produce.
    const flavours = <String, String>{
      '4:4:4': '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',
      '4:2:2': '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAIBAQEBAQIBAQECAgICAgQDAgICAgUEBAMEBgUGBgYFBgYGBwkIBgcJBwYGCAsICQoKCgoKBggLDAsKDAkKCgr/2wBDAQICAgICAgUDAwUKBwYHCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgr/wAARCABAAGADASEAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD53or8HP8AWgKKACigDHor/XQ/wPCigAooA2KK/wAiz/fAKKACigDHr7z/AOCI/wCxf+zT+15/ws3/AIaI+G3/AAkP/CPf2L/Y/wDxOLy0+z+f9v8AN/49po9+7yYvvZxt4xk5/wBRePc0x+S8J4nGYOfJUhyWdk7XqRi9JJrZtao/wo4ewmHx2cUqFeN4vmurtbRb6We6PvP/AIcwf8E1P+jbf/Lx1n/5Mo/4cwf8E1P+jbf/AC8dZ/8Akyv5x/4ijx1/0F/+U6X/AMgfpv8AqnkH/Pn/AMmn/wDJH4rftU+C/DXw3/af+I/w78F6b9i0fQPHusadpNn5zyeRbQXs0UUe+Qs7bUVRuYljjJJPNcFX9Y5dVqV8vo1Ju8pRi36tJs/H8TCNPETjHZNr8TYor/Jc/wB6gooAKKAMev1E/wCDbT/ms/8A3Lv/ALk6/wBNfFH/AJIXF/8AcP8A9OwP8MeE/wDkf0f+3v8A0iR+olFfyEfsx/OR+3D/AMnqfF//ALKj4g/9OU9eXV/dmU/8irD/AOCH/pKP5/xn+91P8T/M2KK/ybP96AooAKKAMev1E/4NtP8Ams//AHLv/uTr/TXxR/5IXF/9w/8A07A/wx4T/wCR/R/7e/8ASJH6iUV/IR+zH85H7cP/ACep8X/+yo+IP/TlPXl1f3ZlP/Iqw/8Agh/6Sj+f8Z/vdT/E/wAzYor/ACbP96AooAKKAMev1E/4NtP+az/9y7/7k6/018Uf+SFxf/cP/wBOwP8ADHhP/kf0f+3v/SJH6iUV/IR+zH85H7cP/J6nxf8A+yo+IP8A05T15dX92ZT/AMirD/4If+ko/n/Gf73U/wAT/M2KK/ybP96AooAKKAMev1E/4NtP+az/APcu/wDuTr/TXxR/5IXF/wDcP/07A/wx4T/5H9H/ALe/9IkfqJRX8hH7Mfzkftw/8nqfF/8A7Kj4g/8ATlPXl1f3ZlP/ACKsP/gh/wCko/n/ABn+91P8T/M2KK/ybP8AegKKACigDHr3n9iP/gof8av2Cf8AhJ/+FP8AhjwtqX/CV/Yv7R/4SWyuZvL+y+f5fl+RcRYz9ofdu3ZwuMYOf9XM+yXC8RZTUy/EykoTtdxaT92SkrXTW6XTY/wcy/HVstxkcTSSco3tfbVNdGu/c96/4iH/ANtT/omHwu/8Eupf/J9H/EQ/+2p/0TD4Xf8Agl1L/wCT6/Of+IK8Lf8AP6t/4FD/AOVn03+vObfyQ+6X/wAkfFXxU+Imt/F74n+JPiz4ltbWDUfFGvXmr6hDYoywRz3M7zOsYdmYIGcgAsxAxknrWDX6xh6EMNh4UY7RSSvvZKx8fUqOrUlN7tt/ebFFf5In+9oUUAFFAGPRX+uh/geFFABRQB//2Q==',
      '4:2:0 with restart markers': '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',
      'progressive 4:4:4': '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAIBAQEBAQIBAQECAgICAgQDAgICAgUEBAMEBgUGBgYFBgYGBwkIBgcJBwYGCAsICQoKCgoKBggLDAsKDAkKCgr/2wBDAQICAgICAgUDAwUKBwYHCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgr/wgARCABAAGADAREAAhEBAxEB/8QAGgABAQADAQEAAAAAAAAAAAAAAAQGBwgJBf/EABsBAQEBAQEBAQEAAAAAAAAAAAAIBgUEBwMC/9oADAMBAAIQAxAAAAHXeDrQAAR11A4AAskW+AABHXUD75yHZ31j+0OKvqeS+D7PxskW+AABHXUD9RYDRdRYDRDzj+3YPF+h57JFvgAAR11A/UWA0XUWA0Q84/t2DxfoeeyRb4AAEddQP1FgNF1FgNEPOP7dg8X6HnskW+AABHXUD9RYDRdRYDRDzj+3YPF+h57JFvgAAR11A+ecf2Z7yPaNK6nkwft/Fki3wAAI66gcAAf/xAAgEAABAwQDAQEAAAAAAAAAAAAGAAUwBwgQNgQXGANA/9oACAEBAAEFAvx0RCxovXTFNV0xTVFXC4zaTwW25ON1gttycbrBbbk43WC23JxusARUN6Al6HNV6HNU6uP2d3OX/8QALREAAAIFCwMFAAAAAAAAAAAAAQQAAgMFMBARFTRDcYGhscHRElFSEyExQEH/2gAIAQMBAT8B+m6Chc11+qE8026USQ8Mx5SiSHhmPKGVVWZhdVX4ARguC0w3lOVtpeOsFwWmG8pyttLx1guC0w3lOVtpeOsFwWmG8pyttLx1glDzUlP0AHv3SnDfYM+Upw32DPlGi4tWgrj+xv/EADMRAAACAg8HBQEAAAAAAAAAAAECAwUABAYQERIWMDE1RHKCscITUVJTkaLRFCFAQdKB/9oACAECAQE/AfhurWjeVux9MeLGjQ+wDRBvBkqF7ze0vhkqF7ze0vhivSnTtBEkPSJSiP8AQmXc2fFpfVNVoLhcgmXc2fFpfVNVoLhcgmXc2fFpfVNVoLhcgmXc2fFpfVNVoLhcgmVqpWquIm2EQiw0QfcG8B3MkUq+M/UPyyRSr4z9Q/LGuhK1kBERaCgAdJ7/xAAxEAAAAwMICAcBAAAAAAAAAAABAwUCBBEAEBIUMHWEsxMhNTaTpMPSFRYjMTJAUVL/2gAIAQEABj8C+mp+Yk2sVfQ6H1m2aMacfiIfgS3b5w7vlu3zh3fJRTnIugSQ/nFlMRjBkGxAA12Kzh+pOr3o8Zg2Kzh+pOr3o8Zg2Kzh+pOr3o8Zg2Kzh+pOr3o8Zg2Lz4O7OplaoaSssNDCjGEINB/UtmJfBM75bMS+CZ3yeVZ5ZZAx6PbNMBj2AWhjqtv/xAAdEAEBAAEEAwAAAAAAAAAAAAABESEQQVHwMEBQ/9oACAEBAAE/IfT6QIsm73GvHGQyRcqilgGXP2fJ+T8n5Pr1gslW3bWvXDjlaNWUrK8vm//aAAwDAQACAAMAAAAQAAAAAAAAAFSoAAAAA4AAAAA4AAAAA4AAAAA4AAAHtAAAAAAA/8QAHxEAAQMEAwEAAAAAAAAAAAAAAREwMQAhUfAQYfFA/9oACAEDAQE/EPj6Ci5E3QRgcpJBKQEB0CQHG0eTjaPJxtHk42jyZvWWqgmFhCM15dHl0TykSUhSVs9//8QAIBEBAQABAwQDAAAAAAAAAAAAARExECFBMEBQUWFxkf/aAAgBAgEBPxDs/wBMAMOSSuJnfWutr68bFRVhAq8E8ybY2xtjbeuNWPZfgJJzqiRLWoFcwAWAWG8D663/xAAgEAEBAAEBCQAAAAAAAAAAAAABERAxITBAQVBRYdHw/9oACAEBAAE/EOD+C4XnmU0StxttzrFovaiSipVXb1nbO2ds7Z9Jb8S3uiRI3FmyFZiJehBUBQJV133/2Q==',

    };

    for (final e in flavours.entries) {
      test('${e.key} JPEG decodes and uploads with the right colours in the right places', () async {
        final interp = FakeInterpreter();
        final svc = build(backends: [FakeBackend('groq')], interp: interp);
        final r = await scanBytes(svc, base64Decode(e.value));
        final out = decodeOut(r);
        expect((out.width, out.height), (96, 64));
        final left = out.getPixel(20, 32);
        final right = out.getPixel(90, 60);
        final block = out.getPixel(70, 30);
        expect(left.r, greaterThan(190), reason: 'left half stays red');
        expect(left.b, lessThan(70));
        expect(right.b, greaterThan(170), reason: 'right half stays blue');
        expect(right.r, lessThan(80));
        expect(block.r, greaterThan(220), reason: 'white block stays white');
        expect(block.b, greaterThan(220));
        expect(interp.inputs.single.length, 300 * 300 * 3);
      });
    }

    test('a 60 KB comment segment, an ICC-sized APP2 and a second JPEG appended after the first (Ultra-HDR style) do not stop the primary image decoding', () async {
      final base = jpegOf(gradient(320, 240), quality: 92);
      Uint8List segment(int marker, List<int> payload) {
        final len = payload.length + 2;
        return Uint8List.fromList([0xFF, marker, len >> 8, len & 0xFF, ...payload]);
      }
      final withComment = Uint8List.fromList([
        ...base.sublist(0, 2),
        ...segment(0xFE, List.filled(60000, 0x78)),
        ...segment(0xE2, [...'ICC_PROFILE'.codeUnits, 0, 1, 1, ...List.filled(3000, 7)]),
        ...base.sublist(2),
      ]);
      final gain = jpegOf(solid(80, 60, 128, 128, 128));
      final ultra = Uint8List.fromList([...base, ...gain]);
      for (final (name, bytes) in [('comment+icc', withComment), ('appended second jpeg', ultra)]) {
        final svc = build(backends: [FakeBackend('groq')]);
        final out = decodeOut(await scanBytes(svc, bytes));
        expect((out.width, out.height), (320, 240), reason: name);
      }
    });

    test('nonsense EXIF orientation values (0, 9, 99, 65535) are ignored rather than rotating or breaking the frame', () async {
      Uint8List withOrientation(int o) {
        // Little-endian TIFF with one IFD0 entry: Orientation (0x0112), SHORT.
        final tiff = <int>[
          0x49, 0x49, 0x2A, 0x00, 8, 0, 0, 0, // header, IFD at 8
          1, 0, // one entry
          0x12, 0x01, 3, 0, 1, 0, 0, 0, o & 0xFF, o >> 8, 0, 0,
          0, 0, 0, 0, // next IFD
        ];
        final payload = [...'Exif'.codeUnits, 0, 0, ...tiff];
        final len = payload.length + 2;
        final base = jpegOf(gradient(64, 32), quality: 92);
        return Uint8List.fromList([
          ...base.sublist(0, 2),
          0xFF, 0xE1, len >> 8, len & 0xFF, ...payload,
          ...base.sublist(2),
        ]);
      }

      for (final o in [0, 9, 99, 65535]) {
        final svc = build(backends: [FakeBackend('groq')]);
        final out = decodeOut(await scanBytes(svc, withOrientation(o)));
        expect((out.width, out.height), (64, 32), reason: 'orientation $o');
      }
      // and a sane value in the same hand-built block does rotate, so the
      // block is really being parsed
      final svc = build(backends: [FakeBackend('groq')]);
      final rotated = decodeOut(await scanBytes(svc, withOrientation(6)));
      expect((rotated.width, rotated.height), (32, 64));
    });

    test('a flat colour keeps its exact value in every corner after downscale to either cap, for odd source sizes', () async {
      for (final (w, h) in [(1281, 961), (1300, 1000), (1921, 1081), (641, 481)]) {
        for (final focus in [ScanFocus.ahead, ScanFocus.surroundings]) {
          final svc = build(backends: [FakeBackend('groq')]);
          final out = decodeOut(
            await scanBytes(svc, jpegOf(solid(w, h, 200, 60, 30), quality: 95), focus: focus),
          );
          for (final (x, y) in [(0, 0), (out.width - 1, 0), (0, out.height - 1), (out.width - 1, out.height - 1)]) {
            final p = out.getPixel(x, y);
            expect((p.r - 200).abs(), lessThan(4), reason: '${w}x$h $focus corner $x,$y red');
            expect((p.g - 60).abs(), lessThan(4), reason: '${w}x$h $focus corner $x,$y green');
            expect((p.b - 30).abs(), lessThan(4), reason: '${w}x$h $focus corner $x,$y blue');
          }
        }
      }
    });

    test('a bright block at a known place lands at the same relative place in the SSD tensor (no shift, no flip) for landscape and portrait frames', () async {
      for (final (w, h) in [(1280, 730), (640, 480), (480, 640), (1000, 1000)]) {
        final im = solid(w, h, 20, 20, 20);
        // block covering normalised x 0.60..0.80, y 0.10..0.30
        img.fillRect(im, x1: (w * 0.60).round(), y1: (h * 0.10).round(), x2: (w * 0.80).round(), y2: (h * 0.30).round(), color: img.ColorRgb8(250, 250, 250));
        final interp = FakeInterpreter();
        final svc = build(backends: [FakeBackend('groq')], interp: interp);
        await scanBytes(svc, jpegOf(im, quality: 95));
        final t = interp.inputs.single;
        final scale = 300 / (w > h ? w : h);
        final cw = (w * scale).round(), ch = (h * scale).round();
        final ox = (300 - cw) ~/ 2, oy = (300 - ch) ~/ 2;
        int lum(int x, int y) => t[(y * 300 + x) * 3];
        final inX = ox + (cw * 0.70).round(), inY = oy + (ch * 0.20).round();
        expect(lum(inX, inY), greaterThan(200), reason: '${w}x$h block centre');
        // just outside each edge of the block is dark again
        expect(lum(ox + (cw * 0.55).round(), inY), lessThan(60), reason: '${w}x$h left of block');
        expect(lum(ox + (cw * 0.85).round(), inY), lessThan(60), reason: '${w}x$h right of block');
        expect(lum(inX, oy + (ch * 0.05).round()), lessThan(60), reason: '${w}x$h above block');
        expect(lum(inX, oy + (ch * 0.36).round()), lessThan(60), reason: '${w}x$h below block');
      }
    });

    test('sensor noise does not make a heavily blurred frame outrank a sharp one in the sweep pick (sigma up to 30)', () {
      final sharp = checker(640, 480, 6);
      final blurred = img.gaussianBlur(checker(640, 480, 6), radius: 8);
      final sharpScore = SnapshotVisionService.sharpness(sharp);
      final rnd = math.Random(5);
      for (final sigma in [4.0, 12.0, 30.0]) {
        final noisy = blurred.clone();
        for (final p in noisy) {
          var g = -6.0;
          for (var i = 0; i < 12; i++) {
            g += rnd.nextDouble();
          }
          final n = g * sigma;
          p
            ..r = (p.r + n).clamp(0, 255)
            ..g = (p.g + n).clamp(0, 255)
            ..b = (p.b + n).clamp(0, 255);
        }
        final reencoded = img.decodeJpg(jpegOf(noisy, quality: 90))!;
        expect(SnapshotVisionService.sharpness(reencoded), lessThan(sharpScore), reason: 'sigma $sigma');
      }
    });
  });
}
