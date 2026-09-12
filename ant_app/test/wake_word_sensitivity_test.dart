// The in-app sensitivity dial.
//
// Testers reported that "Hey Jarvis" has to be said softly, gently, and with
// a pause between the two words. That is a statement about where the detection
// line sits for their voices and their rooms — and the line was a compile-time
// constant (`--dart-define=WAKE_WORD_THRESHOLD_PCT`), so every guess at it cost
// a new APK and a new round of testing.
//
// What the dial cannot do is worth stating too: the cadence complaint ("a pause
// between the two words") is the placeholder `hey_jarvis_v0.1` model's fit to
// real voices, not a threshold. The point of shipping the live score alongside
// the slider is that testers can now *measure* that instead of describing it.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';
import 'package:ant_app/core/providers/ai_assistant_providers.dart';
import 'package:ant_app/core/services/wake_word_service.dart';
import 'package:ant_app/features/dashboard/widgets/wake_word_sensitivity_tile.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';

void main() {
  group('the threshold is settable at runtime', () {
    test('it starts at the build default', () {
      expect(WakeWordService(loadModels: () async => false).threshold,
          WakeWordService.defaultDetectionThreshold);
    });

    test('it can be moved without a restart', () {
      final service = WakeWordService(loadModels: () async => false);
      service.threshold = 0.22;
      expect(service.threshold, closeTo(0.22, 1e-9));
    });

    test('it is clamped, never rejected', () {
      // This value arrives from a persisted profile field that a future build
      // could widen or narrow. Refusing to listen at all because a stored
      // number is out of range would be the worst available outcome.
      final service = WakeWordService(loadModels: () async => false);

      service.threshold = -5;
      expect(service.threshold, WakeWordService.minThreshold);

      service.threshold = 99;
      expect(service.threshold, WakeWordService.maxThreshold);
    });

    test('neither end of the dial is a broken wake word', () {
      // At 0 every window fires and the microphone never closes; at 1 nothing
      // can fire and the wake word is silently off while claiming to be on.
      expect(WakeWordService.minThreshold, greaterThan(0));
      expect(WakeWordService.maxThreshold, lessThan(1));
    });

    test('even the most sensitive setting sits well clear of background', () {
      // The loudest background window measured on 12 September was 0.003. A
      // dial that lets a quiet room trigger the wake word is worse than no
      // dial: it is uninstalled the same day.
      expect(WakeWordService.minThreshold / 0.003, greaterThan(10));
    });
  });

  group('the chosen sensitivity survives', () {
    UserProfile profile({double? threshold}) => UserProfile(
          uid: 'u1',
          role: UserRole.disabledUser,
          wakeWordEnabled: true,
          wakeWordThreshold: threshold,
        );

    test('a Firestore round trip', () {
      expect(UserProfile.fromJson(profile(threshold: 0.22).toJson()).wakeWordThreshold,
          closeTo(0.22, 1e-9));
    });

    test('a profile written before the dial existed keeps the build default', () {
      final json = profile(threshold: 0.22).toJson()..remove('wakeWordThreshold');
      expect(UserProfile.fromJson(json).wakeWordThreshold, isNull,
          reason: 'null is what "never tuned" looks like, and the default stands');
    });

    test('a value stored as an int is still read as a threshold', () {
      // Firestore hands back whatever number type it stored, and a round 0 or
      // 1 can come back as an int.
      final json = profile(threshold: 0.22).toJson()..['wakeWordThreshold'] = 1;
      expect(UserProfile.fromJson(json).wakeWordThreshold, 1.0);
    });
  });

  group('the dial', () {
    Future<WakeWordService> pumpTile(
      WidgetTester tester, {
      double? threshold,
      bool enabled = true,
      required List<double> saved,
    }) async {
      final service = WakeWordService(loadModels: () async => false);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [wakeWordServiceProvider.overrideWithValue(service)],
          child: MaterialApp(
            home: Scaffold(
              body: WakeWordSensitivityTile(
                threshold: threshold,
                enabled: enabled,
                strings: Dashboard.of(AppLanguage.english),
                onChanged: saved.add,
              ),
            ),
          ),
        ),
      );
      return service;
    }

    testWidgets('reads higher sensitivity as an easier trigger, not a harder one',
        (tester) async {
      // The slider runs the opposite way to the threshold on purpose: dragging
      // right should make the wake word easier to trigger, which is a *lower*
      // score bar. Getting this backwards would be worse than no dial.
      final saved = <double>[];
      await pumpTile(tester, threshold: 0.5, saved: saved);

      await tester.drag(find.byType(Slider), const Offset(200, 0));
      await tester.pumpAndSettle();

      expect(saved, isNotEmpty);
      expect(saved.last, lessThan(0.5), reason: 'dragged right = more sensitive = lower threshold');
    });

    testWidgets('saves only when the drag ends', (tester) async {
      // Every save is a Firestore write. One per frame of a drag is not a dial,
      // it is a denial of service on the user's own profile document.
      final saved = <double>[];
      await pumpTile(tester, threshold: 0.5, saved: saved);

      await tester.drag(find.byType(Slider), const Offset(120, 0));
      await tester.pumpAndSettle();

      expect(saved, hasLength(1));
    });

    testWidgets('reset puts the build default back', (tester) async {
      final saved = <double>[];
      await pumpTile(tester, threshold: 0.8, saved: saved);

      await tester.tap(find.text(Dashboard.of(AppLanguage.english).settingsWakeWordReset));
      await tester.pumpAndSettle();

      expect(saved.single, WakeWordService.defaultDetectionThreshold);
    });

    testWidgets('shows the live score, so tuning is not guesswork', (tester) async {
      final service = await pumpTile(tester, threshold: 0.3, saved: []);

      // What a real attempt that failed to fire looked like on 12 September.
      service.lastScore.value = 0.34;
      await tester.pump();

      expect(find.textContaining('0.34'), findsOneWidget,
          reason: 'the number is the whole reason the dial is usable');
    });

    testWidgets('holds the peak, because the phrase spans only a few windows',
        (tester) async {
      // The classifier scores every 80ms and the phrase covers a handful of
      // windows, so a meter that only ever showed the current value would
      // flash the peak for one frame and be unreadable.
      final service = await pumpTile(tester, threshold: 0.3, saved: []);

      service.lastScore.value = 0.72;
      await tester.pump();
      service.lastScore.value = 0.0;
      await tester.pump();

      expect(find.textContaining('0.72'), findsOneWidget);

      // And it lets go again, rather than leaving a stale number reading as
      // current.
      await tester.pump(const Duration(seconds: 4));
      expect(find.textContaining('0.72'), findsNothing);
    });

    testWidgets('lays out on a narrow phone without overflowing', (tester) async {
      // The settings screen is a scrolling list on a 360dp-wide budget phone —
      // the Redmi 10C this is tested on. A tile that overflows there paints a
      // black-and-yellow bar over the very meter it exists to show.
      tester.view.physicalSize = const Size(360 * 3, 640 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      final service = WakeWordService(loadModels: () async => false);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [wakeWordServiceProvider.overrideWithValue(service)],
          child: MaterialApp(
            home: Scaffold(
              body: ListView(
                children: [
                  // Both languages: the Bangla strings are the longer ones, so
                  // English fitting proves nothing on its own.
                  for (final language in AppLanguage.values)
                    for (final enabled in [true, false])
                      WakeWordSensitivityTile(
                        threshold: 0.30,
                        enabled: enabled,
                        strings: Dashboard.of(language),
                        onChanged: (_) {},
                      ),
                ],
              ),
            ),
          ),
        ),
      );
      service.lastScore.value = 0.34;
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets('says why the meter is blank when the wake word is off', (tester) async {
      await pumpTile(tester, threshold: 0.3, enabled: false, saved: []);
      expect(find.text(Dashboard.of(AppLanguage.english).settingsWakeWordListeningOff),
          findsOneWidget);
    });
  });
}
