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

  Future<void> start() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod('start');
      debugPrint('[BackgroundListening] foreground service started');
    } catch (e) {
      debugPrint('[BackgroundListening] start failed: $e');
    }
  }

  Future<void> stop() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod('stop');
      debugPrint('[BackgroundListening] foreground service stopped');
    } catch (e) {
      debugPrint('[BackgroundListening] stop failed: $e');
    }
  }
}
