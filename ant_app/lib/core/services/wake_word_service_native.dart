import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import 'wake_word_audio_source.dart';

/// Continuous on-device wake-word detection ("Hey ANT"), via
/// [openWakeWord](https://github.com/dscripka/openWakeWord)'s three-stage
/// TFLite pipeline: raw audio -> mel-spectrogram -> embedding -> classifier
/// score. Runs entirely on-device, no cloud call, matching this app's other
/// AI Assistant pieces.
///
/// The bundled classifier (`assets/wakeword/hey_jarvis_v0.1.tflite`) is a
/// **placeholder** — it was the only wake phrase this build could actually
/// obtain, since training a real "Hey ANT" model needs ML infrastructure
/// (PyTorch, thousands of synthetic Piper-TTS clips, realistically a GPU)
/// that wasn't available in the sandbox this was written in. Swapping the
/// classifier file is the only change needed once a real one is trained —
/// see `assets/wakeword/README.md` for exact steps and a licensing note
/// (the placeholder model's weights are CC-BY-NC-SA, non-commercial only).
///
/// Exact tensor shapes and the `int16 -> float32` (unnormalized) and
/// `melOutput / 10 + 2` conventions below are taken directly from
/// openWakeWord's own `openwakeword/utils.py` (`AudioFeatures` class) —
/// not guessed. **This has not been verified against a real wake-word
/// utterance** — the sandbox this was built in has no microphone, so only
/// `flutter analyze`/compilation could be checked here. Verify on a real
/// device before relying on it.
class WakeWordService {
  /// [audioSource] and [loadModels] are seams for tests — see
  /// [WakeWordAudioSource]. Both default to the real thing, so production
  /// code constructs this with no arguments.
  WakeWordService({WakeWordAudioSource? audioSource, Future<bool> Function()? loadModels})
      : _injectedSource = audioSource,
        _injectedLoader = loadModels;

  final WakeWordAudioSource? _injectedSource;
  final Future<bool> Function()? _injectedLoader;

  /// Built on first use, not on construction.
  ///
  /// The recorder reaches its platform plugin the moment it exists, so an
  /// eager field meant simply *having* this service required a working mic
  /// plugin — it allocated one for every user including those who never turn
  /// the wake word on, and made the coordination logic untestable off-device.
  late final WakeWordAudioSource _recorder = _injectedSource ?? _RecordAudioSource();

  Interpreter? _melInterpreter;
  Interpreter? _embeddingInterpreter;
  Interpreter? _wakeWordInterpreter;
  bool _modelsLoaded = false;

  StreamSubscription<Uint8List>? _audioSub;
  final List<int> _pendingBytes = [];
  final List<List<double>> _melFrames = [];
  final List<List<double>> _embeddings = [];
  DateTime? _lastDetection;

  static const String _assetDir = 'assets/wakeword';
  static const int sampleRate = 16000;
  // 80ms per openWakeWord's own streaming convention — every model in the
  // pipeline expects audio in multiples of this chunk size.
  static const int _chunkSamples = 1280;
  static const int _melBins = 32;
  static const int _melWindowFrames = 76;
  static const int _embeddingWindowCount = 16;
  /// Score a window must reach to count as the wake phrase.
  ///
  /// **0.30, not openWakeWord's default 0.5.** Measured on a Redmi 10C on
  /// 12 September, across 56 scored windows of one real session:
  ///
  /// | Score        | What it was                    | Windows |
  /// |--------------|--------------------------------|---------|
  /// | 0.000-0.003  | silence and background          | 47      |
  /// | 0.016-0.144  | speech that is not the phrase   | 4       |
  /// | 0.300-0.342  | the phrase, **not detected**    | 3       |
  /// | 0.667-0.972  | the phrase, detected            | 8       |
  ///
  /// The three in the middle are what "sometimes it just does not respond"
  /// is. They are known to be real attempts rather than noise because each
  /// is followed by a successful detection within 3-16 seconds — the
  /// signature of somebody saying it, getting nothing, and saying it again.
  ///
  /// 0.30 clears the background floor by a factor of a hundred and the
  /// loudest non-attempt speech by two. The asymmetry justifies the rest: a
  /// false positive opens a microphone that closes itself a few seconds
  /// later, while a false negative means the only hands-free way into this
  /// app did not work for somebody who cannot reach the button.
  ///
  /// **This number belongs to `hey_jarvis_v0.1` and to the voices it has
  /// been measured against, not to the pipeline.** It is a placeholder model
  /// trained on synthetic English clips; a real "Hey ANT" model will need
  /// its own measurement. Tune per build without touching code:
  ///
  /// ```
  /// flutter build apk --dart-define=WAKE_WORD_THRESHOLD_PCT=40
  /// ```
  static const int _thresholdPercent =
      int.fromEnvironment('WAKE_WORD_THRESHOLD_PCT', defaultValue: 30);
  static const double detectionThreshold = _thresholdPercent / 100;
  static const Duration _cooldown = Duration(seconds: 2);

