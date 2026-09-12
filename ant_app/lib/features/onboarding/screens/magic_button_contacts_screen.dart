import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_language.dart';
import '../../../core/localization/onboarding_strings.dart';
import '../../../core/providers/ai_assistant_providers.dart';
import '../../../core/providers/tts_providers.dart';
import '../../../core/services/stt_service.dart';
import '../../../core/services/tts_service.dart';
import '../../../core/theme/app_colors.dart';
import '../models/trusted_contact.dart';
import '../providers/onboarding_providers.dart';
import '../widgets/onboarding_scaffold.dart';
import '../widgets/onboarding_voice.dart';
import '../widgets/spoken_digits.dart';
import '../widgets/spoken_name.dart';
import '../widgets/voice_dictate_button.dart';

class MagicButtonContactsScreen extends ConsumerStatefulWidget {
  const MagicButtonContactsScreen({super.key});

  @override
  ConsumerState<MagicButtonContactsScreen> createState() => _MagicButtonContactsScreenState();
}

class _MagicButtonContactsScreenState extends ConsumerState<MagicButtonContactsScreen> {
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  bool _disposed = false;
  bool _voiceStarted = false;

  // See `LanguageSelectionScreen`'s identical fields for why this is a
  // `late final` capture rather than `ref.read` inside `dispose()` — the
  // latter is unsafe and throws (confirmed by a real test failure) once
  // the widget is unmounting.
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

  Future<void> _introAndListen() async {
    if (_disposed || !ref.read(ttsEnabledProvider)) return;
    final language = ref.read(onboardingControllerProvider).profile!.language;
    final s = Onboarding.of(language);
    await _tts.speak('${s.contactsTitle}. ${s.contactsSpokenHint}', language: language);
    if (_disposed || !ref.read(ttsEnabledProvider) || _voiceStarted) return;
    _voiceStarted = true;
    await _voiceContactLoop(s, language);
  }

  /// Repeats name -> phone -> save -> "add another, or continue?" for as
  /// many contacts as the user wants — every other multi-field onboarding
  /// screen this session got the same "detect one action is done, then
  /// prompt for the next" treatment, and this screen was the one left out.
  ///
  /// Deliberately saves the contact automatically the moment both fields
  /// are dictated, rather than requiring a separate "add" voice command
  /// first — an earlier version asked "add or continue?" immediately after
  /// dictation, then treated "add" as *both* "save this" *and* "collect
  /// another", which confirmed live as genuinely confusing: a user who
  /// dictated one contact and said "add" (meaning "save it") was then
  /// immediately asked for a *second* contact's name, as if they'd asked
  /// for that. Splitting "save" (automatic, no voice command needed) from
  /// "add another vs. continue" (one clear, separate question afterward)
  /// removes that double meaning entirely.
  Future<void> _voiceContactLoop(Onboarding s, AppLanguage language) async {
    final myGeneration = ref.read(onboardingControllerProvider).stepGeneration;
    bool cancelled() =>
        _disposed || ref.read(onboardingControllerProvider).stepGeneration != myGeneration;
    final stt = _stt;
    final tts = _tts;
    final controller = ref.read(onboardingControllerProvider.notifier);

    while (!cancelled()) {
      await tts.speak(s.contactsNamePromptSpoken, language: language);
      if (cancelled()) return;
      if (!await stt.ensureAvailable()) {
        debugPrint('[ContactsVoice] stt.ensureAvailable() returned false — giving up silently');
        return;
      }
      String? name;
      await stt.listenOnce(
        language: language,
        onResult: (text, isFinal) {
          if (isFinal && text.trim().isNotEmpty) name = text.trim();
        },
      );
      if (cancelled()) return;
      if (name != null) setState(() => _nameController.text = name!);

      await tts.speak(s.contactsPhonePromptSpoken, language: language);
      if (cancelled()) return;
      if (!await stt.ensureAvailable()) {
        debugPrint('[ContactsVoice] stt.ensureAvailable() returned false — giving up silently');
        return;
      }
      String? phone;
      await stt.listenOnce(
        language: language,
        onResult: (text, isFinal) {
          if (!isFinal || text.trim().isEmpty) return;
          // "double three double three..." -> "3344..." — see
          // `spokenTextToDigits`'s doc comment for the live bug this fixes;
          // applies here too, not just `VoiceDictateButton`'s manual mic,
          // since this loop dictates the same phone field automatically.
          final digits = spokenTextToDigits(text.trim());
          if (digits.isNotEmpty) phone = digits;
        },
      );
      if (cancelled()) return;
      if (phone != null) setState(() => _phoneController.text = phone!);

      if (_nameController.text.trim().isEmpty || _phoneController.text.trim().isEmpty) {
        // Neither utterance was captured (silence/mismatch both times) —
        // don't silently save an empty contact, just loop back and ask again.
        continue;
      }

      // Read back before saving, not after — explicit user feedback: a
      // dictated phone number especially is easy for STT to get subtly
      // wrong, and this is an *emergency* contact, so the user needs a
      // real chance to catch and redo a mistake before it's saved, not
      // just after. "No" here redoes both fields from scratch rather than
      // trying to isolate which one was wrong — simpler and more reliable
      // than a voice-driven "which field do you want to fix".
      if (!await _confirmContact(stt, tts, s, language, cancelled)) {
        if (cancelled()) return;
        continue;
      }
      if (cancelled()) return;

      _addContact(controller);

      var action = '';
      await listenForVoiceChoice(
        stt: stt,
        tts: tts,
        language: language,
        choices: [
          OnboardingVoiceChoice(
            label: s.contactsAddAnotherLabel,
            synonyms: s.contactsAddAnotherSynonyms,
            onSelect: () => action = 'another',
          ),
          OnboardingVoiceChoice(label: s.continueLabel, synonyms: s.continueSynonyms, onSelect: () => action = 'continue'),
        ],
        retryHint: s.contactsAddedThenAddAnotherOrContinueSpoken,
        unavailableMessage: s.voiceUnavailableSpoken,
        isCancelled: cancelled,
      );
      if (cancelled()) return;

      if (action == 'continue') {
        controller.continueFromContacts();
        return;
      }
      // 'another' — loop back and collect the next contact.
    }
  }

