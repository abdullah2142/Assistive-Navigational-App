import 'package:cloud_firestore/cloud_firestore.dart';

/// Trigger source for a Guardian alert.
///
/// [magicButton] and [inactivity] are the two triggers the master plan
/// defines (Modules 8-9); nothing writes these documents yet — see
/// [GuardianAlert].
enum GuardianAlertType {
  magicButton,
  inactivity;

  static GuardianAlertType fromFirestore(String? value) =>
      GuardianAlertType.values.firstWhere((v) => v.name == value, orElse: () => GuardianAlertType.inactivity);

  String get label => switch (this) {
        GuardianAlertType.magicButton => 'Magic Button pressed',
        GuardianAlertType.inactivity => 'No movement detected',
      };
}

/// A row in the Guardian Hub's Alert Center, read from
/// `alerts/{disabledUserUid}/items`. Populated by the Virtual Guardian
/// background isolate (Module 8) and the Magic Button (Module 9) — this
/// model and [AlertService] define the contract those modules write to.
class GuardianAlert {
  const GuardianAlert({
    required this.id,
    required this.type,
    required this.createdAt,
    this.resolved = false,
  });

  final String id;
  final GuardianAlertType type;
  final DateTime? createdAt;
  final bool resolved;

  factory GuardianAlert.fromJson(String id, Map<String, dynamic> json) => GuardianAlert(
        id: id,
        type: GuardianAlertType.fromFirestore(json['type'] as String?),
        createdAt: (json['createdAt'] as Timestamp?)?.toDate(),
        resolved: json['resolved'] as bool? ?? false,
      );
}
