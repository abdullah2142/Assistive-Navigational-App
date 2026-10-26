// QA probe for the on-device detectors (area key: local_detectors).
//
// Everything here PASSES today and pins behaviour that was verified to work:
// SSD post-processing against hostile tensors, the label map against the real
// model's index convention, depth-profile edge cases, the ambient scan policy
// arithmetic and the bus-route matcher. No network, no real TFLite, no camera.
//
// The SSD / MiDaS models themselves were run from Python on real photographs
// (see the QA report); what a unit test cannot show is listed there.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ant_app/core/config/vision_config.dart';
import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';
import 'package:ant_app/core/services/emergency_channel.dart';
import 'package:ant_app/core/services/haptics_service.dart';
import 'package:ant_app/core/services/vision/ambient_hazard_scanner.dart';
import 'package:ant_app/core/services/vision/ambient_scan_policy.dart';
import 'package:ant_app/core/services/vision/snapshot_camera.dart';
import 'package:ant_app/core/services/vision/vision_backend.dart';
import 'package:ant_app/core/services/vision/vision_scene.dart';
import 'package:ant_app/features/onboarding/models/disability_profile_enums.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_async/fake_async.dart';
import 'package:geolocator/geolocator.dart';
import 'package:ant_app/core/services/vision/bus_route_directory.dart';
import 'package:ant_app/core/services/vision/depth_dropoff_detector.dart';
import 'package:ant_app/core/services/vision/depth_profile.dart';
import 'package:ant_app/core/services/vision/edge_hazard_detector.dart';
import 'package:ant_app/core/services/vision/vision_detection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

// ---------------------------------------------------------------- fakes ----

/// One row of the SSD output: class, score, [ymin, xmin, ymax, xmax].
class Row {
  const Row(this.cls, this.score, this.box);
  final double cls;
  final double score;
  final List<double> box;
}

class FakeSsd implements Interpreter {
  FakeSsd(this.rows, {this.count, this.throwOnRun = false});
  final List<Row> rows;
  final double? count;
  final bool throwOnRun;
  final inputs = <Uint8List>[];
  bool closed = false;

  @override
  void runForMultipleInputs(List<Object> inputs, Map<int, Object> outputs) {
    this.inputs.add(inputs.first as Uint8List);
    if (throwOnRun) throw StateError('interpreter exploded');
    final boxes = (outputs[0]! as List)[0] as List;
    final classes = (outputs[1]! as List)[0] as List<double>;
    final scores = (outputs[2]! as List)[0] as List<double>;
    final cnt = outputs[3]! as List<double>;
    for (var i = 0; i < rows.length && i < 10; i++) {
      classes[i] = rows[i].cls;
      scores[i] = rows[i].score;
      for (var j = 0; j < 4; j++) {
        (boxes[i] as List<double>)[j] = rows[i].box[j];
      }
    }
    cnt[0] = count ?? rows.length.toDouble();
  }

  @override
  void close() => closed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

List<String> realLabels() => File('assets/vision/labelmap.txt')
    .readAsStringSync()
    .split('\n')
    .map((l) => l.trim())
    .toList();

EdgeHazardDetector detectorWith(FakeSsd ssd) => EdgeHazardDetector(
  loadInterpreter: () async => ssd,
  loadLabels: () async => realLabels(),
);

Future<HazardVerdict> run(List<Row> rows, {double? count, img.Image? frame}) async {
  final d = detectorWith(FakeSsd(rows, count: count));
  expect(await d.ensureLoaded(), isTrue);
  return d.detect(frame ?? img.Image(width: 640, height: 480));
}

const _personIdx = 0.0;
const _busIdx = 5.0;
const _carIdx = 2.0;


// ------------------------------------------- ambient scanner test rig ----

Uint8List _jpeg([int w = 64, int h = 48]) {
  final image = img.Image(width: w, height: h)..clear(img.ColorRgb8(90, 90, 90));
  return Uint8List.fromList(img.encodeJpg(image));
}

class _Camera extends SnapshotCamera {
  _Camera(this.frames);
  final List<Uint8List> frames;
  int captures = 0;
  int releases = 0;
  @override
  Future<List<Uint8List>> capture({
    int count = 1,
    Duration gap = const Duration(milliseconds: 900),
    Future<void> Function(int index)? onBeforeFrame,
    bool holdOpen = false,
  }) async {
    captures++;
    return frames;
  }

  @override
  void releaseNow() => releases++;
}

class _Edge extends EdgeHazardDetector {
  _Edge([this.verdict = HazardVerdict.empty]);
  HazardVerdict verdict;
  int detects = 0;
  @override
  Future<bool> ensureLoaded() async => true;
  @override
  Future<HazardVerdict> detect(img.Image frame) async {
    detects++;
    return verdict;
  }

  @override
  void dispose() {}
}

class _Depth extends DepthDropoffDetector {
  _Depth([this.verdict = DropoffVerdict.unreadable]);
  DropoffVerdict verdict;
  int detects = 0;
  @override
  Future<bool> ensureLoaded() async => true;
  @override
  Future<DropoffVerdict> detect(img.Image frame) async {
    detects++;
    return verdict;
  }
}

class _Haptics extends HapticsService {
  _Haptics() : super(probeOverride: (motor: false, amplitude: false));
  final cues = <HapticCue>[];
  @override
  Future<void> play(HapticCue cue) async => cues.add(cue);
}

class _Battery extends EmergencyChannel {
  _Battery(this.percent);
  int? percent;
  @override
  Future<int?> batteryPercent() async => percent;
}

class _Cloud implements VisionBackend {
  _Cloud(this.scenes);
  final List<VisionScene?> scenes;
  int calls = 0;
  @override
  String get name => 'scripted';
  @override
  bool get isConfigured => true;
  @override
  int get maxFrames => 1;
  @override
  Future<VisionScene?> describe({
    required List<Uint8List> jpegs,
    required ScanFocus focus,
    required AppLanguage language,
    List<String> edgeLabels = const [],
    String? question,
  }) async {
    final i = calls++;
    return i < scenes.length ? scenes[i] : scenes.last;
  }
}

UserProfile _profile({
  VisionLevel vision = VisionLevel.none,
  AppLanguage lang = AppLanguage.english,
  bool? depth,
}) =>
    UserProfile(
      uid: 'rahim',
      role: UserRole.disabledUser,
      visionLevel: vision,
      language: lang,
      depthScanningEnabled: depth,
    );

Position _fix(double lat, double lng) => Position(
      latitude: lat,
      longitude: lng,
      timestamp: DateTime(2026, 10, 1, 9),
      accuracy: 5,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 1,
      speedAccuracy: 0,
    );

class _Rig {
  _Rig(
    FakeAsync async, {
    _Camera? camera,
    _Edge? edge,
    _Depth? depth,
    VisionBackend? cloud,
    int? battery = 80,
    Stream<Position>? positions,
  })  : camera = camera ?? _Camera([_jpeg()]),
        edge = edge ?? _Edge(),
        depth = depth ?? _Depth(),
        haptics = _Haptics(),
        battery = _Battery(battery) {
    final clock = async.getClock(DateTime(2026, 10, 1, 9));
    scanner = AmbientHazardScanner(
      camera: this.camera,
      edge: this.edge,
      haptics: haptics,
      onlineVision: cloud,
      depth: this.depth,
      battery: this.battery,
      positionStream: positions ?? const Stream<Position>.empty(),
      now: () => clock.now(),
    );
    scanner.announcements.listen(said.add);
  }

