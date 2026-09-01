enum ChatSender { user, assistant }

/// One bubble in the Dynamic Chat Stream.
///
/// This is transient, in-memory conversation state — it does not persist to
/// Firestore. Nothing here calls a real model yet: [ChatController] (Module
/// 2) generates canned replies. Module 3 swaps that generator for Gemini
/// with function calling, without needing to change this model.
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
