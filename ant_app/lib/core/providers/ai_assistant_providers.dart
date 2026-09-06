import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/onboarding/providers/onboarding_providers.dart';
import '../config/gemini_config.dart';
import '../services/background_listening_service.dart';
import '../services/cloud_stt_service.dart';
import '../services/function_call_executor.dart';
import '../services/gemini_assistant_service.dart';
import '../services/navigation_controller.dart';
import '../services/route_planning_service.dart';
import '../../features/guardian/providers/guardian_providers.dart';
import '../services/emergency_service.dart';
import '../services/stt_service.dart';
import '../../core/providers/tts_providers.dart';
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
/// The Magic Button (Module 9).
///
/// A single instance, because its "already running" guard is what stops a
/// volume hold and a shouted "help me" seconds apart from sending two full
/// rounds of messages — the same person asking twice, not asking for twice
/// as much help.
final emergencyServiceProvider = Provider<EmergencyService>(
  (ref) => EmergencyService(
    tts: ref.watch(ttsServiceProvider),
    stt: ref.watch(sttServiceProvider),
    alerts: ref.watch(alertServiceProvider),
  ),
);

final sttServiceProvider = Provider<SttService>(
  (ref) => SttService(wakeWord: ref.watch(wakeWordServiceProvider), cloudStt: ref.watch(cloudSttServiceProvider)),
);

/// Shared so the chat controller's own clarification loop plans routes
/// through exactly the same path the function-call executor does.
final routePlanningServiceProvider = Provider<RoutePlanningService>((ref) => RoutePlanningService());

/// What a function call (settings change, overlay trigger, route request)
/// actually *does* — shared between the Gemini function-calling path and
/// `LocalIntentMatcher`'s local-pattern path, so both produce identical
/// effects/wording. Doesn't need `GeminiConfig.isConfigured` at all — this
/// works standalone even with no Gemini key, which is exactly what lets
/// local-matched settings changes work without one.
final functionCallExecutorProvider = Provider<FunctionCallExecutor>((ref) {
  return FunctionCallExecutor(
    pairingService: ref.watch(pairingServiceProvider),
    routePlanning: ref.watch(routePlanningServiceProvider),
  );
});

/// `null` when [GeminiConfig.isConfigured] is false — callers must check
/// that flag first (same pattern as `MapsConfig.isConfigured`) rather than
/// force-unwrap this.
final geminiAssistantServiceProvider = Provider<GeminiAssistantService?>((ref) {
  if (!GeminiConfig.isConfigured) return null;
  return GeminiAssistantService(apiKey: GeminiConfig.apiKey, executor: ref.watch(functionCallExecutorProvider));
});


/// Spoken turn-by-turn navigation. One per app — starting a new route
/// replaces the previous session rather than running two narrators over
/// the same voice.
final navigationControllerProvider = Provider<NavigationController>((ref) {
  final controller = NavigationController(tts: ref.watch(ttsServiceProvider));
  ref.onDispose(controller.dispose);
  return controller;
});
