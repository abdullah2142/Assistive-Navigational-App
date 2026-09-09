import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_language.dart';
import '../../../core/localization/dashboard_strings.dart';
import '../../../core/providers/ai_assistant_providers.dart';
import '../../../core/providers/tts_providers.dart';
import '../../../core/services/stt_service.dart';
import '../../../core/services/wake_word_service.dart';
import '../../../core/services/voice_cancel_window.dart';
import '../../../core/services/tts_service.dart';
import 'passerby_helper_overlay.dart';

/// Shown before the Passerby Helper overlay itself: lets the user pick one
/// of their onboarding-selected messages, or compose a new one on the spot,
/// instead of the overlay jumping straight to a single hardcoded message.
class PasserbyMessagePicker {
  PasserbyMessagePicker._();

  static Future<void> show(
    BuildContext context, {
    required List<String> messages,
    required Dashboard strings,
    required AppLanguage language,
    required bool autoListen,
  }) async {
    final chosen = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _PickerSheet(
        messages: messages,
        strings: strings,
        language: language,
        autoListen: autoListen,
      ),
    );
    if (chosen == null || chosen.trim().isEmpty) return;
    if (!context.mounted) return;
    await PasserbyHelperOverlay.show(context, chosen.trim(), strings, language);
  }
}

class _PickerSheet extends ConsumerStatefulWidget {
  const _PickerSheet({
    required this.messages,
    required this.strings,
    required this.language,
    required this.autoListen,
  });

  final List<String> messages;
  final Dashboard strings;
  final AppLanguage language;
  final bool autoListen;

  @override
  ConsumerState<_PickerSheet> createState() => _PickerSheetState();
}

class _PickerSheetState extends ConsumerState<_PickerSheet> {
  bool _listening = false;
  // What's been dictated so far, across possibly several separate
  // utterances with pauses in between — same reasoning as the Crowdsource
  // Reporting Hub's identical field: a pause to think isn't "done talking",
  // and a single narrow listening window isn't enough for someone who may
  // stumble.
  String _committed = '';

  /// Set when this sheet is popping in order to show the message, rather
  /// than being abandoned. See [dispose].
  bool _handedOff = false;

  static const _submitPhrasesEn = ['submit', 'send it', 'send this', 'show this', 'show it'];
  static const _submitPhrasesBn = ['পাঠাও', 'পাঠান', 'সাবমিট', 'দেখাও'];
  static const _submitRootsEn = ['submit', 'send', 'show'];
  static const _submitRootsBn = ['পাঠা', 'দেখা', 'সাবমিট'];

  // Owned here, not passed in from `PasserbyMessagePicker.show()` — that
  // used to be the case, and it was a real, confirmed-live bug: the parent
  // disposed the controller the instant its `await showModalBottomSheet`
  // resolved, which happens as soon as the pop is *initiated*, not once
  // this sheet's own closing animation (and therefore this State's actual
  // unmount) finishes. That gap meant `mounted` could still read `true`
  // here while the controller was already disposed out from under it —
  // "TextEditingController was used after being disposed," thrown from a
  // still-pending `onResult` callback. Owning it locally ties its
  // lifecycle to this State's own `dispose()`, which *is* correctly
  // synchronized with `mounted`.
  final _composeController = TextEditingController();

  // Captured once, here, rather than `ref.read` inside `dispose()` — `ref`
  // is unsafe to use once a widget is unmounting (a real crash this caused
  // live elsewhere: "Bad state: Using 'ref' when a widget is about to or
  // has been unmounted is unsafe"). Also lets this sheet stop an
  // in-progress listening session if it's dismissed mid-recognition.
  late final SttService _stt = ref.read(sttServiceProvider);
  late final WakeWordService _wakeWord = ref.read(wakeWordServiceProvider);
  late final TtsService _tts = ref.read(ttsServiceProvider);

  List<String> get messages => widget.messages;
  TextEditingController get composeController => _composeController;
  Dashboard get strings => widget.strings;

