// Item 26 — onboarding threw away everything if the app was killed.
//
// Both testers, independently: "app data clean hoye jacche", and against the
// kill-and-reopen step, "নষ্ট হয়ে যায় সব ডাটা আগের গুলো" — all the previous data
// is destroyed. Pack A step 19 says it should resume where it left off.
//
// There were two separate faults behind one complaint, and the second is the
// literal one:
//
//   1. Nothing recorded *which step* the user had reached. Every answer was
//      being written to Firestore after every step — `ProfileService`'s own
//      doc comment says that is why it upserts — but the flow always restarted
//      at language selection, so all of it was asked again.
//
//   2. `chooseRole` then built a brand-new `UserProfile` and saved it. That
//      write is `SetOptions(merge: true)` over the *same* uid, because
//      `ensureSignedIn` returns the existing anonymous user on relaunch — so
//      every default in a blank profile landed on top of the real answers.
//      The data was not merely re-requested, it was overwritten, by the
//      second screen of the app.

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:ant_app/features/onboarding/screens/onboarding_flow_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/providers/ai_assistant_providers.dart';
import 'package:ant_app/core/providers/tts_providers.dart';
import 'package:ant_app/core/services/stt_service.dart';
import 'package:ant_app/core/services/tts_service.dart';
import 'package:ant_app/features/onboarding/models/disability_profile_enums.dart';
import 'package:ant_app/features/onboarding/models/onboarding_step.dart';
import 'package:ant_app/features/onboarding/models/trusted_contact.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';
import 'package:ant_app/features/onboarding/providers/onboarding_providers.dart';
import 'package:ant_app/features/onboarding/services/auth_service.dart';
import 'package:ant_app/features/onboarding/services/pairing_service.dart';
import 'package:ant_app/features/onboarding/services/profile_service.dart';

/// A part-finished interview: vision, mobility and a Magic Button contact
/// already answered, and the user sitting on the deaf/hearing question.
UserProfile _halfFinished({OnboardingStep? step = OnboardingStep.deafHearingQuestion}) => UserProfile(
      uid: 'u1',
      role: UserRole.disabledUser,
      language: AppLanguage.bangla,
      visionLevel: VisionLevel.none,
      mobilityAid: MobilityAid.whiteCane,
      complexInstructionsHard: true,
      magicButtonContacts: const [TrustedContact(name: 'Ma', phoneNumber: '+8801711111111')],
      homeAddress: 'Dhanmondi 27',
      onboardingStep: step,
    );

