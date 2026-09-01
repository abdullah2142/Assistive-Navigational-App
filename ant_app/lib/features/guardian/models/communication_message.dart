import 'package:cloud_firestore/cloud_firestore.dart';

/// [memo] is a free-text Asynchronous Memo. [voiceMemo] is a short recorded
/// clip (see [CommunicationMessage.audioBase64]) — both deliberately
/// asynchronous, never live audio/video (see the "No Live Video Feeds"
/// architectural rule: this is a bounded recording sent once, not a call).
/// [snapshotRequest] asks the disabled user's device for one still frame —
/// real capture/delivery is the Snapshot Vision Engine, Module 6; this just
/// records that the request was sent.
enum CommunicationType {
  memo,
  voiceMemo,
  snapshotRequest;

  static CommunicationType fromFirestore(String? value) =>
      CommunicationType.values.firstWhere((v) => v.name == value, orElse: () => CommunicationType.memo);
}

/// One entry in the Communication Hub, read from
/// `communications/{disabledUserUid}/messages`.
class CommunicationMessage {
  const CommunicationMessage({
    required this.id,
    required this.fromUid,
    required this.toUid,
    required this.type,
    required this.text,
    this.audioBase64,
    this.durationSeconds,
    this.createdAt,
  });

  final String id;
  final String fromUid;
  final String toUid;
  final CommunicationType type;
  final String text;

  /// WAV-wrapped PCM16 audio, base64-encoded — only set when
  /// [type] is [CommunicationType.voiceMemo]. Capped short (see
  /// `VoiceMemoRecorderDialog`) to stay well under Firestore's 1MiB
  /// document limit without needing Cloud Storage.
  final String? audioBase64;
  final int? durationSeconds;
  final DateTime? createdAt;

  factory CommunicationMessage.fromJson(String id, Map<String, dynamic> json) => CommunicationMessage(
        id: id,
        fromUid: json['fromUid'] as String,
        toUid: json['toUid'] as String,
        type: CommunicationType.fromFirestore(json['type'] as String?),
        text: json['text'] as String? ?? '',
        audioBase64: json['audioBase64'] as String?,
        durationSeconds: (json['durationSeconds'] as num?)?.toInt(),
        createdAt: (json['createdAt'] as Timestamp?)?.toDate(),
      );
}
