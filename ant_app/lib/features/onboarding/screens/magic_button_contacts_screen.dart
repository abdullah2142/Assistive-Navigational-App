import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../models/trusted_contact.dart';
import '../providers/onboarding_providers.dart';
import '../widgets/onboarding_scaffold.dart';

class MagicButtonContactsScreen extends ConsumerStatefulWidget {
  const MagicButtonContactsScreen({super.key});

  @override
  ConsumerState<MagicButtonContactsScreen> createState() => _MagicButtonContactsScreenState();
}

class _MagicButtonContactsScreenState extends ConsumerState<MagicButtonContactsScreen> {
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  void _addContact(OnboardingController controller) {
    if (_nameController.text.trim().isEmpty || _phoneController.text.trim().isEmpty) return;
    controller.addContact(TrustedContact(
      name: _nameController.text.trim(),
      phoneNumber: _phoneController.text.trim(),
    ));
    _nameController.clear();
    _phoneController.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(onboardingControllerProvider);
    final controller = ref.read(onboardingControllerProvider.notifier);
    final contacts = state.profile?.magicButtonContacts ?? const [];

    return OnboardingScaffold(
      title: 'Who should we contact in an emergency?',
      subtitle: 'Add at least one trusted contact. They\'ll get an SMS with your location if you press the Magic Button.',
      onBack: controller.goBack,
      primaryActionLabel: 'Continue',
      onPrimaryAction: controller.continueFromContacts,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < contacts.length; i++)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              elevation: 0,
              color: Theme.of(context).colorScheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: const BorderSide(color: AppColors.divider),
              ),
              child: ListTile(
                title: Text(contacts[i].name),
                subtitle: Text(contacts[i].phoneNumber),
                trailing: Semantics(
                  label: 'Remove ${contacts[i].name}',
                  button: true,
                  child: IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => controller.removeContact(i),
                  ),
                ),
              ),
            ),
          const SizedBox(height: 8),
          Semantics(
            textField: true,
            label: 'Contact name',
            child: TextField(
              controller: _nameController,
              decoration: const InputDecoration(hintText: 'Name (e.g. Mother)'),
            ),
          ),
          const SizedBox(height: 12),
          Semantics(
            textField: true,
            label: 'Contact phone number',
            child: TextField(
              controller: _phoneController,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(hintText: 'Phone number'),
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => _addContact(controller),
            icon: const Icon(Icons.add_rounded),
            label: const Text('Add contact'),
          ),
          if (state.errorMessage != null) ...[
            const SizedBox(height: 12),
            Text(state.errorMessage!, style: const TextStyle(color: AppColors.danger)),
          ],
        ],
      ),
    );
  }
}
