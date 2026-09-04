import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/dashboard_strings.dart';
import '../../../core/providers/ai_assistant_providers.dart';
import '../../../core/providers/tts_providers.dart';
import '../../../core/services/background_listening_service.dart';
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
  const ChatStreamPanel({super.key, required this.onOverlayChip, required this.profile});

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
  final _textFocus = FocusNode();
  bool _listening = false;

  /// Whether the keyboard input is expanded.
  ///
  /// Collapsed by default. A permanently-open text field cost roughly a
  /// fifth of this panel's height to a control that most of this app's
  /// users will never touch — they speak. Folding it into a single button
  /// hands that space back to the chat and to the suggestion chips, which
  /// are what the panel is actually for.
  bool _typing = false;

  // Captured once, here, rather than `ref.read` inside `dispose()` — `ref`
  // is unsafe to use once a widget is unmounting (a real crash this caused
  // live: "Bad state: Using 'ref' when a widget is about to or has been
  // unmounted is unsafe").
  late final SttService _stt = ref.read(sttServiceProvider);
  late final WakeWordService _wakeWord = ref.read(wakeWordServiceProvider);
  late final BackgroundListeningService _backgroundListening = ref.read(backgroundListeningServiceProvider);

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
    // Collapse the composer once the user is done with it, so the space
    // goes back to the chat without anyone having to remember to close it.
    // Only when it's empty — a half-typed message that vanished because the
    // keyboard was dismissed would be a worse trade than the space.
    _textFocus.addListener(() {
      if (!_textFocus.hasFocus && _typing && _textController.text.trim().isEmpty) {
        setState(() => _typing = false);
      }
    });
    ref.read(ttsServiceProvider).setVoiceId(widget.profile.voiceId);
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
    if (widget.profile.wakeWordEnabled == oldWidget.profile.wakeWordEnabled) return;
    if (widget.profile.wakeWordEnabled) {
      _startWakeWordListening();
    } else {
      _wakeWord.stop();
      _backgroundListening.stop();
    }
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
        _toggleListening(Dashboard.of(widget.profile.language));
      },
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _textController.dispose();
    _textFocus.dispose();
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
  Future<void> _toggleListening(Dashboard d) async {
    if (_listening) {
      await _stt.stop();
      setState(() => _listening = false);
      return;
    }
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
    if (mounted) setState(() => _listening = false);
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
        // Voice is the primary way most of this app's users interact — a
        // small icon squeezed next to the text field undersold that, so the
        // mic keeps its own big, centered, unmissable button. 64 rather
        // than 76: still far above the 48dp minimum and still the largest
        // target on the panel, but no longer crowding the chat above it.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          child: _typing ? _buildComposer(d) : _buildVoiceBar(d),
        ),
      ],
    );
  }

  /// Collapsed state: the mic, centered, with a small keyboard affordance
  /// beside it. Typing is available but no longer occupying the panel
  /// whether or not anyone wants it.
  Widget _buildVoiceBar(Dashboard d) {
    return Row(
      children: [
        // Balances the keyboard button on the right so the mic sits at the
        // true centre of the panel rather than being nudged off it — this
        // is the control users aim at by feel.
        const SizedBox(width: 52),
        Expanded(
          child: Center(
            child: Semantics(
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
                    width: 64,
                    height: 64,
                    child: Icon(_listening ? Icons.mic_off_rounded : Icons.mic_rounded,
                        color: Colors.white, size: 32),
                  ),
                ),
              ),
            ),
          ),
        ),
        Semantics(
          button: true,
          label: d.chatTypeInsteadSemantics,
          child: Material(
            color: Colors.transparent,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: _openComposer,
              child: SizedBox(
                width: 52,
                height: 52,
                child: Icon(Icons.keyboard_rounded,
                    color: Theme.of(context).colorScheme.onSurfaceVariant, size: 26),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Expanded state: the full text field, focused, with a way back out.
  Widget _buildComposer(Dashboard d) {
    return Row(
      children: [
        Semantics(
          button: true,
          label: d.chatCloseKeyboardSemantics,
          child: Material(
            color: Colors.transparent,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: _closeComposer,
              child: SizedBox(
                width: 48,
                height: 48,
                child: Icon(Icons.close_rounded,
                    color: Theme.of(context).colorScheme.onSurfaceVariant, size: 24),
              ),
            ),
          ),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Semantics(
            textField: true,
            label: d.chatInputHint,
            child: TextField(
              controller: _textController,
              focusNode: _textFocus,
              autofocus: true,
              onSubmitted: (_) => _submitText(),
              textInputAction: TextInputAction.send,
              decoration: InputDecoration(hintText: d.chatInputHint),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Semantics(
          button: true,
          label: d.chatSendSemantics,
          child: Material(
            color: AppColors.primaryLight,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => _submitText(),
              child: const Padding(
                padding: EdgeInsets.all(14),
                child: Icon(Icons.send_rounded, color: Colors.white),
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _openComposer() {
    setState(() => _typing = true);
    // The field is created focused (`autofocus`), so this only matters when
    // reopening a composer the framework has already built once.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _typing) _textFocus.requestFocus();
    });
  }

  void _closeComposer() {
    _textFocus.unfocus();
    setState(() => _typing = false);
  }
}