  /// How long to wait after the microphone is handed back before reopening
  /// the recorder. Not `const` so a test can shrink it — every restart path
  /// goes through this delay, and waiting half a second per assertion turns
  /// a fast suite into a slow one.
  @visibleForTesting
  static Duration restartHandoff = const Duration(milliseconds: 500);

  bool get isListening => _audioSub != null;

  void Function()? _lastOnDetected;

  /// Whether the app *wants* the wake word running, independent of whether
  /// the recorder happens to be open right now.
  ///
  /// This is the authoritative bit, and separating it from [isListening] is
  /// what fixes the reported "with both toggles on, neither works". The old
  /// code inferred the intent instead, at the moment a suspension was taken:
  /// if the recorder was live it remembered to restart it, and otherwise it
  /// did not. That inference is wrong whenever a suspension lands while a
  /// `start()` is still in flight — which is a routine ordering, not an
  /// exotic one, because a wake-word detection is immediately followed by a
  /// listen session whose release schedules a restart 500 ms later, and the
  /// command the user just spoke ("report a hazard") opens a screen that
  /// suspends inside that same window. The result was the worst of both:
  /// the recorder came up *inside* the suspension and took the microphone
  /// away from the recognizer, and the release then declined to restart it,
  /// so the wake word never came back either.
  ///
  /// With an explicit flag, [start] can refuse to open the recorder while
  /// suspended, and the release always knows whether to bring it back.
  bool _enabled = false;

  @visibleForTesting
  bool get isEnabled => _enabled;

  /// Guards two `start()` calls racing each other into `startStream()`.
  /// `ChatStreamPanel` can issue one from `initState` and another from
  /// `didUpdateWidget` before the first has finished loading models.
  bool _starting = false;

  /// How many suspensions are currently held.
  ///
  /// Reference-counted because they nest. `SttService.listenOnce` takes one
  /// around every single listen, and a voice *flow* — the hazard hub, the
  /// passerby picker — takes one around its whole narrate-then-listen loop.
  /// Without counting, the inner release restarted the recorder in the gap
  /// between two steps of the outer flow, which is precisely when the app is
  /// talking. The wake-word recorder then held the microphone through the
  /// narration and the next listen came up empty, so the hub read out the
  /// hazard options and took no answer.
  int _suspendDepth = 0;

  @visibleForTesting
  int get suspendDepth => _suspendDepth;

  /// Suspends wake-word listening for the duration of [action].
  ///
  /// Centralizes a fix that used to live duplicated (and, in one real case,
  /// forgotten) in each caller of [SttService.listenOnce]: two separate
  /// audio-capture sessions — this service's own continuous recorder stream
  /// and the speech recognizer's — fighting over the microphone at the same
  /// time. Confirmed live in more than one place: the classifier's score
  /// would flatline to an exact `0.000` (not even background-noise variance)
  /// after the recognizer grabbed the mic mid-listen, and the *reverse* —
  /// starting a manual push-to-talk session while this service was still
  /// actively listening — could cut the STT session off before a word was
  /// even transcribed. [SttService] now calls this around every
  /// `listenOnce`, so any caller gets the coordination for free without
  /// needing to know wake-word exists at all.
  ///
  /// Nest it around a whole spoken exchange when one screen owns the
  /// microphone for several turns — otherwise the recorder comes back
  /// between them.
  Future<T> pauseAround<T>(Future<T> Function() action) async {
    await _acquireSuspend();
    try {
      return await action();
    } finally {
      await _releaseSuspend();
    }
  }

