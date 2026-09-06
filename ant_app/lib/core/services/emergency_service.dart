import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

import '../localization/app_language.dart';
import '../localization/dashboard_strings.dart';
import '../../features/guardian/models/guardian_alert.dart';
import '../../features/guardian/services/alert_service.dart';
import '../../features/onboarding/models/user_profile.dart';
import 'emergency_channel.dart';
import 'emergency_payload.dart';
import 'emergency_plan.dart';
import 'stt_service.dart';
import 'tts_service.dart';
import 'voice_cancel_window.dart';

/// What happened, for logging and for the caller to speak.
@immutable
class EmergencyOutcome {
  const EmergencyOutcome({
    required this.cancelled,
    this.messaged = const [],
    this.failed = const {},
    this.called,
    this.alerted = false,
    this.reason,
  });

  final bool cancelled;
  final List<String> messaged;
  final Map<String, String> failed;
  final String? called;
  final bool alerted;

  /// Why nothing was sent, when nothing was.
  final String? reason;

  bool get reachedAnyone => messaged.isNotEmpty;
}

/// The Magic Button.
///
/// ## Ordering, and why it is this order
///
/// Every step is attempted even if the one before it failed, and the order
/// is by how likely each is to work when things have gone wrong:
///
/// 1. **Speak first.** Before anything is sent, so the user knows the phone
///    understood them and can stop holding it, shout again, or run.
/// 2. **SMS.** Cellular, so it survives the data outage that is one of the
///    reasons someone is in trouble in the first place.
/// 3. **Call the primary contact.** A ringing phone gets answered when a
///    text does not.
/// 4. **Write the Caretaker alert.** Needs data, so it goes last — it is
///    the step most likely to fail and the least costly to lose.
///
/// A failure at any step is spoken, never swallowed. A user who believes
/// help is coming and stops trying to get it themselves is in a worse
/// position than one who knows the phone could not reach anyone.
///
/// ## The cancel window
///
/// A false trigger messages and rings the user's family, so there is one —
/// but it defaults to **proceeding**, not to asking. Requiring a confirmed
/// "yes" would mean an unconscious or panicking user is never helped, and
/// yes/no is the least reliable thing to recognise in noise. Silence sends.
class EmergencyService {
  EmergencyService({
    required TtsService tts,
    required SttService stt,
    required AlertService alerts,
    EmergencyChannel? channel,
  })  : _tts = tts,
        _stt = stt,
        _alerts = alerts,
        _channel = channel ?? EmergencyChannel();

  final TtsService _tts;
  final SttService _stt;
  final AlertService _alerts;
  final EmergencyChannel _channel;

  /// Guards against a second trigger while one is already running.
  ///
  /// The volume hold and a shouted "help me" very plausibly happen within
  /// seconds of each other — the same person asking twice, not asking for
  /// twice as much help. Without this they would each send a full round of
  /// messages.
  bool _running = false;
  bool get isRunning => _running;

  /// Runs the whole escalation.
  ///
  /// [confirm] false skips the cancel window entirely — used when the user
  /// triggers again while one is already counting down, which is as clear a
  /// statement of intent as this app will ever get.
  Future<EmergencyOutcome> trigger({
    required UserProfile profile,
    bool confirm = true,
  }) async {
    if (_running) {
      debugPrint('[Emergency] already running; ignoring repeat trigger');
      return const EmergencyOutcome(cancelled: false, reason: 'already running');
    }
    _running = true;
    try {
      return await _run(profile, confirm);
    } finally {
      _running = false;
    }
  }

