import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ant_app/features/onboarding/services/phone_contact_importer.dart';

void main() {
  final contacts = [
    const Contact(
      id: 'mom',
      displayName: 'Mother',
      phones: [Phone(number: '+880 1712-345678')],
    ),
    const Contact(
      id: 'sister',
      displayName: 'Ayesha',
      phones: [Phone(number: '+880 1812-345678')],
    ),
  ];

  group('phone contact search', () {
    test('empty query returns the locally loaded contacts', () {
      expect(PhoneContactImporter.filterContacts(contacts, ' '), contacts);
    });

    test('matches a name without case sensitivity', () {
      expect(PhoneContactImporter.filterContacts(contacts, 'MOT'), [
        contacts.first,
      ]);
    });

    test('matches part of a saved phone number', () {
      expect(PhoneContactImporter.filterContacts(contacts, '1812'), [
        contacts.last,
      ]);
    });

    test('an unmatched query returns no contacts', () {
      expect(PhoneContactImporter.filterContacts(contacts, 'unknown'), isEmpty);
    });
  });
}
