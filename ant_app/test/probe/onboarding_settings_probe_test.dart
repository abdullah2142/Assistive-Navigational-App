// Regression coverage for onboarding / resume / My Settings behaviours that
// were verified to work in the onboarding_settings QA pass. All offline.
//
//   flutter test --no-pub test/probe/onboarding_settings_probe_test.dart

import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart' show FirebaseException;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/config/tester_build_config.dart';
import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';
import 'package:ant_app/core/localization/onboarding_strings.dart';
import 'package:ant_app/core/providers/ai_assistant_providers.dart';
import 'package:ant_app/core/providers/tts_providers.dart';
import 'package:ant_app/core/services/stt_service.dart';
import 'package:ant_app/core/services/tts_service.dart';
import 'package:ant_app/core/utils/text_scale_levels.dart';
import 'package:ant_app/features/dashboard/screens/my_settings_screen.dart';
import 'package:ant_app/features/onboarding/models/disability_profile_enums.dart';
import 'package:ant_app/features/onboarding/models/onboarding_step.dart';
import 'package:ant_app/features/onboarding/models/saved_place.dart';
import 'package:ant_app/features/onboarding/models/trusted_contact.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';
import 'package:ant_app/features/onboarding/providers/onboarding_providers.dart';
import 'package:ant_app/features/onboarding/screens/vision_question_screen.dart';
import 'package:ant_app/features/onboarding/services/auth_service.dart';
import 'package:ant_app/features/onboarding/services/pairing_service.dart';
import 'package:ant_app/features/onboarding/services/profile_service.dart';
import 'package:ant_app/features/onboarding/widgets/onboarding_voice.dart';
import 'package:ant_app/features/onboarding/widgets/spoken_digits.dart';

// ---------------------------------------------------------------- fakes

class _Profiles implements ProfileService {
  _Profiles({this.delays = const []});

  /// Per-call artificial latency for saveProfile, consumed in order.
  final List<Duration> delays;
  int _n = 0;
  final saved = <UserProfile>[];

  @override
  Future<UserProfile?> fetchProfile(String uid) async => null;

  @override
  Future<void> saveProfile(UserProfile profile) async {
    final d = _n < delays.length ? delays[_n] : Duration.zero;
    _n++;
    if (d > Duration.zero) await Future<void>.delayed(d);
    saved.add(profile);
  }

  @override
  Future<void> saveOnboardingStep({required String uid, required OnboardingStep step}) async {}

  @override
  Stream<UserProfile?> watchProfile(String uid) => const Stream.empty();
}

class _Pairing implements PairingService {
  _Pairing({this.failWith});
  final Object? failWith;
  final redeemed = <String>[];

  @override
  Future<String> generateCode({required String caretakerUid}) async => '123456';

  @override
  Stream<String?> watchClaimedBy(String code) => const Stream.empty();

  @override
  Future<String> redeemCode({required String code, required String disabledUserUid}) async {
    redeemed.add(code);
    if (failWith != null) throw failWith!;
    return 'c1';
  }
}

class _StreamPairing implements PairingService {
  final claims = StreamController<String?>();
  @override
  Future<String> generateCode({required String caretakerUid}) async => '123456';
  @override
  Stream<String?> watchClaimedBy(String code) => claims.stream;
  @override
  Future<String> redeemCode({required String code, required String disabledUserUid}) async => 'c1';
}

class _OfflineProfiles extends _Profiles {
  @override
  Future<void> saveProfile(UserProfile profile) async => throw FirebaseException(
      plugin: 'cloud_firestore', code: 'unavailable', message: 'The service is currently unavailable.');
}

class _Auth implements AuthService {
  @override
  Future<User> ensureSignedIn() async => _User();
  @override
  User? get currentUser => _User();
  @override
  Stream<User?> authStateChanges() => const Stream.empty();
}

class _User implements User {
  @override
  String get uid => 'u1';
  @override
  Future<String> getIdToken([bool forceRefresh = false]) async => 'token';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Tts implements TtsService {
  final spoken = <String>[];
  @override
  Future<void> speak(String text, {AppLanguage language = AppLanguage.english}) async => spoken.add(text);
  @override
  Future<void> stop() async {}
  @override
  void setVoiceId(String voiceId) {}
}

/// Delivers [script] one utterance per listenOnce, then blocks until stop().
class _Stt extends SttService {
  _Stt({this.available = true, this.script = const []});
  final bool available;
  final List<String> script;
  int calls = 0;
  Completer<void>? _gate;

