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
- [x] Verified live against real Firebase: code generation, redemption, and bidirectional `pairedUserId` linking all confirmed in Firestore console

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
