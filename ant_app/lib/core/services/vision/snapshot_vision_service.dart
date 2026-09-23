import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../../config/vision_config.dart';
import '../../localization/app_language.dart';
import '../../localization/dashboard_strings.dart';
import '../haptics_service.dart';
import 'bus_route_directory.dart';
import 'cloud_vision_service.dart';
import 'gemini_vision_service.dart';
import 'vision_router.dart';
import 'edge_hazard_detector.dart';
import 'snapshot_camera.dart';
import 'vision_detection.dart';
import 'vision_scene.dart';

/// The outcome of one scan, for the caller to speak and display.
class ScanResult {
  const ScanResult({
    required this.spoken,
    this.scene,
    this.verdict = HazardVerdict.empty,
    this.abortedForHazard = false,
    this.hazardPrefillKind,
    this.frameJpeg,
  });

  /// What to say. Never empty — every failure path here produces a sentence,
  /// because a scan that returns nothing is indistinguishable to a blind user
  /// from a scan that found nothing dangerous.
  final String spoken;

  final VisionScene? scene;
  final HazardVerdict verdict;

  /// True when the edge tier stopped the scan before any upload — plan Step
  /// 2.3. The caller has already been buzzed by the time it sees this.
  final bool abortedForHazard;

  /// The frame that was actually uploaded — the sharpest of the sweep, at the
  /// size the cloud tier received.
  ///
  /// Exposed so a Snapshot Request from a guardian can be answered with the
  /// picture as well as the description, without capturing or encoding a
  /// second time. Null when the scan never got as far as an upload.
  final Uint8List? frameJpeg;

  /// A `SceneHazard.kind` worth offering to report to Module 5, or null.
  ///
  /// An *offer*, never an automatic filing. The README names this exactly:
  /// filing a hazard that closes a road because somebody asked a question is
  /// a failure a blind user cannot see or undo.
  final String? hazardPrefillKind;
}

/// Orchestrates the Snapshot Vision Engine: capture, edge check, and — only
/// if the edge check says the scene is physically safe — one cloud call.
///
/// The ordering is plan Step 2 and it is not an optimisation. The local model
/// runs *before* anything touches the network so that a bus bearing down on
/// the user produces a buzz in ~100 ms rather than after a round trip, and so
/// that the abort case costs no tokens at all.
class SnapshotVisionService {
  SnapshotVisionService({
    SnapshotCamera? camera,
    EdgeHazardDetector? edge,
    VisionRouter? cloud,
    HapticsService? haptics,
    BusRouteDirectory? routes,
    DateTime Function()? now,
    // ignore_for_file: prefer_initializing_formals
    Future<void> Function(String text)? speak,
  })  : _camera = camera ?? SnapshotCamera(),
        _edge = edge ?? EdgeHazardDetector(),
        _cloud = cloud ??
            VisionRouter(groq: CloudVisionService(), gemini: GeminiVisionService()),
        _haptics = haptics ?? HapticsService(),
        _routes = routes ?? BusRouteDirectory(),
        _now = now ?? DateTime.now,
        _speak = speak;

  final SnapshotCamera _camera;
  final EdgeHazardDetector _edge;
  final VisionRouter _cloud;
  final HapticsService _haptics;
  final BusRouteDirectory _routes;
  final DateTime Function() _now;

  /// How the sweep cues each position out loud.
  ///
  /// Injected rather than reached for, because the thing that owns speech in
  /// this app is `ChatController` — it serialises narration, respects a Deaf
  /// profile, and knows not to talk over itself. A second TTS handle here
  /// would talk across all of that.
  ///
  /// Null means cue by haptic alone, which is also what a Deaf-blind user
  /// gets: the buzz *is* the instruction, and the positions are always in the
  /// same left-ahead-right order so they can be learned.
  final Future<void> Function(String text)? _speak;

  VisionScene? _lastScene;
  DateTime? _lastCloudCallAt;

  /// The question [_lastScene] answers, normalised. Part of the cache key —
  /// see [_cachedScene].
  String? _lastQuestion;

