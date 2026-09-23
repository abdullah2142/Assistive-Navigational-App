import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';
import 'package:ant_app/core/providers/tts_providers.dart';
import 'package:ant_app/core/services/tts_service.dart';
import 'package:ant_app/features/dashboard/providers/chat_providers.dart';
import 'package:ant_app/features/guardian/models/communication_message.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Backlog item 4. A memo used to play exactly once, on arrival, and then be
/// unreachable — for a user who cannot scroll a transcript, a message
/// half-heard over traffic was a message gone.
/// `implements`, not `extends` — the real `TtsService` constructor builds a
/// `FlutterTts`, which needs platform bindings a unit test does not have.
class _Tts implements TtsService {
  final List<String> spoken = [];

  @override
  Future<void> speak(String text, {AppLanguage language = AppLanguage.english}) async =>
      spoken.add(text);

  @override
  Future<void> stop() async {}

  @override
  void setVoiceId(String voiceId) {}
}

void main() {
  final d = Dashboard.of(AppLanguage.english);

  UserProfile user() => const UserProfile(
        uid: 'u1',
        role: UserRole.disabledUser,
        pairedUserId: 'c1',
      );

  CommunicationMessage memo(String id) => CommunicationMessage(
        id: id,
        fromUid: 'c1',
        toUid: 'u1',
        type: CommunicationType.voiceMemo,
        text: '',
        audioBase64: 'AAAA',
      );

  /// Returns (controller, what was said, what was played).
  ({ChatController c, _Tts tts, List<String> played}) harness() {
    final played = <String>[];
    final tts = _Tts();
    final container = ProviderContainer(
      overrides: [ttsServiceProvider.overrideWithValue(tts)],
    );
    addTearDown(container.dispose);
    final c = container.read(chatControllerProvider.notifier);
    c.registerAudioPlayer((audio) async {
      played.add(audio);
      return true;
    });
    return (c: c, tts: tts, played: played);
  }

  test('nothing to replay says so, rather than failing silently', () async {
    final h = harness();
    await h.c.replayVoiceMemo(ReplayDirection.latest, user());
    expect(h.played, isEmpty);
    expect(h.tts.spoken, contains(d.voiceMemoNoneToReplay));
  });

  test('a received memo can be played again', () async {
    final h = harness();
    await h.c.receiveCaretakerMessage(memo('m1'), user(), playAudio: (_) async => true);
    h.played.clear();
    await h.c.replayVoiceMemo(ReplayDirection.repeat, user());
    expect(h.played, ['AAAA']);
  });

  test('previous and next step through them, oldest to newest', () async {
    final h = harness();
    for (final id in ['m1', 'm2', 'm3']) {
      await h.c.receiveCaretakerMessage(memo(id), user(), playAudio: (_) async => true);
    }
    expect(h.c.voiceMemoCount, 3);
    h.played.clear();

    // The cursor sits on the newest after arrival, so "previous" is m2.
    await h.c.replayVoiceMemo(ReplayDirection.previous, user());
    await h.c.replayVoiceMemo(ReplayDirection.previous, user());
    await h.c.replayVoiceMemo(ReplayDirection.next, user());
    expect(h.played.length, 3);
  });

  test('the ends clamp rather than wrap', () async {
    // Silently restarting at the other end sounds like the same message
    // arriving twice, which is worse than being told there are no more.
    final h = harness();
    await h.c.receiveCaretakerMessage(memo('m1'), user(), playAudio: (_) async => true);
    h.played.clear();
    await h.c.replayVoiceMemo(ReplayDirection.next, user());
    expect(h.played, isEmpty, reason: 'nothing newer than the newest');
    expect(h.tts.spoken, contains(d.voiceMemoNoNewer));
    await h.c.replayVoiceMemo(ReplayDirection.previous, user());
    expect(h.played, isEmpty, reason: 'nothing older than the oldest');
    expect(h.tts.spoken, contains(d.voiceMemoNoOlder));
  });

  test('latest jumps back to the newest from anywhere', () async {
    final h = harness();
    for (final id in ['m1', 'm2', 'm3']) {
      await h.c.receiveCaretakerMessage(memo(id), user(), playAudio: (_) async => true);
    }
    await h.c.replayVoiceMemo(ReplayDirection.previous, user());
    await h.c.replayVoiceMemo(ReplayDirection.previous, user());
    h.played.clear();
    await h.c.replayVoiceMemo(ReplayDirection.latest, user());
    expect(h.played, ['AAAA']);
  });

  test('a clip that failed to play on arrival is still replayable', () async {
    // "Play that again" is exactly what somebody says when they did not hear
    // it the first time, so the memo is recorded before playback is tried.
    final h = harness();
    await h.c.receiveCaretakerMessage(memo('m1'), user(), playAudio: (_) async => false);
    h.played.clear();
    await h.c.replayVoiceMemo(ReplayDirection.repeat, user());
    expect(h.played, ['AAAA']);
  });

  test('the position is announced when there is more than one', () {
    expect(d.voiceMemoReplaying(2, 4), contains('2'));
    expect(d.voiceMemoReplaying(2, 4), contains('4'));
    // A single message needs no "1 of 1".
    expect(d.voiceMemoReplaying(1, 1), isNot(contains('1 of 1')));
  });
}