  /// Takes a suspension held until [resume]. For a screen that owns the
  /// microphone across several spoken turns — [pauseAround] is the right
  /// shape when the work is a single awaitable.
  ///
  /// Deliberately not awaited by callers in `initState`; the stop it may
  /// trigger is fire-and-forget and the screen must not block its first
  /// frame on it.
  void suspend() => unawaited(_acquireSuspend());

  /// Releases a [suspend]. Safe to call when nothing is held.
  void resume() {
    if (_suspendDepth == 0) return;
    unawaited(_releaseSuspend());
  }

  Future<void> _acquireSuspend() async {
    _suspendDepth++;
    if (_suspendDepth > 1) return;
    // Whatever features the pipeline has are worth keeping across this gap
    // unless a detection already consumed them — see [_resetBuffers].
    _markWarm();
    // Unconditional, not `if (isListening)`. A recorder that is merely
    // *coming up* has to be silenced too, and `isListening` is false for the
    // whole of that window — see [_enabled]. Stopping a recorder that was
    // never opened is a no-op on every backend.
    await _stopRecorder();
  }

  Future<void> _releaseSuspend() async {
    _suspendDepth--;
    // Still held by an outer flow — leave the microphone alone.
    if (_suspendDepth > 0) return;
    if (_suspendDepth < 0) _suspendDepth = 0;
    if (!_enabled || _lastOnDetected == null) return;
    // Brief handoff gap: reclaiming the mic immediately after the other
    // session ends raced Android's own audio-session teardown on device —
    // see the doc comment above for what that looked like.
    await Future.delayed(restartHandoff);
    // A new suspension may have been taken during that delay.
    if (_suspendDepth > 0) return;
    await start(onDetected: _lastOnDetected!);
  }

  Future<bool> _ensureModelsLoaded() async {
    if (_modelsLoaded) return true;
    final loader = _injectedLoader;
    if (loader != null) return _modelsLoaded = await loader();
    try {
      debugPrint('[WakeWord] loading melspectrogram.tflite...');
      _melInterpreter = await Interpreter.fromAsset('$_assetDir/melspectrogram.tflite');
      debugPrint('[WakeWord] melspectrogram OK, loading embedding_model.tflite...');
      _embeddingInterpreter = await Interpreter.fromAsset('$_assetDir/embedding_model.tflite');
      debugPrint('[WakeWord] embedding OK, loading hey_jarvis_v0.1.tflite...');
      _wakeWordInterpreter = await Interpreter.fromAsset('$_assetDir/hey_jarvis_v0.1.tflite');
      _modelsLoaded = true;
      debugPrint('[WakeWord] all models loaded OK');
    } catch (e) {
      _modelsLoaded = false;
      debugPrint('[WakeWord] FAILED to load models: $e');
    }
    return _modelsLoaded;
  }

  /// Starts continuous listening. [onDetected] fires (debounced by a
  /// 2-second cooldown) whenever the wake phrase is heard. Returns `false`
  /// without starting anything if the TFLite models fail to load or the
  /// microphone permission isn't available — callers should fall back to
  /// push-to-talk-only, exactly like [SttService.ensureAvailable] failing.
  ///
  /// Returns `true` without opening the microphone while a suspension is
  /// held: the intent is recorded and the recorder comes up when the last
  /// suspension is released. Any other answer would be a lie in the
  /// direction that hurts — a caller told `false` falls back to
  /// push-to-talk-only and never asks again.
  Future<bool> start({required void Function() onDetected}) async {
    _lastOnDetected = onDetected;
    _enabled = true;
    if (isListening) return true;
    // Someone else owns the microphone. `_releaseSuspend` starts us.
    if (_suspendDepth > 0) return true;
    if (_starting) return true;
    _starting = true;
    try {
      if (!await _ensureModelsLoaded()) return false;
      if (!await _recorder.hasPermission()) {
        debugPrint('[WakeWord] mic permission not granted');
        return false;
      }
      // Re-checked after every await above. A suspension taken while the
      // models were loading, or while the permission dialog was up, must win
      // — opening the recorder now would take the microphone from whoever
      // suspended us, which is the whole bug this guards.
      if (_suspendDepth > 0 || !_enabled) return true;

      _resetBuffers();

      final stream = await _recorder.startStream();
      if (_suspendDepth > 0 || !_enabled) {
        // Landed during the recorder handshake itself. Hand the microphone
        // straight back rather than listening over the top of the session
        // that suspended us.
        await _recorder.stop();
        return true;
      }
      _audioSub = stream.listen(
        (bytes) => _onAudioBytes(bytes, onDetected),
        // A recorder stream that dies on its own used to be silence in both
        // directions: nothing restarted it, and nothing even knew. See
        // [_onRecorderStreamEnded].
        onError: (Object e) => _onRecorderStreamEnded('error: $e'),
        onDone: () => _onRecorderStreamEnded('stream closed'),
        cancelOnError: true,
      );
      debugPrint('[WakeWord] listening started '
          '(${_warmRestart ? 'warm — feature buffers kept' : 'cold — buffers cleared'})');
      _warmRestart = false;
      return true;
    } finally {
      _starting = false;
    }
  }

