// The development skip. Tested mostly for what it must NOT do — it
// fabricates a disability profile and marks onboarding complete, which is
// exactly the kind of shortcut that must never reach a release build.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/features/onboarding/models/onboarding_step.dart';
import 'package:ant_app/features/onboarding/models/saved_place.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';
import 'package:ant_app/features/onboarding/providers/onboarding_providers.dart';
import 'package:ant_app/features/onboarding/screens/vision_question_screen.dart';

class _SeededController extends OnboardingController {
  _SeededController(this._seed);
  final OnboardingState _seed;
  @override
  OnboardingState build() => _seed;
}

void main() {
  testWidgets('the skip button is present in a debug build', (tester) async {
    // Tests run in debug, so `kDebugMode` is true here — this asserts the
    // button exists at all and is reachable from any onboarding screen,
    // since it lives in the shared scaffold.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          onboardingControllerProvider.overrideWith(
            () => _SeededController(OnboardingState(
              step: OnboardingStep.visionQuestion,
              profile: UserProfile(uid: 'u1', role: UserRole.disabledUser),
            )),
          ),
        ],
        child: const MaterialApp(home: VisionQuestionScreen()),
      ),
    );
    await tester.pump();
    expect(find.byIcon(Icons.fast_forward_rounded), findsOneWidget);
    expect(find.byTooltip('DEV: skip to dashboard'), findsOneWidget);
  });

  test('the dummy profile is complete enough to actually use', () {
    // A profile that is merely *valid* would still leave the dashboard
    // empty. These are the fields that make it useful on arrival.
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(onboardingControllerProvider.notifier);

    // ignore: invalid_use_of_visible_for_testing_member
    final profile = controller.debugDummyProfile('u1', AppLanguage.english);

    expect(profile.onboardingComplete, isTrue, reason: 'AppRoot routes on this');
    expect(profile.role, UserRole.disabledUser);
    expect(profile.magicButtonContacts, isNotEmpty);
    expect(profile.passerbyHelperMessages, isNotEmpty);
    expect(profile.homeAddress, isNotNull);

    // Saved places must carry real coordinates, or "take me to work" needs
    // a geocode that may not resolve — defeating the point of a shortcut.
    expect(profile.savedPlaces, hasLength(3));
    for (final place in profile.savedPlaces) {
      expect(place.hasCoordinates, isTrue, reason: '${place.label} has no coordinates');
      expect(place.isRoutable, isTrue);
      // Sanity-check they are actually in Dhaka.
      expect(place.lat, inInclusiveRange(23.6, 24.0));
      expect(place.lng, inInclusiveRange(90.2, 90.6));
    }
    expect(profile.savedPlaces.map((p) => p.kind),
        containsAll([SavedPlaceKind.work, SavedPlaceKind.school, SavedPlaceKind.family]));

    // Both off, so the microphone is not reopening after every utterance
    // while the dashboard is being poked at.
    expect(profile.wakeWordEnabled, isFalse);
    expect(profile.voiceAutoListen, isFalse);
  });

  test('the dummy profile survives a Firestore round trip', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    // ignore: invalid_use_of_visible_for_testing_member
    final profile = container
        .read(onboardingControllerProvider.notifier)
        .debugDummyProfile('u1', AppLanguage.bangla);
    final restored = UserProfile.fromJson(profile.toJson());

    expect(restored.onboardingComplete, isTrue);
    expect(restored.savedPlaces, hasLength(3));
    expect(restored.magicButtonContacts.first.name, 'Ma');
    expect(restored.language, AppLanguage.bangla, reason: 'keeps the language already chosen');
  });
}
