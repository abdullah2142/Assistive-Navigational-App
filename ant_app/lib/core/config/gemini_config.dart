/// Whether a real Gemini API key has been configured.
///
/// Mirrors `MapsConfig`'s pattern: every entry point into the AI Assistant
/// checks this flag first and falls back to Module 2's canned replies
/// instead of attempting a network call when it's false — consistent with
/// the app's "graceful degradation" philosophy (see `project_master_plan.md`).
///
/// Unlike the Maps key, this one is NOT hardcoded into source. A Gemini key
/// is a billable credential tied to a personal Google AI Studio account
/// (unlike the Maps key it doesn't sit behind a platform/bundle-ID
/// restriction), so it's passed at build/run time instead:
///
/// ```
/// flutter run --dart-define=GEMINI_API_KEY=your-key-here
/// # or, to avoid the key ever touching shell history:
/// flutter run --dart-define-from-file=dart_defines.local.json
/// ```
///
/// `dart_defines.local.json` (repo-root-relative: `ant_app/dart_defines.local.json`)
/// is git-ignored — `{"GEMINI_API_KEY": "..."}` — never commit a real key in it.
///
/// Speech-to-text (`SttService`) and text-to-speech (`TtsService`) both run
/// entirely on-device and need no key — only the Gemini conversational
/// engine is gated by this flag.
class GeminiConfig {
  GeminiConfig._();

  static const String apiKey = String.fromEnvironment('GEMINI_API_KEY');

  static const bool isConfigured = apiKey != '';

  /// Fast, low-latency tier — the right tradeoff for a conversational
  /// assistant that needs to feel responsive and keep API cost down (see
  /// "API Strategy & Cost Mitigation" in `project_master_plan.md`), not the
  /// heavier "Pro" tier the original module doc names. Change this single
  /// constant if a future key should use a different model.
  ///
  /// Deliberately pinned to a specific dated version rather than the
  /// `gemini-flash-latest` alias: live-tested both against the real API on
  /// 2026-09-01 and the alias was returning 503 "high demand" on every
  /// request (plausibly because every app defaulting to `-latest` hammers
  /// the same routing target) while this pinned version responded
  /// normally, function calling included. Trade-off: this will need
  /// bumping by hand again once Google deprecates it (their error messages
  /// name the replacement when that happens) — worth it for not being at
  /// the mercy of whatever the generic alias currently points to.
  ///
  /// **`gemini-3.7-flash` was tried on 2026-09-17 and is unusable.** Ten
  /// calls, ten failures, every one of them:
  ///
  ///     This model is currently experiencing high demand. Spikes in demand
  ///     are usually temporary. Please try again later.
  ///
  /// Not a quota problem — nothing was exceeded, and this is a 503 rather
  /// than a 429. It is the same overload this file already records for the
  /// `gemini-flash-latest` alias on 2026-09-01, and the likely reason is the
  /// same: a very new or very popular routing target with everybody on it.
  /// Worth retrying in a few weeks; there is nothing to fix on this side.
  ///
  /// **And back to `gemini-3.5-flash-lite` on 2026-09-21, on this branch.**
  ///
  /// `3.6-flash` was the pin for four days and is the better model, but its
  /// *rate* limits — RPM and RPD, not the daily quota that reset — are
  /// tighter than flash-lite's, and a tester round is exactly the bursty
  /// sustained load those bound. The 2026-09-03 exhaustion was not bad luck;
  /// it is what this tier does under a real session.
  ///
  /// So the trade is deliberate and narrow: a weaker model that answers every
  /// time beats a stronger one that stops answering halfway through a round.
  /// The eight prompt fixes on this branch exist precisely to lift
  /// flash-lite's behaviour, and they have never been tested against it — the
  /// 16-17 Sep bug list was flash-lite *without* them.
  ///
  /// It is also what the APK currently in Firebase runs (release 1.0.0 (1),
  /// built from `ff3dff9`). Holding the model still is what makes the next
  /// round a readable experiment: the prompt changed, and nothing else did.
  ///
  /// Revisit once billing is enabled on `gen-lang-client-0943644282` — which
  /// today has billing off, so it cannot be charged and cannot escape the
  /// free tier either. That is what actually buys headroom on 3.6. See
  /// `BillableApi.gemini`.
  ///
  /// Superseded reasoning, kept because the route here was not straight:
  ///
  /// Moved to `gemini-3.7-flash` on 2026-09-17.
  ///
  /// The route here was not straight, and the wrong turn is worth recording.
  /// `flash-lite` was picked on 2026-09-03 only because `gemini-3.6-flash`
  /// exhausted its **free-tier** quota under a day of heavy testing — a
  /// billing limit, not a capability judgement. Testers then reported the
  /// assistant as "lacking smartness", which flash-lite deserved, and a
  /// switch to `gemini-2.5-flash` was made on 2026-09-16 and never actually
  /// ran: the build it went out in could not reach Gemini at all (no
  /// `CLOUD_STT_API_KEY`, so nothing was ever transcribed to send), and its
  /// diagnostics log contains zero model turns.
  ///
  /// `2.5` was also a step *backwards* — two generations down — taken to
  /// escape a quota problem that is fixed with billing rather than with a
  /// smaller model. `3.7-flash` is the current generation at the full flash
  /// tier, which is where this should have gone from `3.6`.
  ///
  /// **Two things to confirm against the live API before trusting this**, per
  /// this file's standing convention of live-testing a pin:
  /// 1. It is GA rather than preview.
  /// 2. It handles all 24 `FunctionDeclaration`s without degrading. That is
  ///    the app's hard requirement — many models start ignoring tools, or
  ///    inventing ones, past about ten.
  ///
  /// Cost is bounded in the client, not by a budget alert — see
  /// `BillableApi.gemini` in `api_budget.dart` for why that distinction
  /// matters and what the ceiling actually is.
  /// Ordered recovery models. These are separate model quota buckets within
  /// the same Google Cloud project; they still share the project/API key.
  /// Keep the already tested lite model last in chat and front-snap fallback.
  /// Chat and vision intentionally share these model pools where their
  /// ordered lineups overlap; cooldowns are keyed by provider and model.
  static const String gemma4 = 'gemma-4-31b-it';
  static const String flash37 = 'gemini-3.7-flash';
  static const String flash36 = 'gemini-3.6-flash';
  static const String flash35 = 'gemini-3.5-flash';
  static const String flashLite35 = 'gemini-3.5-flash-lite';

  static const List<String> chatFallbackModels = [
    gemma4,
    flash37,
    flash36,
    flash35,
    flashLite35,
  ];

  static const List<String> frontSnapFallbackModels = [
    flash37,
    flash36,
    gemma4,
    flash35,
    flashLite35,
  ];

  static const List<String> sweepFallbackModels = [
    flash37,
    flash36,
    gemma4,
    flash35,
  ];

  /// Kept for older call sites and as the last-resort default.
  static const String modelName = 'gemini-3.5-flash-lite';
}
