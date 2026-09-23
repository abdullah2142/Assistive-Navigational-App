import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../onboarding/models/disability_profile_enums.dart';
import '../../onboarding/providers/onboarding_providers.dart';
import '../models/communication_message.dart';
import '../providers/guardian_providers.dart';
import 'voice_memo_recorder_dialog.dart';

/// Communication Hub — Async Memo, Voice Memo, and Snapshot Request, per UI
/// module plan Step 3.3. Deliberately asynchronous, never live audio/video
/// (see the "No Live Video Feeds" architectural rule) — a Voice Memo is a
/// short bounded recording sent once, not a call.
class CommunicationHubPanel extends ConsumerStatefulWidget {
  const CommunicationHubPanel({super.key, required this.disabledUserUid, required this.caretakerUid});

  final String disabledUserUid;
  final String caretakerUid;

  @override
  ConsumerState<CommunicationHubPanel> createState() => _CommunicationHubPanelState();
}

class _CommunicationHubPanelState extends ConsumerState<CommunicationHubPanel> {
  final _composer = TextEditingController();
  final _scroll = ScrollController();

  String get disabledUserUid => widget.disabledUserUid;
  String get caretakerUid => widget.caretakerUid;

  @override
  void dispose() {
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Sends whatever is in the composer.
  ///
  /// Inline, not a dialog. The hub was three buttons that each opened a modal
  /// to type one message into, which is a form for filing a memo rather than
  /// a conversation — and the messages it had already exchanged sat below in
  /// a read-only list of five. A caretaker checking in on somebody is having
  /// a conversation; this is the shape of one.
  Future<void> _sendComposed() async {
    final text = _composer.text.trim();
    if (text.isEmpty) return;
    _composer.clear();
    await ref.read(communicationServiceProvider).sendMemo(
          disabledUserUid: disabledUserUid,
          fromUid: caretakerUid,
          toUid: disabledUserUid,
          text: text,
        );
  }

  Future<void> _sendVoiceMemo(BuildContext context, WidgetRef ref) async {
    final result = await VoiceMemoRecorderDialog.show(context);
    if (result == null || result.durationSeconds < 1) return;
    await ref.read(communicationServiceProvider).sendVoiceMemo(
          disabledUserUid: disabledUserUid,
          fromUid: caretakerUid,
          toUid: disabledUserUid,
          audioBase64: result.audioBase64,
          durationSeconds: result.durationSeconds,
        );
  }

  /// Sends a picture the caretaker chose — from the gallery or their own
  /// camera.
  ///
  /// Distinct from a Snapshot Request, which asks the *user's* phone to look.
  /// This is the caretaker showing them something: which bus, which door,
  /// what a letter says. It is read aloud on arrival, because a photo on a
  /// screen the user cannot see is not a delivered message.
  Future<void> _sendPhoto(BuildContext context, WidgetRef ref, ImageSource source) async {
    final XFile? picked;
    try {
      picked = await ImagePicker().pickImage(
        source: source,
        // Downscaled before it is encoded. This rides inline in a Firestore
        // document alongside the message, the same way a voice memo does,
        // and a modern phone camera's full-size JPEG would blow the 1MiB
        // document limit on its own.
        maxWidth: 1280,
        maxHeight: 1280,
        imageQuality: 80,
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not open the picker: $e')));
      return;
    }
    if (picked == null) return;

    final bytes = await picked.readAsBytes();
    if (bytes.lengthInBytes > _maxPhotoBytes) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('That photo is too large to send.')),
      );
      return;
    }

