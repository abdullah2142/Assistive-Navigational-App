import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/onboarding/providers/onboarding_providers.dart';
import '../config/gemini_config.dart';
import '../services/background_listening_service.dart';
import '../services/cloud_stt_service.dart';
import '../services/function_call_executor.dart';
import '../services/gemini_assistant_service.dart';
import '../services/route_planning_service.dart';
import '../services/stt_service.dart';
import '../services/wake_word_service.dart';

final wakeWordServiceProvider = Provider<WakeWordService>((ref) {
  final service = WakeWordService();
  ref.onDispose(service.dispose);
  return service;
});

/// See `BackgroundListeningService`'s doc comment — keeps the process (and
/// whatever `WakeWordService` already has listening inside it) alive while
/// the app is backgrounded or the screen is locked. `ChatStreamPanel` drives
/// this via a `WidgetsBindingObserver` tied to `UserProfile.wakeWordEnabled`.
final backgroundListeningServiceProvider = Provider<BackgroundListeningService>(
  (ref) => BackgroundListeningService(),
);

final cloudSttServiceProvider = Provider<CloudSttService>((ref) {
  final service = CloudSttService();
  ref.onDispose(service.dispose);
  return service;
});

// Injected with `wakeWordServiceProvider` so every `listenOnce()` call
// automatically pauses/resumes wake-word listening around itself (see
// `SttService.listenOnce`'s doc comment for the bug this centralizes the
// fix for), and with `cloudSttServiceProvider` so every caller
// transparently gets cloud-quality continuous recognition instead of the
// on-device recognizer whenever `CloudSttConfig.isConfigured` — confirmed
// live to fix the on-device recognizer's Bangla gibberish problem, not
// just the Passerby overlay's original mic-flicker issue.
final sttServiceProvider = Provider<SttService>(
  (ref) => SttService(wakeWord: ref.watch(wakeWordServiceProvider), cloudStt: ref.watch(cloudSttServiceProvider)),
);

/// What a function call (settings change, overlay trigger, route request)
/// actually *does* — shared between the Gemini function-calling path and
/// `LocalIntentMatcher`'s local-pattern path, so both produce identical
/// effects/wording. Doesn't need `GeminiConfig.isConfigured` at all — this
/// works standalone even with no Gemini key, which is exactly what lets
/// local-matched settings changes work without one.
final functionCallExecutorProvider = Provider<FunctionCallExecutor>((ref) {
  return FunctionCallExecutor(
    pairingService: ref.watch(pairingServiceProvider),
    routePlanning: RoutePlanningService(),
  );
});

/// `null` when [GeminiConfig.isConfigured] is false — callers must check
/// that flag first (same pattern as `MapsConfig.isConfigured`) rather than
/// force-unwrap this.
final geminiAssistantServiceProvider = Provider<GeminiAssistantService?>((ref) {
  if (!GeminiConfig.isConfigured) return null;
  return GeminiAssistantService(apiKey: GeminiConfig.apiKey, executor: ref.watch(functionCallExecutorProvider));
});
