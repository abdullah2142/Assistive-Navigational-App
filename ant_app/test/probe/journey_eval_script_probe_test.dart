import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geolocator_platform_interface/geolocator_platform_interface.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';
import 'package:ant_app/core/localization/onboarding_strings.dart';
import 'package:ant_app/core/providers/ai_assistant_providers.dart';
import 'package:ant_app/core/providers/tts_providers.dart';
import 'package:ant_app/core/services/assistant_service.dart';
import 'package:ant_app/core/services/emergency_service.dart';
import 'package:ant_app/core/services/function_call_executor.dart';
import 'package:ant_app/core/services/gemini_assistant_service.dart';
import 'package:ant_app/core/services/local_intent_matcher.dart';
import 'package:ant_app/core/services/navigation_controller.dart';
import 'package:ant_app/core/services/place_categories.dart';
import 'package:ant_app/core/services/route_planning_service.dart';
import 'package:ant_app/core/services/route_safety_service.dart';
import 'package:ant_app/core/services/routing_service.dart';
import 'package:ant_app/core/services/stt_service.dart';
import 'package:ant_app/core/services/tts_service.dart';
import 'package:ant_app/core/services/weather_service.dart';
import 'package:ant_app/features/dashboard/models/chat_message.dart';
import 'package:ant_app/features/dashboard/models/hazard_report.dart';
import 'package:ant_app/features/dashboard/providers/chat_providers.dart';
import 'package:ant_app/features/dashboard/providers/dashboard_providers.dart';
import 'package:ant_app/features/dashboard/services/hazard_report_service.dart';
import 'package:ant_app/features/dashboard/widgets/crowdsource_reporting_hub.dart';
import 'package:ant_app/features/guardian/models/guardian_alert.dart';
import 'package:ant_app/features/guardian/providers/guardian_providers.dart';
import 'package:ant_app/features/guardian/services/alert_service.dart';
import 'package:ant_app/features/guardian/services/communication_service.dart';
import 'package:ant_app/features/onboarding/models/onboarding_step.dart';
import 'package:ant_app/features/onboarding/models/trusted_contact.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';
import 'package:ant_app/features/onboarding/providers/onboarding_providers.dart';
import 'package:ant_app/features/onboarding/services/profile_service.dart';

// ---------------------------------------------------------------------------
// Fakes at the edges. Everything between them is the real app code.
// ---------------------------------------------------------------------------

Position _fix() => Position(
      latitude: 23.7461,
      longitude: 90.3742,
      timestamp: DateTime.now(),
      accuracy: 5,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );

class FakeGeo extends GeolocatorPlatform with MockPlatformInterfaceMixin {
  @override
  Future<Position?> getLastKnownPosition({bool forceLocationManager = false}) async => _fix();
  @override
  Future<Position> getCurrentPosition({LocationSettings? locationSettings}) async => _fix();
}

