import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/onboarding_strings.dart';
import '../../../core/providers/tts_providers.dart';
import '../../../core/services/tts_service.dart';
import '../../../core/theme/app_colors.dart';
import '../providers/onboarding_providers.dart';

/// Shows the caretaker the six digits their user has to type in.
///
/// Narrates them, which it did not do at all before: the code was rendered
/// at 44pt and never spoken, so a caretaker who is blind, or simply not
/// looking at the screen, had no way to read it out to the person beside
/// them. Digits are spaced so the engine reads them one at a time rather
/// than as "four hundred and seventeen thousand".
class CaretakerPairingScreen extends ConsumerStatefulWidget {
  const CaretakerPairingScreen({super.key});

  @override
  ConsumerState<CaretakerPairingScreen> createState() => _CaretakerPairingScreenState();
}

class _CaretakerPairingScreenState extends ConsumerState<CaretakerPairingScreen> {
  // Captured eagerly so `dispose()` never reaches for `ref` while unmounting.
  late final TtsService _tts = ref.read(ttsServiceProvider);
  String? _announcedCode;

  @override
  void initState() {
    super.initState();
    _tts;
  }

  @override
  void dispose() {
    // A screen's narration belongs to that screen — the same rule the rest
    // of this flow follows.
    _tts.stop();
    super.dispose();
  }

  /// Spoken once per code. The screen rebuilds while it waits for the other
  /// device, and reading the digits out on every rebuild would talk over
  /// itself.
  void _announce(String code, Onboarding s) {
    if (_announcedCode == code) return;
    _announcedCode = code;
    if (!ref.read(ttsEnabledProvider)) return;
    final spaced = code.split('').join(' ');
    final language = ref.read(onboardingControllerProvider).profile?.language ??
        ref.read(onboardingControllerProvider).language;
    unawaited(_tts.speak('${s.caretakerPairingYourCode(spaced)}. ${s.caretakerPairingWaiting}',
        language: language));
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(onboardingControllerProvider);
    final code = state.pairingCode;
    final s = Onboarding.of(state.profile?.language ?? state.language);
    if (code != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _announce(code, s);
      });
    }

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Semantics(
                header: true,
                child: Text(
                  s.caretakerPairingTitle,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              const SizedBox(height: 32),
              Semantics(
                label: code == null ? s.caretakerPairingGenerating : s.caretakerPairingYourCode(code),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: AppColors.primary, width: 2),
                  ),
                  child: code == null
                      ? const CircularProgressIndicator()
                      : Text(
                          code.splitMapJoin('', onNonMatch: (c) => '$c '),
                          style: const TextStyle(
                            fontSize: 44,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 4,
                            color: AppColors.primary,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 32),
              const CircularProgressIndicator(strokeWidth: 2),
              const SizedBox(height: 16),
              Text(
                s.caretakerPairingWaiting,
                style: Theme.of(context).textTheme.bodyLarge,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
