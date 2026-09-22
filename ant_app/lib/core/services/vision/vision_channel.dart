import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The Dart end of Module 6's physical trigger — plan Step 1.1, "presses a
/// physical volume button mapped to the Sweep action".
///
/// Listen-only. Nothing here ever calls into the platform; `MainActivity`
/// pushes `sweepHeld` when Volume Up has been held for two seconds, and that
/// is the entire protocol. See `MainActivity.SWEEP_HOLD_MS` for why it is a
/// two-second hold on Volume Up rather than a press, a double-press, or
/// Volume Down (which Module 9 owns and must not share a meaning with).
///
/// Separate from `EmergencyChannel` rather than folded into it because a
/// single channel with two unrelated inbound methods would mean the Magic
/// Button and the camera share a handler — and `setMethodCallHandler`
/// replaces rather than adds, so whichever registered second would silently
/// take the other's events. That is a failure mode worth a second channel.
class VisionChannel {
  VisionChannel({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('com.ant.assistive.ant_app/vision');

  final MethodChannel _channel;

  /// Registers [handler], called when Volume Up has been held long enough.
  ///
  /// The handler is deliberately not awaited by the platform: a sweep takes
  /// seconds and blocking the platform channel for that long would stall the
  /// key events the same activity is still delivering.
  void onSweepTrigger(Future<void> Function() handler) {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'sweepHeld') return;
      debugPrint('[Vision] sweep triggered by volume-up hold');
      try {
        await handler();
      } catch (e) {
        // A throw here would cross the platform boundary as an unhandled
        // channel error and take nothing useful with it. Every other failure
        // in this module resolves to a spoken sentence; this one is logged
        // and dropped, because by the time it fires the handler has already
        // said whatever it could.
        debugPrint('[Vision] sweep handler failed: $e');
      }
    });
  }

  /// Stops listening. Safe to call when nothing is registered.
  void dispose() => _channel.setMethodCallHandler(null);
}
