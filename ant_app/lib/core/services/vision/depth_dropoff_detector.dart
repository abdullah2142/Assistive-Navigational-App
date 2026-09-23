import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import 'depth_profile.dart';

/// Sees whether the ground ahead keeps going — offline, on device.
///
/// ## Why this is worth 66 MB
///
/// A descending step is the one hazard that injures a blind pedestrian rather
/// than inconveniencing them, and it is invisible to everything else in this
/// module. COCO has no class for stairs, a kerb or an escalator, so the
/// object detector cannot see it. The cloud tier can — but the places stairs
/// are commonest are underpasses, footbridges and lift lobbies, which are
/// also where a signal is worst.
///
/// So this exists to answer one question with no network at all: *does the
/// ground stop*. Naming what it is — stairs, escalator, ramp — stays a cloud
/// question, and the two are used together.
///
/// ## The model
///
/// `assets/vision/midas_v21_small.tflite` — MiDaS v2.1 small, from isl-org's
/// v2_1 release. Input `[1,256,256,3]` float32 in 0-1, output
/// `[1,256,256,1]` float32 **inverse** depth: larger means nearer, relative
/// and unscaled, so there is no metric distance in it.
///
/// It is 66 MB and float32 because that is the only publicly downloadable
/// build — Kaggle's and Qualcomm's quantised copies are gated, and
/// TFLite-to-TFLite float16 conversion is not a supported path. See
/// `docs/open_bugs.md`.
///
/// ## What has and has not been verified
///
/// Verified: the model loads, runs, and returns a plausible depth field.
///
/// **Not verified: that any of it is right about a real pavement.** No
/// threshold here has met a real kerb, a real staircase, or a Dhaka footpath.
/// Synthetic images are useless for this — a depth model given a drawing of
/// stairs estimates the depth of a *drawing*, which was tried and produced
/// profiles indistinguishable from flat ground.
///
/// So every scan logs its score, and [lastScore] is exposed, specifically so
/// the calibration walk is possible: carry the phone past a known kerb and a
/// known flat stretch, read the `[Depth]` lines, and put
/// `DepthProfile.defaultMinScore` between them. That is how
/// `WakeWordService`'s threshold was eventually set, and it is the only
/// honest way to set this one.
class DepthDropoffDetector {
  DepthDropoffDetector({
    DepthProfile profile = const DepthProfile(),
    @visibleForTesting Future<Interpreter?> Function()? loadInterpreter,
    // ignore_for_file: prefer_initializing_formals
  })  : _profile = profile,
        _injectedLoader = loadInterpreter;

  final DepthProfile _profile;
  final Future<Interpreter?> Function()? _injectedLoader;

  static const String modelAsset = 'assets/vision/midas_v21_small.tflite';
  static const int inputSize = 256;

  /// The fraction of frame width sampled, centred.
  ///
  /// Narrow on purpose. The user is about to step forward, not sideways, and
  /// widening this drags in kerbs at the edge of the pavement that they are
  /// walking *along* rather than *off* — which is the difference between a
  /// useful warning and one that fires on every street.
  static const double _bandFraction = 0.25;

  /// Rows nearest the camera are the user's own feet and the phone's own
  /// shadow. Skipped.
  static const double _skipNearestFraction = 0.08;

  Interpreter? _interpreter;
  bool _loadAttempted = false;

  bool get isReady => _interpreter != null;

  /// The score of the most recent frame, for the calibration walk.
  ///
  /// A `ValueNotifier` for the same reason `WakeWordService.lastScore` is one:
  /// a threshold nobody can observe is a threshold nobody can set, and the
  /// gap between a real kerb and ordinary paving is invisible from outside
  /// this class.
  final ValueNotifier<double> lastScore = ValueNotifier<double>(0);

  Future<bool> ensureLoaded() async {
    if (_interpreter != null) return true;
    if (_loadAttempted) return false;
    _loadAttempted = true;
    try {
      _interpreter = _injectedLoader != null
          ? await _injectedLoader()
          : await Interpreter.fromAsset(
              modelAsset,
              options: InterpreterOptions()..threads = 4,
            );
      debugPrint('[Depth] MiDaS loaded');
      return _interpreter != null;
    } catch (e) {
      debugPrint('[Depth] FAILED to load MiDaS: $e');
      _interpreter = null;
      return false;
    }
  }

  /// Reads the ground in one frame.
  ///
  /// Returns [DropoffVerdict.unreadable] rather than "level" on any failure.
  /// The distinction is the whole safety contract of this class: a blind user
  /// hearing nothing from a scan that did not run will keep walking.
  Future<DropoffVerdict> detect(img.Image frame) async {
    final interpreter = _interpreter;
    if (interpreter == null) return DropoffVerdict.unreadable;

    try {
      final input = _toInput(frame);
      // A throwaway buffer. `run` insists on an output argument; what it
      // writes there is not what this reads — see below.
      final sink = [
        for (var y = 0; y < inputSize; y++)
          [for (var x = 0; x < inputSize; x++) List<double>.filled(1, 0)],
      ];

      final stopwatch = Stopwatch()..start();
      interpreter.run([input], [sink]);
      stopwatch.stop();

      // The depth map is read from the output **tensor**, not from the
      // nested `List` handed to `run`.
      //
      // That list came back untouched. The 23 September log is unambiguous —
      // `rows=236 min=0.000 max=0.000 range=0.000` on every scan, after
      // 800-1100ms of real inference work — and running this same model
      // offline shows it produces an output range near 900 for any input at
      // all, so the model was working the whole time and the copy back into
      // Dart was not. `tflite_flutter` fills a nested `List<List<List<double>>>`
      // only when its shape matches what the interpreter expects exactly,
      // and it reports nothing when it does not; the failure is a silent
      // no-op, which is why three sessions of `unreadable` never produced an
      // error line to chase.
      //
      // Reading `Tensor.data` sidesteps the whole question. It is the
      // interpreter's own output buffer, so there is no shape to agree on
      // and no copy to get wrong — and as a `Float32List` it is also far
      // cheaper than materialising 65,536 boxed doubles inside three levels
      // of `List` on every frame.
      final depth = interpreter
          .getOutputTensor(0)
          .data
          .buffer
          .asFloat32List(0, inputSize * inputSize);

      final profile = _groundProfileFlat(depth);
      final verdict = _profile.analyse(profile);
      lastScore.value = verdict.score;

      // Raw tensor statistics, logged on every scan until drop-off detection
      // is trusted.
      //
      // The 22 September session reported `change=unreadable score=0.0` on
      // **all 18** scans, and `score=0.0` is produced by both of `analyse`'s
      // two bail-outs, so the log could not say which had fired. Running
      // this exact model offline settles half of it: `midas_v21_small`
      // returns an output range around 900 for every input tried — a real
      // photo, flat grey, pure black, with and without ImageNet
      // normalisation — so neither the model nor the missing mean/std
      // normalisation can be the cause, and a near-zero range can only mean
      // the output buffer was never written.
      //
      // `rows` separates the other bail-out (too few usable rows), and
      // `min`/`max` say outright whether the tensor came back populated. One
      // walk with this in now answers a question three sessions have not.
      final min = profile.isEmpty ? 0.0 : profile.reduce(math.min);
      final max = profile.isEmpty ? 0.0 : profile.reduce(math.max);
      debugPrint('[Depth] ${stopwatch.elapsedMilliseconds}ms '
          'change=${verdict.change.name} score=${verdict.score.toStringAsFixed(1)} '
          'paces=${verdict.paces} '
          'rows=${profile.length} min=${min.toStringAsFixed(3)} '
          'max=${max.toStringAsFixed(3)} range=${(max - min).toStringAsFixed(3)}');
      return verdict;
    } catch (e) {
      debugPrint('[Depth] inference failed: $e');
      return DropoffVerdict.unreadable;
    }
  }

