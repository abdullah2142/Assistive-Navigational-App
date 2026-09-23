import 'dart:typed_data';

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
    this.imageJpeg,
  });

  final ChatSender sender;
  final String text;
  final DateTime timestamp;

  /// The camera frame this reply was based on, when there was one.
  ///
  /// Asked for directly: "user should be able to see which image made it
  /// through". A scan picks the sharpest of up to three frames, downscales
  /// it and uploads that one — and until now the user had the answer with no
  /// way to tell what it was an answer *about*. A wildly wrong description is
  /// almost always a wildly wrong aim, and that is invisible without the
  /// picture.
  ///
  /// Deliberately not persisted by `ChatHistoryStore`: the transcript is
  /// restored on launch and tens of kilobytes per scan would grow without
  /// bound in shared preferences. The frame lives as long as the session
  /// that produced it.
  final Uint8List? imageJpeg;
}
