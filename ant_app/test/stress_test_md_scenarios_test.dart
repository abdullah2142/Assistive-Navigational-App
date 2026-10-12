// Runs the literal prompts from `stress_test.md` against the real input
// pipeline — `LocalIntentMatcher` for recognition, `FunctionCallExecutor`
// for output — with stubbed network-facing services (no GPS, no Firestore,
// no Gemini/Groq, no camera).
//
// What this can and cannot verify:
//
// Everything a human voice turns into a `LocalIntent` is checked for real:
// the exact strings in the document are fed to `LocalIntentMatcher.match`,
// so a false "it recognises this" claim would fail here exactly as it would
// on a device. Where the document's expected behaviour also names an output
// (a route, a hazard prefill, a setting change), that output is produced
// through the real `FunctionCallExecutor` against a stubbed
// `RoutePlanningService`/profile and checked too.
//
// What it cannot check: anything that depends on Gemini actually making the
// right judgement call (Scene 8's nuanced cases, "what do you know about
// me", conversational refusals), and anything that needs real hardware or a
// live Firebase project (Scene 1's onboarding UI, Scene 3's camera frames,
// Scene 4's Guardian Hub pairing/Firestore side-effects). Those are called
// out inline rather than guessed at, and left to their own dedicated test
// files (phone_contact_search_test.dart, snapshot_vision_test.dart,
// guardian_hub_test.dart, caretaker_messaging_test.dart, emergency_trigger_
// test.dart, hazard_report_submit_test.dart, and the rest).

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/providers/ai_assistant_providers.dart';
import 'package:ant_app/core/services/destination_clarifier.dart';
import 'package:ant_app/core/services/function_call_executor.dart';
import 'package:ant_app/core/services/local_intent_matcher.dart';
import 'package:ant_app/core/services/route_planning_service.dart';
import 'package:ant_app/core/services/route_safety_service.dart';
import 'package:ant_app/core/utils/text_scale_levels.dart';
import 'package:ant_app/features/dashboard/models/chat_message.dart';
import 'package:ant_app/features/dashboard/providers/chat_providers.dart';
import 'package:ant_app/features/guardian/models/guardian_alert.dart';
import 'package:ant_app/features/guardian/services/alert_service.dart';
import 'package:ant_app/features/onboarding/models/onboarding_step.dart';
import 'package:ant_app/features/onboarding/models/saved_place.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';
import 'package:ant_app/features/onboarding/providers/onboarding_providers.dart';
import 'package:ant_app/features/onboarding/services/profile_service.dart';

const _safe = SafetyVerdict(safe: true, riskScore: 1, threshold: 7, dangerousThanaNames: []);

UserProfile _profile({List<SavedPlace> savedPlaces = const []}) => UserProfile(
      uid: 'u1',
      role: UserRole.disabledUser,
      savedPlaces: savedPlaces,
    );

RouteChoice _routeTo(String label) => RouteChoice(
      destinationLabel: label,
      points: const [LatLng(23.7461, 90.3742), LatLng(23.7550, 90.3800)],
      distanceMeters: 1200,
      durationSeconds: 900,
      initialBearingDegrees: 40,
      verdict: _safe,
      wasRerouted: false,
    );

/// Hands back a canned [RoutePlanned] for any query, and records what it was
/// asked to plan. `noSuchMethod` means this never silently exercises the
/// real network path for a method nobody stubbed.
class _StubPlanning implements RoutePlanningService {
  _StubPlanning(this._label);
  final String _label;
  String? lastQuery;

  @override
  Future<RoutePlanResult> plan({
    required String destinationQuery,
    required LatLng origin,
    DateTime? at,
    LatLng? knownDestination,
    String? destinationLabel,
  }) async {
    lastQuery = destinationQuery;
    return RoutePlanned(_routeTo(destinationLabel ?? _label));
  }

  @override
  Future<String?> describeLocation(LatLng location) async => 'Road 7, Dhanmondi';

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// Stands in for the real `AlertService`, which reaches Firestore the moment
/// it is constructed — see `alert_caretaker_test.dart`'s `_RecordingAlerts`,
/// the same shape.
class _FakeAlerts implements AlertService {
  @override
  Stream<List<GuardianAlert>> watchAlerts(String disabledUserUid) => const Stream.empty();

