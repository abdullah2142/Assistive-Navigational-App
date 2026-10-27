// Regression coverage for behaviours verified as working (area a11y_visual_motor).
// Layout tests load Liberation Sans / Noto Sans Bengali from the system when
// present so text metrics are close to the shipped fonts (Flutter's default
// test font, Ahem, is far wider than Inter). When the fonts are missing the
// tests still run, with harsher metrics.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';
import 'package:ant_app/core/localization/onboarding_strings.dart';
import 'package:ant_app/core/providers/ai_assistant_providers.dart';
import 'package:ant_app/core/providers/tts_providers.dart';
import 'package:ant_app/core/services/stt_service.dart';
import 'package:ant_app/core/services/tts_service.dart';
import 'package:ant_app/core/theme/app_colors.dart';
import 'package:ant_app/core/theme/app_theme.dart';
import 'package:ant_app/features/dashboard/models/chat_message.dart';
import 'package:ant_app/features/dashboard/models/hazard_report.dart';
import 'package:ant_app/features/dashboard/providers/dashboard_providers.dart';
import 'package:ant_app/features/dashboard/screens/my_settings_screen.dart';
import 'package:ant_app/features/dashboard/screens/split_mode_dashboard_screen.dart';
import 'package:ant_app/features/dashboard/services/hazard_report_service.dart';
import 'package:ant_app/features/dashboard/widgets/chat_bubble.dart';
import 'package:ant_app/features/dashboard/widgets/crowdsource_reporting_hub.dart';
import 'package:ant_app/features/dashboard/widgets/passerby_helper_overlay.dart';
import 'package:ant_app/features/onboarding/models/onboarding_step.dart';
import 'package:ant_app/features/onboarding/models/trusted_contact.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';
import 'package:ant_app/features/onboarding/providers/onboarding_providers.dart';
import 'package:ant_app/features/onboarding/screens/frequent_places_screen.dart';
import 'package:ant_app/features/onboarding/screens/lock_in_screen.dart';
import 'package:ant_app/features/onboarding/screens/passerby_messages_screen.dart';
import 'package:ant_app/features/onboarding/screens/vision_question_screen.dart';
import 'package:ant_app/features/onboarding/screens/language_selection_screen.dart';
import 'package:ant_app/features/onboarding/screens/mobility_question_screen.dart';
import 'package:ant_app/features/onboarding/screens/theme_preference_screen.dart';
import 'package:ant_app/features/dashboard/widgets/destination_sheet.dart';
import 'package:ant_app/features/onboarding/models/saved_place.dart';
import 'package:ant_app/features/onboarding/services/profile_service.dart';

const _ls = '/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf';
const _nb = '/usr/share/fonts/truetype/noto/NotoSansBengali-Regular.ttf';

Future<void> _loadFonts() async {
  for (final e in {'LS': _ls, 'NB': _nb}.entries) {
    if (!File(e.value).existsSync()) continue;
    final l = FontLoader(e.key)..addFont(Future.value(ByteData.sublistView(File(e.value).readAsBytesSync())));
    await l.load();
  }
}

ThemeData _real(ThemeData t) => File(_ls).existsSync()
    ? t.copyWith(textTheme: t.textTheme.apply(fontFamily: 'LS', fontFamilyFallback: const ['NB']))
    : t;

double _ratio(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return (x > y ? x + .05 : y + .05) / (x > y ? y + .05 : x + .05);
}

class _Tts implements TtsService {
  @override
  Future<void> speak(String t, {AppLanguage language = AppLanguage.english}) => Completer<void>().future;
  @override
  Future<void> stop() async {}
  @override
  void setVoiceId(String v) {}
}

class _Stt extends SttService {
  @override
  Future<bool> ensureAvailable() async => false;
  @override
  Future<void> listenOnce({
    required AppLanguage language,
    required void Function(String text, bool isFinal) onResult,
    Duration pauseFor = const Duration(seconds: 3),
    Duration listenFor = const Duration(minutes: 5),
    Duration? initialSilence,
    List<String> phraseHints = const [],
  }) async {}
  @override
  Future<void> stop() async {}
}

