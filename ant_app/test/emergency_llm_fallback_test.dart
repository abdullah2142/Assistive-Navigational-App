// The second layer of the emergency trigger.
//
// Keyword matching has a recall ceiling that no word list survives contact
// with: people in danger say things nobody anticipated. Before this, a
// missed keyword was not degraded handling — `trigger_emergency` existed
// only in the local matcher, so an unmatched cry for help reached Gemini,
// which had no way to act on it, and nothing happened at all.

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/services/function_call_executor.dart';
import 'package:ant_app/core/services/gemini_assistant_service.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';

void main() {
  const profile = UserProfile(uid: 'u1', role: UserRole.disabledUser, language: AppLanguage.english);

  group('the model can actually raise an alarm', () {
    test('trigger_emergency is declared as a tool', () {
      final names = GeminiAssistantService.functionDeclarations.map((d) => d.name).toList();
      expect(names, contains('trigger_emergency'),
          reason: 'without this the model has no way to act on distress it recognises');
    });

    test('the executor reports it rather than applying it', () async {
      // It is a sequence, not a change to apply and describe, so the
      // caller runs it — the same path a locally-matched trigger takes.
      final turn = await FunctionCallExecutor().execute(
        name: 'trigger_emergency',
        args: const {},
        profile: profile,
      );
      expect(turn.triggersEmergency, isTrue);
      expect(turn.updatedProfile, isNull, reason: 'it must not silently change the profile');
    });

    test('nothing else sets the flag', () async {
      final turn = await FunctionCallExecutor().execute(
        name: 'open_passerby_helper',
        args: const {},
        profile: profile,
      );
      expect(turn.triggersEmergency, isFalse);
    });

    test('the flag defaults off', () {
      expect(const AssistantTurn(responseText: 'x').triggersEmergency, isFalse);
    });
  });

  group('the tool description carries the judgement', () {
    // With no parameters, the description is the entire specification of
    // when to call this — it is the logic, not documentation of it.
    late String description;

    setUp(() {
      description = GeminiAssistantService.functionDeclarations
          .firstWhere((d) => d.name == 'trigger_emergency')
          .description
          .toLowerCase();
    });

    test('it tells the model that negative statements are distress', () {
      // The single most important instruction here, and the exact mistake
      // the keyword layer made: "I can't get up" is a call for help, not a
      // refusal of one.
      expect(description, contains("can't"));
      expect(description, anyOf(contains('not as refusals'), contains('not as a refusal')));
    });

    test('it names who the user is', () {
      expect(description, contains('blind'));
      expect(description, contains('cannot see the screen'));
    });

    test('it says which way to err, and why that is safe', () {
      expect(description, contains('erring toward calling this'));
      // Safe only because of the cancel window — if that instruction ever
      // leaves, so must the bias.
      expect(description, contains('cancel'));
      expect(description, contains('five seconds'));
    });

    test('it lists what must NOT trigger it', () {
      for (final counterExample in ['volume', 'what happens if', 'add my sister', "don't need"]) {
        expect(description, contains(counterExample), reason: counterExample);
      }
    });
  });
}