ProviderContainer _container({
  required ProfileService profiles,
  AuthService? auth,
  OnboardingState? seed,
}) {
  final container = ProviderContainer(
    overrides: [
      profileServiceProvider.overrideWithValue(profiles),
      pairingServiceProvider.overrideWithValue(_FakePairing()),
      if (auth != null) authServiceProvider.overrideWithValue(auth),
      sttServiceProvider.overrideWithValue(_SilentStt()),
      ttsServiceProvider.overrideWithValue(_SilentTts()),
      if (seed != null)
        onboardingControllerProvider.overrideWith(() => _SeededController(seed)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('the step reached is carried in the profile', () {
    test('survives a Firestore round trip', () {
      final restored = UserProfile.fromJson(_halfFinished().toJson());
      expect(restored.onboardingStep, OnboardingStep.deafHearingQuestion);
    });

    test('a profile written before the field existed reads back null', () {
      final json = _halfFinished().toJson()..remove('onboardingStep');
      expect(UserProfile.fromJson(json).onboardingStep, isNull);
    });

    test('a step name this build does not have does not break the profile', () {
      // A renamed or removed step must cost the user their *position*, not
      // the whole document — everything else in it is still readable.
      final json = _halfFinished().toJson()..['onboardingStep'] = 'someStepFromTheFuture';
      final restored = UserProfile.fromJson(json);
      expect(restored.onboardingStep, isNull);
      expect(restored.mobilityAid, MobilityAid.whiteCane);
      expect(restored.homeAddress, 'Dhanmondi 27');
    });
  });

  group('resuming where the user left off', () {
    test('lands on the recorded step, with the answers intact', () {
      final profile = _halfFinished();
      final container = _container(profiles: _FakeProfiles());
      container.read(onboardingControllerProvider.notifier).resumeFrom(profile);

      final state = container.read(onboardingControllerProvider);
      expect(state.step, OnboardingStep.deafHearingQuestion,
          reason: 'this is the whole point — not languageSelection');
      expect(state.profile?.mobilityAid, MobilityAid.whiteCane);
      expect(state.profile?.magicButtonContacts, hasLength(1));
      expect(state.language, AppLanguage.bangla,
          reason: "the profile's language wins, not the default");
    });

    test('a profile with no recorded step goes back to role selection', () {
      // All that can honestly be inferred is that they got past it. Safe to
      // re-ask now only because `chooseRole` no longer overwrites answers.
      final container = _container(profiles: _FakeProfiles());
      container.read(onboardingControllerProvider.notifier).resumeFrom(_halfFinished(step: null));
      expect(container.read(onboardingControllerProvider).step, OnboardingStep.roleSelection);
    });

    test('a finished profile is never resumed into the interview', () {
      final container = _container(profiles: _FakeProfiles());
      container
          .read(onboardingControllerProvider.notifier)
          .resumeFrom(_halfFinished().copyWith(onboardingComplete: true));
      expect(container.read(onboardingControllerProvider).step, OnboardingStep.languageSelection,
          reason: 'untouched — AppRoot sends a finished profile to the dashboard');
    });

    test('resuming twice does not drag the user back', () {
      // The flow screen can rebuild for any reason. A second adoption would
      // undo whatever progress had been made since the first.
      final container = _container(profiles: _FakeProfiles());
      final controller = container.read(onboardingControllerProvider.notifier);
      controller.resumeFrom(_halfFinished());
      controller.skipPairing(); // -> visionQuestion
      controller.resumeFrom(_halfFinished());
      expect(container.read(onboardingControllerProvider).step, OnboardingStep.visionQuestion);
    });
  });

  // The device bug that survived the first fix, reported as "app data clean
  // hoye jaay close korlei".
  //
  // `_ProfileGate` renders `OnboardingFlowScreen(resumeFrom: profile)`, but on
  // a cold start `profileStreamProvider` frequently emits **null first** — the
  // local cache is empty after a force-kill, so the first snapshot has no
  // document and the real one lands a beat later. Adopting only in
  // `initState` meant the State was built with null, returned early, and the
  // profile that arrived afterwards came through `didUpdateWidget`, where
  // nothing was listening. The user got question one and their answers looked
  // destroyed.
  //
  // Invisible to the earlier tests because they all handed the profile over on
  // the very first build, which is the one case that was never broken.
  group('a profile that arrives after the first build', () {
    testWidgets('is still adopted', (tester) async {
      final profiles = _FakeProfiles();
      final container = _container(profiles: profiles);
      final profile = _halfFinished();

      Future<void> pumpWith(UserProfile? resumeFrom) => tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(home: OnboardingFlowScreen(resumeFrom: resumeFrom)),
            ),
          );

      // First frame: auth restored, but the document has not arrived yet.
      await pumpWith(null);
      await tester.pump();
      expect(container.read(onboardingControllerProvider).step, OnboardingStep.languageSelection);

      // The snapshot lands. Same widget type in the same slot, so Flutter
      // updates the existing State rather than creating a new one.
      await pumpWith(profile);
      await tester.pump();

      expect(container.read(onboardingControllerProvider).step, OnboardingStep.deafHearingQuestion,
          reason: 'this is the whole bug — a late profile must still resume');
      expect(container.read(onboardingControllerProvider).profile?.mobilityAid, MobilityAid.whiteCane);
    });

    testWidgets('and is still only adopted once', (tester) async {
      final container = _container(profiles: _FakeProfiles());
      final profile = _halfFinished();

      Future<void> pumpWith(UserProfile? resumeFrom) => tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(home: OnboardingFlowScreen(resumeFrom: resumeFrom)),
            ),
          );

      await pumpWith(null);
      await tester.pump();
      await pumpWith(profile);
      await tester.pump();

      container.read(onboardingControllerProvider.notifier).skipPairing();
      await tester.pump();

      // The stream keeps emitting. None of those may drag the user back.
      await pumpWith(profile);
      await tester.pump();
      expect(container.read(onboardingControllerProvider).step, OnboardingStep.visionQuestion);
    });
  });

  group('moving between steps records the position', () {
    test('the step is written on navigation', () async {
      final profiles = _FakeProfiles();
      final container = _container(
        profiles: profiles,
        seed: OnboardingState(step: OnboardingStep.userPairingCodeEntry, profile: _halfFinished()),
      );
      container.read(onboardingControllerProvider.notifier).skipPairing();
      await Future<void>.delayed(Duration.zero); // the write is fire-and-forget

      expect(profiles.stepsRecorded, [OnboardingStep.visionQuestion]);
      expect(container.read(onboardingControllerProvider).profile?.onboardingStep,
          OnboardingStep.visionQuestion,
          reason: 'the in-memory profile has to carry it too, or the next '
              'whole-profile write puts the old step back');
    });

    test('a failed step write does not break navigation', () async {
      // Losing the bookmark costs a resume point. Blocking the user on it
      // would cost them the app.
      final profiles = _FakeProfiles(failSteps: true);
      final container = _container(
        profiles: profiles,
        seed: OnboardingState(step: OnboardingStep.userPairingCodeEntry, profile: _halfFinished()),
      );
      container.read(onboardingControllerProvider.notifier).skipPairing();
      await Future<void>.delayed(Duration.zero);

      expect(container.read(onboardingControllerProvider).step, OnboardingStep.visionQuestion);
      expect(container.read(onboardingControllerProvider).errorMessage, isNull);
    });
  });

  group('choosing a role does not destroy what is already answered', () {
    test('an existing profile keeps every answer', () async {
      // The reported data loss, reproduced: relaunch, tap through language,
      // tap a role. Before the fix this wrote a blank profile over the top.
      final profiles = _FakeProfiles(existing: _halfFinished());
      final container = _container(profiles: profiles, auth: _FakeAuth());

      await container.read(onboardingControllerProvider.notifier).chooseRole(UserRole.disabledUser);

      final saved = profiles.lastSaved!;
      expect(saved.visionLevel, VisionLevel.none);
      expect(saved.mobilityAid, MobilityAid.whiteCane);
      expect(saved.complexInstructionsHard, isTrue);
      expect(saved.magicButtonContacts, hasLength(1));
      expect(saved.homeAddress, 'Dhanmondi 27');
      expect(saved.onboardingStep, OnboardingStep.deafHearingQuestion,
          reason: 'and the place they had got to is still recorded');
    });

    test('a genuinely new user still gets a fresh profile', () {
      final profiles = _FakeProfiles();
      final container = _container(profiles: profiles, auth: _FakeAuth());

      return container
          .read(onboardingControllerProvider.notifier)
          .chooseRole(UserRole.disabledUser)
          .then((_) {
        expect(profiles.lastSaved!.uid, 'u1');
        expect(profiles.lastSaved!.role, UserRole.disabledUser);
        expect(profiles.lastSaved!.visionLevel, VisionLevel.full);
      });
    });

    test('the chosen role is still applied to the existing profile', () async {
      final profiles = _FakeProfiles(existing: _halfFinished());
      final container = _container(profiles: profiles, auth: _FakeAuth());

      await container.read(onboardingControllerProvider.notifier).chooseRole(UserRole.caretaker);
      expect(profiles.lastSaved!.role, UserRole.caretaker);
    });

    test('a failed read is surfaced, not treated as "no profile"', () async {
      // The dangerous fallback: if a read error meant "start fresh", one
      // transient Firestore failure would wipe a finished interview.
      final profiles = _FakeProfiles(existing: _halfFinished(), failFetch: true);
      final container = _container(profiles: profiles, auth: _FakeAuth());

      await container.read(onboardingControllerProvider.notifier).chooseRole(UserRole.disabledUser);

      expect(profiles.lastSaved, isNull, reason: 'nothing may be written over their answers');
      expect(container.read(onboardingControllerProvider).errorMessage, isNotNull);
      expect(container.read(onboardingControllerProvider).isLoading, isFalse);
    });
  });
}