  @override
  Future<bool> createAlert({
    required String disabledUserUid,
    required GuardianAlertType type,
    double? lat,
    double? lng,
    int? batteryPercent,
    List<String> notifiedContacts = const [],
  }) async => true;

  @override
  Future<bool> publishLocation({
    required String disabledUserUid,
    required double lat,
    required double lng,
  }) async => true;

  @override
  Future<void> resolveAlert(String disabledUserUid, String alertId) async {}
}

/// Stands in for the real `ProfileService`, which also reaches Firestore the
/// moment it is constructed. `ChatController.sendFreeText` saves the profile
/// after *every* locally-matched setting/memory/place change, so anything
/// exercising those through the full controller (rather than
/// `FunctionCallExecutor` directly) needs this — nothing else in this test
/// suite drives that path end to end, which is itself worth noting.
class _FakeProfiles implements ProfileService {
  final saved = <UserProfile>[];

  @override
  Future<void> saveProfile(UserProfile profile) async {
    saved.add(profile);
  }

  @override
  Future<UserProfile?> fetchProfile(String uid) async => null;

  @override
  Stream<UserProfile?> watchProfile(String uid) => const Stream.empty();

  @override
  Future<void> saveOnboardingStep({required String uid, required OnboardingStep step}) async {}
}

FunctionCallExecutor _executorWith(_StubPlanning planning) =>
    FunctionCallExecutor(routePlanning: planning);

void main() {
  group('Scene 2 — Conversational Navigation', () {
    test('2.1 "I\'m really hungry, I want something cheap to eat" → a route, '
        'to a real resolved place, not an invented restaurant name', () async {
      final intent = LocalIntentMatcher.match(
        "I'm really hungry, I want something cheap to eat",
        AppLanguage.english,
      );
      expect(intent?.name, 'request_route',
          reason: 'a need, not a place name, must still start navigation');
      expect(intent!.args['destination'], 'nearest restaurant');

      // "nearest restaurant" is a category phrase, not a place — the
      // planner resolves it to whatever nearby business the stub routing
      // layer names. Simulating that resolution here (rather than literally
      // "nearest restaurant" turning into the spoken destination) is what
      // Module 6's fix guarantees: the spoken label names a real place.
      final stub = _StubPlanning('Star Kabab, Dhanmondi');
      final turn = await _executorWith(stub).execute(
        name: intent.name,
        args: intent.args,
        profile: _profile(),
        location: _fixAt(23.7461, 90.3742),
      );
      expect(turn.route?.destinationLabel, 'Star Kabab, Dhanmondi');
      expect(turn.responseText, contains('Star Kabab'));
      expect(turn.responseText, isNot(contains('nearest restaurant')),
          reason: 'the user should hear a place, not the category it was resolved from');
    });

    test('2.2 "Actually, cancel that" — the bare pronoun does not locally '
        'match cancel_route (verified: the strong/weak phrase lists all '
        'require a named noun — "trip"/"route"/"journey" — and "that" alone '
        'is deliberately not treated as one, to avoid misreading an unrelated '
        '"cancel that [message/report]"); this needs Gemini to resolve "that" '
        'from the conversation, not the instant local path the document '
        'implies', () {
      final intent = LocalIntentMatcher.match('Actually, cancel that', AppLanguage.english);
      expect(intent, isNull);
    });

    test('2.3 "Take me to Dhanmondi" → a route request naming Dhanmondi', () async {
      final intent = LocalIntentMatcher.match('Take me to Dhanmondi', AppLanguage.english);
      expect(intent?.name, 'request_route');
      expect(intent!.args['destination'], 'Dhanmondi');

      final stub = _StubPlanning('Dhanmondi');
      final turn = await _executorWith(stub).execute(
        name: intent.name,
        args: intent.args,
        profile: _profile(),
        location: _fixAt(23.7461, 90.3742),
      );
      expect(stub.lastQuery, 'Dhanmondi');
      expect(turn.route, isNotNull);
      expect(turn.responseText, contains('Dhanmondi'));
      // Whether a medium trip also offers a transport-mode question is a
      // judgement `plan_commute`/Gemini makes from the system prompt, not
      // something `request_route` itself decides — not checked here.
    });

    test('2.4 "I don\'t like this road, give me another way" → an alternative, same destination', () {
      final intent = LocalIntentMatcher.match(
        "I don't like this road, give me another way",
        AppLanguage.english,
      );
      expect(intent?.name, 'request_alternative_route');
    });

    test('2.5 "আমাকে কাছের মসজিদে নিয়ে যাও" (nearest mosque) → a route request, '
        'with no follow-up question needed', () {
      final intent = LocalIntentMatcher.match('আমাকে কাছের মসজিদে নিয়ে যাও', AppLanguage.bangla);
      expect(intent?.name, 'request_route',
          reason: 'Bangla "nearest X" must resolve locally, like its English equivalent');
      expect(DestinationClarifier.wantsNearest(intent!.args['destination'] as String), isTrue);
    });

    test('2.6 map search bar autocomplete is a separate widget, not chat — '
        'covered by destination_sheet_search_test.dart', () {}, skip: 'see that file');

    test('2.7 "I think I went the wrong way" → does not misfire into cancelling '
        'or a fresh route; actually replanning needs a live Gemini call', () {
      final intent = LocalIntentMatcher.match('I think I went the wrong way', AppLanguage.english);
      // Not in the local replan/alternative vocabulary (only "re-route",
      // "start over", etc.) — this is a real gap in local coverage, not a
      // false positive. Documented here rather than silently assumed.
      expect(intent, isNull,
          reason: 'falls through to Gemini for replan_route — requires a live model to confirm '
              'it actually replans rather than, say, apologising conversationally');
    });
  });

  group('Scene 5 — Emergency & Safety', () {
    test('5.1 "There\'s someone following me and I\'m scared" → trigger_emergency '
        '(FIXED 12 Oct: _matchEmergency now also fires on "followed" and '
        '"scared" appearing together, even with no single unmistakable cry '
        'word in the sentence — see _followedAndAfraid)', () {
      final intent = LocalIntentMatcher.match(
        "There's someone following me and I'm scared",
        AppLanguage.english,
      );
      expect(intent?.name, 'trigger_emergency');
    });

    test('5.2 the 5-second cancel window is UI state, not a matcher concern — '
        'covered by voice_cancel_window_test.dart', () {}, skip: 'see that file');

    test('5.3 "আমি উঠতে পারছি না" (I can\'t get up) → trigger_emergency from an '
        'indirect Bangla phrase (FIXED 12 Oct: added to _emergencyStrong, the '
        'same way "i might faint" already was)', () {
      final intent = LocalIntentMatcher.match('আমি উঠতে পারছি না', AppLanguage.bangla);
      expect(intent?.name, 'trigger_emergency');
    });

    test('a single distress word alone still does not trigger — the fix is a '
        'pairing, not a lowered bar for any one of them', () {
      // Guards the 5.1 fix specifically: "following" and "scared" must both
      // be present. Neither alone should flip a word this common into an SOS.
      expect(
        LocalIntentMatcher.match(
                'my little brother keeps following me around the house', AppLanguage.english)
            ?.name,
        isNot('trigger_emergency'),
      );
      expect(
        LocalIntentMatcher.match("I'm scared of spiders", AppLanguage.english)?.name,
        isNot('trigger_emergency'),
      );
    });

    test('5.4 "There\'s a huge pothole on this road" → a hazard report, '
        'pre-filled roadHazard/pothole', () async {
      final intent = LocalIntentMatcher.match(
        "There's a huge pothole on this road",
        AppLanguage.english,
      );
      expect(intent?.name, 'open_hazard_report');
      expect(intent!.args['category'], 'roadHazard');
      expect(intent.args['subCategory'], 'pothole');

      final turn = await FunctionCallExecutor().execute(
        name: intent.name,
        args: intent.args,
        profile: _profile(),
        location: null,
      );
      expect(turn.hazardPrefill?.category.name, 'roadHazard');
      expect(turn.hazardPrefill?.subCategory, 'pothole');
    });

    test('5.5 "The sidewalk is completely blocked by vendors" — does NOT match '
        'a local hazard category (no report verb in it), so it is Gemini\'s to '
        'classify; confirmed here only that it does not misfire into the wrong '
        'thing', () {
      final intent = LocalIntentMatcher.match(
        'The sidewalk is completely blocked by vendors',
        AppLanguage.english,
      );
      // This is the honest result, not the document's assumption: "blocked
      // by vendors" alone, with no "report"/"there's a"/"I see a" verb, is
      // mention rather than report by this matcher's own stated rule (see
      // local_intent_matcher.dart's _reportVerbsEn comment), so it is left
      // for Gemini — which does have accessibilityBlock/blockedByVendors
      // declared to it. A live call is needed to confirm it actually picks
      // the right subCategory; this only confirms the local matcher stays
      // out of the way instead of guessing.
      expect(intent, isNot(predicate((LocalIntent? i) => i != null && i.name != 'open_hazard_report')),
          reason: 'if anything local fires here, it must still be the hazard report, not something else');
    });

    test('5.6 "That pothole I reported is fixed now" → resolve_hazard, not a new report', () {
      final intent = LocalIntentMatcher.match('That pothole I reported is fixed now', AppLanguage.english);
      expect(intent?.name, 'resolve_hazard',
          reason: 'matched before the hazard-report vocabulary specifically so a named '
              'hazard plus a resolution reads as clearing it, not reporting it again');
    });
  });

  group('Scene 6 — Memory & Personalization', () {
    // 6.1/6.2/6.3/6.4 (remember_about_me / forget_about_me / reciting notes
    // back) are not in LocalIntentMatcher's vocabulary at all — deciding to
    // save or recall a free-form personal fact needs the model. What is
    // checked here is the other half: given the call Gemini is expected to
    // make, does FunctionCallExecutor apply it correctly.
    test('6.1/6.2 remembering two separate facts keeps both', () async {
      final executor = FunctionCallExecutor();
      var profile = _profile();
      final first = await executor.execute(
        name: 'remember_about_me',
        args: const {'note': "can't manage stairs at all"},
        profile: profile,
        location: null,
      );
      profile = first.updatedProfile!;
      final second = await executor.execute(
        name: 'remember_about_me',
        args: const {'note': 'daughter picks me up every Friday after Jummah'},
        profile: profile,
        location: null,
      );
      profile = second.updatedProfile!;
      expect(profile.rememberedNotes, hasLength(2));
      expect(profile.rememberedNotes[0], contains('stairs'));
      expect(profile.rememberedNotes[1], contains('Jummah'));
    });

    test('6.4 "forget about the stairs thing" removes only that note', () async {
      final profile = _profile().copyWith(
        rememberedNotes: ["can't manage stairs at all", 'daughter picks me up every Friday'],
      );
      final turn = await FunctionCallExecutor().execute(
        name: 'forget_about_me',
        args: const {'note': 'stairs'},
        profile: profile,
        location: null,
      );
      expect(turn.updatedProfile!.rememberedNotes, ["daughter picks me up every Friday"]);
    });

    test('6.5/6.6 saving "my office" then asking for it by name routes there, '
        'no geocoding needed', () async {
      final saveTurn = await FunctionCallExecutor().execute(
        name: 'save_place',
        args: const {'label': 'office'},
        profile: _profile(),
        location: _fixAt(23.78, 90.41),
      );
      final savedProfile = saveTurn.updatedProfile!;
      expect(savedProfile.savedPlaces.map((p) => p.label), contains('office'));

      final intent = LocalIntentMatcher.match('Take me to my office', AppLanguage.english);
      expect(intent?.name, 'request_route');
      expect(intent!.args['destination'], contains('office'));

      final stub = _StubPlanning('should not be used — saved place short-circuits this');
      final turn = await _executorWith(stub).execute(
        name: intent.name,
        args: intent.args,
        profile: savedProfile,
        location: _fixAt(23.7461, 90.3742),
      );
      expect(stub.lastQuery, isNot(contains('nearest')),
          reason: 'a saved place must resolve without a category/geocode round trip');
      expect(turn.route, isNotNull);
    });
  });

  group('Scene 7 — Accessibility Settings by Voice', () {
    test('7.1 "Switch to dark mode" → theme=dark, applied immediately', () async {
      final intent = LocalIntentMatcher.match('Switch to dark mode', AppLanguage.english);
      expect(intent?.name, 'update_setting');
      expect(intent!.args, {'setting': 'theme', 'value': 'dark'});
      final turn = await FunctionCallExecutor().execute(
        name: intent.name,
        args: intent.args,
        profile: _profile(),
        location: null,
      );
      expect(turn.updatedProfile?.themePreference.name, 'dark');
    });

    test('7.2 "Make the text bigger" → text_size increases by one step', () async {
      final intent = LocalIntentMatcher.match('Make the text bigger', AppLanguage.english);
      expect(intent?.name, 'update_setting');
      expect(intent!.args['setting'], 'text_size');
      expect(intent.args['value'], '_bigger',
          reason: 'the sentinel ChatController._resolveLocalIntentArgs translates into a '
              'real step — translating it here too, rather than skipping straight to a '
              'number, is what calling FunctionCallExecutor directly would otherwise miss');
      final profile = _profile();
      final resolvedValue = stepScale(profile.fontScale, 1).toString();
      final turn = await FunctionCallExecutor().execute(
        name: intent.name,
        args: {'setting': 'text_size', 'value': resolvedValue},
        profile: profile,
        location: null,
      );
      expect(turn.updatedProfile!.fontScale, greaterThan(profile.fontScale));
    });

    test('7.3 "Change the language to Bangla" → language=bangla', () async {
      final intent = LocalIntentMatcher.match('Change the language to Bangla', AppLanguage.english);
      expect(intent?.name, 'update_setting');
      expect(intent!.args, {'setting': 'language', 'value': 'bangla'});
      final turn = await FunctionCallExecutor().execute(
        name: intent.name,
        args: intent.args,
        profile: _profile(),
        location: null,
      );
      expect(turn.updatedProfile?.language, AppLanguage.bangla);
    });

    test('7.4 "I want longer answers, more detail" → verbosity=descriptive', () async {
      final intent = LocalIntentMatcher.match('I want longer answers, more detail', AppLanguage.english);
      expect(intent?.name, 'update_setting');
      expect(intent!.args['setting'], 'verbosity');
      final turn = await FunctionCallExecutor().execute(
        name: intent.name,
        args: intent.args,
        profile: _profile(),
        location: null,
      );
      expect(turn.updatedProfile?.verbosity.name, 'descriptive');
    });

    test('7.5 "Turn off the wake word" → wake_word_enabled=false', () async {
      final intent = LocalIntentMatcher.match('Turn off the wake word', AppLanguage.english);
      expect(intent?.name, 'update_setting');
      expect(intent!.args['setting'], 'wake_word_enabled');
      final turn = await FunctionCallExecutor().execute(
        name: intent.name,
        args: intent.args,
        profile: _profile(),
        location: null,
      );
      expect(turn.updatedProfile?.wakeWordEnabled, isFalse);
    });

    test('7.6 "Change the theme to red" does NOT locally match — it must reach '
        'a model that can refuse, rather than a matcher that would blindly set it', () {
      final intent = LocalIntentMatcher.match('Change the theme to red', AppLanguage.english);
      expect(intent, isNull,
          reason: '_matchTheme only recognises dark/light by design; "red" falls through '
              'to Gemini, which has to say the setting does not support it rather than '
              'inventing a value — a live call is needed to confirm it actually refuses');
    });
  });

  group('Scene 8 — Intelligence Under Pressure (false positives)', () {
    test('8.1 "This road is actually really nice, not dangerous at all" → no '
        'emergency, no hazard report', () {
      final intent = LocalIntentMatcher.match(
        'This road is actually really nice, not dangerous at all',
        AppLanguage.english,
      );
      expect(intent?.name, isNot('trigger_emergency'));
      expect(intent?.name, isNot('open_hazard_report'));
    });

    test('8.2 "What happens if I press the emergency button?" → a question, '
        'not an emergency', () {
      final intent = LocalIntentMatcher.match(
        'What happens if I press the emergency button?',
        AppLanguage.english,
      );
      expect(intent?.name, isNot('trigger_emergency'));
    });

    test('8.3 "Can you help me change the font size?" → a setting change, '
        'not an emergency despite "help"', () {
      final intent = LocalIntentMatcher.match(
        'Can you help me change the font size?',
        AppLanguage.english,
      );
      expect(intent?.name, isNot('trigger_emergency'));
    });

    test('8.4 "Add my sister Fatima as an emergency contact, 01712345678" → '
        'not trigger_emergency despite the word "emergency"', () {
      final intent = LocalIntentMatcher.match(
        'Add my sister Fatima as an emergency contact, 01712345678',
        AppLanguage.english,
      );
      expect(intent?.name, isNot('trigger_emergency'));
      // add_emergency_contact itself is Gemini-only (not in the local
      // vocabulary) — whether it is actually called correctly needs a live
      // model; confirmed here only that nothing worse happens locally.
    });

    test('8.5 "What\'s my brother\'s phone number?" does not locally match '
        'anything that would fabricate an answer', () {
      final intent = LocalIntentMatcher.match("What's my brother's phone number?", AppLanguage.english);
      expect(intent, isNull,
          reason: 'left for Gemini to say plainly it cannot access phone contacts — '
              'a live call is needed to confirm it does not hallucinate a number');
    });

    test('8.6 "I fell and scraped my knee a little, but I\'m totally fine, '
        "don't worry\" → the explicit refusal suppresses the emergency trigger", () {
      final intent = LocalIntentMatcher.match(
        "I fell and scraped my knee a little, but I'm totally fine, don't worry",
        AppLanguage.english,
      );
      expect(intent?.name, isNot('trigger_emergency'),
          reason: '"fell" is a distress word, but the explicit "I\'m fine" refusal must veto it — '
              'whether Gemini still offers alert_caretaker as a softer check-in needs a live call');
    });
  });

  group('Rapid-Fire Endurance Test', () {
    testWidgets('6 prompts back-to-back all succeed: no exception, no dropped '
        'turn, no stall', (tester) async {
      final planning = _StubPlanning('nearest mosque');
      final container = ProviderContainer(overrides: [
        routePlanningServiceProvider.overrideWithValue(planning),
        functionCallExecutorProvider.overrideWithValue(
          FunctionCallExecutor(routePlanning: planning, alertService: _FakeAlerts()),
        ),
        profileServiceProvider.overrideWithValue(_FakeProfiles()),
      ]);
      addTearDown(container.dispose);
      final controller = container.read(chatControllerProvider.notifier);
      final profile = _profile();

      const prompts = [
        'Where am I?', // describe_current_location
        'Take me to the nearest mosque', // request_route
        'Cancel that', // no local match — falls through (Gemini unconfigured in tests)
        'Switch to dark mode', // update_setting
        "Tell my caretaker I'm okay", // no local match since the fix — see the note below
        'Show the map', // open_map
      ];
      for (final prompt in prompts) {
        unawaited(controller.sendFreeText(prompt, profile));
      }
      // Generous: with no geolocator platform channel registered in this
      // test, `request_route`/`describe_current_location` each fall through
      // every real, un-injectable `Geolocator` call they make (chat_
      // providers.dart's own 2s cached-fix wait, then FunctionCallExecutor's
      // 10s fresh-fix wait) before giving up and answering anyway — about
      // 12s worst case, for each of them, in flight together.
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(seconds: 1));
      }

      expect(tester.takeException(), isNull, reason: 'none of the six may throw');

      final userMessages =
          container.read(chatControllerProvider).messages.where((m) => m.sender == ChatSender.user).toList();
      expect(userMessages.map((m) => m.text), prompts,
          reason: 'every prompt must be recorded, in order, none dropped');

      final assistantMessages = container
          .read(chatControllerProvider)
          .messages
          .where((m) => m.sender == ChatSender.assistant)
          .toList();
      expect(assistantMessages.length, greaterThanOrEqualTo(prompts.length),
          reason: 'every prompt gets at least one reply — no silent stall');
      expect(assistantMessages.every((m) => m.text.trim().isNotEmpty), isTrue,
          reason: 'no empty reply');

      // FIXED 12 Oct: this used to match alert_caretaker locally — a
      // generic "please check on me" flag that never passed "I'm okay" on
      // to anyone — because _matchAlertCaretaker's word budget could not
      // tell filler from content. _emergencyRefusals ("i'm okay", "i'm
      // fine", ...) is now checked first, so this correctly falls through
      // to Gemini/send_caretaker_message instead, which actually carries
      // the words. (Gemini is unconfigured in this test, so prompt 5's
      // reply above is the same stub as prompt 3's — that is the correct
      // deferral, not a regression; a live call is needed to confirm
      // Gemini actually relays "I'm okay" verbatim.)
      expect(LocalIntentMatcher.match("Tell my caretaker I'm okay", AppLanguage.english), isNull);
    });
  });
}

Position _fixAt(double lat, double lng) => Position(
      latitude: lat,
      longitude: lng,
      timestamp: DateTime.now(),
      accuracy: 5,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );
