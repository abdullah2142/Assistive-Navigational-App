import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Outcome of one dispatch attempt, per recipient.
@immutable
class SmsDispatchResult {
  const SmsDispatchResult({required this.delivered, required this.failed});

  /// Numbers the platform accepted for sending.
  final List<String> delivered;

  /// Numbers it refused, with the platform's reason.
  final Map<String, String> failed;

  bool get anyDelivered => delivered.isNotEmpty;

  static const none = SmsDispatchResult(delivered: [], failed: {});
}

/// The two capabilities this feature needs, checked separately.
///
/// Separately because they fail separately and cost separately: a user who
/// refuses CALL_PHONE — the scarier-sounding of the two — should still have
/// their family texted.
enum EmergencyPermission { sms, call }

/// Thin wrapper over the native emergency bridge.
///
/// Every method degrades instead of throwing. This is the one code path in
/// the app where an unhandled exception is unacceptable: it runs when
/// something has already gone wrong for the user, and a crash here means
/// nobody is told. So a missing platform, a denied permission and a dead
/// telephony stack all come back as a value the caller can act on, and the
/// caller carries on to the next escalation step.
class EmergencyChannel {
  EmergencyChannel({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('com.ant.assistive.ant_app/emergency');

  final MethodChannel _channel;

  /// Called when the user holds Volume Down for three seconds.
  void onPhysicalTrigger(Future<void> Function() handler) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'sosHeld') await handler();
    });
  }

  Future<bool> hasPermission(EmergencyPermission which) async {
    try {
      return await _channel.invokeMethod<bool>('hasPermission', {'which': which.name}) ?? false;
    } catch (e) {
      debugPrint('[Emergency] hasPermission(${which.name}) failed: $e');
      return false;
    }
  }

  Future<void> requestPermissions() async {
    try {
      await _channel.invokeMethod<void>('requestPermissions');
    } catch (e) {
      debugPrint('[Emergency] requestPermissions failed: $e');
    }
  }

  /// Battery percentage, or null when the platform will not say.
  ///
  /// Null rather than a guess: the number tells a recipient how long the
  /// phone will keep reporting its location, and a wrong one is worse than
  /// none.
  Future<int?> batteryPercent() async {
    try {
      return await _channel.invokeMethod<int>('batteryPercent');
    } catch (e) {
      debugPrint('[Emergency] batteryPercent failed: $e');
      return null;
    }
  }

  Future<SmsDispatchResult> sendSms({
    required List<String> recipients,
    required List<String> messages,
  }) async {
    if (recipients.isEmpty || messages.isEmpty) return SmsDispatchResult.none;
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>('sendSms', {
        'recipients': recipients,
        'messages': messages,
      });
      final delivered = (raw?['delivered'] as List?)?.cast<String>() ?? const <String>[];
      final failed = (raw?['failed'] as Map?)?.map((k, v) => MapEntry('$k', '$v')) ?? <String, String>{};
      return SmsDispatchResult(delivered: delivered, failed: failed);
    } catch (e) {
      debugPrint('[Emergency] sendSms failed: $e');
      // Every recipient failed for the same reason — reported per-number so
      // the caller's "who was reached" logic has one shape to handle.
      return SmsDispatchResult(
        delivered: const [],
        failed: {for (final r in recipients) r: '$e'},
      );
    }
  }

  Future<bool> placeCall(String number) async {
    if (number.trim().isEmpty) return false;
    try {
      return await _channel.invokeMethod<bool>('placeCall', {'number': number}) ?? false;
    } catch (e) {
      debugPrint('[Emergency] placeCall failed: $e');
      return false;
    }
  }
}
