import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import '../../features/dashboard/models/hazard_report.dart';
import '../../features/dashboard/models/suggested_chip.dart';
import '../../features/onboarding/models/disability_profile_enums.dart';
import '../../features/onboarding/models/saved_place.dart';
import '../../features/onboarding/models/trusted_contact.dart';
import '../../features/onboarding/models/user_profile.dart';
import '../../features/onboarding/services/pairing_service.dart';
import '../localization/app_language.dart';
import '../localization/dashboard_strings.dart';
import 'gemini_assistant_service.dart' show AssistantTurn;
import 'destination_clarifier.dart';
import 'route_planning_service.dart';
import 'route_safety_service.dart';
import 'saved_place_matcher.dart';

class _AppliedCall {
  const _AppliedCall(
    this.profile,
    this.resultForModel,
    this.overlay, {
    this.route,
    this.hazardPrefill,
    this.clarification,
    this.triggersEmergency = false,
  });
  final UserProfile profile;
  final Map<String, Object?> resultForModel;
  final SuggestedChipAction? overlay;
  final RouteChoice? route;
  final HazardReportPrefill? hazardPrefill;

  /// Set when the destination could not be pinned down and the assistant is
  /// now waiting on an answer — see [DestinationClarification].
  final DestinationClarification? clarification;

