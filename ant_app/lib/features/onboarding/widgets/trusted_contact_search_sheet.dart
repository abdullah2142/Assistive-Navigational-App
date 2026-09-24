import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_language.dart';
import '../../../core/providers/ai_assistant_providers.dart';
import '../../../core/services/stt_service.dart';
import '../../../core/theme/app_colors.dart';
import '../models/trusted_contact.dart';
import '../services/phone_contact_importer.dart';
import 'voice_dictate_button.dart';

/// On-device searchable contact list plus a voice-friendly manual-entry path.
/// Only a contact explicitly selected or entered here is returned to the
/// caller for saving in the emergency-contact profile.
class TrustedContactSearchSheet extends ConsumerStatefulWidget {
  const TrustedContactSearchSheet({super.key, required this.language});

  final AppLanguage language;

  static Future<TrustedContact?> show(
    BuildContext context, {
    required AppLanguage language,
  }) => showModalBottomSheet<TrustedContact>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => TrustedContactSearchSheet(language: language),
  );

  @override
  ConsumerState<TrustedContactSearchSheet> createState() =>
      _TrustedContactSearchSheetState();
}

class _TrustedContactSearchSheetState
    extends ConsumerState<TrustedContactSearchSheet> {
  final _search = TextEditingController();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  late final SttService _stt = ref.read(sttServiceProvider);
  List<Contact> _contacts = const [];
  bool _loading = true;
  bool _manualEntry = false;
  bool _listening = false;

  @override
  void initState() {
    super.initState();
    _stt;
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadContacts());
  }

  @override
  void dispose() {
    if (_listening || _stt.isListening) _stt.stop();
    _search.dispose();
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  String _t(String en, String bn) =>
      widget.language == AppLanguage.bangla ? bn : en;

  Future<void> _loadContacts() async {
    final contacts = await PhoneContactImporter.readPhoneContacts(
      context,
      language: widget.language,
    );
    if (!mounted) return;
    setState(() {
      _contacts =
          contacts
              .where((c) => c.phones.any((p) => p.number.trim().isNotEmpty))
              .toList()
            ..sort(
              (a, b) => (a.displayName ?? '').toLowerCase().compareTo(
                (b.displayName ?? '').toLowerCase(),
              ),
            );
      _loading = false;
    });
  }

  List<Contact> get _matches =>
      PhoneContactImporter.filterContacts(_contacts, _search.text);

  Future<void> _voiceSearch() async {
    if (_listening) {
      await _stt.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }
    if (!await _stt.ensureAvailable()) {
      if (mounted)
        _showMessage(
          _t(
            'Voice input is unavailable. Type a name or number instead.',
            'ভয়েস ইনপুট নেই। নাম বা নম্বর লিখে খুঁজুন।',
          ),
        );
      return;
    }
    if (!mounted) return;
    setState(() => _listening = true);
    await _stt.listenOnce(
      language: widget.language,
      onResult: (text, isFinal) {
        if (!mounted || text.trim().isEmpty) return;
        _search.value = TextEditingValue(
          text: text.trim(),
          selection: TextSelection.collapsed(offset: text.trim().length),
        );
        setState(() {});
        if (isFinal) setState(() => _listening = false);
      },
    );
    if (mounted) setState(() => _listening = false);
  }

  void _select(Contact contact, String phone) {
    final name = (contact.displayName ?? '').trim();
    Navigator.of(context).pop(
      TrustedContact(name: name.isEmpty ? phone : name, phoneNumber: phone),
    );
  }

  void _selectContact(Contact contact) {
    final numbers = contact.phones
        .map((p) => p.number.trim())
        .where((p) => p.isNotEmpty)
        .toSet()
        .toList();
    if (numbers.length == 1) {
      _select(contact, numbers.single);
      return;
    }
    if (numbers.length < 2) return;
    showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          _t(
            'Choose a number for ${contact.displayName ?? 'this contact'}',
            '${contact.displayName ?? 'এই পরিচিতি'}-র নম্বর বেছে নিন',
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final number in numbers)
              ListTile(
                leading: const Icon(Icons.phone_outlined),
                title: Text(number),
                onTap: () => Navigator.of(dialogContext).pop(number),
              ),
          ],
        ),
      ),
    ).then((number) {
      if (mounted && number != null) _select(contact, number);
    });
  }

  void _saveManual() {
    final name = _name.text.trim();
    final phone = _phone.text.trim();
    if (name.isEmpty || phone.isEmpty) {
      _showMessage(
        _t(
          'Enter both a name and phone number.',
          'নাম ও ফোন নম্বর দুটোই লিখুন।',
        ),
      );
      return;
    }
    Navigator.of(context).pop(TrustedContact(name: name, phoneNumber: phone));
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final matches = _matches;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Material(
        color: AppColors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .84,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _manualEntry
                            ? _t('Add a new contact', 'নতুন যোগাযোগ যোগ করুন')
                            : _t(
                                'Find an emergency contact',
                                'জরুরি যোগাযোগ খুঁজুন',
                              ),
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      tooltip: _t('Close', 'বন্ধ করুন'),
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  _t(
                    'Search your phone contacts by name or number. Contacts stay on this phone; only the one you choose is saved.',
                    'নাম বা নম্বর দিয়ে ফোনের পরিচিতি খুঁজুন। পরিচিতিগুলো ফোনেই থাকবে; আপনি যেটি বাছবেন শুধু সেটিই সেভ হবে।',
                  ),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              const SizedBox(height: 14),
              if (!_manualEntry)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: TextField(
                    controller: _search,
                    onChanged: (_) => setState(() {}),
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: _t('Search contacts', 'পরিচিতি খুঁজুন'),
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: IconButton(
                        tooltip: _listening
                            ? _t('Stop voice search', 'ভয়েস খোঁজা থামান')
                            : _t('Search by voice', 'কথা বলে খুঁজুন'),
                        onPressed: _voiceSearch,
                        icon: Icon(_listening ? Icons.mic : Icons.mic_none),
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              Expanded(
                child: _manualEntry
                    ? _manualForm(context)
                    : _contactList(matches),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                child: OutlinedButton.icon(
                  onPressed: () {
                    setState(() {
                      _manualEntry = !_manualEntry;
                      _search.clear();
                    });
                  },
                  icon: Icon(
                    _manualEntry
                        ? Icons.search_rounded
                        : Icons.person_add_alt_1_rounded,
                  ),
                  label: Text(
                    _manualEntry
                        ? _t('Search phone contacts', 'ফোনের পরিচিতি খুঁজুন')
                        : _t(
                            'Enter a new name and number',
                            'নতুন নাম ও নম্বর লিখুন',
                          ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _contactList(List<Contact> matches) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_contacts.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _t(
              'No phone contacts available. Allow contact access or enter a new contact manually.',
              'ফোনে কোনো পরিচিতি পাওয়া যায়নি। অনুমতি দিন অথবা হাতে নতুন যোগাযোগ লিখুন।',
            ),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (matches.isEmpty) {
      return Center(
        child: Text(
          _t('No contacts match that search.', 'এই নামে কোনো পরিচিতি মেলেনি।'),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      itemCount: matches.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final contact = matches[index];
        final name = (contact.displayName ?? '').trim();
        final numbers = contact.phones
            .map((p) => p.number.trim())
            .where((p) => p.isNotEmpty)
            .toSet()
            .toList();
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: AppColors.primary.withValues(alpha: .12),
            foregroundColor: AppColors.primary,
            child: Text(
              name.isEmpty ? '#' : name.characters.first.toUpperCase(),
            ),
          ),
          title: Text(
            name.isEmpty ? _t('Unnamed contact', 'নামহীন পরিচিতি') : name,
          ),
          subtitle: Text(numbers.join(' · ')),
          trailing: const Icon(Icons.add_circle_outline_rounded),
          onTap: () => _selectContact(contact),
        );
      },
    );
  }

  Widget _manualForm(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
    children: [
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                labelText: _t('Name', 'নাম'),
                hintText: _t('e.g. Mother', 'যেমন মা'),
              ),
            ),
          ),
          const SizedBox(width: 8),
          VoiceDictateButton(
            controller: _name,
            language: widget.language,
            fieldLabel: _t('name', 'নাম'),
          ),
        ],
      ),
      const SizedBox(height: 14),
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(
                labelText: _t('Phone number', 'ফোন নম্বর'),
                hintText: _t('Enter the number', 'নম্বর লিখুন'),
              ),
            ),
          ),
          const SizedBox(width: 8),
          VoiceDictateButton(
            controller: _phone,
            language: widget.language,
            isPhoneNumber: true,
            fieldLabel: _t('phone number', 'ফোন নম্বর'),
          ),
        ],
      ),
      const SizedBox(height: 18),
      FilledButton.icon(
        onPressed: _saveManual,
        icon: const Icon(Icons.add_rounded),
        label: Text(_t('Add emergency contact', 'জরুরি যোগাযোগ যোগ করুন')),
      ),
    ],
  );
}
