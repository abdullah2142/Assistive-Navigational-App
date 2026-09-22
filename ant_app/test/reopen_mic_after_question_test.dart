// Keeping the microphone open after the assistant speaks — item 60, widened.
//
// Reported first as: "after ai asks a question, it should reopen mic."
// Reported later, and more importantly, as a worry about the shape of the
// whole conversation: having to say the wake phrase again after every answer
// gets in the way of a disabled user. It did, and the rule below is why.
//
// The triage read this as auto-listen covering some flows but not a Gemini
// reply that ends in a question. It was worse than that: `voiceAutoListen` was
// read by onboarding and by the settings toggle and **by nothing on the
// dashboard at all**, so the microphone reopened after no chat reply
// whatsoever. A user asked "which one did you mean?" had to go and find the
// mic button to answer — the one thing somebody who cannot see the screen
// should never have to do in the middle of a conversation.
//
// The ordering is the delicate part. The invitation is raised only *after* the
// question has finished being spoken; raising it any earlier opens the
// recognizer underneath the app's own voice, which is item 23 and the easiest
// way to bring it back.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/providers/tts_providers.dart';
import 'package:ant_app/core/services/tts_service.dart';
import 'package:ant_app/features/dashboard/models/suggested_chip.dart';
import 'package:ant_app/features/dashboard/providers/chat_providers.dart';
import 'package:ant_app/features/guardian/models/communication_message.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';

void main() {
  UserProfile user({bool autoListen = true, bool deaf = false}) => UserProfile(
        uid: 'u1',
        role: UserRole.disabledUser,
        voiceAutoListen: autoListen,
        isDeafOrHardOfHearing: deaf,
      );

  /// Runs [action] against a fresh controller and reports how many times the
  /// microphone was invited to open, plus what was spoken.
  Future<({int invitations, _RecordingTts tts})> run(
    Future<void> Function(ChatController controller) action, {
    required UserProfile profile,
  }) async {
    final tts = _RecordingTts();
    final container = ProviderContainer(
      overrides: [ttsServiceProvider.overrideWithValue(tts)],
    );
    addTearDown(container.dispose);
    await action(container.read(chatControllerProvider.notifier));
    return (invitations: container.read(chatControllerProvider).answerInvitations, tts: tts);
  }

  Future<void> askDestination(ChatController c, UserProfile profile) => c.handleChip(
        const SuggestedChip(
          action: SuggestedChipAction.routeToWork,
          icon: IconsPlaceholder.icon,
        ),
        profile,
        'Route to Work',
      );

  test('a question reopens the microphone', () async {
    // "Where would you like to go?" — the assistant is waiting on an answer
    // and the user should simply be able to give one.
    final profile = user();
    final result = await run((c) => askDestination(c, profile), profile: profile);
    expect(result.invitations, 1);
  });

  test('and only after it has finished being spoken', () async {
    // Item 23 in miniature. Opening the recognizer while the question is
    // still playing means the app transcribes itself.
    final profile = user();
    final result = await run((c) => askDestination(c, profile), profile: profile);
    expect(result.tts.finishedSpeaking, isTrue,
        reason: 'the invitation was raised before narration completed');
  });

  test('a statement reopens it too', () async {
    // This used to assert the opposite, on the reasoning that "a chat surface
    // is mostly not questions". True, and it was the wrong conclusion.
    //
    // `auto_listen_rule_test.dart` gives a blind user this setting *without
    // asking*, because "a microphone that does not open itself is one they do
    // not have". Under the old rule they got it after "Where do you want to
    // go?" and not after "Taking you to Gulshan 2, about 1.2 km" — so the
    // person the feature exists for still had to say the wake phrase after
    // most turns, which is precisely what it was meant to remove.
    //
    // Statements invite a follow-up at least as often as questions: "that is
    // the route 6 bus" is answered with "take me there".
    final profile = user();
    final result = await run(
      (c) => c.announceStatementForTest('Taking you to Gulshan 2, about 1.2 km.', profile),
      profile: profile,
    );
    expect(result.invitations, 1);
  });

  test('a hazard warning does not reopen it', () async {
    // The exception, and the reason `mayInviteAnswer` still exists as a flag
    // rather than being deleted along with the question-mark rule. Somebody
    // who has just been told to stop walking is not also being asked to
    // reply, and an open microphone implies they are.
    final profile = user();
    final result = await run(
      (c) => c.announceAmbientHazard('Stop. The ground drops right in front of you.', profile),
      profile: profile,
    );
    expect(result.invitations, 0);
  });

  test('a user who turned auto-listen off is not overruled', () async {
    final profile = user(autoListen: false);
    final result = await run((c) => askDestination(c, profile), profile: profile);
    expect(result.invitations, 0);
  });

  test('a deaf user still gets the microphone, with nothing to wait for', () async {
    // `voiceAutoListen` and `isDeafOrHardOfHearing` are separate answers and
    // some users set both — being unable to hear the question does not mean
    // being unable to speak the answer.
    final profile = user(deaf: true);
    final result = await run((c) => askDestination(c, profile), profile: profile);
    expect(result.invitations, 1);
    expect(result.tts.spoken, isEmpty, reason: 'nothing should have been spoken');
  });

  test('a caretaker memo does not reopen the microphone', () async {
    // Their caretaker asking them something is not the app asking them
    // something, and the answer does not belong to this microphone.
    final profile = user();
    final result = await run(
      (c) => c.receiveCaretakerMessage(
        const CommunicationMessage(
          id: 'm1',
          fromUid: 'c1',
          toUid: 'u1',
          type: CommunicationType.memo,
          text: 'Are you on your way?',
        ),
        profile,
      ),
      profile: profile,
    );
    expect(result.invitations, 0);
  });

  test('two questions in a row are two invitations', () async {
    // A counter, not a flag. A bool would only ever change value once.
    final profile = user();
    final result = await run((c) async {
      await askDestination(c, profile);
      await askDestination(c, profile);
    }, profile: profile);
    expect(result.invitations, 2);
  });
}

/// Records what was said, and whether `speak` had actually completed by the
/// time the invitation went out.
/// `implements` rather than `extends`: `TtsService`'s constructor installs a
/// method-call handler and builds an `AudioPlayer`, neither of which exists on
/// a test binding.
class _RecordingTts implements TtsService {
  final spoken = <String>[];
  var finishedSpeaking = false;

  @override
  Future<void> speak(String text, {AppLanguage language = AppLanguage.english}) async {
    spoken.add(text);
    // A real utterance takes time. A fake that returns instantly cannot tell
    // "waited for narration" from "did not wait" — which is the whole
    // property under test here. See the handoff's note about a fake that is
    // simpler than the real thing in the dimension being tested.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    finishedSpeaking = true;
  }

  @override
  Future<void> stop() async {}

  @override
  void setVoiceId(String voiceId) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// The chip's icon is irrelevant to every test here.
class IconsPlaceholder {
  static const icon = IconData(0xe000, fontFamily: 'MaterialIcons');
}
