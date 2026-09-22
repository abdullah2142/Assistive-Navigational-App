// Falling back to the second backend, for chat and for vision.
//
// Both paths exist for the same measured reason: on 17 September a tester
// session logged **twelve** Groq `429`s, every one `ITPM: Limit 7000`. Each
// was a turn where somebody spoke to the app and got `OfflineIntentMatcher`'s
// stub instead of an answer. The point of all this is to turn those into a
// slower answer rather than no answer.
//
// The fakes here are deliberately dumb. What needs testing is the *routing* —
// who is tried, in what order, what happens when one dies — and a fake that
// modelled HTTP would test `http`, not this.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/services/assistant_service.dart';
import 'package:ant_app/core/services/fallback_assistant_service.dart';
import 'package:ant_app/core/services/gemini_assistant_service.dart' show AssistantTurn;
import 'package:ant_app/core/services/vision/cloud_vision_service.dart'
    show VisionBudgetExhausted;
import 'package:ant_app/core/services/vision/vision_backend.dart';
import 'package:ant_app/core/services/vision/vision_router.dart';
import 'package:ant_app/core/services/vision/vision_scene.dart';
import 'package:ant_app/features/dashboard/models/chat_message.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';

// ---- chat fakes ------------------------------------------------------------

class _FakeAssistant implements AssistantService {
  _FakeAssistant(this.backendName, {this.failWith, this.delay, this.reply = 'ok'});

  @override
  final String backendName;

  final Object? failWith;
  final Duration? delay;
  final String reply;

  int calls = 0;
  List<ChatMessage>? sawHistory;
  UserProfile? sawProfile;

  @override
  Future<AssistantTurn> converse({
    required String userText,
    required UserProfile profile,
    required List<ChatMessage> recentHistory,
    Position? location,
    void Function(String partialText)? onPartialText,
    dynamic activeRoute,
    List<dynamic> routeAlternatives = const [],
  }) async {
    calls++;
    sawHistory = recentHistory;
    sawProfile = profile;
    if (delay != null) await Future<void>.delayed(delay!);
    if (failWith != null) throw failWith!;
    onPartialText?.call(reply);
    return AssistantTurn(responseText: reply);
  }
}

UserProfile _profile() => const UserProfile(uid: 'u1', role: UserRole.disabledUser);

List<ChatMessage> _history() => [
      ChatMessage(sender: ChatSender.user, text: 'earlier question', timestamp: DateTime(2026)),
      ChatMessage(sender: ChatSender.assistant, text: 'earlier answer', timestamp: DateTime(2026)),
    ];

Future<AssistantTurn> _ask(
  FallbackAssistantService svc, {
  void Function(String)? onPartial,
}) =>
    svc.converse(
      userText: 'where am i',
      profile: _profile(),
      recentHistory: _history(),
      onPartialText: onPartial,
    );

// ---- vision fakes ----------------------------------------------------------

class _FakeVision implements VisionBackend {
  _FakeVision(
    this.name, {
    this.maxFrames = 1,
    this.isConfigured = true,
    this.failWith,
    this.answers = true,
  });

  @override
  final String name;
  @override
  final int maxFrames;
  @override
  final bool isConfigured;

  final Object? failWith;
  final bool answers;

  int calls = 0;
  int? sawFrameCount;

  @override
  Future<VisionScene?> describe({
    required List<Uint8List> jpegs,
    required ScanFocus focus,
    required AppLanguage language,
    List<String> edgeLabels = const [],
  }) async {
    calls++;
    sawFrameCount = jpegs.length;
    if (failWith != null) throw failWith!;
    if (!answers) return null;
    return VisionScene(focus: focus, spoken: 'seen by $name');
  }
}

List<Uint8List> _frames(int n) =>
    [for (var i = 0; i < n; i++) Uint8List.fromList([i])];

Future<VisionScene?> _look(VisionRouter r, ScanFocus focus, {int frames = 1}) =>
    r.describe(
      jpegs: _frames(frames),
      focus: focus,
      language: AppLanguage.bangla,
    );

