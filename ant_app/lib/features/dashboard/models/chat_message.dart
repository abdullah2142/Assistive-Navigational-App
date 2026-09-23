import 'dart:typed_data';

enum ChatSender { user, assistant, caretaker }

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
    this.messageId,
    this.replyToMessageId,
    this.replyToText,
    this.audioBase64,
    this.audioDurationSeconds,
  });

  final ChatSender sender;
  final String text;
  final DateTime timestamp;

  /// Stable identifier for quoting a particular assistant turn. Older
  /// transcripts did not store ids; their timestamp and sender provide a
  /// deterministic fallback until the next save upgrades the record.
  final String? messageId;

  String get id =>
      messageId ?? '${timestamp.microsecondsSinceEpoch}-${sender.name}';

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

  /// The assistant message this one is a reply to, quoted.
  ///
  /// Asked for as: an AI message should be replyable, so the chat knows
  /// which one is meant. Without it "that one" and "the second place you
  /// said" resolve to whatever the model infers from five turns of history,
  /// which is a guess — and a wrong guess routes somebody to the wrong
  /// place.
  ///
  /// Carried as the quoted *text* rather than an id because that is what has
  /// to reach the model anyway: it reads a transcript, not a database, and
  /// a reference it can act on is the sentence itself.
  final String? replyToText;

  /// The [id] of the assistant bubble quoted by this user turn.
  final String? replyToMessageId;

  /// A caretaker voice memo, kept in memory and out of durable transcripts.
  final String? audioBase64;
  final int? audioDurationSeconds;
}
