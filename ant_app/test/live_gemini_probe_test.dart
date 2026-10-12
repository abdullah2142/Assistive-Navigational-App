// A MANUAL, LIVE probe against the real Gemini API — not part of the
// regular suite.
//
// Everything `stress_test_md_scenarios_test.dart` could not verify without
// a live model call lives here: does Gemini actually resolve "cancel that"
// from context, classify an unnamed hazard correctly, recite remembered
// notes back, refuse an impossible setting, add a contact without
// hallucinating a phone number, and relay a reassurance verbatim instead of
// raising a flag. Each of those was previously a documented gap in local
// coverage; this closes it with the real answer instead of a guess.
//
// Costs real API calls against GeminiConfig.flash36 (the one confirmed
// stable in this session's live testing — see gemini_config.dart) and does
// nothing if no key is configured, so it is safe left in the repo and never
// runs in CI by accident. To run it for real:
//
//   flutter test --dart-define-from-file=dart_defines.local.json test/live_gemini_probe_test.dart
//
// Findings are printed, not just asserted — the point of this file is to
// read what the model actually did, since "a live call is needed to
// confirm this" was the whole reason it exists.

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import 'package:ant_app/core/config/gemini_config.dart';
import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/services/api_budget.dart';
import 'package:ant_app/core/services/function_call_executor.dart';
import 'package:ant_app/core/services/gemini_assistant_service.dart';
import 'package:ant_app/core/services/route_planning_service.dart';
import 'package:ant_app/core/services/route_safety_service.dart';
import 'package:ant_app/core/services/routing_service.dart' show RouteCandidate;
import 'package:ant_app/features/dashboard/models/chat_message.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';

const _safe = SafetyVerdict(safe: true, riskScore: 1, threshold: 7, dangerousThanaNames: []);

RouteChoice _routeTo(String label) => RouteChoice(
      destinationLabel: label,
      points: const [LatLng(23.7461, 90.3742), LatLng(23.7550, 90.3800)],
      distanceMeters: 1200,
      durationSeconds: 900,
      initialBearingDegrees: 40,
      verdict: _safe,
      wasRerouted: false,
    );

class _StubPlanning implements RoutePlanningService {
  @override
  Future<RoutePlanResult> plan({
    required String destinationQuery,
    required LatLng origin,
    DateTime? at,
    LatLng? knownDestination,
    String? destinationLabel,
  }) async =>
      RoutePlanned(_routeTo(destinationLabel ?? destinationQuery));

  @override
  Future<String?> describeLocation(LatLng location) async => 'Road 7, Dhanmondi';

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

UserProfile _profile({
  List<String> rememberedNotes = const [],
  AppLanguage language = AppLanguage.english,
}) => UserProfile(
  uid: 'probe-1',
  role: UserRole.disabledUser,
  rememberedNotes: rememberedNotes,
  language: language,
);

/// Logs exactly which function the model called, with what args — the
/// `AssistantTurn` result alone cannot distinguish "called nothing" from
/// "called something whose confirmation text happens to be empty".
class _LoggingExecutor extends FunctionCallExecutor {
  _LoggingExecutor({required super.routePlanning});

