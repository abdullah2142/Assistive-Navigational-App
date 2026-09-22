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
      final output = [
        for (var y = 0; y < inputSize; y++)
          [for (var x = 0; x < inputSize; x++) List<double>.filled(1, 0)],
      ];

      final stopwatch = Stopwatch()..start();
      interpreter.run([input], [output]);
      stopwatch.stop();

      final verdict = _profile.analyse(_groundProfile(output));
      lastScore.value = verdict.score;
      debugPrint('[Depth] ${stopwatch.elapsedMilliseconds}ms '
          'change=${verdict.change.name} score=${verdict.score.toStringAsFixed(1)} '
          'paces=${verdict.paces}');
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
