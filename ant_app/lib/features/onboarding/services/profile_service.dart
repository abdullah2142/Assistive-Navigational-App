import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/onboarding_step.dart';
import '../models/user_profile.dart';

/// Reads/writes the `users/{uid}` profile document.
class ProfileService {
  ProfileService({FirebaseFirestore? firestore}) : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  DocumentReference<Map<String, dynamic>> _doc(String uid) => _db.collection('users').doc(uid);

  Stream<UserProfile?> watchProfile(String uid) {
    return _doc(uid).snapshots().map((snap) {
      final data = snap.data();
      if (data == null) return null;
      return UserProfile.fromJson(data);
    });
  }

  Future<UserProfile?> fetchProfile(String uid) async {
    final snap = await _doc(uid).get();
    final data = snap.data();
    if (data == null) return null;
    return UserProfile.fromJson(data);
  }

  /// Upsert — used after every onboarding step so progress survives an app
  /// restart mid-interview, not just at final lock-in.
  Future<void> saveProfile(UserProfile profile) {
    return _doc(profile.uid).set(profile.toJson(), SetOptions(merge: true));
  }

  /// Records how far through onboarding this user has got, and nothing else.
  ///
  /// Its own single-field write rather than a whole-profile [saveProfile]:
  /// step changes are synchronous and frequent, and touching only this field
  /// means it can never race a profile write into overwriting an answer.
  Future<void> saveOnboardingStep({required String uid, required OnboardingStep step}) {
    return _doc(uid).set({'onboardingStep': step.name}, SetOptions(merge: true));
  }
}
