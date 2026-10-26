// Shared fakes for the assistant_orchestration probes. Offline, deterministic.
import 'dart:async';
import 'dart:io';

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/providers/ai_assistant_providers.dart';
import 'package:ant_app/core/providers/tts_providers.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';
import 'package:ant_app/core/services/api_budget.dart';
import 'package:ant_app/core/services/assistant_service.dart';
import 'package:ant_app/core/services/fallback_assistant_service.dart';
import 'package:ant_app/core/services/gemini_assistant_cascade.dart';
import 'package:ant_app/core/services/gemini_model_cooldowns.dart';
import 'package:ant_app/core/services/groq_assistant_service.dart';
import 'package:ant_app/core/services/gemini_assistant_service.dart' show applyFunctionCalls, navigationStateLine;
import 'package:ant_app/core/services/emergency_service.dart';
import 'package:ant_app/core/services/function_call_executor.dart';
import 'package:ant_app/core/services/gemini_assistant_service.dart' show AssistantTurn;
import 'package:ant_app/core/services/navigation_controller.dart';
import 'package:ant_app/core/services/route_planning_service.dart';
import 'package:ant_app/core/services/route_safety_service.dart';
import 'package:ant_app/core/services/routing_service.dart' show RouteCandidate;
import 'package:ant_app/core/services/tts_service.dart';
import 'package:ant_app/features/dashboard/models/chat_message.dart';
import 'package:ant_app/features/dashboard/providers/chat_providers.dart';
import 'package:ant_app/features/dashboard/services/chat_history_store.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';
import 'package:ant_app/features/onboarding/providers/onboarding_providers.dart';
import 'package:ant_app/features/onboarding/services/profile_service.dart';

typedef Handler = Future<AssistantTurn> Function(
  int n,
  String userText,
  void Function(String)? onPartial,
  List<ChatMessage> history,
);

class FakeAssistant implements AssistantService {
  FakeAssistant(this.handler, {this.name = 'fake'});
  final String name;
  Handler handler;
  final texts = <String>[];
  final histories = <List<ChatMessage>>[];
  final activeRoutes = <RouteChoice?>[];
  @override
  String get backendName => name;
  @override
  Future<AssistantTurn> converse({
    required String userText,
    required UserProfile profile,
    required List<ChatMessage> recentHistory,
    Position? location,
    void Function(String partialText)? onPartialText,
    RouteChoice? activeRoute,
    List<RouteCandidate> routeAlternatives = const [],
  }) {
    texts.add(userText);
    histories.add(recentHistory);
    activeRoutes.add(activeRoute);
    return handler(texts.length, userText, onPartialText, recentHistory);
  }
}

class RecTts implements TtsService {
  final spoken = <String>[];
  int stops = 0;
  @override
  Future<void> speak(String text, {AppLanguage language = AppLanguage.english}) async {
    spoken.add(text);
  }

  @override
  Future<void> stop() async => stops++;
  @override
  void setVoiceId(String voiceId) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

class GatedTts extends RecTts {
  final gate = Completer<void>();
  @override
  Future<void> speak(String text, {AppLanguage language = AppLanguage.english}) async {
    spoken.add(text);
    if (text.trimRight().endsWith('?')) await gate.future;
  }
}

class FakeEmergency implements EmergencyService {
  int triggers = 0;
  @override
  Future<EmergencyOutcome> trigger({required UserProfile profile, bool confirm = true}) async {
    triggers++;
    return const EmergencyOutcome(cancelled: false, reason: 'fake');
  }

