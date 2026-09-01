import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_language.dart';
import '../../../core/localization/dashboard_strings.dart';
import '../../../core/localization/onboarding_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/ai_text_summarizer.dart';
import '../../onboarding/models/disability_profile_enums.dart';
import '../../onboarding/models/trusted_contact.dart';
import '../../onboarding/models/user_profile.dart';
import '../../onboarding/providers/onboarding_providers.dart';

const _voiceOptions = [
  ('bn-BD-female-1', 'Bangla — Female voice', 'বাংলা — নারী কণ্ঠ'),
  ('bn-BD-male-1', 'Bangla — Male voice', 'বাংলা — পুরুষ কণ্ঠ'),
];

/// Self-service settings for the Disabled User themselves — a deliberate,
/// narrow exception to "No Settings Menus for Users."
///
/// The architecture calls for settings changes to happen only through
/// natural-language AI chat (Module 3's Gemini function calling) or through
/// a paired Caretaker's Remote Management screen. Neither exists yet for
/// someone using ANT alone: Module 3 isn't built, and a person with no
/// caretaker has no Remote Management screen acting on their behalf. This
/// screen is that bridge — everything set during onboarding, reachable and
/// editable again, for exactly the person the "no caretaker" path is for.
/// It can shrink or disappear once Module 3 makes chat-driven changes a
/// real alternative for everyone, not just those with someone to lean on.
class MySettingsScreen extends ConsumerWidget {
  const MySettingsScreen({super.key, required this.profile});

  final UserProfile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profileAsync = ref.watch(profileStreamProvider(profile.uid));
    final d = Dashboard.of(profile.language);

    return Scaffold(
      appBar: AppBar(title: Text(d.settingsTitle)),
      body: profileAsync.when(
        data: (latest) => _MySettingsForm(profile: latest ?? profile),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => Center(child: Text('${d.settingsCouldNotLoad}: $e')),
      ),
    );
  }
}

class _MySettingsForm extends ConsumerStatefulWidget {
  const _MySettingsForm({required this.profile});

  final UserProfile profile;

  @override
  ConsumerState<_MySettingsForm> createState() => _MySettingsFormState();
}

class _MySettingsFormState extends ConsumerState<_MySettingsForm> {
  late final _homeController = TextEditingController(text: widget.profile.homeAddress ?? '');
  late final _safePlaceController = TextEditingController(text: widget.profile.safePlaceAddress ?? '');
  final _contactNameController = TextEditingController();
  final _contactPhoneController = TextEditingController();
  final _messageController = TextEditingController();
  // Local optimistic copy so the slider tracks the finger immediately —
  // driving `value` straight off `profile.fontScale` made it fight the drag,
  // since that only updates after a full Firestore round trip.
  late double _fontScale = widget.profile.fontScale;

