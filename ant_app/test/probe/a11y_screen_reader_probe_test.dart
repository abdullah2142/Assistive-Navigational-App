// Regression coverage for screen-reader (TalkBack) behaviour verified to work.
import 'dart:async';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';
import 'package:ant_app/core/localization/onboarding_strings.dart';
import 'package:ant_app/core/providers/ai_assistant_providers.dart';
import 'package:ant_app/core/providers/tts_providers.dart';
import 'package:ant_app/core/services/emergency_service.dart';
import 'package:ant_app/core/services/stt_service.dart';
import 'package:ant_app/core/services/tts_service.dart';
import 'package:ant_app/features/dashboard/models/chat_message.dart';
import 'package:ant_app/features/dashboard/models/hazard_report.dart';
import 'package:ant_app/features/dashboard/providers/dashboard_providers.dart';
import 'package:ant_app/features/dashboard/screens/my_settings_screen.dart';
import 'package:ant_app/features/dashboard/screens/split_mode_dashboard_screen.dart';
import 'package:ant_app/features/dashboard/services/hazard_report_service.dart';
import 'package:ant_app/features/dashboard/widgets/chat_bubble.dart';
import 'package:ant_app/features/dashboard/widgets/crowdsource_reporting_hub.dart';
import 'package:ant_app/features/dashboard/widgets/emergency_cancel_banner.dart';
import 'package:ant_app/features/dashboard/widgets/passerby_helper_overlay.dart';
import 'package:ant_app/features/dashboard/widgets/passerby_message_picker.dart';
import 'package:ant_app/features/onboarding/models/onboarding_step.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';
import 'package:ant_app/features/onboarding/providers/onboarding_providers.dart';
import 'package:ant_app/features/onboarding/screens/cognitive_anxiety_screen.dart';
import 'package:ant_app/features/onboarding/screens/vision_question_screen.dart';
import 'package:ant_app/features/onboarding/services/profile_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

SemanticsNode? findNode(WidgetTester t, bool Function(SemanticsData) test) {
  SemanticsNode? hit;
  void walk(SemanticsNode n) {
    if (hit != null) return;
    if (test(n.getSemanticsData())) {
      hit = n;
      return;
    }
    n.visitChildren((c) {
      walk(c);
      return true;
    });
  }

  walk(t.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!);
  return hit;
}

List<SemanticsData> nodes(WidgetTester t) {
  final out = <SemanticsData>[];
  void walk(SemanticsNode n) {
    out.add(n.getSemanticsData());
    n.visitChildren((c) {
      walk(c);
      return true;
    });
  }

  walk(t.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!);
  return out;
}

class _Tts implements TtsService {
  @override
  Future<void> speak(String text, {AppLanguage language = AppLanguage.english}) async {}
  @override
  Future<void> stop() async {}
  @override
  void setVoiceId(String voiceId) {}
}

class _Stt extends SttService {
  @override
  Future<bool> ensureAvailable() async => true;
  @override
  Future<void> listenOnce({
    required AppLanguage language,
    required void Function(String, bool) onResult,
    Duration pauseFor = const Duration(seconds: 3),
    Duration listenFor = const Duration(minutes: 5),
    Duration? initialSilence,
    List<String> phraseHints = const [],
  }) async {
    await Completer<void>().future;
  }

  @override
  Future<void> stop() async {}
}

class _Profiles implements ProfileService {
  @override
  Future<UserProfile?> fetchProfile(String uid) async => null;
  @override
  Future<void> saveProfile(UserProfile profile) async {}
  @override
  Future<void> saveOnboardingStep({required String uid, required OnboardingStep step}) async {}
  @override
  Stream<UserProfile?> watchProfile(String uid) => const Stream.empty();
}

class _Reports implements HazardReportService {
  final submitted = <HazardReport>[];
  @override
  Future<void> submitReport(HazardReport report) async => submitted.add(report);
}

class _Seeded extends OnboardingController {
  _Seeded(this._seed);
  final OnboardingState _seed;
  @override
  OnboardingState build() => _seed;
}

final _ov = [ttsServiceProvider.overrideWithValue(_Tts()), sttServiceProvider.overrideWithValue(_Stt())];
final bn = Dashboard.of(AppLanguage.bangla);
UserProfile _bnProfile() => UserProfile(uid: 'u1', role: UserRole.disabledUser, language: AppLanguage.bangla);