class FakeTts implements TtsService {
  final spoken = <String>[];
  @override
  Future<void> speak(String text, {AppLanguage language = AppLanguage.english}) async {
    spoken.add(text);
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  @override
  Future<void> stop() async {}
  @override
  void setVoiceId(String voiceId) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// Hears nothing, ever: the participant is silent or mute.
class SilentStt extends SttService {
  @override
  Future<bool> ensureAvailable() async => true;
  @override
  Future<void> listenOnce({
    required AppLanguage language,
    required void Function(String text, bool isFinal) onResult,
    Duration pauseFor = const Duration(seconds: 3),
    Duration listenFor = const Duration(minutes: 5),
    Duration? initialSilence,
    List<String> phraseHints = const [],
  }) async {
    await Completer<void>().future;
  }

  @override
  Future<void> stop() async {}
}

/// Says the scripted utterances, one per listen, then goes silent.
class ScriptedStt extends SttService {
  ScriptedStt(this.utterances);
  final List<String> utterances;
  var calls = 0;
  @override
  Future<bool> ensureAvailable() async => true;
  @override
  Future<void> listenOnce({
    required AppLanguage language,
    required void Function(String text, bool isFinal) onResult,
    Duration pauseFor = const Duration(seconds: 3),
    Duration listenFor = const Duration(minutes: 5),
    Duration? initialSilence,
    List<String> phraseHints = const [],
  }) async {
    if (calls < utterances.length) {
      onResult(utterances[calls++], true);
      return;
    }
    await Completer<void>().future;
  }

  @override
  Future<void> stop() async {}
}

class FakeAlerts implements AlertService {
  final created = <GuardianAlertType>[];
  @override
  Stream<List<GuardianAlert>> watchAlerts(String u) => const Stream.empty();
  @override
  Future<bool> createAlert({
    required String disabledUserUid,
    required GuardianAlertType type,
    double? lat,
    double? lng,
    int? batteryPercent,
    List<String> notifiedContacts = const [],
  }) async {
    created.add(type);
    return true;
  }

  @override
  Future<bool> publishLocation({required String disabledUserUid, required double lat, required double lng}) async => true;
  @override
  Future<void> resolveAlert(String d, String a) async {}
}

class FakeProfiles implements ProfileService {
  final saved = <UserProfile>[];
  @override
  Future<void> saveProfile(UserProfile profile) async => saved.add(profile);
  @override
  Future<UserProfile?> fetchProfile(String uid) async => null;
  @override
  Stream<UserProfile?> watchProfile(String uid) => const Stream.empty();
  @override
  Future<void> saveOnboardingStep({required String uid, required OnboardingStep step}) async {}
}

class FakeComm implements CommunicationService {
  final memos = <String>[];
  @override
  Future<void> sendMemo({required String disabledUserUid, required String fromUid, required String toUid, required String text}) async {
    memos.add(text);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

const _safe = SafetyVerdict(safe: true, riskScore: 1, threshold: 7, dangerousThanaNames: []);
RouteChoice routeTo(String label) => RouteChoice(
      destinationLabel: label,
      points: const [LatLng(23.7461, 90.3742), LatLng(23.7550, 90.3800)],
      distanceMeters: 1200,
      durationSeconds: 900,
      initialBearingDegrees: 40,
      verdict: _safe,
      wasRerouted: false,
    );

/// "the market" is ambiguous, "gulshan" resolves, anything else is not found.
/// Records every query that reaches the geocoder.
class FakePlanner implements RoutePlanningService {
  final queries = <String>[];
  Duration delay = Duration.zero;
  @override
  Future<RoutePlanResult> plan({
    required String destinationQuery,
    required LatLng origin,
    DateTime? at,
    LatLng? knownDestination,
    String? destinationLabel,
  }) async {
    queries.add(destinationQuery);
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (knownDestination != null) return RoutePlanned(routeTo(destinationLabel ?? destinationQuery));
    final q = destinationQuery.toLowerCase();
    if (q == 'the market') {
      return const RoutePlanAmbiguous([
        GeocodeCandidate(label: 'Karwan Bazar Market, Tejgaon, Dhaka', location: LatLng(23.7510, 90.3930)),
        GeocodeCandidate(label: 'New Market, Azimpur, Dhaka', location: LatLng(23.7330, 90.3850)),
      ]);
    }
    if (q.contains('gulshan')) return RoutePlanned(routeTo('Gulshan'));
    return const RoutePlanFailed('destination_not_found');
  }

  @override
  Future<String?> describeLocation(LatLng l) async => 'Road 7, Dhanmondi';
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// The model backend is unreachable (airplane mode, 3G stall, quota).
class DownLlm implements AssistantService {
  @override
  String get backendName => 'down';
  @override
  Future<AssistantTurn> converse({
    required String userText,
    required UserProfile profile,
    required List<ChatMessage> recentHistory,
    Position? location,
    void Function(String partialText)? onPartialText,
    RouteChoice? activeRoute,
    List<RouteCandidate> routeAlternatives = const [],
  }) async {
    throw TimeoutException('assistant unreachable');
  }
}

class _Doc {}

class FakeReports implements HazardReportService {
  final submitted = <HazardReport>[];
  @override
  Future<void> submitReport(HazardReport report) {
    submitted.add(report);
    return Future<_Doc>.value(_Doc());
  }
}

UserProfile participant({
  bool paired = true,
  bool contacts = true,
  AppLanguage language = AppLanguage.english,
}) =>
    UserProfile(
      uid: 'p01',
      role: UserRole.disabledUser,
      language: language,
      pairedUserId: paired ? 'test-caretaker' : null,
      magicButtonContacts: contacts
          ? const [
              TrustedContact(name: 'Amma', phoneNumber: '01711111111', isPrimary: true),
              TrustedContact(name: 'Bhai', phoneNumber: '01822222222'),
            ]
          : const [],
    );

/// One phone, one sitting: every provider the nine tasks share.
class Phone {
  Phone({this.llm}) {
    container = ProviderContainer(overrides: [
      ttsServiceProvider.overrideWithValue(tts),
      sttServiceProvider.overrideWithValue(SilentStt()),
      alertServiceProvider.overrideWithValue(alerts),
      communicationServiceProvider.overrideWithValue(comm),
      routePlanningServiceProvider.overrideWithValue(planner),
      profileServiceProvider.overrideWithValue(profiles),
      weatherServiceProvider.overrideWithValue(
        WeatherService(client: http_testing.MockClient((r) async => http.Response('{}', 500))),
      ),
      functionCallExecutorProvider.overrideWithValue(
        FunctionCallExecutor(
          routePlanning: planner,
          alertService: alerts,
          communicationService: comm,
          freshLocation: () async => _fix(),
        ),
      ),
      geminiAssistantServiceProvider.overrideWithValue(llm ?? DownLlm()),
    ]);
    chat = container.read(chatControllerProvider.notifier);
  }

  final AssistantService? llm;
  final tts = FakeTts();
  final alerts = FakeAlerts();
  final comm = FakeComm();
  final planner = FakePlanner();
  final profiles = FakeProfiles();
  late final ProviderContainer container;
  late final ChatController chat;

  ChatState get state => container.read(chatControllerProvider);
  EmergencyPhase get phase => container.read(emergencyPhaseProvider).value;

  /// Assistant bubbles added since [from] (not user text, not debug banners).
  List<String> repliesSince(int from) => state.messages
      .skip(from)
      .where((m) => m.sender == ChatSender.assistant)
      .map((m) => m.text)
      .toList();

  /// Says [text] (typed and spoken take the same door) and lets time pass.
  Future<List<String>> say(WidgetTester tester, String text, UserProfile profile, {int seconds = 6}) async {
    final from = state.messages.length;
    unawaited(chat.sendFreeText(text, profile));
    for (var i = 0; i < seconds * 2; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    return repliesSince(from);
  }

  Future<void> wait(WidgetTester tester, int seconds) async {
    for (var i = 0; i < seconds; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
  }

  void dispose() => container.dispose();
}

/// Records which emergency-channel calls (SMS, phone call, battery) happen.
final channelCalls = <String>[];

void installPlatformFakes() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GeolocatorPlatform.instance = FakeGeo();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (c) async => null);
  messenger.setMockMethodCallHandler(const MethodChannel('com.ant.assistive.ant_app/emergency'), (c) async {
    channelCalls.add(c.method);
    if (c.method == 'batteryPercent') return 80;
    return null;
  });
}

// ---------------------------------------------------------------------------
// Task 3: a mock-GPS walk along a real polyline.
// ---------------------------------------------------------------------------

class QuietRouting implements RoutingService {
  @override
  Future<List<NearbyRefuge>> nearbyOfCategory({
    required LatLng origin,
    required PlaceCategory category,
    double radiusMeters = 1500,
    Duration timeout = const Duration(seconds: 12),
  }) async => const [];
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

const _o = LatLng(23.7461, 90.3742);
LatLng _at(double north, double east) =>
    LatLng(_o.latitude + north / 111320.0, _o.longitude + east / (111320.0 * 0.9166));

/// 400 m north, left, 300 m west, right, 250 m north, arrive. Vertices every 10 m.
RouteChoice walkRoute() {
  final pts = <LatLng>[
    for (var n = 0.0; n <= 400; n += 10) _at(n, 0),
    for (var e = -10.0; e >= -300; e -= 10) _at(400, e),
    for (var n = 410.0; n <= 650; n += 10) _at(n, -300),
  ];
  return RouteChoice(
    destinationLabel: 'Test Road',
    points: pts,
    distanceMeters: 950,
    durationSeconds: 800,
    initialBearingDegrees: 0,
    verdict: _safe,
    wasRerouted: false,
    steps: [
      RouteStep(location: _at(400, 0), distanceMeters: 400, maneuver: ManeuverKind.left, streetName: 'A Road'),
      RouteStep(location: _at(400, -300), distanceMeters: 300, maneuver: ManeuverKind.right, streetName: 'B Road'),
      RouteStep(location: _at(650, -300), distanceMeters: 250, maneuver: ManeuverKind.arrive),
    ],
  );
}

Position _gps(LatLng p, double accuracy) => Position(
      latitude: p.latitude,
      longitude: p.longitude,
      timestamp: DateTime.now(),
      accuracy: accuracy,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 1.2,
      speedAccuracy: 0,
    );

/// Walks [route] at 1.2 m/s, one fix per second, each fix [noiseMin]-[noiseMax]
/// metres off, with a 20 s pause at about 200 m. Returns everything spoken.
Future<List<String>> walkAndCollect({int seed = 1, double noiseMin = 3, double noiseMax = 8}) async {
  final rnd = math.Random(seed);
  final tts = FakeTts();
  final stream = StreamController<Position>.broadcast();
  final nav = NavigationController(tts: tts, positionStream: stream.stream, routing: QuietRouting());
  final route = walkRoute();
  await nav.start(route, language: AppLanguage.english);
  var metres = 0.0;
  var tick = 0;
  while (metres <= 950 + 5 && tick < 3000) {
    tick++;
    final base = route.points[(metres / 10).floor().clamp(0, route.points.length - 1)];
    final r = noiseMin + rnd.nextDouble() * (noiseMax - noiseMin);
    final a = rnd.nextDouble() * 2 * math.pi;
    final p = LatLng(
      base.latitude + r * math.sin(a) / 111320.0,
      base.longitude + r * math.cos(a) / (111320.0 * 0.9166),
    );
    final fixes = tick == 150 ? 21 : 1; // the pause: 20 extra fixes in place
    for (var k = 0; k < fixes; k++) {
      stream.add(_gps(p, 5 + rnd.nextDouble() * 10));
      await Future<void>.delayed(Duration.zero);
    }
    metres += 1.2;
  }
  await Future<void>.delayed(const Duration(milliseconds: 400));
  await nav.stop(silent: true);
  await stream.close();
  return tts.spoken;
}

void main() {
  installPlatformFakes();
  setUp(channelCalls.clear);

  // ---- Task 6 -------------------------------------------------------------

  testWidgets('Task 6: a typed "cancel" inside the countdown stops the alarm, sends nothing, and says so', (tester) async {
    final phone = Phone();
    addTearDown(phone.dispose);
    final p = participant();
    unawaited(phone.chat.sendFreeText('someone is following me and I am scared', p));
    await phone.wait(tester, 2);
    expect(phone.phase, EmergencyPhase.countdown, reason: 'natural words, no "help", start the alarm');

    final from = phone.state.messages.length;
    unawaited(phone.chat.sendFreeText('cancel', p));
    await phone.wait(tester, 2);
    await phone.wait(tester, 8);

    expect(phone.phase, EmergencyPhase.idle);
    expect(phone.repliesSince(from), [Dashboard.of(AppLanguage.english).emergencyCancelled]);
    expect(phone.alerts.created, isEmpty);
    expect(channelCalls, isNot(contains('sendSms')));
    expect(channelCalls, isNot(contains('placeCall')));
  });

  testWidgets('Task 6: the tester build rehearses the whole sequence but never texts or dials anyone', (tester) async {
    final phone = Phone();
    addTearDown(phone.dispose);
    unawaited(phone.chat.sendFreeText('i am in danger', participant()));
    await phone.wait(tester, 20);

    final d = Dashboard.of(AppLanguage.english);
    expect(phone.tts.spoken.first, d.emergencyActivated, reason: 'heard first, before anything else');
    expect(phone.tts.spoken.any((s) => s.contains('Say cancel')), isTrue, reason: 'the cancel window is announced');
    expect(phone.tts.spoken.last, d.emergencyRehearsal(2));
    expect(phone.state.messages.last.text, d.emergencyRehearsal(2));
    expect(channelCalls, isNot(contains('sendSms')));
    expect(channelCalls, isNot(contains('placeCall')));
    expect(phone.phase, EmergencyPhase.idle);
  });

  test('Task 6: scared people who never say "help" still reach the alarm (local, no network)', () {
    for (final phrase in [
      'someone is following me and I am scared',
      'i am in danger',
      'i might faint',
      'please help',
      'sos',
    ]) {
      expect(LocalIntentMatcher.match(phrase, AppLanguage.english)?.name, 'trigger_emergency', reason: phrase);
    }
    for (final phrase in ['বাঁচাও', 'আমি বিপদে পড়েছি', 'bachao']) {
      expect(LocalIntentMatcher.match(phrase, AppLanguage.bangla)?.name, 'trigger_emergency', reason: phrase);
    }
  });

  test('Task 6: saying the alarm was a mistake never starts one', () {
    for (final phrase in ["i'm fine", 'false alarm', 'oops that was a mistake', 'cancel the emergency']) {
      expect(LocalIntentMatcher.match(phrase, AppLanguage.english)?.name, isNot('trigger_emergency'), reason: phrase);
    }
  });

  // ---- Task 7 -------------------------------------------------------------

  test('Task 7: "okay" reassurances are neither an SOS nor the generic check-on-me alert', () {
    for (final phrase in [
      "tell my caretaker I'm okay",
      'tell them I am okay',
      'let my caretaker know I am alright',
      'message my caretaker I am okay',
      'tell my caretaker I am fine',
    ]) {
      final name = LocalIntentMatcher.match(phrase, AppLanguage.english)?.name;
      expect(name, isNot('trigger_emergency'), reason: phrase);
      expect(name, isNot('alert_caretaker'), reason: phrase);
    }
  });

  test('Task 7: send_caretaker_message delivers the participant\'s own words and raises no alert', () async {
    final alerts = FakeAlerts();
    final comm = FakeComm();
    final executor = FunctionCallExecutor(alertService: alerts, communicationService: comm);
    final turn = await executor.execute(
      name: 'send_caretaker_message',
      args: {'message': 'I am okay'},
      profile: participant(),
      location: null,
    );
    expect(comm.memos, ['I am okay']);
    expect(alerts.created, isEmpty);
    expect(turn.responseText, isNotEmpty);
  });

  test('Task 7: before pairing, the caretaker message says so instead of pretending', () async {
    final comm = FakeComm();
    final turn = await FunctionCallExecutor(communicationService: comm).execute(
      name: 'send_caretaker_message',
      args: {'message': 'I am okay'},
      profile: participant(paired: false),
      location: null,
    );
    expect(comm.memos, isEmpty);
    expect(turn.responseText, Dashboard.of(AppLanguage.english).alertCaretakerNotPaired);
  });

  testWidgets('Task 7: "send a message to my caretaker" then "I am okay" delivers exactly those words', (tester) async {
    final phone = Phone();
    addTearDown(phone.dispose);
    final p = participant();
    final ask = await phone.say(tester, 'send a message to my caretaker', p);
    expect(ask.single, contains('What message'));
    final done = await phone.say(tester, 'I am okay', p);
    expect(phone.comm.memos, ['I am okay']);
    expect(done.single, Dashboard.of(AppLanguage.english).caretakerMemoSent);
    expect(phone.state.caretakerMessageArmed, isFalse, reason: 'one shot: the next sentence is a command again');
  });

  // ---- Tasks 2 and 4 -----------------------------------------------------

  testWidgets('Tasks 2 and 4: "the market" asks, "the second one" routes there, "stop the trip" ends it, then a new route starts', (tester) async {
    final phone = Phone();
    addTearDown(phone.dispose);
    final p = participant();

    final ask = await phone.say(tester, 'take me to the market', p);
    expect(ask.join(' '), contains('Karwan Bazar'));
    expect(ask.join(' '), contains('New Market'));
    expect(phone.state.pendingRoute, isNull, reason: 'it asks, it does not guess');
    expect(phone.state.pendingClarification, isNotNull);

    final routed = await phone.say(tester, 'the second one', p);
    expect(routed.join(' '), contains('New Market'));
    expect(phone.state.pendingRoute?.destinationLabel, 'New Market, Azimpur');
    expect(phone.state.pendingClarification, isNull);

    final stopped = await phone.say(tester, 'stop the trip', p);
    expect(stopped.single, Dashboard.of(AppLanguage.english).routeCancelled);
    expect(phone.state.pendingRoute, isNull);

    await phone.say(tester, 'take me to Gulshan', p);
    expect(phone.state.pendingRoute?.destinationLabel, 'Gulshan');
  });

  testWidgets('Tasks 2 and 4: giving up on the question ("never mind") clears it for the next task', (tester) async {
    final phone = Phone();
    addTearDown(phone.dispose);
    final p = participant();
    await phone.say(tester, 'take me to the market', p);
    final reply = await phone.say(tester, 'never mind', p);
    expect(reply.single, Dashboard.of(AppLanguage.english).clarifyCancelled);
    expect(phone.state.pendingClarification, isNull);
    final where = await phone.say(tester, 'where am i', p);
    expect(where.join(' '), contains('Road 7'));
  });

  test('Task 2: Bangla and Banglish "I want to go to X" are recognised locally', () {
    expect(LocalIntentMatcher.match('আমি বাজারে যেতে চাই', AppLanguage.bangla)?.name, 'request_route');
    expect(LocalIntentMatcher.match('amake gulshan niye jao', AppLanguage.english)?.name, 'request_route');
    expect(LocalIntentMatcher.match('take me to the market', AppLanguage.english)?.args['destination'], 'the market');
  });

  // ---- Task 3 ------------------------------------------------------------

  test('Task 3: a noisy 1.2 m/s walk (3-8 m GPS error, a 20 s pause) announces each turn once per band, never wanders off route, and arrives once', () async {
    final d = Dashboard.of(AppLanguage.english);
    for (final seed in [1, 2, 3, 4, 5]) {
      final spoken = await walkAndCollect(seed: seed);
      bool turn(String s, String word) => s.startsWith('In ') || s.startsWith('Now') ? s.contains(word) : false;
      expect(spoken.where((s) => turn(s, 'turn left onto A Road')).length, 3, reason: 'seed $seed: 200 m, 50 m, now. $spoken');
      expect(spoken.where((s) => turn(s, 'turn right onto B Road')).length, 3, reason: 'seed $seed. $spoken');
      expect(spoken.where((s) => s == d.navigateOffRoute), isEmpty, reason: 'seed $seed: no re-route storm');
      expect(spoken.where((s) => s == d.navigateArrived).length, 1, reason: 'seed $seed: arrival exactly once');
      expect(spoken.last, d.navigateArrived, reason: 'seed $seed: nothing after arrival');
    }
  });

  test('Task 3: a fix 120 m off (urban canyon) is ignored, a real departure is reported once', () async {
    final d = Dashboard.of(AppLanguage.english);
    final tts = FakeTts();
    final stream = StreamController<Position>.broadcast();
    final nav = NavigationController(tts: tts, positionStream: stream.stream, routing: QuietRouting());
    await nav.start(walkRoute(), language: AppLanguage.english);
    final before = tts.spoken.length;
    stream.add(_gps(_at(100, 120), 120));
    await Future<void>.delayed(Duration.zero);
    expect(tts.spoken.length, before, reason: 'a 120 m accuracy fix says nothing');
    for (var i = 0; i < 5; i++) {
      stream.add(_gps(_at(100, 80), 8));
      await Future<void>.delayed(Duration.zero);
    }
    expect(tts.spoken.where((s) => s == d.navigateOffRoute).length, 1, reason: 'said once, not every fix');
    await nav.stop(silent: true);
    await stream.close();
  });

  testWidgets('Task 3: "where am I" is answered locally with the street name, no model needed', (tester) async {
    final phone = Phone();
    addTearDown(phone.dispose);
    final reply = await phone.say(tester, 'where am i', participant());
    expect(reply.join(' '), contains('Road 7, Dhanmondi'));
  });

  // ---- Magic Button explanation ---------------------------------------------

  testWidgets('"what can you do" answers from the phone with the Magic Button explanation', (tester) async {
    final phone = Phone();
    addTearDown(phone.dispose);
    final reply = await phone.say(tester, 'What can you do?', participant());
    expect(reply.single, Dashboard.of(AppLanguage.english).capabilitiesOverview);
    expect(reply.single, contains('Magic Button'));
  });

  // ---- Task 1 and between-task state -----------------------------------------

  testWidgets('Task 1: "make the text bigger" moves one rung and is saved', (tester) async {
    final phone = Phone();
    addTearDown(phone.dispose);
    await phone.say(tester, 'make the text bigger', participant());
    expect(phone.profiles.saved, hasLength(1));
    expect(phone.profiles.saved.single.fontScale, greaterThan(1.0));
  });

  testWidgets('between tasks: a finished trip, a cancelled alarm and an answered question leave nothing pending', (tester) async {
    final phone = Phone();
    addTearDown(phone.dispose);
    final p = participant();
    await phone.say(tester, 'take me to Gulshan', p);
    await phone.say(tester, 'stop the trip', p);
    unawaited(phone.chat.sendFreeText('help me', p));
    await phone.wait(tester, 2);
    unawaited(phone.chat.sendFreeText('cancel', p));
    await phone.wait(tester, 10);
    final s = phone.state;
    expect(s.pendingRoute, isNull);
    expect(s.pendingClarification, isNull);
    expect(s.pendingPlaceSave, isNull);
    expect(s.caretakerMessageArmed, isFalse);
    expect(s.snapshotConsentPrompt, isFalse);
    expect(phone.phase, EmergencyPhase.idle);
  });

  // ---- Task 8 and 9 ------------------------------------------------------------

  test('Task 8: "show my screen" opens the message board in both languages and the bus question is a preset', () {
    expect(LocalIntentMatcher.match('show my screen', AppLanguage.english)?.name, 'open_passerby_helper');
    expect(LocalIntentMatcher.match('আমার স্ক্রিন দেখাও', AppLanguage.bangla)?.name, 'open_passerby_helper');
    expect(Onboarding.of(AppLanguage.english).defaultPasserbyMessages, contains('Which bus number is this?'));
    expect(Onboarding.of(AppLanguage.bangla).defaultPasserbyMessages, contains('এটি কত নম্বর বাস?'));
  });

  test('Task 9: "there is a pothole" opens the hazard report already set to road hazard / pothole', () {
    for (final phrase in ['there is a pothole', 'report a pothole']) {
      final i = LocalIntentMatcher.match(phrase, AppLanguage.english);
      expect(i?.name, 'open_hazard_report', reason: phrase);
      expect(i?.args['category'], 'roadHazard');
      expect(i?.args['subCategory'], 'pothole');
    }
    expect(LocalIntentMatcher.match('গর্ত আছে', AppLanguage.bangla)?.name, 'open_hazard_report');
  });

  testWidgets('Task 9: the hazard screen waits at its Submit step and files nothing until the participant says or taps submit', (tester) async {
    final reports = FakeReports();
    final tts = FakeTts();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        hazardReportServiceProvider.overrideWithValue(reports),
        ttsServiceProvider.overrideWithValue(tts),
        sttServiceProvider.overrideWithValue(SilentStt()),
      ],
      child: const MaterialApp(
        home: CrowdsourceReportingHub(
          reporterUid: 'p01',
          language: AppLanguage.english,
          voiceAutoListen: true,
          prefill: HazardReportPrefill(category: HazardCategory.roadHazard, subCategory: 'pothole'),
        ),
      ),
    ));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(reports.submitted, isEmpty);
    expect(find.text(Dashboard.of(AppLanguage.english).crowdsourceSubmitButton), findsOneWidget);
    expect(tts.spoken.first, Dashboard.of(AppLanguage.english).crowdsourceOptionalPromptSpoken);
  });
}