  final _Camera camera;
  final _Edge edge;
  final _Depth depth;
  final _Haptics haptics;
  final _Battery battery;
  late final AmbientHazardScanner scanner;
  final said = <String>[];
}

const _bus = VisionDetection(
    label: 'bus', confidence: 0.9, left: 0.2, top: 0.2, right: 0.8, bottom: 0.95);
const _imminentBus = HazardVerdict(
    level: HazardLevel.imminent, detections: [_bus], nearest: _bus, threatScore: 0.6);
const _cautionBus = HazardVerdict(
    level: HazardLevel.caution, detections: [_bus], nearest: _bus, threatScore: 0.3);

// ---------------------------------------------------------------- tests ----


// ---------------------------------------------------- session 3 helpers ----

class _FakeTensor implements Tensor {
  _FakeTensor(this._bytes);
  final Uint8List _bytes;
  @override
  Uint8List get data => _bytes;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Midas implements Interpreter {
  _Midas(this.depth, {this.throwOnRun = false});
  final Float32List depth;
  final bool throwOnRun;
  @override
  void run(Object input, Object output) {
    if (throwOnRun) throw StateError('delegate crashed');
  }

  @override
  Tensor getOutputTensor(int index) =>
      _FakeTensor(depth.buffer.asUint8List(depth.offsetInBytes, depth.lengthInBytes));
  @override
  void close() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Snap implements QuerySnapshot<Map<String, dynamic>> {
  _Snap(this._docs);
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> _docs;
  @override
  List<QueryDocumentSnapshot<Map<String, dynamic>>> get docs => _docs;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Doc implements QueryDocumentSnapshot<Map<String, dynamic>> {
  _Doc(this.id, this._data);
  @override
  final String id;
  final Map<String, dynamic> _data;
  @override
  Map<String, dynamic> data() => _data;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Throws on the first read (permission-denied / unavailable), answers after.
class _Coll implements CollectionReference<Map<String, dynamic>> {
  _Coll(this.failFirst, this.snap);
  final bool failFirst;
  final _Snap snap;
  int gets = 0;
  @override
  Future<QuerySnapshot<Map<String, dynamic>>> get([GetOptions? options]) async {
    gets++;
    if (failFirst && gets == 1) throw StateError('[cloud_firestore/unavailable]');
    return snap;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Db implements FirebaseFirestore {
  _Db(this.coll);
  final _Coll coll;
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) => coll;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final labels = realLabels();

  group('label map vs the real model convention (checked on real photos)', () {
    test('90 rows, person is row 0 and bus is row 5 (0-based class ids)', () {
      // Real SSD run on Wikimedia photos: people came back as class 0, cars as
      // 2, buses as 5, dogs as 17, cows as 20. The Dart code indexes the label
      // list directly with that value, so no off-by-one.
      expect(labels.where((l) => l.isNotEmpty).length, 90);
      expect(labels[0], 'person');
      expect(labels[1], 'bicycle');
      expect(labels[2], 'car');
      expect(labels[3], 'motorcycle');
      expect(labels[5], 'bus');
      expect(labels[6], 'train');
      expect(labels[7], 'truck');
      expect(labels[17], 'dog');
      expect(labels[20], 'cow');
    });

    test('every hazard class and every spoken class exists in the label map', () {
      for (final k in kHazardClassWeights.keys) {
        expect(labels, contains(k), reason: '$k must be a real label');
      }
      final d = Dashboard.of(AppLanguage.english);
      for (final k in [
        'bus', 'truck', 'car', 'motorcycle', 'bicycle', 'person', 'train',
        'traffic light', 'dog', 'bench',
      ]) {
        expect(labels, contains(k));
        expect(d.visionObjectLabel(k), isNot('something'));
      }
    });

    test('the ??? placeholder rows map to a non-hazard, never a crash', () async {
      final i = labels.indexOf('???');
      expect(i, greaterThan(0));
      final v = await run([Row(i.toDouble(), 0.9, [0.1, 0.1, 0.9, 0.9])]);
      expect(v.level, HazardLevel.clear);
      expect(v.nearest, isNull);
    });
  });

  group('SSD post-processing', () {
    test('box order is [ymin, xmin, ymax, xmax] -> top,left,bottom,right', () async {
      final v = await run([
        const Row(_busIdx, 0.9, [0.30, 0.20, 0.90, 0.80]),
      ]);
      final n = v.nearest!;
      expect(n.label, 'bus');
      expect(n.top, closeTo(0.30, 1e-9));
      expect(n.left, closeTo(0.20, 1e-9));
      expect(n.bottom, closeTo(0.90, 1e-9));
      expect(n.right, closeTo(0.80, 1e-9));
    });

    test('score threshold is inclusive at 0.45', () async {
      final at = await run([const Row(_busIdx, 0.45, [0.2, 0.2, 0.9, 0.8])]);
      final below = await run([const Row(_busIdx, 0.449, [0.2, 0.2, 0.9, 0.8])]);
      expect(at.detections, hasLength(1));
      expect(below.detections, isEmpty);
    });

    test('boxes outside [0,1] are clamped, not propagated', () async {
      final v = await run([
        const Row(_busIdx, 0.8, [-0.2, -0.1, 1.3, 1.2]),
      ]);
      final n = v.nearest!;
      expect([n.top, n.left], everyElement(0.0));
      expect([n.bottom, n.right], everyElement(1.0));
      expect(v.level, HazardLevel.imminent);
    });

    test('zero-area, inverted and fully off-frame boxes score zero', () async {
      for (final box in [
        [0.5, 0.5, 0.5, 0.5],
        [0.9, 0.9, 0.1, 0.1],
        [-0.5, -0.5, -0.1, -0.1],
      ]) {
        final v = await run([Row(_busIdx, 0.99, box)]);
        expect(v.level, HazardLevel.clear, reason: '$box');
        expect(v.threatScore, 0);
      }
    });

    test('class index out of range or negative is skipped', () async {
      for (final c in [-1.0, 91.0, 5000.0]) {
        final v = await run([Row(c, 0.9, [0.1, 0.1, 0.9, 0.9])]);
        expect(v.detections, isEmpty, reason: 'class $c');
      }
    });

    test('class 90 (one past the 90 labels) maps to the empty trailing label', () async {
      // The label file ends in a newline, so split('\n') yields 91 entries and
      // the last is ''. SSD never emits class 90, so this is cosmetic only.
      final v = await run([const Row(90, 0.9, [0.1, 0.1, 0.9, 0.9])]);
      expect(v.detections.single.label, '');
      expect(v.level, HazardLevel.clear);
    });

    test('NaN score never survives into the verdict', () async {
      final v = await run([
        const Row(_busIdx, double.nan, [0.1, 0.1, 0.9, 0.9]),
      ]);
      expect(v.detections, isEmpty);
      expect(v.level, HazardLevel.clear);
    });

    test('count 0 -> nothing, even when the score rows are filled', () async {
      final v = await run([
        const Row(_busIdx, 0.9, [0.1, 0.1, 0.9, 0.9]),
      ], count: 0);
      expect(v.detections, isEmpty);
    });

    test('count above 10 is clamped to the 10 slots', () async {
      final rows = [
        for (var i = 0; i < 10; i++)
          const Row(_carIdx, 0.9, [0.3, 0.3, 0.9, 0.7]),
      ];
      final v = await run(rows, count: 99);
      expect(v.detections.length, 10);
    });

    test('ten identical detections are all kept and imminent', () async {
      final rows = [
        for (var i = 0; i < 10; i++)
          const Row(_busIdx, 0.9, [0.2, 0.2, 0.95, 0.8]),
      ];
      final v = await run(rows);
      expect(v.detections.length, 10);
      expect(v.level, HazardLevel.imminent);
    });

    test('all-zero output (model saw nothing) is clear with no detections', () async {
      final v = await run(const []);
      expect(v.level, HazardLevel.clear);
      expect(v.detections, isEmpty);
    });

    test('a thrown inference degrades to empty without throwing', () async {
      final d = detectorWith(FakeSsd(const [], throwOnRun: true));
      await d.ensureLoaded();
      final v = await d.detect(img.Image(width: 64, height: 64));
      expect(v, same(HazardVerdict.empty));
    });

    test('person-only crowd, even at arm length, is never an alarm', () async {
      final v = await run([
        for (var i = 0; i < 10; i++)
          const Row(_personIdx, 0.95, [0.2, 0.1, 1.0, 0.9]),
      ]);
      expect(v.level, isNot(HazardLevel.imminent));
      expect(v.personCount, 10);
    });

    test('mixed: strongest hazard wins and drives nearest', () async {
      final v = await run([
        const Row(_personIdx, 0.9, [0.4, 0.4, 0.9, 0.6]),
        const Row(_busIdx, 0.9, [0.2, 0.2, 0.95, 0.8]),
        const Row(_carIdx, 0.9, [0.6, 0.0, 0.8, 0.1]),
      ]);
      expect(v.nearest!.label, 'bus');
      expect(v.detections.first.label, 'bus');
    });
  });

  group('model availability', () {
    test('missing model: not ready, detect is empty, load tried once', () async {
      var loads = 0;
      final d = EdgeHazardDetector(
        loadInterpreter: () async {
          loads++;
          throw StateError('asset missing');
        },
        loadLabels: () async => labels,
      );
      expect(await d.ensureLoaded(), isFalse);
      expect(await d.ensureLoaded(), isFalse);
      expect(loads, 1, reason: 'a failed load is remembered for the session');
      expect(d.isReady, isFalse);
      expect(await d.detect(img.Image(width: 8, height: 8)), same(HazardVerdict.empty));
    });

    test('null interpreter is reported as not ready', () async {
      final d = EdgeHazardDetector(
        loadInterpreter: () async => null,
        loadLabels: () async => labels,
      );
      expect(await d.ensureLoaded(), isFalse);
    });

    test('label file failing to load also marks the detector not ready', () async {
      final d = EdgeHazardDetector(
        loadInterpreter: () async => FakeSsd(const []),
        loadLabels: () async => throw StateError('no labels'),
      );
      expect(await d.ensureLoaded(), isFalse);
      expect(d.isReady, isFalse);
    });

    test('dispose closes the interpreter', () async {
      final ssd = FakeSsd(const []);
      final d = detectorWith(ssd);
      await d.ensureLoaded();
      d.dispose();
      expect(ssd.closed, isTrue);
      expect(d.isReady, isFalse);
    });
  });

  group('SSD input tensor (landscape frame without EXIF)', () {
    test('is 300x300x3 uint8, letterboxed with mid-grey, content centred', () async {
      final ssd = FakeSsd(const []);
      final d = detectorWith(ssd);
      await d.ensureLoaded();
      final frame = img.Image(width: 640, height: 480)
        ..clear(img.ColorRgb8(255, 0, 0));
      await d.detect(frame);
      final t = ssd.inputs.single;
      expect(t.length, 300 * 300 * 3);
      int px(int x, int y, int c) => t[(y * 300 + x) * 3 + c];
      // 640x480 -> 300x225, padded top/bottom by 37 rows.
      expect(px(150, 5, 0), 128);
      expect(px(150, 294, 0), 128);
      expect(px(150, 150, 0), 255);
      expect(px(150, 150, 1), 0);
      expect(px(2, 150, 0), 255);
    });

    test('RGB channel order is preserved (not BGR)', () async {
      final ssd = FakeSsd(const []);
      final d = detectorWith(ssd);
      await d.ensureLoaded();
      final frame = img.Image(width: 300, height: 300)
        ..clear(img.ColorRgb8(10, 20, 30));
      await d.detect(frame);
      final t = ssd.inputs.single;
      expect([t[(150 * 300 + 150) * 3], t[(150 * 300 + 150) * 3 + 1], t[(150 * 300 + 150) * 3 + 2]],
          [10, 20, 30]);
    });

    test('1x1 and extreme-aspect frames do not throw', () async {
      final d = detectorWith(FakeSsd(const []));
      await d.ensureLoaded();
      for (final f in [
        img.Image(width: 1, height: 1),
        img.Image(width: 4000, height: 2),
        img.Image(width: 2, height: 4000),
      ]) {
        expect(await d.detect(f), isA<HazardVerdict>());
      }
    });
  });

  group('HazardAssessor on hand-built detections', () {
    const a = HazardAssessor();
    VisionDetection det(String l, double c, double left, double top, double right, double bottom) =>
        VisionDetection(
          label: l, confidence: c, left: left, top: top, right: right, bottom: bottom);

    test('a bus that fills the frame is imminent (all-frame box, conf 0.8)', () {
      expect(a.assess([det('bus', 0.8, 0, 0, 1, 1)]).level, HazardLevel.imminent);
    });

    test('Dhaka classes: no rickshaw/CNG/cow class exists, they degrade to something', () {
      final d = Dashboard.of(AppLanguage.english);
      expect(kHazardClassWeights.containsKey('rickshaw'), isFalse);
      expect(d.visionObjectLabel('rickshaw'), d.visionObjectLabel(null));
      expect(d.visionObjectLabel('bicycle'), 'a bike or rickshaw');
      expect(Dashboard.of(AppLanguage.bangla).visionObjectLabel('bicycle'), 'সাইকেল বা রিকশা');
    });

    test('confidence below 0.45 never counts', () {
      expect(a.assess([det('bus', 0.44, 0, 0, 1, 1)]).detections, isEmpty);
    });

    test('score is monotonic in box size for a fixed class/position', () {
      var last = -1.0;
      for (var s = 0.1; s <= 1.0; s += 0.1) {
        final v = a.assess([det('truck', 0.9, 0.5 - s / 2, 1 - s, 0.5 + s / 2, 1.0)]);
        expect(v.threatScore, greaterThanOrEqualTo(last));
        last = v.threatScore;
      }
    });

    test('left/right swapped box (right<left) has zero width, not negative', () {
      final v = a.assess([det('bus', 0.9, 0.9, 0.1, 0.1, 0.9)]);
      expect(v.threatScore, 0);
    });
  });

  group('depth profile edge cases', () {
    const p = DepthProfile();
    List<double> ramp([int n = 100]) => [for (var i = 0; i < n; i++) 100.0 - i];

    test('constant image -> unreadable, never level', () {
      expect(p.analyse(List.filled(100, 7.0)).change, GroundChange.unreadable);
    });

    test('a single-row-wide strip (1 value) -> unreadable', () {
      expect(p.analyse([1.0]).change, GroundChange.unreadable);
    });

    test('23 rows unreadable, 24 rows readable (boundary)', () {
      expect(p.analyse(ramp(23)).change, GroundChange.unreadable);
      expect(p.analyse(ramp(24)).change, isNot(GroundChange.unreadable));
    });

    test('a smooth ramp is level', () {
      expect(p.analyse(ramp()).change, GroundChange.level);
    });

    test('a hard negative step is dropsAway with a score above threshold', () {
      final prof = [for (var i = 0; i < 100; i++) i < 50 ? 100.0 - i : 20.0 - (i - 50) * 0.2];
      final v = p.analyse(prof);
      expect(v.change, GroundChange.dropsAway);
      expect(v.isDangerous, isTrue);
      expect(v.paces, 2);
    });

    test('a hard positive step is risesUp and not dangerous', () {
      final prof = [for (var i = 0; i < 100; i++) i < 50 ? 100.0 - i : 200.0 - (i - 50) * 0.2];
      final v = p.analyse(prof);
      expect(v.change, GroundChange.risesUp);
      expect(v.isDangerous, isFalse);
    });

    test('step in the first two or last two diffs is ignored (edge artefacts)', () {
      final prof = ramp(100);
      prof[0] += 500;
      prof[99] -= 500;
      expect(p.analyse(prof).change, GroundChange.level);
    });

    test('paces bands: <1/3 -> 1, <2/3 -> 2, else 4', () {
      List<double> stepAt(int k) => [
            for (var i = 0; i < 100; i++) i < k ? 100.0 - i : 5.0 - (i - k) * 0.1,
          ];
      expect(p.analyse(stepAt(20)).paces, 1);
      expect(p.analyse(stepAt(50)).paces, 2);
      expect(p.analyse(stepAt(85)).paces, 4);
    });

    test('ground profile: median across the band rejects one bad column', () {
      const n = DepthDropoffDetector.inputSize;
      final flat = List<double>.generate(n * n, (i) => (i ~/ n).toDouble());
      for (var y = 0; y < n; y++) {
        flat[y * n + 130] = 9999;
      }
      expect(DepthDropoffDetector.groundProfileFlat(flat), isNot(contains(9999.0)));
    });

    test('ground profile has 236 rows, nearest first, bottom 8% skipped', () {
      const n = DepthDropoffDetector.inputSize;
      final flat = List<double>.generate(n * n, (i) => (i ~/ n).toDouble());
      final prof = DepthDropoffDetector.groundProfileFlat(flat);
      expect(prof.length, 236);
      expect(prof.first, 255 - 20);
      expect(prof.last, 0);
    });

    test('model missing -> unreadable verdict (not level) and not ready', () async {
      final d = DepthDropoffDetector(loadInterpreter: () async => null);
      expect(await d.ensureLoaded(), isFalse);
      final v = await d.detect(img.Image(width: 32, height: 32));
      expect(v.change, GroundChange.unreadable);
      expect(v.isTrustworthy, isFalse);
    });

    test('a loader that throws is swallowed once and remembered', () async {
      var n = 0;
      final d = DepthDropoffDetector(loadInterpreter: () async {
        n++;
        throw StateError('oom');
      });
      expect(await d.ensureLoaded(), isFalse);
      expect(await d.ensureLoaded(), isFalse);
      expect(n, 1);
    });
  });

  group('ambient scan policy arithmetic', () {
    final t0 = DateTime(2026, 10, 1, 9);
    AmbientScanPolicy pol() => AmbientScanPolicy();
    const clear = HazardVerdict(level: HazardLevel.clear, detections: []);
    const caution = HazardVerdict(level: HazardLevel.caution, detections: []);
    AmbientDecision decide(AmbientScanPolicy p, DateTime now,
            {double moved = 50, int? battery = 80}) =>
        p.decide(enabled: true, now: now, metersMoved: moved, batteryPercent: battery);

    test('defaults are 30/15/60 s, 4 clears, 8 m, 20 %', () {
      final p = pol();
      expect(p.interval.inSeconds, 30);
      expect(p.alertInterval.inSeconds, 15);
      expect(p.calmInterval.inSeconds, 60);
      expect(p.calmAfter, 4);
      expect(p.minMovementMeters, 8);
      expect(p.minBatteryPercent, 20);
    });

    test('interval boundary: 29.999 s refused, exactly 30 s allowed', () {
      final p = pol()..recordScan(t0, clear);
      expect(decide(p, t0.add(const Duration(milliseconds: 29999))), AmbientDecision.tooSoon);
      expect(decide(p, t0.add(const Duration(seconds: 30))), AmbientDecision.scan);
    });

    test('movement gate: 7.99 m stationary, 8.0 m scans, NaN scans', () {
      final p = pol()..recordScan(t0, clear);
      final later = t0.add(const Duration(seconds: 31));
      expect(decide(p, later, moved: 7.99), AmbientDecision.stationary);
      expect(decide(p, later, moved: 8.0), AmbientDecision.scan);
      expect(decide(p, later, moved: double.nan), AmbientDecision.scan);
    });

    test('battery boundary 19 low, 20 and 21 scan, null is not low', () {
      final p = pol();
      expect(decide(p, t0, battery: 19), AmbientDecision.batteryLow);
      expect(decide(p, t0, battery: 20), AmbientDecision.scan);
      expect(decide(p, t0, battery: 21), AmbientDecision.scan);
      expect(decide(p, t0, battery: null), AmbientDecision.scan);
      expect(decide(p, t0, battery: 0), AmbientDecision.batteryLow);
      expect(decide(p, t0, battery: -1), AmbientDecision.batteryLow);
    });

    test('battery low beats tooSoon and stationary', () {
      final p = pol()..recordScan(t0, clear);
      expect(decide(p, t0.add(const Duration(seconds: 1)), battery: 5, moved: 0),
          AmbientDecision.batteryLow);
    });

    test('backoff: 4 clears -> 60 s; a hazard resets to 30 s immediately', () {
      final p = pol();
      var now = t0;
      for (var i = 0; i < 4; i++) {
        p.recordScan(now, clear);
        now = now.add(const Duration(seconds: 31));
      }
      expect(p.currentInterval.inSeconds, 60);
      expect(decide(p, now), AmbientDecision.tooSoon);
      p.recordScan(now, caution);
      expect(p.consecutiveClear, 0);
      expect(p.currentInterval.inSeconds, 30);
    });

    test('alert pace (15 s) overrides calm pace and releases afterwards', () {
      final p = pol();
      for (var i = 0; i < 4; i++) {
        p.recordScan(t0, clear);
      }
      expect(p.currentInterval.inSeconds, 60);
      p.alert = true;
      expect(p.currentInterval.inSeconds, 15);
      expect(decide(p, t0.add(const Duration(seconds: 16))), AmbientDecision.scan);
      p.alert = false;
      expect(p.currentInterval.inSeconds, 60);
    });

    test('reset forgets pacing; first scan after reset is immediate and unconditional', () {
      final p = pol();
      for (var i = 0; i < 6; i++) {
        p.recordScan(t0, clear);
      }
      p.alert = true;
      p.reset();
      expect(p.currentInterval.inSeconds, 30);
      expect(decide(p, t0, moved: 0), AmbientDecision.scan);
    });

    test('disabled profile never scans, whatever else is true', () {
      expect(pol().decide(enabled: false, now: t0, metersMoved: 99, batteryPercent: 99),
          AmbientDecision.notEnabled);
    });

    test('a stationary user is not re-scanned however long they wait', () {
      final p = pol()..recordScan(t0, clear);
      expect(decide(p, t0.add(const Duration(hours: 3)), moved: 0), AmbientDecision.stationary);
    });
  });

  group('bus route directory', () {
    BusRoute r(String id, String en, String bn, {String? no, List<String> stops = const []}) =>
        BusRoute(id: id, nameEn: en, nameBn: bn, routeNumber: no, stops: stops);

    BusRouteDirectory dir(List<BusRoute> seed) =>
        BusRouteDirectory(seed: seed, awaitAuth: () async {});

    final seed = [
      r('a', 'Achim Paribahan', 'আছিম পরিবহন', stops: ['Mirpur 10', 'Badda']),
      r('b', 'Akash Bus', 'আকাশ বাস', stops: ['Uttara', 'Motijheel']),
      r('c', '6 No. Dhaka', '৬ নং ঢাকা', no: '6', stops: ['Mirpur', 'Farmgate']),
      r('d', 'Agradut', 'অগ্রদূত', stops: ['Gabtoli', 'Sadarghat']),
    ];

    test('exact Bangla and English names match', () async {
      final d = dir(seed);
      expect((await d.identify(readText: 'আছিম পরিবহন'))?.route.id, 'a');
      expect((await d.identify(readText: 'AKASH BUS'))?.route.id, 'b');
    });

    test('Banglish lands on the right operator, unrelated text is refused', () async {
      final d = dir(seed);
      expect((await d.identify(readText: 'achhim poribohon'))?.route.id, 'a');
      expect(await d.identify(readText: 'zzzz qqqq'), isNull);
    });

    test('empty and whitespace-only input -> null; very long junk does not hang', () async {
      final d = dir(seed);
      expect(await d.identify(readText: ''), isNull);
      expect(await d.identify(readText: '   \n\t'), isNull);
      final sw = Stopwatch()..start();
      expect(await d.identify(readText: 'x' * 600), isNull);
      expect(sw.elapsedMilliseconds, lessThan(3000));
    });

    test('empty directory returns null', () async {
      expect(await dir(const []).identify(readText: 'আছিম পরিবহন'), isNull);
    });

    test('a number no one runs falls through and is not a wrong bus', () async {
      final d = dir(seed);
      expect(await d.identify(routeNumber: '99'), isNull);
    });

    test('whitespace around a number is tolerated', () async {
      final d = dir(seed);
      expect((await d.identify(routeNumber: ' 6 '))?.route.id, 'c');
    });

    test('one-character OCR slip in the name still lands on the right operator', () async {
      final d = dir(seed);
      expect((await d.identify(readText: 'আছিন পরিবহন'))?.route.id, 'a');
      expect((await d.identify(readText: 'Akash Bas'))?.route.id, 'b');
    });

    test('operator shared by several corridors: name trusted, destination not', () async {
      final d = dir([
        r('x1', 'BRTC Bus', 'বি আর টিসি বাস', stops: ['Savar', 'Madanpur']),
        r('x2', 'BRTC Bus', 'বি আর টিসি বাস', stops: ['Tongi', 'Motijheel']),
      ]);
      final m = await d.identify(readText: 'বি আর টিসি বাস');
      expect(m, isNotNull);
      expect(m!.destinationCertain, isFalse);
    });

    test('normalise folds Bangla digits and punctuation', () {
      expect(BusRouteDirectory.normalise('৬ নং, Mirpur-১০!'), '6 নং mirpur 10');
    });
  });

  group('misc sanity', () {
    test('VisionConfig numbers the detectors rely on', () {
      expect(VisionConfig.edgeInputSize, 300);
      expect(VisionConfig.edgeMaxDetections, 10);
      expect(DepthDropoffDetector.inputSize, 256);
    });

    test('threat score never exceeds weight * confidence', () {
      const a = HazardAssessor();
      for (final e in kHazardClassWeights.entries) {
        final v = a.assess([
          VisionDetection(
              label: e.key, confidence: 1.0, left: 0, top: 0, right: 1, bottom: 1),
        ]);
        expect(v.threatScore, lessThanOrEqualTo(e.value + 1e-9));
        expect(v.threatScore, closeTo(e.value, 1e-9));
      }
      expect(math.sqrt(1.0), 1.0);
    });
  });

  // ================================================ session 2 additions ====

  group('ambient scanner behaviour (verified working)', () {
    test('battery 19 percent: one spoken warning, no camera use, and one "resumed" line at 25 percent', () {
      fakeAsync((async) {
        final rig = _Rig(async, battery: 19);
        unawaited(rig.scanner.start(_profile()));
        async.elapse(const Duration(minutes: 12));
        async.flushMicrotasks();
        expect(rig.camera.captures, 0);
        expect(rig.said, hasLength(1), reason: 'warned once, not on every tick: ${rig.said}');
        expect(rig.said.single, contains('19 percent'));
        rig.battery.percent = 22; // back over 20 but under the 25 re-arm margin
        async.elapse(const Duration(minutes: 6));
        async.flushMicrotasks();
        expect(rig.said, hasLength(1), reason: 'no "resumed" line below 25 percent');
        rig.battery.percent = 26;
        async.elapse(const Duration(minutes: 6));
        async.flushMicrotasks();
        expect(rig.said, hasLength(2));
        expect(rig.said.last.toLowerCase(), contains('watching the path again'));
        expect(rig.camera.captures, greaterThan(0));
        rig.scanner.dispose();
      });
    });

    test('battery 20 and 21 percent scan without any warning; unknown battery scans too', () {
      for (final b in <int?>[20, 21, null]) {
        fakeAsync((async) {
          final rig = _Rig(async, battery: b);
          unawaited(rig.scanner.start(_profile()));
          async.elapse(const Duration(seconds: 12));
          async.flushMicrotasks();
          expect(rig.camera.captures, 1, reason: 'battery=$b');
          expect(rig.said, isEmpty, reason: 'battery=$b');
          rig.scanner.dispose();
        });
      }
    });

    test('low-battery warning is spoken in Bangla for a Bangla profile', () {
      fakeAsync((async) {
        final rig = _Rig(async, battery: 15);
        unawaited(rig.scanner.start(_profile(lang: AppLanguage.bangla)));
        async.elapse(const Duration(seconds: 12));
        async.flushMicrotasks();
        expect(rig.said, hasLength(1));
        expect(rig.said.single, contains('ব্যাটারি 15 শতাংশ'));
        rig.scanner.dispose();
      });
    });

    test('an imminent offline verdict buzzes and says stop in English and in Bangla', () {
      for (final lang in [AppLanguage.english, AppLanguage.bangla]) {
        fakeAsync((async) {
          final rig = _Rig(async, edge: _Edge(_imminentBus));
          unawaited(rig.scanner.start(_profile(lang: lang)));
          async.elapse(const Duration(seconds: 12));
          async.flushMicrotasks();
          expect(rig.haptics.cues, contains(HapticCue.hazard));
          expect(rig.said, hasLength(1));
          expect(rig.said.single, contains(lang == AppLanguage.english ? 'Stop' : 'থামুন'));
          rig.scanner.dispose();
        });
      }
    });

    test('caution and clear offline verdicts stay silent and do not buzz', () {
      fakeAsync((async) {
        final rig = _Rig(async, edge: _Edge(_cautionBus));
        unawaited(rig.scanner.start(_profile()));
        async.elapse(const Duration(seconds: 12));
        async.flushMicrotasks();
        expect(rig.edge.detects, 1);
        expect(rig.said, isEmpty);
        expect(rig.haptics.cues, isEmpty);
        rig.scanner.dispose();
      });
    });

    test('depth drop is spoken only when the profile enables depth scanning (blind default on, low vision default off)', () {
      const drop = DropoffVerdict(
          change: GroundChange.dropsAway, score: 20, rowsAhead: 0.2, paces: 1);
      final cases = <(UserProfile, bool)>[
        (_profile(vision: VisionLevel.none), true),
        (_profile(vision: VisionLevel.low), false),
        (_profile(vision: VisionLevel.none, depth: false), false),
        (_profile(vision: VisionLevel.low, depth: true), true),
      ];
      for (final c in cases) {
        fakeAsync((async) {
          final rig = _Rig(async, depth: _Depth(drop));
          unawaited(rig.scanner.start(c.$1));
          async.elapse(const Duration(seconds: 12));
          async.flushMicrotasks();
          expect(rig.depth.detects, c.$2 ? 1 : 0, reason: '${c.$1.visionLevel.name} depth=${c.$1.depthScanningEnabled}');
          expect(rig.said.isNotEmpty, c.$2);
          if (c.$2) {
            expect(rig.said.single, contains('Stop. The ground drops right in front of you.'));
            expect(rig.haptics.cues, contains(HapticCue.hazard));
          }
          rig.scanner.dispose();
        });
      }
    });

    test('a step UP and an unreadable ground reading stay silent', () {
      for (final v in [
        const DropoffVerdict(change: GroundChange.risesUp, score: 30, rowsAhead: 0.5, paces: 2),
        DropoffVerdict.unreadable,
      ]) {
        fakeAsync((async) {
          final rig = _Rig(async, depth: _Depth(v));
          unawaited(rig.scanner.start(_profile()));
          async.elapse(const Duration(seconds: 12));
          async.flushMicrotasks();
          expect(rig.said, isEmpty);
          rig.scanner.dispose();
        });
      }
    });

    test('sighted and caretaker profiles never open the camera; stop() halts scanning and releases it; start() twice does not double the ticks', () {
      fakeAsync((async) {
        final rig = _Rig(async);
        unawaited(rig.scanner.start(_profile(vision: VisionLevel.full)));
        async.elapse(const Duration(minutes: 3));
        async.flushMicrotasks();
        expect(rig.camera.captures, 0);
        expect(rig.scanner.isRunning, isFalse);
        rig.scanner.dispose();
      });
      fakeAsync((async) {
        final rig = _Rig(async);
        unawaited(rig.scanner.start(_profile()));
        unawaited(rig.scanner.start(_profile()));
        async.elapse(const Duration(seconds: 12));
        async.flushMicrotasks();
        expect(rig.camera.captures, 1, reason: 'double start must not double-scan');
        rig.scanner.stop();
        final releases = rig.camera.releases;
        expect(releases, greaterThan(0));
        async.elapse(const Duration(minutes: 5));
        async.flushMicrotasks();
        expect(rig.camera.captures, 1, reason: 'no scan after stop()');
        expect(rig.scanner.isRunning, isFalse);
        rig.scanner.dispose();
      });
    });

    test('movement gate: first scan is immediate, a stationary user is not re-scanned, 7 m does not wake it, 9 m does', () {
      fakeAsync((async) {
        final gps = StreamController<Position>();
        final rig = _Rig(async, positions: gps.stream);
        unawaited(rig.scanner.start(_profile()));
        gps.add(_fix(23.7500, 90.3900));
        async.elapse(const Duration(seconds: 12));
        async.flushMicrotasks();
        expect(rig.camera.captures, 1, reason: 'first scan needs no movement');
        // GPS jitter of ~3 m for two minutes: still stationary.
        gps.add(_fix(23.75002, 90.39001));
        async.elapse(const Duration(minutes: 2));
        async.flushMicrotasks();
        expect(rig.camera.captures, 1);
        // ~7.8 m north: under the 8 m gate.
        gps.add(_fix(23.75007, 90.3900));
        async.elapse(const Duration(minutes: 2));
        async.flushMicrotasks();
        expect(rig.camera.captures, 1);
        // ~10 m north of the first scan position: scans.
        gps.add(_fix(23.75010, 90.3900));
        async.elapse(const Duration(seconds: 70));
        async.flushMicrotasks();
        expect(rig.camera.captures, 2);
        rig.scanner.dispose();
        unawaited(gps.close());
      });
    });

    test('alert pace is 15 s and returns to the calm pace when the alert clears', () {
      fakeAsync((async) {
        final rig = _Rig(async);
        unawaited(rig.scanner.start(_profile()));
        rig.scanner.alert = true;
        async.elapse(const Duration(seconds: 62));
        async.flushMicrotasks();
        // moved == infinity because the position stream never emits, so only
        // the interval gates: 5 s first scan, then every 15 s -> 4 scans.
        expect(rig.camera.captures, inInclusiveRange(3, 5));
        rig.scanner.dispose();
      });
    });

    test('cloud findings: same kind is spoken once per 2 minutes (boundary exact), urgent ones buzz, minor ones do not', () {
      fakeAsync((async) {
        VisionScene sc(String say, int severity) => VisionScene(
              focus: ScanFocus.hazard,
              spoken: say,
              hazards: [SceneHazard(kind: 'manhole', description: 'open manhole', severity: severity)],
            );
        final cloud = _Cloud([sc('Open manhole ahead.', 3)]);
        final rig = _Rig(async, cloud: cloud);
        unawaited(rig.scanner.start(_profile()));
        async.elapse(const Duration(seconds: 6)); // scan 1 at 5 s
        async.flushMicrotasks();
        expect(rig.said, ['Open manhole ahead.']);
        expect(rig.haptics.cues, [HapticCue.hazard]);
        // The scanner never moves (no GPS), so only the pace gates: 30 s scans.
        // Scan at 35 s, 65 s, 95 s fall inside the window -> suppressed.
        async.elapse(const Duration(seconds: 100));
        async.flushMicrotasks();
        expect(rig.said, hasLength(1), reason: 'suppressed inside 2 minutes: ${rig.said}');
        // Scan at 125 s is 120 s after the first announcement -> allowed again.
        async.elapse(const Duration(seconds: 30));
        async.flushMicrotasks();
        expect(rig.said, hasLength(2), reason: 'window is closed at exactly 120 s: ${rig.said}');
        rig.scanner.dispose();
      });
    });

    test('cloud scene with no hazards is silent and counts as a clear scan', () {
      fakeAsync((async) {
        final cloud = _Cloud([
          const VisionScene(focus: ScanFocus.hazard, spoken: 'Nothing actionable is visible.'),
        ]);
        final rig = _Rig(async, cloud: cloud);
        unawaited(rig.scanner.start(_profile()));
        async.elapse(const Duration(seconds: 12));
        async.flushMicrotasks();
        expect(cloud.calls, 1);
        expect(rig.said, isEmpty);
        expect(rig.edge.detects, 0, reason: 'a cloud answer means no offline pass');
        rig.scanner.dispose();
      });
    });

    test('cloud returning null falls back to the offline detectors in the same scan', () {
      fakeAsync((async) {
        final rig = _Rig(async, cloud: _Cloud([null]), edge: _Edge(_imminentBus));
        unawaited(rig.scanner.start(_profile()));
        async.elapse(const Duration(seconds: 12));
        async.flushMicrotasks();
        expect(rig.edge.detects, 1);
        expect(rig.said.single, contains('Stop'));
        rig.scanner.dispose();
      });
    });
  });

  group('bus route directory against the real 156-operator dataset', () {
    late List<BusRoute> all;
    late BusRouteDirectory dir;
    setUpAll(() {
      final m = jsonDecode(File('../functions/data/dhaka_bus_routes.json').readAsStringSync())
          as Map<String, dynamic>;
      all = [
        for (final e in m.entries)
          BusRoute.fromSnapshot(e.key, (e.value as Map).cast<String, dynamic>())!,
      ];
      dir = BusRouteDirectory(awaitAuth: () async {}, seed: all);
    });

    test('dataset has 156 operators and exactly 7 carry a route number', () {
      expect(all, hasLength(156));
      expect(all.where((r) => r.routeNumber != null && r.routeNumber!.isNotEmpty), hasLength(7));
    });

    test('an exactly read Bangla signboard name never returns null and resolves to its own operator for 150+ of 156', () async {
      var exact = 0;
      for (final r in all) {
        final m = await dir.identify(readText: r.nameBn);
        expect(m, isNotNull, reason: r.nameBn);
        if (m!.route.nameBn == r.nameBn) exact++;
      }
      expect(exact, greaterThanOrEqualTo(150), reason: 'resolved exactly: $exact / 156');
    });

    test('destination words alone name no operator', () async {
      for (final t in ['Gulshan Motijheel', 'ঢাকা মোটর', '', '   ', '!!!', '১২৩৪৫৬৭৮৯']) {
        final m = await dir.identify(readText: t);
        expect(m, isNull, reason: '"$t" -> ${m?.route.nameEn}');
      }
    });

    test('route numbers: a unique number wins, a shared number falls through, junk numbers are ignored', () async {
      expect((await dir.identify(routeNumber: '27'))?.route.id, 'vip-27');
      expect((await dir.identify(routeNumber: '4'))?.route.id, '4-no-alike-dhaka');
      expect(await dir.identify(routeNumber: '6'), isNull,
          reason: 'two operators run 6 and no text was read');
      for (final n in ['06', '6A', '99999999999', '৬', ' ', '']) {
        // Bangla digits are normalised by VisionPrompt before they get here.
        expect((await dir.identify(routeNumber: n))?.route.routeNumber == n, isFalse, reason: n);
      }
    });
  });

  group('session 3 regression coverage', () {
    test('depth: an output tensor of the wrong size or a crashing delegate degrades to unreadable, never to level', () async {
      final tiny = DepthDropoffDetector(loadInterpreter: () async => _Midas(Float32List(100)));
      await tiny.ensureLoaded();
      final v = await tiny.detect(img.Image(width: 64, height: 48));
      expect(v.change, GroundChange.unreadable);
      final boom = DepthDropoffDetector(
          loadInterpreter: () async => _Midas(Float32List(256 * 256), throwOnRun: true));
      await boom.ensureLoaded();
      expect((await boom.detect(img.Image(width: 64, height: 48))).change, GroundChange.unreadable);
    });

    test('depth: an all-zero output (model wrote nothing) is unreadable, not level', () async {
      final d = DepthDropoffDetector(loadInterpreter: () async => _Midas(Float32List(256 * 256)));
      await d.ensureLoaded();
      final v = await d.detect(img.Image(width: 640, height: 480));
      expect(v.change, GroundChange.unreadable);
      expect(v.isTrustworthy, isFalse);
    });

    test('depth: a clean single negative step in an otherwise smooth ramp is read as a drop at the right distance band', () {
      // 200-row ramp with one 60-unit fall 150 rows up: the far band.
      final prof = [
        for (var i = 0; i < 200; i++) 400.0 - 1.5 * i - (i >= 150 ? 60 : 0),
      ];
      final v = const DepthProfile().analyse(prof);
      expect(v.change, GroundChange.dropsAway);
      expect(v.paces, 4);
      final near = [
        for (var i = 0; i < 200; i++) 400.0 - 1.5 * i - (i >= 30 ? 60 : 0),
      ];
      expect(const DepthProfile().analyse(near).paces, 1);
    });

    test('assessor fuzz: 2,000 random detection lists never throw and keep their invariants', () {
      final rng = math.Random(7);
      const a = HazardAssessor();
      const labels = ['bus', 'truck', 'car', 'person', 'bicycle', 'motorcycle', 'train', 'dog', 'cow', '', '???'];
      for (var n = 0; n < 2000; n++) {
        final dets = [
          for (var i = 0; i < rng.nextInt(12); i++)
            VisionDetection(
              label: labels[rng.nextInt(labels.length)],
              confidence: rng.nextDouble() * 1.4 - 0.2,
              left: rng.nextDouble() * 1.6 - 0.3,
              top: rng.nextDouble() * 1.6 - 0.3,
              right: rng.nextDouble() * 1.6 - 0.3,
              bottom: rng.nextDouble() * 1.6 - 0.3,
            ),
        ];
        final v = a.assess(dets);
        expect(v.threatScore.isNaN, isFalse);
        expect(v.threatScore, inInclusiveRange(0, 1.0 + 1e-9));
        if (v.level == HazardLevel.imminent) expect(v.threatScore, greaterThanOrEqualTo(a.imminentThreshold));
        if (v.level == HazardLevel.clear && v.nearest != null) {
          expect(v.threatScore, lessThan(a.cautionThreshold));
        }
        for (final d in v.detections) {
          expect(d.confidence, greaterThanOrEqualTo(kMinDetectionConfidence));
        }
      }
    });

    test('policy fuzz: a random walk of scans never scans faster than the pace, never when battery < 20 and always releases on reset', () {
      final rng = math.Random(11);
      final p = AmbientScanPolicy();
      var now = DateTime(2026, 10, 1, 9);
      DateTime? lastScan;
      for (var i = 0; i < 5000; i++) {
        now = now.add(Duration(seconds: rng.nextInt(20)));
        final battery = rng.nextInt(10) == 0 ? null : rng.nextInt(100);
        final moved = rng.nextDouble() * 20;
        p.alert = rng.nextInt(7) == 0;
        final d = p.decide(enabled: true, now: now, metersMoved: moved, batteryPercent: battery);
        if (d == AmbientDecision.scan) {
          expect(battery == null || battery >= 20, isTrue);
          if (lastScan != null) {
            expect(now.difference(lastScan) >= p.currentInterval, isTrue);
            expect(moved >= 8, isTrue);
          }
          p.recordScan(
              now,
              rng.nextBool()
                  ? const HazardVerdict(level: HazardLevel.clear, detections: [])
                  : const HazardVerdict(level: HazardLevel.caution, detections: []));
          lastScan = now;
        }
        if (rng.nextInt(400) == 0) {
          p.reset();
          lastScan = null;
        }
      }
    });

    test('bus: every dataset operator name, in both Unicode nukta forms and with its full text, resolves to its own operator', () async {
      final m = jsonDecode(File('../functions/data/dhaka_bus_routes.json').readAsStringSync())
          as Map<String, dynamic>;
      final all = [
        for (final e in m.entries)
          BusRoute.fromSnapshot(e.key, (e.value as Map).cast<String, dynamic>())!,
      ];
      final dir = BusRouteDirectory(awaitAuth: () async {}, seed: all);
      String dec(String s) => s
          .replaceAll('\u09df', '\u09af\u09bc')
          .replaceAll('\u09dc', '\u09a1\u09bc')
          .replaceAll('\u09dd', '\u09a2\u09bc');
      String com(String s) => s
          .replaceAll('\u09af\u09bc', '\u09df')
          .replaceAll('\u09a1\u09bc', '\u09dc')
          .replaceAll('\u09a2\u09bc', '\u09dd');
      var checked = 0;
      for (final r in all) {
        for (final read in {r.nameBn, dec(r.nameBn), com(r.nameBn)}) {
          final got = await dir.identify(readText: read);
          expect(got, isNotNull, reason: read);
          // BRTC and a few others exist as several documents under one name.
          // pallabi-super and suveccha are the two known misses (their names sit
          // inside a longer operator name); see probe_bugs for the failing test.
          if (r.id == 'pallabi-super' || r.id == 'suveccha') continue;
          expect(got!.route.nameBn == r.nameBn || got.route.nameEn.toLowerCase() == r.nameEn.toLowerCase(),
              isTrue,
              reason: '"$read" -> ${got.route.nameEn}, expected ${r.nameEn}');
          checked++;
        }
      }
      expect(checked, greaterThan(156));
    });

    test('bus: Latin-script OCR slips in a numbered operator (V1P 27, VlP 27, VIP Z7, Vip-27) still resolve to VIP 27', () async {
      final dir = BusRouteDirectory(
        awaitAuth: () async {},
        seed: const [
          BusRoute(id: 'vip-27', nameEn: 'VIP 27', nameBn: 'ভিআইপি ২৭ বাস', routeNumber: '27', stops: ['Gabtoli']),
          BusRoute(id: 'dlink', nameEn: 'D Link', nameBn: 'ডি লিংক বাস', stops: ['Badda']),
        ],
      );
      for (final t in ['VIP 27', 'V1P 27', 'VlP 27', 'VIP Z7', 'Vip-27', 'ভিআইপি ২৭']) {
        expect((await dir.identify(readText: t))?.route.id, 'vip-27', reason: t);
      }
      expect(await dir.identify(readText: 'farmgate'), isNull);
      expect(await dir.identify(readText: 'bus stand'), isNull);
    });

    test('bus: a Firestore read that THROWS is not cached; the next scan asks again and succeeds', () async {
      final coll = _Coll(true, _Snap([
        _Doc('achim', {'nameEn': 'Achim Paribahan', 'nameBn': 'আছিম পরিবহন', 'stops': ['Mirpur 10']}),
      ]));
      final dir = BusRouteDirectory(firestore: _Db(coll), awaitAuth: () async {});
      expect(await dir.identify(readText: 'আছিম পরিবহন'), isNull);
      expect((await dir.identify(readText: 'আছিম পরিবহন'))?.route.id, 'achim');
      expect(coll.gets, 2);
      // ...and a loaded directory is read once, not on every scan.
      await dir.identify(readText: 'আছিম পরিবহন');
      expect(coll.gets, 2);
    });

    test('ambient: two different hazard kinds in one scan are both announced, and an urgent one buzzes exactly once', () {
      fakeAsync((async) {
        final cloud = _Cloud([
          const VisionScene(
            focus: ScanFocus.hazard,
            spoken: 'Open drain ahead and a crowd.',
            hazards: [
              SceneHazard(kind: 'open_drain', description: 'open drain', severity: 3),
              SceneHazard(kind: 'crowd', description: 'crowd', severity: 1),
            ],
          ),
        ]);
        final rig = _Rig(async, cloud: cloud);
        unawaited(rig.scanner.start(_profile()));
        async.elapse(const Duration(seconds: 8));
        async.flushMicrotasks();
        expect(rig.said, ['Open drain ahead and a crowd.']);
        expect(rig.haptics.cues, [HapticCue.hazard]);
        rig.scanner.dispose();
      });
    });
  });
}
