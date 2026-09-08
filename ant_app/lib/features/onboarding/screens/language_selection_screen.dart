import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_language.dart';
import '../../../core/providers/ai_assistant_providers.dart';
import '../../../core/providers/tts_providers.dart';
import '../../../core/services/stt_service.dart';
import '../../../core/services/tts_service.dart';
import '../providers/onboarding_providers.dart';
import '../widgets/big_choice_card.dart';
import '../widgets/onboarding_scaffold.dart';
import '../widgets/onboarding_voice.dart';

/// The very first screen, before role selection — a Bangla-only reader
/// needs to understand *that* screen too. Deliberately bilingual on its own
/// terms: both labels are native-script regardless of any chosen language
/// (there isn't one yet), and voice guidance announces in both languages in
/// turn rather than guessing one and getting it wrong for half the
/// audience.
class LanguageSelectionScreen extends ConsumerStatefulWidget {
  const LanguageSelectionScreen({super.key});

  @override
  ConsumerState<LanguageSelectionScreen> createState() => _LanguageSelectionScreenState();
}

class _LanguageSelectionScreenState extends ConsumerState<LanguageSelectionScreen> {
  bool _disposed = false;

  // Captured once, here, rather than `ref.read` inside `dispose()` — `ref`
  // is unsafe to use once a widget is unmounting (confirmed by a real test
  // failure: `ConsumerStatefulElement._assertNotDisposed` throws "Bad
  // state: Using 'ref' when a widget is about to or has been unmounted is
  // unsafe" from exactly this call site). Forced eager in `initState` so
  // `dispose()` always has a valid reference even if this screen is left
  // before `_announce` itself ever runs.
  late final TtsService _tts = ref.read(ttsServiceProvider);
  late final SttService _stt = ref.read(sttServiceProvider);

  @override
  void initState() {
    super.initState();
    _tts;
    _stt;
    WidgetsBinding.instance.addPostFrameCallback((_) => _announce());
  }

  @override
  void dispose() {
    _disposed = true;
    _stt.stop();
    _tts.stop();
    super.dispose();
  }

  Future<void> _announce() async {
    if (!ref.read(ttsEnabledProvider)) return;
    await _tts.speak('Choose your language: English, or Bangla.', language: AppLanguage.english);
    if (!mounted) return;
    await _tts.speak('আপনার ভাষা বেছে নিন: ইংরেজি, অথবা বাংলা।', language: AppLanguage.bangla);
    if (_disposed || !ref.read(ttsEnabledProvider)) return;
    final myGeneration = ref.read(onboardingControllerProvider).stepGeneration;
    final controller = ref.read(onboardingControllerProvider.notifier);
    // No language is chosen yet, so this can't rely on one recognizer
    // locale alone — Bangla's is used since (per the phonetic-matching
    // precedent in `PasserbyHelperOverlay`) its online recognition still
    // fairly reliably catches a loanword like "English" spoken plainly,
    // while the reverse (an English recognizer hearing Bangla) does not.
    // Every synonym a user might actually say is listed for each choice.
    await listenForVoiceChoice(
      stt: _stt,
      tts: _tts,
      language: AppLanguage.bangla,
      choices: [
        OnboardingVoiceChoice(label: 'english', onSelect: () => controller.setLanguage(AppLanguage.english)),
        OnboardingVoiceChoice(label: 'ইংরেজি', onSelect: () => controller.setLanguage(AppLanguage.english)),
        OnboardingVoiceChoice(label: 'ইংলিশ', onSelect: () => controller.setLanguage(AppLanguage.english)),
        OnboardingVoiceChoice(label: 'bangla', onSelect: () => controller.setLanguage(AppLanguage.bangla)),
        OnboardingVoiceChoice(label: 'বাংলা', onSelect: () => controller.setLanguage(AppLanguage.bangla)),
      ],
      retryHint: 'দুঃখিত, বুঝতে পারিনি। ইংরেজি অথবা বাংলা বলুন। / Sorry, please say English or Bangla.',
      // Bilingual, like the retry hint above: the user has not chosen a
      // language yet, so either half may be the one they understand.
      unavailableMessage:
          'মাইক্রোফোন ব্যবহার করতে পারছি না। স্ক্রিনে চাপ দিন। / I cannot use the microphone. Please tap the screen.',
      isCancelled: () =>
          _disposed || ref.read(onboardingControllerProvider).stepGeneration != myGeneration,
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.read(onboardingControllerProvider.notifier);

    return OnboardingScaffold(
      title: 'Choose your language / ভাষা বাছাই করুন',
      autoSpeak: false,
      child: Column(
        children: [
          BigChoiceCard(
            label: 'English',
            onTap: () => controller.setLanguage(AppLanguage.english),
          ),
          BigChoiceCard(
            label: 'বাংলা',
            onTap: () => controller.setLanguage(AppLanguage.bangla),
          ),
        ],
      ),
    );
  }
}
