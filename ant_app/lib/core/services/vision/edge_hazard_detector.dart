
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import '../../config/vision_config.dart';
import 'vision_detection.dart';

/// The offline half of the Snapshot Vision Engine: a quantized COCO detector
/// that answers one question — *is something big and close right now* — with
/// no network at all.
///
/// ## Why this model
///
/// `assets/vision/ssd_mobilenet_v1.tflite` is SSD MobileNet v1, 4.1 MB,
/// uint8-quantized, input `[1,300,300,3]`. Chosen over EfficientDet-Lite0
/// (the other obvious candidate) for three reasons, all verified by loading
/// both and reading their signatures:
///
/// 1. **Its NMS is inside the model.** The `TFLite_Detection_PostProcess` op
///    emits four ready tensors — boxes `[1,10,4]`, classes `[1,10]`, scores
///    `[1,10]`, count `[1]`. EfficientDet emits `[1,19206,90]` raw logits and
///    `[1,19206,4]` raw boxes, which would mean anchor decoding and
///    non-maximum suppression written by hand in Dart, on the critical path
///    of a safety alarm.
/// 2. **4.1 MB against 13.8 MB.** The APK ships to testers over mobile data.
/// 3. **uint8 against float32.** Integer inference is materially faster and
///    cooler on the Adreno-class budget hardware this app targets — the same
///    Redmi that forced the Impeller opt-out in `AndroidManifest.xml`.
///
/// ## What it structurally cannot do
///
/// COCO has 90 classes and **none of them is a rickshaw, a CNG auto-rickshaw,
/// an open manhole, a fire, or broken pavement.** In practice a
/// cycle-rickshaw detects as `bicycle` and a CNG as `car` or `truck`. That is
/// wrong as a *name* and adequate as a *hazard*, which is the only thing this
/// tier decides — see [kHazardClassWeights]. Naming and ground hazards are
/// the cloud tier's job, which means they need a network; the app says so out
/// loud rather than implying it looked and saw nothing.
///
/// Closing that gap needs a labelled Dhaka dataset and a GPU, which is out of
/// scope for this module. `assets/vision/README.md` records what a
/// replacement model would have to satisfy.
class EdgeHazardDetector {
  EdgeHazardDetector({
    HazardAssessor assessor = const HazardAssessor(),
    @visibleForTesting Future<Interpreter?> Function()? loadInterpreter,
    @visibleForTesting Future<List<String>> Function()? loadLabels,
    // ignore: prefer_initializing_formals
  })  : _assessor = assessor,
        _injectedLoader = loadInterpreter,
        _injectedLabels = loadLabels;

  final HazardAssessor _assessor;
  final Future<Interpreter?> Function()? _injectedLoader;
  final Future<List<String>> Function()? _injectedLabels;

  static const String modelAsset = 'assets/vision/ssd_mobilenet_v1.tflite';
  static const String labelAsset = 'assets/vision/labelmap.txt';

  Interpreter? _interpreter;
  List<String> _labels = const [];
  bool _loadAttempted = false;

  bool get isReady => _interpreter != null;

  /// Loads the model. Returns false if it cannot be loaded, in which case the
  /// caller must fall back to the cloud tier alone — never to silence.
  ///
  /// Loads once and remembers the failure: retrying a missing asset on every
  /// scan costs a file-system miss and a log line each time, and the answer
  /// does not change while the app is running.
  Future<bool> ensureLoaded() async {
    if (_interpreter != null) return true;
    if (_loadAttempted) return false;
    _loadAttempted = true;
    try {
      // Four threads, matching the big cluster on a typical budget
      // octa-core. More than that contends with the audio pipeline, which on
      // this app is never idle — the wake word holds a recorder stream open.
      _interpreter = _injectedLoader != null
          ? await _injectedLoader()
          : await Interpreter.fromAsset(
              modelAsset,
              options: InterpreterOptions()..threads = 4,
            );
      _labels = _injectedLabels != null
          ? await _injectedLabels()
          : (await rootBundle.loadString(labelAsset))
              .split('\n')
              .map((l) => l.trim())
              .toList();
      debugPrint('[EdgeVision] model loaded, ${_labels.length} labels');
      return _interpreter != null;
    } catch (e) {
      debugPrint('[EdgeVision] FAILED to load model: $e');
      _interpreter = null;
      return false;
    }
  }

