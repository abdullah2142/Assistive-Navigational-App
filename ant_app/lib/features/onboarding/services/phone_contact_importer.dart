import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';

import '../../../core/localization/app_language.dart';

/// Reads the local address book only after the user opens the contact search.
/// The list stays in memory on-device; callers persist only the one
/// TrustedContact the user selects.
class PhoneContactImporter {
  PhoneContactImporter._();

  /// Filters the already-loaded on-device list. Nothing is sent to a server
  /// while a user types or dictates a query.
  static List<Contact> filterContacts(List<Contact> contacts, String query) {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) return contacts;
    return contacts.where((contact) {
      final name = (contact.displayName ?? '').toLowerCase();
      final phones = contact.phones.map((phone) => phone.number.toLowerCase());
      return name.contains(normalized) ||
          phones.any((phone) => phone.contains(normalized));
    }).toList();
  }

  static Future<List<Contact>> readPhoneContacts(
    BuildContext context, {
    required AppLanguage language,
  }) async {
    try {
      final permission = await FlutterContacts.permissions.request(
        PermissionType.read,
      );
      if (!context.mounted) return const [];
      if (permission != PermissionStatus.granted &&
          permission != PermissionStatus.limited) {
        _message(
          context,
          _copy(
            language,
            'Allow contacts access to search saved numbers. You can still enter a contact manually.',
            'সংরক্ষিত নম্বর খুঁজতে পরিচিতির অনুমতি দিন। চাইলে হাতে যোগাযোগ যোগ করতে পারেন।',
          ),
        );
        return const [];
      }

      return await FlutterContacts.getAll(properties: {ContactProperty.phone});
    } catch (_) {
      if (context.mounted) {
        _message(
          context,
          _copy(
            language,
            'Could not read phone contacts. You can enter a contact manually.',
            'ফোনের পরিচিতি পড়া যায়নি। চাইলে হাতে যোগাযোগ যোগ করতে পারেন।',
          ),
        );
      }
      return const [];
    }
  }

  static void _message(BuildContext context, String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  static String _copy(AppLanguage language, String english, String bangla) =>
      language == AppLanguage.bangla ? bangla : english;
}
