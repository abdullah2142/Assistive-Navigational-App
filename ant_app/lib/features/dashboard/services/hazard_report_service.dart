import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/hazard_report.dart';

/// Writes crowdsourced reports to the flat `hazardReports` collection.
/// Module 5 owns reading/aggregating these into routing weights.
class HazardReportService {
  HazardReportService({FirebaseFirestore? firestore}) : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  Future<void> submitReport(HazardReport report) {
    return _db.collection('hazardReports').add({
      ...report.toJson(),
      'createdAt': FieldValue.serverTimestamp(),
    });
  }
}
