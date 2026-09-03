import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import '../../features/dashboard/models/suggested_chip.dart';
import '../../features/onboarding/models/disability_profile_enums.dart';
import '../../features/onboarding/models/trusted_contact.dart';
import '../../features/onboarding/models/user_profile.dart';
import '../../features/onboarding/services/pairing_service.dart';
import '../localization/app_language.dart';
import 'gemini_assistant_service.dart' show AssistantTurn;
import 'route_planning_service.dart';

class _AppliedCall {
  const _AppliedCall(this.profile, this.resultForModel, this.overlay, {this.route});
  final UserProfile profile;
  final Map<String, Object?> resultForModel;
  final SuggestedChipAction? overlay;
  final RouteChoice? route;
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
  FunctionCallExecutor({PairingService? pairingService, RoutePlanningService? routePlanning})
      : _pairing = pairingService ?? PairingService(),
        _routePlanning = routePlanning ?? RoutePlanningService();

  final PairingService _pairing;
  final RoutePlanningService _routePlanning;

  Future<AssistantTurn> execute({
    required String name,
    required Map<String, Object?> args,
    required UserProfile profile,
    Position? location,
  }) async {
    final applied = await _applyFunctionCall(name, args, profile, location);
    final confirmation = _confirmationFor(name, args, applied.resultForModel, profile.language);
    return AssistantTurn(
      responseText: confirmation,
      updatedProfile: identical(applied.profile, profile) ? null : applied.profile,
      overlayAction: applied.overlay,
      route: applied.route,
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
    if (name == 'request_route' && result['ok'] != true) {
      switch (result['error']) {
        case 'no_location':
          return bn
              ? 'আপনার অবস্থান জানতে পারছি না। লোকেশন চালু আছে কিনা দেখুন।'
              : "I can't tell where you are right now — please check that location access is enabled.";
        case 'destination_not_found':
          return bn ? 'জায়গাটা খুঁজে পাইনি। আবার বলুন।' : "I couldn't find that place — try saying it again.";
        case 'no_routes_found':
          return bn ? 'ওই জায়গায় হেঁটে যাওয়ার পথ পেলাম না।' : "I couldn't find a walking route there.";
        default:
          return bn
              ? 'পথ খুঁজতে গিয়ে সমস্যা হয়েছে। একটু পরে আবার চেষ্টা করুন।'
              : 'Something went wrong planning that route — try again in a moment.';
      }
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
          return bn
              ? '$destination-এর সবচেয়ে নিরাপদ পথটাও কিছুটা ঝুঁকিপূর্ণ এলাকা দিয়ে যায় — সাবধানে থাকবেন।'
              : "Even the safest route I found to $destination passes through a somewhat risky area — please stay alert.";
        }
        if (rerouted) {
          return bn
              ? 'আপনার নিরাপত্তার জন্য পথ পাল্টে দিয়েছি, কারণ সরাসরি পথটা একটা অনিরাপদ এলাকা দিয়ে যেত। $destination-এর দিকে পথ দেখাচ্ছি।'
              : "I've adjusted your route to avoid a historically unsafe area for your security. Showing the way to $destination.";
        }
        return bn ? '$destination-এর দিকে পথ দেখাচ্ছি।' : "Showing the way to $destination.";
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
      case 'open_passerby_helper':
        return bn ? 'স্ক্রিন দেখাচ্ছি।' : 'Showing your screen now.';
      case 'open_hazard_report':
        return bn ? 'বিপদ জানানোর ফর্ম খুলছি।' : 'Opening the hazard report form.';
      default:
        return bn ? 'ঠিক আছে।' : 'Done.';
    }
  }

  Future<_AppliedCall> _applyFunctionCall(
    String name,
    Map<String, Object?> args,
    UserProfile profile,
    Position? location,
  ) async {
    switch (name) {
      case 'request_route':
        return _applyRequestRoute(args, profile, location);
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
      case 'open_passerby_helper':
        return _AppliedCall(profile, const {'ok': true}, SuggestedChipAction.showScreenToPasserby);
      case 'open_hazard_report':
        return _AppliedCall(profile, const {'ok': true}, SuggestedChipAction.reportHazard);
      default:
        return _AppliedCall(profile, const {'ok': false, 'error': 'unknown function'}, null);
    }
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

    try {
      final result = await _routePlanning.plan(
        destinationQuery: destination,
        origin: LatLng(location.latitude, location.longitude),
      );
      switch (result) {
        case RoutePlanned(:final choice):
          return _AppliedCall(
            profile,
            {
              'ok': true,
              'destination': destination,
              'wasRerouted': choice.wasRerouted,
              'stillUnsafe': !choice.verdict.safe,
            },
            null,
            route: choice,
          );
        case RoutePlanFailed(:final reason):
          return _AppliedCall(profile, {'ok': false, 'error': reason}, null);
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
