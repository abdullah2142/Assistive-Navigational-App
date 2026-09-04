import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_language.dart';
import '../../../core/localization/onboarding_strings.dart';
import '../../../core/providers/ai_assistant_providers.dart';
import '../../../core/providers/tts_providers.dart';
import '../../../core/services/stt_service.dart';
import '../../../core/services/tts_service.dart';
import '../providers/onboarding_providers.dart';
import '../widgets/big_choice_card.dart';
import '../widgets/onboarding_scaffold.dart';
import '../widgets/onboarding_voice.dart';

class DeafHearingScreen extends ConsumerStatefulWidget {
  const DeafHearingScreen({super.key});

  @override
  ConsumerState<DeafHearingScreen> createState() => _DeafHearingScreenState();
}

class _DeafHearingScreenState extends ConsumerState<DeafHearingScreen> {
  bool _disposed = false;
  bool _voiceStarted = false;

  // See `LanguageSelectionScreen`'s identical fields for why this is a
  // `late final` capture rather than `ref.read` inside `dispose()`.
  late final TtsService _tts = ref.read(ttsServiceProvider);
  late final SttService _stt = ref.read(sttServiceProvider);

  @override
  void initState() {
    super.initState();
    _tts;
    _stt;
    WidgetsBinding.instance.addPostFrameCallback((_) => _introAndListen());
  }

  @override
  void dispose() {
    _disposed = true;
    _stt.stop();
    _tts.stop();
    super.dispose();
  }

  /// The full spoken option list. Shared by [build]'s `spokenOptions` and
  /// [_introAndListen] so the two can't drift apart — they did: the intro
  /// spoke only the title and subtitle, leaving a blind user listening to
  /// an open mic with no idea what a valid answer sounded like. Options are
  /// always narrated *before* the mic opens (see `OnboardingScaffold`'s
  /// `_speakThenListen` for the same rule and why it was reverted back to
  /// this); "help" mid-loop still repeats them.
  List<String> _spokenOptions(Onboarding s) => [
        '${s.spokenOptionLabel(1)}: ${s.deafYesLabel}. ${s.deafYesDescription}',
        '${s.spokenOptionLabel(2)}: ${s.deafNoLabel}. ${s.deafNoDescription}',
      ];

  /// Uses `classifyTraitYesNo` instead of the generic choice-matching
  /// mechanism — this question's two answers are direct opposites, which
  /// word-overlap fuzzy matching handles badly (see that function's doc
  /// comment for the exact live bug this replaces: "I can hear my
  /// assistant" was able to match the *deaf* answer purely by sharing the
  /// word "hear" with its "can't hear" synonym).
  Future<void> _introAndListen() async {
    if (_disposed || !ref.read(ttsEnabledProvider)) return;
    final language = ref.read(onboardingControllerProvider).profile!.language;
    final s = Onboarding.of(language);
    await _tts.speak(
      [s.deafTitle, s.deafSubtitle, ..._spokenOptions(s)].join('. '),
      language: language,
    );
    if (_disposed || !ref.read(ttsEnabledProvider) || _voiceStarted) return;
    _voiceStarted = true;
    await _voiceLoop(s, language);
  }

  Future<void> _voiceLoop(Onboarding s, AppLanguage language) async {
    final myGeneration = ref.read(onboardingControllerProvider).stepGeneration;
    bool cancelled() =>
        _disposed || ref.read(onboardingControllerProvider).stepGeneration != myGeneration;
    final stt = _stt;
    final tts = _tts;
    final controller = ref.read(onboardingControllerProvider.notifier);

    while (!cancelled()) {
      if (!await stt.ensureAvailable()) return;
      var wantsHelp = false;
      bool? answer;
      await stt.listenOnce(
        language: language,
        onResult: (text, isFinal) {
          if (!isFinal || wantsHelp || answer != null) return;
          final trimmed = text.trim();
          if (trimmed.isEmpty) return;
          if (isHelpRequest(trimmed)) {
            wantsHelp = true;
            return;
          }
          answer = classifyTraitYesNo(
            trimmed,
            presentPhrases: s.deafPresentPhrases,
            absentPhrases: s.deafAbsentPhrases,
          );
        },
      );
      if (cancelled()) return;
      if (wantsHelp) {
        await tts.speak(_spokenOptions(s).join('. '), language: language);
        continue;
      }
      if (answer != null) {
        controller.setDeafHearing(answer!);
        return;
      }
      await tts.speak(s.voiceChoiceRetryHint, language: language);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.read(onboardingControllerProvider.notifier);
    final language = ref.watch(onboardingControllerProvider.select((s) => s.profile!.language));
    final s = Onboarding.of(language);

    return OnboardingScaffold(
      title: s.deafTitle,
      subtitle: s.deafSubtitle,
      onBack: controller.goBack,
      language: language,
      spokenOptions: _spokenOptions(s),
      autoSpeak: false,
      // Re-arms this screen's own voice loop when a step fails and we stay
      // put — `_stopCurrentScreenVoice` cancels it up front on every
      // navigating action. See `OnboardingState.voiceRearmToken`.
      onVoiceRestart: () {
        _voiceStarted = false;
        _introAndListen();
      },
      child: Column(
        children: [
          BigChoiceCard(
            label: s.deafYesLabel,
            description: s.deafYesDescription,
            icon: Icons.hearing_disabled_rounded,
            onTap: () => controller.setDeafHearing(true),
          ),
          BigChoiceCard(
            label: s.deafNoLabel,
            description: s.deafNoDescription,
            icon: Icons.hearing_rounded,
            onTap: () => controller.setDeafHearing(false),
          ),
        ],
      ),
    );
  }
}