  @override
  bool cancelPending() => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

class FakeProfileService implements ProfileService {
  final saved = <UserProfile>[];
  Completer<void>? hang;
  Object? failWith;
  @override
  Future<void> saveProfile(UserProfile profile) async {
    saved.add(profile);
    if (failWith != null) throw failWith!;
    if (hang != null) await hang!.future;
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

class NoFixGeolocator extends GeolocatorPlatform with MockPlatformInterfaceMixin {
  @override
  Future<Position?> getLastKnownPosition({bool forceLocationManager = false}) async => null;
}

class FakeExecutor implements FunctionCallExecutor {
  FakeExecutor(this.onExecute);
  Future<AssistantTurn> Function(String name, Map<String, Object?> args) onExecute;
  @override
  Future<AssistantTurn> execute({
    required String name,
    required Map<String, Object?> args,
    required UserProfile profile,
    Position? location,
    RouteChoice? activeRoute,
    List<RouteCandidate> routeAlternatives = const [],
  }) =>
      onExecute(name, args);
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

RouteChoice routeTo(String label) => RouteChoice(
      destinationLabel: label,
      points: const [LatLng(23.7461, 90.3742), LatLng(23.7600, 90.3900)],
      distanceMeters: 1240,
      durationSeconds: 900,
      initialBearingDegrees: 40,
      verdict: const SafetyVerdict(safe: true, riskScore: 1, threshold: 7, dangerousThanaNames: []),
      wasRerouted: false,
    );

const profile = UserProfile(uid: 'u1', role: UserRole.disabledUser, language: AppLanguage.english);

class Rig {
  Rig({Handler? handler, FakeExecutor? executor, RecTts? ttsOverride}) : tts = ttsOverride ?? RecTts() {
    GeolocatorPlatform.instance = NoFixGeolocator();
    assistant = FakeAssistant(handler ?? (n, t, p, h) async => const AssistantTurn(responseText: 'ok'));
    positions = StreamController<Position>.broadcast();
    nav = NavigationController(tts: RecTts(), positionStream: positions.stream);
    tmp = Directory.systemTemp.createTempSync('ant-orch');
    container = ProviderContainer(overrides: [
      ttsServiceProvider.overrideWithValue(tts),
      geminiAssistantServiceProvider.overrideWithValue(assistant),
      emergencyServiceProvider.overrideWithValue(emergency),
      profileServiceProvider.overrideWithValue(profiles),
      navigationControllerProvider.overrideWithValue(nav),
      chatHistoryStoreProvider.overrideWithValue(ChatHistoryStore(directory: tmp)),
      functionCallExecutorProvider.overrideWithValue(executor ?? FakeExecutor((n, a) async => const AssistantTurn(responseText: 'fake executor'))),
    ]);
    chat = container.read(chatControllerProvider.notifier);
  }
  late final FakeAssistant assistant;
  late final StreamController<Position> positions;
  late final NavigationController nav;
  late final Directory tmp;
  late final ProviderContainer container;
  late final ChatController chat;
  final RecTts tts;
  final emergency = FakeEmergency();
  final profiles = FakeProfileService();

  ChatState get state => container.read(chatControllerProvider);
  List<String> get assistantTexts =>
      state.messages.where((m) => m.sender == ChatSender.assistant).map((m) => m.text).toList();

  Future<void> dispose() async {
    container.dispose();
    await positions.close();
  }
}

Future<void> tick([int ms = 20]) => Future<void>.delayed(Duration(milliseconds: ms));


/// Groq backed by a canned SSE body; counts requests so "no network call" is assertable.
({GroqAssistantService svc, List<int> calls}) groqWith(String sse, {String model = 'probe-model', ApiBudget? budget, int status = 200}) {
  final calls = <int>[];
  final client = http_testing.MockClient.streaming((req, bodyStream) async {
    await bodyStream.drain<void>();
    calls.add(1);
    return http.StreamedResponse(Stream.value(utf8.encode(sse)), status);
  });
  return (
    svc: GroqAssistantService(
      apiKey: 'k',
      executor: FakeExecutorForServices(),
      modelName: model,
      budget: budget ?? const UnlimitedApiBudget(),
      client: client,
    ),
    calls: calls,
  );
}

FunctionCallExecutor FakeExecutorForServices() => FunctionCallExecutor();

String sseOf(List<String> jsonChunks) => '${jsonChunks.map((c) => 'data: $c').join('\n\n')}\n\ndata: [DONE]\n\n';

class _ExhaustedBudget implements ApiBudget {
  @override
  Future<bool> tryConsume(BillableApi api) async => false;
  @override
  Future<Map<String, int>> usage() async => {};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final d = Dashboard.of(AppLanguage.english);

  group('chat controller turn handling', () {
    test('what is sent to the model excludes error banners and the message just sent', () async {
      var call = 0;
      final rig = Rig(handler: (n, t, p, h) async {
        call++;
        if (call == 1) throw Exception('boom');
        return const AssistantTurn(responseText: 'second answer');
      });
      addTearDown(rig.dispose);
      await rig.chat.sendFreeText('zebra one', profile);
      expect(rig.state.messages.any((m) => m.sender == ChatSender.error), isTrue, reason: 'debug banner shown in tests');
      await rig.chat.sendFreeText('zebra two', profile);
      final h = rig.assistant.histories.last;
      expect(h.any((m) => m.sender == ChatSender.error), isFalse);
      expect(h.any((m) => m.text == 'zebra two'), isFalse);
      expect(h.any((m) => m.text == 'zebra one'), isTrue);
    });

    test('the debug banner is never spoken and never persisted', () async {
      final rig = Rig(handler: (n, t, p, h) async => throw Exception('SECRET-DIAG-TEXT'));
      addTearDown(rig.dispose);
      await rig.chat.sendFreeText('zebra one', profile);
      await rig.chat.sendFreeText('zebra two', profile);
      expect(rig.tts.spoken.join(' '), isNot(contains('SECRET-DIAG-TEXT')));
      expect(rig.state.messages.where((m) => m.sender == ChatSender.error), hasLength(2), reason: 'stacked failures each get a banner');
      final store = ChatHistoryStore(directory: rig.tmp);
      store.save('u1', rig.state.messages);
      await store.flush();
      expect((await store.load('u1')).any((m) => m.text.contains('SECRET-DIAG-TEXT')), isFalse);
    });

    test('a locally matched emergency never waits for, or reaches, the model', () async {
      final rig = Rig(handler: (n, t, p, h) async => fail('model must not be called'));
      addTearDown(rig.dispose);
      await rig.chat.sendFreeText('emergency', profile);
      expect(rig.emergency.triggers, 1);
      expect(rig.assistant.texts, isEmpty);
    });

    test('a model-judged emergency runs the emergency and replaces the chat reply', () async {
      final rig = Rig(handler: (n, t, p, h) async => const AssistantTurn(responseText: 'ok calm down', triggersEmergency: true));
      addTearDown(rig.dispose);
      await rig.chat.sendFreeText('zebra story', profile);
      expect(rig.emergency.triggers, 1);
      expect(rig.tts.spoken, isNot(contains('ok calm down')));
    });

    test('a model-judged cancel with nothing active says so out loud', () async {
      final rig = Rig(handler: (n, t, p, h) async => const AssistantTurn(responseText: '', cancelsRoute: true));
      addTearDown(rig.dispose);
      await rig.chat.sendFreeText('zebra story', profile);
      expect(rig.tts.spoken, contains(d.routeNothingToCancel));
    });

    test('emergency + cancel + route in one turn: emergency wins and no route is started', () async {
      final rig = Rig(handler: (n, t, p, h) async => AssistantTurn(
            responseText: 'x',
            triggersEmergency: true,
            cancelsRoute: true,
            route: routeTo('Farmgate'),
          ));
      addTearDown(rig.dispose);
      await rig.chat.sendFreeText('zebra story', profile);
      expect(rig.emergency.triggers, 1);
      expect(rig.state.pendingRoute, isNull);
    });

    test('an unexecuted "alerts have been sent" claim is replaced by an honest sentence', () async {
      final rig = Rig(handler: (n, t, p, h) async => const AssistantTurn(responseText: 'Alerts have been sent.'));
      addTearDown(rig.dispose);
      await rig.chat.sendFreeText('zebra story', profile);
      expect(rig.assistantTexts.last, d.emergencyNotTriggered);
      expect(rig.tts.spoken, isNot(contains('Alerts have been sent.')));
    });

    test('20 messages in one second: all kept in order, only the last is answered, nothing crashes', () async {
      final rig = Rig(handler: (n, t, p, h) async {
        await Future<void>.delayed(Duration(milliseconds: 5 * (21 - n)));
        return AssistantTurn(responseText: 'answer to $t');
      });
      addTearDown(rig.dispose);
      final fs = <Future<void>>[];
      for (var i = 1; i <= 20; i++) {
        fs.add(rig.chat.sendFreeText('zebra $i', profile));
        await tick(2);
      }
      await Future.wait(fs);
      final users = rig.state.messages.where((m) => m.sender == ChatSender.user).map((m) => m.text).toList();
      expect(users, [for (var i = 1; i <= 20; i++) 'zebra $i']);
      final replies = rig.assistantTexts.where((t) => t.startsWith('answer to')).toList();
      expect(replies, ['answer to zebra 20'], reason: 'older answers arrive after newer ones (reverse delays) and are discarded');
      expect(rig.assistant.texts, hasLength(20), reason: 'documented cost: every message is a full model call');
    });

    test('the same message sent twice a moment apart is two bubbles and one answer', () async {
      final rig = Rig(handler: (n, t, p, h) async {
        await tick(100);
        return AssistantTurn(responseText: 'reply $n');
      });
      addTearDown(rig.dispose);
      final f1 = rig.chat.sendFreeText('zebra again', profile);
      await tick(5);
      final f2 = rig.chat.sendFreeText('zebra again', profile);
      await Future.wait([f1, f2]);
      expect(rig.state.messages.where((m) => m.sender == ChatSender.user), hasLength(2));
      expect(rig.assistantTexts.where((t) => t.startsWith('reply')), hasLength(1));
    });

    test('a stale streamed bubble is withdrawn when a newer message supersedes it', () async {
      final first = Completer<AssistantTurn>();
      final rig = Rig(handler: (n, t, p, h) {
        if (n == 1) {
          p!('half an answer');
          return first.future;
        }
        return Future.value(const AssistantTurn(responseText: 'fresh'));
      });
      addTearDown(rig.dispose);
      final f1 = rig.chat.sendFreeText('zebra one', profile);
      await tick();
      expect(rig.assistantTexts, contains('half an answer'));
      await rig.chat.sendFreeText('zebra two', profile);
      first.complete(const AssistantTurn(responseText: 'half an answer plus more'));
      await f1;
      expect(rig.assistantTexts, isNot(contains('half an answer plus more')));
    });

    test('the model is told about the route only while one is active, and not after a cancel', () async {
      var n0 = 0;
      final rig = Rig(handler: (n, t, p, h) async {
        n0++;
        return n0 == 1 ? AssistantTurn(responseText: 'Route found.', route: routeTo('Farmgate')) : const AssistantTurn(responseText: 'fine');
      });
      addTearDown(rig.dispose);
      await rig.chat.sendFreeText('zebra story one', profile);
      await rig.chat.sendFreeText('zebra story two', profile);
      expect(rig.assistant.activeRoutes[0], isNull);
      expect(rig.assistant.activeRoutes[1]?.destinationLabel, 'Farmgate');
      await rig.chat.sendFreeText('cancel the trip', profile);
      await rig.chat.sendFreeText('zebra story three', profile);
      expect(rig.assistant.activeRoutes.last, isNull);
      expect(navigationStateLine(null), contains('Not currently navigating'));
      expect(navigationStateLine(routeTo('Farmgate')), contains('Farmgate'));
    });

    test('no assistant configured: the stub is shown, and the emergency path still works', () async {
      final rig = Rig();
      addTearDown(rig.dispose);
      // Rebuild with a null assistant.
      final c = ProviderContainer(overrides: [
        ttsServiceProvider.overrideWithValue(rig.tts),
        geminiAssistantServiceProvider.overrideWithValue(null),
        emergencyServiceProvider.overrideWithValue(rig.emergency),
        profileServiceProvider.overrideWithValue(rig.profiles),
        navigationControllerProvider.overrideWithValue(rig.nav),
        chatHistoryStoreProvider.overrideWithValue(ChatHistoryStore(directory: rig.tmp)),
      ]);
      addTearDown(c.dispose);
      final chat = c.read(chatControllerProvider.notifier);
      await chat.sendFreeText('zebra story', profile);
      await chat.sendFreeText('sos', profile);
      expect(rig.emergency.triggers, 1);
      expect(rig.tts.spoken, contains(d.chatStubReply));
    });

    test('a deaf user gets the reply as text only', () async {
      final rig = Rig(handler: (n, t, p, h) async => const AssistantTurn(responseText: 'text answer'));
      addTearDown(rig.dispose);
      await rig.chat.sendFreeText('zebra story', profile.copyWith(isDeafOrHardOfHearing: true));
      expect(rig.assistantTexts, contains('text answer'));
      expect(rig.tts.spoken, isEmpty);
    });

    test('offline matcher still answers help when every backend fails', () async {
      final rig = Rig(handler: (n, t, p, h) async => throw Exception('network down'));
      addTearDown(rig.dispose);
      await rig.chat.sendFreeText('I need some help with the zebra', profile);
      expect(rig.tts.spoken.join(' '), contains('Basic Safety Mode'));
    });
  });

  group('tool-call aggregation', () {
    test('flags are OR-ed, the last route wins and unknown tools are harmless', () async {
      final exec = FakeExecutor((name, args) async => switch (name) {
            'trigger_emergency' => const AssistantTurn(responseText: '', triggersEmergency: true),
            'cancel_route' => const AssistantTurn(responseText: '', cancelsRoute: true),
            'request_route' => AssistantTurn(responseText: 'r', route: routeTo(args['destination'] as String)),
            _ => const AssistantTurn(responseText: 'Sorry, I couldn\'t do that.'),
          });
      final turn = await applyFunctionCalls(
        calls: const [
          (name: 'request_route', args: {'destination': 'A'}),
          (name: 'nonsense_tool', args: {'x': null}),
          (name: 'cancel_route', args: {}),
          (name: 'request_route', args: {'destination': 'B'}),
          (name: 'trigger_emergency', args: {}),
        ],
        executor: exec,
        profile: profile,
      );
      expect(turn.triggersEmergency && turn.cancelsRoute, isTrue);
      expect(turn.route?.destinationLabel, 'B');
    });

    test('real executor: unknown tool, empty name and null args are answered, not thrown', () async {
      for (final name in ['get_weather', '', 'DROP TABLE']) {
        final t = await FunctionCallExecutor().execute(name: name, args: const {'a': null}, profile: profile);
        expect(t.responseText, isNotEmpty);
      }
    });

    test('real executor: huge string argument does not throw', () async {
      final t = await FunctionCallExecutor().execute(name: 'plan_commute', args: {'destination': 'x' * 200000}, profile: profile);
      expect(t.commuteDestination, isNotNull);
    });
  });

  group('fallback chain', () {
    test('primary fails, secondary answers; flag set; both fail reports the primary reason', () async {
      final bad = FakeAssistant((n, t, p, h) async => throw Exception('groq 503'));
      final good = FakeAssistant((n, t, p, h) async => const AssistantTurn(responseText: 'from gemini'));
      final svc = FallbackAssistantService(primary: bad, secondary: good);
      final turn = await svc.converse(userText: 'x', profile: profile, recentHistory: const []);
      expect(turn.responseText, 'from gemini');
      expect(svc.lastTurnUsedFallback, isTrue);

      final svc2 = FallbackAssistantService(primary: bad, secondary: FakeAssistant((n, t, p, h) async => throw Exception('gemini 429')));
      await expectLater(
        svc2.converse(userText: 'x', profile: profile, recentHistory: const []),
        throwsA(isA<AssistantBothBackendsFailed>().having((e) => '${e.primaryError}', 'primary', contains('groq 503'))),
      );
      final svc3 = FallbackAssistantService(primary: bad, secondary: null);
      await expectLater(svc3.converse(userText: 'x', profile: profile, recentHistory: const []), throwsException);
    });

    test('a hanging primary is abandoned at its timeout and the secondary answers', () async {
      final hang = FakeAssistant((n, t, p, h) => Completer<AssistantTurn>().future);
      final good = FakeAssistant((n, t, p, h) async => const AssistantTurn(responseText: 'ok'));
      final svc = FallbackAssistantService(primary: hang, secondary: good, primaryTimeout: const Duration(milliseconds: 40));
      expect((await svc.converse(userText: 'x', profile: profile, recentHistory: const [])).responseText, 'ok');
    });

    test('cascade skips a cooling model, recovers after expiry, and reports when all are cooling', () async {
      var now = DateTime.utc(2026, 10, 1, 12);
      final cool = GeminiModelCooldowns(now: () => now);
      final a = FakeAssistant((n, t, p, h) async => throw Exception('429 quota exceeded, retry in 20s'), name: 'model-a');
      final b = FakeAssistant((n, t, p, h) async => const AssistantTurn(responseText: 'b answered'), name: 'model-b');
      final cascade = GeminiAssistantCascade(models: [a, b], cooldowns: cool);
      expect((await cascade.converse(userText: 'x', profile: profile, recentHistory: const [])).responseText, 'b answered');
      expect(cool.isCooling('model-a'), isTrue);
      cool.recordReset('model-b', const Duration(seconds: 30));
      await expectLater(cascade.converse(userText: 'x', profile: profile, recentHistory: const []), throwsStateError);
      now = now.add(const Duration(minutes: 5));
      expect(cool.isCooling('model-a'), isFalse);
      expect(cool.isCooling('model-b'), isFalse);
    });

    test('cooldown durations: 429 honours the stated retry, unknown errors do not cool', () {
      final cool = GeminiModelCooldowns(now: () => DateTime.utc(2026, 10, 1, 12));
      final until = cool.recordFailure('m1', Exception('429 rate limit, please retry in 20s'))!;
      expect(until.difference(DateTime.utc(2026, 10, 1, 12)).inSeconds, inInclusiveRange(20, 22));
      expect(cool.recordFailure('m2', Exception('FormatException: bad json')), isNull);
      expect(cool.recordFailure('m3', Exception('503 high demand')), isNotNull);
    });

    test('documented design: a timeout is treated like an overload and cools the model for 30 s', () {
      final cool = GeminiModelCooldowns(now: () => DateTime.utc(2026, 10, 1, 12));
      final until = cool.recordFailure('m', TimeoutException('x', const Duration(seconds: 4)))!;
      expect(until.difference(DateTime.utc(2026, 10, 1, 12)).inSeconds, 30);
    });

    test('Groq: exhausted budget and active cooldown fail before any network call', () async {
      final noBudget = groqWith('', budget: _ExhaustedBudget());
      await expectLater(noBudget.svc.converse(userText: 'x', profile: profile, recentHistory: const []), throwsA(isA<AssistantBudgetExhausted>()));
      expect(noBudget.calls, isEmpty);
      GeminiModelCooldowns.shared.recordReset('groq:probe-cooling', const Duration(seconds: 5));
      final cooling = groqWith('', model: 'probe-cooling');
      await expectLater(cooling.svc.converse(userText: 'x', profile: profile, recentHistory: const []), throwsStateError);
      expect(cooling.calls, isEmpty);
    });

    test('Groq: a 429 is not retried against the same model and starts a cooldown', () async {
      final g = groqWith('{"error":{"message":"rate_limit_exceeded. Please try again in 14.9s"}}', model: 'probe-429', status: 429);
      await expectLater(g.svc.converse(userText: 'x', profile: profile, recentHistory: const []), throwsException);
      expect(g.calls, hasLength(1));
      expect(GeminiModelCooldowns.shared.isCooling('groq:probe-429'), isTrue);
    });

    test('Groq: empty, whitespace-only and partial-JSON replies still produce speakable text', () async {
      final empty = groqWith(sseOf(['{"choices":[{"delta":{"content":"   "}}]}']));
      expect((await empty.svc.converse(userText: 'x', profile: profile, recentHistory: const [])).responseText, 'Got it.');
      final bn = groqWith(sseOf(['{"choices":[{"delta":{"content":""}}]}']));
      expect((await bn.svc.converse(userText: 'x', profile: profile.copyWith(language: AppLanguage.bangla), recentHistory: const [])).responseText, 'ঠিক আছে।');
      final garbage = groqWith('data: {"choices":[{"delta":{"con\n\ndata: {"choices":[{"delta":{"content":"fine"}}]}\n\ndata: [DONE]\n\n');
      expect((await garbage.svc.converse(userText: 'x', profile: profile, recentHistory: const [])).responseText, 'fine');
    });

    test('Groq: truncated tool-call JSON is survivable and runs the tool with empty args', () async {
      final g = groqWith(sseOf([
        '{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"trigger_emergency","arguments":"{\\"x\\":"}}]}}]}',
      ]));
      final t = await g.svc.converse(userText: 'x', profile: profile, recentHistory: const []);
      expect(t.triggersEmergency, isTrue, reason: 'a garbled argument string must not lose the alarm');
    });
  });

  group('history store', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('ant-orch-h'));
    tearDown(() => dir.deleteSync(recursive: true));
    File file() => File('${dir.path}/${ChatHistoryStore.fileName}');

    test('garbage, truncated, wrong-shape and foreign files all load as empty without throwing', () async {
      final s = ChatHistoryStore(directory: dir);
      for (final content in ['', 'not json', '{"uid":"u1","messages":[{"text":"hi"', '[]', '{"uid":"u1","messages":"x"}', '{"uid":"other","messages":[]}', 'null']) {
        file().writeAsStringSync(content);
        expect(await s.load('u1'), isEmpty, reason: content);
      }
    });

    test('10 000 messages keep the newest 200 in order; a 1 MB message round-trips; error bubbles are dropped', () async {
      final s = ChatHistoryStore(directory: dir);
      final msgs = [
        for (var i = 0; i < 10000; i++)
          ChatMessage(
            sender: i % 7 == 0 ? ChatSender.error : ChatSender.user,
            text: i == 9999 ? 'x' * 1000000 : 'm$i',
            timestamp: DateTime.utc(2026, 10, 1).add(Duration(seconds: i)),
          ),
      ];
      s.save('u1', msgs);
      await s.flush();
      final back = await s.load('u1');
      expect(back, hasLength(ChatHistoryStore.maxMessages));
      expect(back.last.text.length, 1000000);
      expect(back.any((m) => m.sender == ChatSender.error), isFalse);
      for (var i = 1; i < back.length; i++) {
        expect(back[i].timestamp.isAfter(back[i - 1].timestamp), isTrue);
      }
    });

    test('a restart restores the transcript and does not duplicate the welcome line', () async {
      final seeded = ChatHistoryStore(directory: dir);
      seeded.save('u1', [
        ChatMessage(sender: ChatSender.user, text: 'take me home', timestamp: DateTime.utc(2026, 10, 1)),
        ChatMessage(sender: ChatSender.assistant, text: 'Which home?', timestamp: DateTime.utc(2026, 10, 1, 0, 0, 1)),
      ]);
      await seeded.flush();
      final rig = Rig();
      addTearDown(rig.dispose);
      final c = ProviderContainer(overrides: [
        ttsServiceProvider.overrideWithValue(rig.tts),
        chatHistoryStoreProvider.overrideWithValue(ChatHistoryStore(directory: dir)),
        navigationControllerProvider.overrideWithValue(rig.nav),
      ]);
      addTearDown(c.dispose);
      final chat = c.read(chatControllerProvider.notifier);
      await chat.restoreHistory('u1', d);
      chat.ensureWelcomeMessage(d);
      final texts = c.read(chatControllerProvider).messages.map((m) => m.text).toList();
      expect(texts, ['take me home', 'Which home?']);
    });
  });
}
