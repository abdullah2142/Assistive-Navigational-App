import 'dart:async';

/// A `Future.delayed` a widget can take back when it is disposed.
///
/// The app's voice screens are all built on the same shape: narrate, wait a
/// beat, listen, repeat for as long as the screen is up. The waits are real
/// and necessary — [SttService.narrationSettle] keeps the recorder from
/// transcribing the tail of the prompt that just played, and the 400 ms
/// between listen attempts keeps a recognizer that cannot start from
/// spinning the CPU flat.
///
/// A bare `Future.delayed` in one of those loops outlives the widget. The
/// loop's own `mounted` check retires it on the far side of the await, so it
/// never touches a dead widget — but the *timer* is still armed and still
/// pointing at that closure when the tree is torn down. On a device that is
/// a leak nobody sees; in a widget test it is a hard failure ("A Timer is
/// still pending even after the widget tree was disposed"), which is how
/// this was found.
///
/// Usage: hold one per State, `await`/check in the loop, cancel in `dispose`.
///
/// ```dart
/// final _delay = CancellableDelay();
///
/// Future<void> _loop() async {
///   while (mounted) {
///     await _speak(prompt);
///     if (!await _delay.wait(SttService.narrationSettle)) return;
///     await _stt.listenOnce(...);
///   }
/// }
///
/// @override
/// void dispose() {
///   _delay.cancel();
///   super.dispose();
/// }
/// ```
class CancellableDelay {
  /// Every wait currently in flight. Each gets its own timer and completer
  /// rather than the class holding a single `_timer`: the picker can have
  /// two loops running at once (a re-prompt started from inside a listen
  /// callback, while the outer loop is still awaiting that same session),
  /// and a single-slot field would strand whichever one it overwrote.
  final Map<Timer, Completer<bool>> _pending = {};

  bool _cancelled = false;

  /// Whether [cancel] has been called.
  bool get isCancelled => _cancelled;

  /// Waits [duration].
  ///
  /// Completes `true` when the time actually elapsed, and `false` if
  /// [cancel] ran first — or had already run before this was called, so a
  /// loop that is mid-`await` somewhere else when the widget dies does not
  /// get to arm a fresh timer on its way out. Callers treat `false` as
  /// "stop": `if (!await delay.wait(...)) return;`.
  Future<bool> wait(Duration duration) {
    if (_cancelled) return Future.value(false);
    final completer = Completer<bool>();
    late final Timer timer;
    timer = Timer(duration, () {
      _pending.remove(timer);
      if (!completer.isCompleted) completer.complete(true);
    });
    _pending[timer] = completer;
    return completer.future;
  }

  /// Cancels every in-flight wait and makes all future ones no-ops.
  ///
  /// Sticky by design — this is called from `dispose`, and a disposed widget
  /// never wants a delay again. Safe to call more than once.
  void cancel() {
    _cancelled = true;
    // Copied before iterating: completing a waiter can synchronously run
    // code that starts another wait, which would mutate `_pending`.
    final pending = Map<Timer, Completer<bool>>.from(_pending);
    _pending.clear();
    for (final entry in pending.entries) {
      entry.key.cancel();
      if (!entry.value.isCompleted) entry.value.complete(false);
    }
  }
}