  @override
  void initState() {
    super.initState();
    _messageController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _homeController.dispose();
    _safePlaceController.dispose();
    _contactNameController.dispose();
    _contactPhoneController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _save(UserProfile updated) {
    return ref.read(profileServiceProvider).saveProfile(updated);
  }

  void _promptVoiceUnavailable(Dashboard d) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(d.chatVoiceUnavailable)));
  }

  void _addMessage(UserProfile profile) {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    final updated = [...profile.passerbyHelperMessages, summarizeText(text)];
    _save(profile.copyWith(passerbyHelperMessages: updated));
    _messageController.clear();
  }

  @override
  Widget build(BuildContext context) {
    final profile = widget.profile;
    final theme = Theme.of(context);
    final d = Dashboard.of(profile.language);
    final o = Onboarding.of(profile.language);

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _SectionCard(
          title: d.settingsVisionSection,
          child: Wrap(
            spacing: 8,
            children: VisionLevel.values
                .map((level) => Semantics(
                      button: true,
                      selected: profile.visionLevel == level,
                      label: o.visionLevelLabel(level),
                      child: ChoiceChip(
                        label: Text(o.visionLevelLabel(level)),
                        selected: profile.visionLevel == level,
                        onSelected: (_) => _save(profile.copyWith(visionLevel: level)),
                      ),
                    ))
                .toList(),
          ),
        ),
        // Independent of Vision — a Low Vision user still picks Light/Dark
        // like anyone else and gets the matching high-contrast variant
        // (see theme_resolver.dart), not one theme forced regardless.
        _SectionCard(
          title: d.settingsThemeSection,
          child: Wrap(
            spacing: 8,
            children: ThemePreference.values
                .map((t) => Semantics(
                      button: true,
                      selected: profile.themePreference == t,
                      label: o.themePreferenceLabel(t),
                      child: ChoiceChip(
                        label: Text(o.themePreferenceLabel(t)),
                        selected: profile.themePreference == t,
                        onSelected: (_) => _save(profile.copyWith(themePreference: t)),
                      ),
                    ))
                .toList(),
          ),
        ),
        _SectionCard(
          title: d.settingsLanguageSection,
          child: Wrap(
            spacing: 8,
            children: AppLanguage.values
                .map((lang) => Semantics(
                      button: true,
                      selected: profile.language == lang,
                      label: d.languageLabel(lang),
                      child: ChoiceChip(
                        label: Text(d.languageLabel(lang)),
                        selected: profile.language == lang,
                        onSelected: (_) => _save(profile.copyWith(language: lang)),
                      ),
                    ))
                .toList(),
          ),
        ),
        _SectionCard(
          title: d.settingsTextSizeSection,
          child: Row(
            children: [
              const Icon(Icons.text_fields_rounded, size: 18),
              Expanded(
                child: Semantics(
                  label: d.settingsTextSizeSemantics(_fontScale.toStringAsFixed(1)),
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
              ),
              const Icon(Icons.text_fields_rounded, size: 28),
            ],
          ),
        ),
        _SectionCard(
          title: d.settingsMobilitySection,
          child: Wrap(
            spacing: 8,
            children: MobilityAid.values
                .map((aid) => Semantics(
                      button: true,
                      selected: profile.mobilityAid == aid,
                      label: o.mobilityAidLabel(aid),
                      child: ChoiceChip(
                        label: Text(o.mobilityAidLabel(aid)),
                        selected: profile.mobilityAid == aid,
                        onSelected: (_) => _save(profile.copyWith(mobilityAid: aid)),
                      ),
                    ))
                .toList(),
          ),
        ),
        _SectionCard(
          title: d.settingsCognitiveSection,
          child: Column(
            children: [
              _SwitchRow(
                label: d.settingsCrowdedSwitch,
                value: profile.crowdedPlacesAnxious,
                onChanged: (v) => _save(profile.copyWith(crowdedPlacesAnxious: v)),
              ),
              const SizedBox(height: 10),
              _SwitchRow(
                label: d.settingsComplexSwitch,
                value: profile.complexInstructionsHard,
                onChanged: (v) => _save(profile.copyWith(complexInstructionsHard: v)),
              ),
            ],
          ),
        ),
        _SectionCard(
          title: d.settingsDeafSection,
          child: _SwitchRow(
            label: d.settingsDeafSwitch,
            value: profile.isDeafOrHardOfHearing,
            onChanged: (v) => _save(profile.copyWith(isDeafOrHardOfHearing: v)),
          ),
        ),
        _SectionCard(
          title: d.settingsVerbositySection,
          child: Wrap(
            spacing: 8,
            children: VerbosityLevel.values
                .map((v) => Semantics(
                      button: true,
                      selected: profile.verbosity == v,
                      label: o.verbosityLevelLabel(v),
                      child: ChoiceChip(
                        label: Text(o.verbosityLevelLabel(v)),
                        selected: profile.verbosity == v,
                        onSelected: (_) => _save(profile.copyWith(verbosity: v)),
                      ),
                    ))
                .toList(),
          ),
        ),
        _SectionCard(
          title: d.settingsVoiceSection,
          child: Wrap(
            spacing: 8,
            children: _voiceOptions
                .map((option) => Semantics(
                      button: true,
                      selected: profile.voiceId == option.$1,
                      label: profile.language == AppLanguage.bangla ? option.$3 : option.$2,
                      child: ChoiceChip(
                        label: Text(profile.language == AppLanguage.bangla ? option.$3 : option.$2),
                        selected: profile.voiceId == option.$1,
                        onSelected: (_) => _save(profile.copyWith(voiceId: option.$1)),
                      ),
                    ))
                .toList(),
          ),
        ),
        _SectionCard(
          title: o.lockInSnapshotLabel,
          child: Wrap(
            spacing: 8,
            children: SnapshotConsentPreference.values
                .map((pref) => Semantics(
                      button: true,
                      selected: profile.snapshotConsent == pref,
                      label: o.snapshotConsentLabel(pref),
                      child: ChoiceChip(
                        label: Text(o.snapshotConsentLabel(pref)),
                        selected: profile.snapshotConsent == pref,
                        onSelected: (_) => _save(profile.copyWith(snapshotConsent: pref)),
                      ),
                    ))
                .toList(),
          ),
        ),
        _SectionCard(
          title: d.settingsContactsSection,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < profile.magicButtonContacts.length; i++)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(profile.magicButtonContacts[i].name),
                  subtitle: Text(profile.magicButtonContacts[i].phoneNumber),
                  trailing: Semantics(
                    button: true,
                    label: d.settingsRemoveContactSemantics(profile.magicButtonContacts[i].name),
                    child: IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () {
                        final updated = List<TrustedContact>.from(profile.magicButtonContacts)..removeAt(i);
                        _save(profile.copyWith(magicButtonContacts: updated));
                      },
                    ),
                  ),
                ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _contactNameController,
                      decoration: InputDecoration(hintText: d.settingsNamePlaceholder),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _contactPhoneController,
                      keyboardType: TextInputType.phone,
                      decoration: InputDecoration(hintText: d.settingsPhonePlaceholder),
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
                label: Text(d.settingsAddContactButton),
              ),
            ],
          ),
        ),
        _SectionCard(
          title: d.settingsMessagesSection,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < profile.passerbyHelperMessages.length; i++)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(profile.passerbyHelperMessages[i]),
                  trailing: Semantics(
                    button: true,
                    label: d.settingsRemoveMessageSemantics,
                    child: IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () {
                        final updated = List<String>.from(profile.passerbyHelperMessages)..removeAt(i);
                        _save(profile.copyWith(passerbyHelperMessages: updated));
                      },
                    ),
                  ),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Semantics(
                      textField: true,
                      label: d.settingsWriteMessageSemantics,
                      child: TextField(
                        controller: _messageController,
                        decoration: InputDecoration(hintText: d.settingsWriteMessageHint),
                        onSubmitted: (_) => _addMessage(profile),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Semantics(
                    button: true,
                    label: d.settingsSpeakMessageSemantics,
                    hint: d.chatSpeakHint,
                    child: Material(
                      color: theme.colorScheme.primary,
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () => _promptVoiceUnavailable(d),
                        child: const Padding(
                          padding: EdgeInsets.all(14),
                          child: Icon(Icons.mic_rounded, color: Colors.white),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              if (_messageController.text.trim().isNotEmpty) ...[
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Semantics(
                    liveRegion: true,
                    label: '${o.passerbyAiSummaryLabel}: ${summarizeText(_messageController.text)}',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.auto_awesome_rounded, size: 16, color: theme.colorScheme.primary),
                            const SizedBox(width: 6),
                            Text(
                              o.passerbyAiSummaryLabel,
                              style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.primary),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(summarizeText(_messageController.text), style: theme.textTheme.bodyMedium),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _messageController.text.trim().isEmpty ? null : () => _addMessage(profile),
                icon: const Icon(Icons.add_rounded),
                label: Text(d.settingsAddMessageButton),
              ),
            ],
          ),
        ),
        _SectionCard(
          title: d.settingsHavensSection,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _homeController,
                decoration: InputDecoration(labelText: d.settingsHomeLabel),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _safePlaceController,
                decoration: InputDecoration(labelText: d.settingsSafePlaceLabel),
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: () => _save(profile.copyWith(
                  homeAddress: _homeController.text.trim(),
                  safePlaceAddress:
                      _safePlaceController.text.trim().isEmpty ? null : _safePlaceController.text.trim(),
                )),
                child: Text(d.settingsSaveAddressesButton),
              ),
            ],
          ),
        ),
        Text(
          d.settingsFooterNote,
          style: theme.textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({required this.label, required this.value, required this.onChanged});

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      toggled: value,
      label: label,
      child: Row(
        children: [
          Expanded(child: Text(label, style: Theme.of(context).textTheme.bodyMedium)),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
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
