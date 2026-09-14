import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_language.dart';
import '../../../core/localization/onboarding_strings.dart';
import '../../../core/providers/ai_assistant_providers.dart';
import '../../../core/providers/tts_providers.dart';
import '../../../core/services/saved_place_matcher.dart';
import '../../../core/services/dhaka_places.dart';
import '../../../core/services/stt_service.dart';
import '../../../core/services/tts_service.dart';
import '../../../core/theme/app_colors.dart';
import '../models/saved_place.dart';
import '../providers/onboarding_providers.dart';
import '../widgets/onboarding_scaffold.dart';
import '../widgets/onboarding_voice.dart';
import '../widgets/voice_confirm.dart';
import '../widgets/voice_dictate_button.dart';

/// Collects the places this user goes to often, so afterwards they can say
/// "take me to work" instead of reciting an address.
///
/// **Optional, and genuinely so.** It sits near the end of a long
/// accessibility interview, and a user who just wants to finish must be
/// able to say "skip" and move on — the same information can be captured
/// far more accurately later by saying "save this as my office" while
/// actually standing there, which also gets real coordinates instead of an
/// address string that may not geocode.
class FrequentPlacesScreen extends ConsumerStatefulWidget {
  const FrequentPlacesScreen({super.key});

  @override
  ConsumerState<FrequentPlacesScreen> createState() => _FrequentPlacesScreenState();
}

class _FrequentPlacesScreenState extends ConsumerState<FrequentPlacesScreen> {
  final List<SavedPlace> _places = [];
  final _nameController = TextEditingController();
  final _addressController = TextEditingController();
  bool _disposed = false;
  bool _voiceStarted = false;

  // See `LanguageSelectionScreen`'s identical fields for why these are
  // `late final` captures rather than `ref.read` inside `dispose()`.
  late final TtsService _tts = ref.read(ttsServiceProvider);
  late final SttService _stt = ref.read(sttServiceProvider);

  @override
  void initState() {
    super.initState();
    _tts;
    _stt;
    WidgetsBinding.instance.addPostFrameCallback((_) => _introAndListen());
  }

  @override
  void dispose() {
    _disposed = true;
    _stt.stop();
    _tts.stop();
    _nameController.dispose();
    _addressController.dispose();
    super.dispose();
  }

  Future<void> _introAndListen() async {
    if (_disposed || !ref.read(ttsEnabledProvider)) return;
    final language = ref.read(onboardingControllerProvider).profile!.language;
    final s = Onboarding.of(language);
    // Full narration before the mic opens, including that this step can be
    // skipped — a user who has no places to add must hear that up front
    // rather than discovering it after being asked twice.
    await _tts.speak(
      [s.placesTitle, s.placesSubtitle, s.placesSpokenHint].join('. '),
      language: language,
    );
    if (_disposed || !ref.read(ttsEnabledProvider) || _voiceStarted) return;
    _voiceStarted = true;
    await _voiceLoop(s, language);
  }

  /// name -> address -> save -> "another or done", repeating. Mirrors the
  /// emergency-contacts loop, including reading each dictated value back
  /// before it is committed.
  Future<void> _voiceLoop(Onboarding s, AppLanguage language) async {
    final myGeneration = ref.read(onboardingControllerProvider).stepGeneration;
    bool cancelled() =>
        _disposed || ref.read(onboardingControllerProvider).stepGeneration != myGeneration;

    while (!cancelled()) {
      final name = await _dictate(
        prompt: s.placesNamePromptSpoken,
        fieldLabel: s.placesNameLabel,
        language: language,
        skipWords: s.placesSkipSynonyms,
        cancelled: cancelled,
      );
      if (cancelled()) return;
      if (name == null) {
        // "skip"/"done" at the name prompt ends the step, keeping whatever
        // was already added.
        _finish();
        return;
      }

      final address = await _dictate(
        prompt: s.placesAddressPromptSpoken,
        fieldLabel: s.placesAddressLabel,
        language: language,
        skipWords: s.placesSkipSynonyms,
        cancelled: cancelled,
      );
      if (cancelled()) return;
      if (address == null) {
        // A place with a name but no address cannot be routed to, so
        // there is nothing worth saving — drop it rather than storing a
        // label that fails confusingly weeks later.
        _finish();
        return;
      }

      setState(() => _places.add(SavedPlace(
            label: name,
            address: address,
            kind: _kindFor(name),
          )));

      var action = '';
      await listenForVoiceChoice(
        stt: _stt,
        tts: _tts,
        language: language,
        choices: [
          OnboardingVoiceChoice(
            label: s.placesAddAnotherLabel,
            synonyms: s.placesAddAnotherSynonyms,
            onSelect: () => action = 'another',
          ),
          OnboardingVoiceChoice(
            label: s.placesSkipLabel,
            synonyms: s.placesSkipSynonyms,
            onSelect: () => action = 'done',
          ),
        ],
        retryHint: s.placesAddAnotherSpoken,
        unavailableMessage: s.voiceUnavailableSpoken,
        isCancelled: cancelled,
      );
      if (cancelled()) return;
      if (action != 'another') {
        _finish();
        return;
      }
    }
  }

