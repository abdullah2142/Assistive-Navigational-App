import 'package:cloud_firestore/cloud_firestore.dart';

/// [memo] is a free-text Asynchronous Memo. [voiceMemo] is a short recorded
/// clip (see [CommunicationMessage.audioBase64]) — both deliberately
/// asynchronous, never live audio/video (see the "No Live Video Feeds"
/// architectural rule: this is a bounded recording sent once, not a call).
/// [snapshotRequest] asks the disabled user's device for one still frame;
/// [snapshotReply] is that frame coming back, with what the vision tier made
/// of it.
///
/// The reply half did not exist. A guardian pressed the button, the request
/// was recorded, and the user's device answered "that ability will be added
/// later" — accurate when written, because Module 6 was unbuilt, and stale
/// ever since it shipped. Reported by a tester as the request sending
/// nothing back.
enum CommunicationType {
  memo,
  voiceMemo,
  snapshotRequest,
  snapshotReply;

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
    this.imageBase64,
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

  /// A JPEG, base64-encoded — only set when [type] is
  /// [CommunicationType.snapshotReply].
  ///
  /// Held inline for the same reason [audioBase64] is: a scan frame is tens
  /// of kilobytes, comfortably under Firestore's 1MiB document limit, and
  /// inlining it avoids standing up Cloud Storage and its own rules for one
  /// picture. The frame sent is the same downscaled one the vision tier
  /// uploaded, so this costs no extra capture and no extra encode.
  final String? imageBase64;

  final int? durationSeconds;
  final DateTime? createdAt;

  factory CommunicationMessage.fromJson(String id, Map<String, dynamic> json) => CommunicationMessage(
        id: id,
        fromUid: json['fromUid'] as String,
        toUid: json['toUid'] as String,
        type: CommunicationType.fromFirestore(json['type'] as String?),
        text: json['text'] as String? ?? '',
        audioBase64: json['audioBase64'] as String?,
        imageBase64: json['imageBase64'] as String?,
        durationSeconds: (json['durationSeconds'] as num?)?.toInt(),
        createdAt: (json['createdAt'] as Timestamp?)?.toDate(),
      );
}