  /// Whether the *next* [start] may keep the mel/embedding buffers it
  /// already has. See [_resetBuffers].
  bool _warmRestart = false;

  /// What a (re)start does to the feature pipeline.
  ///
  /// ## Why a restart can be warm at all
  ///
  /// The classifier needs 16 embedding windows before it can score anything,
  /// each embedding needs 76 mel frames, and both are built 80 ms at a time
  /// — about 2.5 s of audio from empty. Clearing everything on every restart
  /// therefore left the wake word genuinely deaf for ~2 s after each voice
  /// exchange, on top of the 500 ms handoff gap. Say "Hey ANT" into that
  /// window and it is silently missed, which reads as the detector being
  /// flaky rather than warming up. openWakeWord itself never clears between
  /// utterances — it runs one continuous stream — so keeping the features is
  /// also closer to the reference implementation than resetting was.
  ///
  /// ## Why it cannot be warm after a detection
  ///
  /// The suspension that follows a detection is taken within milliseconds of
  /// it, so the retained buffer's newest 16 embeddings *are* the wake phrase
  /// that just fired. On resume the window would be 15 of those plus one
  /// fresh embedding, score essentially the same, and fire again — and the
  /// 2-second cooldown is no help, because the suspension outlasts it by the
  /// length of the whole command. So a detection marks the buffers poisoned
  /// and the next start is cold. Every other reason for suspending — the mic
  /// button, the hazard hub, the passerby picker, the emergency flow — holds
  /// ordinary speech or silence, and keeps its warmth.
  void _resetBuffers() {
    // Always dropped: a partial chunk spliced across the gap would put one
    // frame of nonsense at the seam, and it is 80 ms of context at most.
    _pendingBytes.clear();
    if (_warmRestart) return;
    _melFrames.clear();
    _embeddings.clear();
    // Reset the detection cooldown too. Without this, a restart that lands
    // inside the cooldown window from the *previous* session's detection
    // silently swallows the next wake word — the one case where "it worked
    // once and then stopped" is exactly what the user would see. Safe here
    // precisely because a cold buffer cannot re-fire the old phrase.
    _lastDetection = null;
    _lastScoreLog = null;
    _peakSinceLog = 0;
  }

  /// Stops the recorder without changing whether the wake word is wanted.
  /// Used by suspension; [stop] is the caller-facing "turn it off".
  Future<void> _stopRecorder() async {
    await _audioSub?.cancel();
    _audioSub = null;
    try {
      await _recorder.stop();
    } catch (_) {
      // Already stopped — fine.
    }
  }

  /// Turns the wake word off. Distinct from a suspension: nothing brings it
  /// back until a caller asks for it again with [start].
  Future<void> stop() async {
    _enabled = false;
    // Before `_stopRecorder`, so a reopen already queued cannot land after it.
    _restartTimer?.cancel();
    _restartTimer = null;
    _restartAttempts = 0;
    await _stopRecorder();
  }

  Future<void> dispose() async {
    await stop();
    _melInterpreter?.close();
    _embeddingInterpreter?.close();
    _wakeWordInterpreter?.close();
    try {
      await _recorder.dispose();
    } catch (_) {
      // Nothing to release — a build that never opened the microphone, or a
      // test host with no recorder plugin at all. This runs from Riverpod's
      // container teardown, where an unhandled async throw surfaces as an
      // unrelated test failing rather than as anything anyone can act on.
    }
  }

