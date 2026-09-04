import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import '../widgets/spoken_digits.dart';
import '../widgets/voice_confirm.dart';

class UserPairingScreen extends ConsumerStatefulWidget {
  const UserPairingScreen({super.key});

  @override
  ConsumerState<UserPairingScreen> createState() => _UserPairingScreenState();
}

class _UserPairingScreenState extends ConsumerState<UserPairingScreen> {
  final _controller = TextEditingController();
  bool _listening = false;
  bool _disposed = false;
  bool _voiceStarted = false;

  // See `LanguageSelectionScreen`'s identical field for why this is a
  // `late final` capture rather than `ref.read` inside `dispose()` — the
  // latter is unsafe and throws (confirmed by a real test failure) once
  // the widget is unmounting.
  late final SttService _stt = ref.read(sttServiceProvider);
  late final TtsService _tts = ref.read(ttsServiceProvider);

  @override
  void initState() {
    super.initState();
    _stt;
    _tts;
    WidgetsBinding.instance.addPostFrameCallback((_) => _introAndListen());
  }

  @override
  void dispose() {
    _disposed = true;
    _stt.stop();
    _tts.stop();
    _controller.dispose();
    super.dispose();
  }

  /// `spokenTextToDigits` handles plain digit words in either language and
  /// the "double"/"triple" convention ("double three" -> "33") — a real
  /// gap confirmed live without it: those words were landing in the field
  /// literally instead of being expanded.
  Future<void> _dictateCode(AppLanguage language) async {
    final stt = _stt;
    if (!await stt.ensureAvailable()) return;
    setState(() => _listening = true);
    await stt.listenOnce(
      language: language,
      onResult: (text, isFinal) {
        if (!isFinal) return;
        final digits = spokenTextToDigits(text);
        if (digits.isEmpty) return;
        final code = digits.length > 6 ? digits.substring(0, 6) : digits;
        _controller.text = code;
        _controller.selection = TextSelection.collapsed(offset: code.length);
      },
    );
    if (mounted) setState(() => _listening = false);
  }

  /// Previously the mic only ever activated on a manual tap — the code
  /// field had no automatic listening at all, unlike the rest of
  /// onboarding (explicit user feedback: every multi-action screen needs
  /// its own clearly-announced keywords and shouldn't require finding a
  /// button first). Recognizes either a spoken code or the skip phrase in
  /// the same listen; a partial code (fewer than 6 digits) is kept and the
  /// user is asked to continue it rather than starting over.
  Future<void> _introAndListen() async {
    if (_disposed || !ref.read(ttsEnabledProvider)) return;
    final state = ref.read(onboardingControllerProvider);
    final s = Onboarding.of(state.language);
    // Full narration before the mic opens — title, subtitle, and the
    // spoken hint about the skip button. `_voiceLoop` then states the two
    // valid spoken answers (`userPairingVoicePromptSpoken`) before each
    // listen.
    await _tts.speak(
      [s.userPairingTitle, s.userPairingSubtitle, s.userPairingSpokenHint].join('. '),
      language: state.language,
    );
    if (_disposed || !ref.read(ttsEnabledProvider) || _voiceStarted) return;
    _voiceStarted = true;
    await _voiceLoop(s, state.language);
  }