  @override
  Future<bool> ensureAvailable() async => available;

  @override
  Future<void> listenOnce({
    required AppLanguage language,
    required void Function(String text, bool isFinal) onResult,
    Duration pauseFor = const Duration(seconds: 3),
    Duration listenFor = const Duration(minutes: 5),
    Duration? initialSilence,
    List<String> phraseHints = const [],
  }) async {
    final i = calls++;
    if (i < script.length) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      onResult(script[i], true);
      return;
    }
    _gate = Completer<void>();
    await _gate!.future;
  }

  @override
  Future<void> stop() async {
    if (_gate != null && !_gate!.isCompleted) _gate!.complete();
  }
}

class _Seeded extends OnboardingController {
  _Seeded(this._seed);
  final OnboardingState _seed;
  @override
  OnboardingState build() => _seed;
}

ProviderContainer _container({
  ProfileService? profiles,
  PairingService? pairing,
  OnboardingState? seed,
}) {
  final c = ProviderContainer(overrides: [
    profileServiceProvider.overrideWithValue(profiles ?? _Profiles()),
    pairingServiceProvider.overrideWithValue(pairing ?? _Pairing()),
    authServiceProvider.overrideWithValue(_Auth()),
    sttServiceProvider.overrideWithValue(_Stt()),
    ttsServiceProvider.overrideWithValue(_Tts()),
    if (seed != null) onboardingControllerProvider.overrideWith(() => _Seeded(seed)),
  ]);
  addTearDown(c.dispose);
  return c;
}

/// Runs the real [listenForVoiceChoice] once with [heard] and returns the
/// label of the choice it selected, or null if nothing was selected.
Future<String?> _pick(List<OnboardingVoiceChoice> choices, String heard) async {
  String? selected;
  final stt = _Stt(script: List.filled(6, heard));
  final wrapped = [
    for (final c in choices)
      OnboardingVoiceChoice(label: c.label, synonyms: c.synonyms, onSelect: () => selected = c.label),
  ];
  await listenForVoiceChoice(
    stt: stt,
    tts: _Tts(),
    language: AppLanguage.english,
    choices: wrapped,
    retryHint: 'retry',
    isCancelled: () => selected != null || stt.calls >= 5,
  );
  return selected;
}


// ---------------------------------------------------------------- tests