  /// How long to wait before reopening a recorder whose stream ended by
  /// itself, and the ceiling that wait backs off to.
  ///
  /// Long enough not to fight a recorder that cannot come up at all, short
  /// enough that a user who has just turned airplane mode off is not left
  /// pressing a dead wake word.
  /// Not `const`, for the same reason as [restartHandoff] — a test that has
  /// to wait out a real backoff per assertion is a test nobody runs.
  @visibleForTesting
  static Duration recorderRetryBase = const Duration(seconds: 2);
  @visibleForTesting
  static Duration recorderRetryMax = const Duration(seconds: 60);

  Timer? _restartTimer;
  int _restartAttempts = 0;

  /// The recorder's stream ended without anyone asking it to.
  ///
  /// This is what a disrupted audio stack looks like from Dart: airplane mode
  /// toggling the radio, a phone call taking the microphone, another app
  /// grabbing it, or the recorder session simply dying. The subscription was
  /// created with neither `onError` nor `onDone`, so all of that was silent —
  /// and worse than silent, because [isListening] is `_audioSub != null` and a
  /// subscription whose stream is finished stays non-null. The service went on
  /// reporting that it was listening, with the microphone dead, and nothing
  /// ever brought it back. "মাইক অন হচ্ছে না। অফ থাকে" — the mic does not turn
  /// on, it stays off (open_bugs item 32).
  ///
  /// Cancelling a subscription does not fire `onDone`, so a deliberate
  /// [_stopRecorder] never lands here — only an ending nobody asked for.
  void _onRecorderStreamEnded(String reason) {
    _audioSub = null;
    if (!_enabled) return;
    if (_suspendDepth > 0) {
      // Somebody else owns the microphone; `_releaseSuspend` restarts us.
      debugPrint('[WakeWord] recorder ended during a suspension ($reason)');
      return;
    }
    final onDetected = _lastOnDetected;
    if (onDetected == null) return;

    // Backed off, because the common reason a reopen fails is the same reason
    // the stream ended, and retrying flat out would hold the CPU awake behind
    // a wake lock for as long as the condition lasts.
    final delay = _backoffDelay(_restartAttempts);
    _restartAttempts++;
    debugPrint('[WakeWord] recorder ended on its own ($reason) — '
        'reopening in ${delay.inMilliseconds}ms (attempt $_restartAttempts)');
    _restartTimer?.cancel();
    _restartTimer = Timer(delay, () {
      if (!_enabled || _suspendDepth > 0 || isListening) return;
      // Warm: the feature buffers are still good, and a user who said "Hey
      // ANT" as the recorder came back should not have to wait out a cold
      // classifier as well.
      _warmRestart = true;
      unawaited(start(onDetected: onDetected));
    });
  }

  Duration _backoffDelay(int attempts) {
    final millis = recorderRetryBase.inMilliseconds * (1 << attempts.clamp(0, 5));
    return millis >= recorderRetryMax.inMilliseconds
        ? recorderRetryMax
        : Duration(milliseconds: millis);
  }

  void _onAudioBytes(Uint8List bytes, void Function() onDetected) {
    // Audio is flowing, so whatever was wrong is over. Without this the delay
    // would keep climbing across a long session of unrelated interruptions
    // until a real one took a minute to recover from.
    _restartAttempts = 0;
    _pendingBytes.addAll(bytes);
    const bytesPerChunk = _chunkSamples * 2; // 16-bit samples
    while (_pendingBytes.length >= bytesPerChunk) {
      final chunkBytes = Uint8List.fromList(_pendingBytes.sublist(0, bytesPerChunk));
      _pendingBytes.removeRange(0, bytesPerChunk);
      final samples = chunkBytes.buffer.asInt16List();
      _processChunk(samples, onDetected);
    }
  }

  // Score logging was one line per frame — roughly twelve a second, which
  // buried every other log in the app and made a real device session
  // impossible to read. Now a periodic summary carrying the *peak* score
  // in each window, which is the number that actually matters: if a user
  // says the wake phrase and the peak stays near zero, the detector is not
  // hearing them (a microphone or echo-cancellation problem); if it peaks
  // at 0.3, it is hearing them and the threshold is wrong. One line every
  // few seconds distinguishes those; twelve identical lines a second
  // distinguishes nothing.
  static const Duration _scoreLogInterval = Duration(seconds: 3);
  DateTime? _lastScoreLog;
  double _peakSinceLog = 0;

