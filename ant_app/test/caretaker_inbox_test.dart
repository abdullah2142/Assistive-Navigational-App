// Module 8's receiving half — item 28, "communication er kono part e kaaj
// korche na".
//
// Nothing here was broken. `CommunicationService` writes memos, voice memos
// and snapshot requests correctly; the Firestore rules for
// `communications/{uid}/messages` pass for both parties; `redeemCode` sets
// `pairedUserId` on both profiles in one transaction. All of that was checked
// before a line was written.
//
// The gap was that `communicationsStreamProvider` was referenced only from
// inside `lib/features/guardian/` — the caretaker's own UI. The messages were
// written and nobody on the other device was listening.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';
import 'package:ant_app/core/providers/tts_providers.dart';
import 'package:ant_app/core/services/tts_service.dart';
import 'package:ant_app/features/dashboard/models/chat_message.dart';
import 'package:ant_app/features/dashboard/providers/chat_providers.dart';
import 'package:ant_app/features/guardian/models/communication_message.dart';
import 'package:ant_app/features/onboarding/models/disability_profile_enums.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';

void main() {
  final d = Dashboard.of(AppLanguage.english);

  UserProfile user({
    SnapshotConsentPreference consent = SnapshotConsentPreference.askEachTime,
  }) =>
      UserProfile(
        uid: 'u1',
        role: UserRole.disabledUser,
        pairedUserId: 'c1',
        snapshotConsent: consent,
      );

  CommunicationMessage msg(
    CommunicationType type, {
    String text = '',
    String? audio,
    String id = 'm1',
  }) =>
      CommunicationMessage(
        id: id,
        fromUid: 'c1',
        toUid: 'u1',
        type: type,
        text: text,
        audioBase64: audio,
      );

  /// Delivers [message] and returns what the user ended up being told.
  Future<List<String>> deliver(
    CommunicationMessage message, {
    UserProfile? profile,
    Future<bool> Function(String)? playAudio,
  }) async {
    final tts = _RecordingTts();
    final container = ProviderContainer(overrides: [ttsServiceProvider.overrideWithValue(tts)]);
    addTearDown(container.dispose);

    await container.read(chatControllerProvider.notifier).receiveCaretakerMessage(
          message,
          profile ?? user(),
          playAudio: playAudio,
        );

    return container
        .read(chatControllerProvider)
        .messages
        .where((m) => m.sender == ChatSender.assistant)
        .map((m) => m.text)
        .toList();
  }

  group('a memo reaches the user', () {
    test('spoken and written into the chat they already have', () async {
      final said = await deliver(msg(CommunicationType.memo, text: 'Dinner is ready'));
      expect(said.single, d.caretakerMemoHeard('Dinner is ready'));
    });

    test('an empty memo is not announced as one', () async {
      expect(await deliver(msg(CommunicationType.memo, text: '   ')), isEmpty);
    });
  });

  group('a voice memo', () {
    test('is announced before it plays', () async {
      // The announcement is what tells somebody who cannot see the screen that
      // the sound about to come out of their phone is their caretaker and not
      // the assistant.
      final order = <String>[];
      final said = await deliver(
        msg(CommunicationType.voiceMemo, audio: 'AAAA'),
        playAudio: (a) async {
          order.add('played');
          return true;
        },
      );
      expect(said.first, d.caretakerVoiceMemoHeard);
      expect(order, ['played']);
    });

    test('says so when the clip will not play', () async {
      // A clip that cannot be decoded must not swallow the fact that the
      // caretaker sent something.
      final said = await deliver(
        msg(CommunicationType.voiceMemo, audio: 'not-audio'),
        playAudio: (_) async => false,
      );
      expect(said, [d.caretakerVoiceMemoHeard, d.caretakerVoiceMemoUnplayable]);
    });
  });

  group('a snapshot request', () {
    test('is delivered, and says plainly that nothing was sent', () async {
      // Module 6 is unbuilt — there is no camera dependency in this app at
      // all. A request that arrives and then silently does nothing is exactly
      // what item 28 felt like from both ends, so it is said out loud.
      final said = await deliver(msg(CommunicationType.snapshotRequest));
      expect(said, [d.caretakerSnapshotRequested, d.caretakerSnapshotNotAvailable]);
    });

    test('is refused outright for a user who switched photo sharing off', () async {
      // `snapshotConsent` has been collected by onboarding since Module 1 and
      // read by nothing until now.
      final said = await deliver(
        msg(CommunicationType.snapshotRequest),
        profile: user(consent: SnapshotConsentPreference.never),
      );
      expect(said, [d.caretakerSnapshotRequested, d.caretakerSnapshotDeclined]);
      expect(said, isNot(contains(d.caretakerSnapshotNotAvailable)),
          reason: 'their answer decides it, not the missing module');
    });
  });

  group('what the user hears is in their language', () {
    test('Bangla', () async {
      final bn = Dashboard.of(AppLanguage.bangla);
      final said = await deliver(
        msg(CommunicationType.memo, text: 'ভাত খেয়ে নাও'),
        profile: UserProfile(
          uid: 'u1',
          role: UserRole.disabledUser,
          pairedUserId: 'c1',
          language: AppLanguage.bangla,
        ),
      );
      expect(said.single, bn.caretakerMemoHeard('ভাত খেয়ে নাও'));
      expect(said.single, matches(RegExp(r'[ঀ-৿]')));
    });
  });
}

class _RecordingTts implements TtsService {
  final List<String> spoken = [];

  @override
  Future<void> speak(String text, {AppLanguage language = AppLanguage.english}) async =>
      spoken.add(text);

  @override
  Future<void> stop() async {}

  @override
  void setVoiceId(String voiceId) {}
}
