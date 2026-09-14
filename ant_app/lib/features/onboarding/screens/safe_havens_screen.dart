import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_language.dart';
import '../../../core/localization/onboarding_strings.dart';
import '../../../core/providers/ai_assistant_providers.dart';
import '../../../core/providers/tts_providers.dart';
import '../../../core/services/dhaka_places.dart';
import '../../../core/services/stt_service.dart';
import '../../../core/services/tts_service.dart';
import '../providers/onboarding_providers.dart';
import '../widgets/onboarding_scaffold.dart';
import '../widgets/voice_confirm.dart';
import '../widgets/voice_dictate_button.dart';

class SafeHavensScreen extends ConsumerStatefulWidget {
  const SafeHavensScreen({super.key});

  @override
  ConsumerState<SafeHavensScreen> createState() => _SafeHavensScreenState();
}

class _SafeHavensScreenState extends ConsumerState<SafeHavensScreen> {
  final _homeController = TextEditingController();
  final _safePlaceController = TextEditingController();
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
    _homeController.dispose();
    _safePlaceController.dispose();
    super.dispose();
  }

  /// Previously this screen only ever listened when the user manually
  /// tapped one of its two `VoiceDictateButton`s — every other onboarding
  /// screen narrates and listens automatically, and this one not doing the
  /// same read as "the mic doesn't work here" (explicit user feedback).
  /// Home address loops until something is captured (it's required); the
  /// safe place is asked once and accepts a "skip" word since it's
  /// optional.
  Future<void> _introAndListen() async {
    if (_disposed || !ref.read(ttsEnabledProvider)) return;
    final language = ref.read(onboardingControllerProvider).profile!.language;
    final s = Onboarding.of(language);
    // Includes the screen overview (`safeHavensSpokenHint`: how many
    // fields there are and which is required) before the mic opens, not
    // just the title and subtitle — the per-field prompts below still
    // introduce each field as it comes up.
    await _tts.speak(
      [s.safeHavensTitle, s.safeHavensSubtitle, s.safeHavensSpokenHint].join('. '),
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

    while (_homeController.text.trim().isEmpty && !cancelled()) {
      await tts.speak(s.safeHavensHomePromptSpoken, language: language);
      if (cancelled()) return;
      if (!await stt.ensureAvailable()) {
        debugPrint('[SafeHavensVoice] stt.ensureAvailable() returned false — giving up silently');
        return;
      }
      String? home;
      await stt.listenOnce(
        language: language,
        // Every one of these prompts asks for a Dhaka place name, which is
        // exactly the vocabulary a general recognizer is weakest at.
        phraseHints: dhakaPlacePhrases,
        onResult: (text, isFinal) {
          if (isFinal && text.trim().isNotEmpty) home = text.trim();
        },
      );
      if (cancelled()) return;
      if (home == null) continue;
      // Addresses are long, and a recognizer that mangles a road number
      // produces something that still sounds like an address — the failure
      // is invisible without a read-back, and this one feeds both routing
      // and the "guide me home" safety path.
      final confirmed = await VoiceConfirm.readBackAndConfirm(
        tts: tts,
        stt: stt,
        language: language,
        fieldLabel: s.safeHavensHomeLabel,
        value: home!,
        isCancelled: cancelled,
      );
      if (cancelled() || confirmed == null) return;
      if (!confirmed) continue;
      setState(() => _homeController.text = home!);
    }
    if (cancelled()) return;

    await tts.speak(s.safeHavensPlacePromptSpoken, language: language);
    if (cancelled()) return;
    if (!await stt.ensureAvailable()) {
        debugPrint('[SafeHavensVoice] stt.ensureAvailable() returned false — giving up silently');
        return;
      }
    String? place;
    await stt.listenOnce(
      language: language,
      // Every one of these prompts asks for a Dhaka place name, which is
      // exactly the vocabulary a general recognizer is weakest at.
      phraseHints: dhakaPlacePhrases,
      onResult: (text, isFinal) {
        if (!isFinal) return;
        final trimmed = text.trim();
        if (trimmed.isEmpty) return;
        final lower = trimmed.toLowerCase();
        if (s.safeHavensSkipWords.any((w) => lower.contains(w.toLowerCase()) || trimmed.contains(w))) return;
        place = trimmed;
      },
    );
    if (cancelled()) return;
    if (place != null) {
      final confirmed = await VoiceConfirm.readBackAndConfirm(
        tts: tts,
        stt: stt,
        language: language,
        fieldLabel: s.safeHavensPlaceLabel,
        value: place!,
        isCancelled: cancelled,
      );
      if (cancelled() || confirmed == null) return;
      // Declining an *optional* field just leaves it empty rather than
      // looping — the user can add it later from My Settings or by voice,
      // and trapping them in a retry loop over something they did not have
      // to fill in is worse than skipping it.
      if (confirmed) setState(() => _safePlaceController.text = place!);
    }
    if (cancelled()) return;

    controller.setSafeHavens(
      homeAddress: _homeController.text.trim(),
      safePlaceAddress: _safePlaceController.text.trim().isEmpty ? null : _safePlaceController.text.trim(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.read(onboardingControllerProvider.notifier);
    final language = ref.watch(onboardingControllerProvider.select((s) => s.profile!.language));
    final s = Onboarding.of(language);

    return OnboardingScaffold(
      title: s.safeHavensTitle,
      subtitle: s.safeHavensSubtitle,
      onBack: controller.goBack,
      language: language,
      primaryActionLabel: s.continueLabel,
      primaryActionEnabled: _homeController.text.trim().isNotEmpty,
      onPrimaryAction: () => controller.setSafeHavens(
        homeAddress: _homeController.text.trim(),
        safePlaceAddress:
            _safePlaceController.text.trim().isEmpty ? null : _safePlaceController.text.trim(),
      ),
      spokenOptions: [s.safeHavensSpokenHint],
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
          Text(s.safeHavensHomeLabel, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Semantics(
                  textField: true,
                  label: s.safeHavensHomeLabel,
                  child: TextField(
                    controller: _homeController,
                    decoration: InputDecoration(hintText: s.safeHavensHomeHint),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              VoiceDictateButton(
                controller: _homeController,
                language: language,
                fieldLabel: s.safeHavensHomeLabel,
                onDictated: (_) => setState(() {}),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text(s.safeHavensPlaceLabel, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Semantics(
                  textField: true,
                  label: s.safeHavensPlaceLabel,
                  child: TextField(
                    controller: _safePlaceController,
                    decoration: InputDecoration(hintText: s.safeHavensPlaceHint),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              VoiceDictateButton(
                controller: _safePlaceController,
                language: language,
                fieldLabel: s.safeHavensPlaceLabel,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
