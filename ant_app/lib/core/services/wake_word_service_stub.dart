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
  bool get isListening => false;

  Future<bool> start({required void Function() onDetected}) async => false;

  Future<void> stop() async {}

  Future<void> dispose() async {}

  /// Nestable, like the native one — there is nothing to suspend here, so
  /// depth does not need tracking.
  Future<T> pauseAround<T>(Future<T> Function() action) => action();

  void suspend() {}

  void resume() {}
}
