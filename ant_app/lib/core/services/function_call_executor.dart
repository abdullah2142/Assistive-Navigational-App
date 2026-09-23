import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import 'dart:async';

import '../../features/dashboard/models/hazard_report.dart';
import '../../features/guardian/models/guardian_alert.dart';
import '../../features/guardian/services/alert_service.dart';
import '../../features/guardian/services/communication_service.dart';
import '../../features/dashboard/models/suggested_chip.dart';
import '../../features/onboarding/models/disability_profile_enums.dart';
import '../../features/onboarding/models/saved_place.dart';
import '../../features/onboarding/models/trusted_contact.dart';
import '../../features/onboarding/models/user_profile.dart';
import '../../features/onboarding/services/pairing_service.dart';
import '../localization/app_language.dart';
import '../localization/dashboard_strings.dart';
import '../utils/text_scale_levels.dart';
import 'gemini_assistant_service.dart' show AssistantTurn;
import 'destination_clarifier.dart';
import 'route_planning_service.dart';
import 'route_safety_service.dart';
import 'routing_service.dart' show RouteCandidate;
import 'pending_place_save.dart';
import 'saved_place_matcher.dart';
import 'vision/vision_scene.dart' show ScanFocus;

class _AppliedCall {
  const _AppliedCall(
    this.profile,
    this.resultForModel,
    this.overlay, {
    this.route,
    this.routeAlternatives,
    this.hazardPrefill,
    this.clarification,
    this.placeSave,
    this.scanFocus,
    this.scanQuestion,
    this.triggersEmergency = false,
    this.cancelsRoute = false,
  });
  final UserProfile profile;
  final Map<String, Object?> resultForModel;
  final SuggestedChipAction? overlay;
  final RouteChoice? route;

  /// The routes still on the shelf after this call, or null when the call
  /// had nothing to say about routing. Null and empty mean different things:
  /// empty is "there are no others", which the assistant says out loud.
  final List<RouteCandidate>? routeAlternatives;
  final HazardReportPrefill? hazardPrefill;

  /// Set when the destination could not be pinned down and the assistant is
  /// now waiting on an answer — see [DestinationClarification].
  final DestinationClarification? clarification;

  /// Set when a save is waiting on a missing slot.
  final PendingPlaceSave? placeSave;

  /// Set when the model called `look_around` — Module 6. See
  /// [AssistantTurn.scanFocus] for why this is a request and not a result.
  final ScanFocus? scanFocus;

  /// The user's own wording, when they asked something more specific than
  /// the focus enum can express. See [AssistantTurn.scanQuestion].
  final String? scanQuestion;

  /// Set when the model called `trigger_emergency`.
  final bool triggersEmergency;

  /// Set when the model called `cancel_route`.
  ///
  /// A flag rather than an applied change, for the same reason as
  /// [triggersEmergency]: cancelling means stopping the narrator and clearing
  /// the route from chat state, and neither of those is this executor's to
  /// touch. The caller owns both and already has one implementation of it.
  final bool cancelsRoute;
}

/// What a function name + args actually *does* — profile mutation, overlay
/// trigger, or route planning — and the bilingual confirmation text for it.
/// Deliberately independent of Gemini/the SDK's `FunctionCall` type: this is
/// the single source of truth both `GeminiAssistantService` (when the model
/// decides to call one of these) and `LocalIntentMatcher` (when a plain
/// pattern match decides the same thing, without ever calling the model at
/// all) delegate to, so a setting change behaves identically — same
/// validation, same wording — regardless of which one triggered it.
///
/// Extracted from `GeminiAssistantService` specifically so the local-match
/// path can execute a function call without needing a configured Gemini API
/// key at all (`GeminiConfig.isConfigured == false` still works for these).
class FunctionCallExecutor {
  FunctionCallExecutor({
    PairingService? pairingService,
    RoutePlanningService? routePlanning,
    RouteSafetyService? routeSafety,
    AlertService? alertService,
    CommunicationService? communicationService,
    Future<Position?> Function()? freshLocation,
  })  : _injectedPairing = pairingService,
        _injectedRoutePlanning = routePlanning,
        _injectedRouteSafety = routeSafety,
        _injectedAlerts = alertService,
        _injectedCommunications = communicationService,
        _freshLocation = freshLocation ?? _defaultFreshLocation;

  final PairingService? _injectedPairing;
  final RoutePlanningService? _injectedRoutePlanning;
  final RouteSafetyService? _injectedRouteSafety;
  final AlertService? _injectedAlerts;
  final CommunicationService? _injectedCommunications;

  /// How to get a *current* fix, as opposed to the cached one every call is
  /// handed. Injectable so a test can answer without a platform channel.
  final Future<Position?> Function() _freshLocation;

  /// Beyond this, a cached fix is not an answer to "where am I".
  ///
  /// Every chat message is handed `Geolocator.getLastKnownPosition()` — a
  /// cheap cached fix, which is the right trade for almost everything here.
  /// It is the wrong one for this question. A walking user covers about 1.4
  /// metres a second, so a two-minute-old fix can be most of a block away,
  /// and confidently naming the wrong road to somebody who cannot check it
  /// against what they can see is worse than admitting we do not know.
  static const _cachedFixIsStaleAfter = Duration(seconds: 60);

