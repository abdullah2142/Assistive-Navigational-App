import 'package:flutter/foundation.dart';

/// Routes the recognizer's out-of-band stream death back to the code that
/// can do something about it — item 49.
///
/// ## What this is for
///
/// `google_speech`'s `EndlessStreamingService` can deliver one last buffered
/// gRPC response just after its internal controller has been closed, throwing
/// `Bad state: Cannot add new events after calling close` from inside the
/// package on its own zone. It does not propagate back through `stop()`'s
/// future and cannot be caught by any try/catch in this app, so
/// `main.dart`'s `PlatformDispatcher.onError` swallows it. Swallowing was the
/// right call — it is not fatal and there was nothing else to do with it.
///
/// **But it happened 37 times across three half-hour tester sessions**, and
/// reading those logs line by line says that is two different events wearing
/// one message:
///
/// - **28 of the 37** fired *after* the session had already ended cleanly and
///   the transcript had already gone to Gemini. Those cost nothing at all;
///   they are the tail of a stream nobody is waiting on.
/// - **9 of the 37** fired mid-utterance, with partial results still arriving
///   and no final ever delivered. Those cost the user whatever they were
///   saying — and worse, they leave `CloudSttService._listening` true and the
///   caller's `listenOnce` future pending forever, so the microphone stays
///   *shown as open* while being permanently deaf. The user gets no final
///   result, no error, and a red mic that means nothing.
///
/// That second case is very likely behind some of the standing "it didn't
/// hear me" reports, and it is the one this fixes: on a fault, the live
/// session is stopped properly, which completes the pending future and lets
/// the normal auto-listen and wake-word paths start a fresh one.
///
/// ## Why a bus rather than a direct call
///
/// The handler lives in `main()`, before any provider container exists, and
/// the thing that has to act is an `SttService` built by a provider much
/// later. Neither can reach the other directly.
class RecognizerFaults {
  RecognizerFaults._();

  static final RecognizerFaults instance = RecognizerFaults._();

  /// Visible for tests, which must not leak listeners between cases.
  @visibleForTesting
  static RecognizerFaults forTesting() => RecognizerFaults._();

  final _listeners = <void Function()>[];

  /// How many faults have been seen this session. Printed into the
  /// diagnostics log so the next tester round can measure this rather than
  /// counting log lines by hand, which is how it was found.
  int get faultCount => _faultCount;
  int _faultCount = 0;

  /// How many of those actually ended a live listening session.
  int get sessionsLost => _sessionsLost;
  int _sessionsLost = 0;

  /// Registers [onFault]; the returned callback removes it again.
  VoidCallback listen(void Function() onFault) {
    _listeners.add(onFault);
    return () => _listeners.remove(onFault);
  }

  /// Whether [error] is the recognizer's stream death rather than some other
  /// uncaught async error.
  ///
  /// Matched on the message because the type is `StateError` — far too broad
  /// to act on, and acting on the wrong error here would tear down a working
  /// microphone.
  static bool isDeadStream(Object error) =>
      error is StateError && error.message.contains('Cannot add new events after calling close');

  /// Called from the global error handler. Does nothing for anything else.
  void report(Object error) {
    if (!isDeadStream(error)) return;
    _faultCount++;
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }

  /// Recorded by whoever actually tore a session down, so the counts in the
  /// log distinguish the harmless tail from the lost utterance.
  void noteSessionLost() {
    _sessionsLost++;
    debugPrint('[Recognizer] stream fault ended a live session '
        '($_sessionsLost lost of $_faultCount faults this session)');
  }
}
