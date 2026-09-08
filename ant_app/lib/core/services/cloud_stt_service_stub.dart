import '../localization/app_language.dart';

/// Web (and any other platform without `dart:io`) fallback for
/// [CloudSttService] — the underlying `grpc` package needs a real HTTP/2
/// connection `dart:io` provides, which isn't available on the web target.
/// Degrades the same way `WakeWordService`'s web stub does: `start()`
/// always reports unavailable, and callers already know to fall back to
/// on-device `SttService` when that happens.
class CloudSttService {
  bool get isListening => false;

  Future<bool> start({
    required AppLanguage language,
    required void Function(String text, bool isFinal) onResult,
    /// Never called here — this stub reports unavailable before any stream
    /// exists. Present so the two implementations stay interchangeable.
    void Function(Object error)? onStreamError,
  }) async =>
      false;

  Future<void> stop() async {}

  Future<void> dispose() async {}
}