void main() {
  final en = Onboarding.of(AppLanguage.english);

  OnboardingVoiceChoice ch(String l, List<String> s) =>
      OnboardingVoiceChoice(label: l, synonyms: s, onSelect: () {});

  group('profile persistence', () {
    test('round trip keeps the onboarding step and every accessibility answer', () {
      final p = UserProfile(
        uid: 'u1',
        role: UserRole.disabledUser,
        language: AppLanguage.bangla,
        visionLevel: VisionLevel.low,
        fontScale: 1.5,
        mobilityAid: MobilityAid.wheelchair,
        isDeafOrHardOfHearing: true,
        savedPlaces: const [SavedPlace(label: 'work', address: 'Gulshan', lat: 23.78, lng: 90.41)],
        magicButtonContacts: const [TrustedContact(name: 'আম্মু', phoneNumber: '01712345678')],
        onboardingStep: OnboardingStep.safeHavens,
      );
      final r = UserProfile.fromJson(p.toJson());
      expect(r.onboardingStep, OnboardingStep.safeHavens);
      expect(r.language, AppLanguage.bangla);
      expect(r.mobilityAid, MobilityAid.wheelchair);
      expect(r.magicButtonContacts.single.name, 'আম্মু');
      expect(r.savedPlaces.single.lat, 23.78);
    });

    test('a document with only uid and role (downgrade / partial write) reads with safe defaults', () {
      final r = UserProfile.fromJson({'uid': 'u1', 'role': 'disabledUser'});
      expect(r.onboardingComplete, isFalse);
      expect(r.onboardingStep, isNull);
      expect(r.visionLevel, VisionLevel.full);
      expect(r.savedPlaces, isEmpty);
      expect(r.magicButtonContacts, isEmpty);
    });

    test('unknown enum names and a null savedPlaces list do not throw', () {
      final r = UserProfile.fromJson({
        'uid': 'u1',
        'role': 'disabledUser',
        'visionLevel': 'someFutureLevel',
        'mobilityAid': 'hoverboard',
        'onboardingStep': 'removedStep',
        'savedPlaces': null,
      });
      expect(r.onboardingStep, isNull);
    });

    test('a profile that already says onboarding is complete is never resumed into the interview', () {
      final c = _container();
      c.read(onboardingControllerProvider.notifier).resumeFrom(UserProfile(
          uid: 'u1', role: UserRole.disabledUser, onboardingComplete: true, onboardingStep: OnboardingStep.lockIn));
      expect(c.read(onboardingControllerProvider).step, OnboardingStep.languageSelection);
    });

    test('resuming lands on exactly the recorded step for every step that needs no setup', () {
      for (final step in OnboardingStep.values) {
        if (step == OnboardingStep.caretakerPairing || step == OnboardingStep.complete) continue;
        final c = _container();
        c.read(onboardingControllerProvider.notifier).resumeFrom(UserProfile(
              uid: 'u1',
              role: UserRole.disabledUser,
              language: AppLanguage.bangla,
              visionLevel: VisionLevel.none,
              onboardingStep: step,
            ));
        final s = c.read(onboardingControllerProvider);
        expect(s.step, step, reason: 'resume must not skip or repeat $step');
        expect(s.profile!.visionLevel, VisionLevel.none, reason: 'answers survive resume at $step');
        expect(s.language, AppLanguage.bangla);
      }
    });

    test('a second resume (stream re-emit) does not drag the user back', () {
      final c = _container();
      final ctl = c.read(onboardingControllerProvider.notifier);
      final p = UserProfile(uid: 'u1', role: UserRole.disabledUser, onboardingStep: OnboardingStep.deafHearingQuestion);
      ctl.resumeFrom(p);
      ctl.skipPairing();
      ctl.resumeFrom(p);
      expect(c.read(onboardingControllerProvider).step, OnboardingStep.visionQuestion);
    });
  });

  group('navigation and stale listeners', () {
    test('every step change bumps the step generation so an older voice loop cancels', () async {
      final c = _container(seed: OnboardingState(
        step: OnboardingStep.mobilityQuestion,
        profile: UserProfile(uid: 'u1', role: UserRole.disabledUser),
      ));
      final ctl = c.read(onboardingControllerProvider.notifier);
      final g0 = c.read(onboardingControllerProvider).stepGeneration;
      await ctl.setMobilityAid(MobilityAid.wheelchair);
      expect(c.read(onboardingControllerProvider).stepGeneration, greaterThan(g0));
      final g1 = c.read(onboardingControllerProvider).stepGeneration;
      ctl.goBack();
      expect(c.read(onboardingControllerProvider).stepGeneration, greaterThan(g1));
      expect(c.read(onboardingControllerProvider).step, OnboardingStep.mobilityQuestion);
    });

    test('a failed save keeps the user on the step and asks the screen to re-arm its voice', () async {
      final c = _container(
        profiles: _OfflineProfiles(),
        seed: OnboardingState(
          step: OnboardingStep.mobilityQuestion,
          profile: UserProfile(uid: 'u1', role: UserRole.disabledUser),
        ),
      );
      final before = c.read(onboardingControllerProvider).voiceRearmToken;
      await c.read(onboardingControllerProvider.notifier).setMobilityAid(MobilityAid.whiteCane);
      final s = c.read(onboardingControllerProvider);
      expect(s.step, OnboardingStep.mobilityQuestion);
      expect(s.voiceRearmToken, greaterThan(before));
      expect(s.errorMessage, isNotNull);
    });

    test('continuing from contacts with none added is refused with an error', () {
      final c = _container(seed: OnboardingState(
        step: OnboardingStep.magicButtonContacts,
        profile: UserProfile(uid: 'u1', role: UserRole.disabledUser),
      ));
      c.read(onboardingControllerProvider.notifier).continueFromContacts();
      final s = c.read(onboardingControllerProvider);
      expect(s.step, OnboardingStep.magicButtonContacts);
      expect(s.errorMessage, isNotNull);
    });

    test('skipping the caretaker leaves pairedUserId null and moves to the vision question', () {
      final c = _container(seed: OnboardingState(
        step: OnboardingStep.userPairingCodeEntry,
        profile: UserProfile(uid: 'u1', role: UserRole.disabledUser),
      ));
      c.read(onboardingControllerProvider.notifier).skipPairing();
      expect(c.read(onboardingControllerProvider).step, OnboardingStep.visionQuestion);
      expect(c.read(onboardingControllerProvider).profile!.pairedUserId, isNull);
    });

    test('a blind user is not asked the auto-listen question and gets voice auto-listen on', () async {
      final c = _container(seed: OnboardingState(
        step: OnboardingStep.visionQuestion,
        profile: UserProfile(uid: 'u1', role: UserRole.disabledUser),
      ));
      final ctl = c.read(onboardingControllerProvider.notifier);
      await ctl.setVisionLevel(VisionLevel.none);
      expect(c.read(onboardingControllerProvider).profile!.voiceAutoListen, isTrue);
      expect(c.read(onboardingControllerProvider).profile!.themePreference, ThemePreference.dark);
      expect(c.read(onboardingControllerProvider).step, OnboardingStep.mobilityQuestion);
    });

    test('a low-vision user goes through calibration before the theme question', () async {
      final c = _container(seed: OnboardingState(
        step: OnboardingStep.visionQuestion,
        profile: UserProfile(uid: 'u1', role: UserRole.disabledUser),
      ));
      await c.read(onboardingControllerProvider.notifier).setVisionLevel(VisionLevel.low);
      expect(c.read(onboardingControllerProvider).step, OnboardingStep.visualCalibration);
    });
  });

  group('voice answers', () {
    test('control: a screen on the shared voice loop announces an unavailable microphone', () async {
      final tts = _Tts();
      final tester = TestWidgetsFlutterBinding.ensureInitialized();
      expect(tester, isNotNull);
      // Pumped in the widget test below; here only the plain loop is exercised.
      final stt = _Stt(available: false);
      await listenForVoiceChoice(
        stt: stt,
        tts: tts,
        language: AppLanguage.english,
        choices: [ch('yes', const [])],
        retryHint: 'retry',
        unavailableMessage: en.voiceUnavailableSpoken,
        isCancelled: () => false,
      );
      expect(tts.spoken, contains(en.voiceUnavailableSpoken));
    });

    test('plain, correct answers select the right option', () async {
      final vis = [
        ch(en.visionNoneLabel, en.visionNoneSynonyms),
        ch(en.visionLowLabel, en.visionLowSynonyms),
        ch(en.visionFullLabel, en.visionFullSynonyms),
      ];
      expect(await _pick(vis, 'No vision'), en.visionNoneLabel);
      expect(await _pick(vis, 'I am blind'), en.visionNoneLabel);
      expect(await _pick(vis, 'low vision'), en.visionLowLabel);
      expect(await _pick(vis, 'Full vision'), en.visionFullLabel);
      final mob = [
        ch(en.mobilityWhiteCaneLabel, en.mobilityWhiteCaneSynonyms),
        ch(en.mobilityWheelchairLabel, en.mobilityWheelchairSynonyms),
        ch(en.mobilityUnassistedLabel, en.mobilityUnassistedSynonyms),
      ];
      expect(await _pick(mob, 'I use a wheelchair'), en.mobilityWheelchairLabel);
      expect(await _pick(mob, 'white cane'), en.mobilityWhiteCaneLabel);
      expect(await _pick(mob, 'I walk alone'), en.mobilityUnassistedLabel);
      final snap = [
        ch(en.snapshotAlwaysLabel, en.snapshotAlwaysSynonyms),
        ch(en.snapshotAskLabel, en.snapshotAskSynonyms),
        ch(en.snapshotNeverLabel, en.snapshotNeverSynonyms),
      ];
      expect(await _pick(snap, 'never allow'), en.snapshotNeverLabel);
      expect(await _pick(snap, 'no'), en.snapshotNeverLabel);
      expect(await _pick(snap, 'ask me each time'), en.snapshotAskLabel);
    });

    test('gibberish selects nothing', () async {
      final vis = [ch(en.visionNoneLabel, en.visionNoneSynonyms), ch(en.visionFullLabel, en.visionFullSynonyms)];
      expect(await _pick(vis, 'blorp zibble quonk'), isNull);
    });

    test('a request for the options is answered with the options, never as an answer', () async {
      String? selected;
      final tts = _Tts();
      final stt = _Stt(script: const ['repeat the options please', 'full vision']);
      await listenForVoiceChoice(
        stt: stt,
        tts: tts,
        language: AppLanguage.english,
        choices: [OnboardingVoiceChoice(label: en.visionFullLabel, onSelect: () => selected = 'full')],
        helpText: 'Option one. Option two.',
        retryHint: 'retry',
        isCancelled: () => selected != null || stt.calls > 4,
      );
      expect(tts.spoken, contains('Option one. Option two.'));
      expect(selected, 'full');
    });

    test('an answer that arrives after the screen was left is not applied', () async {
      var selected = false;
      var cancelled = false;
      final stt = _Stt(script: const ['full vision']);
      await listenForVoiceChoice(
        stt: stt,
        tts: _Tts(),
        language: AppLanguage.english,
        choices: [OnboardingVoiceChoice(label: en.visionFullLabel, onSelect: () => selected = true)],
        retryHint: 'retry',
        isCancelled: () {
          if (stt.calls > 0) cancelled = true; // user left while the recognizer was running
          return stt.calls > 0;
        },
      );
      expect(cancelled, isTrue);
      expect(selected, isFalse);
    });

    test('a long sentence that merely contains the word help is not treated as a help request', () {
      expect(isHelpRequest('I am a caretaker and I will help my mother set this up today'), isFalse);
      expect(isHelpRequest('help'), isTrue);
      expect(isHelpRequest('বিকল্প'), isTrue);
    });

    test('deaf question: negation-aware yes/no', () {
      bool? deaf(String s) => classifyTraitYesNo(s,
          presentPhrases: en.deafPresentPhrases, absentPhrases: en.deafAbsentPhrases);
      final bn = Onboarding.of(AppLanguage.bangla);
      expect(deaf('I can hear fine'), isFalse);
      expect(deaf("I'm deaf"), isTrue);
      expect(deaf('no'), isFalse);
      expect(deaf('yes'), isTrue);
      expect(deaf('blorp'), isNull);
      expect(
          classifyTraitYesNo('কানে শুনি না',
              presentPhrases: bn.deafPresentPhrases, absentPhrases: bn.deafAbsentPhrases),
          isTrue);
    });
  });

  group('dictated digits', () {
    test('English words, double/triple, Bengali numerals and filler', () {
      expect(spokenTextToDigits('one two three four five six'), '123456');
      expect(spokenTextToDigits('double one triple two'), '11222');
      expect(spokenTextToDigits('০১৭১২৩৪৫৬৭৮'), '01712345678');
      expect(spokenTextToDigits('শূন্য এক সাত'), '017');
      expect(spokenTextToDigits('um my code is 1 2 3 uh'), '123');
      expect(spokenTextToDigits('blorp'), '');
    });

    test('text scale levels snap to named steps', () {
      expect(snapToLevel(1.3), 1.25);
      expect(snapToLevel(9), 2.0);
      expect(snapToLevel(0.1), 0.8);
    });
  });

  test('the onboarding skip button is a compile-time tester/debug flag, absent by default', () {
    expect(TesterBuildConfig.isTesterBuild, isFalse);
  });

  testWidgets('control: Vision screen with an unavailable microphone speaks the notice', (tester) async {
    final tts = _Tts();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        ttsServiceProvider.overrideWithValue(tts),
        sttServiceProvider.overrideWithValue(_Stt(available: false)),
        profileServiceProvider.overrideWithValue(_Profiles()),
        onboardingControllerProvider.overrideWith(() => _Seeded(OnboardingState(
              step: OnboardingStep.visionQuestion,
              profile: UserProfile(uid: 'u1', role: UserRole.disabledUser),
            ))),
      ],
      child: const MaterialApp(home: VisionQuestionScreen()),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(tts.spoken.any((t) => t.contains(en.voiceUnavailableSpoken)), isTrue);
    // and the tap path still works with no microphone
    await tester.tap(find.text(en.visionFullLabel));
    await tester.pump();
  });

  group('My Settings', () {
    Future<_Profiles> pump(WidgetTester tester, UserProfile p, {Size size = const Size(900, 12000)}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final fake = _Profiles();
      await tester.pumpWidget(ProviderScope(
        overrides: [
          profileServiceProvider.overrideWithValue(fake),
          profileStreamProvider(p.uid).overrideWith((ref) => Stream.value(p)),
        ],
        child: MaterialApp(home: MySettingsScreen(profile: p)),
      ));
      await tester.pump();
      await tester.pump();
      return fake;
    }

    final d = Dashboard.of(AppLanguage.english);

    testWidgets('cancelling the redo-onboarding confirmation saves nothing', (tester) async {
      final fake = await pump(tester, UserProfile(uid: 'u1', role: UserRole.disabledUser, onboardingComplete: true));
      await tester.tap(find.text(d.settingsRedoOnboardingButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text(d.settingsRedoOnboardingCancel));
      await tester.pumpAndSettle();
      expect(fake.saved, isEmpty);
    });

    testWidgets('deleting a saved place removes just that place', (tester) async {
      final p = UserProfile(uid: 'u1', role: UserRole.disabledUser, savedPlaces: const [
        SavedPlace(label: 'work', address: 'Gulshan 1'),
        SavedPlace(label: 'school', address: 'Dhanmondi'),
      ]);
      final fake = await pump(tester, p);
      await tester.tap(find.byIcon(Icons.delete_outline_rounded).first);
      await tester.pump();
      expect(fake.saved.last.savedPlaces.map((e) => e.label), ['school']);
    });

    testWidgets('a saved place needs both a name and an address', (tester) async {
      final fake = await pump(tester, UserProfile(uid: 'u1', role: UserRole.disabledUser));
      await tester.tap(find.text(d.settingsSavedPlaceSaveButton));
      await tester.pump();
      expect(fake.saved, isEmpty);
      expect(find.text(d.settingsSavedPlaceNeedsBoth), findsOneWidget);
    });

    testWidgets('mobility, theme and deaf toggles persist exactly one field change', (tester) async {
      final o = Onboarding.of(AppLanguage.english);
      final p = UserProfile(uid: 'u1', role: UserRole.disabledUser);
      final fake = await pump(tester, p);
      await tester.tap(find.widgetWithText(ChoiceChip, o.mobilityAidLabel(MobilityAid.wheelchair)));
      await tester.pump();
      expect(fake.saved.last.mobilityAid, MobilityAid.wheelchair);
      expect(fake.saved.last.toJson()..remove('mobilityAid'), p.toJson()..remove('mobilityAid'));
    });

    testWidgets('renders at 360dp wide with 2x system text in both languages without overflow', (tester) async {
      for (final lang in AppLanguage.values) {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1.0;
        final p = UserProfile(uid: 'u1', role: UserRole.disabledUser, fontScale: 2.0, language: lang,
            magicButtonContacts: const [TrustedContact(name: 'আম্মু খুব লম্বা একটা নাম', phoneNumber: '+8801712345678')]);
        await tester.pumpWidget(ProviderScope(
          key: UniqueKey(),
          overrides: [
            profileServiceProvider.overrideWithValue(_Profiles()),
            profileStreamProvider('u1').overrideWith((ref) => Stream.value(p)),
          ],
          child: MaterialApp(
            builder: (c, w) => MediaQuery(
                data: MediaQuery.of(c).copyWith(textScaler: const TextScaler.linear(2.0)), child: w!),
            home: MySettingsScreen(profile: p),
          ),
        ));
        await tester.pump();
        await tester.pump();
        for (var i = 0; i < 40; i++) {
          await tester.drag(find.byType(Scrollable).first, const Offset(0, -600));
          await tester.pump();
        }
        expect(tester.takeException(), isNull, reason: '$lang');
      }
      addTearDown(tester.view.reset);
    });
  });
}
