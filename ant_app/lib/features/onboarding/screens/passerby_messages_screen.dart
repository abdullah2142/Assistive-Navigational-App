import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_language.dart';
import '../../../core/localization/onboarding_strings.dart';
import '../../../core/providers/ai_assistant_providers.dart';
import '../../../core/providers/tts_providers.dart';
import '../../../core/services/stt_service.dart';
import '../../../core/services/tts_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/ai_text_summarizer.dart';
import '../models/disability_profile_enums.dart';
import '../models/user_profile.dart';
import '../providers/onboarding_providers.dart';
import '../widgets/onboarding_scaffold.dart';
import '../widgets/onboarding_voice.dart';

/// Builds a suggestion pool tailored to what's already known about this
/// person from earlier onboarding steps, so the checklist isn't generic.
List<String> _suggestedMessages(Onboarding s, UserProfile profile) {
  final messages = <String>[s.passerbyNeedHelp, s.passerbyWhichDirection, s.passerbyHelpCross];
  if (profile.visionLevel != VisionLevel.full) {
    messages.addAll([s.passerbyVisuallyImpaired, s.passerbyRoadFlooded, s.passerbyWhatSignSays]);
  }
  if (profile.isDeafOrHardOfHearing) {
    messages.addAll([s.passerbyDeaf, s.passerbyWhichBus]);
  }
  if (profile.mobilityAid == MobilityAid.wheelchair) {
    messages.add(s.passerbyRampNearby);
  }
  return messages;
}

/// Collects the "Show Screen" Passerby Helper's message templates — the
/// Crowdsource module plan's Step 4.1 overlay needs *something* to display,
/// and asking now (while context is fresh) beats making a stressed user
/// compose one on the spot later.
class PasserbyMessagesScreen extends ConsumerStatefulWidget {
  const PasserbyMessagesScreen({super.key});

  @override
  ConsumerState<PasserbyMessagesScreen> createState() => _PasserbyMessagesScreenState();
}

class _PasserbyMessagesScreenState extends ConsumerState<PasserbyMessagesScreen> {
  late List<String> _suggestions;
  late Set<String> _selected;
  final List<String> _custom = [];
  final _customController = TextEditingController();
  bool _initialized = false;
  bool _disposed = false;
  bool _voiceStarted = false;

  // See `LanguageSelectionScreen`'s identical fields for why this is a
  // `late final` capture rather than `ref.read` inside `dispose()` — the
  // latter is unsafe and throws (confirmed by a real test failure) once
  // the widget is unmounting.
  late final TtsService _tts = ref.read(ttsServiceProvider);
  late final SttService _stt = ref.read(sttServiceProvider);

  void _initFrom(Onboarding s, UserProfile profile) {
    if (_initialized) return;
    _suggestions = _suggestedMessages(s, profile);
    // Pre-check the first three so Continue is always immediately usable.
    _selected = _suggestions.take(3).toSet();
    _initialized = true;
  }