  static Future<Position?> _defaultFreshLocation() async {
    try {
      // Dart-side timeout as well as the platform one. `LocationSettings.
      // timeLimit` is enforced platform-side and does nothing when the
      // channel itself is unresponsive — the trap four separate hangs in
      // this app have already come from.
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      ).timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('[Assistant] fresh location lookup failed: $e');
      return null;
    }
  }

  // Built on first use, not in the constructor. Each default reaches for
  // `FirebaseFirestore.instance`/`FirebaseFunctions.instance`, which throws
  // outright when no Firebase app has been initialized — so an eager field
  // makes this whole class unconstructible in that situation even for the
  // many function calls (every `update_setting`, both `open_*` overlays)
  // that never touch Firebase at all.
  late final PairingService _pairing = _injectedPairing ?? PairingService();
  late final RoutePlanningService _routePlanning = _injectedRoutePlanning ?? RoutePlanningService();
  late final RouteSafetyService _routeSafety = _injectedRouteSafety ?? RouteSafetyService();
  late final AlertService _alerts = _injectedAlerts ?? AlertService();
  late final CommunicationService _communications =
      _injectedCommunications ?? CommunicationService();

  Future<AssistantTurn> execute({
    required String name,
    required Map<String, Object?> args,
    required UserProfile profile,
    Position? location,
    RouteChoice? activeRoute,
    /// The unused alternatives from the route currently being walked — what
    /// `request_alternative_route` switches between. See [RoutePlanned].
    List<RouteCandidate> routeAlternatives = const [],
  }) async {
    final applied =
        await _applyFunctionCall(name, args, profile, location, activeRoute, routeAlternatives);
    final confirmation = _confirmationFor(name, args, applied.resultForModel, profile.language);
    return AssistantTurn(
      responseText: confirmation,
      updatedProfile: identical(applied.profile, profile) ? null : applied.profile,
      overlayAction: applied.overlay,
      route: applied.route,
      routeAlternatives: applied.routeAlternatives,
      hazardPrefill: applied.hazardPrefill,
      clarification: applied.clarification,
      placeSave: applied.placeSave,
      triggersEmergency: applied.triggersEmergency,
      cancelsRoute: applied.cancelsRoute,
    );
  }

  static const _settingLabelsEn = {
    'text_size': 'text size',
    'theme': 'theme',
    'language': 'language',
    'verbosity': 'reply style',
    'voice': 'voice',
    'vision_level': 'vision setting',
    'mobility_aid': 'mobility setting',
    'deaf_hearing_mode': 'hearing setting',
    'snapshot_consent': 'snapshot permission',
    'crowded_places_anxious': 'crowded-places setting',
    'complex_instructions_hard': 'instruction-style setting',
    'home_address': 'home address',
    'safe_place_address': 'safe place',
    'wake_word_enabled': '"Hey ANT" wake word',
    'voice_auto_listen': 'auto-listen for voice input',
  };

  static const _settingLabelsBn = {
    'text_size': 'লেখার আকার',
    'theme': 'রং',
    'language': 'ভাষা',
    'verbosity': 'কথা বলার ধরন',
    'voice': 'ভয়েস',
    'vision_level': 'চোখের সেটিং',
    'mobility_aid': 'চলাফেরার সেটিং',
    'deaf_hearing_mode': 'শোনার সেটিং',
    'snapshot_consent': 'ছবি তোলার অনুমতি',
    'crowded_places_anxious': 'ভিড়ের সেটিং',
    'complex_instructions_hard': 'নির্দেশের ধরন',
    'home_address': 'বাড়ির ঠিকানা',
    'safe_place_address': 'নিরাপদ জায়গা',
    'wake_word_enabled': '"Hey ANT" ভয়েস ট্রিগার',
    'voice_auto_listen': 'ভয়েস ইনপুটে নিজে থেকে শোনা',
  };

  /// Short, templated confirmation for a single executed function call —
  /// the client-side stand-in for the model's own phrasing (see the doc
  /// comment on `GeminiAssistantService.converse` for why this isn't
  /// Gemini-generated even on the LLM path).
  /// Appends Module 5's crowdsourced-hazard sentence to a route
  /// confirmation, when there is one to append.
  ///
  /// Confirmed (Red Flag) hazards come first and are never omitted — if the
  /// route still crosses one, no alternative existed, and walking a blind or
  /// wheelchair-using person into a hazard three people have independently
  /// reported without saying so is the worst thing this module could do.
  /// Only one hazard is named even when several are on the route: a spoken
  /// list is not something a user can hold onto while walking, and the
  /// nearest confirmed one is the one that matters first.
  String _withHazardNotice(String base, Map<String, Object?> result, AppLanguage language) {
    final d = Dashboard.of(language);
    final confirmed = (result['confirmedHazards'] as List<Object?>? ?? const []).cast<String>();
    final reported = (result['reportedHazards'] as List<Object?>? ?? const []).cast<String>();

    if (confirmed.isNotEmpty) {
      final label = d.hazardSubCategoryLabel(confirmed.first);
      // Reaching here at all means the route still crosses it — a confirmed
      // hazard that *was* avoided doesn't survive into the chosen route's
      // verdict, so `wasRerouted`'s own wording already covered that case.
      return '$base ${d.hazardConfirmedUnavoidable(label)}';
    }
    if (reported.isNotEmpty) {
      return '$base ${d.hazardWarningAhead(d.hazardSubCategoryLabel(reported.first))}';
    }
    return base;
  }

  /// The "via X — 1.2 km, about 15 minutes" clause, from whatever the route
  /// result carried. Empty when the numbers are missing, so a malformed
  /// result degrades to the old sentence rather than to "0 metres".
  String _routeSummary(Map<String, Object?> result, AppLanguage language) {
    final distance = (result['distanceMeters'] as num?)?.toDouble() ?? 0;
    if (distance <= 0) return '';
    return Dashboard.of(language).routeSummary(
      via: result['via'] as String? ?? '',
      distanceMeters: distance,
      durationSeconds: (result['durationSeconds'] as num?)?.toDouble() ?? 0,
    );
  }

  String _confirmationFor(String name, Map<String, Object?> args, Map<String, Object?> result, AppLanguage language) {
    final bn = language == AppLanguage.bangla;
    // Asked rather than reported as an error, and it reopens the microphone
    // because it ends in a question — the user is one short answer away from
    // finishing what they started.
    if (name == 'add_emergency_contact' && result['error'] == 'need_phone') {
      final who = (result['name'] as String?)?.trim() ?? '';
      return bn
          ? '$who-এর ফোন নম্বরটা কী?'
          : "What's $who's phone number?";
    }
    if (name == 'add_emergency_contact' && result['error'] == 'no_name') {
      return bn ? 'কার নম্বর যোগ করব?' : 'Whose number should I add?';
    }
    if (name == 'pair_with_caretaker') {
      if (result['ok'] == true) {
        return bn ? 'আপনার দেখাশোনাকারীর সাথে যুক্ত হয়ে গেছে।' : "You're now paired with your caretaker.";
      }
      switch (result['error']) {
        case 'already_paired':
          return bn ? 'আপনি ইতিমধ্যে একজন দেখাশোনাকারীর সাথে যুক্ত আছেন।' : "You're already paired with a caretaker.";
        case 'invalid_code':
          return bn ? 'কোডটি ৬ সংখ্যার হতে হবে। আবার বলুন।' : 'That code should be 6 digits — try again.';
        case 'not_found':
          return bn
              ? 'এই কোডটি খুঁজে পাইনি। দেখাশোনাকারীকে নতুন কোড দিতে বলুন।'
              : "I couldn't find that code. Ask your caretaker for a new one.";
        case 'expired':
          return bn
              ? 'কোডটির মেয়াদ শেষ হয়ে গেছে। দেখাশোনাকারীকে নতুন কোড দিতে বলুন।'
              : 'That code expired. Ask your caretaker for a new one.';
        case 'used':
          return bn ? 'কোডটি আগেই ব্যবহার হয়ে গেছে।' : 'That code has already been used.';
        default:
          return bn ? 'যুক্ত করতে পারলাম না।' : "I couldn't pair that.";
      }
    }
    // Ambiguity is not a failure to apologize for — it is a question to
    // ask, and it has to be checked before any per-call error branch, or
    // the generic "something went wrong planning that route" swallows it
    // and the user never gets asked which place they meant.
    if (result['error'] == 'ambiguous_saved_place') {
      return Dashboard.of(language)
          .savedPlaceAmbiguous((result['options'] as List<Object?>? ?? const []).cast<String>());
    }
    if (name == 'replan_route' && result['ok'] != true) {
      final d = Dashboard.of(language);
      return switch (result['error']) {
        'no_active_route' => d.routeNoActiveRoute,
        'no_location' => bn
            ? 'আপনার অবস্থান জানতে পারছি না। লোকেশন চালু আছে কিনা দেখুন।'
            : "I can't tell where you are right now — please check that location access is enabled.",
        'no_routes_found' => bn
            ? 'এখান থেকে হেঁটে যাওয়ার পথ পেলাম না।'
            : "I couldn't find a walking route from here.",
        _ => bn
            ? 'নতুন পথ খুঁজতে গিয়ে সমস্যা হয়েছে। একটু পরে আবার বলুন।'
            : 'Something went wrong finding the way from here — try again in a moment.',
      };
    }
    if (name == 'request_alternative_route' && result['ok'] != true) {
      final d = Dashboard.of(language);
      return switch (result['error']) {
        'no_active_route' => d.routeNoActiveRoute,
        'no_alternatives' => d.routeNoAlternatives,
        _ => bn
            ? 'অন্য পথটা আনতে গিয়ে সমস্যা হয়েছে। একটু পরে আবার বলুন।'
            : 'Something went wrong fetching the other route — try again in a moment.',
      };
    }
    if (name == 'request_route' && result['ok'] != true) {
      final d = Dashboard.of(language);
      switch (result['error']) {
        case 'ambiguous_destination':
          return d.clarifyChooseOption(
              (result['options'] as List<Object?>? ?? const []).cast<String>());
        case 'destination_not_found':
          // The opening question of the clarification conversation. Asks
          // for the area first — broad, easy to answer, and the single most
          // useful thing for narrowing a Dhaka search.
          return d.clarifyAskArea(result['destination'] as String? ?? '');
        case 'no_location':
          return bn
              ? 'আপনার অবস্থান জানতে পারছি না। লোকেশন চালু আছে কিনা দেখুন।'
              : "I can't tell where you are right now — please check that location access is enabled.";
        case 'no_routes_found':
          return bn ? 'ওই জায়গায় হেঁটে যাওয়ার পথ পেলাম না।' : "I couldn't find a walking route there.";
        // The model named nowhere, or named a placeholder. Ask the question it
        // should have asked instead of reporting a failure the user did not
        // cause — and because this is a question, it reopens the microphone
        // (item 60) so they can just answer it.
        case 'no_destination':
          return d.chatAskDestination;
        default:
          return bn
              ? 'পথ খুঁজতে গিয়ে সমস্যা হয়েছে। একটু পরে আবার চেষ্টা করুন।'
              : 'Something went wrong planning that route — try again in a moment.';
      }
    }
    if (name == 'save_place' && result['ok'] != true) {
      return switch (result['error']) {
        'no_location' => Dashboard.of(language).savedPlaceNeedsLocation,
        // The name it was given was the request itself. Ask for a real one
        // rather than saving a place under a name nobody chose.
        'label_is_the_request' => Dashboard.of(language).savedPlaceNeedsName,
        _ => bn ? 'জায়গাটার একটা নাম বলুন।' : 'Tell me what to call that place.',
      };
    }
    if (name == 'remove_place' && result['ok'] != true) {
      return Dashboard.of(language).savedPlaceUnknown;
    }
    if ((name == 'send_caretaker_message' || name == 'record_caretaker_voice_memo') &&
        result['ok'] != true) {
      final d = Dashboard.of(language);
      return switch (result['error']) {
        'not_paired' => d.alertCaretakerNotPaired,
        'no_message' => d.caretakerMessageEmpty,
        _ => d.caretakerMessageFailed,
      };
    }
    if (name == 'forget_about_me' && result['ok'] != true) {
      return Dashboard.of(language).forgotNoteUnknown;
    }
    if (name == 'alert_caretaker' && result['ok'] != true) {
      final d = Dashboard.of(language);
      return result['error'] == 'not_paired' ? d.alertCaretakerNotPaired : d.alertCaretakerFailed;
    }
    if (name == 'describe_current_location' && result['ok'] != true) {
      final d = Dashboard.of(language);
      // Two different things to be told, and the difference matters to
      // somebody deciding whether to go and turn location back on.
      return result['error'] == 'no_location' ? d.locationUnknown : d.locationUnnamed;
    }
    if (name == 'resolve_hazard' && result['ok'] != true) {
      if (result['error'] == 'no_hazard') return Dashboard.of(language).hazardResolveNothingToClear;
      return bn
          ? 'এখন সরাতে পারলাম না — একটু পরে আবার বলুন।'
          : "I couldn't clear that right now — try again in a moment.";
    }
    if (result['ok'] != true) {
      return bn ? 'দুঃখিত, এটা করতে পারলাম না।' : "Sorry, I couldn't do that.";
    }
    switch (name) {
      case 'request_route':
        final destination = result['destination'] as String? ?? '';
        final rerouted = result['wasRerouted'] == true;
        // `shouldWarn`, not `stillUnsafe`. The latter is the routing
        // decision — whether a safer alternative was worth looking for — and
        // it is false for roughly a quarter of Dhaka after 8pm before any
        // crime evidence is involved, because the fixed threshold it uses
        // sits below the 75th percentile of the night distribution. Speaking
        // on every one of those is how a warning becomes background noise.
        // See `functions/lib/risk_threshold.js`.
        final stillUnsafe = result['shouldWarn'] == true;
        // Which way, how far, how long — appended to every outcome below.
        //
        // Reported: after "take me to Labaid" the only thing said was that
        // the route passed a risky area. That is a warning with no route
        // attached to it, and a user who cannot see the map has no way to
        // ask "which way?" of a line they cannot look at.
        final summary = _routeSummary(result, language);
        if (stillUnsafe) {
          // Chronic and acute get different words. Collapsing them is what
          // made the app say the same sentence about a neighbourhood that
          // has been rough for twenty years and one where a mugging spree
          // was reported this week — and "recently reported" is the half a
          // pedestrian can actually act on tonight.
          final acute = result['riskKind'] == 'acute';
          return _withHazardNotice(
            bn
                ? (acute
                    ? '$destination-এর পথে একটা এলাকা নিয়ে সম্প্রতি খবর এসেছে — সাবধানে থাকবেন। $summary'
                    : '$destination-এর সবচেয়ে নিরাপদ পথটাও এমন একটা এলাকা দিয়ে যায় যেটা এ সময়ে '
                        'তুলনামূলক ঝুঁকিপূর্ণ — সাবধানে থাকবেন। $summary')
                : (acute
                    ? 'There have been recent reports about an area on the way to $destination — '
                        'please stay alert. $summary'
                    : "Even the safest route I found to $destination passes through an area that's "
                        'riskier than most at this hour — please stay alert. $summary'),
            result,
            language,
          );
        }
        if (rerouted) {
          return _withHazardNotice(
            bn
                ? 'আপনার নিরাপত্তার জন্য পথ পাল্টে দিয়েছি, কারণ সরাসরি পথটা একটা অনিরাপদ এলাকা দিয়ে যেত। '
                    '$destination-এর দিকে পথ দেখাচ্ছি। $summary'
                : "I've adjusted your route to avoid a historically unsafe area for your security. "
                    'Showing the way to $destination. $summary',
            result,
            language,
          );
        }
        return _withHazardNotice(
          bn ? '$destination-এর দিকে পথ দেখাচ্ছি। $summary' : 'Showing the way to $destination. $summary',
          result,
          language,
        );
      case 'replan_route':
        return _withHazardNotice(
          bn
              ? 'এখান থেকে নতুন পথ পেয়েছি। ${_routeSummary(result, language)}'
              : 'I have the way from here. ${_routeSummary(result, language)}',
          result,
          language,
        );
      case 'request_alternative_route':
        final d = Dashboard.of(language);
        final base = d.routeAlternativeTaken(
          via: result['via'] as String? ?? '',
          distanceMeters: (result['distanceMeters'] as num?)?.toDouble() ?? 0,
          durationSeconds: (result['durationSeconds'] as num?)?.toDouble() ?? 0,
        );
        final remaining = d.routeAlternativesRemaining((result['alternativeCount'] as int?) ?? 0);
        // The route the user asked for can be less safe than the one they
        // rejected — the planner stops checking at the first safe route, so
        // an alternative is only measured when it is actually taken. Saying
        // nothing here would quietly walk them somewhere the app already
        // knows is worse.
        final warning = result['shouldWarn'] == true
            ? (result['riskKind'] == 'acute'
                ? (bn
                    ? ' এই পথের একটা এলাকা নিয়ে সম্প্রতি খবর এসেছে — সাবধানে থাকবেন।'
                    : ' There have been recent reports about an area on this one — please stay alert.')
                : (bn
                    ? ' এই পথটা এ সময়ের তুলনায় ঝুঁকিপূর্ণ একটা এলাকা দিয়ে যায় — সাবধানে থাকবেন।'
                    : " This one passes through an area that's riskier than most at this hour — "
                        'please stay alert.'))
            : '';
        return _withHazardNotice('$base$warning $remaining', result, language);
      case 'update_setting':
        final setting = args['setting'] as String?;
        final label = (bn ? _settingLabelsBn : _settingLabelsEn)[setting];
        if (label == null) return bn ? 'ঠিক আছে, পাল্টে দিয়েছি।' : "Done — I've updated that.";
        return bn ? 'ঠিক আছে, $label পাল্টে দিয়েছি।' : "Done — I've updated your $label.";
      case 'add_emergency_contact':
        return bn ? 'নতুন জরুরি পরিচিতি যোগ করা হয়েছে।' : "Added that as an emergency contact.";
      case 'remove_emergency_contact':
        return bn ? 'পরিচিতি বাদ দেওয়া হয়েছে।' : 'Removed that contact.';
      case 'add_passerby_message':
        return bn ? 'নতুন বার্তা যোগ করা হয়েছে।' : "Added that message.";
      case 'remove_passerby_message':
        return bn ? 'বার্তা বাদ দেওয়া হয়েছে।' : 'Removed that message.';
      // Spoken by the emergency sequence itself, which starts speaking the
      // instant it is handed control — so this confirmation is never heard.
      // Present so the switch stays total.
      case 'trigger_emergency':
        return Dashboard.of(language).emergencyActivated;

      // Deliberately empty. The scan's own answer — what the camera actually
      // saw — is what gets spoken, and a canned "let me look" ahead of it
      // would make every scan two utterances long. For a user navigating by
      // ear, a redundant sentence is time spent standing in a road.
      case 'look_around':
        return '';
      case 'open_passerby_helper':
        return bn ? 'স্ক্রিন দেখাচ্ছি।' : 'Showing your screen now.';
      case 'open_hazard_report':
        return bn ? 'বিপদ জানানোর ফর্ম খুলছি।' : 'Opening the hazard report form.';
      case 'remember_about_me':
        return Dashboard.of(language).rememberedNote(result['note'] as String? ?? '');
      case 'forget_about_me':
        return Dashboard.of(language).forgotNote;
      case 'open_map':
        return Dashboard.of(language).mapOpened;
      case 'close_map':
        return Dashboard.of(language).mapClosed;
      // Spoken by the caller's own cancel path, which is the only thing that
      // knows whether there was a route to cancel in the first place.
      case 'cancel_route':
        return '';
      case 'resolve_hazard':
        return Dashboard.of(language).hazardResolvedConfirmation;
      case 'save_place':
        return Dashboard.of(language).savedPlaceStored(
          label: result['label'] as String? ?? '',
          usedCurrentLocation: result['usedCurrentLocation'] == true,
        );
      case 'remove_place':
        return Dashboard.of(language).savedPlaceRemoved(result['label'] as String? ?? '');
      case 'describe_current_location':
        return Dashboard.of(language).locationHere(result['place'] as String? ?? '');
      case 'alert_caretaker':
        return Dashboard.of(language).alertCaretakerSent;
      case 'send_caretaker_message':
        // Read back verbatim. A blind user cannot check what was sent on
        // their behalf against a screen, and this app mis-transcribes often
        // enough (items 46, 54) that hearing it is the only way to catch it.
        return Dashboard.of(language).caretakerMessageSent(result['message'] as String? ?? '');
      // The recorder speaks for itself the moment it opens — anything said
      // here would talk over it. Present so the switch stays total.
      case 'record_caretaker_voice_memo':
        return '';
      default:
        return bn ? 'ঠিক আছে।' : 'Done.';
    }
  }

  Future<_AppliedCall> _applyFunctionCall(
    String name,
    Map<String, Object?> args,
    UserProfile profile,
    Position? location,
    RouteChoice? activeRoute,
    List<RouteCandidate> routeAlternatives,
  ) async {
    switch (name) {
      case 'request_route':
        return _applyRequestRoute(args, profile, location);
      case 'request_alternative_route':
        return _applyAlternativeRoute(profile, activeRoute, routeAlternatives);
      case 'replan_route':
        return _applyReplanRoute(profile, location, activeRoute);
      case 'resolve_hazard':
        return _applyResolveHazard(profile, activeRoute);
      case 'save_place':
        return _applySavePlace(args, profile, location);
      case 'remove_place':
        return _applyRemovePlace(args, profile);
      case 'describe_current_location':
        return _applyDescribeLocation(profile, location);
      case 'alert_caretaker':
        return _applyAlertCaretaker(profile, location);
      case 'send_caretaker_message':
        return _applySendCaretakerMessage(args, profile);
      case 'record_caretaker_voice_memo':
        return _applyRecordVoiceMemo(profile);
      case 'pair_with_caretaker':
        if (profile.pairedUserId != null) {
          return _AppliedCall(profile, const {'ok': false, 'error': 'already_paired'}, null);
        }
        final code = (args['code'] as String?)?.trim() ?? '';
        if (code.length != 6) {
          return _AppliedCall(profile, const {'ok': false, 'error': 'invalid_code'}, null);
        }
        try {
          final caretakerUid = await _pairing.redeemCode(code: code, disabledUserUid: profile.uid);
          return _AppliedCall(profile.copyWith(pairedUserId: caretakerUid), const {'ok': true}, null);
        } on PairingException catch (e) {
          return _AppliedCall(profile, {'ok': false, 'error': _pairingErrorCode(e.message)}, null);
        }
      case 'update_setting':
        return _applyUpdateSetting(args, profile);
      case 'add_emergency_contact':
        final name = (args['name'] as String?)?.trim() ?? '';
        final phone = (args['phone'] as String?)?.trim() ?? '';
        if (name.isEmpty) {
          return _AppliedCall(profile, const {'ok': false, 'error': 'no_name'}, null);
        }
        // Distinct from a missing name, because the two need different
        // questions asked. Reported 23 September: a contact saved with only
        // a name and a number the user never gave — `phone` was a required
        // argument, and a model told a field is required fills it rather
        // than declining. An invented number on the Magic Button is dialled
        // when somebody is in trouble.
        if (phone.isEmpty || !_looksLikeAPhoneNumber(phone)) {
          return _AppliedCall(profile, {'ok': false, 'error': 'need_phone', 'name': name}, null);
        }
        final updated = profile.copyWith(
          magicButtonContacts: [...profile.magicButtonContacts, TrustedContact(name: name, phoneNumber: phone)],
        );
        return _AppliedCall(updated, const {'ok': true}, null);
      case 'remove_emergency_contact':
        final name = (args['name'] as String?)?.trim().toLowerCase() ?? '';
        final remaining = profile.magicButtonContacts.where((c) => c.name.toLowerCase() != name).toList();
        final found = remaining.length != profile.magicButtonContacts.length;
        return _AppliedCall(
          profile.copyWith(magicButtonContacts: remaining),
          {'ok': found, if (!found) 'error': 'no contact with that name'},
          null,
        );
      case 'add_passerby_message':
        return _applyAddPasserbyMessage(args, profile);
      case 'remove_passerby_message':
        return _applyRemovePasserbyMessage(args, profile);
      // The emergency is a sequence — speak, wait, dispatch, call, alert,
      // route — not a change to apply and describe, so it is run by the
      // caller exactly as a locally-matched trigger is. Both paths converge
      // on one implementation and one cancel window. Nothing is sent here.
      case 'trigger_emergency':
        return _AppliedCall(profile, const {'ok': true}, null, triggersEmergency: true);

      // Item 51 — "after saying cancel trip, ai thinks trip is cancelled, but
      // map still renders previous route".
      //
      // `cancel_route` has been declared to Gemini all along and had no case
      // here, so a model-issued cancellation fell through to `default` and
      // came back as 'unknown function' while the route stayed on the map.
      // Only the *local* match path ever cancelled anything — which is why
      // this has five passing tests and still failed on a device: the tester
      // said "trip cancel koro", the local matcher does not speak Banglish
      // (item 54), so it went to Gemini, and Gemini's answer was dropped.
      case 'cancel_route':
        return _AppliedCall(profile, const {'ok': true}, null, cancelsRoute: true);

      // Item 51's other half: there was no way to ask for the map at all, in
      // any language. It opens itself when a route is planned and closes when
      // one is cleared, and between those two moments the user had no say.
      case 'remember_about_me':
        // The merged form: `forget: true` removes instead of saving. Both
        // names still work — `forget_about_me` remains declared to nothing
        // but is still accepted, for the same reason `open_map` is.
        return _boolArg(args, 'forget', orElse: false)
            ? _applyForgetNote(args, profile)
            : _applyRememberNote(args, profile);
      case 'forget_about_me':
        return _applyForgetNote(args, profile);

      case 'open_map':
        return _AppliedCall(profile, const {'ok': true}, SuggestedChipAction.showMap);
      case 'close_map':
        return _AppliedCall(profile, const {'ok': true}, SuggestedChipAction.hideMap);

      // The merged form. `open_map`/`close_map` above are kept because the
      // offline matcher and the suggested chips still emit them, and because
      // a model that has seen the old names in an older conversation may
      // still use one — accepting both costs a case label and removes a
      // whole class of "the tool exists but the name changed" failure.
      case 'set_map':
        return _boolArg(args, 'visible', orElse: true)
            ? _AppliedCall(profile, const {'ok': true}, SuggestedChipAction.showMap)
            : _AppliedCall(profile, const {'ok': true}, SuggestedChipAction.hideMap);

      case 'passerby_message':
        return _boolArg(args, 'remove', orElse: false)
            ? _applyRemovePasserbyMessage(args, profile)
            : _applyAddPasserbyMessage(args, profile);

      case 'look_around':
        return _AppliedCall(
          profile,
          const {'ok': true},
          null,
          scanFocus: _scanFocusFrom(args),
          scanQuestion: (args['question'] as String?)?.trim(),
        );

      case 'open_passerby_helper':
        return _AppliedCall(profile, const {'ok': true}, SuggestedChipAction.showScreenToPasserby);
      case 'open_hazard_report':
        // `category`/`subCategory` are optional: a bare "report a hazard"
        // opens the Hub at the top as before, while "report an open
        // manhole" skips straight to it. Unrecognized values are ignored
        // rather than rejected — Gemini can pass anything, and a wrong
        // prefill must never block the user from filing the report by hand.
        return _AppliedCall(
          profile,
          const {'ok': true},
          SuggestedChipAction.reportHazard,
          hazardPrefill: _prefillFrom(args),
        );
      default:
        return _AppliedCall(profile, const {'ok': false, 'error': 'unknown function'}, null);
    }
  }

  /// Clears the hazards on the user's current route.
  ///
  /// Scoped to the active route deliberately: "it's fixed" only ever means
  /// something the user is standing at or walking toward, and resolving by
  /// proximity alone would let a passing remark clear a hazard somebody
  /// else's route depends on. With no route active there is nothing to
  /// resolve, and saying so is better than silently doing nothing.
  Future<_AppliedCall> _applyResolveHazard(UserProfile profile, RouteChoice? activeRoute) async {
    final hazards = activeRoute?.verdict.allHazards ?? const [];
    if (hazards.isEmpty) {
      return _AppliedCall(profile, const {'ok': false, 'error': 'no_hazard'}, null);
    }
    try {
      for (final hazard in hazards) {
        await _routeSafety.resolveHazard(hazard.zoneId);
      }
      return _AppliedCall(profile, {'ok': true, 'resolved': hazards.length}, null);
    } catch (_) {
      return _AppliedCall(profile, const {'ok': false, 'error': 'network_error'}, null);
    }
  }

  /// Saves a frequent destination.
  ///
  /// With no address given this saves the user's *current* coordinates —
  /// "save this as my office", said while standing there. That is by far
  /// the most reliable way to record a Dhaka destination: informal
  /// addressing means a great many real places have no string a geocoder
  /// can resolve, but every place has coordinates when you are standing on
  /// it.
  /// Phrases that are the *request* rather than the name of anywhere.
  ///
  /// Reported from the device: "add a new place i go to frequently" was
  /// saved as a place called **"frequent place"**, pinned to wherever the
  /// user happened to be standing. Neither field was ever given, and both
  /// were invented. It then went on matching unrelated destinations — "I
  /// would like to go to my friend's place" routed to it.
  ///
  /// A place the user cannot see, saved under a name they did not choose, at
  /// a location they did not confirm, is worse than no saved place: they
  /// find out by being walked somewhere wrong. When the label looks like the
  /// sentence that asked for it, ask for a real one instead.
  static const _labelIsNotAName = [
    'new place', 'a place', 'this place', 'place i', 'place that',
    'frequent place', 'frequent', 'somewhere', 'a new one', 'save place',
    'নতুন জায়গা', 'একটা জায়গা', 'এই জায়গা',
  ];

  static bool _looksLikeTheRequest(String label) {
    final lower = label.toLowerCase().trim();
    if (lower.isEmpty) return true;
    if (_labelIsNotAName.any((p) => lower == p)) return true;
    // "a place i go to frequently" and friends — the request restated.
    return _labelIsNotAName.any((p) => lower.contains(p)) && lower.split(RegExp(r'\s+')).length >= 2;
  }

  /// Item 57 — "user asking to alert caretaker doesnt do anything yet".
  ///
  /// There was no intent for it. Module 8 built the caretaker's receiving
  /// half, so the Alert Center and the Overwatch map were both watching, and
  /// the only thing that ever wrote to them was the Magic Button — which is
  /// an emergency, not a way of saying "please check on me".
  ///
  /// Recorded as [GuardianAlertType.userRequested] rather than reusing the
  /// Magic Button's type: a caretaker who cannot tell an emergency from a
  /// calm request will learn to discount both.
  ///
  /// The position rides along with the alert. A caretaker told that someone
  /// wants them and not told where they are has been given half a message.
  Future<_AppliedCall> _applyAlertCaretaker(UserProfile profile, Position? location) async {
    if (profile.pairedUserId == null) {
      return _AppliedCall(profile, const {'ok': false, 'error': 'not_paired'}, null);
    }
    final ok = await _alerts.createAlert(
      disabledUserUid: profile.uid,
      type: GuardianAlertType.userRequested,
      lat: location?.latitude,
      lng: location?.longitude,
    );
    if (!ok) return _AppliedCall(profile, const {'ok': false, 'error': 'failed'}, null);
    if (location != null) {
      // So the Overwatch map has somewhere to point the moment the caretaker
      // opens it, rather than whatever the last publish left behind.
      unawaited(_alerts.publishLocation(
        disabledUserUid: profile.uid,
        lat: location.latitude,
        lng: location.longitude,
      ));
    }
    return _AppliedCall(profile, const {'ok': true}, null);
  }

  /// Item 56 — "remembering context and informations/preferences".
  ///
  /// The recent transcript now survives a restart (item 52), which covers the
  /// last few turns. A conversation window is not memory though: anything
  /// said nine turns ago is gone, and the things worth keeping are exactly
  /// the ones said once, in passing, and never repeated.
  ///
  /// Kept as plain sentences on the profile, so they persist with everything
  /// else the user has told this app and are handed back to the model in its
  /// prompt.
  _AppliedCall _applyRememberNote(Map<String, Object?> args, UserProfile profile) {
    final note = (args['note'] as String?)?.trim() ?? '';
    if (note.isEmpty) {
      return _AppliedCall(profile, const {'ok': false, 'error': 'no_note'}, null);
    }
    // Case-insensitive, because the model will not phrase it identically
    // twice and a list with the same fact three times in it spends prompt on
    // saying one thing.
    final lower = note.toLowerCase();
    if (profile.rememberedNotes.any((n) => n.toLowerCase() == lower)) {
      return _AppliedCall(profile, {'ok': true, 'note': note}, null);
    }
    // Oldest out. An unbounded list grows into the prompt, and a prompt that
    // grows every turn eventually costs more than the reply it buys.
    final kept = [...profile.rememberedNotes, note];
    final trimmed = kept.length > UserProfile.maxRememberedNotes
        ? kept.sublist(kept.length - UserProfile.maxRememberedNotes)
        : kept;
    return _AppliedCall(
      profile.copyWith(rememberedNotes: trimmed),
      {'ok': true, 'note': note},
      null,
    );
  }

  /// The other half, and not optional.
  ///
  /// Anything that remembers what somebody said about themselves has to be
  /// able to forget it on request. This app holds a disabled user's health,
  /// household and movements; "stop keeping that" must be a thing they can
  /// say out loud, in the same breath they said it in.
  _AppliedCall _applyForgetNote(Map<String, Object?> args, UserProfile profile) {
    final query = (args['note'] as String?)?.trim().toLowerCase() ?? '';
    if (query.isEmpty) {
      // "Forget everything" — the whole list goes.
      if (profile.rememberedNotes.isEmpty) {
        return _AppliedCall(profile, const {'ok': false, 'error': 'nothing_to_forget'}, null);
      }
      return _AppliedCall(profile.copyWith(rememberedNotes: const []), const {'ok': true}, null);
    }
    final remaining =
        profile.rememberedNotes.where((n) => !n.toLowerCase().contains(query)).toList();
    if (remaining.length == profile.rememberedNotes.length) {
      return _AppliedCall(profile, const {'ok': false, 'error': 'nothing_to_forget'}, null);
    }
    return _AppliedCall(profile.copyWith(rememberedNotes: remaining), const {'ok': true}, null);
  }

  /// Sending the caretaker something in the user's own words.
  ///
  /// The other direction of Module 8. `CommunicationService` was already
  /// direction-agnostic — `_send` takes `fromUid` and `toUid` — and
  /// `firestore.rules` already allowed the disabled user to create these,
  /// and the caretaker's hub already draws received messages with a
  /// different arrow from sent ones. The only thing missing was any way for
  /// the user to say one.
  ///
  /// The message text is pulled out by Gemini rather than by
  /// `LocalIntentMatcher`, deliberately. Extracting free text from an
  /// arbitrary sentence is exactly what that matcher refuses to do, because
  /// a wrong local guess here does not fail visibly — it sends somebody's
  /// caretaker half a sentence.
  Future<_AppliedCall> _applySendCaretakerMessage(
    Map<String, Object?> args,
    UserProfile profile,
  ) async {
    final caretakerUid = profile.pairedUserId;
    if (caretakerUid == null) {
      return _AppliedCall(profile, const {'ok': false, 'error': 'not_paired'}, null);
    }
    final message = (args['message'] as String?)?.trim() ?? '';
    if (message.isEmpty) {
      // Nothing is sent and the question is asked instead. An empty memo
      // arriving on a caretaker's phone is worse than no memo.
      return _AppliedCall(profile, const {'ok': false, 'error': 'no_message'}, null);
    }
    try {
      await _communications.sendMemo(
        disabledUserUid: profile.uid,
        fromUid: profile.uid,
        toUid: caretakerUid,
        text: message,
      );
      return _AppliedCall(profile, {'ok': true, 'message': message}, null);
    } catch (e) {
      debugPrint('[Assistant] send_caretaker_message failed: $e');
      return _AppliedCall(profile, const {'ok': false, 'error': 'failed'}, null);
    }
  }

  /// Opens the recorder. The sending itself happens there, because the audio
  /// does not exist yet at the point this call is made.
  _AppliedCall _applyRecordVoiceMemo(UserProfile profile) {
    if (profile.pairedUserId == null) {
      return _AppliedCall(profile, const {'ok': false, 'error': 'not_paired'}, null);
    }
    return _AppliedCall(
      profile,
      const {'ok': true},
      SuggestedChipAction.sendCaretakerVoiceMemo,
    );
  }

  /// Item 48 — "even though location is on, it says it cannot tell me where
  /// i am".
  ///
  /// The triage put this down to the map never getting a fix. The logs say
  /// otherwise: 529 fixes against 7 nulls, and every null inside the first
  /// four seconds of a session, which is just the wait for a first fix. The
  /// position was always there. What was missing was any way for the
  /// assistant to *say* it — there was no function for this, so the model
  /// answered the only way a model can when it has no tool and no knowledge,
  /// which is to say it cannot know.
  Future<_AppliedCall> _applyDescribeLocation(UserProfile profile, Position? location) async {
    // The cached fix is used only when it is recent enough to still be true.
    // Otherwise — and when there is none at all, which is every device that
    // has not had a fix since it was last restarted — ask for a real one.
    // This is the second half of why the tester was told the app could not
    // say where they were: even with a function to call, a null cached
    // position would have produced exactly that sentence.
    var fix = location;
    if (fix == null || DateTime.now().difference(fix.timestamp) > _cachedFixIsStaleAfter) {
      fix = await _freshLocation() ?? fix;
    }
    if (fix == null) {
      return _AppliedCall(profile, const {'ok': false, 'error': 'no_location'}, null);
    }
    try {
      // Bounded, like every other network call on a path someone is standing
      // still waiting for. An unanswered reverse geocode must become "I
      // couldn't name it" rather than silence.
      final place = await _routePlanning
          .describeLocation(LatLng(fix.latitude, fix.longitude))
          .timeout(const Duration(seconds: 8));
      if (place == null || place.isEmpty) {
        return _AppliedCall(profile, const {'ok': false, 'error': 'no_name'}, null);
      }
      return _AppliedCall(profile, {'ok': true, 'place': place}, null);
    } catch (e) {
      debugPrint('[Assistant] describe_current_location failed: $e');
      return _AppliedCall(profile, const {'ok': false, 'error': 'no_name'}, null);
    }
  }

  _AppliedCall _applySavePlace(Map<String, Object?> args, UserProfile profile, Position? location) {
    final label = (args['label'] as String?)?.trim() ?? '';
    if (label.isEmpty) {
      return _AppliedCall(profile, const {'ok': false, 'error': 'no_label'}, null);
    }
    if (_looksLikeTheRequest(label)) {
      // The question is now live: whatever the user says next is the answer
      // to it, not a fresh command. See [PendingPlaceSave].
      return _AppliedCall(
        profile,
        const {'ok': false, 'error': 'label_is_the_request'},
        null,
        placeSave: PendingPlaceSave(address: (args['address'] as String?)?.trim()).asked(),
      );
    }
    final address = (args['address'] as String?)?.trim() ?? '';
    final useHere = address.isEmpty;
    if (useHere && location == null) {
      return _AppliedCall(profile, const {'ok': false, 'error': 'no_location'}, null);
    }

    final kind = SavedPlaceKind.values
            .where((k) => k.name == (args['kind'] as String?))
            .firstOrNull ??
        SavedPlaceKind.other;
    final place = SavedPlace(
      label: label,
      address: address,
      lat: useHere ? location!.latitude : null,
      lng: useHere ? location!.longitude : null,
      kind: kind,
    );

    // Replacing a same-labelled place rather than adding a duplicate:
    // "save this as work" said from a new office should move work, not
    // leave two places called work that then resolve ambiguously forever.
    final updated = [
      ...profile.savedPlaces.where((p) => p.label.toLowerCase() != label.toLowerCase()),
      place,
    ];
    return _AppliedCall(
      profile.copyWith(savedPlaces: updated),
      {'ok': true, 'label': label, 'usedCurrentLocation': useHere},
      null,
    );
  }

  _AppliedCall _applyRemovePlace(Map<String, Object?> args, UserProfile profile) {
    final label = (args['label'] as String?)?.trim() ?? '';
    final matches = SavedPlaceMatcher.candidates(label, profile.savedPlaces);
    if (matches.isEmpty) {
      return _AppliedCall(profile, const {'ok': false, 'error': 'no_such_place'}, null);
    }
    if (matches.length > 1) {
      return _AppliedCall(profile, {
        'ok': false,
        'error': 'ambiguous_saved_place',
        'options': matches.map((p) => p.label).toList(),
      }, null);
    }
    final removed = matches.first;
    return _AppliedCall(
      profile.copyWith(savedPlaces: profile.savedPlaces.where((p) => p != removed).toList()),
      {'ok': true, 'label': removed.label},
      null,
    );
  }

  static HazardReportPrefill? _prefillFrom(Map<String, Object?> args) {
    final categoryName = (args['category'] as String?)?.trim();
    if (categoryName == null || categoryName.isEmpty) return null;
    final category = HazardCategory.values.where((c) => c.name == categoryName).firstOrNull;
    if (category == null) return null;
    final sub = (args['subCategory'] as String?)?.trim();
    return HazardReportPrefill(
      category: category,
      subCategory: (sub == null || sub.isEmpty) ? null : sub,
    );
  }

  /// Maps the model's `focus` argument onto [ScanFocus].
  ///
  /// Falls back to [ScanFocus.surroundings] rather than rejecting an
  /// unrecognised value, for the same reason [_prefillFrom] ignores a bad
  /// category: the model can pass anything, and a scan that refuses to run
  /// because the focus word was unexpected is worse for the user than a scan
  /// that looks at the whole scene. Describing everything is never the wrong
  /// answer, only a less specific one.
  static ScanFocus _scanFocusFrom(Map<String, Object?> args) {
    final raw = (args['focus'] as String?)?.trim().toLowerCase() ?? '';
    return switch (raw) {
      'vehicle' || 'bus' || 'transport' => ScanFocus.vehicle,
      'sign' || 'text' || 'read' => ScanFocus.sign,
      'hazard' || 'obstacle' || 'danger' || 'path' => ScanFocus.hazard,
      _ => ScanFocus.surroundings,
    };
  }

  _AppliedCall _applyUpdateSetting(Map<String, Object?> args, UserProfile profile) {
    final setting = args['setting'] as String? ?? '';
    final value = (args['value'] as String? ?? '').trim();
    UserProfile? updated;
    switch (setting) {
      case 'text_size':
        final scale = double.tryParse(value);
        // Snapped, not just clamped. A model told "a number between 0.8 and
        // 2.0" will happily answer 1.37, and an off-ladder value is one the
        // slider cannot display and no label can name — see
        // `text_scale_levels.dart`.
        if (scale != null) {
          updated = profile.copyWith(
              fontScale: snapToLevel(scale.clamp(minTextScale, maxTextScale)));
        }
      case 'theme':
        final t = _enumOrNull(ThemePreference.values, value);
        if (t != null) updated = profile.copyWith(themePreference: t);
      case 'language':
        final l = _enumOrNull(AppLanguage.values, value);
        if (l != null) updated = profile.copyWith(language: l);
      case 'verbosity':
        final v = _enumOrNull(VerbosityLevel.values, value);
        if (v != null) updated = profile.copyWith(verbosity: v);
      case 'voice':
        if (value.isNotEmpty) updated = profile.copyWith(voiceId: value);
      case 'vision_level':
        final vl = _enumOrNull(VisionLevel.values, value);
        if (vl != null) updated = profile.copyWith(visionLevel: vl);
      case 'mobility_aid':
        final ma = _enumOrNull(MobilityAid.values, value);
        if (ma != null) updated = profile.copyWith(mobilityAid: ma);
      case 'deaf_hearing_mode':
        updated = profile.copyWith(isDeafOrHardOfHearing: value == 'true');
      case 'snapshot_consent':
        final sc = _enumOrNull(SnapshotConsentPreference.values, value);
        if (sc != null) updated = profile.copyWith(snapshotConsent: sc);
      case 'crowded_places_anxious':
        updated = profile.copyWith(crowdedPlacesAnxious: value == 'true');
      case 'complex_instructions_hard':
        updated = profile.copyWith(complexInstructionsHard: value == 'true');
      case 'home_address':
        if (value.isNotEmpty) updated = profile.copyWith(homeAddress: value);
      case 'safe_place_address':
        if (value.isNotEmpty) updated = profile.copyWith(safePlaceAddress: value);
      case 'wake_word_enabled':
        updated = profile.copyWith(wakeWordEnabled: value == 'true');
      case 'voice_auto_listen':
        updated = profile.copyWith(voiceAutoListen: value == 'true');
    }
    if (updated == null) {
      return _AppliedCall(profile, {'ok': false, 'error': 'unrecognized setting or value: $setting=$value'}, null);
    }
    return _AppliedCall(updated, const {'ok': true}, null);
  }

  /// Module 4, Step 4: plan a route to `destination`, safety-checking every
  /// walking alternative the routing backend offers against the live
  /// `crimeZones` data and picking the safest one — see
  /// `RoutePlanningService`.
  /// How long routing may wait for a live GPS fix when there is no cached
  /// one. Long enough for a warm start indoors, short enough that a user who
  /// is never going to get a fix is told so rather than left listening to
  /// silence.
  static const Duration _routeFixBudget = Duration(seconds: 10);

  /// Enough digits to dial. Deliberately loose about *format* — Bangladeshi
  /// numbers are written with and without +880, with and without spaces —
  /// and strict about there being real digits at all, which is what a
  /// placeholder like "N/A" or "unknown" fails.
  /// Reads a boolean the model may send as a bool, "true"/"false", or
  /// "yes"/"no" — tool arguments arrive as whatever JSON the model emitted.
  _AppliedCall _applyAddPasserbyMessage(Map<String, Object?> args, UserProfile profile) {
    final message = (args['message'] as String?)?.trim() ?? '';
    if (message.isEmpty) {
      return _AppliedCall(profile, const {'ok': false, 'error': 'message was empty'}, null);
    }
    return _AppliedCall(
      profile.copyWith(passerbyHelperMessages: [...profile.passerbyHelperMessages, message]),
      const {'ok': true},
      null,
    );
  }

  _AppliedCall _applyRemovePasserbyMessage(Map<String, Object?> args, UserProfile profile) {
    final message = (args['message'] as String?)?.trim().toLowerCase() ?? '';
    final remaining =
        profile.passerbyHelperMessages.where((m) => m.toLowerCase() != message).toList();
    final found = remaining.length != profile.passerbyHelperMessages.length;
    return _AppliedCall(
      profile.copyWith(passerbyHelperMessages: remaining),
      {'ok': found, if (!found) 'error': 'no matching message'},
      null,
    );
  }

  static bool _boolArg(Map<String, Object?> args, String key, {required bool orElse}) {
    final raw = args[key];
    if (raw is bool) return raw;
    final text = raw?.toString().trim().toLowerCase();
    if (text == null || text.isEmpty) return orElse;
    if (text == 'true' || text == 'yes' || text == '1') return true;
    if (text == 'false' || text == 'no' || text == '0') return false;
    return orElse;
  }

  static bool _looksLikeAPhoneNumber(String raw) =>
      RegExp(r'[0-9]').allMatches(raw).length >= 6;

  Future<_AppliedCall> _applyRequestRoute(
    Map<String, Object?> args,
    UserProfile profile,
    Position? location,
  ) async {
    // Routing is the one call that genuinely needs a fix, so it is the one
    // call allowed to wait for one.
    //
    // Everything upstream runs on `getLastKnownPosition`, deliberately — a
    // chat reply should not stall behind a GPS lock. But a *route* computed
    // from no origin is not a degraded route, it is no route, and on a fresh
    // launch there is no cached fix at all. The 22 September log shows the
    // map building with `myLocation=null`, and every request_route in that
    // window could only ever have returned `no_location`: "I can't tell where
    // you are right now", to a user who had just asked to be taken somewhere.
    //
    // Bounded, and falling back to the failure it would have returned anyway,
    // so the worst case is unchanged and the common case now works.
    var origin = location;
    if (origin == null) {
      try {
        origin = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium),
        ).timeout(_routeFixBudget);
        debugPrint('[Assistant] no cached fix — took a live one for routing');
      } catch (e) {
        debugPrint('[Assistant] could not get a fix for routing: $e');
      }
    }
    if (origin == null) {
      return _AppliedCall(profile, const {'ok': false, 'error': 'no_location'}, null);
    }
    final destination = (args['destination'] as String?)?.trim() ?? '';
    if (destination.isEmpty) {
      return _AppliedCall(profile, const {'ok': false, 'error': 'no_destination'}, null);
    }
    // A model asked to fill a required argument will fill it, inventing a
    // placeholder rather than declining — "অন্য জায়গা", "another place". The
    // local matcher has refused these since item 55; this path never did, and
    // shipped a route to a destination that names nowhere. Asking is the
    // right outcome: it is the question the model should have asked itself.
    if (DestinationClarifier.isPlaceholder(destination)) {
      debugPrint('[Assistant] refusing a placeholder destination: "$destination"');
      return _AppliedCall(profile, const {'ok': false, 'error': 'no_destination'}, null);
    }

    // Saved places are checked before anything else. "Take me to work"
    // resolves here with no geocode and no model call — and for labels like
    // "work" or "my sister's house" this is the *only* thing that can
    // resolve them, since they are not geocodable strings.
    final matches = SavedPlaceMatcher.candidates(destination, profile.savedPlaces);
    if (matches.length > 1) {
      // Never guess between two saved places. Walking someone to the wrong
      // relative's house is a failure they may not notice until they arrive.
      return _AppliedCall(profile, {
        'ok': false,
        'error': 'ambiguous_saved_place',
        'options': matches.map((p) => p.label).toList(),
      }, null);
    }
    final saved = matches.length == 1 ? matches.first : null;

    try {
      final result = await _routePlanning.plan(
        destinationQuery: saved?.address.isNotEmpty == true ? saved!.address : destination,
        destinationLabel: saved?.label,
        knownDestination:
            saved != null && saved.hasCoordinates ? LatLng(saved.lat!, saved.lng!) : null,
        origin: LatLng(origin.latitude, origin.longitude),
      );
      switch (result) {
        case RoutePlanAmbiguous(:final options):
          return _AppliedCall(
            profile,
            {
              'ok': false,
              'error': 'ambiguous_destination',
              'options': options.map((o) => o.spokenLabel).toList(),
            },
            null,
            clarification: DestinationClarification(originalQuery: destination).offering(options),
          );
        case RoutePlanned(:final choice, :final alternatives):
          return _AppliedCall(
            profile,
            {
              'ok': true,
              'destination': saved?.label ?? destination,
              'fromSavedPlace': saved != null,
              'wasRerouted': choice.wasRerouted,
              'stillUnsafe': !choice.verdict.safe,
              'shouldWarn': choice.verdict.shouldWarn,
              'riskKind': choice.verdict.riskKind,
              // Which way, how far, how long. Announced rather than kept to
              // ourselves: a user who cannot see the map cannot object to a
              // route they were never told about.
              'via': choice.viaSummary,
              'distanceMeters': choice.distanceMeters,
              'durationSeconds': choice.durationSeconds,
              'alternativeCount': alternatives.length,
              // Module 5 ($w_2$). Confirmed hazards are reported separately
              // from unconfirmed ones because they earn a different
              // sentence — and, when no way around one exists, the single
              // most important sentence this assistant says.
              'confirmedHazards':
                  choice.verdict.blockingHazards.map((h) => h.subCategory).toList(),
              'reportedHazards':
                  choice.verdict.hazardWarnings.map((h) => h.subCategory).toList(),
            },
            null,
            route: choice,
            routeAlternatives: alternatives,
          );
        case RoutePlanFailed(:final reason):
          return _AppliedCall(
            profile,
            {'ok': false, 'error': reason, 'destination': destination},
            null,
            // A destination we simply could not find becomes a short
            // conversation instead of a dead end. Everything else (no GPS
            // fix, no walking route) is a different problem that more
            // detail about the place cannot fix.
            clarification: reason == 'destination_not_found'
                ? DestinationClarification(originalQuery: destination).withHint('')
                : null,
          );
      }
    } catch (_) {
      return _AppliedCall(profile, const {'ok': false, 'error': 'network_error'}, null);
    }
  }

  /// Plans the same journey again from where the user is standing now.
  ///
  /// This is what "re-route" means, and [Dashboard.navigateOffRoute] tells a
  /// user who has drifted off the route to say exactly that — then promises
  /// the way will be found from where they are. Nothing implemented the
  /// promise, so the one command offered at the moment someone is lost did
  /// nothing at all.
  ///
  /// The destination comes from the active route's own last point rather
  /// than from re-geocoding its label: it is exact, it costs no network
  /// call, and it cannot resolve to a different place than the one the user
  /// was already walking to — which a second geocode of "the hospital"
  /// very much could.
  Future<_AppliedCall> _applyReplanRoute(
    UserProfile profile,
    Position? location,
    RouteChoice? activeRoute,
  ) async {
    if (activeRoute == null || activeRoute.points.isEmpty) {
      return _AppliedCall(profile, const {'ok': false, 'error': 'no_active_route'}, null);
    }
    if (location == null) {
      return _AppliedCall(profile, const {'ok': false, 'error': 'no_location'}, null);
    }
    try {
      final result = await _routePlanning.plan(
        destinationQuery: activeRoute.destinationLabel,
        destinationLabel: activeRoute.destinationLabel,
        knownDestination: activeRoute.points.last,
        origin: LatLng(location.latitude, location.longitude),
      );
      if (result case RoutePlanned(:final choice, :final alternatives)) {
        return _AppliedCall(
          profile,
          {
            'ok': true,
            'destination': choice.destinationLabel,
            'via': choice.viaSummary,
            'distanceMeters': choice.distanceMeters,
            'durationSeconds': choice.durationSeconds,
            'stillUnsafe': !choice.verdict.safe,
            'shouldWarn': choice.verdict.shouldWarn,
            'riskKind': choice.verdict.riskKind,
            'confirmedHazards': choice.verdict.blockingHazards.map((h) => h.subCategory).toList(),
            'reportedHazards': choice.verdict.hazardWarnings.map((h) => h.subCategory).toList(),
          },
          null,
          route: choice,
          routeAlternatives: alternatives,
        );
      }
      return _AppliedCall(profile, const {'ok': false, 'error': 'no_routes_found'}, null);
    } catch (_) {
      return _AppliedCall(profile, const {'ok': false, 'error': 'network_error'}, null);
    }
  }

  /// Switches to the next walking route the backend already offered.
  ///
  /// Deliberately does not re-plan. Asking for "a different route" is asking
  /// for one of the routes already found — going back to the network could
  /// answer with an entirely different set, including the one just rejected,
  /// and would cost a geocode and a directions call to do it.
  ///
  /// The safety check happens here rather than at plan time so the common
  /// case — a user who accepts the first route, which is most of them —
  /// never pays for two or three extra Cloud Function round trips it did not
  /// need.
  Future<_AppliedCall> _applyAlternativeRoute(
    UserProfile profile,
    RouteChoice? activeRoute,
    List<RouteCandidate> alternatives,
  ) async {
    if (activeRoute == null) {
      return _AppliedCall(profile, const {'ok': false, 'error': 'no_active_route'}, null);
    }
    if (alternatives.isEmpty) {
      return _AppliedCall(profile, const {'ok': false, 'error': 'no_alternatives'}, null);
    }
    final remaining = alternatives.sublist(1);
    try {
      final choice = await _routePlanning.promote(
        alternatives.first,
        destinationLabel: activeRoute.destinationLabel,
      );
      return _AppliedCall(
        profile,
        {
          'ok': true,
          'destination': choice.destinationLabel,
          'via': choice.viaSummary,
          'distanceMeters': choice.distanceMeters,
          'durationSeconds': choice.durationSeconds,
          'stillUnsafe': !choice.verdict.safe,
          'shouldWarn': choice.verdict.shouldWarn,
          'riskKind': choice.verdict.riskKind,
          'alternativeCount': remaining.length,
          'confirmedHazards': choice.verdict.blockingHazards.map((h) => h.subCategory).toList(),
          'reportedHazards': choice.verdict.hazardWarnings.map((h) => h.subCategory).toList(),
        },
        null,
        route: choice,
        routeAlternatives: remaining,
      );
    } catch (_) {
      return _AppliedCall(profile, const {'ok': false, 'error': 'network_error'}, null);
    }
  }

  /// [PairingService] throws plain English prose (shared with the onboarding
  /// UI) — map it to a stable code so [_confirmationFor] can phrase it
  /// bilingually instead of leaking English into a Bangla reply.
  String _pairingErrorCode(String message) {
    if (message.contains('not found')) return 'not_found';
    if (message.contains('expired')) return 'expired';
    if (message.contains('already been used')) return 'used';
    return 'unknown';
  }

  static T? _enumOrNull<T extends Enum>(List<T> values, String name) {
    for (final v in values) {
      if (v.name == name) return v;
    }
    return null;
  }
}