void main() {
  testWidgets('assistant bubble: Bangla speaker prefix, long-press and a custom Reply action for TalkBack', (tester) async {
    final h = tester.ensureSemantics();
    var replied = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatBubble(
          message: ChatMessage(sender: ChatSender.assistant, text: 'সামনে গর্ত', timestamp: DateTime(2026)),
          strings: bn,
          onReply: () => replied++,
        ),
      ),
    ));
    final node = findNode(tester, (d) => d.label.contains('সামনে গর্ত'))!;
    final data = node.getSemanticsData();
    expect(data.label, startsWith(bn.chatAssistantSaid('').trim().split(':').first));
    expect(data.hasAction(SemanticsAction.longPress), isTrue);
    expect(data.customSemanticsActionIds, isNotEmpty);
    final action = CustomSemanticsAction.getAction(data.customSemanticsActionIds!.first)!;
    expect(action.label, bn.chatReplyAction);
    tester.binding.pipelineOwner.semanticsOwner!.performAction(
      node.id, SemanticsAction.customAction, data.customSemanticsActionIds!.first);
    expect(replied, 1);
    h.dispose();
  });

  testWidgets('bubble without a reply handler (user/caretaker) exposes no custom action', (tester) async {
    final h = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatBubble(
          message: ChatMessage(sender: ChatSender.user, text: 'হ্যালো', timestamp: DateTime(2026)),
          strings: bn,
        ),
      ),
    ));
    final d = findNode(tester, (d) => d.label.contains('হ্যালো'))!.getSemanticsData();
    expect(d.customSemanticsActionIds ?? const [], isEmpty);
    expect(d.label, contains(bn.chatYouSaid('').trim().split(':').first));
    h.dispose();
  });

  testWidgets('voice-message bubble is a single tappable button (no hidden second target)', (tester) async {
    final h = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatBubble(
          message: ChatMessage(
            sender: ChatSender.caretaker, text: '', timestamp: DateTime(2026),
            audioBase64: 'AAAA', audioDurationSeconds: 7),
          strings: bn,
        ),
      ),
    ));
    final tappable = nodes(tester).where((d) => d.hasAction(SemanticsAction.tap)).toList();
    expect(tappable, hasLength(1));
    expect(tappable.single.flagsCollection.isButton, isTrue);
    expect(tappable.single.label, contains('7'));
    h.dispose();
  });

  testWidgets('emergency banner: live region carrying title+body+cancel while counting down, gone otherwise', (tester) async {
    final h = tester.ensureSemantics();
    final phase = ValueNotifier(EmergencyPhase.idle);
    await tester.pumpWidget(ProviderScope(
      overrides: [emergencyPhaseProvider.overrideWithValue(phase)],
      child: const MaterialApp(home: Scaffold(body: EmergencyCancelBanner(language: AppLanguage.bangla))),
    ));
    expect(nodes(tester).where((d) => d.label.contains(bn.emergencyBannerTitle)), isEmpty);
    phase.value = EmergencyPhase.countdown;
    await tester.pump();
    final banner = nodes(tester).firstWhere((d) => d.label.contains(bn.emergencyBannerTitle));
    expect(banner.flagsCollection.isLiveRegion, isTrue);
    expect(banner.label, contains(bn.emergencyBannerBody));
    expect(banner.label, contains(bn.emergencyBannerCancel));
    phase.value = EmergencyPhase.dispatching;
    await tester.pump();
    expect(nodes(tester).where((d) => d.label.contains(bn.emergencyBannerTitle)), isEmpty);
    h.dispose();
  });

  testWidgets('dashboard: chat controls are named buttons/text field in Bangla, map toggle state is in the label', (tester) async {
    final h = tester.ensureSemantics();
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(home: SplitModeDashboardScreen(profile: _bnProfile())),
    ));
    await tester.pump();
    final all = nodes(tester);
    bool has(String l) => all.any((d) => d.label.contains(l));
    expect(has(bn.chatSpeakSemantics), isTrue);
    expect(has(bn.chatSendSemantics), isTrue);
    expect(has(bn.mapShowSemantics), isTrue);
    expect(all.any((d) => d.flagsCollection.isTextField && d.label.contains(bn.chatInputHint)), isTrue);
    expect(all.firstWhere((d) => d.label.contains(bn.chatSpeakSemantics)).hint, bn.chatSpeakHint);
    await tester.tap(find.byIcon(Icons.map_outlined));
    await tester.pump();
    expect(nodes(tester).any((d) => d.label.contains(bn.mapHideSemantics)), isTrue);
    expect(nodes(tester).any((d) => d.label.contains(bn.mapShowSemantics)), isFalse);
    h.dispose();
  });

  testWidgets('map split handle can be resized by the TalkBack increase/decrease actions alone', (tester) async {
    final h = tester.ensureSemantics();
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(home: SplitModeDashboardScreen(profile: _bnProfile())),
    ));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.map_outlined));
    await tester.pump();
    final node = findNode(tester, (d) => d.flagsCollection.isSlider && d.label.contains(bn.mapResizeSemantics))!;
    final data = node.getSemanticsData();
    expect(data.hasAction(SemanticsAction.increase), isTrue);
    expect(data.hasAction(SemanticsAction.decrease), isTrue);
    final before = tester.getSize(find.byType(SplitModeDashboardScreen)).height; // sanity: screen present
    expect(before, greaterThan(0));
    final chatBefore = tester.getRect(find.byKey(const ValueKey('chat-input-row'))).top;
    tester.binding.pipelineOwner.semanticsOwner!.performAction(node.id, SemanticsAction.increase);
    await tester.pump();
    final chatAfter = tester.getRect(find.byKey(const ValueKey('chat-input-row'))).top;
    expect(chatAfter, isNot(chatBefore), reason: 'increase moved the divider');
    h.dispose();
  });

  testWidgets('hazard report: whole category -> sub-type -> details -> submit flow works through semantics taps only', (tester) async {
    final h = tester.ensureSemantics();
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    final reports = _Reports();
    await tester.pumpWidget(ProviderScope(
      overrides: [..._ov, hazardReportServiceProvider.overrideWithValue(reports)],
      child: const MaterialApp(
        home: CrowdsourceReportingHub(reporterUid: 'u1', language: AppLanguage.bangla, voiceAutoListen: false),
      ),
    ));
    await tester.pump();
    final owner = tester.binding.pipelineOwner.semanticsOwner!;
    void tapLabel(String l) {
      final n = findNode(tester, (d) => d.hasAction(SemanticsAction.tap) && d.label.contains(l));
      expect(n, isNotNull, reason: 'no tappable node named $l');
      owner.performAction(n!.id, SemanticsAction.tap);
    }

    tapLabel(bn.hazardCategoryLabel(HazardCategory.roadHazard));
    await tester.pump();
    final sub = bn.hazardSubCategoryKeys(HazardCategory.roadHazard).firstWhere((k) => !bn.isOtherSubCategoryKey(k));
    tapLabel(bn.hazardSubCategoryLabel(sub));
    await tester.pump();
    expect(nodes(tester).any((d) => d.flagsCollection.isTextField), isTrue, reason: 'details field reachable');
    tapLabel(bn.crowdsourceSubmitButton);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(CircularProgressIndicator), findsOneWidget, reason: 'semantic tap on Submit started the submission');
    h.dispose();
    await tester.pump(const Duration(seconds: 60));
    tester.takeException();
  });

  testWidgets('passerby overlay: the whole surface is one live-region tap target that says how to close it', (tester) async {
    final h = tester.ensureSemantics();
    await tester.pumpWidget(ProviderScope(
      overrides: _ov,
      child: MaterialApp(
        home: PasserbyHelperOverlay(message: 'আমাকে সাহায্য করুন', strings: bn, language: AppLanguage.bangla),
      ),
    ));
    await tester.pump();
    final n = nodes(tester).firstWhere((d) => d.label.contains('আমাকে সাহায্য করুন'));
    expect(n.flagsCollection.isLiveRegion, isTrue);
    expect(n.hasAction(SemanticsAction.tap), isTrue);
    expect(n.label, contains(bn.passerbyOverlayTapToClose));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 60));
    h.dispose();
  });

  testWidgets('passerby picker: messages, text field, mic (with hint) and Show are all named and operable', (tester) async {
    final h = tester.ensureSemantics();
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: _ov,
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (c) => TextButton(
              onPressed: () => PasserbyMessagePicker.show(c,
                  messages: const ['আমাকে রাস্তা পার করে দিন'], strings: bn, language: AppLanguage.bangla, autoListen: true),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    final all = nodes(tester);
    expect(all.any((d) => d.hasAction(SemanticsAction.tap) && d.label.contains('আমাকে রাস্তা পার করে দিন')), isTrue);
    expect(all.any((d) => d.flagsCollection.isTextField && d.label.contains(bn.passerbyWriteFieldSemantics)), isTrue);
    expect(all.any((d) => d.hasAction(SemanticsAction.tap) && d.hint == bn.passerbySpeakHint), isTrue);
    expect(all.any((d) => d.hasAction(SemanticsAction.tap) && d.label.contains(bn.passerbyPickerShowButton)), isTrue);
    expect(all.any((d) => d.flagsCollection.isHeader && d.label.contains(bn.passerbyPickerTitle)), isTrue);
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    while (nav.canPop()) {
      nav.pop();
      await tester.pump(const Duration(milliseconds: 400));
    }
    await tester.pump(SttService.narrationSettle + const Duration(seconds: 1));
    tester.takeException();
    h.dispose();
  });

  testWidgets('onboarding choice screen: title is a header, every option is a tappable named button, listening is a live region', (tester) async {
    final h = tester.ensureSemantics();
    tester.view.physicalSize = const Size(1080, 3200);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    final s = Onboarding.of(AppLanguage.bangla);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        ..._ov,
        profileServiceProvider.overrideWithValue(_Profiles()),
        onboardingControllerProvider.overrideWith(() => _Seeded(OnboardingState(
              step: OnboardingStep.visionQuestion, language: AppLanguage.bangla, profile: _bnProfile()))),
      ],
      child: const MaterialApp(home: VisionQuestionScreen()),
    ));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final all = nodes(tester);
    expect(all.where((d) => d.flagsCollection.isHeader).length, greaterThanOrEqualTo(1));
    for (final label in [s.visionNoneLabel, s.visionLowLabel, s.visionFullLabel]) {
      expect(all.any((d) => d.hasAction(SemanticsAction.tap) && d.label.contains(label)), isTrue, reason: label);
    }
    expect(all.any((d) => d.flagsCollection.isLiveRegion && d.label.contains(s.voiceListeningIndicator)), isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    tester.takeException();
    h.dispose();
  });

  testWidgets('settings: text-size slider exposes a value and increase/decrease; sections are headers', (tester) async {
    final h = tester.ensureSemantics();
    tester.view.physicalSize = const Size(1080, 6000);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    final p = _bnProfile();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        ..._ov,
        profileServiceProvider.overrideWithValue(_Profiles()),
        profileStreamProvider('u1').overrideWith((ref) => Stream.value(p)),
      ],
      child: MaterialApp(home: MySettingsScreen(profile: p)),
    ));
    await tester.pump();
    await tester.pump();
    final slider = nodes(tester).firstWhere((d) => d.flagsCollection.isSlider && d.hasAction(SemanticsAction.increase));
    expect(slider.value, isNotEmpty);
    expect(slider.hasAction(SemanticsAction.decrease), isTrue);
    expect(nodes(tester).where((d) => d.flagsCollection.isHeader).length, greaterThanOrEqualTo(6));
    h.dispose();
  });

  testWidgets('anxiety onboarding screen exposes a named Continue button', (tester) async {
    // Control for the bug file: the screen itself builds and exposes a primary action.
    final h = tester.ensureSemantics();
    tester.view.physicalSize = const Size(1080, 3200);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        ..._ov,
        profileServiceProvider.overrideWithValue(_Profiles()),
        onboardingControllerProvider.overrideWith(() => _Seeded(OnboardingState(
              step: OnboardingStep.cognitiveAnxietyQuestion, language: AppLanguage.bangla, profile: _bnProfile()))),
      ],
      child: const MaterialApp(home: CognitiveAnxietyScreen()),
    ));
    await tester.pump(const Duration(milliseconds: 200));
    final s = Onboarding.of(AppLanguage.bangla);
    expect(nodes(tester).any((d) => d.hasAction(SemanticsAction.tap) && d.label.contains(s.continueLabel)), isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    tester.takeException();
    h.dispose();
  });
}
