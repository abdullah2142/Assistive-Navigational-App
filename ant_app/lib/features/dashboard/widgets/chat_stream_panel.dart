import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/dashboard_strings.dart';
import '../../../core/providers/ai_assistant_providers.dart';
import '../../../core/providers/tts_providers.dart';
import '../../../core/services/background_listening_service.dart';
import '../../../core/services/emergency_channel.dart';
import '../../../core/services/stt_service.dart';
import '../../../core/services/wake_word_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../onboarding/models/user_profile.dart';
import '../models/hazard_report.dart';
import '../models/suggested_chip.dart';
import '../providers/chat_providers.dart';
import 'chat_bubble.dart';
import 'suggested_chip_row.dart';

/// The Dynamic Chat Stream — top 60% of the Split-Mode Dashboard.
class ChatStreamPanel extends ConsumerStatefulWidget {
  const ChatStreamPanel({
    super.key,
    required this.onOverlayChip,
    required this.profile,
    this.onToggleMap,
    this.mapVisible = false,
  });

  /// Shows/hides the map. Null hides the control entirely — the panel is
  /// usable without one.
  final VoidCallback? onToggleMap;
  final bool mapVisible;

  /// [SuggestedChipAction.showScreenToPasserby] and
  /// [SuggestedChipAction.reportHazard] open full-screen overlays owned by
  /// the parent screen rather than staying inside the chat, so this callback
  /// hands those two actions back up — whether triggered by a chip tap or
  /// by the AI Assistant's function calling (see [ChatState.pendingOverlayAction]).
  /// Second argument is non-null only for
  /// [SuggestedChipAction.reportHazard] triggered by a command that already
  /// named the hazard — see [HazardReportPrefill].
  final void Function(SuggestedChipAction action, HazardReportPrefill? prefill) onOverlayChip;
  final UserProfile profile;

  @override
  ConsumerState<ChatStreamPanel> createState() => _ChatStreamPanelState();
}

class _ChatStreamPanelState extends ConsumerState<ChatStreamPanel> with WidgetsBindingObserver {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  bool _listening = false;

  /// True between "a listen was requested" and "that listen finished".
  /// Separate from [_listening], which only becomes true once the recognizer
  /// is actually up — the gap between the two is what a second wake-word
  /// detection used to land in.
  bool _startingListen = false;

  // Captured once, here, rather than `ref.read` inside `dispose()` — `ref`
  // is unsafe to use once a widget is unmounting (a real crash this caused
  // live: "Bad state: Using 'ref' when a widget is about to or has been
  // unmounted is unsafe").
  late final SttService _stt = ref.read(sttServiceProvider);
  late final WakeWordService _wakeWord = ref.read(wakeWordServiceProvider);
  late final BackgroundListeningService _backgroundListening = ref.read(backgroundListeningServiceProvider);

  /// The Volume-Down hold. Registered here because this panel is alive for
  /// the whole time the dashboard is, which is the whole time the physical
  /// trigger can fire — Android only delivers key events to a foregrounded
  /// activity.
  final _emergencyChannel = EmergencyChannel();

