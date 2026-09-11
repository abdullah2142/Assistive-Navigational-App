import 'wake_word_audio_source.dart';

/// Web (and any other platform without `dart:io`) fallback for
/// [WakeWordService] — `tflite_flutter` is an FFI plugin (`dart:ffi`),
/// which doesn't exist on the web target at all, so the real
/// implementation can't even be imported there without breaking
/// compilation. This app's actual target platforms are Android/iOS (see
/// `project_master_plan.md`'s tech stack); web is only used as this
/// project's dev-testing convenience surface, so it degrades gracefully
/// here exactly like [SttService.ensureAvailable] does on a device with no
/// recognizer — `start()` always reports unavailable, callers already
/// handle that by falling back to push-to-talk.
class WakeWordService {
  /// Accepted and ignored, so the two implementations stay constructible
  /// through the same call — nothing on web has a recorder or models to
  /// substitute.
  WakeWordService({WakeWordAudioSource? audioSource, Future<bool> Function()? loadModels});

  static const double detectionThreshold = 0.3;

  bool get isListening => false;

  bool get isEnabled => false;

  int get suspendDepth => 0;

  Future<bool> start({required void Function() onDetected}) async => false;

  Future<void> stop() async {}

  Future<void> dispose() async {}

  /// Nestable, like the native one — there is nothing to suspend here, so
  /// depth does not need tracking.
  Future<T> pauseAround<T>(Future<T> Function() action) => action();

  void suspend() {}

  void resume() {}

  // ---- Parity with the native implementation ------------------------------
  //
  // `flutter analyze` resolves the conditional export to *this* file while
  // `flutter test` resolves it to the native one, so anything the native
  // class exposes has to exist here too or the analyzer reports errors for
  // code that compiles and passes. Inert on purpose — there is no recorder
  // and no feature pipeline on web to observe.

  static Duration restartHandoff = const Duration(milliseconds: 500);

  List<List<double>> get debugMelFrames => const [];

  List<List<double>> get debugEmbeddings => const [];

  bool get debugWillRestartWarm => false;

  void debugSimulateDetection() {}
}