  /// Note on `peak=0.000` in the log.
  ///
  /// It is tempting to read an exact zero as "the microphone is starved" —
  /// [pauseAround]'s comment describes that symptom, and a run of zeros does
  /// appear right after a Cloud STT session hands the mic back. A self-heal
  /// was written on that basis and then disproved on device: three
  /// consecutive 0.000 windows were followed immediately by a clean
  /// detection at 0.783. On this hardware an exact zero is simply what
  /// silence scores.
  ///
  /// So do not restart the recorder on a run of zeros. It would fire after
  /// any few seconds of quiet — which is most of the time — and the churn
  /// would cause the very starvation it was meant to repair. If real
  /// starvation needs detecting, it needs a signal that distinguishes "no
  /// audio" from "quiet audio"; the classifier score is not one.
  void _logScore(double score) {
    _peakSinceLog = score > _peakSinceLog ? score : _peakSinceLog;
    final now = DateTime.now();
    _lastScoreLog ??= now;
    if (now.difference(_lastScoreLog!) < _scoreLogInterval) return;
    debugPrint('[WakeWord] peak=${_peakSinceLog.toStringAsFixed(3)} '
        '(threshold $detectionThreshold) over the last ${_scoreLogInterval.inSeconds}s');
    _lastScoreLog = now;
    _peakSinceLog = 0;
  }

  void _processChunk(Int16List pcm, void Function() onDetected) {
    final frames = _runMelspectrogram(pcm);
    for (final frame in frames) {
      // openWakeWord's own post-processing scale on the raw mel output,
      // applied before the frame ever reaches the embedding model.
      _melFrames.add(frame.map((v) => v / 10 + 2).toList());
    }
    while (_melFrames.length > _melWindowFrames * 3) {
      _melFrames.removeAt(0);
    }
    if (_melFrames.length < _melWindowFrames) return;

    final melWindow = _melFrames.sublist(_melFrames.length - _melWindowFrames);
    _embeddings.add(_runEmbedding(melWindow));
    while (_embeddings.length > _embeddingWindowCount * 3) {
      _embeddings.removeAt(0);
    }
    if (_embeddings.length < _embeddingWindowCount) return;

    final embeddingWindow = _embeddings.sublist(_embeddings.length - _embeddingWindowCount);
    final score = _runWakeWordClassifier(embeddingWindow);
    _logScore(score);

    final now = DateTime.now();
    final offCooldown = _lastDetection == null || now.difference(_lastDetection!) > _cooldown;
    if (score >= detectionThreshold && offCooldown) {
      _lastDetection = now;
      debugPrint('[WakeWord] DETECTED (score=${score.toStringAsFixed(3)})');
      // The suspension the callback is about to take must start cold — see
      // [_resetBuffers].
      _poisonBuffers();
      onDetected();
    }
  }

  /// Marks the feature buffers as holding a phrase that has already fired,
  /// so the next start clears them instead of re-scoring it.
  void _poisonBuffers() {
    _melFrames.clear();
    _embeddings.clear();
  }

  /// Records that the next [start] should keep whatever features the
  /// pipeline has, because the gap in audio was not caused by a detection.
  ///
  /// Called by [SttService] and by every screen that suspends around its own
  /// spoken flow — via [pauseAround]/[suspend], which is the only way in.
  void _markWarm() {
    // Nothing to keep if the pipeline was never running.
    _warmRestart = _melFrames.isNotEmpty || _embeddings.isNotEmpty;
  }

  /// [1, 1280] raw (unnormalized — NOT divided by 32768) float32 samples in
  /// -> flattened mel bins out, regrouped into 32-wide frames. openWakeWord
  /// itself feeds the model int16 magnitudes cast straight to float32; the
  /// output frame count depends on chunk size and isn't hardcoded here.
  List<List<double>> _runMelspectrogram(Int16List pcm) {
    final input = [pcm.map((s) => s.toDouble()).toList()];
    final flat = _invokeAndReadFloats(_melInterpreter!, [input]);
    final frames = <List<double>>[];
    for (var i = 0; i + _melBins <= flat.length; i += _melBins) {
      frames.add(flat.sublist(i, i + _melBins));
    }
    return frames;
  }

