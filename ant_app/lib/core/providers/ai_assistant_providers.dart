import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/onboarding/providers/onboarding_providers.dart';
import '../config/gemini_config.dart';
import '../config/groq_config.dart';
import '../services/background_listening_service.dart';
import '../services/cloud_stt_service.dart';
import '../services/assistant_service.dart';
import '../services/fallback_assistant_service.dart';
import '../services/function_call_executor.dart';
import '../services/gemini_assistant_service.dart';
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
import '../services/vision/snapshot_vision_service.dart';
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
/// The three-pattern haptic language (Module 7). One instance, because the
/// hazard-alarm throttle is state that has to be shared across every caller.
final hapticsServiceProvider = Provider<HapticsService>((ref) => HapticsService());

/// The tone that says the microphone is open — item 59.
final earconServiceProvider = Provider<EarconService>((ref) {
  final service = EarconService();
  ref.onDispose(service.dispose);
  return service;
});

/// Asks for location permission during onboarding — item 50.
final locationPermissionPrimerProvider =
    Provider<LocationPermissionPrimer>((ref) => LocationPermissionPrimer());

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
  final gemini = GeminiConfig.isConfigured
      ? GeminiAssistantService(apiKey: GeminiConfig.apiKey, executor: executor)
      : null;

  // Gemini leads, Groq follows. This is the documented revert path in the
  // comment above — "if Groq's free tier ever stops being viable" — and the
  // 23 September session is what made that call.
  //
  // Groq is still the faster model by a wide margin, ~600ms against Gemini's
  // 2-3s, and on latency alone it would still lead. It does not lead because
  // it runs out. That session logged **41 rate-limit failures**: first the
  // per-minute ceiling, then the daily one, `TPD: Limit 200000, Used 199915`,
  // after which the model was locked out for 25 minutes at a stretch. A turn
  // costs ~3,300 input tokens — 76% of it the tool declarations, which are
  // sent whole on every turn — so the free tier affords roughly sixty turns a
  // day. A field test is longer than sixty turns.
  //
  // Prompt caching was supposed to rescue this and does not. Two sessions and
  // 286 billed requests, with a byte-stable tool list and system prompt,
  // report `cached=0` on every single line. Whatever the reason — the model,
  // the tier, or the field simply not being populated — it cannot be planned
  // around, and two rounds of work premised on it have now measured zero.
  //
  // Swapping the order costs latency on the common path and buys a provider
  // that finishes the day. Groq keeps its value as the fallback: when it has
  // budget it answers in under a second, and Gemini's occasional 503s under
  // load (see `gemini_config.dart`) now have somewhere to go. It also stops
  // chat competing with `VisionRouter` for the same Groq pool, which is what
  // `rate limited (shared ITPM with chat)` in the 22 September log was.
  //
  // With only one configured it becomes the primary outright. With neither,
  // null, and every caller already checks for that.
  if (gemini == null) return groq;
  return FallbackAssistantService(primary: gemini, secondary: groq);
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

/// Periodic, edge-only hazard scanning for blind users (Module 6).
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
  final service = SnapshotVisionService(haptics: ref.read(hapticsServiceProvider));
  ref.onDispose(service.dispose);
  return service;
});
