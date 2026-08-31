class TrustedContact {
  const TrustedContact({
    required this.name,
    required this.phoneNumber,
    this.relationship = '',
    this.isPrimary = false,
  });

  final String name;
  final String phoneNumber;
  final String relationship;
  final bool isPrimary;

  Map<String, dynamic> toJson() => {
        'name': name,
        'phoneNumber': phoneNumber,
        'relationship': relationship,
        'isPrimary': isPrimary,
      };

  factory TrustedContact.fromJson(Map<String, dynamic> json) => TrustedContact(
        name: json['name'] as String? ?? '',
        phoneNumber: json['phoneNumber'] as String? ?? '',
        relationship: json['relationship'] as String? ?? '',
        isPrimary: json['isPrimary'] as bool? ?? false,
      );

  TrustedContact copyWith({
    String? name,
    String? phoneNumber,
    String? relationship,
    bool? isPrimary,
  }) =>
      TrustedContact(
        name: name ?? this.name,
        phoneNumber: phoneNumber ?? this.phoneNumber,
        relationship: relationship ?? this.relationship,
        isPrimary: isPrimary ?? this.isPrimary,
      );
}