  @override
  void initState() {
    super.initState();
    // Forces both lazy `late final` initializers to run now, while `ref` is
    // still safe to use — otherwise, if push-to-talk is never tapped and
    // wake-word is off, `dispose()` ends up being the *first* access to one
    // or both, which is exactly the unsafe-`ref` crash these fields were
    // introduced to avoid.
    _stt;
    _wakeWord;
    _backgroundListening;
    _emergencyChannel.onPhysicalTrigger(() async {
      if (!mounted) return;
      debugPrint('[Emergency] volume-down hold');
      await ref.read(chatControllerProvider.notifier).triggerEmergency(widget.profile);
    });
    ref.read(ttsServiceProvider).setVoiceId(widget.profile.voiceId);
    _applyWakeWordThreshold();
    // The saved strength has to reach the service before the first turn, not
    // on the first visit to settings.
    ref.read(hapticsServiceProvider).intensity = widget.profile.hapticIntensity;
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => ref.read(chatControllerProvider.notifier).ensureWelcomeMessage(Dashboard.of(widget.profile.language)),
    );
    if (widget.profile.wakeWordEnabled) _startWakeWordListening();
  }

  /// Backgrounding/locking is exactly when continuous listening matters
  /// most (the user isn't looking at the screen at all) and exactly when
  /// Android would otherwise freeze or kill this process — start the
  /// foreground service so it doesn't, and stop it again once the app is
  /// back in front (no need for a persistent notification while visible).
  /// A no-op whenever wake-word itself is off.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!widget.profile.wakeWordEnabled) return;
    switch (state) {
      // `paused`/`hidden` mean the app really has gone away. `inactive` is
      // deliberately NOT in this list: it fires transiently while the app is
      // still on screen and fully usable — pulling down the notification
      // shade, an incoming-call banner, a permission dialog, the app
      // switcher — so starting on it put an ongoing "listening in the
      // background" notification in front of a user who had not
      // backgrounded anything, and flapped the service on every one of
      // those, since `inactive` is also the state every app passes through
      // on its way back to `resumed`.
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _backgroundListening.start();
      case AppLifecycleState.resumed:
        _backgroundListening.stop();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  void didUpdateWidget(covariant ChatStreamPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.profile.voiceId != oldWidget.profile.voiceId) {
      ref.read(ttsServiceProvider).setVoiceId(widget.profile.voiceId);
    }
    // Before the enabled check below, which returns early. The dial can be
    // moved without the toggle changing at all — in fact that is the normal
    // case, since somebody tuning it has the wake word switched on already.
    if (widget.profile.wakeWordThreshold != oldWidget.profile.wakeWordThreshold) {
      _applyWakeWordThreshold();
    }
    if (widget.profile.hapticIntensity != oldWidget.profile.hapticIntensity) {
      ref.read(hapticsServiceProvider).intensity = widget.profile.hapticIntensity;
    }
    if (widget.profile.wakeWordEnabled == oldWidget.profile.wakeWordEnabled) return;
    if (widget.profile.wakeWordEnabled) {
      _startWakeWordListening();
    } else {
      _wakeWord.stop();
      _backgroundListening.stop();
    }
  }

  /// Pushes the user's chosen sensitivity into the detector.
  ///
  /// No restart needed — detection reads the threshold at comparison time,
  /// so a change takes effect on the very next scored window. That is what
  /// makes the dial usable at all: somebody tuning it says the phrase, reads
  /// the score, moves the slider, and says it again, without a round trip
  /// through a rebuild or a rebuilt APK.
  ///
  /// A null threshold means the profile has never been tuned, and the build's
  /// own default stands.
  void _applyWakeWordThreshold() {
    final chosen = widget.profile.wakeWordThreshold;
    _wakeWord.threshold = chosen ?? WakeWordService.defaultDetectionThreshold;
  }

  /// Starts (or restarts, after a command was just handled) continuous
  /// "Hey ANT" listening. Stopped while push-to-talk command listening is
  /// actually in progress — the two shouldn't fight over the microphone —
  /// and restarted once that finishes, so detection is effectively
  /// continuous whenever the toggle is on. The actual stop/restart around
  /// the STT session lives in [_toggleListening] itself now, not here — see
  /// its doc comment for why.
  Future<void> _startWakeWordListening() async {
    await _wakeWord.start(
      onDetected: () {
        if (!mounted) return;
        HapticFeedback.mediumImpact();
        _listenFromWakeWord(Dashboard.of(widget.profile.language));
      },
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _textController.dispose();
    _scrollController.dispose();
    _stt.stop();
    _wakeWord.stop();
    _backgroundListening.stop();
    super.dispose();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _handleChip(SuggestedChip chip, Dashboard d) async {
    if (chip.action == SuggestedChipAction.showScreenToPasserby ||
        chip.action == SuggestedChipAction.reportHazard) {
      widget.onOverlayChip(chip.action, null);
      return;
    }
    await ref.read(chatControllerProvider.notifier).handleChip(chip, widget.profile, chip.labelFor(d));
    _scrollToEnd();
  }

  Future<void> _submitText() async {
    final text = _textController.text;
    _textController.clear();
    await ref.read(chatControllerProvider.notifier).sendFreeText(text, widget.profile);
    _scrollToEnd();
  }

  /// Push-to-talk, triggered either by the mic button or by wake-word
  /// detection. Pausing/resuming wake-word listening around this session
  /// is handled centrally inside `SttService.listenOnce` now (see its doc
  /// comment) — every mic entry point in the app gets that coordination
  /// automatically, so this doesn't need its own copy of that logic.
  /// The mic button. A tap while a session is running ends it.
  ///
  /// It used to do nothing at all. One method served both the button and
  /// wake-word detection, and its reentrancy guard — there to stop a second
  /// detection cancelling the session the first one started — was held for
  /// the whole of `listenOnce`, not just the start. So every tap on the red
  /// mic hit `if (_startingListen) return`, and the `if (_listening)` branch
  /// under it was unreachable. A user who opened the microphone by accident
  /// had no way to close it, which for someone who cannot see that it is
  /// open is worse than a stuck button.
  ///
  /// The two callers want opposite things from a session that is already
  /// running, so they are two methods now: a tap stops it, a wake word
  /// leaves it alone.
  Future<void> _toggleListening(Dashboard d) async {
    if (_listening || _startingListen) {
      // `SttService.stop()` completes the pending session's completer, so
      // the `listenOnce` below returns and its `finally` clears both flags.
      await _stt.stop();
      return;
    }
    await _beginListening(d);
  }

  /// Wake-word detection. Never cancels a session already in progress: the
  /// phrase was almost certainly the user starting to talk into a
  /// microphone that is already open, and stopping it there is how "Hey ANT
  /// works once, then stops working while the mic icon stays on" happened —
  /// alternating start/stop, the icon left showing whenever the pair ended
  /// on a start.
  Future<void> _listenFromWakeWord(Dashboard d) async {
    if (_listening || _startingListen) return;
    await _beginListening(d);
  }

  Future<void> _beginListening(Dashboard d) async {
    // Set synchronously, before the first await, so two calls in the same
    // turn cannot both get past the guards above.
    _startingListen = true;
    try {
      if (!await _stt.ensureAvailable()) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(d.chatVoiceUnavailable)));
        return;
      }
      setState(() => _listening = true);
      await _stt.listenOnce(
        language: widget.profile.language,
        onResult: (text, isFinal) {
          // `mounted` must gate the whole callback — a pending listen session
          // can still deliver a result after this widget is gone (same crash
          // class confirmed live elsewhere: writing into a disposed
          // controller).
          if (!mounted) return;
          _textController.text = text;
          _textController.selection = TextSelection.collapsed(offset: text.length);
          if (isFinal) {
            setState(() => _listening = false);
            if (text.trim().isNotEmpty) _submitText();
          }
        },
      );
    } finally {
      // In `finally` so a throw from `listenOnce` cannot strand the flag —
      // that would wedge the mic button permanently, with no way back short
      // of leaving the screen.
      _startingListen = false;
      if (mounted) setState(() => _listening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final chatState = ref.watch(chatControllerProvider);
    final d = Dashboard.of(widget.profile.language);
    _scrollToEnd();

    ref.listen(chatControllerProvider.select((s) => s.pendingOverlayAction), (previous, next) {
      if (next == null) return;
      // Read the prefill from the same state snapshot, before clearing —
      // `clearPendingOverlay` clears both.
      widget.onOverlayChip(next, ref.read(chatControllerProvider).pendingHazardPrefill);
      ref.read(chatControllerProvider.notifier).clearPendingOverlay();
    });

    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            itemCount: chatState.messages.length + (chatState.isAssistantTyping ? 1 : 0),
            itemBuilder: (context, index) {
              if (index >= chatState.messages.length) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Semantics(
                      liveRegion: true,
                      label: d.chatAssistantTyping,
                      child: SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ),
                  ),
                );
              }
              return ChatBubble(message: chatState.messages[index], strings: d);
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: SuggestedChipRow(
            chips: kDefaultSuggestedChips,
            strings: d,
            onTap: (chip) => _handleChip(chip, d),
          ),
        ),
        // Mic on the left of the input bar rather than on its own row.
        //
        // It was a 76dp button centred on a line of its own, which read as
        // the panel's main control — true — but cost a whole row of height
        // to say so, on top of the row the text field already took. Side by
        // side, it is still the largest and left-most target on the bar (the
        // first thing a thumb or a screen reader reaches) while the chat
        // above keeps the space both rows used to consume.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          child: Row(
            children: [
              if (widget.onToggleMap != null) ...[
                Semantics(
                  button: true,
                  label: widget.mapVisible ? d.mapHideSemantics : d.mapShowSemantics,
                  child: IconButton(
                    icon: Icon(widget.mapVisible ? Icons.map_rounded : Icons.map_outlined),
                    // Beside the mic and the send button rather than in the
                    // app bar's far corner, which is the furthest point on
                    // the screen from a thumb that is already on this row.
                    onPressed: widget.onToggleMap,
                  ),
                ),
                const SizedBox(width: 4),
              ],
              Semantics(
                button: true,
                label: _listening ? d.chatListeningSemantics : d.chatSpeakSemantics,
                hint: d.chatSpeakHint,
                liveRegion: _listening,
                child: Material(
                  color: _listening ? AppColors.danger : AppColors.primary,
                  shape: const CircleBorder(),
                  elevation: 2,
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => _toggleListening(d),
                    child: SizedBox(
                      width: 52,
                      height: 52,
                      child: Icon(_listening ? Icons.mic_off_rounded : Icons.mic_rounded,
                          color: Colors.white, size: 26),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Semantics(
                  textField: true,
                  label: d.chatInputHint,
                  child: TextField(
                    controller: _textController,
                    onSubmitted: (_) => _submitText(),
                    textInputAction: TextInputAction.send,
                    // Grows with the text, like every messaging app, instead
                    // of scrolling a single line sideways. Capped at five so
                    // a long dictation cannot swallow the chat above it —
                    // past that it scrolls within the field.
                    minLines: 1,
                    maxLines: 5,
                    keyboardType: TextInputType.multiline,
                    // Denser than the theme default, which was sized for a
                    // form rather than for one line in a crowded panel.
                    decoration: InputDecoration(
                      hintText: d.chatInputHint,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Semantics(
                button: true,
                label: d.chatSendSemantics,
                child: Material(
                  color: AppColors.primaryLight,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => _submitText(),
                    child: const SizedBox(
                      width: 48,
                      height: 48,
                      child: Icon(Icons.send_rounded, color: Colors.white, size: 22),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

}
