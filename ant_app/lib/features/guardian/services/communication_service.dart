import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/communication_message.dart';

/// Reads/writes `communications/{disabledUserUid}/messages`. Keyed by the
/// disabled user's uid (the stable anchor of a pairing) rather than by both
/// participants, so listing a conversation is a single-field query with no
/// composite index required.
class CommunicationService {
  CommunicationService({FirebaseFirestore? firestore}) : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> _messages(String disabledUserUid) =>
      _db.collection('communications').doc(disabledUserUid).collection('messages');

  Stream<List<CommunicationMessage>> watchMessages(String disabledUserUid) {
    return _messages(disabledUserUid).orderBy('createdAt', descending: true).limit(50).snapshots().map(
          (snap) => snap.docs.map((d) => CommunicationMessage.fromJson(d.id, d.data())).toList(),
        );
  }

  Future<void> _send({
    required String disabledUserUid,
    required String fromUid,
    required String toUid,
    required CommunicationType type,
    required String text,
    String? audioBase64,
    String? imageBase64,
    int? durationSeconds,
  }) {
    return _messages(disabledUserUid).add({
      'fromUid': fromUid,
      'toUid': toUid,
      'type': type.name,
      'text': text,
      'audioBase64': ?audioBase64,
      'imageBase64': ?imageBase64,
      'durationSeconds': ?durationSeconds,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> sendMemo({
    required String disabledUserUid,
    required String fromUid,
    required String toUid,
    required String text,
  }) {
    return _send(
      disabledUserUid: disabledUserUid,
      fromUid: fromUid,
      toUid: toUid,
      type: CommunicationType.memo,
      text: text,
    );
  }

  /// [audioBase64] is WAV-wrapped PCM16, already capped short by
  /// `VoiceMemoRecorderDialog` — see [CommunicationMessage.audioBase64].
  Future<void> sendVoiceMemo({
    required String disabledUserUid,
    required String fromUid,
    required String toUid,
    required String audioBase64,
    required int durationSeconds,
  }) {
    return _send(
      disabledUserUid: disabledUserUid,
      fromUid: fromUid,
      toUid: toUid,
      type: CommunicationType.voiceMemo,
      text: '',
      audioBase64: audioBase64,
      durationSeconds: durationSeconds,
    );
  }

  /// Records that a Snapshot Request was sent. Module 6 (Snapshot Vision
  /// Engine) is what actually captures and delivers the frame in response.
  Future<void> requestSnapshot({
    required String disabledUserUid,
    required String fromUid,
    required String toUid,
  }) {
    return _send(
      disabledUserUid: disabledUserUid,
      fromUid: fromUid,
      toUid: toUid,
      type: CommunicationType.snapshotRequest,
      text: 'Snapshot requested.',
    );
  }

  /// Answers a Snapshot Request with the frame and what the vision tier made
  /// of it.
  ///
  /// [text] is sent even when [imageBase64] is null — a scan that could not
  /// see still owes the guardian an answer, and "the camera could not see"
  /// is a different thing from a request that vanished. The latter is what a
  /// tester reported.
  Future<void> sendSnapshotReply({
    required String disabledUserUid,
    required String fromUid,
    required String toUid,
    required String text,
    String? imageBase64,
  }) {
    return _send(
      disabledUserUid: disabledUserUid,
      fromUid: fromUid,
      toUid: toUid,
      type: CommunicationType.snapshotReply,
      text: text,
      imageBase64: imageBase64,
    );
  }
}
