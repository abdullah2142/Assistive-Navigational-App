import 'package:flutter/material.dart';

import '../../../core/localization/dashboard_strings.dart';
import '../models/chat_message.dart';

class ChatBubble extends StatelessWidget {
  const ChatBubble({super.key, required this.message, required this.strings});

  final ChatMessage message;
  final Dashboard strings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = message.sender == ChatSender.user;
    final frame = message.imageJpeg;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Semantics(
        // A screen-reader user is told the photo exists. They cannot see it,
        // but "this answer came from a photo" is still information — it is
        // what makes "point the camera lower" a sensible next thing to say.
        label: isUser
            ? strings.chatYouSaid(message.text)
            : '${frame == null ? '' : '${strings.chatAnsweredFromAPhoto} '}'
                '${strings.chatAssistantSaid(message.text)}',
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
          decoration: BoxDecoration(
            color: isUser ? theme.colorScheme.primary : theme.colorScheme.surface,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(18),
              topRight: const Radius.circular(18),
              bottomLeft: Radius.circular(isUser ? 18 : 4),
              bottomRight: Radius.circular(isUser ? 4 : 18),
            ),
            border: isUser ? null : Border.all(color: theme.dividerColor),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // The frame a scan was answered from, above its answer.
              //
              // Asked for directly: "user should be able to see which image
              // made it through". A sweep takes up to three frames and
              // uploads the sharpest one; until now the user had a
              // description with no way to tell what it described. A wildly
              // wrong answer is almost always a wildly wrong aim, which is
              // invisible without the picture — and it is the one thing a
              // sighted helper can fix in a second.
              if (frame != null) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 200),
                    child: Image.memory(
                      frame,
                      fit: BoxFit.contain,
                      // A truncated frame must not take the answer down with
                      // it — the text below is the part that matters.
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],
              Text(
                message.text,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: isUser ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