    await ref.read(communicationServiceProvider).sendPhoto(
          disabledUserUid: disabledUserUid,
          fromUid: caretakerUid,
          toUid: disabledUserUid,
          imageBase64: base64Encode(bytes),
        );
  }

  /// Firestore's document limit is 1MiB and base64 costs a third on top, so
  /// this is the raw ceiling that keeps the encoded form inside it with room
  /// for the rest of the message.
  static const int _maxPhotoBytes = 700 * 1024;

  Future<void> _requestSnapshot(BuildContext context, WidgetRef ref) async {
    await ref.read(communicationServiceProvider).requestSnapshot(
          disabledUserUid: disabledUserUid,
          fromUid: caretakerUid,
          toUid: disabledUserUid,
        );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Snapshot requested — their phone will answer with a photo.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final messagesAsync = ref.watch(communicationsStreamProvider(disabledUserUid));
    // Whether Snapshot Requests are allowed at all is the Disabled User's
    // own onboarding choice (SnapshotConsentPreference) — never the
    // Caretaker's to override.
    final snapshotConsent = ref
            .watch(profileStreamProvider(disabledUserUid))
            .value
            ?.snapshotConsent ??
        SnapshotConsentPreference.askEachTime;
    final snapshotAllowed = snapshotConsent != SnapshotConsentPreference.never;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            OutlinedButton.icon(
              onPressed: () => _sendVoiceMemo(context, ref),
              icon: const Icon(Icons.mic_none_rounded),
              label: const Text('Voice Memo'),
            ),
            OutlinedButton.icon(
              onPressed: () => _sendPhoto(context, ref, ImageSource.gallery),
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('Send Photo'),
            ),
            OutlinedButton.icon(
              onPressed: () => _sendPhoto(context, ref, ImageSource.camera),
              icon: const Icon(Icons.photo_camera_outlined),
              label: const Text('Take Photo'),
            ),
            if (snapshotAllowed)
              OutlinedButton.icon(
                onPressed: () => _requestSnapshot(context, ref),
                icon: const Icon(Icons.camera_alt_outlined),
                label: const Text('Snapshot Request'),
              )
            else
              Tooltip(
                message: 'Turned off in their Snapshot permission setting',
                child: OutlinedButton.icon(
                  onPressed: null,
                  icon: const Icon(Icons.no_photography_outlined),
                  label: const Text('Snapshot Request'),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        messagesAsync.when(
          data: (messages) {
            if (messages.isEmpty) {
              return Text('No messages yet.', style: theme.textTheme.bodySmall);
            }
            // Oldest at the top, newest at the bottom, the way a
            // conversation reads. The stream arrives newest-first because
            // that is how Firestore limits it to the most recent fifty.
            final ordered = messages.reversed.toList();
            return ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 420),
              child: ListView.builder(
                controller: _scroll,
                shrinkWrap: true,
                reverse: true,
                itemCount: ordered.length,
                itemBuilder: (context, i) => _MessageRow(
                  message: ordered[ordered.length - 1 - i],
                  caretakerUid: caretakerUid,
                ),
              ),
            );
          },
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(),
          ),
          error: (e, st) => Text('Couldn\'t load messages: $e', style: theme.textTheme.bodySmall),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _composer,
                onSubmitted: (_) => _sendComposed(),
                textInputAction: TextInputAction.send,
                // Grows with the message rather than scrolling one line
                // sideways, the same as the user's own input row.
                minLines: 1,
                maxLines: 4,
                keyboardType: TextInputType.multiline,
                decoration: const InputDecoration(
                  hintText: 'Write a message…',
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: _sendComposed,
              icon: const Icon(Icons.send_rounded),
              tooltip: 'Send',
            ),
          ],
        ),
      ],
    );
  }
}

class _MessageRow extends StatefulWidget {
  const _MessageRow({required this.message, required this.caretakerUid});

  final CommunicationMessage message;
  final String caretakerUid;

  @override
  State<_MessageRow> createState() => _MessageRowState();
}

class _MessageRowState extends State<_MessageRow> {
  final _player = AudioPlayer();
  bool _playing = false;

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _togglePlay() async {
    final audioBase64 = widget.message.audioBase64;
    if (audioBase64 == null) return;
    if (_playing) {
      await _player.stop();
      setState(() => _playing = false);
      return;
    }
    setState(() => _playing = true);
    await _player.play(BytesSource(base64Decode(audioBase64), mimeType: 'audio/wav'));
    _player.onPlayerComplete.first.then((_) {
      if (mounted) setState(() => _playing = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final message = widget.message;
    final fromMe = message.fromUid == widget.caretakerUid;

    Widget content;
    if (message.type == CommunicationType.voiceMemo) {
      content = Row(
        children: [
          Semantics(
            button: true,
            label: _playing ? 'Stop voice memo' : 'Play voice memo, ${message.durationSeconds ?? 0} seconds',
            child: InkWell(
              onTap: _togglePlay,
              child: Icon(
                _playing ? Icons.stop_circle_rounded : Icons.play_circle_fill_rounded,
                size: 20,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text('Voice memo · ${message.durationSeconds ?? 0}s', style: theme.textTheme.bodySmall),
        ],
      );
    } else if (message.type == CommunicationType.snapshotReply ||
        message.type == CommunicationType.photo) {
      // The picture and what the vision tier made of it, together. The text
      // alone is what a guardian gets when the camera could not see, and it
      // matters that the two look different — a description with no photo is
      // an answer, not a failure to answer.
      final jpeg = message.imageBase64;
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (jpeg != null && jpeg.isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: Image.memory(
                  base64Decode(jpeg),
                  fit: BoxFit.contain,
                  // A corrupt or truncated frame must not take the whole hub
                  // down — the description below it is still useful.
                  errorBuilder: (_, _, _) =>
                      Text('(photo could not be shown)', style: theme.textTheme.bodySmall),
                ),
              ),
            ),
          if (jpeg != null && jpeg.isNotEmpty) const SizedBox(height: 4),
          Text(message.text, style: theme.textTheme.bodySmall),
        ],
      );
    } else {
      final label = message.type == CommunicationType.snapshotRequest ? '📷 ${message.text}' : message.text;
      content = Text(label, style: theme.textTheme.bodySmall);
    }

    // A bubble on a side, not a row with a direction arrow.
    //
    // The arrow was correct and unreadable at a glance: a caretaker scanning
    // for what they last said had to read each icon. Side and colour are the
    // convention every messaging app has trained everyone on, and this is a
    // conversation — the same one the user is having on their phone.
    return Align(
      alignment: fromMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.66),
        decoration: BoxDecoration(
          color: fromMe ? theme.colorScheme.primaryContainer : theme.colorScheme.surface,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(14),
            topRight: const Radius.circular(14),
            bottomLeft: Radius.circular(fromMe ? 14 : 4),
            bottomRight: Radius.circular(fromMe ? 4 : 14),
          ),
          border: fromMe ? null : Border.all(color: theme.dividerColor),
        ),
        child: Semantics(
          label: fromMe ? 'You sent' : 'They sent',
          child: content,
        ),
      ),
    );
  }
}