class _FakeProfiles implements ProfileService {
  _FakeProfiles({this.existing, this.failFetch = false, this.failSteps = false});

  final UserProfile? existing;
  final bool failFetch;
  final bool failSteps;

  UserProfile? lastSaved;
  final List<OnboardingStep> stepsRecorded = [];

  @override
  Future<UserProfile?> fetchProfile(String uid) async {
    if (failFetch) throw StateError('permission denied');
    return existing;
  }

  @override
  Future<void> saveProfile(UserProfile profile) async => lastSaved = profile;

  @override
  Future<void> saveOnboardingStep({required String uid, required OnboardingStep step}) async {
    if (failSteps) throw StateError('network unreachable');
    stepsRecorded.add(step);
  }

  @override
  Stream<UserProfile?> watchProfile(String uid) => const Stream.empty();
}

/// Only reached by the caretaker path, which generates a code the moment a
/// role is chosen. Without this the real one goes to Firestore and throws.
class _FakePairing implements PairingService {
  @override
  Future<String> generateCode({required String caretakerUid}) async => '123456';

  @override
  Stream<String?> watchClaimedBy(String code) => const Stream.empty();

  @override
  Future<String> redeemCode({required String code, required String disabledUserUid}) async => 'c1';
}

class _FakeAuth implements AuthService {
  @override
  Future<User> ensureSignedIn() async => _FakeUser();

  @override
  User? get currentUser => _FakeUser();

  @override
  Stream<User?> authStateChanges() => const Stream.empty();
}

/// Only `uid` is ever read off this. `User` has a large surface and none of
/// the rest of it is reachable from the paths under test.
class _FakeUser implements User {
  @override
  String get uid => 'u1';

  @override
  Future<String> getIdToken([bool forceRefresh = false]) async => 'token';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SeededController extends OnboardingController {
  _SeededController(this._seed);
  final OnboardingState _seed;
  @override
  OnboardingState build() => _seed;
}

class _SilentStt extends SttService {
  @override
  Future<void> stop() async {}
}

/// `implements`, not `extends` — `TtsService`'s constructor builds a
/// `FlutterTts` and a `CloudTtsService` (and through it an `AudioPlayer`),
/// all of which need platform channels no unit test has.
class _SilentTts implements TtsService {
  @override
  Future<void> speak(String text, {AppLanguage language = AppLanguage.english}) async {}
  @override
  Future<void> stop() async {}
  @override
  void setVoiceId(String voiceId) {}
}