  /// Bottom-centre strip, median across the band, ordered nearest first.
  ///
  /// The median rather than the mean across the band because a single bright
  /// or dark column — a painted line, a drain cover, a shadow — should not
  /// move the profile. One odd column out of sixty-four is exactly what a
  /// median is for.
  @visibleForTesting
  static List<double> groundProfileFrom(List<List<List<double>>> depth) =>
      _groundProfile(depth);

  /// The same strip, read from the interpreter's flat output buffer.
  ///
  /// Row-major `[1, inputSize, inputSize, 1]`, so pixel (x, y) is at
  /// `y * inputSize + x`. Kept beside [_groundProfile] rather than replacing
  /// it because the nested-list form is what `depth_profile_test` feeds
  /// synthetic ground into, and that test is the only thing standing between
  /// a threshold change and a missed kerb.
  @visibleForTesting
  static List<double> groundProfileFlat(List<double> depth) => _groundProfileFlat(depth);

  static List<double> _groundProfileFlat(List<double> depth) {
    const height = inputSize;
    const width = inputSize;
    final half = (width * _bandFraction / 2).round();
    final x0 = (width ~/ 2) - half;
    final x1 = (width ~/ 2) + half;
    final skip = (height * _skipNearestFraction).round();

    final profile = <double>[];
    for (var y = height - 1 - skip; y >= 0; y--) {
      final row = <double>[
        for (var x = x0; x < x1 && x < width; x++)
          if (x >= 0) depth[y * width + x],
      ];
      if (row.isEmpty) continue;
      row.sort();
      profile.add(row[row.length ~/ 2]);
    }
    return profile;
  }

  static List<double> _groundProfile(List<List<List<double>>> depth) {
    final height = depth.length;
    final width = depth.first.length;
    final half = (width * _bandFraction / 2).round();
    final x0 = (width ~/ 2) - half;
    final x1 = (width ~/ 2) + half;
    final skip = (height * _skipNearestFraction).round();

    final profile = <double>[];
    // Bottom row is nearest the user, so walk upward from there.
    for (var y = height - 1 - skip; y >= 0; y--) {
      final row = <double>[
        for (var x = x0; x < x1 && x < width; x++)
          if (x >= 0) depth[y][x][0],
      ];
      if (row.isEmpty) continue;
      row.sort();
      profile.add(row[row.length ~/ 2]);
    }
    return profile;
  }

  /// `[1,256,256,3]` float32, values 0-1.
  ///
  /// Letterboxed rather than stretched, like the object detector: distorting
  /// aspect ratio distorts the ground's apparent slope, which is the one
  /// signal this whole class reads.
  List<List<List<double>>> _toInput(img.Image frame) {
    final scale = inputSize / math.max(frame.width, frame.height);
    final resized = img.copyResize(
      frame,
      width: (frame.width * scale).round().clamp(1, inputSize),
      height: (frame.height * scale).round().clamp(1, inputSize),
      interpolation: img.Interpolation.linear,
    );
    final canvas = img.Image(width: inputSize, height: inputSize)
      ..clear(img.ColorRgb8(128, 128, 128));
    img.compositeImage(
      canvas,
      resized,
      dstX: (inputSize - resized.width) ~/ 2,
      dstY: (inputSize - resized.height) ~/ 2,
    );

    return [
      for (var y = 0; y < inputSize; y++)
        [
          for (var x = 0; x < inputSize; x++)
            () {
              final p = canvas.getPixel(x, y);
              return [p.r / 255.0, p.g / 255.0, p.b / 255.0];
            }(),
        ],
    ];
  }

  void dispose() {
    _interpreter?.close();
    _interpreter = null;
    lastScore.dispose();
  }
}
