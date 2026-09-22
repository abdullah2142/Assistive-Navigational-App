import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import '../config/emergency_config.dart';
import '../localization/app_language.dart';
import '../localization/dashboard_strings.dart';
import '../../features/guardian/models/guardian_alert.dart';
import '../../features/guardian/services/alert_service.dart';
import '../../features/onboarding/models/user_profile.dart';
import 'emergency_channel.dart';
import 'emergency_payload.dart';
import 'emergency_plan.dart';
import 'route_planning_service.dart';
import 'routing_service.dart';
import 'safe_haven_finder.dart';
import 'stt_service.dart';
import 'tts_service.dart';
import 'voice_cancel_window.dart';

// The named parameters below are deliberately not initializing formals:
// they are named for the caller ('store', 'tts') while the fields are
// private ('_store', '_tts'), which is the convention across this
// codebase and what makes the constructors readable at the call site.
// ignore_for_file: prefer_initializing_formals

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
    this.haven,
  });

  final bool cancelled;
  final List<String> messaged;
  final Map<String, String> failed;
  final String? called;
  final bool alerted;

  /// Where they were sent, when anywhere.
  final String? haven;

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
    RoutingService? routing,
    RoutePlanningService? planner,
    void Function(RouteChoice route, AppLanguage language)? onRoute,
  })  : _tts = tts,
        _stt = stt,
        _alerts = alerts,
        _channel = channel ?? EmergencyChannel(),
        _routing = routing ?? RoutingService(),
        _planner = planner ?? RoutePlanningService(),
        _onRoute = onRoute;

  final TtsService _tts;
  final SttService _stt;
  final AlertService _alerts;
  final EmergencyChannel _channel;
  final RoutingService _routing;
  final RoutePlanningService _planner;

  /// Hands a planned escape route back to whatever is driving navigation.
  ///
  /// A callback rather than a Riverpod read, so this service stays
  /// constructible and testable without a container — it is the one thing
  /// in the app that most needs to be exercisable in isolation.
  final void Function(RouteChoice route, AppLanguage language)? _onRoute;

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
        emergency: true,
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

    // Rehearsal stops here, deliberately *after* everything that is worth
    // getting human feedback on — the announcement, the haptics, the cancel
    // window, the contact selection — and before the only step that cannot
    // be undone.
    //
    // Above the permission check on purpose: asking a tester to grant "send
    // SMS and make phone calls" for a build that will never do either is a
    // prompt with no honest answer, and a denied prompt would then mask the
    // rehearsal behind a permissions error. See `EmergencyConfig`.
    if (EmergencyConfig.isRehearsal) {
      await _speak(d.emergencyRehearsal(recipients.length), profile.language);
      return EmergencyOutcome(
        cancelled: false,
        reason: 'rehearsal — live dispatch disabled in this build',
        messaged: const [],
      );
    }

    // Permissions are checked per-capability, and never all-or-nothing.
    //
    // Two defects lived here. `hasPermissions()` required SEND_SMS *and*
    // CALL_PHONE, so a user who allowed texting but refused calling — the
    // scarier of the two, and the one most likely to be refused — got no
    // message sent at all. And the recovery path asked for permission and
    // re-read the answer in the same breath, while the system dialog was
    // still animating in, so it always saw "no" and abandoned the whole
    // escalation: the first genuine emergency after install could never
    // send anything.
    //
    // Now each capability stands alone, and a missing one costs only the
    // step it belongs to. The request is still fired — the answer arrives
    // too late for this run, but it means the *next* one works — and this
    // run proceeds with whatever it already has.
    final canSms = await _channel.hasPermission(EmergencyPermission.sms);
    final canCall = await _channel.hasPermission(EmergencyPermission.call);
    if (!canSms || !canCall) {
      unawaited(_channel.requestPermissions());
    }
    if (!canSms && !canCall) {
      await _speak(d.emergencyNoPermission, profile.language);
      return const EmergencyOutcome(cancelled: false, reason: 'permissions denied');
    }

    final messages = EmergencyPayload.messages(
      language: profile.language,
      name: profile.displayName,
      lat: position?.latitude,
      lng: position?.longitude,
      batteryPercent: battery,
    );

    final sms = canSms
        ? await _channel.sendSms(recipients: recipients, messages: messages)
        : SmsDispatchResult.none;
    await _speak(
      sms.anyDelivered ? d.emergencySent(sms.delivered.length) : d.emergencyNotSent,
      profile.language,
    );

    String? called;
    if (callTarget != null && canCall) {
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

    // Last of all, and never allowed to fail the run: getting them moving
    // matters less than having been heard, and everything above has already
    // happened by now.
    SafeHaven? haven;
    try {
      haven = await _routeToSafety(profile, position, d);
    } catch (e) {
      debugPrint('[Emergency] safe haven routing failed: $e');
    }

    return EmergencyOutcome(
      cancelled: false,
      messaged: sms.delivered,
      failed: sms.failed,
      called: called,
      alerted: alerted,
      haven: haven?.label,
    );
  }

  /// Step 3 of the module plan: get them somewhere safer.
  ///
  /// Runs after the messages and the call, never before. Being *found*
  /// matters more than moving, and the contacts already have the position
  /// this started from — so if this step fails, nothing that mattered has
  /// been lost.
  ///
  /// Three outcomes, in descending order of usefulness, and the third is a
  /// real answer rather than a failure:
  ///
  /// 1. A route to a haven, with turn-by-turn as normal.
  /// 2. No route (no data, no route found) but a known haven — a compass
  ///    direction and a distance, which a person can still act on.
  /// 3. Nowhere to go — say so, and say to stay put, because moving makes
  ///    someone harder to find and their contacts were told where they were.
  Future<SafeHaven?> _routeToSafety(
    UserProfile profile,
    Position? position,
    Dashboard d,
  ) async {
    if (position == null) return null;
    final origin = LatLng(position.latitude, position.longitude);

    // Discovery is best-effort and time-boxed inside `nearbyRefuges`. A
    // saved place outranks anything it finds anyway (see `SafeHavenFinder`),
    // so this is skipped entirely when the user already has one — no reason
    // to make someone wait on a network call whose answer cannot win.
    var discovered = const <SafeHaven>[];
    // Ask the ranker what it would actually accept, rather than guessing.
    // Testing `isRoutable` across *all* saved places suppressed discovery
    // for a user whose only saved places were work and school — which the
    // ranker then discards as non-refuges, leaving them told to stay put
    // next to a hospital.
    final hasOwnPlace = SafeHavenFinder.rank(
          origin: origin,
          savedPlaces: profile.savedPlaces,
          statedSafePlace: profile.safePlaceAddress,
        ).isNotEmpty;
    if (!hasOwnPlace) {
      final nearby = await _routing.nearbyRefuges(origin: origin);
      discovered = [
        for (final n in nearby)
          SafeHaven(label: n.name, source: HavenSource.discovered, location: n.location),
      ];
    }

    final haven = SafeHavenFinder.best(
      origin: origin,
      savedPlaces: profile.savedPlaces,
      statedSafePlace: profile.safePlaceAddress,
      discovered: discovered,
    );
    if (haven == null) {
      await _speak(d.havenStayPut, profile.language);
      return null;
    }

    // A stated safe place is only a string; everything else already has
    // coordinates and needs no network to be useful.
    var location = haven.location;
    if (location == null && haven.address != null) {
      location = await _routing.geocode(haven.address!);
    }
    if (location == null) {
      await _speak(d.havenStayPut, profile.language);
      return null;
    }

    final plan = await _planner.plan(
      destinationQuery: haven.address ?? haven.label,
      origin: origin,
      knownDestination: location,
      destinationLabel: haven.label,
    );

    if (plan is RoutePlanned) {
      await _speak(d.havenRouting(haven.label), profile.language);
      _onRoute?.call(plan.choice, profile.language);
      return haven;
    }

    // No route — but we know where it is, so say which way and how far.
    // Deliberately a compass bearing rather than left/right, which would
    // require knowing which way the user is facing.
    final metres = SafeHavenFinder.metresBetween(origin, location);
    final bearing = SafeHavenFinder.bearingDegrees(origin, location);
    final compass = d.compassPoints[SafeHavenFinder.compassIndex(bearing)];
    await _speak(
      d.havenDirection(
        label: haven.label,
        compass: compass,
        metres: (metres / 10).round() * 10,
      ),
      profile.language,
    );
    return haven;
  }

  /// A long, unmistakable burst — distinct from every other pattern in the
  /// app, because this one means something irreversible is happening.
  Future<void> _signalTriggered() async {
    for (var i = 0; i < 4; i++) {
      await HapticFeedback.heavyImpact();
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
  }

  /// How long any single announcement may take before the run moves on.
  ///
  /// `TtsService` awaits speech completion, and that completion callback is
  /// known not to fire when audio focus is lost mid-utterance — an incoming
  /// call, a Bluetooth handoff. Without a bound, one such utterance leaves
  /// `_running` true forever and every later trigger is silently refused:
  /// the Magic Button would stop working for the rest of the session, with
  /// no symptom until someone needed it.
  static const Duration _speakBudget = Duration(seconds: 12);

  Future<void> _speak(String text, AppLanguage language) async {
    try {
      await _tts.speak(text, language: language).timeout(_speakBudget);
    } catch (e) {
      // Losing the voice must not stop the messages going out.
      debugPrint('[Emergency] speak failed or timed out: $e');
    }
  }

  /// A fix, or null. Bounded, because an emergency cannot wait for a good
  /// one — a message with a rough position beats a better one that arrives
  /// after the phone is gone.
  static const Duration _positionBudget = Duration(seconds: 8);

  Future<Position?> _position() async {
    try {
      // Bounded in Dart as well as in the plugin, and both are needed.
      // `LocationSettings.timeLimit` is enforced by the platform side, so it
      // only helps while the platform is answering — if the channel itself
      // never replies, nothing is watching the clock and this never completes.
      // Found while fixing the hazard hub, where the same shape stalled a
      // report before the write was ever attempted; here it would hold up an
      // emergency, which is worse.
      //
      // One bound around both attempts, not one each: chained timeouts make
      // the worst case their sum, and this is the path where somebody is
      // waiting for a message to go out.
      return await _freshOrLastKnownPosition().timeout(_positionBudget);
    } catch (e) {
      debugPrint('[Emergency] no position: $e');
      return null;
    }
  }

  Future<Position?> _freshOrLastKnownPosition() async {
    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: _positionBudget,
        ),
      );
    } catch (e) {
      debugPrint('[Emergency] no fresh fix: $e');
      // A stale fix is still a place to start looking.
      return Geolocator.getLastKnownPosition();
    }
  }
}
