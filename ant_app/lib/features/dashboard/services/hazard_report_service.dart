import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/hazard_report.dart';

/// Writes crowdsourced reports to the flat `hazardReports` collection.
/// Module 5 owns reading/aggregating these into routing weights.
class HazardReportService {
  HazardReportService({FirebaseFirestore? firestore}) : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  /// `async`/`await` rather than returning the `add()` future directly, and
  /// that difference is not cosmetic.
  ///
  /// `CollectionReference.add` returns `Future<DocumentReference<...>>`.
  /// Returning it from a `Future<void>` signature compiles — Dart allows the
  /// upcast — but the *runtime* object is still a `Future<DocumentReference>`,
  /// so `.timeout(...)` on it demands an `onTimeout` that returns a
  /// `DocumentReference`. The caller passes one returning `bool`, and every
  /// submission threw:
  ///
  ///   type '() => bool' is not a subtype of type
  ///   `'() => FutureOr<DocumentReference<Map<String, dynamic>>>' of 'onTimeout'`
  ///
  /// Reported from the device as "পাঠানো যায়নি" on every report. Awaiting here
  /// makes the returned future genuinely `Future<void>`, which is what the
  /// signature has always promised.
  Future<void> submitReport(HazardReport report) async {
    await _db.collection('hazardReports').add({
      ...report.toJson(),
      'createdAt': FieldValue.serverTimestamp(),
    });
  }
}