  @override
  void initState() {
    super.initState();
    _wakeWord;
    // Held for the whole sheet — see CrowdsourceReportingHub for the failure
    // this prevents. The picker narrates between utterances too, so it has
    // the same gap for the wake-word recorder to reclaim the microphone in.
    _wakeWord.suspend();
    // Forces the lazy `late final _stt` initializer to run now, while `ref`
    // is still safe to use — otherwise, if the mic button here is never
    // tapped, `dispose()` ends up being the *first* access, which is
    // exactly the unsafe-`ref` crash this field was introduced to avoid.
    _stt;
    // Auto-listen: for a user whose profile signals they'd benefit most
    // (not fully sighted, or finds multi-step instructions hard —
    // `UserProfile.voiceAutoListen`), start listening the instant this
    // sheet opens instead of making them find and tap a mic button first.
    if (widget.autoListen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _autoListenLoop();
      });
    }
  }

  @override
  void dispose() {
    // Same rule as everywhere else: a screen's narration stops when the
    // screen does. The exception is the hand-off — when this sheet pops in
    // order to *show* the message, the overlay it is handing to has already
    // started its own announcement, and Flutter runs this `dispose` after
    // that push. Stopping unconditionally would clip the first words off the
    // screen the user actually asked for.
    if (!_handedOff) _tts.stop();
    _wakeWord.resume();
    _stt.stop();
    _composeController.dispose();
    super.dispose();
  }

  Future<bool> _speak(String text) async {
    if (!ref.read(ttsEnabledProvider)) return false;
    await _tts.speak(text, language: widget.language);
    return true;
  }

  /// The manual mic button: a single deliberate tap-to-start/tap-to-stop
  /// dictation pass, accumulating onto whatever was already dictated (see
  /// `_committed` — a second tap to add more shouldn't erase the first
  /// pass, same reasoning as the Crowdsource Reporting Hub). Recognizes a
  /// trailing submit phrase as a convenience but doesn't require one —
  /// tapping the mic again, or the Show This button, both still work.
  Future<void> _toggleListening() async {
    if (_listening) {
      await _stt.stop();
      setState(() => _listening = false);
      return;
    }
    if (!await _stt.ensureAvailable()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(strings.chatVoiceUnavailable)));
      return;
    }
    setState(() => _listening = true);
    await _stt.listenOnce(
      language: widget.language,
      // A touch more forgiving than the app's general 3s default — composing
      // a message here tends to have slightly longer natural pauses (word
      // choice, phrasing) than a short command, and 3s alone was still
      // reported as cutting off before the sentence was finished.
      pauseFor: const Duration(seconds: 4),
      onResult: (text, isFinal) {
        // `mounted` must gate the whole callback, not just the final
        // `setState` — a pending listen session can still deliver a result
        // after this sheet is popped (tapping a suggested message, back
        // gesture, tapping the scrim) while it's still in progress.
        if (!mounted) return;
        if (!isFinal) {
          _updateComposeLive(text);
          return;
        }
        setState(() => _listening = false);
        final extracted = _extractSubmitIntent(text);
        if (extracted == null) {
          _commitToCompose(text);
          return;
        }
        if (extracted.isNotEmpty) _commitToCompose(extracted);
        if (composeController.text.trim().isNotEmpty) _submitCompose(context, fromVoice: true);
      },
    );
    if (mounted) setState(() => _listening = false);
  }

  /// Auto-listen's own loop, separate from the manual button: keeps
  /// re-listening indefinitely, accumulating dictation across as many
  /// utterances as needed, and — unlike the old one-shot version that
  /// auto-submitted the instant *any* single utterance finished — only
  /// submits once a "show it"/"দেখাও" (or similar) voice command is
  /// actually heard. Confirmed live as a real problem otherwise: a user
  /// who paused mid-thought had their first, incomplete fragment
  /// auto-submitted before they'd finished composing. Speaks a short
  /// re-prompt between each committed utterance, both as the "still
  /// listening" cue asked for directly and to give each "was that a submit
  /// command?" decision its own short, clean listening window rather than
  /// asking the recognizer to find it buried in one long run-on utterance.
  Future<void> _autoListenLoop() async {
    // Narrate first, listen second — never both at once.
    //
    // The first pass used to skip straight to opening the microphone, which
    // was wrong twice over. The user heard a listening buzz with no idea
    // what to say into it; and the chat's own "Showing your screen now."
    // was still playing, so the recorder came up *underneath* it. Caught on
    // device 10 September:
    //
    //   02:19:13.467  [CloudStt] continuous listening started
    //   02:19:13.545  audioplayers requestAudioFocus req=3
    //   02:19:13.564  onAudioFocusChange(-3) -> record
    //
    // `record` treats a duck request as a full focus loss, and its default
    // interruption mode pauses without resuming — so the session that just
    // opened was already dead, and the message spoken into it never arrived.
    // That empty message is what made the "show it" prompt loop forever.
    //
    // `TtsService` serializes utterances, so awaiting this also waits out
    // whatever the chat is still saying.
    var first = true;
    // Set when the previous turn already said something more specific than
    // the standing prompt, so the user is not given two instructions for one
    // turn.
    var alreadyPrompted = false;
    while (mounted && widget.autoListen) {
      if (!alreadyPrompted) {
        await _speak(first ? strings.passerbyPickerIntroSpoken : strings.passerbyPickerContinueOrShowSpoken);
      }
      alreadyPrompted = false;
      first = false;
      if (!mounted) return;
      if (!await _stt.ensureAvailable()) return;
      setState(() => _listening = true);
      var submitted = false;
      var heardSubmitWithNothing = false;
      await _stt.listenOnce(
        language: widget.language,
        pauseFor: const Duration(seconds: 4),
        onResult: (text, isFinal) {
          if (!mounted) return;
          if (!isFinal) {
            _updateComposeLive(text);
            return;
          }
          final extracted = _extractSubmitIntent(text);
          if (extracted == null) {
            _commitToCompose(text);
            return;
          }
          if (extracted.isNotEmpty) _commitToCompose(extracted);
          // The live-partial preview above wrote the in-progress utterance
          // into the field, and that utterance turned out to be the submit
          // command itself. Nothing put the field back, so "show it" was
          // shown to the passerby as part of the message. `_committed` is
          // the only authoritative text — the preview is just a preview.
          _resetComposeToCommitted();
          if (composeController.text.trim().isNotEmpty) {
            submitted = true;
            _submitCompose(context, fromVoice: true);
          } else {
            // "Show it" with nothing to show. The loop used to fall through
            // here and replay the identical prompt, forever — reported from
            // the device as exactly that. Say what is actually missing.
            heardSubmitWithNothing = true;
          }
        },
      );
      if (mounted) setState(() => _listening = false);
      if (submitted || !mounted) return;
      if (heardSubmitWithNothing) {
        await _speak(strings.passerbyPickerNothingToShowSpoken);
        alreadyPrompted = true;
      }
    }
  }

  void _updateComposeLive(String livePartial) {
    final combined = [_committed, livePartial].where((s) => s.trim().isNotEmpty).join(' ').trim();
    composeController.text = combined;
    composeController.selection = TextSelection.collapsed(offset: combined.length);
  }

  /// Drops any uncommitted live preview, leaving only what was actually
  /// dictated. Called before submitting, because the preview can contain the
  /// submit phrase.
  void _resetComposeToCommitted() {
    composeController.text = _committed;
    composeController.selection = TextSelection.collapsed(offset: _committed.length);
  }

  void _commitToCompose(String finalizedText) {
    final trimmed = finalizedText.trim();
    if (trimmed.isEmpty) return;
    _committed = [_committed, trimmed].where((s) => s.isNotEmpty).join(' ');
    composeController.text = _committed;
    composeController.selection = TextSelection.collapsed(offset: _committed.length);
  }

  /// Returns the composed text with a trailing submit phrase stripped off
  /// (possibly empty, meaning "show whatever was already composed"), or
  /// `null` if [text] doesn't contain a submit command at all. Same
  /// two-tier approach as the Crowdsource Reporting Hub: an exact/trailing
  /// phrase match first, then — only for a short utterance, since this is
  /// asked right after a dedicated "say more, or say show it" re-prompt —
  /// a looser bare-root fallback for a near-miss the exact check would
  /// otherwise reject outright.
  String? _extractSubmitIntent(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    final lower = trimmed.toLowerCase();
    for (final phrase in _submitPhrasesEn) {
      if (lower == phrase) return '';
      if (lower.endsWith(phrase)) return trimmed.substring(0, trimmed.length - phrase.length).trim();
    }
    for (final phrase in _submitPhrasesBn) {
      if (trimmed == phrase) return '';
      if (trimmed.endsWith(phrase)) return trimmed.substring(0, trimmed.length - phrase.length).trim();
    }
    if (trimmed.split(RegExp(r'\s+')).length <= 3) {
      if (_submitRootsEn.any(lower.contains) || _submitRootsBn.any(trimmed.contains)) return '';
    }
    return null;
  }

  /// Shows the composed message to the passer-by.
  ///
  /// A dictated message gets a read-back and a window to stop it: this text
  /// is about to be held up to a stranger, and the person holding the phone
  /// is the one person present who cannot see what it says. A tapped submit
  /// skips it — that text is on screen and has been read.
  Future<void> _submitCompose(BuildContext context, {required bool fromVoice}) async {
    final text = composeController.text.trim();
    if (text.isEmpty) return;

    if (fromVoice) {
      final outcome = await VoiceCancelWindow.run(
        tts: _tts,
        stt: _stt,
        language: widget.language,
        readBack: strings.cancelWindowReadBack(text),
        isCancelled: () => !mounted,
      );
      if (!mounted) return;
      if (outcome == CancelWindowOutcome.cancelled) {
        await _tts.speak(strings.cancelWindowCancelled, language: widget.language);
        return;
      }
      if (outcome == CancelWindowOutcome.edit) {
        _composeController.clear();
        if (!mounted) return;
        setState(() {});
        unawaited(_autoListenLoop());
        return;
      }
      if (!mounted) return;
    }
    if (!context.mounted) return;
    _handedOff = true;
    Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final d = strings;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: 20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.75),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(d.passerbyPickerTitle, style: theme.textTheme.headlineSmall),
                    ),
                  ),
                  Semantics(
                    button: true,
                    label: d.passerbyPickerCloseSemantics,
                    child: IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(d.passerbyPickerSubtitle, style: theme.textTheme.bodySmall),
              const SizedBox(height: 16),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      for (final message in messages)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Semantics(
                            button: true,
                            label: message,
                            child: Material(
                              color: theme.scaffoldBackgroundColor,
                              borderRadius: BorderRadius.circular(14),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(14),
                                onTap: () => Navigator.of(context).pop(message),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                                  alignment: Alignment.centerLeft,
                                  child: Text(message, style: theme.textTheme.titleSmall),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Semantics(
                      textField: true,
                      label: d.passerbyWriteFieldSemantics,
                      child: TextField(
                        controller: composeController,
                        decoration: InputDecoration(hintText: d.passerbyPickerComposeHint),
                        onSubmitted: (_) => _submitCompose(context, fromVoice: false),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Semantics(
                    button: true,
                    label: _listening ? d.chatListeningSemantics : d.passerbySpeakSemantics,
                    hint: d.passerbySpeakHint,
                    liveRegion: _listening,
                    child: Material(
                      color: _listening ? theme.colorScheme.error : theme.colorScheme.primary,
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: _toggleListening,
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Icon(_listening ? Icons.mic_off_rounded : Icons.mic_rounded, color: Colors.white),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => _submitCompose(context, fromVoice: false),
                  child: Text(d.passerbyPickerShowButton),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
