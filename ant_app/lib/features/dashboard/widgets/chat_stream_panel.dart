import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_language.dart';
import '../../../core/localization/dashboard_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../models/suggested_chip.dart';
import '../providers/chat_providers.dart';
import 'chat_bubble.dart';
import 'suggested_chip_row.dart';

/// The Dynamic Chat Stream — top 60% of the Split-Mode Dashboard.
class ChatStreamPanel extends ConsumerStatefulWidget {
  const ChatStreamPanel({super.key, required this.onOverlayChip, required this.language});

  /// [SuggestedChipAction.showScreenToPasserby] and
  /// [SuggestedChipAction.reportHazard] open full-screen overlays owned by
  /// the parent screen rather than staying inside the chat, so this callback
  /// hands those two actions back up.
  final ValueChanged<SuggestedChipAction> onOverlayChip;
  final AppLanguage language;

  @override
  ConsumerState<ChatStreamPanel> createState() => _ChatStreamPanelState();
}

class _ChatStreamPanelState extends ConsumerState<ChatStreamPanel> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => ref.read(chatControllerProvider.notifier).ensureWelcomeMessage(Dashboard.of(widget.language)),
    );
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
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
    await ref.read(chatControllerProvider.notifier).handleChip(chip, d, chip.labelFor(d));
    _scrollToEnd();
  }

  Future<void> _submitText(Dashboard d) async {
    final text = _textController.text;
    _textController.clear();
    await ref.read(chatControllerProvider.notifier).sendFreeText(text, d);
    _scrollToEnd();
  }

  @override
  Widget build(BuildContext context) {
    final chatState = ref.watch(chatControllerProvider);
    final d = Dashboard.of(widget.language);
    _scrollToEnd();

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
              label: d.chatSpeakSemantics,
              hint: d.chatSpeakHint,
              child: Material(
                color: AppColors.primary,
                shape: const CircleBorder(),
                elevation: 2,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(d.chatVoiceUnavailable)),
                    );
                  },
                  child: const SizedBox(
                    width: 76,
                    height: 76,
                    child: Icon(Icons.mic_rounded, color: Colors.white, size: 36),
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
                    onSubmitted: (_) => _submitText(d),
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
                    onTap: () => _submitText(d),
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