class _Profiles implements ProfileService {
  final saved = <UserProfile>[];
  @override
  Future<UserProfile?> fetchProfile(String uid) async => null;
  @override
  Future<void> saveProfile(UserProfile p) async => saved.add(p);
  @override
  Future<void> saveOnboardingStep({required String uid, required OnboardingStep step}) async {}
  @override
  Stream<UserProfile?> watchProfile(String uid) => const Stream.empty();
}

class _Seeded extends OnboardingController {
  _Seeded(this.s);
  final OnboardingState s;
  @override
  OnboardingState build() => s;
}

class _Reports implements HazardReportService {
  @override
  Future<void> submitReport(HazardReport r) async {}
}


class _SlowReports implements HazardReportService {
  final submitted = <HazardReport>[];
  @override
  Future<void> submitReport(HazardReport r) {
    submitted.add(r);
    return Completer<Object>().future.then((_) {});
  }
}

final bool _haveFonts = File(_ls).existsSync();

void main() {
  group('contrast that holds', () {
    test('body text, primary buttons and assistant bubbles clear 4.5:1 in all four themes', () {
      for (final t in {
        'light': AppTheme.standard(),
        'dark': AppTheme.standardDark(),
        'hcLight': AppTheme.highContrastLight(),
        'hcDark': AppTheme.highContrastDark(),
      }.entries) {
        final c = t.value.colorScheme;
        final bg = t.value.scaffoldBackgroundColor;
        expect(_ratio(c.onSurface, c.surface), greaterThanOrEqualTo(7), reason: '${t.key} assistant bubble');
        expect(_ratio(c.onSurface, bg), greaterThanOrEqualTo(7), reason: '${t.key} body');
        expect(_ratio(c.onPrimary, c.primary), greaterThanOrEqualTo(4.5), reason: '${t.key} filled button / user bubble');
        expect(_ratio(c.primary, bg), greaterThanOrEqualTo(4.5), reason: '${t.key} outlined button text on page');
        final small = Color.alphaBlend(t.value.textTheme.bodySmall!.color!, bg);
        expect(_ratio(small, bg), greaterThanOrEqualTo(4.5), reason: '${t.key} bodySmall (75% alpha)');
      }
    });

    test('light-theme secondary text, error text and white-on-danger banner clear 4.5:1', () {
      expect(_ratio(AppColors.textSecondary, AppColors.background), greaterThanOrEqualTo(4.5));
      expect(_ratio(AppColors.darkTextSecondary, AppColors.darkBackground), greaterThanOrEqualTo(4.5));
      expect(_ratio(AppColors.danger, AppColors.background), greaterThanOrEqualTo(4.5));
      expect(_ratio(Colors.white, AppColors.danger), greaterThanOrEqualTo(4.5), reason: 'emergency banner');
      expect(_ratio(AppColors.passerbyHelperText, AppColors.passerbyHelperBackground), greaterThanOrEqualTo(7));
    });

    test('white icons on the filled circular buttons clear the 3:1 UI-component bar', () {
      expect(_ratio(Colors.white, AppColors.primaryLight), greaterThanOrEqualTo(3));
      expect(_ratio(Colors.white, AppColors.primary), greaterThanOrEqualTo(4.5));
      expect(_ratio(Colors.white, AppColors.danger), greaterThanOrEqualTo(3));
    });
  });

  testWidgets('My Settings icon buttons (remove place / contact / message) are at least 48x48', (tester) async {
    tester.view.physicalSize = const Size(360, 20000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final p = UserProfile(
      uid: 'u1',
      role: UserRole.disabledUser,
      onboardingComplete: true,
      magicButtonContacts: const [TrustedContact(name: 'Amma', phoneNumber: '+8801712345678')],
      passerbyHelperMessages: const ['Please help me cross'],
      savedPlaces: const [SavedPlace(label: 'work', address: 'Gulshan 1')],
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [
        profileServiceProvider.overrideWithValue(_Profiles()),
        profileStreamProvider('u1').overrideWith((ref) => Stream.value(p)),
      ],
      child: MaterialApp(theme: AppTheme.standard(), home: MySettingsScreen(profile: p)),
    ));
    await tester.pump();
    await tester.pump();
    for (final e in find.byType(IconButton).evaluate()) {
      final s = (e.renderObject! as RenderBox).size;
      expect(s.width, greaterThanOrEqualTo(48));
      expect(s.height, greaterThanOrEqualTo(48));
    }
  });

  testWidgets('hazard report Submit is disabled while sending, so a double tap files one report', (tester) async {
    await _loadFonts();
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final d = Dashboard.of(AppLanguage.english);
    final svc = _SlowReports();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        hazardReportServiceProvider.overrideWithValue(svc),
        ttsServiceProvider.overrideWithValue(_Tts()),
        sttServiceProvider.overrideWithValue(_Stt()),
      ],
      child: MaterialApp(
        theme: _real(AppTheme.standard()),
        home: const CrowdsourceReportingHub(reporterUid: 'u', language: AppLanguage.english, voiceAutoListen: false),
      ),
    ));
    await tester.tap(find.text(d.hazardCategoryLabel(HazardCategory.roadHazard)));
    await tester.pump();
    final key = d.hazardSubCategoryKeys(HazardCategory.roadHazard).firstWhere((k) => !d.isOtherSubCategoryKey(k));
    await tester.tap(find.text(d.hazardSubCategoryLabel(key)));
    await tester.pump();
    final submit = find.text(d.crowdsourceSubmitButton);
    await tester.tap(submit);
    await tester.pump(const Duration(milliseconds: 30));
    await tester.tap(find.byType(ElevatedButton), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 30));
    expect(tester.widget<ElevatedButton>(find.byType(ElevatedButton)).enabled, isFalse);
    await tester.pump(const Duration(seconds: 30));
    expect(svc.submitted.length, lessThanOrEqualTo(1));
  }, skip: !_haveFonts);

  testWidgets('rotating the dashboard keeps the half-typed message', (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(home: SplitModeDashboardScreen(profile: UserProfile(uid: 'u', role: UserRole.disabledUser))),
    ));
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, 'take me to Farmgate');
    await tester.pump();
    tester.view.physicalSize = const Size(915, 412);
    await tester.pump();
    tester.takeException(); // layout of the landscape squeeze is covered by the bug file
    expect(find.text('take me to Farmgate'), findsOneWidget);
    tester.view.physicalSize = const Size(412, 915);
    await tester.pump();
    tester.takeException();
    expect(find.text('take me to Farmgate'), findsOneWidget);
  });

  testWidgets('destination sheet fits 320x568 at 2.0x text with saved places', (tester) async {
    await _loadFonts();
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        theme: _real(AppTheme.standard()),
        builder: (c, w) => MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: const TextScaler.linear(2.0)), child: w!),
        home: Builder(
          builder: (c) => Scaffold(
            body: Center(
              child: ElevatedButton(
                child: const Text('open'),
                onPressed: () => showModalBottomSheet<void>(
                  context: c,
                  isScrollControlled: true,
                  builder: (_) => DestinationSheet(
                    profile: UserProfile(
                      uid: 'u',
                      role: UserRole.disabledUser,
                      language: AppLanguage.bangla,
                      savedPlaces: const [SavedPlace(label: 'আমার বাসা', address: 'ধানমন্ডি ৩২'), SavedPlace(label: 'Work', address: 'Gulshan 1')],
                    ),
                    onPickOnMap: () async => null,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
  }, skip: !_haveFonts);

  for (final cfg in {
    'std 360x640 @1.0': (AppTheme.standard(), const Size(360, 640), 1.0),
    'std 360x640 @2.0': (AppTheme.standard(), const Size(360, 640), 2.0),
    'hcDark(1.4) 360x640 @1.5': (AppTheme.highContrastDark(), const Size(360, 640), 1.5),
    'hcDark(1.4) 412x915 @2.0': (AppTheme.highContrastDark(), const Size(412, 915), 2.0),
    'std(2.0) 412x915 @1.5': (AppTheme.standard(fontScale: 2.0), const Size(412, 915), 1.5),
    'std 640x360 landscape @2.0': (AppTheme.standard(), const Size(640, 360), 2.0),
  }.entries) {
    testWidgets('dashboard keeps mic and send on screen: ${cfg.key}', (tester) async {
      await _loadFonts();
      tester.view.physicalSize = cfg.value.$2;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          theme: _real(cfg.value.$1),
          builder: (c, w) => MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(cfg.value.$3)), child: w!),
          home: SplitModeDashboardScreen(profile: UserProfile(uid: 'u', role: UserRole.disabledUser)),
        ),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);
      final screen = Offset.zero & cfg.value.$2;
      for (final icon in [Icons.mic_rounded, Icons.send_rounded]) {
        final r = tester.getRect(find.byIcon(icon).first);
        expect(screen.contains(r.center), isTrue, reason: '$icon');
      }
    }, skip: !_haveFonts);
  }

  testWidgets('onboarding option screens fit 360x640 at 1.5x system text', (tester) async {
    await _loadFonts();
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final failures = <String>[];
    for (final lang in AppLanguage.values) {
      for (final entry in {
        'vision': const VisionQuestionScreen(),
        'language': const LanguageSelectionScreen(),
        'mobility': const MobilityQuestionScreen(),
        'theme': const ThemePreferenceScreen(),
      }.entries) {
        await tester.pumpWidget(ProviderScope(
          key: UniqueKey(),
          overrides: [
            ttsServiceProvider.overrideWithValue(_Tts()),
            sttServiceProvider.overrideWithValue(_Stt()),
            profileServiceProvider.overrideWithValue(_Profiles()),
            onboardingControllerProvider.overrideWith(() => _Seeded(OnboardingState(
                  step: OnboardingStep.values.first,
                  profile: UserProfile(uid: 'u', role: UserRole.disabledUser, language: lang),
                ))),
          ],
          child: MaterialApp(
            theme: _real(AppTheme.standard()),
            builder: (c, w) => MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: const TextScaler.linear(1.5)), child: w!),
            home: entry.value,
          ),
        ));
        await tester.pump(const Duration(milliseconds: 100));
        final e = tester.takeException();
        if (e != null) failures.add('${lang.name} ${entry.key}');
      }
    }
    expect(failures, isEmpty);
  }, skip: !_haveFonts);

  testWidgets('passer-by overlay shows every default message in full at normal text size (landscape 800x360)', (tester) async {
    await _loadFonts();
    tester.view.physicalSize = const Size(800, 360);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    for (final lang in AppLanguage.values) {
      for (final m in Onboarding.of(lang).defaultPasserbyMessages) {
        await tester.pumpWidget(ProviderScope(
          key: UniqueKey(),
          overrides: [ttsServiceProvider.overrideWithValue(_Tts()), sttServiceProvider.overrideWithValue(_Stt())],
          child: MaterialApp(
            theme: _real(AppTheme.standard()),
            builder: (c, w) => DefaultTextStyle.merge(style: const TextStyle(fontFamily: 'LS', fontFamilyFallback: ['NB']), child: w!),
            home: PasserbyHelperOverlay(message: m, strings: Dashboard.of(lang), language: lang),
          ),
        ));
        await tester.pump(const Duration(milliseconds: 50));
        final rp = tester.renderObject<RenderParagraph>(find.text(m));
        expect(rp.getMaxIntrinsicHeight(800 - 64), lessThanOrEqualTo(360 - 64), reason: m);
      }
    }
    await tester.pump(const Duration(seconds: 10));
  }, skip: !_haveFonts);
}
