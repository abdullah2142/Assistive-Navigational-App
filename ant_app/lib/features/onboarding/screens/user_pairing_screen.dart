import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_language.dart';
import '../../../core/localization/onboarding_strings.dart';
import '../../../core/providers/ai_assistant_providers.dart';
import '../../../core/services/stt_service.dart';
import '../../../core/theme/app_colors.dart';
import '../providers/onboarding_providers.dart';
import '../widgets/onboarding_scaffold.dart';
import '../widgets/onboarding_voice.dart';

class UserPairingScreen extends ConsumerStatefulWidget {
  const UserPairingScreen({super.key});

  @override
  ConsumerState<UserPairingScreen> createState() => _UserPairingScreenState();
}

class _UserPairingScreenState extends ConsumerState<UserPairingScreen> {
  final _controller = TextEditingController();
  bool _listening = false;

  // See `LanguageSelectionScreen`'s identical field for why this is a
  // `late final` capture rather than `ref.read` inside `dispose()` — the
  // latter is unsafe and throws (confirmed by a real test failure) once
  // the widget is unmounting.
  late final SttService _stt = ref.read(sttServiceProvider);

  @override
  void initState() {
    super.initState();
    _stt;
  }

  @override
  void dispose() {
    if (_listening) _stt.stop();
    _controller.dispose();
    super.dispose();
  }

  /// STT already transcribes spoken digits as numerals in both English and
  /// Bangla speech, but Bangla numerals (০-৯) come through in Bangla script
  /// rather than ASCII — this normalizes either to a plain digit string
  /// before trimming to 6 characters.
  Future<void> _dictateCode(AppLanguage language) async {
    final stt = _stt;
    if (!await stt.ensureAvailable()) return;
    setState(() => _listening = true);
    await stt.listenOnce(
      language: language,
      onResult: (text, isFinal) {
        if (!isFinal) return;
        const bnDigits = '০১২৩৪৫৬৭৮৯';
        final digits = text.split('').map((c) {
          final bnIndex = bnDigits.indexOf(c);
          return bnIndex >= 0 ? '$bnIndex' : c;
        }).where((c) => RegExp(r'\d').hasMatch(c)).join();
        if (digits.isEmpty) return;
        final code = digits.length > 6 ? digits.substring(0, 6) : digits;
        _controller.text = code;
        _controller.selection = TextSelection.collapsed(offset: code.length);
      },
    );
    if (mounted) setState(() => _listening = false);
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
      voiceChoices: [
        OnboardingVoiceChoice(
          label: s.userPairingNoCaretakerButton,
          synonyms: s.userPairingNoCaretakerSynonyms,
          onSelect: controller.skipPairing,
        ),
      ],
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
