# Current State (as of Module 2, Round 6)

**Built and working:** Full onboarding for both roles (Disabled User + Caretaker), bilingual English/Bangla throughout with a first-screen language picker, voice-guided onboarding (on by default, for a blind user with no caretaker), Light/Dark theme independent of the Low Vision high-contrast accommodation, Split-Mode Dashboard (chat + suggested chips + clean map with directional arrow, fully bilingual), Guardian Hub (Overwatch map, Alert Center, Communication Hub with real voice memos, Remote Management — not yet bilingual, see below), self-service Settings for the Disabled User (a deliberate, flagged exception to "no settings menus" — see Round 4), Crowdsource Reporting Hub with AI-summarized free-text reports, Passerby Helper overlay, Snapshot consent preference, and real Google Maps rendering.

**Known gaps / next up:**
- Guardian Hub / Remote Management screens are still English-only (Disabled User-facing screens are fully bilingual; caretaker-facing ones aren't yet).
- Module 3 (Gemini function calling) doesn't exist yet — chat replies, voice input, and hazard-report dictation are all stubbed with clear "arrives with the AI Assistant module" messaging. My Settings exists specifically as the bridge until then.
- `onUserRoleWritten` Cloud Function is written but undeployed (Spark plan, no billing) — role/onboardingComplete checks read the Firestore profile directly instead of a verified Auth custom claim.
- The Google Maps key in use is a personal/experimentation key (user-provided), not tied to the `ant-assistive-nav` GCP project — fine for dev, should be replaced and access-restricted before any real release.
- A couple of throwaway test profiles/reports are still in the live Firestore project (safety classifier blocked automated cleanup — see Round 4).

**Setup notes:** Firebase project `ant-assistive-nav` (Firestore + anonymous Auth, Spark plan). `firebase.json`/`.firebaserc` live at the repo root (not inside `ant_app/`) so `firebase deploy --only firestore:rules` has a target. Web preview served via `.claude/launch.json`'s `ant_app-web` config (static `flutter build web` output, not a live dev server — rebuild before previewing changes).

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
