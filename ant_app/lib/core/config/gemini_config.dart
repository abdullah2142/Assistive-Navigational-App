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
  /// So back to `gemini-3.6-flash`, which is where this should have stayed.
  /// The 2026-09-03 move off it was a *daily* free-tier quota exhaustion
  /// after a day of heavy testing, and daily quotas reset — two weeks have
  /// passed. It is the full flash tier at the current generation, which is
  /// what the testers' "lacking smartness" complaint actually wanted, and
  /// flash-lite only ever existed to dodge a rate limit.
  ///
  /// If it exhausts again under a real tester round, that is the signal to
  /// enable billing on `gen-lang-client-0943644282` — which today has
  /// billing off, so it cannot be charged and cannot escape the free tier
  /// either. See `BillableApi.gemini`.
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
  static const String modelName = 'gemini-3.6-flash';
}
