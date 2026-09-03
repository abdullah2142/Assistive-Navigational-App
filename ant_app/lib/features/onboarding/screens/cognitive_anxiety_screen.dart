import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_language.dart';
import '../../../core/localization/onboarding_strings.dart';
import '../../../core/providers/ai_assistant_providers.dart';
import '../../../core/providers/tts_providers.dart';
import '../../../core/services/stt_service.dart';
import '../../../core/services/tts_service.dart';
import '../../../core/theme/app_colors.dart';
import '../providers/onboarding_providers.dart';
import '../widgets/onboarding_scaffold.dart';
import '../widgets/onboarding_voice.dart';

class CognitiveAnxietyScreen extends ConsumerStatefulWidget {
  const CognitiveAnxietyScreen({super.key});

  @override
  ConsumerState<CognitiveAnxietyScreen> createState() => _CognitiveAnxietyScreenState();
}

class _CognitiveAnxietyScreenState extends ConsumerState<CognitiveAnxietyScreen> {
  bool _crowdedAnxious = false;
  bool _complexHard = false;
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
    await _tts.speak('${s.cognitiveTitle}. ${s.cognitiveSubtitle}', language: language);
    if (_disposed || !ref.read(ttsEnabledProvider)) return;
    await _startVoiceFlow(s, language);
  }

  /// Two independent yes/no questions in sequence, each using
  /// `classifyTraitYesNo` (see its doc comment — plain word-overlap
  /// matching is the wrong shape for a question with two directly
  /// opposite answers) rather than the generic choice mechanism. Then
  /// auto-continues once both are answered — there's no way for a screen
  /// reader-less blind user to then go find and tap the Continue button on
  /// their own.
  Future<void> _startVoiceFlow(Onboarding s, AppLanguage language) async {
    if (_voiceStarted) return;
    _voiceStarted = true;
    final myGeneration = ref.read(onboardingControllerProvider).stepGeneration;
    bool cancelled() =>
        _disposed || ref.read(onboardingControllerProvider).stepGeneration != myGeneration;
    final stt = _stt;
    final tts = _tts;

    final crowded = await _askYesNo(
      stt: stt,
      tts: tts,
      language: language,
      question: s.cognitiveCrowdedQuestion,
      presentPhrases: s.cognitiveCrowdedPresentPhrases,
      absentPhrases: s.cognitiveCrowdedAbsentPhrases,
      retryHint: s.voiceChoiceRetryHint,
      isCancelled: cancelled,
    );
    if (cancelled() || crowded == null) return;
    setState(() => _crowdedAnxious = crowded);

    final complex = await _askYesNo(
      stt: stt,
      tts: tts,
      language: language,
      question: s.cognitiveComplexQuestion,
      presentPhrases: s.cognitiveComplexPresentPhrases,
      absentPhrases: s.cognitiveComplexAbsentPhrases,
      retryHint: s.voiceChoiceRetryHint,
      isCancelled: cancelled,
    );
    if (cancelled() || complex == null) return;
    setState(() => _complexHard = complex);

    ref.read(onboardingControllerProvider.notifier).setCognitiveAnxiety(
          crowdedPlacesAnxious: _crowdedAnxious,
          complexInstructionsHard: _complexHard,
        );
  }

  /// Speaks [question], then listens until `classifyTraitYesNo` returns a
  /// clear answer (re-prompting on anything ambiguous) or the screen is
  /// left. Returns `null` only when cancelled.
  Future<bool?> _askYesNo({
    required SttService stt,
    required TtsService tts,
    required AppLanguage language,
    required String question,
    required List<String> presentPhrases,
    required List<String> absentPhrases,
    required String retryHint,
    required bool Function() isCancelled,
  }) async {
    await tts.speak(question, language: language);
    while (!isCancelled()) {
      if (!await stt.ensureAvailable()) return null;
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
          answer = classifyTraitYesNo(trimmed, presentPhrases: presentPhrases, absentPhrases: absentPhrases);
        },
      );
      if (isCancelled()) return null;
      if (wantsHelp) {
        await tts.speak(question, language: language);
        continue;
      }
      if (answer != null) return answer;
      await tts.speak(retryHint, language: language);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.read(onboardingControllerProvider.notifier);
    final language = ref.watch(onboardingControllerProvider.select((s) => s.profile!.language));
    final s = Onboarding.of(language);

    return OnboardingScaffold(
      title: s.cognitiveTitle,
      subtitle: s.cognitiveSubtitle,
      onBack: controller.goBack,
      language: language,
      primaryActionLabel: s.continueLabel,
      onPrimaryAction: () => controller.setCognitiveAnxiety(
        crowdedPlacesAnxious: _crowdedAnxious,
        complexInstructionsHard: _complexHard,
      ),
      spokenOptions: [s.cognitiveSpokenHint],
      autoSpeak: false,
      child: Column(
        children: [
          _YesNoQuestion(
            question: s.cognitiveCrowdedQuestion,
            value: _crowdedAnxious,
            onChanged: (v) => setState(() => _crowdedAnxious = v),
          ),
          const SizedBox(height: 20),
          _YesNoQuestion(
            question: s.cognitiveComplexQuestion,
            value: _complexHard,
            onChanged: (v) => setState(() => _complexHard = v),
          ),
        ],
      ),
    );
  }
}

class _YesNoQuestion extends StatelessWidget {
  const _YesNoQuestion({required this.question, required this.value, required this.onChanged});

  final String question;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      toggled: value,
      label: question,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.divider),
        ),
        child: Row(
          children: [
            Expanded(child: Text(question, style: Theme.of(context).textTheme.titleMedium)),
            Switch(value: value, onChanged: onChanged),
          ],
        ),
      ),
    );
  }
}