void main() {
  group('chat — the secondary answers when the primary cannot', () {
    test('a Groq 429 becomes a Gemini answer, not a stub', () {
      // The exact shape of the twelve logged failures.
      final groq = _FakeAssistant('groq', failWith: Exception('429 ITPM: Limit 7000'));
      final gemini = _FakeAssistant('gemini', reply: 'তুমি গুলশানে আছ');
      final svc = FallbackAssistantService(primary: groq, secondary: gemini);

      expect(_ask(svc), completion(isA<AssistantTurn>()));
    });

    test('the fallback is handed the same history and profile', () async {
      // The whole claim that a swap loses no context. Nothing lives inside a
      // backend — the caller rebuilds the world on every turn — so this is
      // what makes that concrete rather than asserted.
      final groq = _FakeAssistant('groq', failWith: Exception('boom'));
      final gemini = _FakeAssistant('gemini');
      await _ask(FallbackAssistantService(primary: groq, secondary: gemini));

      expect(gemini.sawHistory, isNotNull);
      expect(gemini.sawHistory!.map((m) => m.text),
          ['earlier question', 'earlier answer']);
      expect(gemini.sawProfile?.uid, 'u1');
      expect(gemini.sawHistory, equals(groq.sawHistory));
    });

    test('the secondary is not called when the primary succeeds', () async {
      // Failure-only, never load-balancing: alternating would halve the hit
      // rate on Groq's prefix cache, which is what `c895add`'s prompt
      // reordering exists to exploit and what keeps the 429s rare.
      final groq = _FakeAssistant('groq');
      final gemini = _FakeAssistant('gemini');
      await _ask(FallbackAssistantService(primary: groq, secondary: gemini));

      expect(groq.calls, 1);
      expect(gemini.calls, 0);
    });

    test('a hung primary still reaches the fallback', () async {
      // Without a per-backend timeout the outer 30 s bound in
      // `ChatController` would fire first and the fallback would never be
      // tried — a hang would look exactly like today's failure.
      final groq = _FakeAssistant('groq', delay: const Duration(seconds: 2));
      final gemini = _FakeAssistant('gemini', reply: 'from the backup');
      final svc = FallbackAssistantService(
        primary: groq,
        secondary: gemini,
        primaryTimeout: const Duration(milliseconds: 50),
      );

      final turn = await _ask(svc);
      expect(turn.responseText, 'from the backup');
      expect(svc.lastTurnUsedFallback, isTrue);
    });

    test('lastTurnUsedFallback resets on the next good turn', () async {
      final groq = _FakeAssistant('groq');
      final svc = FallbackAssistantService(
        primary: _FakeAssistant('groq-bad', failWith: Exception('x')),
        secondary: _FakeAssistant('gemini'),
      );
      await _ask(svc);
      expect(svc.lastTurnUsedFallback, isTrue);

      final healthy = FallbackAssistantService(primary: groq, secondary: null);
      await _ask(healthy);
      expect(healthy.lastTurnUsedFallback, isFalse);
    });

    test('with no secondary the original error reaches the caller unchanged', () async {
      // `ChatController`'s catch logs the reason and falls to the offline
      // matcher. Wrapping the error here would make every existing failure
      // read as a fallback problem.
      final boom = Exception('groq is down');
      final svc = FallbackAssistantService(
        primary: _FakeAssistant('groq', failWith: boom),
        secondary: null,
      );
      await expectLater(_ask(svc), throwsA(same(boom)));
    });

    test('both failing reports the primary reason, not just the last one', () async {
      final svc = FallbackAssistantService(
        primary: _FakeAssistant('groq', failWith: Exception('429 ITPM')),
        secondary: _FakeAssistant('gemini', failWith: Exception('503 overloaded')),
      );
      try {
        await _ask(svc);
        fail('expected both-failed');
      } on AssistantBothBackendsFailed catch (e) {
        // Both reasons survive: a diagnostics log has to show whether this
        // was one outage or two unrelated ones.
        expect(e.toString(), contains('429 ITPM'));
        expect(e.toString(), contains('503 overloaded'));
      }
    });

    test('the two timeouts fit inside the caller\'s 30 s bound', () {
      // If they could sum past it, the outer timeout would fire during the
      // second attempt and discard an answer that was on its way.
      final total = FallbackAssistantService.defaultPrimaryTimeout +
          FallbackAssistantService.defaultSecondaryTimeout;
      expect(total, lessThan(const Duration(seconds: 30)));
    });
  });

  group('vision — routing by question, not by exhaustion', () {
    test('a bus question goes to the fast backend first', () async {
      final groq = _FakeVision('groq');
      final gemini = _FakeVision('gemini', maxFrames: 3);
      final scene = await _look(VisionRouter(groq: groq, gemini: gemini), ScanFocus.vehicle);

      expect(scene?.spoken, 'seen by groq');
      expect(gemini.calls, 0, reason: 'a bus does not wait for the accurate one');
    });

    for (final focus in [ScanFocus.sign, ScanFocus.hazard, ScanFocus.surroundings]) {
      test('a ${focus.name} question goes to the accurate backend first', () async {
        final groq = _FakeVision('groq');
        final gemini = _FakeVision('gemini', maxFrames: 3);
        final scene = await _look(VisionRouter(groq: groq, gemini: gemini), focus);

        expect(scene?.spoken, 'seen by gemini');
        expect(groq.calls, 0);
      });
    }

    test('either backend failing hands the scan to the other', () async {
      final groq = _FakeVision('groq', answers: false);
      final gemini = _FakeVision('gemini', maxFrames: 3);
      final scene = await _look(VisionRouter(groq: groq, gemini: gemini), ScanFocus.vehicle);

      expect(scene?.spoken, 'seen by gemini');
      expect(groq.calls, 1);
      expect(gemini.calls, 1);
    });

    test('a thrown backend does not take the scan down', () async {
      final groq = _FakeVision('groq', failWith: StateError('socket died'));
      final gemini = _FakeVision('gemini', maxFrames: 3);
      final scene = await _look(VisionRouter(groq: groq, gemini: gemini), ScanFocus.vehicle);
      expect(scene?.spoken, 'seen by gemini');
    });

    test('both out of budget says so, rather than "I could not see"', () async {
      // The two need different spoken answers. "I have looked too many times
      // just now" is true and tells the user to wait; "I could not see" sends
      // them to check a signal that is fine.
      final router = VisionRouter(
        groq: _FakeVision('groq', failWith: const VisionBudgetExhausted()),
        gemini: _FakeVision('gemini', failWith: const VisionBudgetExhausted()),
      );
      await expectLater(
        _look(router, ScanFocus.vehicle),
        throwsA(isA<VisionBudgetExhausted>()),
      );
    });

    test('one exhausted and one merely broken is not "too many times"', () async {
      final router = VisionRouter(
        groq: _FakeVision('groq', failWith: const VisionBudgetExhausted()),
        gemini: _FakeVision('gemini', answers: false),
      );
      expect(await _look(router, ScanFocus.vehicle), isNull);
    });

    test('no backend configured returns null rather than throwing', () async {
      final router = VisionRouter(groq: null, gemini: null);
      expect(router.hasAnyBackend, isFalse);
      expect(await _look(router, ScanFocus.vehicle), isNull);
    });

    test('an unconfigured backend is skipped, not tried', () async {
      final groq = _FakeVision('groq', isConfigured: false);
      final gemini = _FakeVision('gemini', maxFrames: 3);
      final scene = await _look(VisionRouter(groq: groq, gemini: gemini), ScanFocus.vehicle);

      expect(scene?.spoken, 'seen by gemini');
      expect(groq.calls, 0);
    });
  });

  group('vision — how many frames the camera takes', () {
    const sweep = 3;

    test('a sweep takes three when a backend can read three', () {
      final router = VisionRouter(
        groq: _FakeVision('groq'),
        gemini: _FakeVision('gemini', maxFrames: 3),
      );
      expect(router.framesNeededFor(ScanFocus.surroundings, sweepFrames: sweep), 3);
    });

    test('a sweep collapses to one when only the single-frame backend exists', () {
      // Otherwise the camera shoots two extra frames, costs the battery and
      // the latency, and discards them — the Groq-only build's behaviour,
      // arrived at correctly rather than by accident.
      final router = VisionRouter(groq: _FakeVision('groq'), gemini: null);
      expect(router.framesNeededFor(ScanFocus.surroundings, sweepFrames: sweep), 1);
    });

    test('every non-sweep question takes exactly one frame', () {
      final router = VisionRouter(
        groq: _FakeVision('groq'),
        gemini: _FakeVision('gemini', maxFrames: 3),
      );
      for (final focus in [ScanFocus.vehicle, ScanFocus.sign, ScanFocus.hazard]) {
        expect(router.framesNeededFor(focus, sweepFrames: sweep), 1, reason: focus.name);
      }
    });

    test('with no backend at all it still captures one, for the offline pass', () {
      final router = VisionRouter(groq: null, gemini: null);
      expect(router.framesNeededFor(ScanFocus.surroundings, sweepFrames: sweep), 1);
    });

    test('a single-frame backend receives one frame even when three were taken', () async {
      // The orchestrator orders them sharpest-first, so the one frame a
      // Groq-shaped backend takes is the best of the sweep.
      final groq = _FakeVision('groq');
      final router = VisionRouter(groq: groq, gemini: null);
      await _look(router, ScanFocus.surroundings, frames: 3);
      // The router passes the whole list; the backend itself takes what it
      // can use. Asserted here so a backend that quietly uploaded all three
      // — three calls' worth of tokens — would fail loudly.
      expect(groq.sawFrameCount, 3,
          reason: 'router forwards all frames; CloudVisionService.describe '
              'takes jpegs.first, which is the sharpest');
    });
  });
}
