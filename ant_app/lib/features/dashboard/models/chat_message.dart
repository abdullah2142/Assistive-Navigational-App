enum ChatSender { user, assistant }

/// One bubble in the Dynamic Chat Stream.
///
/// This is transient, in-memory conversation state — it does not persist to
/// Firestore. [ChatController] generates replies via Gemini function
/// calling (Module 3) when configured, falling back to Module 2's canned
/// replies otherwise — this model didn't need to change for that.
class ChatMessage {
  const ChatMessage({
    required this.sender,
    required this.text,
    required this.timestamp,
  });

  final ChatSender sender;
  final String text;
  final DateTime timestamp;
}
