import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/live_location.dart';

class LiveLocationService {
  LiveLocationService({FirebaseFirestore? firestore}) : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  Stream<LiveLocation?> watchLocation(String disabledUserUid) {
    return _db.collection('liveLocations').doc(disabledUserUid).snapshots().map((snap) {
      final data = snap.data();
      if (data == null) return null;
      return LiveLocation.fromJson(disabledUserUid, data);
    });
  }
}
