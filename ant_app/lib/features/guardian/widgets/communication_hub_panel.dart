import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../onboarding/models/disability_profile_enums.dart';
import '../../onboarding/providers/onboarding_providers.dart';
import '../models/communication_message.dart';
import '../providers/guardian_providers.dart';
import 'voice_memo_recorder_dialog.dart';

/// Communication Hub — Async Memo, Voice Memo, and Snapshot Request, per UI
/// module plan Step 3.3. Deliberately asynchronous, never live audio/video
/// (see the "No Live Video Feeds" architectural rule) — a Voice Memo is a
/// short bounded recording sent once, not a call.
class CommunicationHubPanel extends ConsumerWidget {
  const CommunicationHubPanel({super.key, required this.disabledUserUid, required this.caretakerUid});

  final String disabledUserUid;
  final String caretakerUid;

  Future<void> _sendMemo(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Send a Memo'),
        content: TextField(
          controller: controller,
          maxLines: 3,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'e.g. "Remember to take your medicine at 6pm"'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    if (text == null || text.isEmpty) return;
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

  Future<void> _requestSnapshot(BuildContext context, WidgetRef ref) async {
    await ref.read(communicationServiceProvider).requestSnapshot(
          disabledUserUid: disabledUserUid,
          fromUid: caretakerUid,
          toUid: disabledUserUid,
        );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Snapshot requested — delivery arrives with the Vision Engine module.')),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
              onPressed: () => _sendMemo(context, ref),
              icon: const Icon(Icons.sticky_note_2_outlined),
              label: const Text('Send Memo'),
            ),
            OutlinedButton.icon(
              onPressed: () => _sendVoiceMemo(context, ref),
              icon: const Icon(Icons.mic_none_rounded),
              label: const Text('Voice Memo'),
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
            return Column(
              children: messages.take(5).map((m) => _MessageRow(message: m, caretakerUid: caretakerUid)).toList(),
            );
          },
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(),
          ),
          error: (e, st) => Text('Couldn\'t load messages: $e', style: theme.textTheme.bodySmall),
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
    } else {
      final label = message.type == CommunicationType.snapshotRequest ? '📷 ${message.text}' : message.text;
      content = Text(label, style: theme.textTheme.bodySmall);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            fromMe ? Icons.call_made_rounded : Icons.call_received_rounded,
            size: 16,
            color: AppColors.textSecondary,
          ),
          const SizedBox(width: 8),
          Expanded(child: content),
        ],
      ),
    );
  }
}
