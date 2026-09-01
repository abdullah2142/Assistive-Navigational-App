import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../onboarding/models/disability_profile_enums.dart';
import '../../onboarding/models/trusted_contact.dart';
import '../../onboarding/models/user_profile.dart';
import '../../onboarding/providers/onboarding_providers.dart';

/// Remote Management — the caretaker's standard settings menu for the
/// paired disabled user's [UserProfile], per UI module plan Step 3.4.
///
/// This is the deliberate *exception* to "No Settings Menus for Users":
/// caretakers aren't cognitively-load-constrained the way the disabled user
/// is, so they get direct field editing here instead of natural-language
/// function calling.
class RemoteManagementScreen extends ConsumerWidget {
  const RemoteManagementScreen({super.key, required this.disabledUserUid});

  final String disabledUserUid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profileAsync = ref.watch(profileStreamProvider(disabledUserUid));

    return Scaffold(
      appBar: AppBar(title: const Text('Remote Management')),
      body: profileAsync.when(
        data: (profile) {
          if (profile == null) {
            return const Center(child: Text('Profile not found.'));
          }
          return _RemoteManagementForm(profile: profile);
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => Center(child: Text('Couldn\'t load profile: $e')),
      ),
    );
  }
}

class _RemoteManagementForm extends ConsumerStatefulWidget {
  const _RemoteManagementForm({required this.profile});

  final UserProfile profile;

  @override
  ConsumerState<_RemoteManagementForm> createState() => _RemoteManagementFormState();
}

class _RemoteManagementFormState extends ConsumerState<_RemoteManagementForm> {
  late final _homeController = TextEditingController(text: widget.profile.homeAddress ?? '');
  late final _safePlaceController = TextEditingController(text: widget.profile.safePlaceAddress ?? '');
  final _contactNameController = TextEditingController();
  final _contactPhoneController = TextEditingController();
  // Local optimistic copy so the slider tracks the finger immediately —
  // driving `value` straight off `profile.fontScale` made it fight the drag,
  // since that only updates after a full Firestore round trip.
  late double _fontScale = widget.profile.fontScale;

  @override
  void dispose() {
    _homeController.dispose();
    _safePlaceController.dispose();
    _contactNameController.dispose();
    _contactPhoneController.dispose();
    super.dispose();
  }

  Future<void> _save(UserProfile updated) {
    return ref.read(profileServiceProvider).saveProfile(updated);
  }

  @override
  Widget build(BuildContext context) {
    final profile = widget.profile;
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _SectionCard(
          title: 'Vision',
          child: Wrap(
            spacing: 8,
            children: VisionLevel.values
                .map((level) => ChoiceChip(
                      label: Text(level.name),
                      selected: profile.visionLevel == level,
                      onSelected: (_) => _save(profile.copyWith(visionLevel: level)),
                    ))
                .toList(),
          ),
        ),
        _SectionCard(
          title: 'Text size',
          child: Row(
            children: [
              const Icon(Icons.text_fields_rounded, size: 18),
              Expanded(
                child: Slider(
                  value: _fontScale.clamp(0.8, 2.0),
                  min: 0.8,
                  max: 2.0,
                  divisions: 12,
                  label: '${_fontScale.toStringAsFixed(1)}x',
                  onChanged: (v) => setState(() => _fontScale = v),
                  onChangeEnd: (v) => _save(profile.copyWith(fontScale: v)),
                ),
              ),
              const Icon(Icons.text_fields_rounded, size: 28),
            ],
          ),
        ),
        _SectionCard(
          title: 'Mobility aid',
          child: Wrap(
            spacing: 8,
            children: MobilityAid.values
                .map((aid) => ChoiceChip(
                      label: Text(aid.name),
                      selected: profile.mobilityAid == aid,
                      onSelected: (_) => _save(profile.copyWith(mobilityAid: aid)),
                    ))
                .toList(),
          ),
        ),
        _SectionCard(
          title: 'Assistant verbosity',
          child: Wrap(
            spacing: 8,
            children: VerbosityLevel.values
                .map((v) => ChoiceChip(
                      label: Text(v.name),
                      selected: profile.verbosity == v,
                      onSelected: (_) => _save(profile.copyWith(verbosity: v)),
                    ))
                .toList(),
          ),
        ),
        _SectionCard(
          title: 'Magic Button contacts',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < profile.magicButtonContacts.length; i++)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(profile.magicButtonContacts[i].name),
                  subtitle: Text(profile.magicButtonContacts[i].phoneNumber),
                  trailing: IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () {
                      final updated = List<TrustedContact>.from(profile.magicButtonContacts)..removeAt(i);
                      _save(profile.copyWith(magicButtonContacts: updated));
                    },
                  ),
                ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _contactNameController,
                      decoration: const InputDecoration(hintText: 'Name'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _contactPhoneController,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(hintText: 'Phone'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () {
                  if (_contactNameController.text.trim().isEmpty ||
                      _contactPhoneController.text.trim().isEmpty) {
                    return;
                  }
                  final updated = [
                    ...profile.magicButtonContacts,
                    TrustedContact(
                      name: _contactNameController.text.trim(),
                      phoneNumber: _contactPhoneController.text.trim(),
                    ),
                  ];
                  _save(profile.copyWith(magicButtonContacts: updated));
                  _contactNameController.clear();
                  _contactPhoneController.clear();
                },
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add contact'),
              ),
            ],
          ),
        ),
        _SectionCard(
          title: 'Safe havens',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _homeController,
                decoration: const InputDecoration(labelText: 'Home address'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _safePlaceController,
                decoration: const InputDecoration(labelText: 'Safe place (optional)'),
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: () => _save(profile.copyWith(
                  homeAddress: _homeController.text.trim(),
                  safePlaceAddress:
                      _safePlaceController.text.trim().isEmpty ? null : _safePlaceController.text.trim(),
                )),
                child: const Text('Save addresses'),
              ),
            ],
          ),
        ),
        Text(
          'Changes here save immediately and sync to the paired device.',
          style: theme.textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(header: true, child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}
