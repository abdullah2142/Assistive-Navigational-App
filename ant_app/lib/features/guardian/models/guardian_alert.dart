import 'package:cloud_firestore/cloud_firestore.dart';

/// Trigger source for a Guardian alert.
///
/// [magicButton] and [inactivity] are the two triggers the master plan
/// defines (Modules 8-9). [userRequested] is item 57: "user asking to alert
/// caretaker doesnt do anything yet".
///
/// It is deliberately a separate type rather than reusing [magicButton].
/// They mean genuinely different things on the caretaker's side — the Magic
/// Button is an emergency that has already rung round the family, while this
/// is somebody asking, calmly and in words, to be checked on. Showing the
/// second as the first would teach a caretaker to discount both.
enum GuardianAlertType {
  magicButton,
  inactivity,
  userRequested;

  static GuardianAlertType fromFirestore(String? value) =>
      GuardianAlertType.values.firstWhere((v) => v.name == value, orElse: () => GuardianAlertType.inactivity);

  String get label => switch (this) {
        GuardianAlertType.magicButton => 'Magic Button pressed',
        GuardianAlertType.inactivity => 'No movement detected',
        GuardianAlertType.userRequested => 'Asked you to check in',
      };
}

/// A row in the Guardian Hub's Alert Center, read from
/// `alerts/{disabledUserUid}/items`. Written by the Magic Button (Module 9)
/// and by `alert_caretaker`, the spoken request that is item 57. The
/// inactivity trigger is still Module 8's to write.
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