  /// Speaks [prompt], listens, reads the value back, and returns it once
  /// confirmed. Returns null when the user skipped or the screen was left.
  Future<String?> _dictate({
    required String prompt,
    required String fieldLabel,
    required AppLanguage language,
    required List<String> skipWords,
    required bool Function() cancelled,
  }) async {
    while (!cancelled()) {
      await _tts.speak(prompt, language: language);
      if (cancelled() || !await _stt.ensureAvailable()) return null;

      String? heard;
      var skipped = false;
      await _stt.listenOnce(
        language: language,
        // Every one of these prompts asks for a Dhaka place name, which is
        // exactly the vocabulary a general recognizer is weakest at.
        phraseHints: dhakaPlacePhrases,
        onResult: (text, isFinal) {
          if (!isFinal || heard != null || skipped) return;
          final trimmed = text.trim();
          if (trimmed.isEmpty) return;
          if (skipWords.any((w) => fuzzyVoiceMatch(trimmed, w))) {
            skipped = true;
            return;
          }
          heard = trimmed;
        },
      );
      if (cancelled()) return null;
      if (skipped) return null;
      if (heard == null) continue;

      final confirmed = await VoiceConfirm.readBackAndConfirm(
        tts: _tts,
        stt: _stt,
        language: language,
        fieldLabel: fieldLabel,
        value: heard!,
        isCancelled: cancelled,
      );
      if (cancelled() || confirmed == null) return null;
      if (confirmed) return heard;
      // Rejected — loop and ask for the same field again.
    }
    return null;
  }

  /// Best guess at what kind of place a label describes, purely to seed
  /// spoken synonyms later (someone who saved "work" should also be
  /// understood saying "office"). Wrong guesses cost nothing — the label
  /// itself always matches regardless.
  SavedPlaceKind _kindFor(String label) {
    for (final entry in SavedPlaceMatcher.kindSynonyms.entries) {
      if (entry.value.isEmpty) continue;
      if (SavedPlaceMatcher.candidates(label, [SavedPlace(label: '', kind: entry.key)]).isNotEmpty) {
        return entry.key;
      }
    }
    return SavedPlaceKind.other;
  }

  void _addTypedPlace() {
    final name = _nameController.text.trim();
    final address = _addressController.text.trim();
    if (name.isEmpty || address.isEmpty) return;
    setState(() {
      _places.add(SavedPlace(label: name, address: address, kind: _kindFor(name)));
      _nameController.clear();
      _addressController.clear();
    });
  }

  void _finish() => ref.read(onboardingControllerProvider.notifier).setFrequentPlaces(_places);

  @override
  Widget build(BuildContext context) {
    final controller = ref.read(onboardingControllerProvider.notifier);
    final language = ref.watch(onboardingControllerProvider.select((s) => s.profile!.language));
    final s = Onboarding.of(language);
    final theme = Theme.of(context);

    return OnboardingScaffold(
      title: s.placesTitle,
      subtitle: s.placesSubtitle,
      onBack: controller.goBack,
      language: language,
      // Always enabled — this step is optional, so "Continue" with nothing
      // added is a legitimate answer, not an incomplete form.
      primaryActionLabel: _places.isEmpty ? s.placesSkipLabel : s.continueLabel,
      onPrimaryAction: _finish,
      spokenOptions: [s.placesSpokenHint],
      autoSpeak: false,
      onVoiceRestart: () {
        _voiceStarted = false;
        _introAndListen();
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            liveRegion: true,
            child: Text(s.placesSavedCount(_places.length), style: theme.textTheme.titleMedium),
          ),
          const SizedBox(height: 12),
          for (final place in _places)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: const Icon(Icons.place_rounded, color: AppColors.primary),
                title: Text(place.label),
                subtitle: place.address.isEmpty ? null : Text(place.address),
                trailing: Semantics(
                  button: true,
                  label: s.contactsRemoveSemantics(place.label),
                  child: IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => setState(() => _places.remove(place)),
                  ),
                ),
              ),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _nameController,
                  decoration: InputDecoration(labelText: s.placesFieldNameHint),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 8),
              VoiceDictateButton(
                controller: _nameController,
                language: language,
                fieldLabel: s.placesNameLabel,
                onDictated: (_) => setState(() {}),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _addressController,
                  decoration: InputDecoration(labelText: s.placesFieldAddressHint),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 8),
              VoiceDictateButton(
                controller: _addressController,
                language: language,
                fieldLabel: s.placesAddressLabel,
                onDictated: (_) => setState(() {}),
              ),
            ],
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: (_nameController.text.trim().isEmpty || _addressController.text.trim().isEmpty)
                ? null
                : _addTypedPlace,
            icon: const Icon(Icons.add_rounded),
            label: Text(s.placesAddButton),
          ),
        ],
      ),
    );
  }
}
