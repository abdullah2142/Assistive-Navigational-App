import 'package:flutter/material.dart';

import '../models/chat_message.dart';

/// A debug-only annotation that an assistant call failed, shown as its own
/// banner rather than a chat bubble — a screen reader must not read this as
/// something the assistant said, and a tester skimming the transcript
/// should be able to tell at a glance which lines are the conversation and
/// which are this app's own account of what went wrong underneath it.
///
/// Only ever built for a [ChatMessage] whose `sender` is
/// [ChatSender.error], and that sender only ever exists in `kDebugMode` —
/// see where `ChatController` appends one.
class DebugErrorBanner extends StatelessWidget {
  const DebugErrorBanner({super.key, required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ExcludeSemantics(
      child: Align(
        alignment: Alignment.center,
        child: Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: theme.colorScheme.errorContainer.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: theme.colorScheme.error, width: 1),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.bug_report_outlined,
                size: 18,
                color: theme.colorScheme.error,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Assistant call failed (debug only)',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.error,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      message.text,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onErrorContainer,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
