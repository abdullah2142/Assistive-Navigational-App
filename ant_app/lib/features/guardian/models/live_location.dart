import 'package:cloud_firestore/cloud_firestore.dart';

/// A disabled user's most recent position, read from `liveLocations/{uid}`.
///
/// Nothing writes this document yet — the background isolate that publishes
/// real GPS + battery updates is `08_module_plan_virtual_guardian.md`
/// (Module 8). This model and [LiveLocationService] establish the read-side
/// contract the Overwatch Map is built against, so Module 8 only has to
/// start writing matching documents, not touch this UI.
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