  static String? _normalisedQuestion(String? raw) {
    final trimmed = raw?.trim().toLowerCase();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  /// True while a scan is running, so the UI can say "looking…" and a second
  /// trigger does not open the camera twice.
  final ValueNotifier<bool> isScanning = ValueNotifier(false);

  /// Runs one scan.
  ///
  /// [focus] decides both how many frames are taken and how the cloud tier is
  /// prompted. Only [ScanFocus.surroundings] takes the plan's full three-frame
  /// sweep; the rest take a single frame, because the plan's own worked
  /// example — "what bus is this?" — cannot afford three seconds of standing
  /// still before the question is even sent.
  /// [narrate] speaks the sweep's aiming cues — "Left.", "Straight ahead.",
  /// "Right." — one before each frame.
  ///
  /// Passed per call rather than held on the instance because the caller is
  /// the only party that knows the user's current language and owns the TTS
  /// chain these have to queue into. The constructor's [_speak] remains as
  /// the injection point for tests; this wins when both are present.
  ///
  /// **It had no caller at all.** `snapshotVisionServiceProvider` built this
  /// service with `haptics:` and nothing else, so `_speak` was null in every
  /// real build and the sweep ran as three unexplained buzzes. Reported from
  /// the 22 September session as "the ai doesnt say aim straight, right left
  /// or anything, and the buzzes are out of sync" — the buzzes were in time,
  /// but with nothing naming the positions there was no way to tell which
  /// buzz meant which direction, which is the same thing from where the user
  /// is standing. The strings, the ordering and the settle delay were all
  /// already written and localised; only the wire was missing.
  Future<ScanResult> scan({
    required ScanFocus focus,
    required AppLanguage language,
    Future<void> Function(String text)? narrate,
    /// The user's own question, when more specific than [focus] can say. See
    /// `VisionPrompt.build`.
    String? question,
  }) async {
    final d = Dashboard.of(language);
    if (isScanning.value) return ScanResult(spoken: d.visionAlreadyLooking);
    isScanning.value = true;
    try {
      return await _run(focus, language, d, narrate ?? _speak, question);
    } finally {
      isScanning.value = false;
    }
  }

  Future<ScanResult> _run(ScanFocus focus, AppLanguage language, Dashboard d,
      Future<void> Function(String text)? narrate, String? question) async {
    // Asked before the camera opens, because it decides what the capture
    // does. A three-frame sweep is only worth taking when a backend that can
    // read three is going to be tried — with Gemini unconfigured this
    // collapses to one rather than shooting two frames to discard them.
    final frameCount = _cloud.framesNeededFor(
      focus,
      sweepFrames: VisionConfig.sweepFrameCount,
    );
    final frames = await _camera.capture(
      count: frameCount,
      onBeforeFrame: frameCount > 1 ? (i) => _cueSweepPosition(i, d, narrate) : null,
    );
    if (frames.isEmpty) {
      return ScanResult(
        spoken: _camera.isAvailable ? d.visionCaptureFailed : d.visionNoCamera,
      );
    }

    // Decoded once, here, and reused for both the edge pass and the sharpness
    // pick. Decoding a JPEG is the most expensive avoidable operation on this
    // path and doing it twice per frame was the obvious trap.
    final decoded = <img.Image>[];
    for (final bytes in frames) {
      final image = img.decodeJpg(bytes);
      if (image != null) decoded.add(image);
    }
    if (decoded.isEmpty) return ScanResult(spoken: d.visionCaptureFailed);

    await _edge.ensureLoaded();

    // Every frame gets the local check — it is free and offline, and the
    // hazard may only be visible in one of them.
    var worst = HazardVerdict.empty;
    final verdicts = <HazardVerdict>[];
    for (final frame in decoded) {
      final verdict = await _edge.detect(frame);
      verdicts.add(verdict);
      if (verdict.threatScore > worst.threatScore) worst = verdict;
    }

    // Plan Step 2.3 — abort before any upload.
    if (worst.isImminent) {
      // Buzz first, speak second. The motor reaches somebody whose phone is
      // in a pocket and whose ears are full of traffic; `HapticsService`
      // already throttles this to one every five seconds.
      await _haptics.play(HapticCue.hazard);
      final label = worst.nearest?.label;
      debugPrint('[Vision] sweep aborted — imminent $label '
          'score=${worst.threatScore.toStringAsFixed(2)}');
      return ScanResult(
        spoken: d.visionHazardAbort(d.visionObjectLabel(label)),
        verdict: worst,
        abortedForHazard: true,
      );
    }

    // A repeat question inside the cooldown is answered from the last scene
    // rather than refused. Somebody who cannot see the screen asks twice when
    // they are not sure they were heard, and spending a minute's shared token
    // allowance on that is the failure `VisionConfig.cloudScanCooldown`
    // exists to prevent — but so is stonewalling them.
    final cached = _cachedScene(focus, question);
    if (cached != null) {
      debugPrint('[Vision] answering from cache (cooldown)');
      return ScanResult(
        // Marked as old rather than repeated as if fresh — the user asked
        // twice because they thought the street had changed.
        spoken: d.visionFromAMomentAgo(cached.spoken),
        scene: cached,
        verdict: worst,
        hazardPrefillKind: _reportableKind(cached),
      );
    }

    // Sharpest first, then the rest in capture order. A backend that takes
    // only one frame therefore gets the best one, and a backend that takes
    // three gets the whole sweep — one ordering serves both, and neither
    // needs to know which it is.
    final ordered = _sharpestFirst(decoded, verdicts);
    final uploads = [for (final frame in ordered) _encodeForUpload(frame, focus)];
    // The sharpest frame, which `_sharpestFirst` has already put at the head.
    final bestFrame = uploads.isEmpty ? null : uploads.first;

    VisionScene? scene;
    try {
      scene = await _cloud.describe(
        jpegs: uploads,
        focus: focus,
        language: language,
        edgeLabels: worst.detections.map((e) => e.label).toSet().toList(),
        question: question,
      );
      if (scene != null) {
        _lastCloudCallAt = _now();
        _lastQuestion = _normalisedQuestion(question);
        scene = await _verifyRoutes(scene, language);
        _lastScene = scene;
      }
    } on VisionBudgetExhausted {
      return ScanResult(
        spoken: d.visionBudgetSpent,
        verdict: worst,
      );
    }

    if (scene == null) {
      // The cloud tier could not answer. Say what the *local* model saw and
      // say plainly that the reading half did not happen — never let this
      // sound like "there is nothing there".
      return ScanResult(
        spoken: _offlineSentence(worst, d),
        verdict: worst,
        frameJpeg: bestFrame,
      );
    }

    return ScanResult(
      spoken: scene.spoken,
      scene: scene,
      verdict: worst,
      hazardPrefillKind: _reportableKind(scene),
      frameJpeg: bestFrame,
    );
  }

  /// The last scene, if it is recent enough *and answers the same question*.
  ///
  /// The focus check is not a nicety. "Which bus is this" and "is the path
  /// clear" are two different questions about the same street, and a user who
  /// asks the second within the cooldown of the first would otherwise be read
  /// the bus answer back — a confident reply to a question they did not ask,
  /// which for somebody who cannot see the street is indistinguishable from
  /// the app having looked and checked. A different question always costs a
  /// real call.
  /// Cues one sweep position, then waits for the user to actually get there.
  ///
  /// Buzz first, words second. The motor reaches somebody whose ears are full
  /// of Dhaka traffic, and it is the only channel a Deaf-blind user has — the
  /// order left, ahead, right never changes, so three buzzes are learnable as
  /// instructions on their own.
  ///
  /// The settle delay is the whole reason this is not a burst. A frame taken
  /// while the phone is still moving is motion-blurred, and blur is what was
  /// measured turning `গুলশান` into `ঠানশান`. Waiting is cheaper than an
  /// unreadable frame.
  Future<void> _cueSweepPosition(
      int index, Dashboard d, Future<void> Function(String text)? narrate) async {
    // The same buzz for all three positions said only "a frame is coming",
    // which is the half of the instruction the user already knew. One pulse
    // for left and two for right — the same vocabulary the turn cues use, so
    // it is one thing to learn rather than two — leaves the haptic channel
    // carrying the direction even when the words are lost to traffic.
    await _haptics.play(switch (index) {
      0 => HapticCue.turnLeft,
      1 => HapticCue.navigation,
      _ => HapticCue.turnRight,
    });
    final speak = narrate;
    if (speak != null) {
      try {
        await speak(d.visionSweepStep(index));
      } catch (e) {
        // A sweep must not die because narration did. The haptic already
        // carried the instruction.
        debugPrint('[Vision] sweep cue narration failed: $e');
      }
    }
    await Future<void>.delayed(VisionConfig.sweepSettleDelay);
  }

  /// The last scene, if it answers *this* question and is still fresh.
  ///
  /// Keyed on the question as well as the focus. The focus alone was enough
  /// while the only questions were the six the enum names, but a free-text
  /// question makes two different asks share a focus — "what colour is the
  /// rabbit" and "what is written on that sign" are both `surroundings`.
  /// Answering the second from the first's cache would read back a confident
  /// reply to something the user did not ask, which for somebody who cannot
  /// see the street is indistinguishable from the app having looked and
  /// checked. That is the exact failure the focus check was already written
  /// to prevent; the question simply widened the space it has to cover.
  VisionScene? _cachedScene(ScanFocus focus, String? question) {
    final last = _lastCloudCallAt;
    final scene = _lastScene;
    if (last == null || scene == null) return null;
    if (scene.focus != focus) return null;
    if (_normalisedQuestion(question) != _lastQuestion) return null;
    final age = _now().difference(last);
    if (age >= VisionConfig.cloudScanCooldown) return null;
    if (age >= VisionConfig.sceneCacheLifetime) return null;
    return VisionScene(
      focus: scene.focus,
      spoken: scene.spoken,
      hazards: scene.hazards,
      vehicles: scene.vehicles,
      textFound: scene.textFound,
      peopleEstimate: scene.peopleEstimate,
      capturedAt: scene.capturedAt,
      fromCache: true,
    );
  }

  /// Replaces model-read destinations with the ones in the route directory.
  ///
  /// See `VisionConfig.busRouteLookupWins`. Measured on a deliberately
  /// degraded sign: the model kept the route number and corrupted the
  /// destination (`গুলশান` -> `ঠানশান`). Digits survive blur, conjunct Bangla
  /// letterforms do not — so the number is a usable key and the names are not
  /// usable output.
  Future<VisionScene> _verifyRoutes(VisionScene scene, AppLanguage language) async {
    if (!VisionConfig.busRouteLookupWins) return scene;
    final bus = scene.vehicles.where((v) => v.kind == 'bus').firstOrNull ??
        scene.vehicles.firstOrNull;
    if (bus == null) return scene;

    // Everything the board said, not just the name field. The model splits a
    // signboard into `raw_text`, `destination` and the scene's `text_found`
    // inconsistently, and the matcher wants the lot — it is looking for an
    // operator name *somewhere* in a noisy read.
    final read = [bus.rawText, bus.destination ?? '', scene.textFound]
        .where((e) => e.trim().isNotEmpty)
        .join(' ');

    final match = await _routes.identify(
      routeNumber: bus.routeNumber,
      readText: read,
      readStops: [if (bus.destination != null) bus.destination!],
    );
    if (match == null) return scene;

    final d = Dashboard.of(language);
    final route = match.route;
    final verified = [
      SceneVehicle(
        kind: 'bus',
        routeNumber: route.routeNumber ?? bus.routeNumber,
        destination: match.destinationCertain ? route.destination : null,
        rawText: bus.rawText,
      ),
      ...scene.vehicles.where((v) => v != bus),
    ];

    debugPrint('[Vision] bus identified as ${route.nameEn} '
        '(${match.why}, destination ${match.destinationCertain ? "certain" : "UNKNOWN"})');

    return VisionScene(
      focus: scene.focus,
      // Rebuilt rather than kept, because the model's sentence contained its
      // own unverified reading of the name. Correctness outranks fluency when
      // the alternative is confidently naming a bus somebody will board.
      spoken: match.destinationCertain
          ? d.visionBusVerified(
              route: route.nameFor(language),
              destination: route.destination,
            )
          : d.visionBusNameOnly(route.nameFor(language)),
      hazards: scene.hazards,
      vehicles: verified,
      textFound: scene.textFound,
      peopleEstimate: scene.peopleEstimate,
      capturedAt: scene.capturedAt,
    );
  }

  /// The highest-severity hazard worth offering to file as a Module 5 report.
  ///
  /// Only the durable ones. A vehicle or a crowd is gone in a minute and a
  /// report about it would be noise on the map by the time anybody routed
  /// around it; a manhole or a dug-up footpath is there next week.
  static const _reportableKinds = {
    'manhole', 'open_drain', 'construction', 'broken_pavement', 'flooding', 'step',
  };

  String? _reportableKind(VisionScene scene) {
    for (final h in scene.hazards) {
      if (_reportableKinds.contains(h.kind)) return h.kind;
    }
    return null;
  }

  /// What to say when the network could not be reached.
  ///
  /// Deliberately states the limitation first. "I can see a bus and two
  /// people, but I cannot read signs without internet" is honest; "there is a
  /// bus and two people" implies the whole question was answered.
  String _offlineSentence(HazardVerdict verdict, Dashboard d) {
    if (verdict.detections.isEmpty) return d.visionOfflineNothingSeen;
    final counts = <String, int>{};
    for (final det in verdict.detections) {
      counts[det.label] = (counts[det.label] ?? 0) + 1;
    }
    final parts = counts.entries
        .map((e) => d.visionCountedObject(d.visionObjectLabel(e.key), e.value))
        .toList();
    return d.visionOfflineSaw(parts.join(d.visionListSeparator));
  }

  /// Picks the frame to upload.
  ///
  /// Sharpness by variance of the Laplacian, the standard cheap focus
  /// measure: a blurred frame has little high-frequency energy. This matters
  /// more here than it would elsewhere because only one frame is ever sent
  /// (see `VisionConfig.framesUploadedPerScan`), and the measured OCR
  /// degradation on a blurred sign was the difference between reading a
  /// destination correctly and inventing one.
  ///
  /// Ties break toward the frame whose edge verdict saw the most — a sharp
  /// photograph of nothing is worse input than a slightly softer one with the
  /// bus in it.
  List<img.Image> _sharpestFirst(List<img.Image> frames, List<HazardVerdict> verdicts) {
    if (frames.length == 1) return frames;
    final scored = [
      for (var i = 0; i < frames.length; i++)
        (
          frame: frames[i],
          score: sharpness(frames[i]) *
              (1 + 0.15 * (i < verdicts.length ? verdicts[i].detections.length : 0)),
        ),
    ]..sort((a, b) => b.score.compareTo(a.score));
    debugPrint('[Vision] frames ranked, sharpest '
        'score=${scored.first.score.toStringAsFixed(1)}');
    return [for (final s in scored) s.frame];
  }

  /// Variance of a 3x3 Laplacian over a downscaled grayscale copy.
  ///
  /// Downscaled first: this runs on every frame of a sweep and the absolute
  /// value is meaningless — only the comparison between frames matters, and
  /// that survives decimation at a fraction of the cost.
  @visibleForTesting
  static double sharpness(img.Image frame) {
    final small = img.copyResize(frame, width: 160, interpolation: img.Interpolation.average);
    final gray = img.grayscale(small);
    var sum = 0.0;
    var sumSq = 0.0;
    var n = 0;
    for (var y = 1; y < gray.height - 1; y++) {
      for (var x = 1; x < gray.width - 1; x++) {
        final v = 4 * gray.getPixel(x, y).r -
            gray.getPixel(x - 1, y).r -
            gray.getPixel(x + 1, y).r -
            gray.getPixel(x, y - 1).r -
            gray.getPixel(x, y + 1).r;
        sum += v;
        sumSq += v * v;
        n++;
      }
    }
    if (n == 0) return 0;
    final mean = sum / n;
    return (sumSq / n) - (mean * mean);
  }

  /// Downscales and re-encodes for upload.
  ///
  /// 320x240 buys nothing in accuracy and everything in radio time — token
  /// cost is flat across resolution (measured), so this is purely about how
  /// long the cellular radio is transmitting, which is the part of a snapshot
  /// the battery actually notices.
  /// Whether [focus] is a question about fine detail — see
  /// [VisionConfig.detailUploadWidth].
  static bool _wantsDetail(ScanFocus focus) =>
      focus == ScanFocus.sign || focus == ScanFocus.ahead;

  Uint8List _encodeForUpload(img.Image frame, ScanFocus focus) {
    final detail = _wantsDetail(focus);
    final width = detail ? VisionConfig.detailUploadWidth : VisionConfig.uploadWidth;
    final height = detail ? VisionConfig.detailUploadHeight : VisionConfig.uploadHeight;
    final resized = img.copyResize(
      frame,
      width: width,
      height: height,
      interpolation: img.Interpolation.average,
    );
    final bytes = img.encodeJpg(resized, quality: VisionConfig.uploadJpegQuality);
    debugPrint('[Vision] upload frame ${bytes.length} bytes (${width}x$height)');
    return bytes;
  }

  /// The camera and detector, shared with [AmbientHazardScanner].
  ///
  /// Shared deliberately. Two `SnapshotCamera`s would each hold a warm
  /// window and fight over the sensor — on Android the second `initialize()`
  /// fails outright with camera-in-use — and two `EdgeHazardDetector`s would
  /// put a second copy of the 4 MB model in memory on a phone that has
  /// little. One of each, used by whoever asks.
  SnapshotCamera get camera => _camera;
  EdgeHazardDetector get edge => _edge;

  /// Releases the camera. Call on app pause and on dashboard dispose.
  void releaseCamera() => _camera.releaseNow();

  void dispose() {
    _camera.dispose();
    _edge.dispose();
    isScanning.dispose();
  }
}
