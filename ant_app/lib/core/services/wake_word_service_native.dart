import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

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
  /// Built on first use, not on construction.
  ///
  /// The recorder reaches its platform plugin the moment it exists, so an
  /// eager field meant simply *having* this service required a working mic
  /// plugin — it allocated one for every user including those who never turn
  /// the wake word on, and made the coordination logic untestable off-device.
  late final AudioRecorder _recorder = AudioRecorder();

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
  static const double detectionThreshold = 0.5;
  static const Duration _cooldown = Duration(seconds: 2);

  bool get isListening => _audioSub != null;

  void Function()? _lastOnDetected;

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
  bool _resumeWhenReleased = false;

  /// Suspends wake-word listening for the duration of [action].
  ///
  /// Centralizes a fix that used to live duplicated (and, in one real case,
  /// forgotten) in each caller of [SttService.listenOnce]: two separate
  /// audio-capture sessions — this service's own continuous
  /// [AudioRecorder] stream and Android's `SpeechRecognizer` — fighting
  /// over the microphone at the same time. Confirmed live in more than one
  /// place: the classifier's score would flatline to an exact `0.000` (not
  /// even background-noise variance) after the recognizer grabbed the mic
  /// mid-listen, and the *reverse* — starting a manual push-to-talk session
  /// while this service was still actively listening — could cut the STT
  /// session off before a word was even transcribed. [SttService] now
  /// calls this around every `listenOnce`, so any caller gets the
  /// coordination for free without needing to know wake-word exists at all.
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
    if (isListening) {
      _resumeWhenReleased = true;
      await stop();
    }
  }

  Future<void> _releaseSuspend() async {
    _suspendDepth--;
    // Still held by an outer flow — leave the microphone alone.
    if (_suspendDepth > 0) return;
    _suspendDepth = 0;
    if (!_resumeWhenReleased || _lastOnDetected == null) return;
    _resumeWhenReleased = false;
    // Brief handoff gap: reclaiming the mic immediately after the other
    // session ends raced Android's own audio-session teardown on device —
    // see the doc comment above for what that looked like.
    await Future.delayed(const Duration(milliseconds: 500));
    // A new suspension may have been taken during that delay.
    if (_suspendDepth > 0) {
      _resumeWhenReleased = true;
      return;
    }
    await start(onDetected: _lastOnDetected!);
  }

  Future<bool> _ensureModelsLoaded() async {
    if (_modelsLoaded) return true;
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
  Future<bool> start({required void Function() onDetected}) async {
    _lastOnDetected = onDetected;
    if (isListening) return true;
    if (!await _ensureModelsLoaded()) return false;
    if (!await _recorder.hasPermission()) {
      debugPrint('[WakeWord] mic permission not granted');
      return false;
    }

    _pendingBytes.clear();
    _melFrames.clear();
    _embeddings.clear();
    // Reset the detection cooldown too. Without this, a restart that lands
    // inside the cooldown window from the *previous* session's detection
    // silently swallows the next wake word — the one case where "it worked
    // once and then stopped" is exactly what the user would see.
    _lastDetection = null;
    _lastScoreLog = null;
    _peakSinceLog = 0;

    final stream = await _recorder.startStream(
      // See `CloudSttService`'s identical config for why — the assistant's
      // own spoken replies can play while this is still listening in the
      // background (wake-word pausing is only coordinated around actual
      // STT sessions, not every TTS utterance), so the same
      // hearing-its-own-voice risk applies here too.
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: 1,
        echoCancel: true,
        noiseSuppress: true,
      ),
    );
    _audioSub = stream.listen((bytes) => _onAudioBytes(bytes, onDetected));
    debugPrint('[WakeWord] listening started (restart-safe: buffers and cooldown cleared)');
    return true;
  }

  Future<void> stop() async {
    await _audioSub?.cancel();
    _audioSub = null;
    try {
      await _recorder.stop();
    } catch (_) {
      // Already stopped — fine.
    }
  }

  Future<void> dispose() async {
    await stop();
    _melInterpreter?.close();
    _embeddingInterpreter?.close();
    _wakeWordInterpreter?.close();
    await _recorder.dispose();
  }

  void _onAudioBytes(Uint8List bytes, void Function() onDetected) {
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
      onDetected();
    }
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
}