  Future<void> _voiceLoop(Onboarding s, AppLanguage language) async {
    final myGeneration = ref.read(onboardingControllerProvider).stepGeneration;
    bool cancelled() =>
        _disposed || ref.read(onboardingControllerProvider).stepGeneration != myGeneration;
    final stt = _stt;
    final tts = _tts;
    final controller = ref.read(onboardingControllerProvider.notifier);

    while (!cancelled()) {
      await tts.speak(
        _controller.text.isEmpty ? s.userPairingVoicePromptSpoken : s.userPairingCodePartialSpoken,
        language: language,
      );
      if (cancelled()) return;
      if (!await stt.ensureAvailable()) return;
      var wantsSkip = false;
      String? digits;
      await stt.listenOnce(
        language: language,
        onResult: (text, isFinal) {
          if (!isFinal || wantsSkip || digits != null) return;
          final trimmed = text.trim();
          if (trimmed.isEmpty) return;
          if (fuzzyVoiceMatch(trimmed, s.userPairingNoCaretakerButton) ||
              s.userPairingNoCaretakerSynonyms.any((w) => trimmed.toLowerCase().contains(w.toLowerCase()) || trimmed.contains(w))) {
            wantsSkip = true;
            return;
          }
          final d = spokenTextToDigits(trimmed);
          if (d.isNotEmpty) digits = d;
        },
      );
      if (cancelled()) return;
      if (wantsSkip) {
        controller.skipPairing();
        return;
      }
      if (digits != null) {
        // Appends onto whatever was already captured, same "don't erase a
        // stumbled, multi-part answer" principle used everywhere else —
        // reading out 6 digits in one breath is exactly the kind of thing
        // someone might pause partway through.
        final combined = (_controller.text + digits!);
        final code = combined.length > 6 ? combined.substring(0, 6) : combined;
        setState(() {
          _controller.text = code;
          _controller.selection = TextSelection.collapsed(offset: code.length);
        });
        if (code.length == 6) {
          // Read the code back digit by digit before redeeming it. A
          // pairing code is single-use and expires: submitting a misheard
          // one burns it and leaves the user waiting for a caretaker
          // response that will never come, with nothing on screen they can
          // read to work out why.
          final confirmed = await VoiceConfirm.readBackAndConfirm(
            tts: tts,
            stt: stt,
            language: language,
            fieldLabel: s.userPairingCodeFieldLabel,
            value: code,
            isDigits: true,
            isCancelled: cancelled,
          );
          if (cancelled() || confirmed == null) return;
          if (!confirmed) {
            // Clear and start the whole code again — isolating which digit
            // was wrong by voice is far more work for the user than saying
            // six digits over.
            setState(() {
              _controller.text = '';
              _controller.selection = const TextSelection.collapsed(offset: 0);
            });
            continue;
          }
          controller.submitPairingCode(code);
          return;
        }
        continue;
      }
      await tts.speak(s.voiceChoiceRetryHint, language: language);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(onboardingControllerProvider);
    final controller = ref.read(onboardingControllerProvider.notifier);
    final s = Onboarding.of(state.language);

    return OnboardingScaffold(
      title: s.userPairingTitle,
      subtitle: s.userPairingSubtitle,
      onBack: controller.goBack,
      isLoading: state.isLoading,
      language: state.language,
      primaryActionLabel: s.continueLabel,
      primaryActionEnabled: _controller.text.length == 6,
      onPrimaryAction: () => controller.submitPairingCode(_controller.text),
      spokenOptions: [s.userPairingSpokenHint],
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
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Semantics(
                  label: s.userPairingCodeFieldLabel,
                  textField: true,
                  child: TextField(
                    controller: _controller,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(6),
                    ],
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 32, letterSpacing: 8, fontWeight: FontWeight.bold),
                    decoration: const InputDecoration(hintText: '000000'),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Semantics(
                button: true,
                label: s.voiceDictateSemantics,
                child: Material(
                  color: _listening ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.primary.withValues(alpha: 0.85),
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: _listening ? null : () => _dictateCode(state.language),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Icon(_listening ? Icons.mic_rounded : Icons.mic_none_rounded, color: Colors.white, size: 20),
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (state.errorMessage != null) ...[
            const SizedBox(height: 16),
            Text(state.errorMessage!, style: const TextStyle(color: AppColors.danger)),
          ],
          const SizedBox(height: 32),
          Semantics(
            button: true,
            label: s.userPairingNoCaretakerSemantics,
            child: TextButton(
              onPressed: state.isLoading ? null : controller.skipPairing,
              child: Text(s.userPairingNoCaretakerButton),
            ),
          ),
          Text(
            s.userPairingNoCaretakerCaption,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
