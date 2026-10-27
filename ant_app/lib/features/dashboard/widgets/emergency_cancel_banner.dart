import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_language.dart';
import '../../../core/localization/dashboard_strings.dart';
import '../../../core/providers/ai_assistant_providers.dart';
import '../../../core/services/emergency_service.dart';
import '../../../core/theme/app_colors.dart';

/// Visible, tappable proof that an emergency alert is about to go out.
///
/// The cancel window was heard and spoken only. A deaf user saw nothing for
/// the whole countdown and nobody who could not speak could stop it.
class EmergencyCancelBanner extends ConsumerWidget {
  const EmergencyCancelBanner({super.key, required this.language});

  final AppLanguage language;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ValueListenableBuilder<EmergencyPhase>(
      valueListenable: ref.watch(emergencyPhaseProvider),
      builder: (context, phase, _) {
        final cancellable =
            phase == EmergencyPhase.announcing || phase == EmergencyPhase.countdown;
        if (!cancellable) return const SizedBox.shrink();
        final d = Dashboard.of(language);
        return Semantics(
          liveRegion: true,
          container: true,
          label: '${d.emergencyBannerTitle}. ${d.emergencyBannerBody}. ${d.emergencyBannerCancel}.',
          child: Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.danger,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExcludeSemantics(
                  child: Text(
                    d.emergencyBannerTitle,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                ExcludeSemantics(
                  child: Text(
                    d.emergencyBannerBody,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: Colors.white),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: AppColors.danger,
                    ),
                    onPressed: () => ref.read(emergencyServiceProvider).cancelPending(),
                    // The text is the button's accessible name. It used to be
                    // wrapped in a second Semantics and the text hidden, which
                    // left the node TalkBack could double-tap with no name.
                    child: Text(
                      d.emergencyBannerCancel,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