  Future<EmergencyOutcome> _run(UserProfile profile, bool confirm) async {
    final d = Dashboard.of(profile.language);
    final recipients = EmergencyPlan.smsRecipients(profile.magicButtonContacts);
    final callTarget = EmergencyPlan.callTarget(profile.magicButtonContacts);

    // Said before any check, because the user is waiting to know whether the
    // phone heard them at all.
    await _speak(d.emergencyActivated, profile.language);
    unawaited(_signalTriggered());

    if (recipients.isEmpty && callTarget == null) {
      await _speak(d.emergencyNoContacts, profile.language);
      return const EmergencyOutcome(cancelled: false, reason: 'no contacts');
    }

    if (confirm) {
      final outcome = await VoiceCancelWindow.run(
        tts: _tts,
        stt: _stt,
        language: profile.language,
        readBack: d.emergencyAbout(recipients.length, VoiceCancelWindow.window.inSeconds),
        isCancelled: () => false,
      );
      if (outcome != CancelWindowOutcome.proceed) {
        await _speak(d.emergencyCancelled, profile.language);
        return const EmergencyOutcome(cancelled: true);
      }
    }

    // Gathered in parallel and never allowed to hold the dispatch up: a
    // message with no location still tells someone that something is wrong
    // and who it is, which is most of its value.
    final position = await _position();
    final battery = await _channel.batteryPercent();

    if (!await _channel.hasPermissions()) {
      await _channel.requestPermissions();
      if (!await _channel.hasPermissions()) {
        await _speak(d.emergencyNoPermission, profile.language);
        return const EmergencyOutcome(cancelled: false, reason: 'permissions denied');
      }
    }

    final messages = EmergencyPayload.messages(
      language: profile.language,
      name: profile.displayName,
      lat: position?.latitude,
      lng: position?.longitude,
      batteryPercent: battery,
    );

    final sms = await _channel.sendSms(recipients: recipients, messages: messages);
    await _speak(
      sms.anyDelivered ? d.emergencySent(sms.delivered.length) : d.emergencyNotSent,
      profile.language,
    );

    String? called;
    if (callTarget != null) {
      final name = profile.magicButtonContacts
          .firstWhere(
            (c) => EmergencyPlan.normalise(c.phoneNumber) == callTarget,
            orElse: () => profile.magicButtonContacts.first,
          )
          .name;
      await _speak(d.emergencyCalling(name), profile.language);
      if (await _channel.placeCall(callTarget)) called = callTarget;
    }

    // Last, because it needs data — the thing most likely to be missing.
    var alerted = false;
    if (profile.pairedUserId != null) {
      alerted = await _alerts.createAlert(
        disabledUserUid: profile.uid,
        type: GuardianAlertType.magicButton,
        lat: position?.latitude,
        lng: position?.longitude,
        batteryPercent: battery,
        notifiedContacts: sms.delivered,
      );
      if (position != null) {
        unawaited(_alerts.publishLocation(
          disabledUserUid: profile.uid,
          lat: position.latitude,
          lng: position.longitude,
        ));
      }
    }

    return EmergencyOutcome(
      cancelled: false,
      messaged: sms.delivered,
      failed: sms.failed,
      called: called,
      alerted: alerted,
    );
  }

  /// A long, unmistakable burst — distinct from every other pattern in the
  /// app, because this one means something irreversible is happening.
  Future<void> _signalTriggered() async {
    for (var i = 0; i < 4; i++) {
      await HapticFeedback.heavyImpact();
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
  }

  Future<void> _speak(String text, AppLanguage language) async {
    try {
      await _tts.speak(text, language: language);
    } catch (e) {
      // Losing the voice must not stop the messages going out.
      debugPrint('[Emergency] speak failed: $e');
    }
  }

  /// A fix, or null. Bounded, because an emergency cannot wait for a good
  /// one — a message with a rough position beats a better one that arrives
  /// after the phone is gone.
  Future<Position?> _position() async {
    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 8),
        ),
      );
    } catch (e) {
      debugPrint('[Emergency] no position: $e');
      try {
        // A stale fix is still a place to start looking.
        return await Geolocator.getLastKnownPosition();
      } catch (_) {
        return null;
      }
    }
  }
}
