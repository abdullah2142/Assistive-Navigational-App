import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/chat_message.dart';

/// Keeps the chat transcript across restarts — item 52.
///
/// **Reported:** "chat elements go away after closing app."
///
/// `ChatState.messages` lived in memory and nothing wrote it anywhere. For a
/// user who cannot see the screen the transcript is not decoration: it is the
/// only record of what was agreed — which place was picked out of three
/// similarly-named ones, what the caretaker said, what the app claimed it had
/// done. Losing it on every close means there is nothing to go back to and
/// check, and no way to show somebody else what happened.
///
/// ## On device only
///
/// This is written to the app's support directory and **never uploaded**.
/// The transcript is the most sensitive thing this app holds — every spoken
/// command verbatim, the places someone goes, what they asked their caretaker
/// — and the diagnostics log goes to the length of redacting its own copy
/// before it is even stored (`log_redaction.dart`). That file is written to be
/// *sent*; this one exists to be read back by the person who said it, on the
/// phone they said it on, so it is kept whole and kept local.
///
/// It is also keyed to a uid and refuses to load someone else's: a caretaker
/// and the person they care for sharing a handset is an ordinary thing during
/// testing, and a transcript surfacing under the wrong account would be a real
/// disclosure rather than a glitch.
class ChatHistoryStore {
  ChatHistoryStore({Directory? directory}) : _injectedDirectory = directory;

  final Directory? _injectedDirectory;

  /// Enough to cover a session's conversation and a good way into the one
  /// before it, without a transcript growing without bound on the phone of
  /// somebody who cannot see it to clear it.
  static const int maxMessages = 200;

  static const String fileName = 'chat-history.json';

  /// Coalesced within one turn of the event loop rather than behind a timer.
  ///
  /// A timer would batch more — a reply lands as a user turn, a typing state
  /// and an assistant turn spread over a few hundred milliseconds — but it
  /// also leaves a live timer behind whenever the app is closed or a test
  /// ends between the last message and the write, which is exactly the moment
  /// this feature exists for. Per-turn coalescing collapses the bursts that
  /// happen synchronously, writes at most once per turn, and holds nothing
  /// that can outlive its owner. The file is capped at [maxMessages], so a
  /// write is tens of kilobytes at worst.
  bool _scheduled = false;
  Future<void> _writing = Future<void>.value();
  List<ChatMessage>? _queued;
  String? _queuedUid;

  Future<Directory> _directory() async =>
      _injectedDirectory ?? await getApplicationSupportDirectory();

  Future<File> _file() async => File('${(await _directory()).path}/$fileName');

  /// Reads back the transcript for [uid], newest last.
  ///
  /// Returns empty for anything it cannot make sense of — a partial write, a
  /// file from an older shape of this model, another account's. A transcript
  /// is a convenience; failing to read one must never stop the dashboard from
  /// opening.
  Future<List<ChatMessage>> load(String uid) async {
    try {
      final file = await _file();
      if (!await file.exists()) return const [];
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return const [];
      if (decoded['uid'] != uid) {
        debugPrint(
          '[ChatHistory] stored transcript belongs to another account — ignoring',
        );
        return const [];
      }
      final raw = decoded['messages'];
      if (raw is! List) return const [];
      final messages = <ChatMessage>[];
      for (final entry in raw) {
        if (entry is! Map) continue;
        final text = entry['text'];
        final sender = entry['sender'];
        final at = DateTime.tryParse(entry['timestamp'] as String? ?? '');
        if (text is! String || text.isEmpty || at == null) continue;
        messages.add(
          ChatMessage(
            sender: switch (sender) {
              'user' => ChatSender.user,
              'caretaker' => ChatSender.caretaker,
              _ => ChatSender.assistant,
            },
            text: text,
            timestamp: at,
            messageId: entry['id'] as String?,
            replyToMessageId: entry['replyToMessageId'] as String?,
            replyToText: entry['replyToText'] as String?,
          ),
        );
      }
      debugPrint('[ChatHistory] restored ${messages.length} messages');
      return messages;
    } catch (e) {
      debugPrint('[ChatHistory] could not read the transcript (non-fatal): $e');
      return const [];
    }
  }

  /// Schedules a write. Safe to call on every state change.
  void save(String uid, List<ChatMessage> messages) {
    _queued = messages;
    _queuedUid = uid;
    if (_scheduled) return;
    _scheduled = true;
    scheduleMicrotask(() {
      _scheduled = false;
      flush();
    });
  }

  /// Writes whatever is queued, now.
  Future<void> flush() {
    final messages = _queued;
    final uid = _queuedUid;
    if (messages == null || uid == null) return _writing;
    _queued = null;
    _queuedUid = null;
    _writing = _writing.then((_) => _write(uid, messages));
    return _writing;
  }

  Future<void> _write(String uid, List<ChatMessage> messages) async {
    try {
      // The tail, not the head: the end of the conversation is what somebody
      // is going back to check.
      final kept = messages.length > maxMessages
          ? messages.sublist(messages.length - maxMessages)
          : messages;
      final file = await _file();
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({
          'uid': uid,
          'messages': [
            for (final m in kept)
              {
                'sender': m.sender.name,
                'text': m.text,
                'timestamp': m.timestamp.toIso8601String(),
                'id': m.id,
                if (m.replyToMessageId != null)
                  'replyToMessageId': m.replyToMessageId,
                if (m.replyToText != null) 'replyToText': m.replyToText,
              },
          ],
        }),
      );
    } catch (e) {
      debugPrint(
        '[ChatHistory] could not write the transcript (non-fatal): $e',
      );
    }
  }

  /// Removes the stored transcript. Used when the account changes.
  Future<void> clear() async {
    _queued = null;
    _queuedUid = null;
    try {
      final file = await _file();
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('[ChatHistory] could not clear the transcript: $e');
    }
  }

  /// Nothing to release — the store holds no timer and no handle. Kept so
  /// the provider's teardown reads the same as every other service here.
  void dispose() {}
}
