import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_language.dart';
import '../../../core/providers/tts_providers.dart';

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

  @override
  ConsumerState<OnboardingScaffold> createState() => _OnboardingScaffoldState();
}

class _OnboardingScaffoldState extends ConsumerState<OnboardingScaffold> {
  @override
  void initState() {
    super.initState();
    // Post-frame so this fires once this screen has actually landed, not
    // mid-transition with the previous screen's frame still on layout.
    if (widget.autoSpeak) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _speak());
    }
  }

  void _speak() {
    if (!mounted || !ref.read(ttsEnabledProvider)) return;
    final parts = [
      widget.title,
      if (widget.subtitle != null) widget.subtitle!,
      ...widget.spokenOptions,
    ];
    ref.read(ttsServiceProvider).speak(parts.join('. '), language: widget.language);
  }

  @override
  Widget build(BuildContext context) {
    final ttsEnabled = ref.watch(ttsEnabledProvider);

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
          Semantics(
            button: true,
            label: ttsEnabled ? 'Voice guidance is on. Double tap to turn off.' : 'Voice guidance is off. Double tap to turn on.',
            child: IconButton(
              icon: Icon(ttsEnabled ? Icons.volume_up_rounded : Icons.volume_off_rounded),
              onPressed: () {
                final next = !ttsEnabled;
                ref.read(ttsEnabledProvider.notifier).state = next;
                if (next) {
                  _speak();
                } else {
                  ref.read(ttsServiceProvider).stop();
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
