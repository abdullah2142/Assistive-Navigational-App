import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Starts/stops the native `WakeWordForegroundService` (Android only — see
/// its Kotlin doc comment for what it actually does) so the app's process
/// survives being backgrounded or the screen being locked, keeping whatever
/// wake-word listening `WakeWordService` already has running alive right
/// where it was instead of getting frozen or killed by the OS. A no-op
/// everywhere else (iOS/web don't get this yet) — checked via
/// `defaultTargetPlatform` rather than `dart:io`'s `Platform` so this class
/// stays importable from web builds without a conditional-export split.
class BackgroundListeningService {
  static const _channel = MethodChannel('com.ant.assistive.ant_app/background_listening');

  /// Whether the last [start] actually took.
  ///
  /// A failure here is not cosmetic: without the foreground service the
  /// process is frozen the moment the screen locks, taking the wake-word
  /// recorder with it — which is what "screen off doesn't work" looks like
  /// (open_bugs item 31). It used to be swallowed into a debugPrint with no
  /// other trace, so a refused start and a working one were indistinguishable
  /// from the outside.
  bool get isRunning => _running;
  bool _running = false;

  Future<void> start() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod('start');
      _running = true;
      debugPrint('[BackgroundListening] foreground service started');
    } catch (e) {
      _running = false;
      // Loud on purpose. The most likely cause is Android 12+ refusing a
      // foreground-service start from the background, and this is called on
      // `AppLifecycleState.paused` — the exact boundary that restriction
      // polices. See `MainActivity`'s handler, which names the exception.
      debugPrint('[BackgroundListening] FOREGROUND SERVICE DID NOT START: $e — '
          'wake word will stop working as soon as the screen is off');
    }
  }

  Future<void> stop() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod('stop');
      _running = false;
      debugPrint('[BackgroundListening] foreground service stopped');
    } catch (e) {
      debugPrint('[BackgroundListening] stop failed: $e');
    }
  }
}
