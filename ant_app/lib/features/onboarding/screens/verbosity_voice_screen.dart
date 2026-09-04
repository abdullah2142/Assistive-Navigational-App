import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/onboarding_strings.dart';
import '../../../core/providers/ai_assistant_providers.dart';
import '../../../core/providers/tts_providers.dart';
import '../../../core/services/stt_service.dart';
import '../../../core/services/tts_service.dart';
import '../models/disability_profile_enums.dart';
import '../providers/onboarding_providers.dart';
import '../widgets/big_choice_card.dart';
import '../widgets/onboarding_scaffold.dart';
import '../widgets/onboarding_voice.dart';

class VerbosityVoiceScreen extends ConsumerStatefulWidget {
  const VerbosityVoiceScreen({super.key});

  @override
  ConsumerState<VerbosityVoiceScreen> createState() => _VerbosityVoiceScreenState();
}

class _VerbosityVoiceScreenState extends ConsumerState<VerbosityVoiceScreen> {
  VerbosityLevel? _verbosity;
  String? _voiceId;
  bool _disposed = false;
  bool _voiceStarted = false;

  // See `LanguageSelectionScreen`'s identical fields for why this is a
  // `late final` capture rather than `ref.read` inside `dispose()` — the
  // latter is unsafe and throws (confirmed by a real test failure) once
  // the widget is unmounting.
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

  Future<void> _introAndListen() async {
    if (_disposed || !ref.read(ttsEnabledProvider)) return;
    final language = ref.read(onboardingControllerProvider).profile!.language;
    final s = Onboarding.of(language);
    await _tts.speak('${s.verbosityTitle}. ${s.verbositySpokenHint}', language: language);
    if (_disposed || !ref.read(ttsEnabledProvider) || _voiceStarted) return;
    _voiceStarted = true;
    final myGeneration = ref.read(onboardingControllerProvider).stepGeneration;
    bool cancelled() =>
        _disposed || ref.read(onboardingControllerProvider).stepGeneration != myGeneration;
    final stt = _stt;
    final tts = _tts;
    await listenForVoiceChoice(
      stt: stt,
      tts: tts,
      language: language,
      choices: [
        OnboardingVoiceChoice(
          label: s.verbosityMinimalistLabel,
          synonyms: s.verbosityMinimalistSynonyms,
          onSelect: () => setState(() => _verbosity = VerbosityLevel.minimalist),
        ),
        OnboardingVoiceChoice(
          label: s.verbosityDescriptiveLabel,
          synonyms: s.verbosityDescriptiveSynonyms,
          onSelect: () => setState(() => _verbosity = VerbosityLevel.descriptive),
        ),
      ],
      retryHint: s.voiceChoiceRetryHint,
      isCancelled: cancelled,
    );
    if (cancelled()) return;
    await tts.speak(s.verbositySpokenVoiceHint, language: language);
    if (cancelled()) return;
    await listenForVoiceChoice(
      stt: stt,
      tts: tts,
      language: language,
      choices: [
        OnboardingVoiceChoice(
          label: s.verbosityFemaleVoiceLabel,
          synonyms: s.verbosityFemaleVoiceSynonyms,
          onSelect: () => setState(() => _voiceId = 'bn-BD-female-1'),
        ),
        OnboardingVoiceChoice(
          label: s.verbosityMaleVoiceLabel,
          synonyms: s.verbosityMaleVoiceSynonyms,
          onSelect: () => setState(() => _voiceId = 'bn-BD-male-1'),
        ),
      ],
      retryHint: s.voiceChoiceRetryHint,
      isCancelled: cancelled,
    );
    if (cancelled() || _verbosity == null || _voiceId == null) return;
    ref.read(onboardingControllerProvider.notifier).setVerbosityAndVoice(verbosity: _verbosity!, voiceId: _voiceId!);
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.read(onboardingControllerProvider.notifier);
    final language = ref.watch(onboardingControllerProvider.select((s) => s.profile!.language));
    final s = Onboarding.of(language);
    final canContinue = _verbosity != null && _voiceId != null;
    final voiceOptions = [
      ('bn-BD-female-1', s.verbosityFemaleVoiceLabel),
      ('bn-BD-male-1', s.verbosityMaleVoiceLabel),
    ];

    return OnboardingScaffold(
      title: s.verbosityTitle,
      onBack: controller.goBack,
      language: language,
      primaryActionLabel: s.continueLabel,
      primaryActionEnabled: canContinue,
      onPrimaryAction: canContinue
          ? () => controller.setVerbosityAndVoice(verbosity: _verbosity!, voiceId: _voiceId!)
          : null,
      spokenOptions: [s.verbositySpokenHint, s.verbositySpokenVoiceHint],
      autoSpeak: false,
      // Re-arms this screen's own voice loop when a step fails and we stay
      // put — `_stopCurrentScreenVoice` cancels it up front on every
      // navigating action. See `OnboardingState.voiceRearmToken`.
      onVoiceRestart: () {
        _voiceStarted = false;
        _introAndListen();
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s.verbosityChattinessLabel, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          BigChoiceCard(
            label: s.verbosityMinimalistLabel,
            description: s.verbosityMinimalistDescription,
            selected: _verbosity == VerbosityLevel.minimalist,
            onTap: () => setState(() => _verbosity = VerbosityLevel.minimalist),
          ),
          BigChoiceCard(
            label: s.verbosityDescriptiveLabel,
            description: s.verbosityDescriptiveDescription,
            selected: _verbosity == VerbosityLevel.descriptive,
            onTap: () => setState(() => _verbosity = VerbosityLevel.descriptive),
          ),
          const SizedBox(height: 16),
          Text(s.verbosityVoiceLabel, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final (id, label) in voiceOptions)
            BigChoiceCard(
              label: label,
              selected: _voiceId == id,
              onTap: () => setState(() => _voiceId = id),
            ),
        ],
      ),
    );
  }
}
