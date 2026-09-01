import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/guardian_alert.dart';

class AlertService {
  AlertService({FirebaseFirestore? firestore}) : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> _items(String disabledUserUid) =>
      _db.collection('alerts').doc(disabledUserUid).collection('items');

  Stream<List<GuardianAlert>> watchAlerts(String disabledUserUid) {
    return _items(disabledUserUid).orderBy('createdAt', descending: true).limit(50).snapshots().map(
          (snap) => snap.docs.map((d) => GuardianAlert.fromJson(d.id, d.data())).toList(),
        );
  }

  Future<void> resolveAlert(String disabledUserUid, String alertId) {
    return _items(disabledUserUid).doc(alertId).update({
      'resolved': true,
      'resolvedAt': FieldValue.serverTimestamp(),
    });
  }
}
