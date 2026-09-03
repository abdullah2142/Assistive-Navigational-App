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
  final ValueChanged<SuggestedChipAction> onOverlayChip;
  final UserProfile profile;

  @override
  ConsumerState<ChatStreamPanel> createState() => _ChatStreamPanelState();
}

class _ChatStreamPanelState extends ConsumerState<ChatStreamPanel> with WidgetsBindingObserver {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  bool _listening = false;

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
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        _backgroundListening.start();
      case AppLifecycleState.resumed:
        _backgroundListening.stop();
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
      widget.onOverlayChip(chip.action);
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
      widget.onOverlayChip(next);
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
        // mic gets its own big, centered, unmissable button.
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
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
                    width: 76,
                    height: 76,
                    child: Icon(_listening ? Icons.mic_off_rounded : Icons.mic_rounded,
                        color: Colors.white, size: 36),
                  ),
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  textField: true,
                  label: d.chatInputHint,
                  child: TextField(
                    controller: _textController,
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
          ),
        ),
      ],
    );
  }
}