  /// Runs the detector over one already-decoded frame.
  ///
  /// Takes a decoded [img.Image] rather than JPEG bytes so a sweep decodes
  /// each frame exactly once — the sharpness comparison in
  /// `SnapshotVisionService` needs the pixels too, and decoding a JPEG twice
  /// is the most expensive avoidable thing on this path.
  Future<HazardVerdict> detect(img.Image frame) async {
    final interpreter = _interpreter;
    if (interpreter == null) return HazardVerdict.empty;

    try {
      final input = _toInputTensor(frame);

      // Shapes fixed by the model signature, verified by loading it:
      // boxes [1,10,4], classes [1,10], scores [1,10], count [1].
      final boxes = [
        List.generate(VisionConfig.edgeMaxDetections, (_) => List.filled(4, 0.0))
      ];
      final classes = [List.filled(VisionConfig.edgeMaxDetections, 0.0)];
      final scores = [List.filled(VisionConfig.edgeMaxDetections, 0.0)];
      final count = List.filled(1, 0.0);

      final stopwatch = Stopwatch()..start();
      interpreter.runForMultipleInputs([input], {0: boxes, 1: classes, 2: scores, 3: count});
      stopwatch.stop();

      final detections = <VisionDetection>[];
      final n = count[0].toInt().clamp(0, VisionConfig.edgeMaxDetections);
      for (var i = 0; i < n; i++) {
        final score = scores[0][i];
        if (score < kMinDetectionConfidence) continue;
        final classIndex = classes[0][i].toInt();
        if (classIndex < 0 || classIndex >= _labels.length) continue;
        final box = boxes[0][i];
        // The op emits [ymin, xmin, ymax, xmax] normalized — not the
        // [x, y, w, h] most detector APIs use. Getting this wrong produces
        // boxes that still land on screen, just transposed, which is a bug
        // that survives a casual glance at a debug overlay.
        detections.add(VisionDetection(
          label: _labels[classIndex],
          confidence: score,
          top: box[0].clamp(0.0, 1.0),
          left: box[1].clamp(0.0, 1.0),
          bottom: box[2].clamp(0.0, 1.0),
          right: box[3].clamp(0.0, 1.0),
        ));
      }

      final verdict = _assessor.assess(detections);
      debugPrint('[EdgeVision] ${stopwatch.elapsedMilliseconds}ms, '
          '${detections.length} detections, level=${verdict.level.name}, '
          'score=${verdict.threatScore.toStringAsFixed(2)}'
          '${verdict.nearest == null ? '' : ', nearest=${verdict.nearest!.label}'}');
      return verdict;
    } catch (e) {
      // A detector that throws must not take the scan down with it — the
      // cloud tier can still answer, and an exception here would otherwise
      // turn "I could not run the local check" into no answer at all.
      debugPrint('[EdgeVision] inference failed: $e');
      return HazardVerdict.empty;
    }
  }

  /// Letterboxes and quantizes a frame into the `[1,300,300,3]` uint8 tensor
  /// the model expects.
  ///
  /// Letterboxed rather than stretched. A stretched frame distorts aspect
  /// ratio, and this tier's entire decision is made from box *geometry* — a
  /// bus squashed into a square reads as a different apparent size than the
  /// bus actually is, which biases the one number that decides whether to
  /// tell somebody to stop walking.
  Uint8List _toInputTensor(img.Image frame) {
    const size = VisionConfig.edgeInputSize;
    final scale = size / (frame.width > frame.height ? frame.width : frame.height);
    final resized = img.copyResize(
      frame,
      width: (frame.width * scale).round().clamp(1, size),
      height: (frame.height * scale).round().clamp(1, size),
      interpolation: img.Interpolation.linear,
    );

    // Mid-grey padding rather than black: a black bar reads to the detector
    // as a dark object at the frame edge, which is a plausible false
    // positive for exactly the low-in-frame region the threat score weights
    // most heavily.
    final canvas = img.Image(width: size, height: size)
      ..clear(img.ColorRgb8(128, 128, 128));
    img.compositeImage(
      canvas,
      resized,
      dstX: (size - resized.width) ~/ 2,
      dstY: (size - resized.height) ~/ 2,
    );

    final bytes = Uint8List(size * size * 3);
    var i = 0;
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final p = canvas.getPixel(x, y);
        bytes[i++] = p.r.toInt();
        bytes[i++] = p.g.toInt();
        bytes[i++] = p.b.toInt();
      }
    }
    return bytes;
  }

  void dispose() {
    _interpreter?.close();
    _interpreter = null;
  }
}
