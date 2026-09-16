import 'package:cloud_firestore/cloud_firestore.dart';

/// A disabled user's most recent position, read from `liveLocations/{uid}`.
///
/// Written by `LiveLocationPublisher` while the disabled user has the app
/// open and a caretaker paired, and by the emergency sequence regardless.
/// That comment used to say nothing wrote it at all, which stayed true for
/// long enough to become item 58 — "caretaker doesnt get location".
///
/// [batteryPercent] is still unwritten: it needs a battery plugin this app
/// does not depend on. It is optional here and the publisher merges rather
/// than replaces, so whatever eventually writes it will not be clobbered.
class LiveLocation {
  const LiveLocation({
    required this.uid,
    required this.lat,
    required this.lng,
    this.batteryPercent,
    this.updatedAt,
  });

  final String uid;
  final double lat;
  final double lng;
  final int? batteryPercent;
  final DateTime? updatedAt;

  factory LiveLocation.fromJson(String uid, Map<String, dynamic> json) => LiveLocation(
        uid: uid,
        lat: (json['lat'] as num).toDouble(),
        lng: (json['lng'] as num).toDouble(),
        batteryPercent: (json['batteryPercent'] as num?)?.toInt(),
        updatedAt: (json['updatedAt'] as Timestamp?)?.toDate(),
      );
}
