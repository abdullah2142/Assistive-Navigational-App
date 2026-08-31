import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';

/// Handles Step 1 of onboarding: linking a Caretaker device to a Disabled
/// User device via a 6-digit code, stored transiently in the
/// `pairingCodes/{code}` collection.
///
/// A code is single-use and expires after 15 minutes so stale codes can't be
/// replayed by a stranger who happened to see one on a caretaker's screen.
class PairingService {
  PairingService({FirebaseFirestore? firestore}) : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;
  static const _codeTtl = Duration(minutes: 15);

  CollectionReference<Map<String, dynamic>> get _codes => _db.collection('pairingCodes');
  CollectionReference<Map<String, dynamic>> get _users => _db.collection('users');

  String _generateCode() {
    final rand = Random.secure();
    return List.generate(6, (_) => rand.nextInt(10)).join();
  }

  /// Caretaker calls this. Returns the 6-digit code to display/read aloud.
  Future<String> generateCode({required String caretakerUid}) async {
    String code = _generateCode();
    // Extremely unlikely, but guard against an active collision.
    var doc = await _codes.doc(code).get();
    while (doc.exists) {
      code = _generateCode();
      doc = await _codes.doc(code).get();
    }

    await _codes.doc(code).set({
      'caretakerUid': caretakerUid,
      'disabledUserUid': null,
      'createdAt': FieldValue.serverTimestamp(),
      'expiresAt': Timestamp.fromDate(DateTime.now().add(_codeTtl)),
    });
    return code;
  }

  /// Caretaker device listens on this to learn the moment a Disabled User
  /// redeems the code, so it can navigate forward automatically.
  Stream<String?> watchClaimedBy(String code) {
    return _codes.doc(code).snapshots().map((snap) => snap.data()?['disabledUserUid'] as String?);
  }

  /// Disabled User calls this after entering the code shown on the
  /// Caretaker's screen. Links both profiles' `pairedUserId` atomically.
  Future<String> redeemCode({required String code, required String disabledUserUid}) async {
    return _db.runTransaction<String>((txn) async {
      final codeRef = _codes.doc(code);
      final codeSnap = await txn.get(codeRef);

      if (!codeSnap.exists) {
        throw PairingException('That code was not found. Ask your caretaker for a new one.');
      }
      final data = codeSnap.data()!;
      final expiresAt = (data['expiresAt'] as Timestamp).toDate();
      if (DateTime.now().isAfter(expiresAt)) {
        throw PairingException('That code has expired. Ask your caretaker for a new one.');
      }
      if (data['disabledUserUid'] != null) {
        throw PairingException('That code has already been used.');
      }

      final caretakerUid = data['caretakerUid'] as String;

      txn.update(codeRef, {'disabledUserUid': disabledUserUid});
      txn.set(_users.doc(disabledUserUid), {'pairedUserId': caretakerUid}, SetOptions(merge: true));
      txn.set(_users.doc(caretakerUid), {'pairedUserId': disabledUserUid}, SetOptions(merge: true));

      return caretakerUid;
    });
  }
}

class PairingException implements Exception {
  PairingException(this.message);
  final String message;

  @override
  String toString() => message;
}
