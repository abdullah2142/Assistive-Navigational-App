import 'package:firebase_auth/firebase_auth.dart';

/// Thin wrapper around Firebase Auth.
///
/// Onboarding must never make a Visually Impaired user type a password, so
/// identity starts as an anonymous session the moment they pick a role.
/// Role-Based Access Control itself is enforced server-side via Custom
/// Claims, set by the `onUserRoleWritten` Cloud Function (see
/// `functions/index.js`) when `users/{uid}.role` is first written — the
/// client only ever reads `role` back off the ID token / Firestore doc, it
/// never sets its own claim.
class AuthService {
  AuthService({FirebaseAuth? auth}) : _auth = auth ?? FirebaseAuth.instance;

  final FirebaseAuth _auth;

  Stream<User?> authStateChanges() => _auth.authStateChanges();

  User? get currentUser => _auth.currentUser;

  Future<User> ensureSignedIn() async {
    final existing = _auth.currentUser;
    final user = existing ?? (await _auth.signInAnonymously()).user;
    if (user == null) {
      throw StateError('Anonymous sign-in returned a null user.');
    }
    // Force the ID token to be (re)fetched before the caller issues any
    // Firestore writes. On web there's a race — both right after
    // signInAnonymously() resolves, and when `currentUser` is restored
    // from a persisted session on page load — where a write can reach
    // Firestore before the auth listener has propagated a valid token,
    // causing a spurious permission-denied.
    await user.getIdToken();
    return user;
  }
}
