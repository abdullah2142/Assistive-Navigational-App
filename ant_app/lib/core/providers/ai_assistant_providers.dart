import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/onboarding/providers/onboarding_providers.dart';
import '../config/gemini_config.dart';
import '../config/groq_config.dart';
import '../config/vision_config.dart';
import '../services/background_listening_service.dart';
import '../services/cloud_stt_service.dart';
import '../services/assistant_service.dart';
import '../services/fallback_assistant_service.dart';
import '../services/function_call_executor.dart';
import '../services/gemini_assistant_service.dart';
import '../services/gemini_assistant_cascade.dart';
import '../services/gemini_model_cooldowns.dart';
import '../services/groq_assistant_service.dart';
import '../services/navigation_controller.dart';
import '../services/route_planning_service.dart';
import '../../features/guardian/providers/guardian_providers.dart';
import '../services/emergency_service.dart';
import '../services/earcon_service.dart';
import '../services/haptics_service.dart';
import '../services/location_permission_primer.dart';
import '../services/stt_service.dart';
import '../../core/providers/tts_providers.dart';
import '../services/vision/ambient_hazard_scanner.dart';
import '../services/vision/cloud_vision_service.dart';
import '../services/vision/gemini_vision_cascade.dart';
import '../services/vision/gemini_vision_service.dart';
import '../services/vision/snapshot_vision_service.dart';
import '../services/vision/vision_router.dart';
import '../services/wake_word_service.dart';
import '../services/weather_service.dart';
import '../services/routing_service.dart';

final wakeWordServiceProvider = Provider<WakeWordService>((ref) {
  final service = WakeWordService();
  ref.onDispose(service.dispose);
  return service;
});

/// Shared foreground-work gate: periodic vision yields while an assistant
/// response is being prepared or spoken. The dashboard mirrors chat state
/// into this notifier without making the scanner depend on dashboard code.
final foregroundAssistantBusyProvider = Provider<ValueNotifier<bool>>((ref) {
  final busy = ValueNotifier<bool>(false);
  ref.onDispose(busy.dispose);
  return busy;
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
/// The three-pattern haptic language (Module 7). One instance, because the
/// hazard-alarm throttle is state that has to be shared across every caller.
final hapticsServiceProvider = Provider<HapticsService>(
  (ref) => HapticsService(),
);

/// The tone that says the microphone is open — item 59.
final earconServiceProvider = Provider<EarconService>((ref) {
  final service = EarconService();
  ref.onDispose(service.dispose);
  return service;
});

/// Asks for location permission during onboarding — item 50.
final locationPermissionPrimerProvider = Provider<LocationPermissionPrimer>(
  (ref) => LocationPermissionPrimer(),
);

final emergencyServiceProvider = Provider<EmergencyService>(
  (ref) => EmergencyService(
    tts: ref.watch(ttsServiceProvider),
    stt: ref.watch(sttServiceProvider),
    alerts: ref.watch(alertServiceProvider),
    planner: ref.watch(routePlanningServiceProvider),
    // An escape route is handed to the same navigation controller that
    // drives every other route, so turn-by-turn, haptics and off-route
    // recovery all behave identically. Nothing about walking somewhere
    // should change because of why you are walking there.
    onRoute: (route, language) =>
        ref.read(navigationControllerProvider).start(route, language: language),
  ),
);

final sttServiceProvider = Provider<SttService>(
  (ref) => SttService(
    wakeWord: ref.watch(wakeWordServiceProvider),
    cloudStt: ref.watch(cloudSttServiceProvider),
  ),
);

/// Shared so the chat controller's own clarification loop plans routes
/// through exactly the same path the function-call executor does.
final routePlanningServiceProvider = Provider<RoutePlanningService>(
  (ref) => RoutePlanningService(),
);

/// Geocoding, routing and nearby-place lookups. One instance so its backend
/// cascade and budget accounting are shared.
final routingServiceProvider = Provider<RoutingService>(
  (ref) => RoutingService(),
);

/// Weather, for warning before a walk. One instance so its ten-minute cache
/// is shared — this is asked on every route request.
final weatherServiceProvider = Provider<WeatherService>(
  (ref) => WeatherService(),
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
    routePlanning: ref.watch(routePlanningServiceProvider),
  );
});

