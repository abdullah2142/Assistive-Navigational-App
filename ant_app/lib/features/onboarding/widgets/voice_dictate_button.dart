import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_language.dart';
import '../../../core/localization/onboarding_strings.dart';
import '../../../core/providers/ai_assistant_providers.dart';
import '../../../core/services/stt_service.dart';
import 'spoken_digits.dart';

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

  @override
  void initState() {
    super.initState();
    _stt;
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
    await stt.listenOnce(
      language: widget.language,
      onResult: (text, isFinal) {
        if (!isFinal) return;
        final trimmed = text.trim();
        if (trimmed.isEmpty) return;
        final value = widget.isPhoneNumber ? spokenTextToDigits(trimmed) : trimmed;
        if (value.isEmpty) return;
        widget.controller.text = value;
        widget.controller.selection = TextSelection.collapsed(offset: value.length);
        widget.onDictated?.call(value);
      },
    );
    if (mounted) setState(() => _listening = false);
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
