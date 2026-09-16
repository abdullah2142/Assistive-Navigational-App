// Remembering the user between turns and between sessions — item 56.
//
// Reported: "app should work like a normal chatbot, as in how conversational
// chatgpt and gemini is in speak mode, remembering context and informations/
// preferences."
//
// Two halves, and the first came free with item 52. The recent transcript is
// now restored from disk at launch, and `recentHistory` is built from
// `ChatState.messages`, so the last turns of the previous session reach the
// model without anything further.
//
// A conversation window is not memory, though. It is eight turns wide;
// anything said before that is gone, and the things worth keeping — "I can't
// manage stairs", "my daughter picks me up on Fridays" — are exactly the ones
// said once, in passing, and never repeated. So they are kept on the profile
// as plain sentences and handed back in the prompt.

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/services/function_call_executor.dart';
import 'package:ant_app/core/services/gemini_assistant_service.dart';
import 'package:ant_app/core/services/route_planning_service.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';

void main() {
  UserProfile user({List<String> notes = const []}) =>
      UserProfile(uid: 'u1', role: UserRole.disabledUser, rememberedNotes: notes);

  FunctionCallExecutor executor() => FunctionCallExecutor(routePlanning: _NoPlanning());

  Future<UserProfile> remember(UserProfile from, String note) async {
    final turn = await executor()
        .execute(name: 'remember_about_me', args: {'note': note}, profile: from);
    return turn.updatedProfile ?? from;
  }

  group('keeping something', () {
    test('a note said in passing is kept', () async {
      final after = await remember(user(), 'Cannot manage stairs');
      expect(after.rememberedNotes, ['Cannot manage stairs']);
    });

    test('and the user is told it was kept', () async {
      // Said out loud on purpose: somebody who cannot see a screen has no
      // other way to know something about them was written down.
      final turn = await executor().execute(
        name: 'remember_about_me',
        args: const {'note': 'Prefers quiet routes'},
        profile: user(),
      );
      expect(turn.responseText, contains('Prefers quiet routes'));
    });

    test('it survives a round trip through storage', () async {
      // It lives on the profile, which is what persists — so this is the
      // "between sessions" half.
      final after = await remember(user(), 'Uses a wheelchair');
      final restored = UserProfile.fromJson(after.toJson());
      expect(restored.rememberedNotes, ['Uses a wheelchair']);
    });

    test('an empty note is not kept', () async {
      final turn = await executor()
          .execute(name: 'remember_about_me', args: const {'note': '  '}, profile: user());
      expect(turn.updatedProfile, isNull);
    });

    test('the same fact twice is kept once', () async {
      // The model will not phrase it identically twice, and a list holding
      // one fact three times spends prompt on saying one thing.
      var profile = await remember(user(), 'Cannot manage stairs');
      profile = await remember(profile, 'cannot manage STAIRS');
      expect(profile.rememberedNotes, hasLength(1));
    });

    test('the list is capped, oldest out', () async {
      // An unbounded list grows into the prompt, and a prompt that grows every
      // turn eventually costs more than the reply it buys.
      var profile = user();
      for (var i = 0; i < UserProfile.maxRememberedNotes + 5; i++) {
        profile = await remember(profile, 'fact $i');
      }
      expect(profile.rememberedNotes, hasLength(UserProfile.maxRememberedNotes));
      expect(profile.rememberedNotes.last, 'fact ${UserProfile.maxRememberedNotes + 4}');
      expect(profile.rememberedNotes, isNot(contains('fact 0')));
    });
  });

  group('forgetting it again', () {
    test('a user can take something back', () async {
      // Not optional. This app holds a disabled user's health, household and
      // movements; "stop keeping that" has to be sayable out loud.
      final profile = user(notes: ['Cannot manage stairs', 'Prefers quiet routes']);
      final turn = await executor()
          .execute(name: 'forget_about_me', args: const {'note': 'stairs'}, profile: profile);
      expect(turn.updatedProfile!.rememberedNotes, ['Prefers quiet routes']);
      expect(turn.responseText, contains('Forgotten'));
    });

    test('forgetting everything empties the list', () async {
      final profile = user(notes: ['one', 'two']);
      final turn = await executor()
          .execute(name: 'forget_about_me', args: const {}, profile: profile);
      expect(turn.updatedProfile!.rememberedNotes, isEmpty);
    });

    test('forgetting something never said changes nothing, and says so', () async {
      final profile = user(notes: ['Cannot manage stairs']);
      final turn = await executor().execute(
        name: 'forget_about_me',
        args: const {'note': 'something else entirely'},
        profile: profile,
      );
      expect(turn.updatedProfile, isNull);
      expect(turn.responseText, contains("don't have anything like that"));
    });
  });

  group('what reaches the model', () {
    String promptFor(UserProfile profile) =>
        GeminiAssistantService.buildPrompt(userText: 'hello', profile: profile);

    test('remembered notes are in the prompt', () async {
      final prompt = promptFor(user(notes: ['Cannot manage stairs']));
      expect(prompt, contains('Cannot manage stairs'));
      expect(prompt, contains('kept across sessions'));
    });

    test('nothing remembered adds nothing to the prompt', () {
      // A header saying "here is nothing" is prompt spent on silence.
      expect(promptFor(user()), isNot(contains('kept across sessions')));
    });

    test('the model is told to use what it already has', () {
      final prompt = promptFor(user());
      expect(prompt, contains('do not ask again for something they have already told you'));
    });

    test('both functions are declared', () {
      final names = GeminiAssistantService.functionDeclarations.map((f) => f.name).toList();
      expect(names, containsAll(['remember_about_me', 'forget_about_me']));
    });

    test('the model is told not to claim memory it does not have', () {
      expect(promptFor(user()), contains('Never claim to remember something without calling it'));
    });
  });

  test('remembering is not routing, and does not change the journey', () async {
    final turn = await executor().execute(
      name: 'remember_about_me',
      args: const {'note': 'Hates crowded markets'},
      profile: user(),
    );
    expect(turn.route, isNull);
    expect(turn.overlayAction, isNull);
    expect(turn.triggersEmergency, isFalse);
    expect(turn.cancelsRoute, isFalse);
  });
}

class _NoPlanning implements RoutePlanningService {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
