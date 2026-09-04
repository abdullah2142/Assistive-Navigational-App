import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_language.dart';
import '../../../core/localization/onboarding_strings.dart';
import '../../../core/providers/ai_assistant_providers.dart';
import '../../../core/providers/tts_providers.dart';
import '../../../core/services/stt_service.dart';
import '../../../core/services/tts_service.dart';
import '../providers/onboarding_providers.dart';
import 'onboarding_voice.dart';

/// Shared shell for every onboarding screen: a Semantics-announced header,
/// optional back button, scrollable body, and a fixed primary action at the
/// bottom so it's always reachable without hunting for it.
///
/// Also where onboarding-wide voice guidance lives: every screen speaks its
/// own title/subtitle/[spokenOptions] the instant it appears, on by default
/// (see [ttsEnabledProvider]'s doc comment for why), with a toggle in the
/// app bar to turn it off. This is the single choke point every onboarding
/// screen passes through, so it's the natural place for this rather than
/// duplicating speech calls in each screen.
class OnboardingScaffold extends ConsumerStatefulWidget {
  const OnboardingScaffold({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.onBack,
    this.primaryActionLabel,
    this.onPrimaryAction,
    this.primaryActionEnabled = true,
    this.isLoading = false,
    this.spokenOptions = const [],
    this.language = AppLanguage.english,
    this.autoSpeak = true,
    this.voiceChoices = const [],
    this.onVoiceRestart,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final VoidCallback? onBack;
  final String? primaryActionLabel;
  final VoidCallback? onPrimaryAction;
  final bool primaryActionEnabled;
  final bool isLoading;

  /// Extra lines spoken after the title/subtitle — typically the labels of
  /// this screen's tappable choices, or a summary of its fields, so a fully
  /// blind user knows what's here without needing to explore by touch first.
  final List<String> spokenOptions;

  /// Which locale to speak [title]/[subtitle]/[spokenOptions] in.
  final AppLanguage language;

  /// Set false when a screen handles its own voice announcement (only
  /// [LanguageSelectionScreen] today — it needs to speak in *both*
  /// languages, since there's no chosen one yet).
  final bool autoSpeak;

  /// When non-empty, this screen's single group of tappable choices can
  /// also be answered out loud: once narration finishes, the mic listens
  /// (re-prompting on a miss instead of giving up) until one matches. A
  /// screen with more than one independent choice to make (e.g. two
  /// sequential yes/no questions) drives `listenForVoiceChoice` itself
  /// rather than using this — see `CognitiveAnxietyScreen`.
  final List<OnboardingVoiceChoice> voiceChoices;

  /// How to restart voice guidance on a screen that drives its own loop
  /// ([autoSpeak] false) after a failed step — see
  /// [OnboardingState.voiceRearmToken]. Screens using this shell's own
  /// narrate-then-listen loop leave it null and get [_speakThenListen].
  final VoidCallback? onVoiceRestart;

  @override
  ConsumerState<OnboardingScaffold> createState() => _OnboardingScaffoldState();
}

class _OnboardingScaffoldState extends ConsumerState<OnboardingScaffold> {
  bool _disposed = false;
  bool _listening = false;

  // Captured once, here, rather than `ref.read` inside `dispose()` — `ref`
  // is unsafe to use once a widget is unmounting. Forced eager in
  // `initState` below so `dispose()` always has a valid reference even on
  // a screen that's left before `_speakThenListen` itself ever ran.
  late final TtsService _tts = ref.read(ttsServiceProvider);
  late final SttService _stt = ref.read(sttServiceProvider);

  @override
  void initState() {
    super.initState();
    _tts;
    _stt;
    // Post-frame so this fires once this screen has actually landed, not
    // mid-transition with the previous screen's frame still on layout.
    if (widget.autoSpeak) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _speakThenListen());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    // Both unconditionally, not just when `_listening` — confirmed live as
    // a real bug without this: leaving a screen mid-narration (tapping an
    // option before its own TTS narration finished playing) left that
    // narration audibly still playing over the *next* screen, since only
    // the mic was ever stopped here, never the voice. `stop()` on either
    // service is a safe no-op when nothing is actually active.
    _tts.stop();
    _stt.stop();
    super.dispose();
  }

  Future<void> _speakThenListen() async {
    if (_disposed || !ref.read(ttsEnabledProvider)) return;
    // Captured once, up front — see `OnboardingState.stepGeneration`'s doc
    // comment for the stale-listener bug this (plus the check in
    // `isCancelled` below) fixes.
    final myGeneration = ref.read(onboardingControllerProvider).stepGeneration;
    // Title + subtitle + the full option list, always spoken up front
    // before listening starts. An earlier version deferred `spokenOptions`
    // to be spoken only on request ("help") once a listen loop was about
    // to start, to avoid making a user who already knows their answer sit
    // through a full read-out first — reverted after live testing: it read
    // as the mic "just recording" with no idea what to say, which is worse
    // than the slightly longer narration this restores. `listenForVoiceChoice`
    // still recognizes "help" mid-loop to *repeat* this, which stays useful
    // regardless of when it was first said.
    final introParts = [widget.title, if (widget.subtitle != null) widget.subtitle!, ...widget.spokenOptions];
    final intro = introParts.join('. ');
    await _tts.speak(intro, language: widget.language);
    if (_disposed || widget.voiceChoices.isEmpty || !ref.read(ttsEnabledProvider)) return;
    setState(() => _listening = true);
    final s = Onboarding.of(widget.language);
    await listenForVoiceChoice(
      stt: _stt,
      tts: _tts,
      language: widget.language,
      choices: widget.voiceChoices,
      helpText: widget.spokenOptions.isEmpty ? null : widget.spokenOptions.join('. '),
      retryHint: s.voiceChoiceRetryHint,
      isCancelled: () =>
          _disposed || ref.read(onboardingControllerProvider).stepGeneration != myGeneration,
    );
    if (!_disposed) setState(() => _listening = false);
  }

  /// Speaks the failure out loud — onboarding errors are otherwise only
  /// ever rendered as red text, invisible to the user this whole flow is
  /// built for — then hands the screen its voice back.
  Future<void> _announceFailureAndRestart() async {
    if (_disposed || !ref.read(ttsEnabledProvider)) return;
    final error = ref.read(onboardingControllerProvider).errorMessage;
    if (error != null) await _tts.speak(error, language: widget.language);
    if (_disposed) return;
    final restart = widget.onVoiceRestart;
    if (restart != null) {
      restart();
    } else {
      await _speakThenListen();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ttsEnabled = ref.watch(ttsEnabledProvider);
    final s = Onboarding.of(widget.language);

    ref.listen(
      onboardingControllerProvider.select((s) => s.voiceRearmToken),
      (previous, next) {
        if (previous != next) _announceFailureAndRestart();
      },
    );

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: widget.onBack == null
            ? null
            : Semantics(
                label: 'Go back to the previous step',
                button: true,
                child: IconButton(
                  icon: const Icon(Icons.arrow_back_rounded),
                  onPressed: widget.onBack,
                ),
              ),
        actions: [
          // Development-only shortcut past the whole interview. Wrapped in
          // `kDebugMode` so it is not merely hidden in release — the tree
          // never contains it, and Dart's tree shaker drops the branch
          // outright. See `OnboardingController.devSkipOnboarding`, which
          // refuses to run in a release build even if reached.
          if (kDebugMode)
            Semantics(
              button: true,
              label: 'Developer: skip onboarding with test data',
              child: IconButton(
                icon: const Icon(Icons.fast_forward_rounded),
                tooltip: 'DEV: skip to dashboard',
                onPressed: () {
                  _tts.stop();
                  _stt.stop();
                  ref.read(onboardingControllerProvider.notifier).devSkipOnboarding();
                },
              ),
            ),
          Semantics(
            button: true,
            label: ttsEnabled ? s.voiceOnSemantics : s.voiceOffSemantics,
            child: IconButton(
              icon: Icon(ttsEnabled ? Icons.volume_up_rounded : Icons.volume_off_rounded),
              onPressed: () {
                final next = !ttsEnabled;
                ref.read(ttsEnabledProvider.notifier).state = next;
                if (next) {
                  _speakThenListen();
                } else {
                  _tts.stop();
                  if (_listening) {
                    _stt.stop();
                    setState(() => _listening = false);
                  }
                }
              },
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 12),
              Semantics(
                header: true,
                child: Text(widget.title, style: Theme.of(context).textTheme.headlineMedium),
              ),
              if (widget.subtitle != null) ...[
                const SizedBox(height: 8),
                Text(widget.subtitle!, style: Theme.of(context).textTheme.bodyLarge),
              ],
              if (_listening) ...[
                const SizedBox(height: 12),
                Semantics(
                  liveRegion: true,
                  label: s.voiceListeningIndicator,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.mic_rounded, size: 18, color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 6),
                      Text(
                        s.voiceListeningIndicator,
                        style: Theme.of(context)
                            .textTheme
                            .labelMedium
                            ?.copyWith(color: Theme.of(context).colorScheme.primary),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 24),
              Expanded(child: SingleChildScrollView(child: widget.child)),
              if (widget.primaryActionLabel != null) ...[
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed:
                        (widget.primaryActionEnabled && !widget.isLoading) ? widget.onPrimaryAction : null,
                    child: widget.isLoading
                        ? const SizedBox(
                            height: 24,
                            width: 24,
                            child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                          )
                        : Text(widget.primaryActionLabel!),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
