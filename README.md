# ANT — Context-Aware Assistive Navigational Tool

A voice-first navigation app for severely disabled people — primarily blind
and low-vision users — walking in Dhaka, Bangladesh. Fully bilingual
(বাংলা / English), and designed so that **every function can be reached
without seeing the screen**.

The premise the whole app is built around: a sighted user dictating a phone
number glances at the field, sees a dropped digit, and fixes it. That glance
is the entire error-correction mechanism in most software, and our users do
not have it. So values are read back before they are saved, dangerous
actions have a spoken escape route, and a wrong action is always treated as
more expensive than a missed one.

---

## What's in the repository

| Path | What it is |
| --- | --- |
| `ant_app/` | The Flutter app (Android-first; the phone is the product) |
| `functions/` | Firebase Cloud Functions — routing safety, crime scoring, hazard aggregation |
| `cloudflare-worker/` | Scheduled collectors that pull current crime signals from news and social feeds |
| `firestore.rules` | Security rules — read these before changing any data model |
| `0N_module_plan_*.md` | Per-module specifications |
| `project_master_plan.md` | Overall architecture and intent |
| `task.md` | Live bug and task list |

### Module status

| # | Module | State |
| --- | --- | --- |
| 1 | Onboarding — accessibility interview, voice-driven | Built |
| 2 | Core UI — dual-role dashboards, localization | Built |
| 3 | AI Assistant — Gemini function calling, local intent matching | Built |
| 4 | Crime & route safety — thana scoring, temporal weighting, advisories | Built + deployed |
| 5 | Crowdsourcing — hazard reports, clustering, Red Flag anti-spam | Built + deployed |
| 6 | Snapshot Vision | Not started |
| 7 | Haptics | Partial — navigation cues built |
| 8 | Virtual Guardian | Not started |
| 9 | Magic Button | Contacts collected; no trigger, SMS or dial yet |

---

## Two ways to get it on a phone

Which one you need depends on whether you are going to change code.

| | **Testing it** | **Developing it** |
| --- | --- | --- |
| How | Firebase App Distribution | Clone this repo and build |
| You need | An Android phone | A computer with the full toolchain |
| Setup | About two minutes | About an hour, first time |
| Updates | Arrive on their own | You rebuild each time |
| API keys | Already in the build | You supply your own |

If you are testing, use App Distribution — everything below the next section
is for people who are going to edit code, and none of it is worth doing to
run the app once.

---

## Installing as a tester (App Distribution)

**What you need:** an Android phone (8.0+), the email address you were
invited on, and a network connection. **No computer, no cable, no Android
SDK, no developer mode** — and on Xiaomi devices, no "Install via USB",
because this is a normal install rather than an `adb` one.

1. Open the invite email on the phone and tap the link.
2. Sign in with the Google account the invite was sent to.
3. Install **Firebase App Tester** when prompted, and allow it to install
   unknown apps when Android asks. This is once, not per build.
4. Open App Tester, pick ANT, tap **Download**.

New builds then arrive as a notification. Tap, download, done.

### Sending a build out

```bash
cd ant_app && flutter build apk --debug
firebase appdistribution:distribute build/app/outputs/flutter-apk/app-debug.apk \
  --app YOUR_ANDROID_APP_ID \
  --groups internal \
  --release-notes "what changed, and what you want tested"
```

`YOUR_ANDROID_APP_ID` is the Android App ID from Firebase **Project settings**
(shaped like `1:123456789:android:abc123`). Manage who gets builds under
**Release & Monitor → App Distribution → Testers & Groups**.

Write real release notes. They are the only instruction most testers read,
and they are where you say *what to test*, not just what changed.

> **Keys ship inside the APK.** `--dart-define` values are compiled in and
> can be extracted from the file by anyone who has it. A distributed build
> hands out whatever keys it was built with, so distribute only to people
> you would give those keys to directly, and use restricted or
> separately-budgeted keys for test builds.

---

## Running it from source

For working on the app. Everything is Android; iOS has never been built or
tested.

### 1. Prerequisites

- **Flutter 3.47+** on the stable channel (`flutter --version`)
- **Android SDK** with `platform-tools` (this gives you `adb`)
- **Node 20** for `functions/`, **Node 22** if you also want to work on the
  Cloudflare Worker with wrangler v4
- An Android phone on **Android 8.0 or newer**

Check the toolchain before anything else:

```bash
flutter doctor
```

### 2. Get the app's dependencies

```bash
cd ant_app && flutter pub get
```

### 3. Put your phone in developer mode

On the phone: **Settings → About phone → tap "Build number" seven times**,
then **Settings → System → Developer options → USB debugging** on.

