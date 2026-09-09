// Who gets auto-listen without being asked, and who gets asked.
//
// Reported as confusion rather than as a defect: "auto listen is a weird
// option, cos if hey jarvis is on, it should also be on by default right?
// maybe not?" — and the reason it read as weird is that nobody ever chose
// it. It was *derived*: on for anyone not fully sighted, or who said complex
// instructions were hard. So it appeared in settings beside the wake word,
// already on, with nothing explaining what it was or how the two related.
//
// The rule now: on for a blind user without asking, because they cannot find
// a mic button on a screen they cannot see, so a microphone that does not
// open itself is one they do not have. Everyone else is asked.

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/features/onboarding/models/disability_profile_enums.dart';
import 'package:ant_app/features/onboarding/models/onboarding_step.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';

void main() {
  group('who gets it without being asked', () {
    test('a blind user does', () {
      expect(
        autoListenDefaultFor(visionLevel: VisionLevel.none, complexInstructionsHard: false),
        isTrue,
      );
      expect(shouldAskAboutAutoListen(VisionLevel.none), isFalse,
          reason: 'a question with one sensible answer is worse than no question');
    });

    for (final level in [VisionLevel.low, VisionLevel.full]) {
      test('a ${level.name}-vision user is asked instead of having it inferred', () {
        expect(
          autoListenDefaultFor(visionLevel: level, complexInstructionsHard: true),
          isFalse,
          reason: 'nothing is turned on for them behind their back',
        );
        expect(shouldAskAboutAutoListen(level), isTrue);
      });
    }
  });

  test('the question has a step of its own, before voice setup', () {
    // It has to come after the vision answer that decides whether to ask at
    // all, and before the user reaches the dashboard.
    expect(
      OnboardingStep.values.indexOf(OnboardingStep.autoListenQuestion),
      greaterThan(OnboardingStep.values.indexOf(OnboardingStep.visionQuestion)),
    );
    expect(
      OnboardingStep.values.indexOf(OnboardingStep.autoListenQuestion),
      lessThan(OnboardingStep.values.indexOf(OnboardingStep.complete)),
    );
  });

  test('a profile built for a blind user has it on', () {
    final profile = UserProfile(
      uid: 'u1',
      role: UserRole.disabledUser,
      visionLevel: VisionLevel.none,
    );
    expect(profile.voiceAutoListen, isTrue);
  });

  test('a sighted profile does not, until they say so', () {
    final profile = UserProfile(
      uid: 'u1',
      role: UserRole.disabledUser,
      visionLevel: VisionLevel.full,
    );
    expect(profile.voiceAutoListen, isFalse);
    expect(profile.copyWith(voiceAutoListen: true).voiceAutoListen, isTrue);
  });
}
