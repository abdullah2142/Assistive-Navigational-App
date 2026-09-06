import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

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

  /// Raises an alert on the paired Caretaker's Alert Center.
  ///
  /// The write side of what was until now a read-only pair of services: the
  /// Overwatch Map and the Alert Center were watching collections that
  /// nothing ever populated, so the Caretaker half of the app looked
  /// finished and did nothing. This is the first thing that writes to them.
  ///
  /// Deliberately never throws. It runs during an emergency, after SMS and
  /// the call have already been attempted, and it needs the network — which
  /// is exactly what may have failed and prompted the SMS route in the
  /// first place. An exception here would abort the remaining escalation
  /// steps to report a failure nobody can act on. The boolean is for
  /// logging and tests, not for changing what the user is told.
  Future<bool> createAlert({
    required String disabledUserUid,
    required GuardianAlertType type,
    double? lat,
    double? lng,
    int? batteryPercent,
    List<String> notifiedContacts = const [],
  }) async {
    try {
      await _items(disabledUserUid).add({
        'type': type.name,
        'createdAt': FieldValue.serverTimestamp(),
        'resolved': false,
        if (lat != null && lng != null) 'lat': lat,
        if (lat != null && lng != null) 'lng': lng,
        'batteryPercent': ?batteryPercent,
        // Recorded so the Caretaker can see who was already reached and
        // does not spend the first minute ringing round people who have
        // been told.
        if (notifiedContacts.isNotEmpty) 'notifiedContacts': notifiedContacts,
      });
      return true;
    } catch (e) {
      debugPrint('[Alerts] createAlert failed (non-fatal): $e');
      return false;
    }
  }

  /// Publishes the user's position for the Overwatch Map.
  ///
  /// One document per user, overwritten — the map shows where they are, not
  /// where they have been, and a history would be a far larger promise
  /// about retention than this app has made to anyone.
  Future<bool> publishLocation({
    required String disabledUserUid,
    required double lat,
    required double lng,
  }) async {
    try {
      await _db.collection('liveLocations').doc(disabledUserUid).set({
        'lat': lat,
        'lng': lng,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      return true;
    } catch (e) {
      debugPrint('[Alerts] publishLocation failed (non-fatal): $e');
      return false;
    }
  }

  Future<void> resolveAlert(String disabledUserUid, String alertId) {
    return _items(disabledUserUid).doc(alertId).update({
      'resolved': true,
      'resolvedAt': FieldValue.serverTimestamp(),
    });
  }
}