  /// Set when the model called `trigger_emergency`.
  final bool triggersEmergency;
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
  })  : _injectedPairing = pairingService,
        _injectedRoutePlanning = routePlanning,
        _injectedRouteSafety = routeSafety;

  final PairingService? _injectedPairing;
  final RoutePlanningService? _injectedRoutePlanning;
  final RouteSafetyService? _injectedRouteSafety;

  // Built on first use, not in the constructor. Each default reaches for
  // `FirebaseFirestore.instance`/`FirebaseFunctions.instance`, which throws
  // outright when no Firebase app has been initialized — so an eager field
  // makes this whole class unconstructible in that situation even for the
  // many function calls (every `update_setting`, both `open_*` overlays)
  // that never touch Firebase at all.
  late final PairingService _pairing = _injectedPairing ?? PairingService();
  late final RoutePlanningService _routePlanning = _injectedRoutePlanning ?? RoutePlanningService();
  late final RouteSafetyService _routeSafety = _injectedRouteSafety ?? RouteSafetyService();

  Future<AssistantTurn> execute({
    required String name,
    required Map<String, Object?> args,
    required UserProfile profile,
    Position? location,
    RouteChoice? activeRoute,
  }) async {
    final applied = await _applyFunctionCall(name, args, profile, location, activeRoute);
    final confirmation = _confirmationFor(name, args, applied.resultForModel, profile.language);
    return AssistantTurn(
      responseText: confirmation,
      updatedProfile: identical(applied.profile, profile) ? null : applied.profile,
      overlayAction: applied.overlay,
      route: applied.route,
      hazardPrefill: applied.hazardPrefill,
      clarification: applied.clarification,
      triggersEmergency: applied.triggersEmergency,
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

  String _confirmationFor(String name, Map<String, Object?> args, Map<String, Object?> result, AppLanguage language) {
    final bn = language == AppLanguage.bangla;
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
        default:
          return bn
              ? 'পথ খুঁজতে গিয়ে সমস্যা হয়েছে। একটু পরে আবার চেষ্টা করুন।'
              : 'Something went wrong planning that route — try again in a moment.';
      }
    }
    if (name == 'save_place' && result['ok'] != true) {
      return result['error'] == 'no_location'
          ? Dashboard.of(language).savedPlaceNeedsLocation
          : (bn ? 'জায়গাটার একটা নাম বলুন।' : 'Tell me what to call that place.');
    }
    if (name == 'remove_place' && result['ok'] != true) {
      return Dashboard.of(language).savedPlaceUnknown;
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
        final stillUnsafe = result['stillUnsafe'] == true;
        if (stillUnsafe) {
          return _withHazardNotice(
            bn
                ? '$destination-এর সবচেয়ে নিরাপদ পথটাও কিছুটা ঝুঁকিপূর্ণ এলাকা দিয়ে যায় — সাবধানে থাকবেন।'
                : "Even the safest route I found to $destination passes through a somewhat risky area — please stay alert.",
            result,
            language,
          );
        }
        if (rerouted) {
          return _withHazardNotice(
            bn
                ? 'আপনার নিরাপত্তার জন্য পথ পাল্টে দিয়েছি, কারণ সরাসরি পথটা একটা অনিরাপদ এলাকা দিয়ে যেত। $destination-এর দিকে পথ দেখাচ্ছি।'
                : "I've adjusted your route to avoid a historically unsafe area for your security. Showing the way to $destination.",
            result,
            language,
          );
        }
        return _withHazardNotice(
          bn ? '$destination-এর দিকে পথ দেখাচ্ছি।' : "Showing the way to $destination.",
          result,
          language,
        );
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

      case 'open_passerby_helper':
        return bn ? 'স্ক্রিন দেখাচ্ছি।' : 'Showing your screen now.';
      case 'open_hazard_report':
        return bn ? 'বিপদ জানানোর ফর্ম খুলছি।' : 'Opening the hazard report form.';
      case 'resolve_hazard':
        return Dashboard.of(language).hazardResolvedConfirmation;
      case 'save_place':
        return Dashboard.of(language).savedPlaceStored(
          label: result['label'] as String? ?? '',
          usedCurrentLocation: result['usedCurrentLocation'] == true,
        );
      case 'remove_place':
        return Dashboard.of(language).savedPlaceRemoved(result['label'] as String? ?? '');
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
  ) async {
    switch (name) {
      case 'request_route':
        return _applyRequestRoute(args, profile, location);
      case 'resolve_hazard':
        return _applyResolveHazard(profile, activeRoute);
      case 'save_place':
        return _applySavePlace(args, profile, location);
      case 'remove_place':
        return _applyRemovePlace(args, profile);
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
        if (name.isEmpty || phone.isEmpty) {
          return _AppliedCall(profile, const {'ok': false, 'error': 'name and phone are both required'}, null);
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
        final message = (args['message'] as String?)?.trim() ?? '';
        if (message.isEmpty) return _AppliedCall(profile, const {'ok': false, 'error': 'message was empty'}, null);
        return _AppliedCall(
          profile.copyWith(passerbyHelperMessages: [...profile.passerbyHelperMessages, message]),
          const {'ok': true},
          null,
        );
      case 'remove_passerby_message':
        final message = (args['message'] as String?)?.trim().toLowerCase() ?? '';
        final remaining = profile.passerbyHelperMessages.where((m) => m.toLowerCase() != message).toList();
        final found = remaining.length != profile.passerbyHelperMessages.length;
        return _AppliedCall(
          profile.copyWith(passerbyHelperMessages: remaining),
          {'ok': found, if (!found) 'error': 'no matching message'},
          null,
        );
      // The emergency is a sequence — speak, wait, dispatch, call, alert,
      // route — not a change to apply and describe, so it is run by the
      // caller exactly as a locally-matched trigger is. Both paths converge
      // on one implementation and one cancel window. Nothing is sent here.
      case 'trigger_emergency':
        return _AppliedCall(profile, const {'ok': true}, null, triggersEmergency: true);

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
  _AppliedCall _applySavePlace(Map<String, Object?> args, UserProfile profile, Position? location) {
    final label = (args['label'] as String?)?.trim() ?? '';
    if (label.isEmpty) {
      return _AppliedCall(profile, const {'ok': false, 'error': 'no_label'}, null);
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

  _AppliedCall _applyUpdateSetting(Map<String, Object?> args, UserProfile profile) {
    final setting = args['setting'] as String? ?? '';
    final value = (args['value'] as String? ?? '').trim();
    UserProfile? updated;
    switch (setting) {
      case 'text_size':
        final scale = double.tryParse(value);
        if (scale != null) updated = profile.copyWith(fontScale: scale.clamp(0.8, 2.0));
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
  Future<_AppliedCall> _applyRequestRoute(
    Map<String, Object?> args,
    UserProfile profile,
    Position? location,
  ) async {
    if (location == null) {
      return _AppliedCall(profile, const {'ok': false, 'error': 'no_location'}, null);
    }
    final destination = (args['destination'] as String?)?.trim() ?? '';
    if (destination.isEmpty) {
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
        origin: LatLng(location.latitude, location.longitude),
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
        case RoutePlanned(:final choice):
          return _AppliedCall(
            profile,
            {
              'ok': true,
              'destination': saved?.label ?? destination,
              'fromSavedPlace': saved != null,
              'wasRerouted': choice.wasRerouted,
              'stillUnsafe': !choice.verdict.safe,
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
