import '../../features/onboarding/models/trusted_contact.dart';

/// Who gets messaged, who gets called, and in what order.
///
/// Pure and separate from dispatch, because this is the decision that
/// actually determines whether anyone comes — and because the moment it
/// runs is the moment nobody is in a position to check it.
class EmergencyPlan {
  const EmergencyPlan._();

  /// Digits, plus a leading `+`.
  ///
  /// Numbers are dictated by voice during onboarding and read back digit by
  /// digit, so what is stored can still contain the spaces and dashes a
  /// person naturally says. `SmsManager` and a `tel:` URI both want them
  /// gone.
  static String normalise(String raw) {
    final trimmed = raw.trim();
    final leadingPlus = trimmed.startsWith('+');
    final digits = trimmed.replaceAll(RegExp(r'[^0-9]'), '');
    return leadingPlus ? '+$digits' : digits;
  }

  /// Whether a stored number is dialable at all.
  ///
  /// Bangladeshi mobile numbers are 11 digits local (`01XXXXXXXXX`) or 13
  /// with the country code (`8801XXXXXXXXX`). The bar is deliberately low —
  /// this rejects blanks and obvious junk, not unusual-but-real numbers,
  /// because refusing to try a number in an emergency is far worse than
  /// trying one that fails.
  static bool isDialable(String raw) {
    final n = normalise(raw);
    final digits = n.replaceAll('+', '');
    return digits.length >= 6 && digits.length <= 15;
  }

  /// Everyone who should receive the SMS, de-duplicated, primary first.
  ///
  /// Primary first because dispatch is sequential and a phone that dies or
  /// loses signal partway through should have reached the most important
  /// person already. Duplicates removed by normalised number, so the same
  /// person saved twice is not messaged twice — in an emergency that reads
  /// as a malfunction and costs the recipient time working out whether
  /// something happened twice.
  static List<String> smsRecipients(List<TrustedContact> contacts) {
    final ordered = [...contacts]..sort((a, b) {
        if (a.isPrimary == b.isPrimary) return 0;
        return a.isPrimary ? -1 : 1;
      });
    final seen = <String>{};
    final out = <String>[];
    for (final c in ordered) {
      if (!isDialable(c.phoneNumber)) continue;
      final number = normalise(c.phoneNumber);
      if (!seen.add(number)) continue;
      out.add(number);
    }
    return out;
  }

  /// The one number to actually ring, or null when there is nobody to ring.
  ///
  /// The explicit primary if there is one, otherwise the first usable
  /// contact — because "nobody was marked primary" must not mean "no call
  /// is placed". Onboarding does not force the choice, so this cannot
  /// assume it was made.
  static String? callTarget(List<TrustedContact> contacts) {
    final usable = contacts.where((c) => isDialable(c.phoneNumber));
    if (usable.isEmpty) return null;
    final primary = usable.where((c) => c.isPrimary);
    final chosen = primary.isNotEmpty ? primary.first : usable.first;
    return normalise(chosen.phoneNumber);
  }
}