**On Xiaomi / Redmi / POCO (MIUI or HyperOS), you must also turn on
"Install via USB"** in the same Developer options screen. Without it every
install fails with `INSTALL_FAILED_USER_RESTRICTED`, which reads like a
permissions bug but is MIUI refusing USB installs. MIUI usually also
requires you to be signed into a Mi account with a SIM inserted, and the
**screen unlocked** while the install runs — a phone that locks mid-install
will fail with the same error.

Plug the phone in and accept the "Allow USB debugging?" prompt. Then
confirm the computer can see it:

```bash
adb devices -l
```

You want a line ending in `device`. `unauthorized` means you haven't
accepted the prompt on the phone yet.

### 4. Install and run

```bash
cd ant_app && flutter run
```

That builds, installs, and attaches with hot reload. To build and install
separately — useful when you want the APK itself:

```bash
cd ant_app && flutter build apk --debug && flutter install
```

> `flutter install` does **not** rebuild. If you changed code, run
> `flutter build apk --debug` first or you will push a stale APK and spend a
> while wondering why your change isn't there.

### 5. Grant the permissions the app asks for

On first launch it requests **microphone** and **location**. Both are
load-bearing — voice control and navigation are the app — so denying either
leaves it largely non-functional. Location must be **"While using the app"**
at minimum.

### 6. Skip onboarding while developing

Onboarding is a full accessibility interview with voice narration at every
step, which is a real obstacle when the thing you're testing is the
dashboard. In **debug builds only** there is a **⏩ button in the top-right**
of the first onboarding screen: it writes a complete dummy profile (Dhaka
saved places, two contacts, wake word off) and drops you straight on the
dashboard. It is `kDebugMode`-guarded at both ends and cannot appear in a
release build.

---

## API keys

Keys are compile-time constants read from `--dart-define`, so nothing
secret is committed. The app degrades rather than crashes when one is
absent — check `isConfigured` on each config class in
`ant_app/lib/core/config/`.

```bash
flutter run \
  --dart-define=GEMINI_API_KEY=your_key \
  --dart-define=CLOUD_STT_API_KEY=your_key \
  --dart-define=CLOUD_TTS_API_KEY=your_key
```

| Key | Without it |
| --- | --- |
| `GEMINI_API_KEY` | Local commands still work; anything needing reasoning does not |
| `CLOUD_STT_API_KEY` | Falls back to on-device recognition (no Bangla on most handsets) |
| `CLOUD_TTS_API_KEY` | Falls back to the system TTS voice |

Maps and routing need no key: routing uses **OpenStreetMap** (Nominatim for
geocoding, OSRM for directions) via `RoutingConfig.useOpenStreetMap`.

---

## Backend

### Cloud Functions

```bash
cd functions && npm install
npm test
firebase deploy --only functions,firestore:rules
```

> Read the deploy output rather than trusting the exit code. Piping
> `firebase deploy` through anything (`| tail`, `| grep`) makes the shell
> report the **pipe's** status, so a partial failure — some functions
> updated, some not — exits 0 and looks like success.

### Cloudflare Worker

Collectors that pull current crime signals and file them through the
functions above. Runs on Cron Triggers; needs no request traffic.

```bash
cd cloudflare-worker && npm install
npm test
npx wrangler deploy
```

---

## Tests

```bash
cd ant_app && flutter test          # widget, unit and localization tests
cd ant_app && flutter analyze       # must stay clean
cd functions && npm test            # hazard clustering, advisories, decay
cd cloudflare-worker && npm test    # feed parsing, thana matching
```

The Flutter suite is where most of the behaviour that matters is pinned.
Several tests are named after the symptom a real user reported on a real
device rather than after the function they cover — `device_reported_fixes_test.dart`
is entirely that. When you fix something found on a phone, add the test
there and name it after what the person saw.

---

## Working on this

A few things that are easy to get wrong here and expensive to get wrong:

- **Bangla is not English with different words.** The verb goes last, so a
  pattern anchored on a trailing verb captures the subject pronoun along
  with the place name. Case endings attach directly to nouns
  (গুলশান → গুলশানে). Dart's `\b` is ASCII-only and never matches after a
  Bangla character, so it silently does nothing in the language that needs
  it most. `voice_matching.dart` exists for this.
- **A wrong action costs more than a missed one.** Starting to walk
  somebody across Dhaka because they wondered aloud about a place, or
  filing a hazard that closes a road because someone asked a question, are
  failures a blind user cannot see or easily undo. Questions and negations
  are deliberately recognised and ignored.
- **Test on a real budget phone.** The blank-map bug was Impeller silently
  dropping raster tiles on an Adreno 610 — invisible in every emulator and
  on any recent flagship, and a Redmi is the typical handset for the people
  this is being built for.

---

## Licence

Not yet licensed. All rights reserved by the project team.
