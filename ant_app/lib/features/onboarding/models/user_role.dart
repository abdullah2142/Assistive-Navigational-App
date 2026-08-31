/// The two Dual-Role Architecture flows. Every screen in the app branches
/// on this value — there is no shared UI between the two roles.
enum UserRole {
  disabledUser,
  caretaker;

  String get firestoreValue => name;

  static UserRole fromFirestore(String value) =>
      UserRole.values.firstWhere((r) => r.name == value, orElse: () => UserRole.disabledUser);
}
