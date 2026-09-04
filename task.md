# Current State (as of 2026-09-04, Session 4 — crime engine has news/social/learned layers on top of the 2009 baseline; edge collectors built; nothing deployed or device-tested yet)

**Built and working:** Full onboarding for both roles (Disabled User + Caretaker), bilingual English/Bangla throughout with a first-screen language picker, voice-guided onboarding (on by default, for a blind user with no caretaker), Light/Dark theme independent of the Low Vision high-contrast accommodation, Split-Mode Dashboard (chat + suggested chips + clean map with directional arrow, fully bilingual), Guardian Hub (Overwatch map, Alert Center, Communication Hub with real voice memos, Remote Management — not yet bilingual, see below), self-service Settings for the Disabled User (a deliberate, flagged exception to "no settings menus" — see Module 2 Round 4), Crowdsource Reporting Hub with AI-summarized free-text reports, Passerby Helper overlay, Snapshot consent preference, real Google Maps rendering, and a real, **live-verified working** AI Assistant: on-device push-to-talk speech-to-text everywhere voice input was promised, and real Gemini (`gemini-3.6-flash`) function calling that changes onboarding settings and opens overlays via natural-language chat — confirmed end-to-end against the live API, Firestore, and UI (see Module 3 Round 3). **Module 4** adds a real, live-verified $w_1$ crime-safety backend (41 real Dhaka thana polygons in Firestore, a deployed `checkRouteSafety` Cloud Function doing point-in-polygon + time-of-day weighting) and a `request_route` Gemini tool wired end-to-end through the chat/voice assistant — the routing *feature* itself can't be exercised live yet because the Maps API key lacks Geocoding/Directions access (see below and Module 4's own section).

