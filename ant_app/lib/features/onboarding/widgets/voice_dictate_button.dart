import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_language.dart';
import '../../../core/localization/onboarding_strings.dart';
import '../../../core/providers/ai_assistant_providers.dart';
import '../../../core/providers/tts_providers.dart';
import '../../../core/services/stt_service.dart';
import '../../../core/services/tts_service.dart';
import 'spoken_digits.dart';
import 'voice_confirm.dart';

/// A small push-to-talk mic button that dictates straight into [controller]
/// — tap, speak, and the recognized text replaces the field's contents.
/// Used on every free-text onboarding field (addresses, contact name/phone,
/// custom passerby messages) so voice input isn't only available on the
/// multiple-choice screens.
class VoiceDictateButton extends ConsumerStatefulWidget {
  const VoiceDictateButton({
    super.key,
    required this.controller,
    required this.language,
    this.onDictated,
    this.isPhoneNumber = false,
    this.fieldLabel,
  });

  final TextEditingController controller;
  final AppLanguage language;

  /// Called with the recognized text after it's been written into
  /// [controller] — for callers that need to react (e.g. re-running
  /// `setState` to enable a button, or summarizing the dictated text).
  final ValueChanged<String>? onDictated;

  /// Runs the dictated text through [spokenTextToDigits] instead of using
  /// it verbatim — set for the emergency-contact phone field specifically,
  /// where a reading like "double three double three double three" needs
  /// to become "334433", not the literal words "double three..." (confirmed
  /// live as a real bug: the words themselves were what ended up in the
  /// field). Never applied to other fields (names, addresses, messages),
  /// where "double" is just as likely to be an ordinary word.
  final bool isPhoneNumber;

  /// What to call this field when reading the dictated value back
  /// ("phone number", "home address"). When null, no read-back happens —
  /// reserved for fields where the value is immediately visible in context
  /// and re-reading it would just be noise. Prefer supplying it: a blind
  /// user has no other way to catch a misheard value before it is saved.
  final String? fieldLabel;

  @override
  ConsumerState<VoiceDictateButton> createState() => _VoiceDictateButtonState();
}

class _VoiceDictateButtonState extends ConsumerState<VoiceDictateButton> {
  bool _listening = false;

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
  }

  @override
  void dispose() {
    if (_listening) _stt.stop();
    super.dispose();
  }

  Future<void> _listen() async {
    final stt = _stt;
    if (!await stt.ensureAvailable()) return;
    setState(() => _listening = true);

    // Captured rather than committed inside the callback: with a read-back
    // configured, nothing is written to the field until the user has heard
    // it and said it is right.
    String? captured;
    await stt.listenOnce(
      language: widget.language,
      onResult: (text, isFinal) {
        if (!isFinal) return;
        final trimmed = text.trim();
        if (trimmed.isEmpty) return;
        final value = widget.isPhoneNumber ? spokenTextToDigits(trimmed) : trimmed;
        if (value.isEmpty) return;
        captured = value;
      },
    );
    if (mounted) setState(() => _listening = false);
    if (!mounted || captured == null) return;

    final label = widget.fieldLabel;
    if (label != null) {
      final confirmed = await VoiceConfirm.readBackAndConfirm(
        tts: _tts,
        stt: stt,
        language: widget.language,
        fieldLabel: label,
        value: captured!,
        isDigits: widget.isPhoneNumber,
        isCancelled: () => !mounted,
      );
      if (!mounted || confirmed == null) return;
      // Rejected — leave the field untouched and let them tap and try
      // again, rather than looping the mic on a button they pressed once.
      if (!confirmed) return;
    }

    _commit(captured!);
  }

  void _commit(String value) {
    widget.controller.text = value;
    widget.controller.selection = TextSelection.collapsed(offset: value.length);
    widget.onDictated?.call(value);
  }

  @override
  Widget build(BuildContext context) {
    final s = Onboarding.of(widget.language);
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label: s.voiceDictateSemantics,
      child: Material(
        color: _listening ? theme.colorScheme.primary : theme.colorScheme.primary.withValues(alpha: 0.85),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: _listening ? null : _listen,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Icon(_listening ? Icons.mic_rounded : Icons.mic_none_rounded, color: Colors.white, size: 20),
          ),
        ),
      ),
    );
  }
}