/// `null` when [GeminiConfig.isConfigured] is false — callers must check
/// that flag first (same pattern as `MapsConfig.isConfigured`) rather than
/// force-unwrap this.
///
/// The name is now doubly historical and kept anyway: it was
/// `geminiAssistantServiceProvider` when Gemini was the only backend, stayed
/// so when Groq replaced it, and stays so now that the answer is *both*.
/// Renaming it would touch every consumer to say something the type already
/// says — it returns an `AssistantService`, and which backend answers is
/// `FallbackAssistantService`'s business rather than the caller's.
///
/// The `testers-flashlite-prompts` branch reverted this to Gemini-only in
/// `99fae0b` to keep that experiment clean. That revert is deliberately not
/// carried across: the experiment was "which provider", and the answer turned
/// out to be neither alone.
final geminiAssistantServiceProvider = Provider<AssistantService?>((ref) {
  final executor = ref.watch(functionCallExecutorProvider);

  final groq = GroqConfig.isConfigured
      ? GroqAssistantService(apiKey: GroqConfig.apiKey, executor: executor)
      : null;
  final fallbackModels = <AssistantService>[];
  if (GroqConfig.isConfigured) {
    fallbackModels.add(
      GroqAssistantService(
        apiKey: GroqConfig.apiKey,
        executor: executor,
        modelName: VisionConfig.visionModel,
      ),
    );
  }
  if (GeminiConfig.isConfigured) {
    fallbackModels.addAll([
      for (final modelName in GeminiConfig.chatFallbackModels)
        GeminiAssistantService(
          apiKey: GeminiConfig.apiKey,
          executor: executor,
          modelName: modelName,
          promptBuilder: modelName == GeminiConfig.gemma4
              ? GeminiAssistantService.buildGemmaPrompt
              : null,
        ),
    ]);
  }
  final fallback = fallbackModels.isEmpty
      ? null
      : GeminiAssistantCascade(
          cooldowns: GeminiModelCooldowns.shared,
          models: fallbackModels,
        );

  // Groq is the normal fast path. The tester diagnostics show Gemini timing
  // out before Groq was attempted, while the user's requested fallback still
  // matters when Groq reports a rate limit or other error.
  if (groq == null) return fallback;
  return FallbackAssistantService(primary: groq, secondary: fallback);
});

/// Spoken turn-by-turn navigation. One per app — starting a new route
/// replaces the previous session rather than running two narrators over
/// the same voice.
final navigationControllerProvider = Provider<NavigationController>((ref) {
  final controller = NavigationController(
    tts: ref.watch(ttsServiceProvider),
    haptics: ref.watch(hapticsServiceProvider),
  );
  ref.onDispose(controller.dispose);
  return controller;
});

/// Periodic online-first hazard scanning with local fallback for blind users.
///
/// Built on the *same* camera and detector as `snapshotVisionServiceProvider`
/// — see `SnapshotVisionService.camera` for why sharing them is not an
/// optimisation but a correctness requirement.
final ambientHazardScannerProvider = Provider<AmbientHazardScanner>((ref) {
  final vision = ref.watch(snapshotVisionServiceProvider);
  final scanner = AmbientHazardScanner(
    camera: vision.camera,
    edge: vision.edge,
    haptics: ref.read(hapticsServiceProvider),
    onlineVision: GeminiConfig.isConfigured
        ? GeminiVisionService(
            apiKey: GeminiConfig.apiKey,
            modelName: GeminiConfig.flashLite35,
            cooldowns: GeminiModelCooldowns.shared,
            requestTimeout: VisionConfig.ambientVisionTimeout,
          )
        : null,
    sharedScanBusy: vision.isScanning,
    shouldDeferScan: () =>
        ref.read(foregroundAssistantBusyProvider).value ||
        vision.isScanning.value,
  );
  ref.onDispose(scanner.dispose);
  return scanner;
});

/// The Snapshot Vision Engine (Module 6).
///
/// A single instance, and that matters for three separate pieces of state it
/// owns: the TFLite interpreter (loading it twice would cost a second copy of
/// the model in memory on a phone that has little), the camera's warm window
/// (two services would each keep a sensor open), and the cloud cooldown —
/// which is what stops a user asking twice from spending a minute of the
/// shared token allowance their own conversation runs on.
final snapshotVisionServiceProvider = Provider<SnapshotVisionService>((ref) {
  final cloud = VisionRouter(
    groq: GroqConfig.isConfigured ? CloudVisionService() : null,
    frontSnapGemini: GeminiConfig.isConfigured
        ? GeminiVisionCascade(
            apiKey: GeminiConfig.apiKey,
            cooldowns: GeminiModelCooldowns.shared,
            modelNames: GeminiConfig.frontSnapFallbackModels,
          )
        : null,
    sweepGemini: GeminiConfig.isConfigured
        ? GeminiVisionCascade(
            apiKey: GeminiConfig.apiKey,
            cooldowns: GeminiModelCooldowns.shared,
            modelNames: GeminiConfig.sweepFallbackModels,
          )
        : null,
  );
  final service = SnapshotVisionService(
    haptics: ref.read(hapticsServiceProvider),
    cloud: cloud,
  );
  ref.onDispose(service.dispose);
  return service;
});