**Known gaps / next up:**
- **Two more real bugs found and fixed this session (2026-09-03), not yet device-tested**: (1) the app's own TTS narration was getting picked back up by the microphone and mistranscribed as user speech (confirmed live on the Passerby overlay's "Showing your screen now..." announcement) — `RecordConfig`'s `echoCancel`/`noiseSuppress` flags (both default `false`, previously unset) are now enabled on every recording session (`CloudSttService`, `WakeWordService`), engaging the platform's acoustic echo canceler. (2) The hazard report's voice "submit" detection was unreliable because it asked the recognizer to decide, in one pass over a single long run-on utterance, whether a description ended with a submit command — rebuilt to speak a short, separate "say more, or say submit" re-prompt before each re-listen instead of silently looping, giving every submit-or-continue decision its own short clean window, plus a short-utterance fuzzy fallback for a near-miss on the exact phrase. Extended the same pattern (loop + accumulate + fuzzy submit phrase, replacing the old "auto-submit on any first utterance" behavior that could cut a user off mid-thought) to the Passerby message composer for consistency, per the user's explicit ask that voice behavior be uniform everywhere, not just in the hazard report.
- **Module 4's routing feature is code-complete and wired into the AI Assistant, but blocked at runtime**: the Maps API key currently in use returns `REQUEST_DENIED` for both the Geocoding API ("must enable Billing") and the Directions API ("legacy API...not enabled for your project") when called directly — confirmed via direct `curl` against the real endpoints, not an app bug. Needs either billing + those two APIs enabled on whichever GCP project that personal key belongs to, or (better, given the note below) a proper key created on the `ant-assistive-nav` project (which already has Blaze billing) with Maps JS/Android/iOS SDK, Geocoding API, and Directions API all enabled and appropriately restricted. See Module 4's section for exact repro.
- **`CloudSttService` is configured and confirmed live** (2026-09-02/03) — `CLOUD_STT_API_KEY` added to `dart_defines.local.json`, mic-flicker fix confirmed on-device (mic stayed stable through a full "go back" round trip). Then **widened to every voice entry point in the app** (chat mic, hazard report, My Settings, passerby composer) by injecting `CloudSttService` into `SttService` itself, adapting the continuous stream to `listenOnce()`'s single-utterance contract — see `SttService._listenOnceViaCloud`. **Found and fixed a real bug in that adapter the same session**: it used one short silence timeout for both "waiting for the user to start talking" and "gap after they've started" — the natural reaction-time gap after a wake-word buzz occasionally exceeded the short one, silently ending the session before anything was captured. Fixed with a separate, longer initial-silence timeout (8s) that only shortens to the real `pauseFor` once actual speech has been heard.
- **Standing design principle, stated explicitly by the user (2026-09-02)**: for a user who can't see the screen, the app should *dictate every step to the user and accept a voice request at every stage* — not just isolated voice entry points. Treat this as the north star the rest of the backlog below is building toward (onboarding voice input, hazard-report voice navigation, the Passerby overlay's own TTS-announce-and-listen loop just added), not a single task to close — audit each screen against it as it comes up rather than assuming today's voice coverage is the ceiling.
- **User-requested backlog (2026-09-02) — all but (4) implemented 2026-09-03, none yet device-tested (build is clean — `flutter analyze` 0 issues, `flutter build apk --debug` succeeded — but install is currently blocked by the same MIUI `INSTALL_FAILED_USER_RESTRICTED` restriction as before; needs the phone unlocked to retry)**:
  1. **Voice input during onboarding** — new `OnboardingVoiceChoice`/`listenForVoiceChoice` (`features/onboarding/widgets/onboarding_voice.dart`) wired into every single-choice screen (role, vision, mobility, deaf/hearing, theme, snapshot consent, language picker) via a new `OnboardingScaffold.voiceChoices` param, plus screens with sequential questions (cognitive anxiety's two yes/no, verbosity+voice) driving the same listener twice and auto-continuing once both are answered — no way for a blind user with no screen reader to otherwise find the Continue button. Free-text fields (home/safe-place address, contact name/phone, custom passerby message, pairing code) got a `VoiceDictateButton`/inline mic instead. The passerby-messages screen's mic button, previously a placeholder SnackBar, is now real dictation.
  2. **Auto-dark theme for `visionLevel == none`** — `OnboardingController.setVisionLevel` now defaults those profiles to `ThemePreference.dark` and skips the now-pointless theme question entirely (same as Low Vision skips it in the other direction), rather than just leaving Dark as an available choice.
  3. **Background/lock-screen wake-word** — new `WakeWordForegroundService.kt` (Android, no audio code of its own — just an ongoing-notification + partial-wake-lock foreground `Service` whose only job is stopping the OS from freezing/killing the process) started/stopped from Dart (`BackgroundListeningService`) via `ChatStreamPanel`'s new `WidgetsBindingObserver`, tied to `AppLifecycleState` and `wakeWordEnabled`. New manifest permissions: `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MICROPHONE`, `WAKE_LOCK`, `POST_NOTIFICATIONS`. **This is the one item that most needs real-device verification** — MIUI in particular is known to aggressively kill backgrounded apps regardless of a foreground service unless the user also manually grants "no restrictions"/autostart under battery settings (same class of friction as the install-permission issue already hit this session); the code is a sound, standard pattern but unverified live.
  4. Mascot wake-word rename + real model training — **explicitly excluded from this round, still not started.**
  5. **Real Google Cloud Text-to-Speech** — new `CloudTtsService`/`CloudTtsConfig`, calling the `text:synthesize` REST endpoint and playing the returned MP3 via `audioplayers`; `TtsService` prefers it and falls back to on-device `flutter_tts` on any failure. Also finally *uses* `UserProfile.voiceId` (collected since onboarding, never actually read before now) to pick a Wavenet/Neural2 voice by gender. **Needs one manual GCP Console step before it does anything**: `CloudTtsConfig` reuses `CLOUD_STT_API_KEY` by default, but that key was deliberately restricted to only the Speech-to-Text API when it was set up — needs "Cloud Text-to-Speech API" enabled on the project *and* added to that key's API restrictions (or a separate `CLOUD_TTS_API_KEY`). Until then it fails closed to the on-device voice, same as if unconfigured.
  6. **Streamed Gemini replies** — `GeminiAssistantService.converse` now takes `onPartialText` and uses `generateContentStream` instead of `generateContent`; `ChatController.sendFreeText` fills the chat bubble in progressively as chunks arrive instead of only after the full round trip (function-call turns are unaffected — they never had streamable text to begin with).
  7. ~~Crowdsource Reporting Hub voice-navigable end-to-end~~ — done 2026-09-03 (see prior entry below). Its "adapt options to context/profile" leftover is **also now done**: Accessibility Block's sub-category list reorders by `UserProfile.mobilityAid` (wheelchair → curb cuts/ramps/vendors first; white cane → tactile paving/blocked path first), applied consistently to both the tap list and the voice narration/matching.
- **Two real bugs found live on-device during the above round's first retest (2026-09-03), both fixed and reverified on-device the same session**: (1) tapping a role-selection option (or any onboarding choice) could reload the same screen — root cause: `OnboardingFlowScreen`'s `AnimatedSwitcher` keeps the *outgoing* screen mounted (with its own narrate-then-listen loop still running) for its ~250ms cross-fade, so the previous step's mic session could still be open when the next step's own screen started its own listen session, and the stale one could pick up the new screen's spoken narration and misfire. Fixed with a `stepGeneration` counter on `OnboardingState`, bumped on every `_goTo`/`goBack` and checked by every screen's listen loop as an immediate cancellation signal (not just widget `dispose()`, which is what was arriving too late) — plus `_goTo`/`goBack` now stop the mic outright the instant a step changes. (2) `fuzzyVoiceMatch`'s first-tier check was a raw substring test across the whole phrase — saying "male voice" matched the *female* voice option, because the label text "female" itself contains "male" as a literal substring. Rewritten to compare whole word tokens only (with the same near-miss tolerance for a single word, gated to only apply between words of comparable length) — confirmed this fixes that exact case without breaking the existing near-miss tolerance for a dropped syllable. Also added a global `PlatformDispatcher.instance.onError` handler in `main.dart`: `google_speech`'s `EndlessStreamingService` can throw an uncaught "Bad state: Cannot add new events after calling close" from deep in its own internals when a stream session is torn down and restarted — not reachable from any try/catch in this app's code, confirmed still happening (now caught/logged quietly instead of spamming) after the above fixes, so it's a latent bug in that third-party package, not this app's session-lifecycle code.
- **Also added same session, from live feedback**: the emergency-contacts screen (Magic Button contacts) had per-field dictation buttons but no orchestrated voice flow, unlike every other multi-field onboarding screen — now narrates "say the contact's name" → listens, "now say their phone number" → listens, "say add to save this contact and add another, or continue if you're done" → listens, loops back for another contact on "add" (speaking a confirmation), or validates at least one contact exists before advancing on "continue" (speaking the existing error and re-listening if not).
- **Local (offline, no-LLM) function-call matching — 2026-09-03, explicit user request to cut Gemini latency/token spend on routine commands**: `FunctionCallExecutor` (new) is `GeminiAssistantService`'s old `_applyFunctionCall`/`_confirmationFor` logic pulled out into its own class, independent of any Gemini API key — the single source of truth both the LLM function-calling path and a new local path delegate to, so a setting change behaves identically either way. `LocalIntentMatcher` (new) recognizes common settings-change/trigger commands via conservative, multi-word-phrase pattern matching (deliberately never a bare single word — free chat has far more false-positive room than onboarding's closed choice screens) in both languages: theme, language, verbosity, text size (relative bump, resolved against the live profile in `ChatController`), wake word on/off, auto-listen on/off, deaf/hearing mode, crowded/complex sensitivity, `open_passerby_helper` ("show my screen"/"স্ক্রিন দেখাও" — the exact phrase that was silently failing earlier this session), `open_hazard_report`, `request_route` (destination extracted via regex, with a Bangla negation guard so "I will *not* go to X" doesn't trigger routing), and `pair_with_caretaker` (6-digit code + a pairing-flavored word, to avoid colliding with an ordinary phone number). Wired into `ChatController.sendFreeText` — the single choke point for both typed and voice chat input — checked before Gemini is ever touched; falls through to Gemini unchanged for anything not confidently matched. Deliberately **not** handled locally at all: `add_emergency_contact`/`remove_emergency_contact`/`add_passerby_message`/`remove_passerby_message` — these need free-text content pulled out of an arbitrary sentence, where a wrong local guess would silently corrupt real contact/message data; always goes to Gemini. **Not yet device-tested.**
- **Found and fixed a real, previously-invisible bug in the main chat**: `ChatController.sendFreeText`'s catch block was a bare `catch (_)` — *any* Gemini failure (network, quota, malformed response, anything) was silently swallowed with zero logging, falling back to `OfflineIntentMatcher`, which only recognizes a handful of safety keywords (help/stop/where-am-i/emergency). Added real logging (`[Chat] -> Gemini:` / `[Chat] <- Gemini in Xms:` / `[Chat] Gemini call FAILED ... : $e`) — **root cause confirmed same session**: the pinned model (`gemini-3.6-flash`) had hit "You exceeded your current quota" after a full day of heavy live testing, not an app bug — "স্ক্রীন দেখাও" was being transcribed and sent correctly the whole time. Verified `open_passerby_helper` still fires correctly for that exact phrase via direct `curl` against a lighter model with its own separate (non-exhausted) quota bucket, then switched `GeminiConfig.modelName` to `gemini-3.5-flash-lite` — **not yet device-tested**.
- **Found and fixed a second critical Cloud STT bug the same session** (this one a real regression from the widening above): `_listenOnceViaCloud`'s Dart-side timeout logic (`finish()`) stopped the stream on a silence/ceiling timeout but never told the caller the session was over — no `onResult(..., isFinal: true)` ever fired unless Cloud STT's own server sent a genuine final result first. Every caller waiting specifically for that final signal to act (send the chat message, select a hazard-report option by voice, auto-submit a passerby message) silently never heard back — explained several very different-looking live symptoms (text sitting unsent, voice selection "not picking up" despite clear speech, Show Screen no longer auto-opening) as one root cause. Fixed by synthesizing that final call with whatever text was last captured whenever a timeout (not a real final result) ends the session.
- **Crowdsource Reporting Hub's voice flow (from the "done 2026-09-03" entry above) rebuilt again after live testing exposed two more gaps**: (1) the auto-listen was one-shot per step — after the first utterance ended, nothing restarted listening, so a "submit"/"পাঠাও" voice command spoken as a separate follow-up utterance was never heard at all; (2) option matching required the *exact* full label as a substring, rejecting a clear, unambiguous near-miss live ("চলাচলে বাধা" finalized as "চলে বাধা" — one dropped syllable). Rebuilt both `_listenForOption` and the describe-step's listener as indefinite loops (keep re-listening until a match/submit or the step changes, not just one attempt), added word-level fuzzy matching as a fallback to the exact-substring check, and made dictation *accumulate* across multiple utterances (`_committedDescription`) instead of each new one replacing the last — directly per the user's explicit principle: a user who stumbles or pauses to think should still have everything they said count, not just their single most recent utterance. **Not yet device-tested.**
- Also added this session: a consistent TTS voice (`TtsService` was calling `setLanguage` but never `setVoice`, leaving voice selection up to the engine's own not-fully-deterministic default logic — confirmed live as the cause of the assistant's voice audibly switching between male and female with no setting change; now pins one specific voice per locale on first use and reuses it), and a reliable app-controlled "listening started" haptic cue (the OS's own mic-start sound wasn't consistently present) — centralized in `SttService.listenOnce` plus the Passerby overlay's own continuous listener. **Not yet device-tested.**
- Guardian Hub / Remote Management screens are still English-only (Disabled User-facing screens are fully bilingual; caretaker-facing ones aren't yet).
- Wake-word detection ("Hey ANT", via openWakeWord) is built and compiles clean on all platforms, but uses a **placeholder pretrained phrase** ("Hey Jarvis" — a real custom-trained model needs external GPU-backed training infrastructure this sandbox doesn't have) and **has not been tested on a real device** (no microphone exists in this sandbox) — off by default, opt-in via My Settings or chat. See Module 3 Round 4 before relying on it.
- The Google Maps key in use is a personal/experimentation key (user-provided), not tied to the `ant-assistive-nav` GCP project — fine for dev, should be replaced and access-restricted before any real release.
- A couple of throwaway test profiles/reports are still in the live Firestore project (safety classifier blocked automated cleanup — see Module 2 Round 4).
- `functions/`'s Node.js 20 runtime is deprecated (decommissioned 2026-10-30) — needs bumping before then.
- Budget kill-switch guardrail is deployed but not fully armed yet — two account-level steps (Pub/Sub-connect the budget alert, grant Billing IAM role) are intentionally left for the user; see Module 3 Round 3.

**Setup notes:** Firebase project `ant-assistive-nav` on **Blaze** (billing enabled as of Module 3 Round 3; a $2 budget alert is set). `firebase.json` now has both `firestore` and `functions` blocks. Cloud Functions (`onUserRoleWritten`, `disableBillingOnBudgetExceeded`) are deployed — `npx firebase-tools deploy --only functions` from the repo root (no `gcloud` CLI in this sandbox; `firebase-tools` via `npx` was already authenticated). Web preview served via `.claude/launch.json`'s `ant_app-web` config (static `flutter build web` output, not a live dev server — rebuild before previewing changes; `autoPort: true` since the fixed port collides across concurrent sessions). The real Gemini key lives at `ant_app/dart_defines.local.json` (gitignored, never commit it) — build/run with `--dart-define-from-file=dart_defines.local.json`. For live debugging (unminified stack traces), prefer `flutter run -d web-server --web-port=<port> --dart-define-from-file=dart_defines.local.json` over `flutter build web` — the latter doesn't support `--track-widget-creation` and browser console traces come back minified.

---

# Module 1 — Onboarding & Dual-Role Architecture

Source: `01_module_plan_onboarding.md`

## Environment
- [x] Flutter SDK installed & verified (`flutter doctor`)
- [x] Android SDK installed (platform 36, build-tools 28.0.3 & 36.0.0), licenses accepted
- [x] Java JDK 17 installed
- [x] Linux desktop toolchain + Chromium installed
- [x] Firebase project created — `ant-assistive-nav` (Firestore in `asia-south1`/Mumbai, closest to Dhaka)
- [x] `flutterfire configure` run — `lib/firebase_options.dart` + `android/app/google-services.json` generated (android/ios/web)
- [x] Firebase Auth (Anonymous) and Firestore (Standard edition, production-mode rules) enabled
- [x] Firebase CLI + FlutterFire CLI installed and authenticated
- [ ] Google Maps Platform API key obtained (needed starting Module 2)
- [ ] iOS `GoogleService-Info.plist` (didn't generate — no Xcode on this Linux machine; not a blocker for Android/web)

## Step 1: Role Selection & Pairing
- [x] Launch screen: "I need assistance" / "I am a Caretaker"
- [x] Caretaker: generates 6-digit pairing code, writes to `pairingCodes/{code}`, waits (live Firestore stream)
- [x] Disabled User: enters code, redeemed transactionally, links `pairedUserId` on both profiles
- [x] Pairing codes expire after 15 minutes, single-use
- [x] "I don't have a caretaker" option on the code-entry screen — Disabled User can skip pairing entirely and still use every feature that doesn't depend on a caretaker (Magic Button contacts, safe havens, hazard detection); `pairedUserId` just stays null and can be set later via the AI chat (Module 3)
- [x] Verified live against real Firebase: code generation, redemption, bidirectional `pairedUserId` linking, and the no-caretaker skip path all confirmed working

## Step 2: Granular Disability Profiling & Calibration
- [x] Vision level question (none / low / full)
- [x] Visual Calibration Phase (contrast + font-size sliders with live preview) — shown only if low vision
- [x] Mobility aid question (white cane / wheelchair / unassisted)
- [x] Cognitive & anxiety threshold questions (crowded places, complex instructions)
- [x] Deaf/hearing profiling question

## Step 3: AI Verbosity & Safety Nets
- [x] Verbosity selection (Minimalist / Descriptive) + voice selection
- [x] Magic Button trusted contacts (add/remove, min. 1 required, validated live)
- [x] Safe Havens (Home required, Safe Place optional)

## Step 4: Automation Lock-In
- [x] Summary + confirmation screen
- [x] Writes `onboardingComplete: true`, hands off to placeholder (Module 2 dashboard)

## Backend / RBAC
- [x] `AuthService` — anonymous sign-in on role selection, forces ID-token refresh to avoid a web auth-propagation race (see Known Issues)
- [x] `firestore.rules` — profile + pairing-code access rules, **deployed** to `ant-assistive-nav`
- [ ] `functions/index.js` (`onUserRoleWritten` custom-claims trigger) — written but **not deployed**; Cloud Functions require the Blaze (pay-as-you-go) plan, project is currently on the free Spark plan. RBAC claims are not yet live — deferred until billing is upgraded.

## Verification
- [x] `flutter analyze` — no issues
- [x] `flutter test` — smoke test passes
- [x] Full manual run in Chromium against the live Firebase project — complete Caretaker + Disabled User flows exercised end-to-end, Firestore data inspected and confirmed correct, test data cleaned up afterward

## Known issues found & fixed during verification
- **Web auth race (fixed):** `signInAnonymously()` resolving didn't guarantee the ID token had propagated to the Firestore client yet, causing a spurious `permission-denied` on the very first write. Fixed by forcing `user.getIdToken()` in `AuthService.ensureSignedIn()` for both the newly-signed-in and already-signed-in paths.
- **Pairing rule gap (fixed):** the pairing transaction needs to write `pairedUserId` onto *both* the caretaker's and disabled user's profiles, but the original rules only allowed a user to write their own doc. Added a narrow rule permitting one user to stamp their own uid onto another *currently-unpaired* profile's `pairedUserId` field only (no other field), relying on Firebase uids being unguessable — see the comment in `firestore.rules`.
- **Cosmetic:** the "add at least one contact" error message on the Magic Button screen doesn't clear itself the moment a contact is added — only on the next Continue press or step change. Low priority.
- **Design note (not a bug):** onboarding progress is not resumed from Firestore if the app is killed/reloaded mid-flow — a restart always begins at role selection. Worth revisiting in a later module if partial-onboarding recovery matters.
- **Testing caveat (not a bug):** Firebase Auth's web session lives in a per-origin IndexedDB store (`firebaseLocalStorageDb`), shared by *every* tab of the same browser at that origin — not per-tab. Two tabs of one browser pointed at the same dev URL are the same anonymous identity, so picking a different role in each tab looks like flipping one account's role and is correctly rejected by the immutable-role rule. To test Caretaker + Disabled User side by side, use two separate browsers (or a normal + incognito window) — confirmed working that way. Real devices are unaffected since each has isolated storage.
- **Testing caveat (not a bug):** a browser tab left backgrounded for a long stretch during heavy multi-tab testing was observed to freeze on a stale rendered frame — the new UI was confirmed present in the compiled JS, in a widget test, and in a brand-new tab, but the old backgrounded tab kept painting an outdated frame until closed and reopened fresh. If a tested change doesn't appear to show up, try a brand-new tab before assuming the code is wrong.

---

# Module 2 — Core Application & UI

Source: `02_module_plan_ui_core.md`

## Step 1: Role-Based Routing
- [x] `AppRoot` — reads `authStateProvider` then `profileStreamProvider(uid)`; routes to Guardian Hub / Split-Mode Dashboard once `onboardingComplete`, else onboarding
- [x] Fixed a Module 1 gap found while wiring this: `finishCaretakerSetup()` never persisted `onboardingComplete: true`, so a Caretaker could never route past onboarding on a later launch — only the Disabled User's `confirmLockIn()` did. Now both paths persist it.
- [x] Reads `role`/`onboardingComplete` off the Firestore profile, not a verified Auth custom claim (the `onUserRoleWritten` claims function is still undeployed — Spark plan, no billing). Documented as a swap-later point in `app_root.dart`.

## Step 2: Split-Mode Dashboard (Disabled User)
- [x] Dynamic Chat Stream (top 60%) — message bubbles, typing indicator, mic button (stub — Module 3 wires real STT), suggested chips
- [x] `ChatController` stub AI — canned replies only; `03_module_plan_ai_assistant.md` replaces `_stubReply`/`sendFreeText` internals with real Gemini function calling without touching the controller's public API
- [x] Clean map (bottom 40%) — POI/transit labels stripped via a Maps JSON style, giant static directional arrow overlay (routing engine to drive rotation is Modules 4-5)
- [x] `MapsConfig.isConfigured` gate — no Google Maps API key obtained yet (task.md Module 1 note), so every map surface renders `MapUnavailablePlaceholder` instead. Android manifest / iOS Info.plist have the required placeholders wired so flipping the flag is the only step left.

## Step 3: Guardian Hub (Caretaker)
- [x] Overwatch Map — live-streams `liveLocations/{uid}`; empty state until Module 8's background isolate starts writing it
- [x] Alert Center — live-streams `alerts/{uid}/items`, pulsing red card + resolve action; populated by Modules 8-9. Audible alarm needs an audio package, left for whichever of those modules adds it.
- [x] Communication Hub — real Async Memo + Snapshot Request writes to `communications/{uid}/messages`, recent-message list
- [x] Remote Management — real settings screen editing the paired Disabled User's `UserProfile` directly (the deliberate exception to "No Settings Menus," since only the Disabled User's cognitive load is the constraint)

## Step 4: Essential User Overlays
- [x] "Show Screen" Passerby Helper — forces landscape, solid `#E5C05C`, massive black text, 4 canned messages (dynamic dictation is Module 3)
- [x] Crowdsource Reporting Hub — glassmorphism overlay, 3 categories x drill-down sub-options, description field, real write to `hazardReports`. Anti-spam thresholds, AI summarization, and decay cron are explicitly Module 5.

## Backend / Firestore
- [x] New rules for `liveLocations`, `alerts/{uid}/items`, `communications/{uid}/messages`, `hazardReports`, and a scoped caretaker-can-edit-paired-profile rule (role/uid/pairedUserId still immutable even to the caretaker) — all use a `get()` check against the caller's own profile to verify the pairing, never trusting a client-supplied uid
- [x] `firebase.json` + `.firebaserc` added at the repo root (didn't exist before) so `firebase deploy --only firestore:rules` has somewhere to point; deployed to `ant-assistive-nav` and confirmed live
- [x] `.claude/launch.json` port changed 5000 → 5057 (another session's dev server already held 5000)

## Verification
- [x] `flutter analyze` — no issues
- [x] `flutter test` — all 3 tests pass (onboarding smoke test updated for the new `AppRoot` entry point + 2 new Guardian Hub widget tests)
- [x] Full manual run in Chromium against the live Firebase project (Disabled User path): role selection → skip pairing → vision/mobility/cognitive/deaf/verbosity/voice → add trusted contact → safe haven → lock-in → landed on Split-Mode Dashboard automatically via `AppRoot`
- [x] Live-verified: chat send (button), suggested chip → stub reply, Passerby Helper overlay (exact yellow/black per spec), Crowdsource Hub full drill-down → real Firestore write (hit `permission-denied` before the rules deploy, succeeded after — confirms the rules file is correct, not just plausible), map placeholder gate
- [ ] **Not live-verified: Guardian Hub / Remote Management against a real paired Caretaker session.** A genuine two-role E2E needs two independent Firebase Auth sessions; per Module 1's own testing notes, tabs in one browser share the same `firebaseLocalStorageDb` origin and can't hold two identities at once, and no service-account credentials were available here to script around it safely. Covered instead with widget tests (`test/guardian_hub_test.dart`) that override the Firestore stream providers directly — confirms the widget tree builds and both the not-paired and paired states render, but doesn't exercise real Firestore reads/writes for that side. Worth a manual pass in two separate browser windows before shipping.

## Known issues / follow-ups
- **Enter key doesn't submit chat text on Flutter web** (observed during manual testing) — the send button works reliably and was used for all verification; unclear whether this is a `TextField.onSubmitted` interaction quirk specific to the browser-automation tool's synthetic key events, or a real gap. Worth a quick check with an actual keyboard before Module 3 wires up voice input alongside it.
- **Test data left in the live project:** two throwaway Disabled User profiles and two `hazardReports` docs from manual verification across both rounds. Deleting them was blocked by the auto-mode safety classifier (destructive Firestore delete); clean up manually via the Firebase console if desired.
- **Design note (not a bug):** the giant directional arrow is static (always points up) since there's no routing engine yet to drive it — Modules 4-5 will feed it real turn instructions.

## Round 2 — user feedback (more sub-options, AI-summarized "other", passerby ask-first, theme + passerby-message onboarding)
- [x] **Crowdsource Hub**: each category expanded to 8 concrete sub-options (was 3-4) plus a `kHazardOtherSubCategory` ("Something else") entry in every category
- [x] **"Something else" → AI-summarized free text**: required description field + mic-stub button; a live "AI summary preview" (`summarizeForReport()` in `hazard_report.dart`) shows exactly what will be submitted, recomputed on every keystroke. It's local string manipulation (trim/collapse whitespace/word-boundary truncate/capitalize) — swapping it for a real Gemini call is the entire Module 5 integration point, by design
- [x] **Passerby Helper now asks first**: tapping the chip opens `PasserbyMessagePicker` (a bottom sheet) instead of jumping straight to a hardcoded message — pick one of the profile's own messages, or compose + a mic-stub, before the full-screen overlay shows
- [x] **Onboarding: Light/Dark theme question** — new `ThemePreferenceScreen` step, asked only when not Low Vision (Low Vision's forced high-contrast theme makes the question moot). Added `AppTheme.standardDark()` using the exact `#120F1D`/`#EAE8F2` hexes from the UI module plan (previously only the light half of "Standard Calm" existed); also corrected light-theme `background`/`textPrimary` to the plan's exact hexes (`#F8F7FA`/`#2D2A3B`, were very slightly off). Applied via a `Theme(...)` wrap in `AppRoot._resolveTheme()` around the routed dashboard — scoped to the Disabled User only, Guardian Hub always renders light (Caretaker onboarding is pairing-only, doesn't ask)
- [x] **Onboarding: Passerby message picker** — new `PasserbyMessagesScreen` step (after Magic Button contacts) suggests messages contextual to what's already known (vision level, deaf/hard-of-hearing, wheelchair use), pre-checks 3, lets the user toggle any + add custom ones. Saved to a new `UserProfile.passerbyHelperMessages` field; the dashboard falls back to the static `kPasserbyHelperMessages` default if a profile has none (e.g. pre-existing profiles from before this field existed)
- [x] Follow-up fix while wiring dark mode: several dashboard widgets (`ChatBubble`, `SuggestedChipRow`, `MapUnavailablePlaceholder`) hardcoded `AppColors.divider`/`AppColors.background` regardless of theme — switched to `Theme.of(context).dividerColor`/`scaffoldBackgroundColor` so dark mode actually looks right instead of light-colored borders on a dark background
- [x] `flutter analyze` clean, all 3 tests pass, full manual re-verification in Chromium (fresh identity): new onboarding steps render with correct contextual suggestions, dark theme applies correctly across the dashboard, expanded categories scroll correctly in the modal, "Something else" live-summarizes and submits successfully to live Firestore, passerby picker shows this profile's own 5 messages and the chosen one renders correctly in the overlay

## Round 3 — voice-guided onboarding, on by default (for a fully blind user with no caretaker)
- [x] Added `flutter_tts` — on-device text-to-speech, deliberately *not* Module 3's Google Cloud TTS/Gemini stack. Its only job is making onboarding itself navigable by ear from screen one, before a solo blind user has necessarily found or enabled their OS screen reader; Module 3 can layer richer Bangla narration on top later without touching this
- [x] `lib/core/services/tts_service.dart` + `lib/core/providers/tts_providers.dart` — `ttsEnabledProvider` defaults to **true** per the request; used `flutter_riverpod/legacy.dart`'s `StateProvider` since Riverpod 3.x moved it out of the main export
- [x] `OnboardingScaffold` (the shared shell nearly every onboarding screen already used) now auto-speaks `title + subtitle + spokenOptions` the instant a screen lands, via `initState` + a post-frame callback — this alone covered every screen for free; a speaker icon in the app bar (always visible, even on the very first screen which previously had no app bar at all) toggles it off/on
- [x] Threaded `spokenOptions` through every onboarding screen so a blind user hears their actual tappable choices, not just the header: role selection, pairing-code entry (explicitly calls out the "I don't have a caretaker" button), vision, visual calibration, mobility, cognitive/anxiety toggles, deaf/hearing, verbosity+voice, magic button contacts, passerby messages (built dynamically from the suggestion list), safe havens, and — most detailed — Lock-In, which now speaks the *entire* profile summary before asking for confirmation
- [x] **Auto-mute on "Yes" to deaf/hard of hearing**: spoken guidance is useless noise for someone who can't hear it, so `setDeafHearing(true)` flips `ttsEnabledProvider` off immediately — verified live, the speaker icon flips to muted the instant that question is answered
- [x] `flutter analyze` clean, all 3 tests pass. Live-verified in Chromium: speaker icon defaults on, toggles correctly, persists across screens, survives a `SpeechSynthesisErrorEvent` without crashing (this sandboxed browser has zero installed TTS voices — confirmed via a direct `speechSynthesis` probe showing `voicesLength: 0` — so audio itself can't be heard here; a real device/browser has voices installed and will speak normally through the same `flutter_tts` code path), and the deaf-hearing auto-mute fires correctly on the very next screen after answering "Yes"

## Round 4 — AI-summarized custom messages everywhere, self-service settings, and a real Maps key
- [x] **Shared AI-summarizer**: moved `summarizeForReport` out of `hazard_report.dart` into `core/utils/ai_text_summarizer.dart` as `summarizeText` — it now has two call sites (Crowdsource Hub, and the new one below), so it earned a shared, non-feature-specific home
- [x] **Onboarding's "write your own" passerby message now goes through AI summarization too**, with a mic-stub button added for parity with every other free-text entry point in the app. Live "AI summary preview" shown while typing; the *summarized* text is what actually gets added to the list — verified live with a 241-character rambling input correctly condensed to a clean, truncated sentence
- [x] **Self-service Settings for the Disabled User** (`lib/features/dashboard/screens/my_settings_screen.dart`) — reachable via a single `tune` icon in a deliberately minimal app bar on the Split-Mode Dashboard (not a menu bar, one button). Covers every onboarding-collected field: vision, theme, text size, mobility, cognitive/anxiety toggles, deaf/hearing, verbosity, voice, Magic Button contacts (add/remove), passerby messages (add-with-AI-summary/remove), safe havens. Changes save immediately to Firestore, same as Remote Management.
  - **This is a deliberate, flagged exception to the "No Settings Menus for Users" architectural rule** (`claude.md`, `ai_developer_prompt.md`, `project_master_plan.md` all state settings should only change via chat/voice function calling or a Caretaker's Remote Management). Module 3 doesn't exist yet, and someone with no caretaker currently has *no other way* to change anything after lock-in — this is the bridge until Gemini function calling exists, not a replacement for it. Worth revisiting/shrinking once Module 3 ships.
- [x] **Found and fixed a real theming bug while testing the above live**: `AppRoot` had wrapped only its *own* route's build output in `Theme(...)`, but `Navigator.push` (used by `MySettingsScreen`, `RemoteManagementScreen`, the Crowdsource Hub, etc.) inserts new routes into the Navigator's `Overlay`, which sits structurally outside that per-route wrapper — so every pushed screen was silently falling back to `MaterialApp`'s hardcoded light theme regardless of the user's Dark preference. Fixed by moving theme resolution up to `MaterialApp.theme` itself (new `core/theme/theme_resolver.dart`, watched reactively in `main.dart`), so it now applies uniformly to every route. Confirmed live: Settings screen picked up Dark correctly after the fix, both on first render and after a full page reload.
- [x] **Real Google Maps API key wired in** (user-provided, personal/experimentation key — not tied to the `ant-assistive-nav` GCP project, fine for dev but should be replaced with a properly restricted project key before any real release). `MapsConfig.isConfigured` flipped to `true`; key added to Android manifest, iOS `AppDelegate.swift` (`GMSServices.provideAPIKey`), and `web/index.html`'s Maps JS script tag. **Live-verified real map tiles rendering** on the Split-Mode Dashboard (road labels, Google attribution, Map Data/Terms footer) — first real confirmation the map integration itself (not just the placeholder gate) works end-to-end.
- [x] `flutter analyze` clean, all 3 tests pass throughout (enabling the real Maps key didn't break the test suite — no widget test path currently instantiates `GoogleMap`, confirmed by inspection and a clean test run).

## Round 5 — text-size bug fix, Bangla/English UI language, Light/Dark decoupled from Low Vision, Snapshot consent setting, real Voice Memos
- [x] **Text-size dial bug, fixed**: both `MySettingsScreen` and `RemoteManagementScreen` sliders wrote to Firestore on every drag tick and read their position back from the async profile stream — so the slider fought the drag instead of moving. Fixed with local optimistic state (`onChanged` updates a local field immediately, `onChangeEnd` persists once on release) — the standard pattern for a slider bound to remote-persisted state.
- [x] **Bangla/English UI language** — a real, working toggle, not just infrastructure:
  - New `AppLanguage` enum + `UserProfile.language` field, chosen on a brand-new **first-ever onboarding screen** (`LanguageSelectionScreen`, before role selection — a Bangla-only reader needs to understand that screen too). It's self-bilingual by necessity (shows "English" and "বাংলা" natively, announces in both languages in sequence via TTS) since there's no chosen language yet to pick one representation.
  - `core/localization/onboarding_strings.dart` and `dashboard_strings.dart` — two large classes (`Onboarding.of(lang)` / `Dashboard.of(lang)`) holding every UI string in both languages.
  - **Full bilingual coverage**: the entire onboarding flow (all 17 screens, both Disabled User and Caretaker paths), `MySettingsScreen`, and `TtsService` (speaks in the matching locale — `bn-BD` or `en-US` — via `AppLanguage.ttsLocale`).
  - **Not yet translated** (English-only, Bangla strings already written and ready in `dashboard_strings.dart`, just not wired in): the Split-Mode Dashboard's chat/chips/map chrome, Passerby Helper overlay/picker, Crowdsource Reporting Hub, and all of Guardian Hub. Flagged clearly rather than silently left half-done — wiring these in is now mechanical (the strings exist), a good next pass.
  - `summarizeText` (the AI-summarizer stub) moved from `hazard_report.dart` into a shared `core/utils/ai_text_summarizer.dart`, since it's now used in three places: Crowdsource Hub's "Something else", onboarding's "write your own" passerby message, and My Settings' passerby-message editor.
- [x] **Light/Dark decoupled from Low Vision** (explicit user correction — these were wrongly conjoined): previously picking Low Vision skipped the theme question entirely and forced one fixed black/yellow palette regardless of preference. Now Low Vision is an independent accessibility axis — every user picks Light or Dark (Low Vision users too, right after Visual Calibration), and get a matching **high-contrast variant** of whichever they picked: `AppTheme.highContrastLight` (pure white/black) or `AppTheme.highContrastDark` (pure black/white, the old fixed look) — see `theme_resolver.dart`. Removed the stale "hide theme row for Low Vision" guards from the Lock-In summary and My Settings.
- [x] **Snapshot consent setting** — new `SnapshotConsentPreference` enum (`always` / `askEachTime` [default] / `never`) + a new onboarding screen (`SnapshotConsentScreen`, after Passerby Messages) asking whether the paired Caretaker can trigger a Snapshot Request without live per-request consent. Wired into `CommunicationHubPanel`: the Snapshot Request button is disabled with an explanatory tooltip when set to `never`. (`askEachTime` vs `always` don't yet produce different *behavior* — the actual consent-prompt UI is Module 6/8's job once real snapshot capture exists; this just establishes the data contract and the one behavior that's actionable today.)
- [x] **Real Voice Memos for the Caretaker** (not a stub) — `record` + `audioplayers` packages. Records mono PCM16 at 8kHz via `AudioRecorder.startStream` (works identically on web and native — no real filesystem path needed, unlike file-based encoders), hard-capped at 20 seconds so the WAV-wrapped, base64-encoded clip stays well under Firestore's 1MiB document limit — deliberately avoiding a Cloud Storage dependency for this small feature. New `core/utils/wav_encoder.dart` stitches a standard 44-byte WAV header onto the raw PCM stream so any player can decode it. `CommunicationType.voiceMemo` added alongside `memo`/`snapshotRequest`; playback via `audioplayers`' `BytesSource`. New `VoiceMemoRecorderDialog` (record/stop/send, live elapsed-time announcement for screen readers).
- [x] `flutter analyze` clean, all 4 tests pass (added a widget test asserting the Bangla path specifically — tapping "বাংলা" renders role selection with the correct Bangla strings — since this exercises real Dart rendering logic without needing CanvasKit/a browser).
- [x] **Live browser verification completed** (retried in a fresh tab after the earlier block — see below for root cause). Full Bangla walkthrough, live against the real Firebase project: language selection → role selection → pairing skip → vision (Low Vision) → visual calibration → **theme preference (now reached even for Low Vision)** → mobility → cognitive/anxiety → deaf/hearing → verbosity/voice → Magic Button contact → passerby messages (vision-specific suggestions correctly shown) → **Snapshot Consent (new screen)** → safe havens → Lock-In summary (correctly showing Theme: গাঢ় and Snapshot permission: কখনো অনুমতি দেবেন না even for Low Vision) → dashboard. Confirmed the dashboard renders in the **high-contrast-dark** palette (pure black/white, visibly distinct from the softer Standard Dark), real Google Maps tiles alongside it, and My Settings' new Language and Snapshot-permission sections both correctly reflect what was set during onboarding.
  - **Root cause of the earlier "hang," for the record**: not the app, not actually a network outage from the page's own perspective (a `fetch()` from inside the page succeeded in 137ms while the tool's clicks were timing out) — the original browser tab's session got wedged at the tab/CDP level. Proved this with a JS `setInterval` probe that kept firing every ~200ms with zero gaps across the full 30s+ "hang," meaning the page's own JS thread was never blocked. A fresh tab resolved it immediately. Worth remembering next time a click mysteriously hangs: check whether the *page* is actually stuck before assuming an app bug.
- **Known limitation carried over**: Guardian Hub / Remote Management still don't get a Language selector on their own screens (only the Disabled User's My Settings does) — a caretaker who picked Bangla during pairing currently can't change it again post-onboarding without going through My Settings on the paired device. Worth adding alongside the "translate the rest of the dashboard" follow-up.

## Round 6 — full dashboard translated, vocabulary simplified, mic button + map width fixed
- [x] **Split-Mode Dashboard fully bilingual now**, closing the gap flagged at the end of Round 5: chat stream (welcome message, stub replies, typing indicator, bubble semantics), suggested chips, map (placeholder + directional-arrow label), Passerby Helper overlay/picker, and the Crowdsource Reporting Hub (categories, all sub-options, description form) all read `Dashboard.of(profile.language)` now, threaded down from `SplitModeDashboardScreen` through every child widget that needed it.
- [x] **Data-model fix found while wiring the Crowdsource Hub**: `HazardReport.subCategory` used to store the *displayed label* directly ("Mugging", "Something else…") — meaning two reports of the same thing would store different strings depending on the reporter's language, breaking any future subcategory-based aggregation (Module 5). Refactored to stable English keys (`'mugging'`, etc.) via `Dashboard.hazardSubCategoryKeys()`/`hazardSubCategoryLabel()`, with the *label* resolved for display only. `HazardCategory.label` and the old `kHazardSubCategories`/`kHazardOtherSubCategory` constants removed in favor of this.
- [x] **`ChatController` made language-aware without becoming a `.family` provider** — state is language-agnostic; each public method takes a `Dashboard` instance instead, so switching language mid-session in Settings doesn't reset the conversation. `SuggestedChip` similarly dropped its baked-in English `label` field for a `labelFor(Dashboard)` method.
- [x] **Vocabulary simplification pass across every Bangla string written so far** (onboarding + dashboard + settings — ~150 strings, all getter names/signatures kept identical so no calling code needed to change): plain everyday spoken Bangla and accepted English loanwords over formal/Sanskrit-derived equivalents — `দেখাশোনাকারী` over `পরিচর্যাকারী` (caretaker), `সুবিধা` over `বৈশিষ্ট্য` (feature), `আরামদায়ক`/`ঠিক করা` over `স্বাচ্ছন্দ্যদায়ক`/`সামঞ্জস্য করা` (comfortable/adjust), `রং` over `থিম` (theme — literally "color", which is what the light/dark choice actually changes), concrete descriptions over technical accessibility terms (e.g. "no curb cut" → "হুইলচেয়ারের জন্য ঢালু পথ নেই", *no sloped path for wheelchairs*, rather than a transliterated technical term). Rule of thumb used throughout: prefer the word a market vendor or rickshaw driver would use over the word a government form would use — documented directly in both string classes' doc comments so future additions stay consistent.
- [x] **Two live UI bugs reported during verification, both fixed**:
  - Mic button was a small icon squeezed between the text field and send button — undersold that voice is the *primary* interaction method for much of this app's audience. Moved to its own large (76px), centered, elevated button above the input row; removed the now-redundant small mic icon from the text row.
  - Map was rendering in a narrow strip instead of the full panel width — a known `google_maps_flutter_web` platform-view sizing quirk where the map bakes in a stale size if it only ever sees "fill your parent" (`Positioned.fill`) rather than explicit pixel dimensions. Fixed with `LayoutBuilder` + explicit `SizedBox(width/height: constraints.max...)`. Confirmed live: full-width map with real, detailed Dhaka road data (DOHS Bypass, Banani Overpass, named lanes).
- [x] `flutter analyze` clean, all 4 tests pass (one test's expected string updated to match the simplified vocabulary — `আমি একজন পরিচর্যাকারী` → `আমি একজন দেখাশোনাকারী`). Full live re-verification in Chromium: entire onboarding flow re-walked in Bangla confirming every simplified string renders correctly, dashboard confirmed fully bilingual (chat/chips/map all in Bangla), both UI fixes confirmed visually.

---

# Module 3 — The Bangla Conversational AI

## Environment / architecture decisions made before coding
Two of the module plan's named cloud services aren't reachable from this project as it stands: the `onUserRoleWritten` note from Module 1 already established Firebase is on the **Spark (no-billing) plan**, so there's no way to stand up a Cloud Functions proxy in front of Gemini/Cloud STT/TTS the way a production build should; and **no Picovoice account** exists for Porcupine wake-word. Rather than build against services that can't run, the module was re-scoped the same way `MapsConfig` already handles its own real-world key constraint:
- **LLM**: real Gemini, called directly from the client via `google_generative_ai` + a Google AI Studio key (no billing account required for that API specifically, unlike Cloud STT/TTS). Gated behind `GeminiConfig.isConfigured` (a `--dart-define`, not hardcoded like the Maps key — this one's a personal billable credential).
- **Voice input**: on-device `speech_to_text` (free, no backend) instead of Cloud STT streaming, and **push-to-talk instead of "Hey ANT" wake-word** instead of Porcupine. Confirmed with the user before building (see chat transcript) — recommended and accepted.
- **Voice output**: kept `flutter_tts` (already built in Module 1/2) rather than adding Cloud TTS — same reasoning, and it already handles both locales.
- **Offline fallback**: the module plan's "bundle a Vosk model + pre-recorded audio" is a real binary-asset undertaking on its own; substituted a lightweight bilingual keyword matcher (`OfflineIntentMatcher`) over whatever `speech_to_text` already transcribed on-device, paired with canned safety replies spoken through the always-available `TtsService`. Functionally equivalent for the stated goal (basic safety commands still work with no signal) without the asset-pipeline scope.

## Step 1: The Audio Input Pipeline
- [x] `SttService` (`core/services/stt_service.dart`) wraps `speech_to_text`: `ensureAvailable()` caches a device capability/permission check (never throws — callers get `false` and show the same "voice unavailable" messaging that existed pre-Module-3), `listenOnce()` runs a single push-to-talk session with live partial-result callbacks, auto-stopping after a pause. Locale resolution is defensive: platform locale-id formatting (`bn_BD` vs `bn-BD`) isn't consistent across OS versions, so it scans `speech.locales()` for a `bn`/`en` prefix match instead of hardcoding a format, falling back to the device default.
- [x] Wired into **all four** places the app already promised voice input for ("arrives with the AI Assistant module" in the Module 2 code comments): the main chat panel's big mic button, the Passerby Message Picker's compose field, the Crowdsource Hub's "Something else" description field, and My Settings' passerby-message field. Each shows a listening state (icon/color swap + `liveRegion` Semantics announcement) and falls back to the pre-existing "voice unavailable" snackbar on a device with no recognizer or a denied permission.
- [x] Android `RECORD_AUDIO` permission added (was actually already needed by the Guardian Hub's `record`-based voice memos from Module 2 and missing — a latent gap this module happened to fix). iOS `NSMicrophoneUsageDescription` + `NSSpeechRecognitionUsageDescription` added.

## Step 2: The LLM Decision Engine
- [x] `GeminiAssistantService` (`core/services/gemini_assistant_service.dart`) builds a per-turn contextual prompt (disability profile, verbosity preference, last-known GPS via `Geolocator.getLastKnownPosition()` — deliberately not a fresh `getCurrentPosition()` fix, not worth the battery/latency cost for a chat reply — and which modules aren't deployed yet so the model doesn't pretend to route/scan/dispatch) and sends it with **real Gemini function-calling tools**, not a hand-rolled JSON schema:
  - `update_setting(setting, value)` — one generic tool covering every field `MySettingsScreen` can edit (text size, theme, language, verbosity, voice, vision level, mobility aid, deaf/hearing mode, snapshot consent, crowded/complex sensitivity, home/safe-place address), instead of ~13 near-identical single-field tools.
  - `add_emergency_contact` / `remove_emergency_contact`, `add_passerby_message` / `remove_passerby_message`.
  - `open_passerby_helper` / `open_hazard_report` — surfaces as `ChatState.pendingOverlayAction`, which `ChatStreamPanel` watches and opens through the exact same path a suggested-chip tap already used, so there's one overlay-opening code path, not two.
  - Two-call pattern per turn when a function is invoked: execute the call(s) locally, feed the results back to the model as `FunctionResponse`s, and use *that* reply as `response_text` — so confirmations are phrased naturally in the user's language instead of the app templating its own "Done." for every possible tool.
- [x] `ChatController.sendFreeText` rewired to call this, applying any `updatedProfile` via `ProfileService.saveProfile` (same Firestore doc `MySettingsScreen` already writes to, so the two stay in sync automatically via the existing `profileStreamProvider` stream) and setting `pendingOverlayAction` when relevant.
- [x] Deliberately **stateless at the network layer across turns** — each call rebuilds context from the *current* profile rather than a long-lived server session, with only the last 8 messages riding along for short-term coherence (keeps prompts small per the master plan's cost-mitigation strategy, and means a change from the Caretaker's Remote Management screen is picked up on the very next turn for free).
- [x] `routeToWork`/`scanBusSign` suggested chips intentionally left as Module 2's canned stub replies (`chatStubRoute`/`chatStubBusScan`) rather than routed through Gemini — those modules (4/5/6) genuinely don't exist yet, so there's nothing for the model to correctly report beyond what the canned string already says.

## Step 3: The Output Pipeline
- [x] Every assistant reply (Gemini-generated, chip-stub, or offline-fallback alike) is spoken through the existing `TtsService` unless `profile.isDeafOrHardOfHearing` — reusing the exact rule `OnboardingController.setDeafHearing` already established for spoken guidance ("show text and visuals instead of relying on audio"), rather than inventing a second toggle.

## Step 4: Graceful Offline Degradation
- [x] `OfflineIntentMatcher` — bilingual (English/Bangla) keyword matcher for `help`/`stop`/`where am i`/`emergency`, returning a canned safety reply. `ChatController.sendFreeText` falls back to this (then to Module 2's original stub reply if nothing matches) on *any* exception from the Gemini call — no configured key, no signal, quota exceeded, malformed response, all collapse to the same safe path. The chat, chips, and overlay triggers all keep working exactly as they did at the end of Module 2 when Gemini is unreachable.

## Backend / Firestore
- No schema changes — `update_setting` and friends write through the same `UserProfile.copyWith()` → `ProfileService.saveProfile()` path every onboarding screen and My Settings already use. No new Cloud Functions (couldn't deploy any on Spark anyway).

## Verification
- [x] `flutter analyze` — no issues, after inspecting the actual installed `google_generative_ai` 0.4.7 and `speech_to_text` 7.4.0 package source in `~/.pub-cache` for exact API signatures rather than guessing (`Schema`/`FunctionDeclaration`/`ChatSession` shapes, `SpeechListenOptions` fields) — paid off, zero signature-mismatch errors on the first analyze.
- [x] `flutter test` — all existing tests still pass unmodified.
- [x] `flutter build web` succeeds; live-verified in Chromium against the real Firebase project (no Gemini key configured, i.e. the fallback path):
  - Full onboarding walkthrough (English) end-to-end, including the new Magic Button contact / safe haven / lock-in screens, landing on the Split-Mode Dashboard via `AppRoot`'s existing routing.
  - Chat: typed "Make my text bigger please" → correctly fell back to Module 2's stub reply (proves the new `sendFreeText(text, profile)` signature and the not-configured branch both work end-to-end through the rewired `ChatStreamPanel`).
  - Hazard Report overlay → Road Hazard → "Something else" → description field: typed text, live AI-summary preview updated correctly, mic button renders in its new state-aware form next to it.
  - No console errors at any point attributable to Module 3 code (some pre-existing `flutter_tts` `SpeechSynthesisErrorEvent` console noise in headless Chromium — present before this module, unrelated: no browser TTS voices/user-gesture in a headless tab).
- **Not live-verified**: actually granting microphone permission and completing a real dictation — this sandbox's automated browser has no way to click "Allow" on the OS-level `getUserMedia` permission prompt Chromium raises, so the recognizer itself (vs. the button wiring around it) couldn't be exercised end-to-end here. Also not verified: a real Gemini key's actual function-calling output, since none is configured yet (see Current State). Worth a manual pass on a real device/browser with a key once available.

## Known issues found & fixed during verification
- The chat/passerby/crowdsource/settings mic buttons all previously showed an unconditional "voice input connects in the AI Assistant module" snackbar (Module 2 stub). Repurposed that same string (`chatVoiceUnavailable`) to fire only when `SttService.ensureAvailable()` genuinely returns false, and added a distinct "Tap, then speak" hint (`chatSpeakHint`) for the now-real affordance.
- Hit the same tab/CDP-level "hang" Module 2's Round 5 notes already diagnosed (browser pane goes unresponsive to clicks, screenshots time out) after the mic button triggered a real `getUserMedia` permission prompt with no way to dismiss it. Confirmed it was the tab, not the app (`get_page_text`/console still responded); a fresh tab resolved it immediately, consistent with the prior root-cause finding.
- `.claude/launch.json`'s `ant_app-web` config had a hardcoded port (`5057`) that collided with another concurrent session; switched to `"autoPort": true` with the start command reading `$PORT`, so it no longer needs a free port to already be known in advance.

## Round 2 — real Gemini key wired in, live debugging (session paused mid-verification, laptop shutting down)
User supplied a real Gemini API key. Stored locally (never committed) at `ant_app/dart_defines.local.json` (gitignored), used via `--dart-define-from-file`. Three real, confirmed bugs found and fixed while getting it working live:
- [x] **`Geolocator.getLastKnownPosition()` throws outright on web** (`geolocator_web` has no implementation — confirmed in its source) — it shared a try/catch with the Gemini call, so every web chat message was silently falling back before ever reaching Gemini. Fixed: isolated into its own try/catch in `chat_providers.dart`.
- [x] **`gemini-flash-latest` alias was returning persistent 503 "high demand"** — confirmed via direct `curl` against the API (not an app bug). Also learned mid-session that `gemini-2.5-flash` is now retired for new users. Pinned `GeminiConfig.modelName` to `gemini-3.6-flash`, live-verified working (including function calling) via direct API calls.
- [x] **The two-call function-calling round trip is fundamentally incompatible with Gemini's newer "thinking" models and this SDK version** (`google_generative_ai` 0.4.7, predates them): (a) the classic `role: "function"` this SDK sends for the function-response turn is now rejected server-side ("Role 'function' is not supported"), and (b) replaying a function-call turn requires echoing a `thoughtSignature` the model attaches, which this SDK's `FunctionCall` class doesn't capture at all — confirmed both independently via direct `curl` tests before touching app code. Redesigned `GeminiAssistantService.converse` to not need the round trip: confirmations are now generated client-side (`_confirmationFor`, bilingual templates) immediately after executing the function call(s), instead of asking Gemini to phrase them in a second call. Also halves per-turn latency.

Session paused here (laptop about to lose power) mid-crash-diagnosis, resumed in Round 3 below.

## Round 3 — Blaze billing enabled, guardrails deployed, crash root-caused and fixed, Module 3 now fully verified live
User enabled Blaze billing and set a $2 budget alert. Resumed the paused crash investigation first (as instructed), then handled the guardrails.

**Crash resolved — two distinct real bugs, not one:**
- [x] Switched to `flutter run -d web-server` (not `flutter build`, which doesn't honor `--track-widget-creation`) specifically to get unminified stack traces. First reproduction actually surfaced a transient Gemini 503 (genuine API overload, correctly handled by the existing fallback — not a bug). Second reproduction hit the real crash: `Assertion failed: fontSize != null || (fontSizeFactor == 1.0 && fontSizeDelta == 0.0)` at `flutter/lib/src/painting/text_style.dart:996`.
- [x] **Root cause**: `AppTheme._build()` called `textTheme.apply(fontSizeFactor: fontScale)`, which throws the instant `fontScale != 1.0` if *any* of the theme's 15 text styles has a null `fontSize`. A dormant bug since Module 1/2 — nothing had exercised a real runtime `fontScale` change before (onboarding's calibration slider evidently never happened to trigger it). Gemini's `update_setting` call for text size was the first code path to actually hit it. Fixed in `app_theme.dart`: replaced the blind `.apply()` with a null-safe per-style scale that skips (rather than crashes on) any null-`fontSize` entry.
- [x] **Second bug, found while re-verifying**: navigating to My Settings and back threw `Bad state: Using "ref" when a widget is about to or has been unmounted is unsafe`, pointing straight at `my_settings_screen.dart:82` — `dispose()` was calling `ref.read(sttServiceProvider).stop()`, which is unsafe once a widget starts unmounting. This exact pattern (`ref.read` inside `dispose()`) was in **four** places from this module's own STT wiring — `MySettingsScreen`, `CrowdsourceReportingHub`, `ChatStreamPanel`, and `PasserbyMessagePicker`'s `_PickerSheet` (the last one didn't even have a `dispose()` override yet, so it was leaking an in-progress listening session on dismiss, a real if minor bug of its own). Fixed all four the same way: capture `late final SttService _stt = ref.read(sttServiceProvider);` once (safe — happens no later than `initState`), use `_stt` everywhere including `dispose()`, never call `ref.read` again after that.
- [x] `flutter analyze` clean, all 4 tests pass, full live re-verification against `gemini-3.6-flash` with the real key: "Make my text bigger please" → real function call → Firestore write → My Settings' text-size slider visibly moved off default, confirming the end-to-end round trip; "I need to show my screen to a passerby" → `open_passerby_helper` → the Passerby Message Picker opened automatically via `ChatState.pendingOverlayAction`, same path a suggested-chip tap uses; navigated to My Settings and back afterward with no crash and no console errors, confirming the dispose fix.
- [x] Final production `flutter build web --dart-define-from-file=dart_defines.local.json` run to produce the actual deployed artifact with all fixes included.

**Guardrails — deployed:**
- [x] `firebase.json` was missing a `functions` block entirely (only had `firestore`) — added `{"source": "functions"}`, otherwise `deploy --only functions` has no target.
- [x] Both Cloud Functions deployed via `npx firebase-tools deploy --only functions` (no `gcloud` CLI available in this sandbox, only `firebase-tools`, which was already logged in as the user). `onUserRoleWritten` needed one retry after a first-time-2nd-gen-functions Eventarc permission-propagation delay (expected, not a bug). `disableBillingOnBudgetExceeded`'s deploy auto-created the `budget-alerts` Pub/Sub topic it's wired to (2nd-gen Pub/Sub triggers provision their topic if missing).
- [x] Set an Artifact Registry cleanup policy (`firebase functions:artifacts:setpolicy --force`, once per region — the command's own region auto-detection defaults to `us-central1` regardless of where functions actually deployed, needed `--location asia-south1`/`--location us-east1` explicitly) so old container images from each deploy don't quietly accrue storage cost.
- [x] Confirmed via `firebase functions:list --json` the exact runtime service account (`514133180208-compute@developer.gserviceaccount.com`) and topic (`projects/ant-assistive-nav/topics/budget-alerts`) — written into `disableBillingOnBudgetExceeded`'s doc comment.
- **Two steps remain, deliberately left to the user** — both are billing/IAM changes on the account itself, not something to automate without them present: (1) connect the existing $2 budget's Pub/Sub notification to the `budget-alerts` topic (Cloud Console → Billing → Budgets & alerts — Firebase Console's simplified budget UI is email-only and can't do this), and (2) grant that service account the "Billing Account Costs Manager" role on the Billing Account (Console → Billing → Account Management → Permissions). Full detail in `functions/index.js`'s doc comment.

**Known gap this round exposed:** `functions/index.js` still uses Node.js 20, which Firebase's deploy output flagged as deprecated 2026-04-30 and decommissioned 2026-10-30 — worth bumping the runtime before then. Not done this round (out of scope for the guardrails task).

## Round 4 — openWakeWord built (English placeholder phrase), not yet device-tested
User greenlit wake-word detection, chose "English 'Hey ANT' first, research Bangla in parallel" when asked to scope it. Two real constraints surfaced during research, both resolved:
- **No dedicated Flutter package exists.** `flutter_wake_word` (pub.dev) looked like one but isn't actually openWakeWord — it requires an external commercial model-generation service ("DaVoice"), reintroducing exactly the account-dependency problem Porcupine was rejected for. Went with `tflite_flutter` (FFI-based TFLite bindings) instead, running openWakeWord's own exported models directly.
- **Training a real "Hey ANT" model isn't feasible in this sandbox** — openWakeWord's own docs point to a Colab notebook with a free GPU tier; thousands of synthetic Piper-TTS clips + PyTorch + realistically a GPU aren't available here. Used one of openWakeWord's *pretrained* models (`hey_jarvis_v0.1.tflite`, downloaded from the project's GitHub release `v0.5.1`, confirmed reachable) as an explicit placeholder — swapping it for a real "Hey ANT" model later is a one-file change. **Its weights are CC-BY-NC-SA (non-commercial)** — fine for now, flagged clearly in `assets/wakeword/README.md`, must be replaced with a self-trained model (which wouldn't carry that restriction) before any commercial release.

**Built:**
- [x] `WakeWordService` (`core/services/wake_word_service_native.dart`) — the real 3-stage TFLite pipeline (mel-spectrogram -> embedding -> classifier), continuous 16kHz mono audio via the `record` package (already a dependency, used for Guardian voice memos). Exact tensor shapes and the `int16 -> float32` unnormalized / `melOutput / 10 + 2` conventions came directly from reading openWakeWord's own `openwakeword/utils.py` (`AudioFeatures` class) — not guessed. Reads model output via raw tensor bytes reinterpreted as `Float32List` rather than pre-constructing shaped Dart output containers, sidestepping rank ambiguity in the docs.
- [x] **Web build broke, then got fixed properly**: `tflite_flutter` is an FFI plugin (`dart:ffi` isn't available on the web target at all — not declared as a supported platform in its own `pubspec.yaml`), so importing it unconditionally would've broken every `flutter build web` verification this project's testing has relied on all along. Fixed with a standard Dart conditional export — `wake_word_service.dart` exports `wake_word_service_native.dart` (`dart.library.io`, i.e. Android/iOS/desktop) or `wake_word_service_stub.dart` (web — always reports unavailable, same graceful-degradation pattern as `SttService`) — neither callers nor the public API need to know which one they got. Confirmed web build succeeds again after the split.
- [x] `UserProfile.wakeWordEnabled` (bool, default **false** — always-on mic capture is a real battery/privacy tradeoff this app shouldn't force on anyone) added end-to-end: Firestore persistence, `update_setting`'s `wake_word_enabled` key (chat-drivable, per this app's "no settings menus" philosophy), a toggle in My Settings, bilingual strings.
- [x] `ChatStreamPanel` lifecycle wiring: starts/stops with the toggle, detection triggers a haptic buzz (`HapticFeedback.mediumImpact()` — Module 7's real haptics vocabulary doesn't exist yet, this is a placeholder) then the same push-to-talk STT flow the mic button uses, stops wake-word listening while a command is actively being captured (the two would otherwise fight over the mic) and restarts it after — continuous in effect while the toggle is on. Scoped to foreground-only (the dashboard screen open, app active); background/lock-screen listening would need native foreground-service/background-audio-session work, out of scope for this round.
- [x] `flutter analyze` clean, all 4 tests pass, `flutter build web` confirmed still working (the conditional-export fix, live-verified: app loads with no console errors, wake-word code path is dormant by default so this doesn't touch the already-verified Gemini/STT flows).

**Not verified — cannot be, in this sandbox:** whether the pipeline actually detects "Hey Jarvis" when spoken. No real microphone exists in this environment (confirmed earlier this session when even the STT permission prompt hung the browser), so only compilation could be checked here. **Needs testing on a real Android/iOS device before relying on it** — if it doesn't fire, the most likely culprits are the exact windowing/stride details in `WakeWordService._processChunk` (simplified from openWakeWord's Python reference to compute one embedding per audio chunk rather than one per possible frame position — functionally reasonable but not bit-identical) or a subtlety in how `tflite_flutter`'s automatic input-shape resizing interacts with the raw-byte output reading approach used here.

**Bangla wake-word research:** not done yet — still an open follow-up (Piper TTS Bangla voice quality/availability needs checking before a custom Bangla phrase is worth attempting via openWakeWord's synthetic-training pipeline).

## Round 5 — real Android device testing (first time), extensive live bug-fixing, Cloud STT streaming built
User connected a real Redmi 10C (MIUI) via USB and testing moved from this sandbox (no mic, no real device) to the actual phone for the first time.

**Android build itself needed 9 escalating fixes before it would even install** (Gradle/AGP 9.1.0/Kotlin JVM-target mismatches across third-party plugins with genuinely different Java targets, a race in a `gradle.projectsEvaluated` block that hung indefinitely, a CMake download race for the `jni`/`tflite_flutter` native module, and three separate rounds of MIUI blocking ADB installs — `INSTALL_FAILED_USER_RESTRICTED` needed "Install via USB", "USB debugging (Security settings)" *and* explicitly re-granting Package Installer permission under Settings → Privacy → Special permissions before installs stopped being silently blocked). Final working fix in `android/build.gradle.kts`: read each subproject's own already-set Java target and match Kotlin's `jvmTarget` to it per-subproject, rather than forcing one value on everything (which broke `geolocator_android` and `audioplayers_android` in earlier attempts — they disagree on their own Java targets, and blanket-touching every subproject's `JavaCompile` corrupted AGP's classpath injection for a module that never had the mismatch to begin with).

**Wake-word confirmed working live** once the build succeeded — real "Hey Jarvis" detections at score 0.6-0.97, well over the 0.5 threshold. Root cause of it not even starting at first: `melspectrogram.tflite` was exported with a dynamic input shape (`shape=[1,1]`, `shape_signature=[-1,-1]`), and `tflite_flutter`'s `Interpreter` constructor allocates tensors eagerly with no chance to resize first — fixed by patching the model file directly (verified in-place flatbuffer edit, original backed up alongside it) to declare a fixed `[1,1280]` shape matching what the code always actually feeds it.

**Extensive live bugs found and fixed during real-device voice testing** (grouped by root cause, since several symptoms shared one cause):
- **Mic-contention race** (two audio sessions fighting over the microphone): wake-word restarting its own `AudioRecorder` stream before a just-finished STT session had actually released the mic, *and* the reverse — a manual mic-button press not stopping wake-word first. Centralized the fix inside `SttService`/`WakeWordService` (`WakeWordService.pauseAround`) so every caller gets it automatically instead of each needing its own copy — this exact bug had already recurred once because a copy was forgotten.
- **`SttService.listenOnce` returned before the session actually finished** — `SpeechToText.listen()`'s own future resolves the instant the recognizer *starts*, not when it's done; fixed by awaiting the platform's `done` status via a completer instead.
- **`cancelOnError: true` killed whole sessions on merely transient hiccups** (`error_no_match` — "didn't quite catch that," not a real failure) — this was the actual cause of what looked like a duration limit on longer recordings, not `pauseFor`/`listenFor` at all. Changed to `false`.
- **`flutter_tts`'s `speak()` doesn't wait for audio to finish playing by default** — a real bug once code started chaining "announce, then listen" (the Passerby overlay): the mic started listening while the announcement was still audibly playing. Fixed with `awaitSpeakCompletion(true)`.
- **`app_theme.dart`'s font-scale was a silent no-op app-wide**, not just in one screen — this Flutter SDK returns `fontSize: null` for every default Material 3 text style (confirmed directly, even on vanilla `ThemeData.light().textTheme`), and the existing scaling code was written to skip (not crash on) a null `fontSize` — which turned out to be the *normal* case, not a rare edge case. Fixed by always assigning an explicit size (Material 3's documented defaults × the scale factor) instead of skipping.
- **The on-device Bangla speech recognizer has no offline Bangla language pack at all** on the test device (confirmed via a locale dump: English/Hindi/a dozen others, no `bn_*`) — Bangla speech was silently being transcribed as English/Hindi gibberish. Mitigated by explicitly requesting `bn-BD` (falls through to online recognition) rather than giving up to the wrong system default — but see Round 5's Cloud STT work below for the real fix.
- **Four separate `TextEditingController`-after-disposed crashes**, all the same root cause as the dispose-safety fix from Round 3 recurring in scenarios nobody had exercised yet (a voice session's `onResult` callback firing after the widget was gone) — fixed uniformly across `chat_stream_panel.dart`, `crowdsource_reporting_hub.dart`, `my_settings_screen.dart`, `passerby_message_picker.dart` by gating the *whole* callback on `mounted`, not just the final `setState`. The passerby picker had a second, subtler version of the same bug: its `TextEditingController` was owned by the *parent* (`PasserbyMessagePicker.show()`), which disposed it as soon as the sheet's pop was *initiated* — not once the sheet's own closing animation (and this State's actual unmount) finished — so `mounted` could still read `true` while the controller was already gone. Fixed by moving the controller's ownership fully inside the sheet's own State.
- **Missing back navigation, audited and fixed in two real places**: `UserPairingScreen` never wired `onBack` (every other onboarding screen does) — a genuine dead end, since onboarding is a manual state-switch, not a `Navigator` stack with a system-back fallback. `PasserbyMessagePicker`'s bottom sheet had no visible close button at all, only scrim-tap. `PasserbyHelperOverlay` also gained a visible back arrow (previously tap-anywhere/voice-only).
- **Gemini replies were getting cut off** — `maxOutputTokens: 400` was too tight for `gemini-3.6-flash` (a "thinking" model that spends part of its budget on internal reasoning before the visible reply); raised to 1024.

**New this round: `CloudSttService`** (`core/services/cloud_stt_service_native.dart` + `_stub.dart` + conditional export, same pattern as `WakeWordService`) — genuinely continuous speech recognition via Google Cloud Speech-to-Text's streaming API (`google_speech` package, `EndlessStreamingService.viaApiKey`), built after the user asked directly whether continuous listening was possible at all. The on-device recognizer is fundamentally session-based (Android's `SpeechRecognizer` restarts on silence by design — that's what caused the mic-indicator flicker on the Passerby overlay's dismiss-listener, not a bug in this app's code), so true continuous listening needed a different backend, not a different configuration.
- Gated behind `CloudSttConfig.isConfigured` (`CloudSttConfig`'s doc comment has the exact GCP Console setup steps — enable the Speech-to-Text API, create a restricted API key, add `CLOUD_STT_API_KEY` to `dart_defines.local.json`) — **not yet configured**, so this is currently dormant and every existing voice flow keeps working exactly as before, unaffected.
- Wired into `PasserbyHelperOverlay` specifically (`_startListeningForDismiss`): tries Cloud STT first, falls back to the existing on-device restart-loop automatically if it's not configured or fails to start. Deliberately *not* wired into the other voice entry points (chat mic, hazard report, My Settings, passerby composer) this round — those already went through extensive live-debugging to reach a proven-working state, and swapping their foundation while unable to test on a real device (see below) was judged too risky to do blind.
- `flutter analyze` clean, all 4 tests pass, `flutter build web` confirmed still succeeding (the conditional export correctly keeps `grpc`/`dart:io` out of the web bundle, same verification already done for `tflite_flutter`/wake-word in Round 4).
- **Not device-tested at all** — the phone disconnected for a few hours right as this was built (user stepped out), and no `CLOUD_STT_API_KEY` is configured yet either way. Needs, in order once the user is back and has done the GCP Console setup: (1) add the key, (2) rebuild and confirm the Passerby overlay's dismiss-listener actually engages Cloud STT (watch for `[CloudStt] continuous listening started` in logs, not `Cloud STT unavailable`), (3) confirm the mic indicator no longer flickers, (4) confirm "go back" now works reliably in both languages without the phonetic-transliteration workaround being needed, (5) if it all works, this becomes the template for widening Cloud STT to the other voice entry points as a deliberate follow-up, not swapped in blind.

---

# Module 4 — Contextual Safety & Crime Data

Source: `04_module_plan_crime.md`

## Scoping decisions made before coding

Same honesty pattern as Module 3's STT/wake-word rescoping: `dmp.gov.bd` (the official crime-report source) sits behind a bot-check wall this sandbox couldn't get past to confirm a stable, real PDF-listing URL or page structure against, and there's no Document AI processor provisioned in the `ant-assistive-nav` project. Rather than fabricate scraper selectors and crime numbers and present them as real:
- **Thana boundaries**: real, not guessed. Sourced live from [geoBoundaries' BGD ADM3 dataset](https://www.geoboundaries.org/api/current/gbOpen/BGD/ADM3/) (Bangladesh Bureau of Statistics via HDX, CC BY 3.0 IGO), filtered to Dhaka's bounding box and cross-checked by name against real DMP thana names — **41 real polygons**, not hand-drawn approximations.
- **Crime scores**: user was asked directly (2026-09-02) how to seed initial scores given the live scraper can't be verified here, and chose "best-effort estimate from public research" over a flat placeholder. Used Table 2 ("DCC – Thana wise Crime Database") from Urmee Chowdhury's 2011 AUST Journal paper — real DMP-sourced Jan-Mar 2009 data, found and read directly (not summarized secondhand) via the paper's PDF. 29 of 41 thanas have real data from that table (density-normalized to a 1-10 score); the other 12 are post-2009 thana splits not in the table, interpolated from their geographic/functional parent thana and tagged one honesty tier lower. Every `crimeZones` document carries a `dataSource` field (`estimated_2009_academic` / `estimated_neighbor_interpolation` / later `scraped_official`) so provenance is always inspectable — see `functions/data/dhaka_thana_crime_seed.js`'s doc comment for the full sourcing story.
- **Ingestion pipeline**: built for real (not stubbed) — `scrapeDmpCrimeReports` does real DMP-page fetch + Document AI OCR + Gemini structuring — but gated behind `DOCUMENT_AI_PROCESSOR_ID`/`GEMINI_API_KEY` env vars being configured (same pattern as `CloudSttConfig`), and its DMP-page selector is an unverified best guess. Currently a clean no-op every scheduled run.
- **Cloud Functions stayed Node.js** (matching the existing `functions/` codebase) rather than the module plan's suggested Python — consistency with what's already deployed, not a scope decision worth a separate ask.

## Step 1 & 2: Data Ingestion Pipeline + Geospatial Mapping
- [x] `functions/data/dhaka_thana_geometry.json` — 41 real thana polygons (geoBoundaries source, ~970 vertices total, ~42KB).
- [x] `functions/data/dhaka_thana_crime_seed.js` — per-thana `densityEstimate` (crimes/km²) + `categoryHint` + `dataSource`, plus `densityToScore()` (min-max normalize to 1-10, anchored on the real table's min/max: Demra 0.08 → Paltan 29.77).
- [x] `functions/lib/geo.js` — polyline decoder, ray-casting point-in-polygon, and `toFirestoreGeometry()`. **Real bug hit and fixed during first deploy**: Firestore rejects any array that directly contains another array ("contains an invalid nested entity") — raw GeoJSON coordinates (`ring -> point -> [lng, lat]`) are exactly that. Fixed by flattening every ring to an array of `{lat, lng}` *objects* instead (`{ polygons: [{ ring: [{lat,lng}, ...] }] }`), confirmed with a direct nested-array scan before redeploying.
- [x] `functions/lib/temporal_weighting.js` — the module plan's "Temporal Multiplier": commercial/transit zones ×1.6 at night (8PM-5AM Bangladesh Standard Time, computed as a fixed UTC+6 offset, not the function runtime's local TZ), institutional/industrial ×1.3, mixed ×1.25, residential ×1.1, all ×1.0 by day.
- [x] `exports.seedCrimeZones` (`functions/index.js`) — idempotent onCall upsert of all 41 thana documents into Firestore `crimeZones/{slug}`. Open to any signed-in user deliberately (only ever writes the same deterministic public dataset, never user data).

## Step 3: Backend Decision Engine
- [x] `exports.checkRouteSafety` (onCall) — decodes a route's encoded polyline, finds which cached `crimeZones` it passes through (module-scope 10-min cache, since Cloud Function instances are reused), applies the temporal multiplier per zone, returns `{safe, riskScore, threshold: 7, evaluatedZones, dangerousZones}`. `threshold: 7` matches the module plan's own ">7" dangerous-zone example.
- [x] `firestore.rules` — `crimeZones/{thanaId}`: any signed-in user can read, `allow write: if false` (writes only ever happen via the Admin SDK inside Cloud Functions, which bypass rules — the `false` just makes that explicit).

## Step 4: Frontend Routing Logic
- [x] `core/services/routing_service.dart` — Directions API (walking, `alternatives=true`) + Geocoding API, called directly client-side with `MapsConfig.apiKey` (same pattern as the existing Maps SDK key and the Gemini key — no proxy Cloud Function, since the key's already client-embedded and a proxy adds latency for no security benefit). Own polyline decoder (a direct Dart port of `geo.js`'s, verified against Google's own documented decode example) and a standard forward-azimuth bearing calculation for the giant arrow.
- [x] `core/services/route_safety_service.dart` — thin `cloud_functions` wrapper around the deployed `checkRouteSafety` callable.
- [x] `core/services/route_planning_service.dart` — orchestrates the module plan's Step 4 loop client-side (not server-side) so the chat transcript can show its work as it goes: geocode → get every walking alternative Google offers → safety-check each → take the first *safe* one, falling back to the lowest-risk alternative with a `stillUnsafe` flag if none are fully safe.
- [x] **`request_route` added as a real Gemini function-calling tool** (`GeminiAssistantService`) — the same natural-language-intent pattern every other Module 3 setting-change already uses. Handles four real failure modes gracefully (no GPS fix, destination not found, no walking route found, network/API error) plus the success path (rerouted-for-safety vs. direct vs. best-available-but-still-risky), each with its own bilingual confirmation string.
- [x] **"Route to Work" chip rewired**: there's no fixed "work" address in `UserProfile` (only Home/Safe Place), so rather than add a new onboarding field for one chip, it now asks "Where would you like to go?" — the reply (sitting in Gemini's recent-message context) is enough for `request_route` to pick up a bare place name on the very next turn. Live-verified this exact flow.
- [x] `features/dashboard/providers/chat_providers.dart` — `ChatState.pendingRoute` (persistent, unlike the one-shot `pendingOverlayAction`) carries the active `RouteChoice` to the map.
- [x] `features/dashboard/widgets/dashboard_map_panel.dart` — converted to `ConsumerStatefulWidget`; draws the active route as a `Polyline` (green `AppColors.success` if safe, amber `AppColors.caution` if not), fits the camera to the route bounds once, and rotates the previously-static giant arrow to the route's initial bearing (Module 2's own note: "Modules 4-5 will feed it real turn instructions" — this is the first of those). Semantics label now speaks real distance-remaining + safety status instead of the old fixed "continue forward".
- [x] `pubspec.yaml` — added `cloud_functions` and `http`.
- [x] `MapsConfig.apiKey` — the same key already embedded in the three native map-SDK integration points, now also exposed to Dart for these direct REST calls.

## Verification
- [x] **Backend live-verified end-to-end against the real deployed project** (`ant-assistive-nav`, `us-central1`): deployed `seedCrimeZones`/`checkRouteSafety`/`scrapeDmpCrimeReports`, invoked `seedCrimeZones` for real (`{"written":41}`), then called `checkRouteSafety` with a real encoded polyline through Motijheel→Paltan→Shahbagh three separate times: (1) daytime → correctly found all three zones, flagged only Paltan (score 10) as dangerous, multiplier 1.0 everywhere; (2) 11PM Dhaka time, same route → multiplier correctly jumped to 1.6 for the two commercial-core zones (Paltan effective score 10→16) and 1.3 for institutional Shahbagh; (3) a route through low-crime Demra → correctly returned `safe: true`, `riskScore: 1`. Point-in-polygon confirmed working against the *real* thana geometry, not a mock. Cleaned up the throwaway anonymous test Auth account used to get a bearer token for these calls afterward.
- [x] `flutter analyze` — clean (2 pre-existing unrelated lint infos only). `flutter test` — all 4 tests pass. `flutter build web --dart-define-from-file=dart_defines.local.json` — succeeds.
- [x] **Live-verified in Chromium against the real Firebase/Gemini project**: fresh onboarding walkthrough (English) → dashboard → "Route to Work" chip correctly asked "Where would you like to go?" instead of the old canned stub → typed "Gulshan 2, Dhaka" → **real Gemini call correctly invoked the new `request_route` function** (confirmed by the response text being the exact new no-location fallback string, not a coincidence) → correctly hit the graceful `no_location` path and told the user to check location access, rather than crashing or silently doing nothing. `GoogleMap` rendered correctly throughout with the new `polylines`/`onMapCreated` parameters wired in (no regression to the existing map rendering).
- [ ] **Not verified: the actual route-drawing success path** (polyline on the map, camera fit, arrow rotation, real safety-based rerouting). Root cause is a genuine, pre-existing platform limit, not a Module 4 bug: `chat_providers.dart` deliberately uses `Geolocator.getLastKnownPosition()` (not `getCurrentPosition()`, for battery/latency reasons — see Module 3 Round 2), and confirmed by reading the installed `geolocator_web` package source that this method **unconditionally throws `UnimplementedError` on web** regardless of permission — there is no way to test the GPS-available path in a browser at all, on any site. Needs a real Android device (same category as wake-word/Cloud STT's device-only verification).
- [ ] **Real, separate blocker found while trying to verify the above differently**: called the Geocoding and Directions REST APIs directly with `MapsConfig.apiKey` via `curl` to rule out a code bug. Both came back `REQUEST_DENIED` — Geocoding: "You must enable Billing on the Google Cloud Project"; Directions: "You're calling a legacy API, which is not enabled for your project." This is the personal/experimentation Maps key flagged as a known gap since Module 2 — it was only ever proven to work for the Maps JS/SDK surface, never for these REST APIs. **Not fixable from here** (needs GCP Console access to the key's own project, or a new key created on `ant-assistive-nav`, which already has Blaze billing). Until resolved, `request_route` will always hit its `network_error` fallback path in practice, even with a real GPS fix.

## Known issues / follow-ups
- The two verification gaps above (GPS-on-web, Maps REST API access) block each other from being tested independently — fixing the Maps key access is worth doing first since it's the cheaper, non-device-dependent fix, then the real route-drawing path can at least be exercised on desktop by temporarily wiring a hardcoded test origin, before finishing with a real Android-device pass alongside whatever Module 3 GPS/mic device-testing happens next.
- `_confirmationFor`'s `request_route` "stillUnsafe" branch (safest-available route still crosses a flagged zone) hasn't been exercised live yet either, for the same GPS-on-web reason — worth deliberately triggering once real routing works, by requesting a destination on the far side of a known high-score thana like Paltan.
- Recomputing per-Thana `baseCrimeScore` from real recurring reports is still unimplemented and, per Round 2's research below, likely can't be — the only routinely-published DMP data is citywide, not per-Thana. Round 2's `cityTrend` mechanism is the honest substitute (a citywide scaling factor, not a spatial refresh).

## Round 2 (2026-09-02/03) — real crime-data source found, redesigned around what Bangladesh Police actually publishes, city-trend multiplier live-verified

User pushed back on the Round 1 plan (rightly) — asked to actually reason about whether a free OSM routing swap was viable given who uses this app (concluded no: public OSM demo servers have no reliability guarantee, wrong trade for a safety app; self-hosting is the real free option but is its own infrastructure project, not a quick swap), then when asking about `scrapeDmpCrimeReports` specifically, shared a real screenshot of a DMP monthly crime-data page and two more sources (a Kaggle dataset, `police.gov.bd/en/january_2020`). That prompted real research that materially changed the design:

- **`dmp.gov.bd` confirmed a dead end** — even its newer `/crime-data/` and `/archived-crime-data/` pages (found this round) sit behind the same bot-check wall.
- **`police.gov.bd`'s "List of Crime Statistics" archive is real, public, and reachable** — verified by fetching it directly, extracting real PDF links (a clean, stable `storage/upload/announcement/{hash}.pdf` pattern), downloading the newest one, and cross-checking its numbers *exactly* against the user's screenshot (3/20/31/34/102/1434 — identical). This is the real, working scrape target, not a guess.
- **That PDF is a scanned image with no text layer** (confirmed with `pdftotext` — empty output), so real OCR is unavoidable — but since Gemini itself reads PDFs directly as multimodal input, the pipeline was redesigned to skip Document AI entirely (removed the `@google-cloud/documentai` dependency) and send the PDF straight to Gemini in one call. **Net effect: zero new GCP setup needed** — just the `GEMINI_API_KEY` already configured, now also given to the relevant Cloud Functions via Secret Manager (`firebase functions:secrets:set GEMINI_API_KEY`, bound via `secrets: [...]` on each function).
- **Real, load-bearing limitation confirmed from the primary source itself**: the report is citywide-only. Its "Names of Unit" column lists DMP as exactly one row (alongside CMP/KMP/other units and police Ranges) — no finer breakdown exists anywhere in it. So this pipeline can refresh *how much* crime is happening citywide, never *which neighborhood* is relatively riskier — that spatial pattern still only exists in the one-time 2009 academic dataset. Designed around honestly rather than glossed over:
  - New `cityTrend/{period}` collection (append-only, one real doc per month) holding the DMP row's pedestrian-relevant categories (Dacoity + Robbery + Burglary + Theft + Kidnapping — deliberately excluding narcotics/arms *recovery* cases, which dominate the report's raw totals but reflect police enforcement activity, not danger to pedestrians; this mirrors the module plan's own instruction to keep only "street-level crimes relevant to pedestrians").
  - New `meta/cityTrendMultiplier` doc — a single citywide scaling factor `checkRouteSafety` now applies on top of every Thana's static score, alongside the existing time-of-day multiplier. **Deliberately stays neutral (1.0x) until ≥3 months of real `cityTrend` history exist** — comparing today's report against the 2009 baseline directly was considered and rejected: different data-collection methodology, a 1-month sample vs. a 3-month one, and a narrower crime definition, meaning a bridged ratio across 17 years would look precise while being methodologically unsound. Once ≥3 months of this pipeline's *own* consistent data exist, the multiplier becomes `latest month ÷ rolling average of the prior months`, clamped to [0.7, 1.5] so one anomalous month can't wildly swing every route's safety score.
- **A second real infrastructure finding, discovered live**: once deployed, **Cloud Functions cannot reach `police.gov.bd` at all** — `ECONNREFUSED` at the TCP level, confirmed identically from both `us-central1` and `asia-south1` (tried redeploying the function to the latter specifically to rule out a region-specific block; same result). This is the site's own network-level access decision (almost certainly blocking cloud-provider/datacenter IP ranges generally, a common defensive measure), not a bug — and not something to route around via a proxy or different network, which would cross from "reading a public government report" into deliberately evading an access control. Resolved honestly instead: split the pipeline into `ingestCrimeReport` (fetch-from-network + extract + record — works if Cloud Functions' access to the site ever changes) and a new `recordCityTrendEntry`/`exports.recordCityCrimeMonth` (record-only, reliable from anywhere) — so whoever *can* reach the site (this session's own sandbox network reached it fine; a human in a browser would too) reads the numbers, and the recording + rolling-multiplier math still happens through a proper Cloud Function endpoint either way.
- [x] **Fully live-verified end-to-end against the real deployed project**: deployed `checkRouteSafety` (now reads both multipliers), `refreshCityCrimeTrend`, `recordCityCrimeMonth`, `scrapeDmpCrimeReports` (all confirmed loading/deploying clean). Called `recordCityCrimeMonth` for real with the actual July 2026 DMP figures already extracted this session (dacoity 3, robbery 20, burglary 34, theft 102, kidnapping 11 → 170 pedestrian-relevant incidents) — confirmed written (`{"period":"2026-07","pedestrianRelevantIncidents":170}`). Re-ran the exact same `checkRouteSafety` polyline test from Round 1 afterward — identical results, plus a new `cityTrendMultiplier: 1` on every zone, confirming the neutral-until-3-months logic is working correctly with only one real month on record. Cleaned up the throwaway anonymous test Auth account afterward, same as Round 1.
- `functions/package.json`: removed the now-unused `@google-cloud/documentai` dependency.
- `firestore.rules`: added `cityTrend/{period}` and `meta/{docId}` — same signed-in-read/function-writes-only pattern as `crimeZones`.
- **Next real step, whenever it's convenient**: manually check `police.gov.bd/en/january_2020` (or run `refreshCityCrimeTrend`/`ingestCrimeReport` from a network that isn't cloud-hosted) once a month for the next couple of months and call `recordCityCrimeMonth` with each — after 3 real months on record, the citywide multiplier starts actually moving off neutral, which would be worth a deliberate live check to see it in action (same way the temporal-hour multiplier was verified in Round 1).

## Round 3 (2026-09-03) — user pushback on staleness/Kaggle/automation, 65 real months backfilled, DMP thana-count gap found

User asked three fair questions after Round 2: is the 2009 per-Thana study too outdated to lean on, was the Kaggle dataset actually worth anything, and can the monthly check be fully automated rather than left to a human. All three got real investigation, not reassurance:

- [x] **Kaggle dataset: genuinely valuable, not a dead end** — the earlier "can't tell, WebFetch couldn't read it" answer was wrong; Kaggle's public API (`kaggle.com/api/v1/datasets/download/...`) needs no auth for public datasets and downloads directly. `faheemhere/crime-statistics-in-bangladesh-from-2020-2025` is a real, clean CSV — **65 consecutive DMP-only monthly rows, Jan 2020 through May 2025, no gaps or duplicates**, sourced from the same monthly PHQ reports this pipeline now scrapes, with exactly the columns (Dacoity/Robbery/Burglary/Theft/Kidnapping) `cityTrend` needs. Converted and recorded all 65 via `recordCityCrimeMonth` — **65/65 succeeded live** against the real deployed project. The rolling multiplier immediately moved off neutral as a result: re-ran the same `checkRouteSafety` polyline test from Round 1/2 and got `cityTrendMultiplier: 0.71` (clamped near its floor) instead of `1.0`, correctly reflecting that July 2026's 170 incidents sit well below the recent months now on record. **This is the single biggest freshness improvement of the module so far** — the citywide half of the crime model now runs on 5+ years of real reported data instead of one month.
  - Honest caveat: because May-2025 (Kaggle's last month) and July-2026 (the one real report ingested so far) leave a 14-month gap, the "prior 3 months" the multiplier compares against are Mar/Apr/May-2025, not truly-recent months — real data, correctly used, just not maximally recent. Closes automatically as more recent months get added (see below); also worth reconsidering `updateCityTrendMultiplier`'s window (currently latest + 3 prior by record-order) now that a real multi-year series exists — a longer or seasonal-aware window is a legitimate design upgrade, not attempted this round to avoid redesigning something just verified working.
- [x] **2009 per-Thana study: confirmed, again, still the only one that exists publicly** — renewed, deliberate search (BSS News, DMP's own Wikipedia page, direct queries for 2023-2025 Thana-level data) surfaced only more citywide-aggregate figures (e.g. a BSS article: 25,049 DMP incidents in 2023 -> 17,964 in 2024, PHQ-sourced, same aggregate granularity as everything else found). No newer per-Thana breakdown exists in anything reachable. What *did* turn up, though, is a related, real, separate gap worth fixing on its own: **DMP now runs 50 Thanas, not 41** — Dhaka's Wikipedia page lists 50 by name, including several not in this project's geometry (Banani, Bhashantek, Hatirjheel, Mugda, Rupnagar, Shahjahanpur, Vatara, Wari, and Uttara now split into Uttara East/West). Tried OpenStreetMap's Overpass API as a free source for the missing 9 boundaries — Bangladesh's Thana-level administrative relations aren't meaningfully mapped in OSM (zero real matches after properly scoping the query to Dhaka). **Left unfixed rather than approximated**: splitting/guessing at boundaries for these 9 without a real source would quietly reintroduce exactly the "invented-looking data presented as real" problem this module has otherwise avoided. Real next step if this is worth pursuing: manually check `dmp.gov.bd/crime-data/`/`archived-crime-data/` (bot-walled for this session, not for a normal browser) for an official Thana list/map, or wait for a newer BBS/geoBoundaries release.
- **Automation: real constraint confirmed, not fixable by better code, one untested real option exists**. Cloud Functions being refused a connection to `police.gov.bd` (Round 2) is a genuine network-level access decision by that site, most likely blocking cloud-provider IP ranges broadly (common anti-scraping practice) rather than Google specifically — not confirmed either way from this session, since testing that needs infrastructure on another provider this sandbox doesn't have. The one concrete, testable next step: **this repo has a real GitHub remote** (`github.com/abdullah2142/Assistive-Navigational-App`) — a scheduled GitHub Actions workflow (free tier, runs on Microsoft-hosted runners, a different network than Google Cloud) could plausibly reach the site where Cloud Functions can't, and would call the already-deployed, already-working `recordCityCrimeMonth` to do the actual write. **Not attempted this round** — untested whether GitHub's runners are also blocked, and setting it up needs the user to add a repo secret (a Firebase-authenticated token) themselves, the same category of manual step as every other account-level setup this project has deferred to the user. Given the 65-month backfill above, this is now a genuine nice-to-have rather than a blocker: the multiplier already runs on years of real history, not one fragile monthly data point.

## Round 4 (2026-09-03) — GitHub Actions automation built + tested, OpenStreetMap wired in as a placeholder routing backend

User asked to build the GitHub Actions idea from Round 3, and separately asked to run routing on OpenStreetMap as an interim placeholder until Google Maps billing is sorted out. Both built and verified real, not stubbed:

**GitHub Actions automation:**
- [x] Refactored `functions/index.js`'s crime-report fetch+extract logic (the `fetchLatestCrimeReportPdf`/`extractDmpRowViaGemini` pair) out into `functions/lib/crime_report_ingestion.js` — a Firebase-independent module (no `firebase-admin`, just `cheerio` + `fetch`) so the exact same, already-tested code can run from anywhere Node runs, not only inside a Cloud Function. `ingestCrimeReport` now just calls it; behavior unchanged, confirmed by `node -e "require('./index.js')"` still loading clean.
- [x] `functions/scripts/monthly_crime_ingest.js` — the actual script GitHub Actions runs: calls the shared module to fetch+extract, signs in anonymously to Firebase (the public Web API key, not a secret — same one already shipped inside the Flutter app), POSTs to the already-deployed `recordCityCrimeMonth`, then deletes the throwaway auth account. **Tested for real, locally, end-to-end** before wiring into CI: correctly re-extracted July 2026's report (identical numbers to Round 2/3: 3/20/34/102/11 -> 170) and recorded it successfully.
- [x] `.github/workflows/monthly-crime-report.yml` — scheduled for the 12th of each month (matching the ~10-day report-upload lag confirmed in Round 2) plus a `workflow_dispatch` manual trigger for testing on demand. YAML validated (`python3 -c "import yaml; yaml.safe_load(...)"`).
- **Not yet verified whether GitHub's runners can actually reach `police.gov.bd`** — that's the one real unknown this setup was built to test, and it can only be tested by actually running the workflow on GitHub's infrastructure, which needs the commit pushed and the secret added first (both intentionally left for the user — see chat). If GitHub's IP ranges turn out to be blocked too (same category of block Google Cloud hit), the fallback stays exactly what Round 3 already established: an occasional manual check, now optional rather than critical given the 65-month backfill.

**OpenStreetMap placeholder routing:**
- [x] `core/config/routing_config.dart` (new) — `RoutingConfig.useOpenStreetMap = true`, a `MapsConfig`/`GeminiConfig`-style flag `RoutingService` branches on. Flip to `false` once `MapsConfig`'s key actually gets Geocoding/Directions access (Round 1's still-open blocker) — nothing else needs to change, `RoutePlanningService`/the Gemini `request_route` tool/the map widget are all already backend-agnostic.
- [x] `core/services/routing_service.dart` — added `_geocodeOsm` (Nominatim) and `_walkingRoutesOsrm` (the public OSRM demo server) alongside the existing Google implementations, both live-verified via direct `curl` before writing the Dart (Nominatim correctly geocoded "Gulshan 2, Dhaka"; OSRM returned a real, road-network-computed walking route). OSRM's `geometries=polyline` output is bit-compatible with Google's own polyline encoding, so the existing `decodePolyline`/`RouteCandidate` plumbing needed zero changes.
- **Real limitation found and compensated for, not glossed over**: the public OSRM demo server's `/foot/` profile returns byte-identical distance *and duration* to its `/driving/` profile on the same two points (verified directly) — it isn't running a genuine pedestrian profile, just labeling car-speed results as walking ones. Trusting its duration would show routes as taking a third of their real walking time. Fixed by discarding OSRM's reported duration and computing it from distance at a fixed ~4.5 km/h walking speed instead (`_walkingSpeedMps` in `routing_service.dart`) — the route *geometry itself* is still real (genuine road-network pathfinding), just not confirmed sidewalk-aware, the same caveat that already applies to Google's own routing in Dhaka per the master plan.
- [x] `flutter analyze` clean project-wide (2 pre-existing unrelated infos only) after both changes. JSON field-shapes in the new Dart parsing code (`_geocodeOsm`/`_toCandidateOsrm`) cross-checked by hand against the real captured Nominatim/OSRM responses. **Full runtime path still not exercisable in this sandbox** — same GPS-on-web platform limit from Round 1 blocks reaching this code either way, unrelated to which routing backend is selected; needs the real Android device pass already queued up for this reason.

**Left for the user** (see chat for the full ask): add `GEMINI_API_KEY` as a GitHub Actions repository secret (Settings -> Secrets and variables -> Actions), and decide whether to push this session's accumulated commits (nothing has been pushed — or committed — yet; only working-tree changes exist so far).

## Round 5 (2026-09-03) — scoped commit pushed, GitHub Actions tested live: also blocked, likely a broad cloud/datacenter IP block

- [x] Committed and the user pushed a deliberately **scoped** commit (`44f1136`) — backend + workflow only (`functions/`, `firestore.rules`, `firebase.json`, `.github/workflows/`, `task.md`, one `.gitignore` fix for `ant_app/android/build/` which wasn't being ignored). **Explicitly excluded**: all Flutter-side changes (`routing_config.dart`, `routing_service.dart`, `route_planning_service.dart`, `route_safety_service.dart`, `maps_config.dart`, `dashboard_map_panel.dart`, `pubspec.yaml`/`.lock`), because (1) a real, unrelated test failure was found live in the working tree — `language_selection_screen.dart` calling `ref` unsafely inside `dispose()`, not something this session touched, looks like it's from concurrent Module 3 onboarding-voice work — and (2) several files central to Module 4's Flutter side (`chat_providers.dart`, `gemini_assistant_service.dart`) are the *same* files that other work is actively modifying, with 150+ lines of unrelated changes mixed in and no git history to cleanly separate them (neither Module 3 nor Module 4 had been committed incrementally, so there was no baseline to diff against). Committing them would have either shipped a known-broken test suite or silently absorbed someone else's in-progress, unreviewed work. The OSM routing code and the `request_route` Flutter wiring still exist locally, just not pushed — flagged as needing to go out together with Module 3's work once its own tests pass again.
- [x] First push attempt was rejected by GitHub itself, not a code problem: **a Personal Access Token needs the `workflow` scope specifically to push changes under `.github/workflows/`** — a deliberate extra guardrail GitHub applies regardless of normal repo write access. User added that scope and re-pushed successfully.
- [x] **Triggered the workflow manually and got a real, clean answer to the one open question**: GitHub Actions' runners hit the exact same `ECONNREFUSED 103.95.38.134:443` that Google Cloud Functions did (Round 2) — identical IP, identical failure mode, now confirmed independently from **two different cloud providers** (Google Cloud and GitHub/Microsoft Azure). This is real, converging evidence that `police.gov.bd` blocks cloud/datacenter IP ranges broadly as a category, not Google specifically — trying a third major cloud provider would very likely hit the same wall, so that avenue is being treated as exhausted rather than chased further. Automation from an ordinary cloud CI/serverless provider is not viable against this specific site.
- **Where this leaves things**: the standing plan from Round 3 is what's left — occasional manual checks (a human opens `police.gov.bd/en/january_2020` from an ordinary residential/consumer network, which isn't blocked, and hands the numbers to `recordCityCrimeMonth`), which is a light lift given the 65-month backfill already provides a robust multi-year baseline. Genuinely different architectures (e.g. Cloudflare Workers, which run from edge network IPs rather than a datacenter block and might not be caught by the same filter) are a real, untried option if worth revisiting later, but not pursued without the user weighing in first — two failed cloud-provider attempts is enough to stop and ask rather than keep spending effort probing for a way around what looks like a deliberate access decision.

## Round 6 (2026-09-03) — Cloudflare Workers tried, works: automation is now real and live

User said try it. Real, working, third architecture — genuinely different from the two that failed (edge PoPs, not a datacenter VM/serverless block), and it mattered:

- [x] **Diagnostic confirmed first**: a bare Worker doing nothing but `fetch(CRIME_STATS_ARCHIVE_URL)`, deployed to Cloudflare's real edge (not local `wrangler dev`, which would've just been this sandbox's own network again and proven nothing), came back a real `200` with real content (203KB, contains "Crime Statistics"). Confirmed Cloudflare's edge genuinely isn't blocked where Google Cloud and GitHub both were.
- [x] **Built out the real pipeline** — `cloudflare-worker/src/index.js`, a deliberate hand-port of `functions/lib/crime_report_ingestion.js` + `functions/scripts/monthly_crime_ingest.js`'s logic (same DMP-row extraction prompt, same pedestrian-relevant category list, same `recordCityCrimeMonth` call). Can't literally share the file with the Node-based versions — Workers run on `workerd`, not Node, no Node APIs by default — so it's regex-based HTML parsing instead of `cheerio` (the real table markup is simple enough not to need a DOM parser) and a manual `ArrayBuffer`-to-base64 conversion instead of `Buffer`.
- [x] **Deployed for real** using an isolated local Node 22 (`wrangler` hard-requires it; downloaded standalone to the session scratchpad rather than touching the machine's system-wide Node 20, which another concurrent session may depend on) plus a Cloudflare API token the user generated and shared directly (scoped to Workers edit, not their account password — same category of credential-sharing already established this session for the Gemini key). Needed one extra one-time step neither of us had hit before: registering a `workers.dev` subdomain via the Workers API (`ant-assistive-nav.workers.dev` — the account had none yet), which `wrangler deploy` can't do automatically on its own.
- [x] **Full pipeline live-verified end-to-end, for real, against the actual deployed project**: hit `https://ant-crime-report-probe.ant-assistive-nav.workers.dev` directly — first two attempts came back empty (one surfaced as a Cloudflare `525`, an edge-to-origin TLS hiccup — transient, not the same category of block as before), third attempt succeeded cleanly: fetched the archive, extracted July 2026's real numbers again, wrote to `recordCityCrimeMonth` (`{"period":"2026-07","pedestrianRelevantIncidents":170}` — idempotent re-write of the same real data, harmless). A monthly Cron Trigger (`0 3 12 * *`, matching the ~10-day report-upload lag) is deployed and active — this now genuinely runs unattended, no monthly human check required.
- [x] **Retired the now-redundant, now-noisy GitHub Actions workflow**: removed its `schedule` trigger (kept `workflow_dispatch` for manual re-testing later if ever useful) so it stops generating a failure-email every month for a path that's now confirmed not to work from that network — the real automation lives on Cloudflare going forward. Left the workflow file itself in place as a documented, honest record of what was tried and why it didn't pan out, rather than deleting the evidence.
- **Real remaining follow-up, not urgent**: the Worker doesn't retry internally on a transient failure like the `525` seen mid-testing — if the one monthly Cron Trigger firing happens to land on a bad moment, that month's data is silently skipped until the next manual check or next month's run. Worth adding a simple retry-with-backoff inside `runIngestion` at some point, but not blocking given the 65-month backfill means missing an occasional single month barely moves the rolling multiplier.

---

# Session 4 (2026-09-04) — edge collectors, and giving the crime engine a memory

**224 Flutter + 51 Cloud Function + 13 Worker tests, all passing.** `flutter analyze` clean
(4 pre-existing style infos). `firebase deploy --dry-run` passes.

## Cloudflare Worker collectors

The Worker now hosts three jobs instead of one, for the reason already established in Module 4:
**Cloud Functions in this project cannot reach these sites** and Cloudflare's edge can.

`src/lib/` — `feed.js` (RSS 2.0 + Atom, regex-based since `workerd` has no XML parser),
`firebase.js` (shared anonymous-session dance, previously inline), `thana_index.js` (generated),
`thana_match.js`. `src/collectors/` — `news.js`, `social.js`. Routes: `/`, `/news`, `/social`, and a
`CRON_JOBS` map so one Worker can host jobs on three schedules.

**Every feed was verified live before being written into the code**, not assumed:
- `thedailystar.net/news/crime-justice/rss.xml` — 200, crime-specific, 10 items
- `thedailystar.net/rss.xml` — 200
- `en.prothomalo.com/feed` — 200; `prothomalo.com/feed/` 302s to `/stories.rss`
- `reddit.com/r/{dhaka,bangladesh}/new/.rss` — 200 (the JSON API is 403 without OAuth, hence RSS)

**X/Twitter and Facebook are deliberately absent.** Both need paid or authenticated search APIs; the
alternative is scraping behind bot protection, which breaks silently and unpredictably. A source that
fails quietly is worse than no source, because the safety map then goes stale with nobody noticing.
The ingestion contract will not need to change when credentials exist.

### Thana matching is the strictest part, and for a concrete reason

The first item in The Daily Star's live crime feed while this was written was a killing in **Raozan,
Chattogram** — 250 km from Dhaka. A naive keyword match would have been wrong on real row one. So:
- A competing district/city in the text with no mention of Dhaka → discarded. Dhaka has a Kotwali and
  a Cantonment; so does Chattogram, and so does most of the country.
- More than one thana named → discarded, not attributed to whichever came first.
- Whole-word matching with a bounded trailing suffix (≤3 chars, ≥3-char stem), which covers English
  plurals ("snatchers") and Bangla case marking (গুলশান → গুলশানে) without degenerating into the
  substring matching this codebase has been bitten by repeatedly.
- Cheap keyword filters run **before** any Gemini call — most feed items are not crime, and most
  crime is not about a Dhaka thana. Paying a model to establish that would be the largest avoidable
  cost in the pipeline. A hard cap of 12 classifications per run backstops a pathological day.
- The classification prompt is written so `none` is the expected answer: a single arrest is not
  evidence a neighbourhood has deteriorated.

`thana_index.js` is generated from the seed, and `functions/test/` asserts the two have not drifted —
a stale slug there would post advisories matching no zone and silently do nothing, which looks
exactly like a working pipeline.

## The crime engine now has a memory

**Answering the question directly: it did not, and that was a real gap.** Measured before the fix:
Mohammadpur reads **38.0** at night with a severe advisory live and **6.1** once it expires — back
under the threshold of 7, as though nothing had ever been reported. The engine could *react* to
current data but could not *learn* from it, because every layer was either permanently stale (2009
seed), uniform (citywide trend), or temporary by design (advisories).

`lib/learned_baseline.js` is the missing layer. It counts **distinct months in which independent
evidence existed** — not incidents, not articles, not posts:

| Evidence months | Learned multiplier | Mohammadpur night score, no advisory |
|---|---|---|
| 0–3 | 1.0 (no effect at all) | 6.1 |
| 7 | 1.27 | **7.7** — clears the threshold on its own |
| 12+ | 1.6 (capped) | 9.7 |

Deliberate properties:
- **One news cycle cannot move it.** Three separate months minimum, matching every other
  corroboration threshold in this codebase. Below that the effect is exactly 1.0, not a small one.
- **Social signals never count here.** They can raise a temporary advisory; they cannot edit a
  neighbourhood's standing score.
- **Only confirmed (Red Flag) crowdsourced *crime* hazards count** — a Red Flag pothole says nothing
  about a crime score.
- **Capped at 1.6×**, far below the advisory (2×) and hotspot (5×) multipliers. This corrects a stale
  figure; it does not become a new source of truth, and the sourced 2009 number stays recognisable.
- **It decays on its own** — evidence ages out of a 24-month window, so a neighbourhood that improves
  recovers with no manual intervention and no permanent state anywhere.
- Written by the hourly sweep, idempotent within a month (it runs ~700 times a month), and trimmed to
  the window on write so a zone document cannot grow without bound.

## Verdict on "does the crime system accommodate contemporary data?"

It does now, at four independent timescales, and the layering is the point — each covers what the
others cannot:

| Layer | Granularity | Currency | Can it move alone? |
|---|---|---|---|
| 2009 academic seed | per-thana | frozen | baseline only |
| Citywide trend (police.gov.bd, monthly) | citywide | monthly | 0.7–1.5× |
| News advisories | per-thana | days | up to 2×, can trigger hotspot |
| Social signals | per-thana | hours | capped at 1.5×, never hotspot |
| Crowdsourced $w_2$ | ~10 m | live | blocks a path outright |
| **Learned baseline** | per-thana | months–years | up to 1.6×, persists |

Remaining honest limitation: **the 2009 figure itself can never be corrected downward.** Every
current-data layer can only raise risk. A thana that was genuinely dangerous in 2009 and is fine now
keeps its baseline forever. That is the safe direction to be wrong in, but it is a real asymmetry and
it should be revisited if a current per-thana source ever exists.

## DEPLOYED (2026-09-04)

**Cloud Functions and Firestore rules are live on `ant-assistive-nav`.** All 12 functions deployed,
including the five new ones — `onHazardReportCreated` (Firestore trigger), `decayHazardZones`
(hourly), `resolveHazardZone`, `recordThanaAdvisory`, `recordSocialSignal` (callables) — plus an
updated `checkRouteSafety` carrying the advisory and learned-baseline logic. Rules released.

**The first attempt was a partial failure and needed a retry.** `checkRouteSafety` and
`seedCrimeZones` both failed with `Unable to parse JSON: SyntaxError: Unexpected token '<',
"<!DOCTYPE "` — a Google API returning an HTML error page instead of JSON, the same transient seen
once during an earlier dry-run. The other ten succeeded. A targeted redeploy of just those two
succeeded immediately. **Worth remembering: the shell exit code was 0 despite the failure**, because
the command was piped through `tail` — so this deploy would have been reported as clean if the log
had not been read. Read the log, not the exit code.

Verified after deploy, rather than assumed: `functions:list` shows all 12 with the right trigger
types, and an unauthenticated probe of each new callable returns this codebase's own
`"Sign-in required."` string — proving they are executing the new code and not a stale revision.

## Not done

- **The Cloudflare Worker is NOT deployed** — blocked on Cloudflare authentication, which is an
  interactive browser flow. See below.
- **Nothing is device-tested.**
- No thana has any advisory or evidence month yet, so the news/social/learned layers are live but
  inert until the Worker runs.
- `wrangler@4` requires Node 22; this machine has Node 20, so `wrangler@3` is the version to use.
- **Original blocker note (now partly resolved):**

- ~~None of this is deployed~~ — functions are; the Worker is not. The Worker needs `wrangler deploy` and its
  `GEMINI_API_KEY` secret; the functions need the deploy command below.
- Collector output has never been observed against live feeds end to end — the feeds and the parsing
  are verified, the classification and recording path is not.
- No thana currently has any advisory or evidence month, so the new layers are inert until the
  collectors run.

# Session 3 (2026-09-04) — destination clarification, current-risk advisories, deploy readiness

**224 Flutter tests + 38 Cloud Function tests, all passing.** `flutter analyze` clean (4 pre-existing
style infos). APK builds. `firebase deploy --dry-run` passes for `functions,firestore:rules`.

## Multi-turn destination clarification (the gap left open last session)

An unresolved destination is now a short conversation instead of the single dead-end sentence
*"I couldn't find that."* A user who cannot see a map does not name places the way a geocoder wants
them named — "the eye hospital", "my daughter's school" — and Dhaka's informal addressing means even
a real address often resolves to nothing.

- `RoutingService.geocodeCandidates` returns *all* matches, not just the top hit. Returning one
  silently discarded the thing that matters most: whether the geocoder was actually sure.
- `RoutePlanAmbiguous` is a distinct outcome from failure. Several matches is not an error — it is a
  question. Options are numbered and read aloud, capped at three (a spoken list is held in working
  memory; six read-aloud addresses is a memory test, not a choice), and collapsed by proximity so a
  building and its own entrance are not offered as a "choice".
- `DestinationClarifier` is pure and synchronous, so the whole multi-turn dialogue is tested without
  a network, a geocoder, or a microphone.
- **The original name is never discarded** — each round searches for it *plus* every hint gathered so
  far, because the original is the only part known to have come from the user.
- **Each round asks for a different kind of clue**: area first (broad, easy, most useful for
  narrowing a Dhaka search), then a landmark. A user who could answer "where is it?" would have
  answered it the first time; repeating the question is how this becomes a trap.
- **Bounded at 3 rounds.** A blind user standing on a footpath being interrogated about an address
  they have already described twice is not being helped. The give-up message ends with two things
  that actually work, not an apology.
- Escape hatches: "cancel"/"বাদ দাও" always works, and simply asking for something else abandons the
  clarification rather than trapping the user in it.
- On success it offers to save the place — a destination that took three questions to find is exactly
  the one worth never having to find again.

**Two real matching bugs the tests caught:** every candidate for "the hospital" contains the word
"hospital", so name-matching on it picked whichever was listed first while looking like a real
answer (now only words *unique to one option* count); and "the one near my house" was read as picking
option 1 (bare cardinals now only count when the reply is essentially nothing else — which also keeps
Bangla working, since a `bn-BD` recognizer transcribes "দুই" far more often than "২").

## Mohammadpur, and current-risk advisories

**Answering the question directly: no, Mohammadpur is not flagged in the existing source.** It is
9.35 crimes/km² in the 2009 table → score 3.8, against a hotspot threshold of 7.7. The base data is
17 years old and cannot know what a neighbourhood is like now; the citywide trend multiplier cannot
help either, since it is one number applied uniformly to all 41 thanas.

New `thanaAdvisories` layer, with two source tiers:

- **`news`** — a citable published article. Can reach any severity, including the one that promotes a
  thana to notorious-hotspot temporal behaviour (spiking from dusk rather than 8 PM).
- **`social`** — corroborated posts. Capped at `high`, **can never promote to hotspot**, and expires
  in 14 days rather than 60.

`ai_developer_prompt.md` originally forbade social-media scraping; the project owner explicitly
overruled that this session, so it is in — on its own tier, because the reasoning behind the original
rule does not stop being true just because the rule was lifted. An unsourced post is weaker evidence
than a published article; rumour about a neighbourhood propagates faster than correction, attaches
disproportionately to poorer areas, and this app converts whatever it believes directly into "the app
will not walk you through there", delivered to someone who cannot see the map and cannot check.

Safeguards, all tested:
- **Provenance is enforced, not expected.** No source URL and publication date → rejected outright.
  Social signals additionally require an author handle, because corroboration counted per *post*
  instead of per *account* is not a threshold at all.
- **Corroboration reuses Module 5's Red Flag rule exactly** — 3 distinct accounts in a 72-hour window,
  counted by author. One account posting twenty times corroborates nothing. One anti-spam rule in the
  codebase, not two that can drift.
- **Advisories can only raise risk, never lower it**, and are capped at 2.0×.
- **They taper rather than expiring off a cliff**, and the hourly sweep retires stale ones — a
  neighbourhood must be able to *stop* being flagged.
- **The strongest live advisory wins, not the newest** — a severe advisory from six weeks ago says
  more than a mild one from yesterday.
- Provenance is returned to the client in the verdict, so an elevated score traces back to a URL.
- `thanaAdvisories`/`socialSignals` are read-only to clients; a client-writable advisory would let any
  signed-in device mark a real neighbourhood dangerous for everyone, unsourced.

Ingestion is via `recordThanaAdvisory`/`recordSocialSignal` callables rather than in-function
scrapers, for the reason already established by `recordCityCrimeMonth`: **Cloud Functions in this
project cannot reach these sites** (confirmed with police.gov.bd from two regions). Collection belongs
in the existing Cloudflare Worker; these are the contracts it posts through. **The Worker-side
collectors are not written yet** — the backend contract, scoring, corroboration, decay and rules are.

## `seedCrimeZones` no longer needs re-running

The hotspot flag is now derived at read time from data already stored on each zone
(`baseCrimeScore` + `dataSource`) rather than from a persisted `notoriousHotspot` field.
`densityToScore` is monotonic, so thresholding the score selects exactly the same thanas as
thresholding the density — asserted by a test over the whole table rather than assumed. A persisted
flag still wins if present.

This removes a manual step from deployment, and that is the point: `seedCrimeZones` is an
authenticated callable, so re-running it is a bearer-token dance, and **a safety rule that silently
does nothing until someone remembers to perform it is a rule that will eventually be wrong in
production.**

## Deployment status

`firebase deploy --only functions,firestore:rules --dry-run` passes. Project `ant-assistive-nav`,
authenticated, dependencies installed, discovery lists all 12 functions including the five new ones
(`onHazardReportCreated`, `decayHazardZones`, `resolveHazardZone`, `recordThanaAdvisory`,
`recordSocialSignal`). No composite index is required — every new query is equality-only, which
Firestore serves by merging single-field indexes.

One transient `Unable to parse JSON` on the first dry-run did not reproduce; the discovery endpoint
was verified serving a valid manifest directly.

# Session 2 (2026-09-04) — voice flexibility, saved places, spoken turn-by-turn navigation

**203 Flutter tests + 19 Cloud Function tests, all passing.** `flutter analyze` clean (4 pre-existing
`prefer_initializing_formals` infos). `flutter build apk --debug` succeeds. Nothing here is
device-tested yet.

## Crime module — hotspots now derived from the existing source, not invented

The seed's source is real and citable (Chowdhury 2011, Table 2, from DMP HQ Jan–Mar 2009 data,
crimes/km²). Rather than hand-listing "notorious" neighbourhoods, `isNotoriousHotspot` computes them:
a thana qualifies at **≥ mean + 2σ** of the *academically-sourced* entries only. On the current table
that selects exactly one — **Paltan** (29.77/km², ~3.1σ above the mean, nearly double the next
thana). Worth stating plainly: the module plan's own example is "specific alleys in Mirpur", and the
**source data does not support it** (Mirpur is 4.64/km², below the city mean). The data wins over the
example, and a test asserts nobody quietly adds Mirpur back by hand.

Interpolated (neighbour-estimated) entries can never be hotspots — a 5× multiplier on a guess
compounds the guess instead of flagging a fact. The flag re-derives itself, so fresher densities
update the hotspot set rather than preserving a 2009 opinion forever. `notoriousHotspot` is a
separate axis from `categoryHint`, not a replacement: Paltan is a commercial core *and* an outlier,
and collapsing the two would discard the daytime-footfall signal.

**Also examined and deliberately not changed:** `densityToScore`'s min-max normalization is
compressed by Paltan's outlier — only 1 of 41 thanas clears the daytime threshold. Log-scaling
"fixes" that by pushing 26 of 41 over it, which is the everything-is-red failure the plan itself
warns about for hazard decay. Changing the safety scale on my own preference rather than on evidence
would silently alter routing citywide, so the documented derivation stands and the temporal
multiplier does the discriminating.

## Voice: flexible phrasing instead of exact phrases

New `core/services/voice_matching.dart`. Matching is now on **word presence, not word order or
adjacency**: a spec names the words that carry the meaning, and the utterance matches if they are in
it somewhere, however arranged. Three parts, because loosening a matcher that fires real actions is
dangerous in a specific way — free chat has far more room for an innocent sentence to collide with a
keyword than a closed option list does:

- `anchors` — the content words. At least one must appear.
- `context` — words that disambiguate an everyday anchor ("dark" + "screen"/"mode"/"theme"), required
  for any anchor that shows up in ordinary speech.
- `blockers` — veto words: negations, and question framings ("is there a pothole?" must not file a
  report; "what does dark mode do?" must not change the theme).

Every matcher was migrated: routing, theme, language, verbosity, text size, on/off toggles, and the
self-describing trait settings. Concretely, all of these now work and previously cost a full Gemini
round trip: *"i wanna go to Gulshan"*, *"let's go to New Market"*, *"how do i get to Dhanmondi"*,
*"bring me to work"*, *"make the screen darker"*, *"disable the wake word"*, *"give me more detail
when you talk"*.

**Bangla case-suffix tolerance** (`containsTermInflected`): Bangla attaches case markers to nouns —
অফিস → অফিসে, বাসা → বাসায়. Strict word equality failed on the single most common way a Bangla
speaker names a destination. Only a *trailing* extension counts, and only on a stem of ≥3 characters,
so this cannot degenerate back into substring matching — "না" can never prefix-match নারায়ণগঞ্জ.

**False positives the audit caught and fixed:** a bare `going to` in the route pattern matched *"is it
going to rain before I get there"* and started walking the user somewhere; question framings changed
settings.

## Saved / frequent places

`SavedPlace` on `UserProfile`, an optional onboarding step (`FrequentPlacesScreen`), voice
save/remove, and resolution during routing.

- **Latency**: "take me to work" resolves with **no geocode and no model call**, and works offline.
- **Reachability**: "work", "Ma's house", "the clinic" are not geocodable strings — no prompting turns
  them into coordinates. Saving them once is what makes those destinations possible at all.
- `save_place` with no address saves the user's **current coordinates** — "save this as my office",
  said while standing there. That is the most reliable way to record a Dhaka destination, since
  informal addressing means many real places have no string a map can resolve.
- Synonyms per kind, so someone who saved "work" is still understood saying "office", and vice versa.
- **Ambiguity is asked about, never guessed.** Two places matching "my relative" produces "did you
  mean Ma's house, or Bhai's house?" and plans no route at all. Walking someone to the wrong
  relative's house is a failure they may not notice until they arrive.
- Saving over an existing label *moves* it rather than adding a duplicate, which would otherwise
  resolve ambiguously forever.
- The onboarding step is genuinely optional — "skip"/"done" at any prompt ends it.

**Bug found while wiring:** the ambiguity question was being swallowed by the generic
"something went wrong planning that route" branch, so the user was never asked. Fixed by hoisting the
check above every per-call error branch.

## Spoken turn-by-turn navigation

Previously the app planned a route and drew an arrow. It never said which way to turn — the sighted
half of the feature only.

- `RoutingService` now requests and parses **manoeuvres** (`steps=true` from OSRM, and the equivalent
  from Google), normalized to a backend-agnostic `ManeuverKind` so neither vendor's vocabulary leaks
  into the narration or the bilingual strings.
- `NavigationNarrator` — a pure state machine over `(steps, routePoints, position)`, tested by
  walking synthetic GPS tracks. Built around two failure modes: **saying too little** (a missed turn
  leaves a blind user walking confidently the wrong way) and **saying too much** (an assistant that
  re-announces every tick becomes noise, and is talking over the ambient sound a blind pedestrian
  actually navigates by). Three distance bands per turn, never repeated, never re-issued on GPS
  jitter.
- `NavigationController` — subscribes to GPS, speaks each cue, and fires the three haptic patterns
  Module 7 allows. Starts automatically when a route is accepted: for a user who cannot see the map,
  a planned-but-silent route is not usable at all.
- Bilingual phrasing puts **distance before direction** ("In 50 metres, turn left") — speech is
  linear, and the listener needs urgency before instruction. Unnamed roads are omitted rather than
  read as "turn left onto unnamed road", which sounds like information and carries none. Off-route
  says **stop and re-route**, never "turn around": telling a blind pedestrian on a Dhaka street to
  reverse direction without seeing what is behind them is not a safe instruction.

**Two real design bugs the tests caught before any device saw them:**
1. `reachedRadiusMeters` (20 m) sat *above* the imminent announce band (15 m), so the narrator retired
   every manoeuvre before its instruction could fire — **"Now, turn left" was unreachable code**. The
   user got both warnings and then silence at the actual corner. Now 15 m against a 25 m band, with a
   test asserting the invariant.
2. The documented "resync after a GPS gap" was not actually implemented — a step only counted as
   reached while the user was *within* the radius, so a dropped fix that returned with them well past
   a corner left guidance stuck on that turn forever. Progress is now measured along the route
   polyline, not by proximity to corners. The same fix cured off-route firing at the start of every
   correct route (manoeuvre points are only the corners; the origin is not one).

## Read-back confirmation on voice input

A sighted user dictating a phone number glances at the field and sees a dropped digit. That glance is
the entire error-correction mechanism, and a blind user does not have it — a misheard value is
committed silently and surfaces later as a contact that does not ring or a code that never works.

Shared `VoiceConfirm.readBackAndConfirm`, now applied to the pairing code, both safe-haven addresses,
every `VoiceDictateButton` field, and the new places step (emergency contacts already had it). Digits
are **spaced and grouped in threes** before being spoken — a TTS engine reads "01712345678" as one
enormous number, which is unverifiable by ear and defeats the point. Unclear answers re-ask rather
than assuming either way: assuming yes commits something the user was rejecting, assuming no discards
something correct.

## Local vs LLM split, and latency

`test/local_vs_llm_coverage_test.dart` is the audit, as a test rather than a claim: 37 routine
phrasings (both languages) asserted to resolve locally, 7 genuinely hard requests asserted to still
defer, and 8 innocent sentences asserted to do nothing.

Where the latency went:
- **Saved places** remove a geocode *and* a model call from the most common request in the app.
- **Flexible matching** moved a large class of routine commands off the model — everything in that
  corpus is now zero-network.
- The boundary is deliberate: `add_emergency_contact`, message add/remove, and anything needing real
  comprehension still go to Gemini. A local guess there corrupts real contact data.
- Streamed replies (`generateContentStream`) were already in place and verified working, so the first
  words appear while the rest is still arriving.

## Background listening & streamed Gemini — both already existed; two real bugs fixed

Verified present and wired: `WakeWordForegroundService.kt` + manifest entry + `BackgroundListeningService`
+ lifecycle observer; and `generateContentStream` + `onPartialText` consumed by the chat controller.

1. **`AppLifecycleState.inactive` started the foreground service.** `inactive` fires transiently while
   the app is still on screen — notification shade, incoming-call banner, permission dialog, app
   switcher — so an ongoing "listening in the background" notification appeared in front of a user who
   had backgrounded nothing, and flapped, since `inactive` is also passed through on the way back to
   `resumed`. Now only `paused`/`hidden`.
2. **`POST_NOTIFICATIONS` was declared but never requested at runtime.** Android 13+ made it a runtime
   permission, so the foreground service's ongoing notification silently never appeared — and an
   invisible foreground service is exactly what aggressive OEM battery managers (MIUI, the device
   under test) kill first. Now requested when background listening starts, so the prompt arrives with
   a reason attached.

## What is NOT done

- **Nothing in this session is device-tested**, and nothing in Module 5 is deployed.
- **Destination "triangulation" is partial.** Saved places, ambiguity questions, and flexible
  extraction are in. What is *not* built is a multi-turn clarification loop for an unknown place —
  today a failed geocode says "I couldn't find that" rather than asking "is it near a landmark you
  know?" and combining answers across turns. That needs conversational state the chat controller does
  not carry yet.
- The `_kindFor` guess in the places screen is a heuristic; a wrong guess costs nothing (the label
  always matches) but it is not clever.
- Turn-by-turn depends on OSRM's `steps`, which is a demo server with no uptime guarantee. With no
  steps the app says so and falls back to arrow-and-distance rather than going silent.

# OPEN BUGS round — 2026-09-04 session: all five closed, plus new bugs found by testing

Every bug in the previous list was root-caused and fixed, and each fix is locked down by a test that
**fails on the old code and passes on the new** (verified by reverting and re-running, not assumed).
Full suite: **76 Flutter tests + 18 Cloud Function tests, all passing**; `flutter analyze` clean
(3 pre-existing `prefer_initializing_formals` infos, untouched); `flutter build apk --debug` succeeds.

## 1. [FIXED] Black dashboard after onboarding — root cause found

`SplitModeDashboardScreen`'s body was `Column(children: [Visibility(maintainState: true, child:
Expanded(...)), Expanded(...)])`. `Expanded` is a `ParentDataWidget` and **must be a direct child of
a Flex** — `Visibility` inserts its own render object between them, so it threw
`Incorrect use of ParentDataWidget` during build. That takes down the entire `body` subtree while the
`Scaffold`'s `AppBar` still renders, which is exactly the reported symptom ("only the settings button
renders"). Reproduced in an isolated widget test before touching the code.

Fixed by replacing it with `Offstage` around an explicitly-sized box inside a `LayoutBuilder`.
`Offstage` does precisely the job the `Visibility(maintainState: true)` was there for — child stays
mounted and laid out (wake-word/STT session and chat scroll position survive) but is not painted, not
hit-tested, and `sizedByParent` reports `constraints.smallest`, so it takes zero room and the map's
`Expanded` fills the body when expanded. Verified against Flutter's own `RenderOffstage` source.

`test/split_mode_dashboard_test.dart` — 3 tests: no ParentDataWidget error, 60/40 split by default,
map fills the body when expanded while `ChatStreamPanel` stays mounted. All 3 fail on the old code.
Swept the rest of `lib/` for the same misuse: no other occurrence.

## 2. [VERIFIED + a new bug found] `spokenTextToDigits`

The previously-applied "triple 3, 1 0" fix is **correct** — 8 unit tests over merged tokens, separate
word tokens, both multipliers, punctuation, filler words, and Bangla multiplier words all pass
(`test/spoken_digits_test.dart`).

**New bug found while testing it**: Bengali numerals (০-৯) were silently dropped entirely. Dart's
`\d` is ASCII-only, so a `bn-BD` transcript of a dictated phone number survived token cleanup (those
characters are inside the Bangla block the cleanup regex deliberately keeps), matched no digit *word*
either, and fell out through the "unrecognized word" branch. A Bangla-speaking blind user dictating
their own phone number got a **silently empty field** — the worst failure mode for someone who can't
see that nothing was entered. Fixed with `_asAsciiDigit`, which normalizes both ASCII and Bengali
numerals; 3 more tests cover it, including multipliers applied to Bengali numerals.

## 3. [FIXED across every screen, and now enforced by test] "Narrate all options before listening"

Audited all 8 screens that bypass `OnboardingScaffold` with `autoSpeak: false`:

- `deaf_hearing_screen.dart` — **was broken**, fixed. Now speaks title + subtitle + both option
  labels/descriptions before the mic opens; `_spokenOptions` is shared with `build`'s `spokenOptions`
  and the mid-loop "help" reply so the three can't drift apart again (drifting is how this happened).
- `cognitive_anxiety_screen.dart` — **was broken**, fixed. Speaks title + subtitle + `cognitiveSpokenHint`
  (both questions) up front, and each `_askYesNo` now appends a new localized "Answer yes or no."
  so the user knows what a valid answer sounds like *before* the mic opens, not only on "help".
- `safe_havens_screen.dart` — partial gap, fixed (screen overview added to the intro).
- `user_pairing_screen.dart` — partial gap, fixed. Also removed a **stale comment** in
  `onboarding_strings.dart` still describing the reverted "brief intro, full options on request" design.
- `verbosity_voice_screen.dart`, `magic_button_contacts_screen.dart`, `passerby_messages_screen.dart`
  — audited, already correct, left alone.

`test/onboarding_narration_test.dart` drives the **real screens** with a recording TTS and an
unavailable mic, and asserts on what was actually spoken before the first listen — a rule enforced
only in the shared shell silently stops applying to whoever opts out of it, which is exactly how these
drifted. Confirmed it catches the original deaf-screen gap by reverting just that hunk.

**New i18n bug the test caught**: `'Option 1:'` was hardcoded English in six screens, so Bangla
narration read "Option 1: [Bangla label]" — and a `bn-BD` voice pronounces a bare ASCII "1" with an
English accent mid-sentence. Added `Onboarding.spokenOptionLabel(int)` (→ "বিকল্প ১", with Bengali
numerals) and replaced all of them. The test found an `Option 3` that the first sweep missed.

## 4. [FIXED — reproduced first] Duplicate "Welcome to ANT" screen

Reproduced deterministically before changing anything (`test/onboarding_stale_listener_test.dart`).
The mechanism is **not** what earlier rounds assumed:

`_stopCurrentScreenVoice()` stopped the mic, but **stopping the mic does not stop the loop**.
`listenOnce` just returns having captured nothing, which `listenForVoiceChoice` reads as "the user
said something I couldn't match" — so it counts a miss, speaks the retry hint, **re-reads the entire
option list after two misses**, and reopens the mic. Its only cancel signal is `stepGeneration`, which
`_goTo` hasn't bumped yet because it is still behind the Firestore `await`. The repro logs
`miss #1` and a second `listenOnce` immediately after the user answers **by tapping**. For a user who
can't see the screen, a screen they already answered reading its title and options at them again *is*
that screen coming back.

Fixed by making `_stopCurrentScreenVoice()` an actual cancellation — it now bumps `stepGeneration`
too, which every screen's loop already checks. Safe because `stepGeneration` is used *only* as a
cancellation token (`OnboardingFlowScreen` keys on `ValueKey(step)`), verified before relying on it.

**Regression this would have introduced, caught and fixed**: cancelling on *every* navigating action
made the cancellation permanent when the navigation then *failed*, leaving a fully-mounted screen with
no voice at all — and onboarding errors are only ever drawn as red text, so a blind user would hit a
silent dead end. Added `OnboardingState.voiceRearmToken`: `_failCurrentStep` bumps it, the scaffold
listens for it, **speaks the error** (which never happened before, for any screen) and re-arms the
loop — via a new `onVoiceRestart` hook for the 7 custom-loop screens. Covered by a second test.

**Larger bug surfaced by that work**: thirteen profile-writing controller methods (`setVisionLevel`,
`setDeafHearing`, `setSafeHavens`, …) awaited a Firestore write with **no error handling whatsoever**.
An offline or permission-denied write threw straight past them into the framework as an unhandled
async error: the step silently never advanced, nothing was shown, nothing was spoken. That is the
crash-instead-of-degrade behaviour `ai_developer_prompt.md`'s "Graceful Offline Degradation" rule
exists to prevent. `_persist` now returns success and every navigating call site bails on failure into
`_failCurrentStep`.

## 5. [VERIFIED] OSM map / Google Maps

Both map panels now render under test with `RoutingConfig.useOpenStreetMap = true` — the dashboard's
via `test/split_mode_dashboard_test.dart` (`flutter_map`'s own OSM tile-policy warning in the output
is live proof `FlutterMap` actually initialized), and the Guardian's via a new
`guardian_hub_test.dart` case that supplies a real location so `_buildOsmMap` is reached. The old
empty-state test never touched that code path, which is why the `NetworkTileProvider` const-headers
crash could hide there.

**Hardening while in the area**: `INTERNET` was declared only in the debug/profile manifests, where
the Flutter template puts it for the dev-time VM connection. Checked whether that actually breaks
release builds rather than assuming — it does not, the Firebase AARs merge it in transitively — but
depending on a transitive dependency for the app's own core permission isn't something to leave to
chance, so it's now declared explicitly in the main manifest.

---

# NEW BUGS found by testing this session (none of these were reported)

## `LocalIntentMatcher` — four real bugs, all confirmed by test before fixing

This runs *before* Gemini and executes what it matches directly, with no model in the loop to
sanity-check it, so a wrong match silently changes a real accessibility setting.

1. **Bangla "I cannot hear" turned Deaf/text mode OFF.** Bangla negates *after* the verb, so the
   affirmative phrase "শুনতে পাই" ("I can hear") is a literal prefix of "শুনতে পাই না" ("I cannot
   hear") — plain `contains` matched the wrong list and set the exact opposite of what was said.
2. **"ভিড়ে আমার অস্বস্তি লাগে না" ("crowds don't bother me") turned crowd anxiety ON** — same shape.
   Both fixed by a shared post-match negation check (`_negatedAfter`) that inspects only the
   immediately-following word, so a negation elsewhere in a longer message can't flip an unrelated clause.
3. **Routing to any destination whose *name* contains "না" was silently swallowed.** The Bangla
   negation guard was a bare `text.contains('না')` — which is also the first two characters of
   নারায়ণগঞ্জ (Narayanganj), নাখালপাড়া (Nakhalpara) and নারিন্দা (Narinda), all real Dhaka-area
   destinations. Now a whole-word check. Same lesson as the already-fixed "male" inside "female".
4. **A message naming both options picked whichever list was checked first** — "switch from dark mode
   to light mode" set **dark**, the mode being switched away from. Now returns `null` on any
   ambiguous pair (theme, language, verbosity, text size, and both sides of a boolean setting), which
   falls through to Gemini — the documented contract for anything this matcher isn't confident about.
   Guessing was never the right answer here.

`test/local_intent_matcher_test.dart` — 14 tests.

## `classifyTraitYesNo` — the worst bug found this session

**The app's own suggested Deaf answer classified as "hearing is fine".** The bare yes/no shortcut ran
*before* the specific present/absent phrase lists. "কানে শুনি না" ("I don't hear with my ears") — the
exact phrase the app reads out to the user as the Deaf option — ends in the bare-no particle "না" and
is under the 15-character shortcut threshold, so a Deaf user repeating back what they had just been
told to say was recorded as hearing perfectly well, and the **entire Deaf/Hard-of-Hearing
accommodation silently never turned on.**

Fixed by ordering: phrase lists (which already have negation baked in) are strictly more specific
than a bare particle and must win. Also made the bare yes/no fallback whole-word — "no" lives inside
"know", "another" and "normal"; "yes" inside "yesterday", so "I know I do" came back as a flat
refusal. `test/onboarding_voice_test.dart` — 9 tests.

---

# Module 5 — Community Crowdsourcing & Temporal Safety

Source: `05_module_plan_crowdsourcing.md`. Backend logic is pure and unit-tested away from Firestore
(`functions/test/hazard_logic.test.js`, 18 tests, `npm test` in `functions/`) — these are the
decisions that close a road for every user of the app, so they are not left to only be exercised
through a deployed function.

## Step 1 — Multi-modal reporting
- **UI input** already existed (Crowdsource Reporting Hub, three categories, GPS captured on submit).
- **Voice input** upgraded from "open the form" to going *straight to the named hazard*:
  `LocalIntentMatcher` now recognizes 13 distinctive hazards in both languages ("report an open
  manhole" → `roadHazard`/`openManhole`), threaded through a new `HazardReportPrefill` →
  `AssistantTurn` → `ChatState` → `CrowdsourceReportingHub`, which skips the steps the command already
  answered. Gemini's `open_hazard_report` tool schema gained the same optional args so both paths agree.
  - A **report verb is required** ("report"/"flag"/"there's a"): without it, "is there a pothole near
    me?" would file a report about a pothole the user was only asking about. Reports close roads for
    other people, so a false one costs more than a missed one. Tested explicitly.
  - Only hazards with an unmistakable name are listed. A bare "blocked"/"broken" could be any of
    several sub-categories, and a wrong guess files a real report under the wrong type — which then
    clusters with the wrong reports and decays on the wrong schedule.
  - A prefilled sub-category that isn't valid for its category is dropped rather than trusted; a test
    asserts every phrase in the table produces a real `hazardSubCategoryKeys` entry.
- **Passive TFLite input** is Module 6's detector — not built here.

## Step 2 — Validation & anti-spam (`functions/lib/hazard_clustering.js`)
Reports are never read directly by routing. They cluster by hazard *type* + 10 m haversine radius
(great-circle, not a lat/lng box — at Dhaka's latitude a degree of longitude is ~9 km shorter than a
degree of latitude, which would skew a 10 m radius into an ellipse; tested).
- **Yellow Flag** (1 report) → $w_2$ = 4, below the threshold: warns, never reroutes.
- **Red Flag** (3 *distinct reporters* within 24 h) → $w_2$ = 9, above it: actively avoided.
- Counting distinct **reporters, not documents**, is the whole anti-spam rule — one person tapping
  submit four times stays Yellow (tested). `flagFor` is the single definition of "confirmed", shared
  by the incremental create-trigger and the hourly rebuild, with a test asserting the two can never
  disagree — if they did, a road could be closed by one path and reopened by the other.

## Step 3 — Data decay (`functions/lib/hazard_decay.js`, `decayHazardZones` hourly cron)
- Crime spikes: 48 h. Temporary blocks (construction, waterlogging): 7 days, **clock reset by
  re-flagging** ("unless re-flagged"). Structural blocks (stairs-only, no curb cut, no tactile paving,
  no sidewalk): **permanent**.
- Anything not explicitly structural is treated as temporary — the safe direction to be wrong in: a
  structural problem wrongly aged out is re-reported by the next person who hits it, whereas a cleared
  obstruction kept forever permanently detours every future user around a path that is fine.
- Permanent blocks only leave via `resolveHazardZone`, wired end to end: "it's fixed" / "ঠিক হয়ে গেছে"
  → matched locally (before the report matcher, so "the broken ramp is fixed" clears it rather than
  opening a form to report it again) → scoped to the hazards on the user's *active route* (resolving
  by proximity alone would let a passing remark clear a hazard someone else's route depends on) →
  `resolveHazardZone`. With no route active it says so rather than silently doing nothing.
- The hourly sweep **rebuilds from scratch** rather than patching, so any drift the incremental
  trigger introduces self-heals within the hour instead of persisting; expired reports are deleted so
  the collection doesn't grow without bound.

## Step 4 — Temporal crime weighting (`functions/lib/temporal_weighting.js`)
Rewritten to the module plan's own worked numbers. The previous version capped everything at 1.6x,
which **could not produce the behaviour the plan describes at all**: against a 1-10 base score and a
threshold of 7, no realistic commercial score could cross the line at night, so "avoid empty
commercial districts at midnight" never actually happened. Now:
- Commercial core / transit hub: **3.0x** after 8 PM (the plan's Motijheel example), 1.0x by day.
- New `notorious_hotspot` typology: elevated all day, 3.0x from dusk (6 PM), **5.0x** at night — the
  plan's "maxes out at 5x after dusk", and the only typology keyed to dusk rather than to 8 PM.
- Residential stays flat (1.2x); unknown typologies never spike (tested).
- Safe to make sharp because `RoutePlanningService` degrades to the lowest-risk candidate rather than
  failing when nothing clears the threshold — so this changes *which* route is chosen, never leaves a
  user with no route. A test asserts a mid-range commercial score crosses the threshold at night and
  not by day, i.e. that the mechanism actually changes a routing decision.

## Wiring
- `checkRouteSafety` now returns `blockingHazards`/`hazardWarnings` alongside the existing $w_1$
  fields, scored on the same 1-10 scale against the same threshold. Hazard-on-route uses a **25 m**
  radius, deliberately wider than the 10 m clustering radius: clustering asks "are these the same
  thing?" (wants to be tight), this asks "will the walker encounter it?" (has to absorb GPS error on
  both the reporter's phone and the route geometry). Erring toward a warning the user walks safely
  past beats the opposite error, which walks a blind user into an open manhole.
- Hazard-zone cache TTL is 60 s, not the crime zones' 10 min — a report about the road someone is
  walking down right now is worth little if it takes ten minutes to become visible.
- `SafetyVerdict` decodes both lists and **defaults to empty when they're absent**, so a client newer
  than the deployed function degrades to Module 4 behaviour instead of failing every route (tested).
- Bilingual warnings worded as *somebody's report*, not fact ("a user reported", "কেউ জানিয়েছে") — a
  Yellow Flag is exactly one unverified person's word, and telling a blind user something is
  definitely there when it might not be trains them to distrust every warning, including the confirmed
  ones. A confirmed hazard with no way around it gets its own, much stronger sentence that is never
  skipped or softened. Only one hazard is named even when several are on the route: a spoken list is
  not something a walking user can hold onto.
- Firestore rules: `hazardReports` is create-only under the caller's own uid (a client able to write
  someone else's `reporterUid` could manufacture a Red Flag alone) with no update/delete — a report is
  evidence. `hazardZones` is read-only to clients; client-writable would defeat the entire anti-spam
  layer in one step.

**Bug found and fixed while wiring**: adding `RouteSafetyService` to `FunctionCallExecutor` made the
whole class unconstructible without an initialized Firebase app, because the default reaches for
`FirebaseFunctions.instance` in the constructor — even for the many calls (every `update_setting`,
both `open_*` overlays) that never touch Firebase. All three dependencies are now `late final`.

## Not done / needs the user
- **Nothing in Module 5 has been deployed or device-tested.** `npx firebase-tools deploy --only
  functions,firestore:rules` from the repo root is the next step; `decayHazardZones` is a new
  scheduled function and `onHazardReportCreated` a new Firestore trigger, so both need a deploy before
  any of this is live. The `hazardZones` `where("flag", "in", [...])` query may need a composite index
  — Firestore will print the exact creation link on first run.
- No thana is tagged `notorious_hotspot` yet in `data/dhaka_thana_crime_seed.js`; the typology is
  implemented and tested but currently unused until real hotspots are identified and justified with a
  source, the same provenance rule the rest of that file already follows.
- Passive TFLite hazard pins (Step 1.3) belong to Module 6.
- `functions/`'s Node.js 20 runtime is still deprecated (decommissioned 2026-10-30).

---

# Previous OPEN BUGS list (all resolved above, kept for the repro details)

# OPEN BUGS — reported live by the user, 2026-09-03/04 device-testing round (start fresh session here)

User has been testing the debug APK on a real MIUI phone and reporting issues one after another. Below is every issue still standing as of this commit — some have code fixes already applied (not yet re-verified live on-device after the fix), some are completely unfixed. Ordered roughly by severity/urgency.

1. **[UNFIXED, NEWEST, HIGH SEVERITY] Main dashboard is a black screen after onboarding** — only the settings button (top-right) renders; nothing else shows. Reported just now, not yet investigated at all. Likely suspects to check first: `SplitModeDashboardScreen`'s recent `_mapFullScreen`/`Visibility(maintainState: true)` change (see `lib/features/dashboard/screens/split_mode_dashboard_screen.dart`), or the OSM/`flutter_map` dual-path rendering in `lib/features/dashboard/widgets/dashboard_map_panel.dart` throwing silently during build. Check `flutter logs`/logcat for an uncaught exception during the dashboard's first frame.

2. **[FIX APPLIED, NOT YET DEVICE-VERIFIED] `spokenTextToDigits` mis-multiplies digits after "double"/"triple"** — reported as "saying triple 3, 1 0 writes 333111000 instead of 33310". Root cause found: when a recognizer merges several spoken digits into one token (e.g. "310" instead of separate "3"/"1"/"0" tokens), the old code applied the `repeat` multiplier from a preceding "double"/"triple" to *every* digit in that merged token, not just the first one. Fixed in `lib/features/onboarding/widgets/spoken_digits.dart` — the multiplier now only ever applies to the first digit of a token, resetting to 1 for the rest of that same token. Applies to both "double" and "triple" (same code path). Needs a real device retest of a phone-number/pairing-code dictation with this exact "triple X, Y Z" shape.

3. **[UNFIXED] "Go back to dictation first" reversal not fully propagated** — user explicitly asked to restore full narration of all available options *before* the mic starts listening (a direct reversal of an earlier "brief intro, full options only on request" design). This was fixed at the shared-shell level (`OnboardingScaffold._speakThenListen` in `lib/features/onboarding/widgets/onboarding_scaffold.dart` now always speaks title+subtitle+full `spokenOptions` before listening). However, several screens bypass the shared shell with their own custom voice loop (`autoSpeak: false`) and were NOT checked/fixed for the same gap:
   - `lib/features/onboarding/screens/deaf_hearing_screen.dart` — **confirmed still missing it**: `_introAndListen()` only speaks `deafTitle`/`deafSubtitle`, never speaks the Yes/No option labels+descriptions before the mic opens (it only speaks them later, on an explicit "help" request mid-loop). Needs a fix mirroring the scaffold's pattern: speak title+subtitle+both option labels/descriptions, then listen.
   - `lib/features/onboarding/screens/cognitive_anxiety_screen.dart` — `_introAndListen`/`_askYesNo` only speak the bare question text for each of the two yes/no questions, never enumerate what a valid spoken answer sounds like up front (only on explicit "help" mid-question). Same gap as above.
   - Not yet checked at all (custom loops, likely same gap): `lib/features/onboarding/screens/magic_button_contacts_screen.dart`, `lib/features/onboarding/screens/safe_havens_screen.dart`, `lib/features/onboarding/screens/user_pairing_screen.dart`, `lib/features/onboarding/screens/passerby_messages_screen.dart`, and the verbosity/voice screen. Each needs a pass to confirm whether its own `_introAndListen` speaks its full set of options/keywords before listening, not just on request.

4. **[STATUS UNCERTAIN] Duplicate "Welcome to ANT" screen** — reported multiple times across earlier rounds. Three fix attempts made (removing `AnimatedSwitcher`, adding a `stepGeneration` cancellation counter, and — the most likely real fix — `_stopCurrentScreenVoice()` now called at the top of every navigating `OnboardingController` method in `lib/features/onboarding/providers/onboarding_providers.dart`, since the actual root cause traced to an async Firestore write completing *before* `_goTo` ran, leaving the old screen's mic/TTS alive through the whole round trip). Not confirmed fixed or still-broken on the most recent build — needs a fresh repro attempt with logcat capturing the `[Onboarding]`/`[OnboardingVoice]` debug prints already left in place in `onboarding_providers.dart` and `onboarding_voice.dart` if it recurs.

5. **[LIKELY FIXED, treat as unverified] OSM map / Google Maps confusion** — user reported seeing an empty Google Maps despite the app having switched to OpenStreetMap. `RoutingConfig.useOpenStreetMap` dual-path rendering was added to both `dashboard_map_panel.dart` and `overwatch_map_panel.dart`; a real crash bug in it ("unsupported operation, cannot modify unmodifiable map", from a `const` headers map passed to `NetworkTileProvider`) was found and fixed in both files. Not re-confirmed live since the fix — and directly relevant to bug #1 above (a silent map-panel exception would also explain a blank/black dashboard), so debug these together.

**Suggested order for the next session**: bug #1 first (it blocks using the app at all), then re-verify #5 while there (same code path), then #2's device retest, then work through #3's remaining screens one by one, then attempt to reproduce #4 with logging.