  @override
  void initState() {
    super.initState();
    _tts;
    _stt;
    _customController.addListener(() => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) => _introAndListen());
  }

  @override
  void dispose() {
    _disposed = true;
    _stt.stop();
    _tts.stop();
    _customController.dispose();
    super.dispose();
  }

  void _addCustom() {
    final text = _customController.text.trim();
    if (text.isEmpty) return;
    setState(() {
      // Summarized, not raw — this is what gets shown full-screen to a
      // passerby later, so it needs to stay short and legible even if the
      // person rambled while typing or dictating it.
      _custom.add(summarizeText(text));
      _customController.clear();
    });
  }

  bool _listening = false;

  Future<void> _dictate(UserProfile profile) async {
    if (!await _stt.ensureAvailable()) return;
    setState(() => _listening = true);
    await _stt.listenOnce(
      language: profile.language,
      onResult: (text, isFinal) {
        if (!isFinal) return;
        final trimmed = text.trim();
        if (trimmed.isEmpty) return;
        _customController.text = trimmed;
        _customController.selection = TextSelection.collapsed(offset: trimmed.length);
      },
    );
    if (mounted) setState(() => _listening = false);
  }

  static const _donePhrasesEn = [
    'continue',
    'done',
    'finish',
    "that's it",
    'thats it',
    'i am done',
    "i'm done",
    'im done',
    'next',
    'ready',
    'okay go',
    'that is all',
    "that's all",
    'nothing else',
    'no more',
  ];
  static const _donePhrasesBn = [
    'চালিয়ে যান',
    'চালিয়ে যাও',
    'শেষ',
    'হয়ে গেছে',
    'শেষ হয়েছে',
    'আর কিছু না',
    'ব্যাস',
    'রেডি',
    'ঠিক আছে চলুন',
  ];

  bool _isDoneCommand(String text) {
    final lower = text.toLowerCase().trim();
    if (lower.length > 24) return false; // too long to be just a done command
    return _donePhrasesEn.any(lower.contains) || _donePhrasesBn.any(text.contains);
  }

  /// Every listen either: toggles one suggested message on/off (spoken
  /// name matched, fuzzily, against `_suggestions`), adds a dictated
  /// message (didn't match a suggestion or a "continue" command, so it's
  /// free text), or finishes the screen ("continue"/"done"). Checked in
  /// that order — a known command always wins over treating the same words
  /// as free text to add, same principle `CrowdsourceReportingHub`'s
  /// submit-intent extraction already applies to its own describe step.
  Future<void> _introAndListen() async {
    if (_disposed || !ref.read(ttsEnabledProvider)) return;
    final profile = ref.read(onboardingControllerProvider).profile;
    if (profile == null) return;
    final s = Onboarding.of(profile.language);
    await _tts.speak('${s.passerbyTitle}. ${s.passerbySubtitle}', language: profile.language);
    if (_disposed || !ref.read(ttsEnabledProvider) || _voiceStarted) return;
    _voiceStarted = true;
    await _voiceLoop(s, profile.language);
  }

  Future<void> _voiceLoop(Onboarding s, AppLanguage language) async {
    final myGeneration = ref.read(onboardingControllerProvider).stepGeneration;
    bool cancelled() =>
        _disposed || ref.read(onboardingControllerProvider).stepGeneration != myGeneration;
    final stt = _stt;
    final tts = _tts;
    final controller = ref.read(onboardingControllerProvider.notifier);

    while (!cancelled()) {
      if (!await stt.ensureAvailable()) return;
      var isDone = false;
      String? toggledMessage;
      String? freeText;
      await stt.listenOnce(
        language: language,
        onResult: (text, isFinal) {
          if (!isFinal || isDone || toggledMessage != null || freeText != null) return;
          final trimmed = text.trim();
          if (trimmed.isEmpty) return;
          if (_isDoneCommand(trimmed)) {
            isDone = true;
            return;
          }
          for (final message in _suggestions) {
            if (fuzzyVoiceMatch(trimmed, message)) {
              toggledMessage = message;
              return;
            }
          }
          freeText = trimmed;
        },
      );
      if (cancelled()) return;

      if (isDone) {
        final allSelected = [..._selected, ..._custom];
        if (allSelected.isEmpty) {
          await tts.speak(s.passerbyNeedAtLeastOneSpoken, language: language);
          continue;
        }
        controller.setPasserbyHelperMessages(allSelected);
        return;
      }
      if (toggledMessage != null) {
        final message = toggledMessage!;
        setState(() {
          if (_selected.contains(message)) {
            _selected.remove(message);
          } else {
            _selected.add(message);
          }
        });
        await tts.speak(
          _selected.contains(message) ? s.passerbyMessageAddedSpoken(message) : s.passerbyMessageRemovedSpoken(message),
          language: language,
        );
        continue;
      }
      if (freeText != null) {
        setState(() => _custom.add(summarizeText(freeText!)));
        await tts.speak(s.passerbyCustomAddedSpoken, language: language);
        continue;
      }
      await tts.speak(s.passerbyVoiceRetryHint, language: language);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(onboardingControllerProvider);
    final controller = ref.read(onboardingControllerProvider.notifier);
    final profile = state.profile;
    if (profile == null) return const SizedBox.shrink();
    final s = Onboarding.of(profile.language);
    _initFrom(s, profile);

    final allSelected = [..._selected, ..._custom];

    return OnboardingScaffold(
      title: s.passerbyTitle,
      subtitle: s.passerbySubtitle,
      onBack: controller.goBack,
      language: profile.language,
      isLoading: state.isLoading,
      primaryActionLabel: s.continueLabel,
      primaryActionEnabled: allSelected.isNotEmpty,
      onPrimaryAction: () => controller.setPasserbyHelperMessages(allSelected),
      spokenOptions: [
        s.passerbySpokenPreselected(_suggestions.take(3).join('. ')),
        if (_suggestions.length > 3) s.passerbySpokenMore(_suggestions.skip(3).join('. ')),
        s.passerbySpokenAddOwn,
      ],
      autoSpeak: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final message in _suggestions)
            _MessageToggleTile(
              message: message,
              selected: _selected.contains(message),
              onChanged: (checked) => setState(() {
                if (checked) {
                  _selected.add(message);
                } else {
                  _selected.remove(message);
                }
              }),
            ),
          for (var i = 0; i < _custom.length; i++)
            _MessageToggleTile(
              message: _custom[i],
              selected: true,
              onChanged: (_) => setState(() => _custom.removeAt(i)),
            ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Semantics(
                  textField: true,
                  label: s.passerbyWriteFieldSemantics,
                  child: TextField(
                    controller: _customController,
                    decoration: InputDecoration(hintText: s.passerbyWriteOwnHint),
                    onSubmitted: (_) => _addCustom(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Semantics(
                button: true,
                label: s.passerbySpeakSemantics,
                child: Material(
                  color: Theme.of(context).colorScheme.primary,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: _listening ? null : () => _dictate(profile),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Icon(_listening ? Icons.mic_rounded : Icons.mic_none_rounded, color: Colors.white),
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (_customController.text.trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Semantics(
                liveRegion: true,
                label: '${s.passerbyAiSummaryLabel}: ${summarizeText(_customController.text)}',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.auto_awesome_rounded, size: 16, color: Theme.of(context).colorScheme.primary),
                        const SizedBox(width: 6),
                        Text(
                          s.passerbyAiSummaryLabel,
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(color: Theme.of(context).colorScheme.primary),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(summarizeText(_customController.text), style: Theme.of(context).textTheme.bodyMedium),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _customController.text.trim().isEmpty ? null : _addCustom,
            icon: const Icon(Icons.add_rounded),
            label: Text(s.passerbyAddButton),
          ),
        ],
      ),
    );
  }
}

class _MessageToggleTile extends StatelessWidget {
  const _MessageToggleTile({required this.message, required this.selected, required this.onChanged});

  final String message;
  final bool selected;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      toggled: selected,
      label: message,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Material(
          color: selected ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.1) : AppColors.background,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => onChanged(!selected),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: selected ? Theme.of(context).colorScheme.primary : AppColors.divider),
              ),
              child: Row(
                children: [
                  Icon(
                    selected ? Icons.check_circle_rounded : Icons.circle_outlined,
                    color: selected ? Theme.of(context).colorScheme.primary : AppColors.textSecondary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text(message, style: Theme.of(context).textTheme.bodyLarge)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
