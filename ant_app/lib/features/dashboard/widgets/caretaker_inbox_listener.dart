import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../guardian/models/communication_message.dart';
import '../../onboarding/models/user_profile.dart';
import '../providers/caretaker_inbox_providers.dart';
import '../providers/chat_providers.dart';

/// Subscribes the Disabled User's device to what their caretaker sends.
///
/// Module 8's receiving half, which never existed — see
/// [incomingCaretakerMessagesProvider] for what was and was not already there.
/// Renders nothing: messages are delivered into the chat stream and spoken,
/// because that is the surface this user already has and already hears.
///
/// Mounted for as long as the dashboard is, so it keeps listening while the
/// user is doing something else in the app.
class CaretakerInboxListener extends ConsumerStatefulWidget {
  const CaretakerInboxListener({super.key, required this.profile, required this.child});

  final UserProfile profile;
  final Widget child;

  @override
  ConsumerState<CaretakerInboxListener> createState() => _CaretakerInboxListenerState();
}

class _CaretakerInboxListenerState extends ConsumerState<CaretakerInboxListener> {
  /// Message ids already accounted for.
  ///
  /// Seeded from the *first* snapshot and never announced, which is the whole
  /// reason it exists: `watchMessages` replays the last 50, so announcing
  /// everything a subscription hands over would read the entire history aloud
  /// on every launch. Only what arrives afterwards is spoken.
  ///
  /// The cost of that is a memo sent while the app was closed staying silent,
  /// and it is a real one. The honest fix is a persisted read marker, which
  /// the Firestore rules cannot support today — `communications` grants read
  /// and create, no update — so it wants a rules change rather than a
  /// workaround here.
  final Set<String> _accountedFor = {};
  bool _seeded = false;

  final _player = AudioPlayer();

  /// One at a time, in arrival order. Two caretaker memos landing together
  /// must not be spoken over each other, and `receiveCaretakerMessage` awaits
  /// playback for a voice memo.
  Future<void> _queue = Future<void>.value();

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<bool> _play(String audioBase64) async {
    try {
      await _player.play(BytesSource(base64Decode(audioBase64), mimeType: 'audio/wav'));
      return true;
    } catch (e) {
      // A clip that will not decode or play must not swallow the fact that
      // the caretaker sent something.
      debugPrint('[CaretakerInbox] could not play voice memo: $e');
      return false;
    }
  }

  void _onMessages(List<CommunicationMessage> messages) {
    if (!_seeded) {
      _seeded = true;
      _accountedFor.addAll(messages.map((m) => m.id));
      debugPrint('[CaretakerInbox] listening — ${messages.length} already in history');
      return;
    }
    final arrived = messages.where((m) => !_accountedFor.contains(m.id)).toList()
      // `watchMessages` orders newest first; deliver oldest first so a
      // sequence of memos is heard in the order it was written.
      ..sort((a, b) => (a.createdAt ?? DateTime.now()).compareTo(b.createdAt ?? DateTime.now()));
    if (arrived.isEmpty) return;
    _accountedFor.addAll(arrived.map((m) => m.id));

    for (final message in arrived) {
      _queue = _queue.then((_) async {
        if (!mounted) return;
        await ref.read(chatControllerProvider.notifier).receiveCaretakerMessage(
              message,
              widget.profile,
              playAudio: _play,
            );
      }).catchError((Object e) {
        debugPrint('[CaretakerInbox] delivering ${message.id} failed: $e');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // No caretaker, no subscription.
    //
    // Not merely an optimisation: pairing is optional by design (see
    // `skipPairing` — every safety feature that does not need a caretaker
    // still works without one), so opening a Firestore listener for a
    // conversation that cannot exist would put a live query, and its cost, on
    // every solo user of the app.
    if (widget.profile.pairedUserId == null) return widget.child;
    ref.listen(
      incomingCaretakerMessagesProvider(widget.profile.uid),
      (previous, next) => next.whenData(_onMessages),
    );
    return widget.child;
  }
}
