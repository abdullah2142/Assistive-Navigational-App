import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;

import '../../../core/localization/dashboard_strings.dart';
import '../models/chat_message.dart';

class ChatBubble extends StatefulWidget {
  const ChatBubble({
    super.key,
    required this.message,
    required this.strings,
    this.onReply,
  });

  final ChatMessage message;
  final Dashboard strings;
  final VoidCallback? onReply;

  @override
  State<ChatBubble> createState() => _ChatBubbleState();
}

class _ChatBubbleState extends State<ChatBubble> {
  final AudioPlayer _player = AudioPlayer();
  bool _playing = false;

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggleAudio() async {
    final audio = widget.message.audioBase64;
    if (audio == null) return;
    if (_playing) {
      await _player.stop();
      if (mounted) setState(() => _playing = false);
      return;
    }
    setState(() => _playing = true);
    _player.onPlayerComplete.first.then((_) {
      if (mounted) setState(() => _playing = false);
    });
    try {
      await _player.play(
        BytesSource(base64Decode(audio), mimeType: 'audio/wav'),
      );
    } catch (_) {
      if (mounted) setState(() => _playing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final message = widget.message;
    final strings = widget.strings;
    final isUser = message.sender == ChatSender.user;
    final isCaretaker = message.sender == ChatSender.caretaker;
    final frame = message.imageJpeg;
    final primaryText = isUser
        ? theme.colorScheme.onPrimary
        : isCaretaker
        ? theme.colorScheme.onTertiaryContainer
        : theme.colorScheme.onSurface;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: widget.onReply,
        child: Semantics(
          label: isUser
              ? '${message.replyToText == null || message.replyToText!.isEmpty ? '' : '${strings.chatReplyingTo(message.replyToText!)}. '}${strings.chatYouSaid(message.text)}'
              : isCaretaker
              ? 'Caretaker message: ${message.text}'
              : '${frame == null ? '' : '${strings.chatAnsweredFromAPhoto} '}${strings.chatAssistantSaid(message.text)}',
          customSemanticsActions: widget.onReply == null
              ? null
              : {
                  CustomSemanticsAction(label: strings.chatReplyAction):
                      widget.onReply!,
                },
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 6),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.78,
            ),
            decoration: BoxDecoration(
              color: isUser
                  ? theme.colorScheme.primary
                  : isCaretaker
                  ? theme.colorScheme.tertiaryContainer
                  : theme.colorScheme.surface,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(18),
                topRight: const Radius.circular(18),
                bottomLeft: Radius.circular(isUser ? 18 : 4),
                bottomRight: Radius.circular(isUser ? 4 : 18),
              ),
              border: isUser || isCaretaker
                  ? null
                  : Border.all(color: theme.dividerColor),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (message.replyToText != null &&
                    message.replyToText!.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    margin: const EdgeInsets.only(bottom: 6),
                    decoration: BoxDecoration(
                      color: primaryText.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8),
                      border: Border(
                        left: BorderSide(width: 3, color: primaryText),
                      ),
                    ),
                    child: Text(
                      message.replyToText!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: primaryText,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                if (message.audioBase64 != null)
                  Semantics(
                    button: true,
                    label: _playing
                        ? 'Stop voice message'
                        : 'Play voice message, ${message.audioDurationSeconds ?? 0} seconds',
                    child: InkWell(
                      borderRadius: BorderRadius.circular(24),
                      onTap: _toggleAudio,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _playing
                                  ? Icons.stop_circle_rounded
                                  : Icons.play_circle_fill_rounded,
                              size: 30,
                              color: primaryText,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _playing
                                  ? 'Playing voice message'
                                  : 'Play voice message · ${message.audioDurationSeconds ?? 0}s',
                              style: TextStyle(color: primaryText),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (frame != null) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 200),
                      child: Image.memory(
                        frame,
                        fit: BoxFit.contain,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                if (message.text.isNotEmpty)
                  Text(
                    message.text,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: primaryText,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
