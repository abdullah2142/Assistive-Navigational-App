import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_language.dart';
import '../../../core/localization/dashboard_strings.dart';
import '../../../core/localization/onboarding_strings.dart';
import '../../../core/providers/ai_assistant_providers.dart';
import '../../../core/services/stt_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/ai_text_summarizer.dart';
import '../../onboarding/models/disability_profile_enums.dart';
import '../../onboarding/models/trusted_contact.dart';
import '../../onboarding/models/user_profile.dart';
import '../../onboarding/providers/onboarding_providers.dart';
import '../../onboarding/services/pairing_service.dart';
import '../widgets/wake_word_sensitivity_tile.dart';

/// The two voices, named for the language the profile is actually set to.
///
/// Was a const list hardcoded to "Bangla", so an English user's settings
/// offered "Bangla — Female voice" and "Bangla — Male voice" — seen on
/// device. The onboarding screen had the same defect and was fixed there;
/// this screen keeps its own copy of the list, so it needed fixing twice.
List<(String, String, String)> _voiceOptionsFor(AppLanguage language) {
  final english = language == AppLanguage.bangla ? 'বাংলা' : 'English';
  return [
    (voiceIdFor(language, female: true), '$english — Female voice', '$english — নারী কণ্ঠ'),
    (voiceIdFor(language, female: false), '$english — Male voice', '$english — পুরুষ কণ্ঠ'),
  ];
}

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
  late final _homeController = TextEditingController(
    text: widget.profile.homeAddress ?? '',
  );
  late final _safePlaceController = TextEditingController(
    text: widget.profile.safePlaceAddress ?? '',
  );
  final _contactNameController = TextEditingController();
  final _contactPhoneController = TextEditingController();
  final _messageController = TextEditingController();
  final _pairingCodeController = TextEditingController();
  bool _pairingBusy = false;
  String? _pairingError;
  // Local optimistic copy so the slider tracks the finger immediately —
  // driving `value` straight off `profile.fontScale` made it fight the drag,
  // since that only updates after a full Firestore round trip.
  late double _fontScale = widget.profile.fontScale;
  bool _listening = false;

  // Captured once, here, rather than `ref.read` inside `dispose()` — `ref`
  // is unsafe to use once a widget is unmounting (a real crash this caused
  // live: "Bad state: Using 'ref' when a widget is about to or has been
  // unmounted is unsafe").
  late final SttService _stt = ref.read(sttServiceProvider);

  @override
  void initState() {
    super.initState();
    // Forces the lazy `late final _stt` initializer to run now, while `ref`
    // is still safe to use — otherwise, if the mic button on this screen is
    // never tapped, `dispose()` ends up being the *first* access, which is
    // exactly the unsafe-`ref` crash this field was introduced to avoid
    // (confirmed live: leaving this screen without touching the mic).
    _stt;
    _messageController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _stt.stop();
    _homeController.dispose();
    _safePlaceController.dispose();
    _contactNameController.dispose();
    _contactPhoneController.dispose();
    _messageController.dispose();
    _pairingCodeController.dispose();
    super.dispose();
  }

  /// Sends the user back to the first onboarding question.
  ///
  /// Confirmed first, because it is reachable by voice and by touch on a
  /// screen the user may not be able to see, and because landing back in
  /// onboarding unexpectedly is disorienting in a way a settings toggle is
  /// not. `AppRoot` watches `onboardingComplete` on the profile stream, so
  /// clearing it is all that is needed — no navigation call, no route stack
  /// to unwind.
  Future<void> _confirmRedoOnboarding(Dashboard d, UserProfile profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(d.settingsRedoOnboardingConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(d.settingsRedoOnboardingCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(d.settingsRedoOnboardingButton),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _save(profile.copyWith(onboardingComplete: false));
  }

  Future<void> _save(UserProfile updated) {
    return ref.read(profileServiceProvider).saveProfile(updated);
  }

  Future<void> _submitPairingCode(UserProfile profile, Dashboard d) async {
    final code = _pairingCodeController.text.trim();
    if (code.length != 6) return;
    setState(() {
      _pairingBusy = true;
      _pairingError = null;
    });
    try {
      final caretakerUid = await ref
          .read(pairingServiceProvider)
          .redeemCode(code: code, disabledUserUid: profile.uid);
      await _save(profile.copyWith(pairedUserId: caretakerUid));
      _pairingCodeController.clear();
    } on PairingException catch (e) {
      final msg = e.message;
      setState(() {
        if (msg.contains('not found')) {
          _pairingError = d.settingsPairingErrorNotFound;
        } else if (msg.contains('expired')) {
          _pairingError = d.settingsPairingErrorExpired;
        } else if (msg.contains('already been used')) {
          _pairingError = d.settingsPairingErrorUsed;
        } else {
          _pairingError = d.settingsPairingErrorGeneric;
        }
      });
    } finally {
      if (mounted) setState(() => _pairingBusy = false);
    }
  }

  Future<void> _toggleListening(Dashboard d, AppLanguage language) async {
    if (_listening) {
      await _stt.stop();
      setState(() => _listening = false);
      return;
    }
    if (!await _stt.ensureAvailable()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(d.chatVoiceUnavailable)));
      return;
    }
    setState(() => _listening = true);
    await _stt.listenOnce(
      language: language,
      onResult: (text, isFinal) {
        // `mounted` must gate the whole callback, not just the final
        // `setState` — a pending listen session can still deliver a result
        // after this widget is gone (same crash class confirmed live in
        // the passerby message picker: writing into a disposed controller).
        if (!mounted) return;
        _messageController.text = text;
        _messageController.selection = TextSelection.collapsed(
          offset: text.length,
        );
        if (isFinal) setState(() => _listening = false);
      },
    );
    if (mounted) setState(() => _listening = false);
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

    // Live preview: the actual persisted `fontScale` only reaches the rest
    // of the app after a Firestore round trip (`onChangeEnd`), so without
    // this override dragging the slider looked like it did nothing — the
    // slider thumb moved, but no text on screen visibly changed size. This
    // reflows every bit of text on the settings screen itself, in real
    // time, off the same local `_fontScale` the slider already drives.
    //
    // Scaled *relative to the currently-persisted* `profile.fontScale`, not
    // as an absolute multiplier — the theme's own text styles already bake
    // fontScale in (see `app_theme.dart`), so applying the raw slider value
    // again here would double-apply it the moment the Firestore save lands
    // and the app-wide theme catches up (confirmed: made this screen's text
    // balloon far past the dashboard's, since only this screen stacked the
    // two). The ratio is 1.0 (no-op) once `profile.fontScale` matches
    // `_fontScale`, and only deviates from 1.0 during an active, unsaved
    // drag.
    return MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(_fontScale.clamp(0.8, 2.0) / profile.fontScale)),
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _SectionCard(
            title: d.settingsVisionSection,
            child: Wrap(
              spacing: 8,
              children: VisionLevel.values
                  .map(
                    (level) => Semantics(
                      button: true,
                      selected: profile.visionLevel == level,
                      label: o.visionLevelLabel(level),
                      child: ChoiceChip(
                        label: Text(o.visionLevelLabel(level)),
                        selected: profile.visionLevel == level,
                        onSelected: (_) =>
                            _save(profile.copyWith(visionLevel: level)),
                      ),
                    ),
                  )
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
                  .map(
                    (t) => Semantics(
                      button: true,
                      selected: profile.themePreference == t,
                      label: o.themePreferenceLabel(t),
                      child: ChoiceChip(
                        label: Text(o.themePreferenceLabel(t)),
                        selected: profile.themePreference == t,
                        onSelected: (_) =>
                            _save(profile.copyWith(themePreference: t)),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
          _SectionCard(
            title: d.settingsLanguageSection,
            child: Wrap(
              spacing: 8,
              children: AppLanguage.values
                  .map(
                    (lang) => Semantics(
                      button: true,
                      selected: profile.language == lang,
                      label: d.languageLabel(lang),
                      child: ChoiceChip(
                        label: Text(d.languageLabel(lang)),
                        selected: profile.language == lang,
                        onSelected: (_) =>
                            _save(profile.copyWith(language: lang)),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
          if (profile.pairedUserId == null)
            _SectionCard(
              title: d.settingsPairingSection,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(d.settingsPairingIntro),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _pairingCodeController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(6),
                    ],
                    decoration: InputDecoration(
                      labelText: d.settingsPairingCodeHint,
                    ),
                    onChanged: (_) => setState(() {}),
                    enabled: !_pairingBusy,
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    onPressed:
                        _pairingBusy ||
                            _pairingCodeController.text.trim().length != 6
                        ? null
                        : () => _submitPairingCode(profile, d),
                    child: _pairingBusy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(d.settingsPairingButton),
                  ),
                  if (_pairingError != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _pairingError!,
                      style: const TextStyle(color: AppColors.danger),
                    ),
                  ],
                ],
              ),
            )
          else
            _SectionCard(
              title: d.settingsPairingSection,
              child: Consumer(
                builder: (context, ref, _) {
                  final caretaker = ref.watch(
                    profileStreamProvider(profile.pairedUserId!),
                  );
                  final name = caretaker.value?.displayName ?? '';
                  return Text(d.settingsPairedWithLabel(name));
                },
              ),
            ),
          _SectionCard(
            title: d.settingsTextSizeSection,
            child: Row(
              children: [
                const Icon(Icons.text_fields_rounded, size: 18),
                Expanded(
                  child: Semantics(
                    label: d.settingsTextSizeSemantics(
                      _fontScale.toStringAsFixed(1),
                    ),
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
                  .map(
                    (aid) => Semantics(
                      button: true,
                      selected: profile.mobilityAid == aid,
                      label: o.mobilityAidLabel(aid),
                      child: ChoiceChip(
                        label: Text(o.mobilityAidLabel(aid)),
                        selected: profile.mobilityAid == aid,
                        onSelected: (_) =>
                            _save(profile.copyWith(mobilityAid: aid)),
                      ),
                    ),
                  )
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
                  onChanged: (v) =>
                      _save(profile.copyWith(crowdedPlacesAnxious: v)),
                ),
                const SizedBox(height: 10),
                _SwitchRow(
                  label: d.settingsComplexSwitch,
                  value: profile.complexInstructionsHard,
                  onChanged: (v) =>
                      _save(profile.copyWith(complexInstructionsHard: v)),
                ),
              ],
            ),
          ),
          _SectionCard(
            title: d.settingsSavedPlacesSection,
            child: profile.savedPlaces.isEmpty
                ? Text(d.settingsSavedPlacesEmpty)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final place in profile.savedPlaces)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(place.label),
                          subtitle: Text(
                            place.address.isNotEmpty
                                ? place.address
                                : place.hasCoordinates
                                    ? '${place.lat!.toStringAsFixed(4)}, ${place.lng!.toStringAsFixed(4)}'
                                    : d.settingsSavedPlaceNoAddress,
                          ),
                          trailing: Semantics(
                            button: true,
                            label: d.settingsSavedPlaceRemoveSemantics(place.label),
                            child: IconButton(
                              icon: const Icon(Icons.delete_outline_rounded),
                              onPressed: () => _save(
                                profile.copyWith(
                                  savedPlaces: profile.savedPlaces
                                      .where((p) => p.label != place.label)
                                      .toList(),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
          _SectionCard(
            title: d.settingsDeafSection,
            child: _SwitchRow(
              label: d.settingsDeafSwitch,
              value: profile.isDeafOrHardOfHearing,
              onChanged: (v) =>
                  _save(profile.copyWith(isDeafOrHardOfHearing: v)),
            ),
          ),
          _SectionCard(
            title: d.settingsVerbositySection,
            child: Wrap(
              spacing: 8,
              children: VerbosityLevel.values
                  .map(
                    (v) => Semantics(
                      button: true,
                      selected: profile.verbosity == v,
                      label: o.verbosityLevelLabel(v),
                      child: ChoiceChip(
                        label: Text(o.verbosityLevelLabel(v)),
                        selected: profile.verbosity == v,
                        onSelected: (_) =>
                            _save(profile.copyWith(verbosity: v)),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
          _SectionCard(
            title: d.settingsVoiceSection,
            child: Wrap(
              spacing: 8,
              children: _voiceOptionsFor(profile.language)
                  .map(
                    (option) => Semantics(
                      button: true,
                      selected: profile.voiceId == option.$1,
                      label: profile.language == AppLanguage.bangla
                          ? option.$3
                          : option.$2,
                      child: ChoiceChip(
                        label: Text(
                          profile.language == AppLanguage.bangla
                              ? option.$3
                              : option.$2,
                        ),
                        selected: profile.voiceId == option.$1,
                        onSelected: (_) =>
                            _save(profile.copyWith(voiceId: option.$1)),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
          _SectionCard(
            title: d.settingsWakeWordSection,
            child: _SwitchRow(
              label: d.settingsWakeWordSwitch,
              value: profile.wakeWordEnabled,
              onChanged: (v) => _save(profile.copyWith(wakeWordEnabled: v)),
            ),
          ),
          _SectionCard(
            title: d.settingsWakeWordSensitivitySection,
            child: WakeWordSensitivityTile(
              threshold: profile.wakeWordThreshold,
              enabled: profile.wakeWordEnabled,
              strings: d,
              // Applied to the live detector immediately and saved alongside,
              // rather than waiting for the profile stream to come back round
              // — a tester saying the phrase again straight away should be
              // testing the value they just set, not the one before it.
              onChanged: (threshold) {
                ref.read(wakeWordServiceProvider).threshold = threshold;
                _save(profile.copyWith(wakeWordThreshold: threshold));
              },
            ),
          ),
          _SectionCard(
            title: d.settingsAutoListenSection,
            child: _SwitchRow(
              label: d.settingsAutoListenSwitch,
              value: profile.voiceAutoListen,
              onChanged: (v) => _save(profile.copyWith(voiceAutoListen: v)),
            ),
          ),
          _SectionCard(
            title: o.lockInSnapshotLabel,
            child: Wrap(
              spacing: 8,
              children: SnapshotConsentPreference.values
                  .map(
                    (pref) => Semantics(
                      button: true,
                      selected: profile.snapshotConsent == pref,
                      label: o.snapshotConsentLabel(pref),
                      child: ChoiceChip(
                        label: Text(o.snapshotConsentLabel(pref)),
                        selected: profile.snapshotConsent == pref,
                        onSelected: (_) =>
                            _save(profile.copyWith(snapshotConsent: pref)),
                      ),
                    ),
                  )
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
                      label: d.settingsRemoveContactSemantics(
                        profile.magicButtonContacts[i].name,
                      ),
                      child: IconButton(
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () {
                          final updated = List<TrustedContact>.from(
                            profile.magicButtonContacts,
                          )..removeAt(i);
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
                        decoration: InputDecoration(
                          hintText: d.settingsNamePlaceholder,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _contactPhoneController,
                        keyboardType: TextInputType.phone,
                        decoration: InputDecoration(
                          hintText: d.settingsPhonePlaceholder,
                        ),
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
                          final updated = List<String>.from(
                            profile.passerbyHelperMessages,
                          )..removeAt(i);
                          _save(
                            profile.copyWith(passerbyHelperMessages: updated),
                          );
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
                          decoration: InputDecoration(
                            hintText: d.settingsWriteMessageHint,
                          ),
                          onSubmitted: (_) => _addMessage(profile),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Semantics(
                      button: true,
                      label: _listening
                          ? d.chatListeningSemantics
                          : d.settingsSpeakMessageSemantics,
                      hint: d.chatSpeakHint,
                      liveRegion: _listening,
                      child: Material(
                        color: _listening
                            ? theme.colorScheme.error
                            : theme.colorScheme.primary,
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => _toggleListening(d, profile.language),
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Icon(
                              _listening
                                  ? Icons.mic_off_rounded
                                  : Icons.mic_rounded,
                              color: Colors.white,
                            ),
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
                      label:
                          '${o.passerbyAiSummaryLabel}: ${summarizeText(_messageController.text)}',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.auto_awesome_rounded,
                                size: 16,
                                color: theme.colorScheme.primary,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                o.passerbyAiSummaryLabel,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            summarizeText(_messageController.text),
                            style: theme.textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _messageController.text.trim().isEmpty
                      ? null
                      : () => _addMessage(profile),
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
                  decoration: InputDecoration(
                    labelText: d.settingsSafePlaceLabel,
                  ),
                ),
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: () => _save(
                    profile.copyWith(
                      homeAddress: _homeController.text.trim(),
                      safePlaceAddress: _safePlaceController.text.trim().isEmpty
                          ? null
                          : _safePlaceController.text.trim(),
                    ),
                  ),
                  child: Text(d.settingsSaveAddressesButton),
                ),
              ],
            ),
          ),
          // Redo onboarding. Testers who reached the dashboard had no way back
          // into the setup flow except uninstalling and reinstalling, which
          // costs a testing round rather than a minute. Only clears the
          // completion flag — every answer already given is kept, so this is
          // a re-run, not a wipe.
          _SectionCard(
            title: d.settingsRedoOnboardingSection,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  d.settingsRedoOnboardingExplain,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.restart_alt_rounded),
                  label: Text(d.settingsRedoOnboardingButton),
                  onPressed: () => _confirmRedoOnboarding(d, profile),
                ),
              ],
            ),
          ),
          Text(
            d.settingsFooterNote,
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppColors.textSecondary,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

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
          Expanded(
            child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
          ),
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
          Semantics(
            header: true,
            child: Text(title, style: Theme.of(context).textTheme.titleMedium),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}