  /// Speaks the dictated name and phone number back, digit by digit for
  /// the number (not as one large number, which TTS engines tend to
  /// mangle), and listens for confirmation. Loops on an unclear answer
  /// rather than guessing; returns `false` on a clear "no" or on
  /// cancellation (caller checks `cancelled()` itself to tell the two apart).
  Future<bool> _confirmContact(
    SttService stt,
    TtsService tts,
    Onboarding s,
    AppLanguage language,
    bool Function() cancelled,
  ) async {
    final spacedPhone = _phoneController.text.trim().split('').join(' ');
    while (!cancelled()) {
      final name = _nameController.text.trim();
      await tts.speak(
        s.contactsConfirmSpoken(name, spelledOutName(name), spacedPhone),
        language: language,
      );
      if (cancelled()) return false;
      if (!await stt.ensureAvailable()) return false;
      bool? confirmed;
      await stt.listenOnce(
        language: language,
        onResult: (text, isFinal) {
          if (!isFinal || confirmed != null) return;
          final trimmed = text.trim();
          if (trimmed.isEmpty) return;
          confirmed = classifyTraitYesNo(
            trimmed,
            presentPhrases: const ['correct', 'that\'s right', 'thats right', 'right', 'save it', 'ঠিক আছে', 'ঠিক'],
            absentPhrases: const ['wrong', 'incorrect', 'redo', 'try again', 'ভুল', 'আবার'],
          );
        },
      );
      if (cancelled()) return false;
      if (confirmed != null) return confirmed!;
      await tts.speak(s.voiceChoiceRetryHint, language: language);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(onboardingControllerProvider);
    final controller = ref.read(onboardingControllerProvider.notifier);
    final contacts = state.profile?.magicButtonContacts ?? const [];
    final language = state.profile!.language;
    final s = Onboarding.of(language);

    return OnboardingScaffold(
      title: s.contactsTitle,
      subtitle: s.contactsSubtitle,
      onBack: controller.goBack,
      language: language,
      primaryActionLabel: s.continueLabel,
      onPrimaryAction: controller.continueFromContacts,
      spokenOptions: [s.contactsSpokenHint],
      autoSpeak: false,
      // Re-arms this screen's own voice loop when a step fails and we stay
      // put — `_stopCurrentScreenVoice` cancels it up front on every
      // navigating action. See `OnboardingState.voiceRearmToken`.
      onVoiceRestart: () {
        _voiceStarted = false;
        _introAndListen();
      },
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
                  label: s.contactsRemoveSemantics(contacts[i].name),
                  button: true,
                  child: IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => controller.removeContact(i),
                  ),
                ),
              ),
            ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Semantics(
                  textField: true,
                  label: s.contactsNameHint,
                  child: TextField(
                    controller: _nameController,
                    decoration: InputDecoration(hintText: s.contactsNameHint),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              VoiceDictateButton(
                controller: _nameController,
                language: language,
                fieldLabel: s.contactsNameLabel,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Semantics(
                  textField: true,
                  label: s.contactsPhoneHint,
                  child: TextField(
                    controller: _phoneController,
                    keyboardType: TextInputType.phone,
                    decoration: InputDecoration(hintText: s.contactsPhoneHint),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              VoiceDictateButton(
                controller: _phoneController,
                language: language,
                isPhoneNumber: true,
                fieldLabel: s.contactsPhoneLabel,
              ),
            ],
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => _addContact(controller),
            icon: const Icon(Icons.add_rounded),
            label: Text(s.contactsAddButton),
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