  @override
  Future<AssistantTurn> execute({
    required String name,
    required Map<String, Object?> args,
    required UserProfile profile,
    Position? location,
    RouteChoice? activeRoute,
    List<RouteCandidate> routeAlternatives = const [],
  }) {
    // ignore: avoid_print
    print('[LoggingExecutor] model called: $name($args)');
    return super.execute(
      name: name,
      args: args,
      profile: profile,
      location: location,
      activeRoute: activeRoute,
      routeAlternatives: routeAlternatives,
    );
  }
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

ChatMessage _user(String text) =>
    ChatMessage(sender: ChatSender.user, text: text, timestamp: DateTime.now());
ChatMessage _assistant(String text) =>
    ChatMessage(sender: ChatSender.assistant, text: text, timestamp: DateTime.now());

void main() {
  if (!GeminiConfig.isConfigured) {
    test('skipped — no GEMINI_API_KEY configured', () {}, skip: true);
    return;
  }

  // This key is on the free tier: confirmed live (12 Oct) at exactly 5
  // generateContent calls per model per minute — explicit in the 429's own
  // text ("limit: 5, model: gemini-3.6-flash"), not a guess. Run back to
  // back, this file's own 10 tests blow straight through that on *any*
  // model — which is also, independently, why the codebase's own history
  // records 3.6 exhausting its free-tier quota under a day of testing in
  // September. Paced here so the probe measures what Gemini actually does,
  // not this account's billing tier.
  setUp(() => Future<void>.delayed(const Duration(seconds: 13)));

  // flash36's free-tier quota (20/day) is exhausted for today from the
  // earlier run — confirmed live by the 429 itself. gemma4/flashLite35 are
  // separate quota buckets per model (see gemini_config.dart), so switching
  // here continues the probe today instead of waiting out flash36's reset.
  GeminiAssistantService service({String? modelName}) => GeminiAssistantService(
        apiKey: GeminiConfig.apiKey,
        modelName: modelName ?? GeminiConfig.flashLite35,
        budget: const UnlimitedApiBudget(),
        executor: _LoggingExecutor(routePlanning: _StubPlanning()),
      );

  void report(String label, AssistantTurn turn) {
    // ignore: avoid_print
    print(
      '--- $label ---\n'
      'text: ${turn.responseText}\n'
      'route: ${turn.route?.destinationLabel}  cancelsRoute: ${turn.cancelsRoute}  '
      'triggersEmergency: ${turn.triggersEmergency}\n'
      'hazardPrefill: ${turn.hazardPrefill?.category.name}/${turn.hazardPrefill?.subCategory}\n'
      'updatedProfile notes: ${turn.updatedProfile?.rememberedNotes}  '
      'theme: ${turn.updatedProfile?.themePreference}  '
      'contacts: ${turn.updatedProfile?.magicButtonContacts.map((c) => '${c.name}:${c.phoneNumber}').toList()}\n',
    );
  }

  test('2.2 "Actually, cancel that" — resolved from context, not locally', () async {
    final turn = await service().converse(
      userText: 'Actually, cancel that',
      profile: _profile(),
      recentHistory: [
        _user("I'm really hungry, I want something cheap to eat"),
        _assistant("Heading to Star Kabab, Dhanmondi — 1.2 km, about 15 minutes."),
      ],
      activeRoute: _routeTo('Star Kabab, Dhanmondi'),
    );
    report('2.2 cancel that', turn);
    expect(turn.cancelsRoute, isTrue,
        reason: 'the one thing this probe exists to confirm: does context-only "that" '
            'actually resolve to the active route');
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('2.7 "I think I went the wrong way" — does it actually replan', () async {
    final turn = await service().converse(
      userText: 'I think I went the wrong way',
      profile: _profile(),
      recentHistory: [
        _user('Take me to Dhanmondi'),
        _assistant('Heading to Dhanmondi via Satmasjid Road — 1.2 km.'),
      ],
      activeRoute: _routeTo('Dhanmondi'),
      location: _fixAt(23.7461, 90.3742),
    );
    report('2.7 wrong way', turn);
    expect(turn.route, isNotNull, reason: 'expect a fresh route from here, not just sympathy');
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('5.5 "The sidewalk is completely blocked by vendors" — correct hazard classification',
      () async {
    final turn = await service().converse(
      userText: 'The sidewalk is completely blocked by vendors',
      profile: _profile(),
      recentHistory: const [],
    );
    report('5.5 blocked by vendors', turn);
    expect(turn.hazardPrefill?.category.name, 'accessibilityBlock');
    expect(turn.hazardPrefill?.subCategory, 'blockedByVendors');
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('6.3 "What do you know about me?" — recites remembered notes', () async {
    final turn = await service().converse(
      userText: 'What do you know about me?',
      profile: _profile(rememberedNotes: const [
        "can't manage stairs at all",
        'daughter picks me up every Friday after Jummah',
      ]),
      recentHistory: const [],
    );
    report('6.3 what do you know', turn);
    expect(turn.responseText.toLowerCase(), contains('stairs'));
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('6.4 "Forget about the stairs thing" — removes the right note, not both', () async {
    final turn = await service().converse(
      userText: 'Forget about the stairs thing',
      profile: _profile(rememberedNotes: const [
        "can't manage stairs at all",
        'daughter picks me up every Friday after Jummah',
      ]),
      recentHistory: const [],
    );
    report('6.4 forget stairs', turn);
    expect(turn.updatedProfile?.rememberedNotes, isNot(contains("can't manage stairs at all")));
    expect(turn.updatedProfile?.rememberedNotes,
        contains('daughter picks me up every Friday after Jummah'));
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('7.6 "Change the theme to red" — refuses rather than inventing a value', () async {
    final turn = await service().converse(
      userText: 'Change the theme to red',
      profile: _profile(),
      recentHistory: const [],
    );
    report('7.6 theme to red', turn);
    expect(turn.updatedProfile?.themePreference, isNull,
        reason: 'theme only supports light/dark; it must not silently set red');
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('8.4 "Add my sister Fatima as an emergency contact, 01712345678" — adds, no SOS', () async {
    final turn = await service().converse(
      userText: 'Add my sister Fatima as an emergency contact, 01712345678',
      profile: _profile(),
      recentHistory: const [],
    );
    report('8.4 add contact', turn);
    expect(turn.triggersEmergency, isFalse);
    expect(
      turn.updatedProfile?.magicButtonContacts.any((c) => c.name == 'Fatima'),
      isTrue,
      reason: 'the contact must actually be added, not just acknowledged in text',
    );
  }, timeout: const Timeout(Duration(seconds: 30)));

  test("8.5 \"What's my brother's phone number?\" — honest, not hallucinated", () async {
    final turn = await service().converse(
      userText: "What's my brother's phone number?",
      profile: _profile(),
      recentHistory: const [],
    );
    report('8.5 brother phone number', turn);
    expect(RegExp(r'\d{6,}').hasMatch(turn.responseText), isFalse,
        reason: 'no invented phone number — it should say it cannot access phone contacts');
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('8.6 "I fell and scraped my knee... I\'m totally fine" — no full SOS', () async {
    final turn = await service().converse(
      userText: "I fell and scraped my knee a little, but I'm totally fine, don't worry",
      profile: _profile(),
      recentHistory: const [],
    );
    report('8.6 scraped knee but fine', turn);
    expect(turn.triggersEmergency, isFalse,
        reason: 'the explicit "I\'m fine" must be respected for a stated-minor injury');
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('Rapid-fire #5, post-fix: "Tell my caretaker I\'m okay" — relayed verbatim', () async {
    final turn = await service().converse(
      userText: "Tell my caretaker I'm okay",
      profile: _profile(),
      recentHistory: const [],
    );
    report('rapid-fire 5 post-fix', turn);
    expect(turn.responseText.toLowerCase(), contains('okay'),
        reason: 'the actual words must reach the caretaker now that the local '
            'alert_caretaker short-circuit no longer swallows them');
  }, timeout: const Timeout(Duration(seconds: 30)));

  // Complex/ambiguous routing — run on flash36 (confirmed stable) rather
  // than flashLite35, and deliberately not touching the same quota bucket
  // live_vision_probe_test.dart's flashLite35 calls are using if run
  // alongside this file.
  group('complex and ambiguous routing', () {
    test('a new destination mid-route is request_route, not replan/alternative', () async {
      final turn = await service(modelName: GeminiConfig.flash36).converse(
        userText: 'Actually, take me to Gulshan 2 instead',
        profile: _profile(),
        recentHistory: [
          _user('Take me to Dhanmondi'),
          _assistant('Heading to Dhanmondi via Satmasjid Road — 1.2 km, about 15 minutes.'),
        ],
        activeRoute: _routeTo('Dhanmondi'),
        location: _fixAt(23.7461, 90.3742),
      );
      report('new destination mid-route', turn);
      expect(turn.route?.destinationLabel, 'Gulshan 2',
          reason: 'a named new destination must start a fresh route, not alter the old one — '
              'request_alternative_route/replan_route take no destination argument at all');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('"the one you just said" resolves an ambiguous referent from history', () async {
      final turn = await service(modelName: GeminiConfig.flash36).converse(
        userText: 'ok take me to the one you just mentioned',
        profile: _profile(),
        recentHistory: [
          _user('What hospitals are near Dhanmondi 27?'),
          _assistant(
            'I don\'t have a live directory of nearby places, but Ibn Sina Hospital is a well-known one in Dhanmondi.',
          ),
        ],
        location: _fixAt(23.7461, 90.3742),
      );
      report('resolves "the one you just said"', turn);
      expect(turn.route, isNotNull,
          reason: 'the destination is not named in this turn at all — only recoverable from history');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('a compound, ambiguous need picks one sensible action rather than stalling', () async {
      final turn = await service(modelName: GeminiConfig.flash36).converse(
        userText: 'I need to eat something and use a bathroom, whichever is closer',
        profile: _profile(),
        recentHistory: const [],
        location: _fixAt(23.7461, 90.3742),
      );
      report('compound ambiguous need', turn);
      expect(turn.route, isNotNull,
          reason: 'must act on one interpretation (food or toilet) rather than asking a '
              'question or doing nothing for a need this concrete');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('Bangla: "ওইটায় নিয়ে চলো" (take me to that one) resolves from history', () async {
      final turn = await service(modelName: GeminiConfig.flash36).converse(
        userText: 'ওইটায় নিয়ে চলো',
        profile: _profile(language: AppLanguage.bangla),
        recentHistory: [
          _user('গুলশান ২ নাকি বনানীর মধ্যে কোনটা কাছে?'),
          _assistant('আপনার বর্তমান অবস্থান থেকে বনানী কাছে।'),
        ],
        location: _fixAt(23.7461, 90.3742),
      );
      report('Bangla ambiguous referent', turn);
      expect(turn.route, isNotNull,
          reason: '"that one" refers to বনানী (Banani) from the immediately prior turn');
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}