  /// [1, 76, 32, 1] mel-frame window -> a single 96-dim embedding vector.
  List<double> _runEmbedding(List<List<double>> melWindow) {
    final input = [melWindow.map((frame) => frame.map((v) => [v]).toList()).toList()];
    return _invokeAndReadFloats(_embeddingInterpreter!, [input]);
  }

  /// [1, 16, 96] window of embeddings -> a single detection score (0-1).
  double _runWakeWordClassifier(List<List<double>> embeddingWindow) {
    final input = [embeddingWindow];
    final flat = _invokeAndReadFloats(_wakeWordInterpreter!, [input]);
    return flat.isNotEmpty ? flat.first : 0.0;
  }

  /// Runs inference, then reads the output tensor's raw bytes back as
  /// float32 directly — sidesteps needing to pre-construct a
  /// correctly-shaped Dart output container (whose exact rank isn't
  /// guaranteed identical to the shapes documented in openWakeWord's
  /// Python reference implementation) since every model in this pipeline
  /// has a single float32 output tensor.
  List<double> _invokeAndReadFloats(Interpreter interpreter, List<Object> inputs) {
    interpreter.runInference(inputs);
    final tensor = interpreter.getOutputTensor(0);
    final bytes = tensor.data;
    final floats = Float32List.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes ~/ 4);
    return List<double>.from(floats);
  }

  // ---- Test seams ---------------------------------------------------------

  /// The live mel-frame buffer, so a test can seed it and then assert
  /// whether a restart kept or cleared it. See [_resetBuffers].
  @visibleForTesting
  List<List<double>> get debugMelFrames => _melFrames;

  @visibleForTesting
  List<List<double>> get debugEmbeddings => _embeddings;

  @visibleForTesting
  bool get debugWillRestartWarm => _warmRestart;

  /// Drives the detection branch without needing the TFLite models — the
  /// only part of [_processChunk] a test can reach off-device.
  @visibleForTesting
  void debugSimulateDetection() => _poisonBuffers();
}

/// The real recorder. Config lives here rather than at each call site so the
/// wake word and Cloud STT cannot drift apart on echo cancellation, which
/// they must agree on — see the comment inside.
class _RecordAudioSource implements WakeWordAudioSource {
  final AudioRecorder _recorder = AudioRecorder();

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<Stream<Uint8List>> startStream() => _recorder.startStream(
        // See `CloudSttService`'s identical config for why — the assistant's
        // own spoken replies can play while this is still listening in the
        // background (wake-word pausing is only coordinated around actual
        // STT sessions, not every TTS utterance), so the same
        // hearing-its-own-voice risk applies here too.
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: WakeWordService.sampleRate,
          numChannels: 1,
          echoCancel: true,
          noiseSuppress: true,
          // The wake word does not participate in audio focus. This is the
          // whole bug behind "Hey ANT answers once and then never again",
          // caught on device 10 September:
          //
          //   requestAudioFocus() USAGE_MEDIA req=1   <- audioplayers, our TTS
          //   onAudioFocusChange(-1) -> record's AudioSessionManager
          //   ...no AudioRecord data, ever again
          //
          // `req=1` is AUDIOFOCUS_GAIN, a *permanent* grab, so Android sends
          // the recorder AUDIOFOCUS_LOSS rather than a transient one — and
          // `record` stops the recording on all three loss codes alike, so
          // ducking would not have helped. The assistant speaking its own
          // reply killed its own microphone, and nothing restored it short
          // of relaunching the app.
          //
          // `none` is the only mode that skips registering the focus
          // listener at all (see `AudioSessionManager.startSession`). It is
          // also the correct behaviour on its own terms: a wake-word
          // detector's entire job is to keep listening *through* other
          // audio, including this app's own voice, which is what
          // `echoCancel` above is for.
          //
          // Deliberately not applied to `CloudSttService`: pausing a
          // dictation session when something else takes the speakers is
          // ordinary, expected behaviour for a session the user started.
          audioInterruption: AudioInterruptionMode.none,
        ),
      );

  @override
  Future<void> stop() => _recorder.stop();

  @override
  Future<void> dispose() => _recorder.dispose();
}
