# Open bugs

Carried over from the device session on 9 September 2026. Everything in the
"Reported" lines below was observed on the Redmi 10C, not inferred from code.

Items 1-5 were worked on 9 September 2026. **A device session on 10 September
found that item 1 is not fixed** — see item 6, which supersedes it — and
turned up thirteen further problems, items 6-19 below, and a second session
that night added items 20-22. Items 2-5 have still
not been confirmed on a phone.

Numbering is append-only. An item keeps its number even once it is fixed, so
a build report can name one without ambiguity.

---

## 1. "Hey ANT" and auto-listen do not work together — REGRESSION — PARTLY FIXED

> **Superseded in part by item 6.** The ordering defects below were real and
> are fixed, but the device session on 10 September found "Hey ANT" still dies
> after a single exchange. Read item 6 first.

**Reported:** with both toggles on, neither works properly. With one on at a
time, that one works — either the wake word fires, or voice option selection
works, but not both.

**Diagnosed.** It was not the `<queries>` manifest entries and not, in the
end, `CLOUD_STT_API_KEY` bringing a second `AudioRecorder` into play. Both of
those were plausible and both were wrong. The cause was two ordering defects
in `WakeWordService`'s suspension state machine, and the second recorder only
made them easier to hit:

1. **`start()` did not know suspensions existed.** It checked `isListening`
   and then opened the recorder. Nothing stopped it opening the microphone
   *inside* a suspension held by somebody else — and that window is wide,
   because `start()` awaits three TFLite model loads and a permission check
   before it gets to the recorder.
2. **The decision to restart was inferred, not recorded.** `_acquireSuspend`
   set `_resumeWhenReleased` only if the recorder happened to be live at that
   instant. If it was mid-`start()`, `isListening` was false, so the release
   concluded there was nothing to restore.

Both fire on the same routine sequence: "Hey ANT" → the listen session ends →
the release schedules a restart 500 ms later → the command the user just
spoke ("report a hazard") opens the hub, whose `initState` suspends *inside*
that window. The wake-word recorder then came up during the hub's suspension
and took the microphone, so the hub read its options and took no answer; and
when the hub closed, the release declined to bring the wake word back. Both
halves of "neither works", from one race.

**Fix:** an explicit `_enabled` flag is now the authority on whether the wake
word is wanted, separate from whether the recorder happens to be open.
`start()` refuses to open the microphone while `_suspendDepth > 0`, re-checks
after every `await` (including the recorder handshake itself, where it hands
the microphone straight back), and a `_starting` guard stops two concurrent
`start()` calls opening two streams. `stop()` now means "off"; suspension
uses a private `_stopRecorder()`.

**Also fixed alongside:** `SttService` no longer returns from a Cloud STT
session with `cloud.stop()` unawaited. The recorder teardown is awaited before
the wake-word suspension is released, so the handoff is deterministic rather
than relying on the 500 ms timer to outrun it.

**Covered by:** `test/wake_word_suspension_test.dart`, which drives the real
service against a fake `WakeWordAudioSource` whose handshake can be held open
on demand — the only way those orderings are reachable off-device. Five of
its tests fail against the old logic.

---

## 2. Wake word is deaf for ~2 seconds after every voice exchange — MOSTLY FIXED

**Measured, not reported.** The classifier needs 16 embedding windows (~1.3 s)
and each embedding needs 76 mel frames (~1.3 s), so a restart from empty is
~2.5 s of audio before it can score anything, plus the 500 ms handoff.

**Fix:** a restart caused by a suspension now *keeps* `_melFrames` and
`_embeddings`, so the model is warm the moment the recorder returns. Only the
partial raw chunk is dropped, since splicing it across the gap would put one
frame of nonsense at the seam. openWakeWord itself never clears between
utterances, so this is also closer to the reference implementation than
resetting was.

**Deliberately not fixed for one case: a restart that follows a detection.**
The suspension after a detection is taken within milliseconds of it, so the
retained buffer's newest 16 embeddings *are* the wake phrase that just fired.
On resume the window would be 15 of those plus one fresh embedding, score
essentially the same, and fire again — and the 2-second cooldown is no help,
because the suspension outlasts it by the length of the whole command. A
detection therefore marks the buffers poisoned and the next start is cold.

So: mic button, hazard hub, passerby picker, emergency flow — warm, no deaf
window. "Hey ANT" → command → "Hey ANT" again — still ~2 s. Closing that one
would need either a wake-word model that is cheap to prime, or zero-padding
the classifier input (which openWakeWord does, but which feeds an
out-of-distribution tensor to a model nobody here can test against a real
utterance — see the note below about not guessing on this pipeline).

**Do not** try to detect starvation via `peak=0.000` in the log. That was
tried on 9 September and disproved on device within minutes: three consecutive
0.000 windows were followed immediately by a clean detection at 0.783, and
later 0.997. An exact zero is simply what silence scores on this hardware. A
self-heal keyed off it would restart the recorder after any few seconds of
quiet and cause the starvation it was meant to repair. See `4b3067e`.

---

## 3. The navigation arrow is confusing; no route line, no distance — FIXED

**Reported:** "that stupid big arrow is confusing, i wanna see the route lines
as well like in google maps, as well as info about how far to go in which
direction."

The arrow is gone. In its place, `DashboardMapPanel` now shows a route banner
across the top carrying the manoeuvre icon, the distance to the next turn as
its own large number, the instruction ("Turn left onto Satmasjid Road"), and
the distance remaining. It updates on every GPS fix and falls back to the
destination and total distance before the first fix, so it is never blank
while a route is active. The route line is drawn with a dark casing under the
coloured core — a single stroke disappeared into pale roads at this zoom — and
the destination now has a pin.

The data was all there and nothing was reading it. Three pieces were added to
join it up:

- `NavigationNarrator.progressAt()` — a read-only view of the walk that never
  advances the state machine or latches an announcement band, so the map can
  render every frame without changing what gets said. Speech has to earn each
  utterance; a display does not, and conflating the two is why there was an
  arrow and no numbers.
- `NavigationController.progress`, a `ValueNotifier` the banner listens to.
- Distance remaining measured **along the route**, not as the crow flies. In
  Dhaka the difference is routinely a factor of two.

**Unlisted bug found and fixed here:** the Google Routes backend never
populated `RouteStep.streetName`, so every turn on the backend this app is
*migrating to* was spoken as a bare "turn left". Routes API has no
street-name field; the road only appears in the English `instructions` prose,
which the code deliberately ignored. `streetNameFromGoogleInstruction` now
mines just the name out of it (safe because `languageCode` is pinned to
`en-US`) and the sentence around it is still built in the user's own language.

**Also:** `navigateStarted` used `spokenDistance`, which is built for the next
manoeuvre and turned a whole journey into "1200 metres in total". It uses
`spokenRouteLength` now — "1.2 km".

---

## 4. Route replies give no context and no way to ask for another — FIXED

**Reported:** after "take me to Labaid", the assistant said only that the
safest route passes through a somewhat risky area. The user wants to know
*which* way it is taking them, and to be able to say "give me a different
route".

Every route reply now ends with "Via Satmasjid Road — 1.2 km, about 15
minutes." The road is the longest single named stretch, not the first one — a
route usually starts on whichever lane the user is standing in, which
identifies nothing.

`RoutePlanned` now carries the alternatives instead of dropping them.
Deliberately **not** safety-checked up front: that would cost two or three
extra Cloud Function round trips on every route request to answer a question
most users never ask. The check happens in `RoutePlanningService.promote()`,
when one is actually taken. Alternatives are ordered unchecked-first, then
already-known-unsafe by ascending risk, because offering a route the planner
has *just measured* as dangerous ahead of one it never looked at is the one
ordering that cannot be defended to somebody who cannot see where they are
being sent. Switching to an unsafe one says so.

"Give me a different route" / "another way" / "অন্য পথ" match locally (no
Gemini round trip) and Gemini has a `request_alternative_route` tool for the
compound phrasings. Naming a destination in the same breath — "another way to
Gulshan" — deliberately falls through to Gemini, which has both tools and the
conversation to tell a change from a fresh journey.

**Unlisted bug found and fixed here:** `navigateOffRoute` tells a user who has
drifted off the route to stop and say "re-route" / "নতুন পথ", and promises the
way will be found from where they are. **Nothing matched it.** The one command
offered at the moment somebody is lost did nothing at all. There is now a
`replan_route` intent and tool; it re-plans to the active route's own last
point rather than re-geocoding its label, which is exact, costs no network
call, and cannot resolve "the hospital" to a different hospital.

---

## 5. Map auto-open is not covered by a test — FIXED

`test/dashboard_route_panel_test.dart` owns the `RouteChoice` fixture and the
`chatControllerProvider` override that were the missing setup. It covers the
reveal, the fact that hiding the map again is not overruled by a rebuild, and
the banner's contents in all four states (pre-fix, walking, off route,
unsafe).

---

# Device session, 10 September 2026

Observed on the Redmi 10C running the release build of `e1f00f8` — the build
carrying every fix in items 1-5. Nothing here is inferred from code except
where it says so.

**Read this first: the release build emits no Dart logs.** Flutter strips
`print`/`debugPrint` from logcat in release mode, so every `[WakeWord] peak=`,
`[Stt]` and `[Chat]` line the diagnosis of items 1, 2 and 6 depends on is
simply absent. Debug the voice stack on a **profile** build
(`flutter build apk --profile` with the same `--dart-define`s) — AOT-compiled
like release, so the TFLite audio pipeline runs at real speed, but the logs
survive. A debug build is not a substitute: JIT changes the timing of a
pipeline that does three inferences every 80 ms.

---

## 6. "Hey ANT" answers once, then never again until relaunch — FIXED, CONFIRMED ON DEVICE

**Reported:** "hey jarvis works the first time, opens mic and takes input,
answers and right after it doesnt respond to hey jarvis anymore. works again
when i relaunch app cleanly."

**Caught on device, 10 September, with a profile build and a logcat stream.
The app's own text-to-speech was killing its own microphone.**

```
02:07:34.598  [WakeWord] listening started (cold)        <- restart works fine
02:07:39.761  AudioRecord [audioRecordData][fine] 5s     <- audio flowing
02:07:40.211  [WakeWord] peak=0.001                      <- first and only peak
02:07:42.277  requestAudioFocus() USAGE_MEDIA req=1
              clientId=...xyz.luan.audioplayers...       <- our TTS
02:07:42.296  onAudioFocusChange(-1)
              -> com.llfbandit.record.AudioSessionManager <- our recorder
02:07:42.377  AudioTrack sr 24000 start                  <- the spoken reply
              ...no AudioRecord data and no peak line, ever again
```

`req=1` is `AUDIOFOCUS_GAIN` — a **permanent** grab, which is audioplayers'
default. Android therefore dispatches `AUDIOFOCUS_LOSS` (-1) rather than a
transient loss, and `record`'s `AudioSessionManager` stops the recording on
all three loss codes alike, so ducking would not have saved it either. The
loss is permanent, so nothing ever restores the recorder — which is exactly
why only a relaunch brought the wake word back.

Every diagnosis before this one was wrong in the same way: the wake word was
never failing to *restart*. It restarted perfectly, every time, and was then
shot by the assistant answering out loud eight seconds later.

**Fix:** `audioInterruption: AudioInterruptionMode.none` on the wake word's
`RecordConfig`. That is the only mode where `record` skips registering a focus
listener at all, and it is right on its own terms — a wake-word detector's job
is to keep listening *through* other audio, including this app's own voice,
which is what `echoCancel` is already there for. Not applied to
`CloudSttService`: pausing a dictation session the user started, when
something else takes the speakers, is ordinary behaviour.

**Also fixed:** the TTS player now requests `gainTransientMayDuck` instead of
permanent gain. Every sentence the assistant spoke was telling Android to
permanently stop whatever else was playing — so a user listening to music lost
it for good the first time ANT said anything. That is a separate defect the
same log exposed.

**Confirmed on device, same night.** Three exchanges back to back, detections
at 0.630, 0.674 and 0.969, and the peak line ran unbroken straight through a
15-second spoken reply where it had previously stopped dead at it. Zero
`onAudioFocusChange(-1)` dispatched to the recorder across the whole session;
every TTS request now shows `req=3`.

---

### What was wrong with the earlier diagnoses

The ordering defects in item 1 were real, and the tests that pin them fail
against the old code — but they were not why the wake word died. Kept here
because both are still worth having fixed, and because the sequence of three
wrong answers is itself the lesson: this was diagnosed twice from code and
twice wrongly, and settled in four minutes once there was a log.

Two candidates were found by reading, one of them introduced on 9 September.
Both were fixed, and **neither was the cause**:

1. **An unbounded await in the Cloud STT teardown.** `SttService` was changed
   on 9 September from `unawaited(cloud.stop())` to awaiting it, so the
   microphone is provably free before the wake-word suspension is released.
   If the recorder's platform side ever wedges, that await never returns —
   and then `listenOnce` never returns, `pauseAround` never releases, and the
   wake word is dead until the process restarts, with the mic stuck on. That
   is exactly the reported symptom, and exactly the reported *shape* (only a
   relaunch clears it). Now bounded to 2 s with a log line.
2. **The reentrancy guard covering the whole session** — see item 7. Any
   session that fails to complete strands `_startingListen`, which wedges the
   button *and* the wake word together.

The decision table that settled it, kept because it will settle the next one
too. After an exchange, look for `[WakeWord] listening started`:

- **absent** → the restart path is not running.
- **present, but no `[WakeWord] peak=` lines follow** → the recorder came up
  and then stopped delivering. ← this is what happened.
- **present, `peak=` at real values, no `DETECTED`** → hearing and not
  matching; a threshold or buffer problem.

The `peak=` line is the load-bearing one and it fires every three seconds, so
it drowns a live stream. Filter it out of the stream and keep the full log in
a file to read afterwards.

---

## 24. "Hey Jarvis" sometimes does not respond — the threshold was too high

**Reported by testers as the wake word "working inconsistently after the first
try", and measured on 12 September.** This is *not* item 6 returning — the
audio-focus fix held for 8 detections out of 8 in the same session, every
restart on time.

Across 56 scored windows of one real session:

| Score | What it was | Windows |
| --- | --- | --- |
| 0.000-0.003 | silence and background | 47 |
| 0.016-0.144 | speech that is not the phrase | 4 |
| **0.300-0.342** | **the phrase, not detected** | **3** |
| 0.667-0.972 | the phrase, detected | 8 |

The three in the middle are the complaint. They are known to be real attempts
rather than noise because **each is followed by a successful detection within
3-16 seconds** — which is what somebody saying it, getting nothing, and saying
it again looks like in a log.

**Fix:** the threshold drops from openWakeWord's default 0.5 to **0.30**,
which clears the background floor by a factor of a hundred and the loudest
non-attempt speech by two. The asymmetry justifies the rest: a false positive
opens a microphone that closes itself seconds later, while a false negative
means the only hands-free way into the app did not work for somebody who
cannot reach the button.

It is now tunable per build, because the right number belongs to *this
placeholder model and the voices it has been measured against*, not to the
pipeline:

```
flutter build apk --dart-define=WAKE_WORD_THRESHOLD_PCT=40
```

**The real fix is a real model.** `hey_jarvis_v0.1` is trained on synthetic
English clips, and is neither the app's own wake phrase nor anything tuned for
Bangladeshi speakers. A threshold is a patch on that.

**Needs watching on device:** false positives. Nothing in this session's data
predicts any — background never exceeded 0.003 — but the sample is one voice,
one room, one session. If the microphone starts opening on its own, raise the
number before anything else.

(`test/wake_word_threshold_test.dart`, which pins the threshold against the
measured distribution rather than against a guess.)

---

## 25. Assistant replies take 1.5-29 seconds, unpredictably

**Measured in the same session.** Three Gemini round trips: **1486 ms**,
**19883 ms**, **20204 ms**, **28867 ms** — same device, same session, same
model (`gemini-3.5-flash-lite`). A locally-matched command in the same session
took **17 ms**.

A 20x spread with no change in conditions is variance, not configuration, so
it is very likely the network rather than anything this app controls.

**Why it matters more than it looks:** nothing is spoken until the whole
response lands. To a user who cannot see the typing indicator, a slow turn is
indistinguishable from a command that was never heard — so they say the wake
word again and report *that* as unreliable. A good part of "the wake word
works inconsistently" is probably this.

**Partly fixed:** the assistant now says "Still working on that…" after three
seconds of silence, and the log records time-to-first-chunk separately from
the total, so a slow *start* (the model thinking) can be told apart from a
slow *stream* (a long answer). Only the first is worth taking to Google.

**Still open:** the latency itself. Worth checking whether it correlates with
mobile data versus wifi before assuming it is Google's end.

---

# Tester round, 12 September 2026

Two testers, in Bangla and English. Numbered from 26 so they can be referenced
individually. **Ordered by severity, not by who reported them.**

## 26. Onboarding loses everything if the app is killed — FIXED

**Both testers, independently.** "app data clean hoye jacche" and, against the
kill-and-reopen step: "নষ্ট হয়ে যায় সব ডাটা আগের গুলো" — all the previous data
is destroyed.

Pack A step 19 says it should resume where it left off. It starts again from
nothing. For a user who has just spent twenty minutes answering an interview
by voice, being sent back to the start is the point at which they stop using
the app.

This is the highest-priority item in the file. Everything else is a feature
not working; this one throws away work the user already did.

**Two faults, one complaint — and the second is the literal one.**

1. **Nothing recorded which step the user had reached.** Every answer was
   already written to Firestore after every step (`ProfileService.saveProfile`
   says in its own doc comment that this is why it upserts), but
   `OnboardingState.step` lived only in memory, so `AppRoot` sent every
   unfinished profile back to `OnboardingFlowScreen`, which started at
   language selection and asked all of it again.

2. **`chooseRole` then overwrote the saved answers with defaults.**
   `ensureSignedIn` returns the *existing* anonymous user on a relaunch, so the
   uid is the same one that already owns a half-finished profile — and
   `chooseRole` built a brand-new `UserProfile` and saved it with
   `SetOptions(merge: true)`. Every default in a blank profile landed on top of
   the real answers. Vision level, mobility aid, contacts, safe havens: back to
   defaults, in Firestore. The tester's "সব ডাটা নষ্ট হয়ে যায়" was not a figure
   of speech about being re-asked; the data really was destroyed, by the app's
   own second screen.

**Fix.** `UserProfile.onboardingStep` records how far the user got, written as
its own single-field merge by `_goTo`/`goBack` (fire-and-forget — navigation is
synchronous and must stay that way, and the field touches nothing `_persist`
writes, so the two cannot clobber each other). `OnboardingController.resumeFrom`
adopts a saved profile and puts the user back on that step;
`OnboardingFlowScreen` takes the profile from `AppRoot` and calls it once.
`chooseRole` now merges into whatever is already saved instead of replacing it,
and a *failed* read is surfaced rather than treated as "no profile" — falling
back to a blank one there is how the destructive version behaved, so a
transient Firestore error would have wiped a finished interview.

A profile written before the field existed reads back `null`, which resumes at
role selection — all that can honestly be inferred is that they got past it,
and it is safe to re-ask now that it no longer destroys anything.

**Covered by:** `test/onboarding_resume_test.dart`, 13 tests. Four of them fail
against the old `chooseRole`.

## 27. Hazard reports are not saved, and no alert reaches the caretaker — SAVING FIXED

**Tester D, twice** — under General and again at Part 4 step 27: "hazard report
kothao save hocche na probably. Caretaker er kacheo kono alert jacche na."

Module 5 end to end. The report is composed, the flow completes, and nothing
lands. Needs checking in this order: whether the Firestore write is attempted
at all, whether it is rejected by rules, and whether the caretaker query is
looking in the right place.

**Checked in that order. The write was never attempted.**

Two unbounded waits sat in front of it, and either one produces the same thing
from the outside — the button spins and nothing else ever happens:

1. **`Geolocator.getCurrentPosition()` with no bound.** It waits indefinitely
   for a fix that may never arrive: indoors, location services off, a
   permission dialog nobody answered. The `catch` around it only ever covered a
   *thrown* error, so a hang stalled the submit with `_submitting` left true and
   the write never reached. `EmergencyService._position` already knew to bound
   this; the hub did not.

   **`LocationSettings.timeLimit` is not enough on its own**, which is worth
   recording because it looks like it should be: it is enforced by the platform
   plugin, so it only helps while the platform is answering. If the channel
   itself never replies, nothing in Dart is watching the clock. Demonstrated by
   the new test — against the version with only the plugin-side limit, the
   submit never completes even after thirty seconds of pumped time. There is
   now a Dart-side `.timeout` as well, one bound around both the fresh fix and
   the last-known fallback (chaining one each makes the worst case their sum,
   and the user has already said "submit" and is waiting in silence).

   **The same defect was in `EmergencyService._position`** and is fixed with it.
   That path holds up an emergency rather than a hazard report.

2. **Firestore acknowledges a write when the *server* has it.** With offline
   persistence on — the default — the document is applied to the local cache
   immediately and synced later, but the returned future stays pending the whole
   time. A report filed on a bad connection was therefore genuinely saved and
   the user told nothing, forever. That wait is now bounded too, and a timeout
   there is deliberately **not** reported as a failure: the report is filed
   either way, only the confirmation is late, so it says so
   (`crowdsourceSubmitQueued`). A rules rejection still surfaces as the error it
   is.

**Rules were checked and are fine.** `hazardReports` allows create when
`request.auth.uid == request.resource.data.reporterUid`, and the hub is handed
`profile.uid`, which is that uid.

**On the caretaker half:** no alert reaches the caretaker because nothing sends
one — `05_module_plan_crowdsourcing.md` does not specify a caretaker alert for
hazard reports, and no code writes one. That is a missing feature rather than a
broken one, and it should be a decision before it is a patch. The caretaker
channel itself is item 28, which is the thing to fix first regardless.

**Covered by:** `test/hazard_report_submit_test.dart`, 3 tests. All three fail
against the unbounded version.

## 28. Caretaker communication does not work at all — DIAGNOSED, UNBUILT

**Tester D:** "caretaker er snapshot request user er kache ashtese na. Not only
that, communication er kono part e kaaj korche na."

Module 8, whole. Snapshot requests do not arrive; no part of the
communication hub functions. Note Pack D's caretaker section was the only
coverage Module 8 had, and it has now been exercised for the first time.

**Diagnosed, not fixed — because there is nothing here to fix.** The receiving
half of Module 8 does not exist.

`CommunicationService` is correct and complete: it writes memos, voice memos
and snapshot requests to `communications/{disabledUserUid}/messages`, and the
Firestore rules for that path allow both parties. Pairing is fine too —
`PairingService.redeemCode` sets `pairedUserId` on *both* profiles in one
transaction, and both writes satisfy the `users/{uid}` rules. All of that was
checked before concluding anything.

The gap is that **`communicationsStreamProvider` and
`communicationServiceProvider` are referenced only from inside
`lib/features/guardian/`** — the caretaker's own UI. Nothing on the Disabled
User's device ever subscribes to that collection. The caretaker's messages are
written, and the caretaker can see them in their own hub, which is why this
reads as "the caretaker's side sort of works and nothing arrives". Nothing
arrives because nothing is listening.

Snapshot requests additionally have nothing that could answer them: there is no
`camera` dependency in `pubspec.yaml` at all, so Module 6 (Snapshot Vision) is
unbuilt. Even a perfect listener could only announce that a snapshot was asked
for.

So this is a feature build across two unbuilt modules, not a bug fix, and it
was deliberately left rather than half-started. What it needs, in order:

1. A listener on the Disabled User's dashboard for
   `communications/{myUid}/messages`, filtered to `toUid == myUid`.
2. Incoming memos announced aloud, and voice memos played — this alone turns
   "no part of it works" into a working one-way channel, and needs no camera.
3. Snapshot requests gated on `UserProfile.snapshotConsent`, which onboarding
   already collects and nothing yet reads.
4. Module 6, for the capture itself.

## 29. "Cancel" is not recognised in a Bangla session — FIXED

**Tester D, Part 3 step 14:** "Cancel bolar poreo cancel hocche na. Tobe বাতিল,
দাঁড়াও catch koreche banglay."

The recognizer runs in one locale for the whole session, so a user in Bangla
who says the English word "cancel" never gets Latin text back — it arrives as
`ক্যান্সেল`, which was missing from the dictation cancel vocabulary.
`emergencyCancelWords` already had it; this list never got the same treatment.

Fixed by adding the phonetic Bangla spellings, the same way
`PasserbyHelperOverlay` already carries "গো ব্যাক".
(`test/voice_cancel_window_test.dart`)

## 30. Onboarding repeats the previous screen's instructions — FIXED — supersedes item 8's second half

**Tester D, with a repro at last:** "2nd page e 1st page er instructions repeat
hocche" and, specifically: "Report a hazard er por crime jodi manually select
kora hoy, tarpor toh 2nd page ashe. Ei page eo 1st page er instructions repeat
hocche."

So it is **the hazard hub**, not onboarding, and the trigger is **selecting a
category by tap** rather than by voice. Item 8's overlap fix addressed speech
still in flight over the network; this is a different thing — the step
narration being issued twice.

`CrowdsourceReportingHub._narrateAndListenForStep` is called from
`_goToCategory`, and `_stepGeneration` is meant to retire the previous step's
narration. Worth checking whether a tap fires it while the previous
`_speak` is still awaiting.

**Confirmed, and that is exactly it.** `_narrateAndListenForStep` bumped
`_stepGeneration` and stopped the *recognizer* — it never stopped the
*narrator*. `TtsService` queues utterances rather than dropping them, on
purpose, because each one is a question or an option list the user needs in
full. So the interrupted category prompt kept its place at the head of the
queue, played all the way to the end, and the sub-category prompt came out
behind it.

`_stepGeneration` could never have helped: it gates what the step logic does
next, not what the narrator has already accepted.

Why only by tap, as reported: answering by *voice* means the prompt had
finished — the hub narrates, then listens — so there is nothing left playing
when the step changes. A tap can land in the middle of it.

**Fix:** `_narrateAndListenForStep` now stops TTS when the step changes.
Deliberately not on the *first* narration: the hub is usually opened by a voice
command whose own reply ("Opening the hazard report") is still being spoken,
and queueing behind that is right — the same reason
`PasserbyMessagePicker._autoListenLoop` awaits rather than interrupts.

**Covered by:** `test/hazard_hub_step_narration_test.dart`, the hub's first
widget coverage. Its fake TTS models the real queue (chained utterances, a
generation that `stop()` bumps) so the test measures what reaches the speaker,
not what was requested — a fake that only recorded `speak` calls would show
nothing wrong, because the hub always asked for the right text.

## 31. The wake word does not work with the screen off — NARROWED

**Both testers.** Tester D Part 1 step 8: "Screen off thakle kaaj korche na."
Tester A: "Screen off doesn't work. Eyes closed works."

`WakeWordForegroundService` holds a partial wake lock precisely so the CPU
keeps running with the screen off, so either it is not being started, the lock
is not held, or Android is suspending the microphone anyway. The second tester
adds that there is **no vibration** either, which suggests the whole detection
path is asleep rather than just the audio.

This matters more than it sounds: a phone in a pocket has its screen off, and
that is the primary way this app is meant to be used.

**Checked what could be checked off-device; not fixed, because the fix is a
decision that needs a device to confirm.**

Ruled out: the manifest is correct — `FOREGROUND_SERVICE_MICROPHONE` is
declared and the service carries `android:foregroundServiceType="microphone"`,
which is what Android 10+ requires for a backgrounded app to keep the mic. The
wake lock is acquired properly, and `POST_NOTIFICATIONS` is requested at
runtime.

**The strongest remaining suspect is *when* the service is started.** Android
12 (API 31) forbids starting a foreground service from the background, and
`ChatStreamPanel.didChangeAppLifecycleState` starts it on
`AppLifecycleState.paused` — the moment the screen locks, which is the exact
boundary that restriction polices. If the start is refused, the process is
frozen with the recorder inside it, and the whole detection path is asleep,
which is what the second tester's "no vibration either" describes.

It was impossible to tell, because the failure was silent:
`BackgroundListeningService.start()` caught the exception into a `debugPrint`
that said only "start failed". **That much is fixed now** —
`MainActivity`'s handler names the exception class and returns it as a method
channel error, and the Dart side logs it loudly. One device session with logcat
now distinguishes this cause from the others in a single line.

Deliberately *not* changed: moving the start earlier (to `inactive`, or to
whenever wake word is enabled) would satisfy the API 31 rule but puts an
ongoing "listening in the background" notification in front of a user who has
not backgrounded anything — which `didChangeAppLifecycleState`'s own comment
records as a previous regression, with the service flapping on every
notification-shade pull. That is a trade to make deliberately, once the log
says it is actually the cause.

The other candidates, if the log clears the above: Doze deferring the partial
wake lock, and MIUI's battery manager killing the process regardless (the test
device is a Redmi, and the manifest comments already note MIUI kills invisible
foreground services first).

## 32. The microphone does not recover after airplane mode — FIXED

**Tester A, Part 5 step 21:** "মাইক অন হচ্ছে না। অফ থাকে" — the mic does not turn
on, it stays off.

Related but distinct: step 20 reports "শুরুতেই মাইক অফ দেখাইলো" — it showed the
mic as off at the very start. Both point at the mic indicator and the actual
recorder state disagreeing.

**They are the same bug, and the second line is the clue.** The audio stream
subscription in `WakeWordService.start` was created with neither `onError` nor
`onDone`:

```dart
_audioSub = stream.listen((bytes) => _onAudioBytes(bytes, onDetected));
```

So a recorder stream that ended *by itself* — the radio cycling through
airplane mode, a phone call taking the microphone, another app grabbing it, the
session simply dying — was silent in both directions. Nothing reopened it, and
nothing knew.

Worse than silent, because `isListening` is `_audioSub != null`, and a
subscription whose stream has finished stays non-null. The service went on
reporting that it was listening while the microphone was dead. That is exactly
"the mic indicator and the actual recorder state disagreeing", and it is why
the two halves of this item are one item.

**Fix:** `onError`/`onDone` land in `_onRecorderStreamEnded`, which clears the
subscription so `isListening` tells the truth, and reopens the recorder on a
backoff (2s doubling to a 60s ceiling, reset as soon as audio flows again).
Airplane mode is not one event — the stack can drop repeatedly on the way back
up — so it keeps trying rather than giving up after one attempt. It restarts
*warm*, since the feature buffers are still good and someone saying "Hey ANT"
as the mic returns should not wait out a cold classifier too.

Cancelling a subscription does not fire `onDone`, so a deliberate
`_stopRecorder` never looks like a death. An explicit `stop()` cancels any
queued reopen, and a suspension is left alone — `_releaseSuspend` owns that
restart, and reopening underneath it is precisely the ownership bug item 1 was
about.

**The fixture had to be fixed first, and that is worth recording.**
`_FakeAudioSource.startStream` returned `const Stream.empty()`, which is *done*
the moment it is listened to — not a recorder that is running, but one that
died on arrival. That distinction did not matter while nothing watched for the
stream ending. It now returns an open, silent `StreamController`, which is what
a real recorder is.

**Covered by:** `test/wake_word_suspension_test.dart`, 5 new tests. Three fail
against the unhandled version.

## 33. Missing synonyms in onboarding answers — FIXED (this one)

**Tester A, Part 2.** "আমার চোখে কান সমস্যা নেই" was accepted. "আমি একাই হাঁটি" (I
walk alone) was **not** — for the mobility question.

The phrasebook is meant to be the list of what works; this is a gap in it.
Testers answering in their own words is exactly what Pack A is for, so more of
these are expected and each one is a cheap fix.

**Measured before changing anything.** `আমি একাই হাঁটি` does score against the
unassisted label, at 0.5, with both other options at 0 — so the phrase as
written is accepted by the current build. But it only scores at all by
*accident*: on the single word `হাঁটি` it happens to share with the label
"আমি সাহায্য ছাড়াই হাঁটি". Nothing in the vocabulary knew the word for *alone*,
so the whole answer rested on that one verb, and every ordinary variation of it
scored zero against all three options:

| Heard | Before | After |
| --- | --- | --- |
| `আমি একাই হাঁটি` | unassisted 0.5 | unassisted 1.0 |
| `আমি একাই হাটি` (no chandrabindu) | **no match** | unassisted 1.0 |
| `একা হাটি` | **no match** | unassisted 1.0 |
| `আমি একা চলি` | **no match** | unassisted 1.0 |
| `একাই চলি` | **no match** | unassisted 1.0 |
| `আমি একা` | **no match** | unassisted 1.0 |

**Fix:** synonyms for the *concept* rather than the phrasing — `একা`, `একাই`,
`একা চলি`, `একাই চলি`, `নিজে চলি`, `নিজেই`, and `alone` / `walk alone` /
`by myself` in English. An answer should not depend on which verb the user
reaches for.

The risk of a one-word synonym is that it outranks a better answer, so that is
tested directly: `আমি ছড়ি নিয়ে হাঁটি` ("I walk with a cane") still resolves to
white cane, not unassisted.

**Covered by:** `test/onboarding_voice_matching_test.dart`, four new tests.

## 34. Narration cannot be interrupted

**Tester A, Part 2:** "সম্পূর্ণ বলা শেষ হলেই তখন সে শুনতে পারে" — it can only hear
you once it has finished speaking.

This is currently **by design** — narrate with the mic shut, then listen (see
item 9, where overlapping the two broke the recorder outright). But a user who
already knows the answer has to sit through the whole option list, and that is
a real cost on every screen.

Worth deciding rather than patching: barge-in needs the recorder open during
narration, which is what caused item 9. A wake-word-style "I'm ready" detector
running during narration would be a way to have both, at the cost of another
model.

## 35. Caretaker gaps

**Tester D, Part 6.**

- step 37: the caretaker end cannot change language. Known — the caretaker
  screens are English-only, which round 1's notes already flagged as a known
  issue, but it is worth closing now that it is being reported.
- step 38: not implemented.
- step 39: **no way to unpair a caretaker.** A pairing that cannot be undone
  is a privacy problem, not only a missing feature — the caretaker sees live
  location.

**Scoped, not built — it needs a Firestore rules change, and that is a security
decision rather than a tidy-up.**

The blocker is specific. **No rule in `firestore.rules` permits clearing the
*other* party's `pairedUserId`**, so a caretaker cannot complete an unpair from
their own device. All three `users/{uid}` update rules were checked:

| Rule | What it allows | Can it clear the other side? |
| --- | --- | --- |
| `auth.uid == uid`, role unchanged | your own profile | only your **own** `pairedUserId` |
| `auth.uid != uid`, `resource.pairedUserId == null`, sets it to `auth.uid` | the pairing handshake | no — it only ever *stamps on*, and only onto an unpaired profile |
| `auth.uid != uid`, `resource.pairedUserId == auth.uid`, remote settings | the caretaker editing their user's settings | no — it explicitly requires `pairedUserId` **unchanged** |

**A one-sided unpair is not enough, and it is worth knowing exactly how far it
gets**, because it is tempting to ship. Clearing only the caretaker's own
`pairedUserId` *does* revoke the live-tracking surface, because those rules all
test the **caretaker's own** profile:

- `liveLocations/{uid}` read — revoked
- `alerts/{uid}/items` read — revoked
- `communications/{uid}/messages` read and create — revoked

But two paths test the **Disabled User's** profile instead, which still points
at the caretaker, so both survive:

- `users/{disabledUserUid}` **read** — the caretaker can still read the whole
  profile
- `users/{disabledUserUid}` **update** (the remote-management rule) — the
  caretaker can still change their settings remotely

So a half unpair leaves someone who has been told they are unpaired still able
to read the profile and change the settings of a person who has removed them.
That is worse than not shipping it.

**What it wants** is a fourth rule, symmetric with the handshake one — either
party may clear a pairing that points at them, and only that field:

```
allow update: if request.auth != null && request.auth.uid != uid &&
  resource.data.pairedUserId == request.auth.uid &&
  request.resource.data.diff(resource.data).affectedKeys().hasOnly(['pairedUserId']) &&
  request.resource.data.pairedUserId == null;
```

Then `PairingService.unpair` clears both sides in one transaction, mirroring
`redeemCode`, and the UI is one section in `RemoteManagementScreen`, which
already has the `_SectionCard`/`ListTile` scaffolding for it.

Left unbuilt deliberately: this repo has no `fake_cloud_firestore` and no rules
test harness, so neither the rule nor the transaction can be verified here, and
an unverified security-rules change on the path that governs who can see a
blind user's live location is not something to ship on inference. The language
half is independent and much smaller — the caretaker's own `language` is
already on their profile and simply has no control bound to it.

## 36. What the testers confirmed working

Worth recording, because "nobody tested it" and "tested and fine" look
identical otherwise.

- Tester D, Part 5: the passer-by helper works fully.
- Tester A, Part 3: spoken phone-number read-back is correct, including
  Bengali numerals and digit-by-digit grouping rather than one huge number.
- Tester A, Part 2: saying nothing re-prompts and re-reads the options.

---

## 7. The red mic button could not be turned off — FIXED

**Reported:** "clicking on the red mic button after its been activated doesnt
deactivate it."

It never could. One method served both the mic button and wake-word
detection, and its reentrancy guard — there to stop a second detection
cancelling the session the first one started — was held for the whole of
`listenOnce` rather than just the start. Every tap on the red mic hit
`if (_startingListen) return`, and the `if (_listening)` branch beneath it was
unreachable dead code.

For a user who cannot see that the microphone is open, a mic that will not
close is worse than a button that does nothing visible.

The two callers want opposite things from a session already running, so they
are two methods now: a tap stops it, a wake word leaves it alone.
(`test/chat_mic_button_test.dart`, two of whose three cases fail against the
old guard.)

---

## 8. Onboarding narration repeats and overlaps into the caretaker code step — FIXED

**Reported:** "the hey ant dialogue repeats and overlaps into the caretaker
code section."

Two separate faults in one sentence, and they need separating before either
is fixed: a step narrating itself more than once, and a step's narration
still playing while the next screen is up. The second is the dangerous one —
overlapping speech is unusable for a blind user, and the caretaker pairing
code is six digits that have to be heard exactly once, clearly.

**Diagnosed by reading, one layer below where it looked.** `OnboardingScaffold`
already stops TTS on dispose, and `TtsService` already has a generation guard
that abandons anything still queued behind a `stop()`. Both were working.

The hole was in `CloudTtsService`. Speaking is an HTTP round trip to Google's
synthesis API *and then* a playback — and `TtsService.stop()` reaches the
cloud service as `stop()`, which stops a **player**. Between the request going
out and the audio coming back there is no player to stop, so a `stop()`
landing inside that window did nothing whatsoever: the response arrived
afterwards and played over whatever screen had replaced the one that asked
for it. Role selection is the step before caretaker pairing, and its narration
is the longest in the flow (title, subtitle and every option), so it is the
most likely to still be in flight when the user answers.

**Fix:** `CloudTtsService` carries its own generation, bumped by `stop()` and
re-checked after the fetch returns. A cancelled utterance is dropped and
reported as success — not failure, which would send `TtsService` to the
on-device engine to say the very thing that was just cancelled.

(`test/tts_serialization_test.dart`)

**Also fixed here: the caretaker's pairing code was never spoken.** The screen
rendered six digits at 44pt and said nothing at all — no narration, and no
`dispose` stopping the previous screen's voice. A caretaker who is blind, or
simply not looking at the phone, had no way to read the code out to the person
beside them. It now speaks the digits, spaced so the engine reads them one at
a time rather than as a single number, once per code rather than on every
rebuild while it waits.

**Not reproduced: the "repeats" half.** The overlap is fixed and explains an
utterance arriving twice as easily as it explains one arriving late. If
repetition survives this build, it needs a device log — the guard to look at
next is `OnboardingScaffold._speakThenListen`'s `stepGeneration` check.

---

## 9. Show Screen opened the microphone before saying what it is for — FIXED, CONFIRMED ON DEVICE

**Reported:** "show screen option should first narrate what user can/should do
here before opening mic." And, separately: "after i say my message it asks me
to say show it, i say show it, and it loops on, telling me it got it and i
should say show it, basically keeping on looping."

Those turned out to be the same bug seen from two ends, and it is worse than
a missing announcement. `_autoListenLoop` skipped narration entirely on its
first pass and opened the recorder immediately — while the chat's own
"Showing your screen now." was still playing. Caught on device:

```
02:19:13.467  [CloudStt] continuous listening started
02:19:13.545  audioplayers requestAudioFocus req=3
02:19:13.564  onAudioFocusChange(-3) -> record
02:19:15.513  onAudioFocusChange(1)  -> record
```

`record` treats a duck request (-3) as a full focus loss, and its default
`AudioInterruptionMode.pause` is documented as "pauses automatically, resumes
**manually**" — nothing resumed it. So the session that had just opened was
already dead and the message spoken into it never arrived. `_committed` stayed
empty, "show it" therefore submitted nothing, and the loop replayed the
identical prompt forever. The user was talking into a stopped recorder and
being told to repeat a command that could never work.

**Three fixes:**

1. **Narrate first, listen second.** The loop now speaks an intro before its
   first listen — what the screen does and what to say into it — and
   `TtsService` serializes utterances, so awaiting it also waits out whatever
   the chat is still saying. This is the order `CrowdsourceReportingHub`
   already used.
2. **`audioInterruption: AudioInterruptionMode.pauseResume`** on
   `CloudSttService`, so a dictation session recovers from *any* interruption
   — a phone call, an alarm, another app — not just this one. Deliberately not
   `none` like the wake word: pausing a session the user started while
   something else has the speakers is right, it just has to come back.
3. **The dead end has an exit.** "Show it" with nothing dictated now says what
   is missing rather than replaying the standing prompt, and does not stack
   both instructions into one turn.

(`test/passerby_picker_voice_test.dart`)

**Confirmed on device 10 September.** The ordering inverted as intended, and
no focus loss was dispatched to the recorder anywhere in the run:

```
02:40:28.514  local match: open_passerby_helper
02:40:29.631  TTS req=3          <- "Showing your screen now." (chat)
02:40:32.592  TTS req=3          <- the picker intro
02:40:40.814  [CloudStt] continuous listening started   <- after both
```

The whole flow then worked: a message dictated and committed, read back, a
second listen, "show it", confirm window, shown. No loop.

**Left open, deliberately: it now talks for 8.2 seconds before the user can
say anything.** The chat's `passerbyOverlayShownAnnouncement` and the picker's
own intro play back to back and overlap in meaning. Both are correct; one of
them should be trimmed. Not done here because which one to cut is a wording
decision, not a defect.

**The general rule this establishes,** worth applying wherever a flow
narrates and then listens: the microphone must be closed for the whole of the
narration and opened only after it finishes. Any overlap ducks our own
recorder, and `record` cannot tell our voice from an interruption.

---

## 20. Show Screen closed itself the moment it opened — NOT A BUG

**Reported:** "after the voice commands in show screen it doesn't actually
open the screen but it does when its clicked", then, watching it happen: "it
closed in 1 sec without me doing anything while its narration kept on playing
on the dashboard."

Not a voice bug at all — the overlay *was* opening every time. The device log
shows a two-finger, 15 ms touch delivered to the activity in the same frame
the overlay pushed:

```
ACTION_DOWN             pointerCount=1
ACTION_POINTER_DOWN(1)  pointerCount=2
  ...15ms...
ACTION_POINTER_UP(0) / ACTION_UP
```

**Withdrawn: that touch was the user's own.** Confirmed directly — "the show
screen is actually fine, it WAS my touch". The tap-grace window written for
this has been reverted, because it delayed a deliberate dismiss by 900 ms to
guard against something that was never happening. A blind user tapping to
close a screen should not have to tap twice.

What was investigated and is worth keeping on record: the overlay's entire
body is a tap-to-dismiss target with no grace period, so a touch closed it — before `initState`'s
`await speak(...)` had even returned, which is why not one `[PasserbyOverlay]`
line appears in the log despite the overlay having been built and spoken
from. Tapping "Show This" worked because by then the touch stream had already
been consumed by the button.

A full-screen surface whose whole body dismisses will always be exposed to
whatever touch stream was in progress when it arrived — a rotation
re-dispatch (this one forces landscape on entry), a lingering finger, an
accessibility gesture. **Fix:** a 900 ms grace window on tap-anywhere. The
explicit back button is deliberately not gated: a press on a specific control
is an intention, a touch anywhere on a yellow rectangle is not.

(`test/passerby_overlay_dismiss_test.dart`)

---

## 23. The app transcribes its own narration — FIXED

**Measured on device, twice, reproducibly.** The Show Screen picker's intro
ends "Say what you need, then say 'show it'", and the recognizer came back
with **"What you need?"** — which was then committed as the user's message
and would have been shown to a passerby.

Not a buffer still draining: in the Show Screen overlay the same thing
happened with the microphone opening a full second *after* playback stopped.
Cloud STT reports interim results about two seconds late, so audio captured
right at the boundary surfaces well after the narration is visibly over.

`SttService.narrationSettle` (600 ms) is now waited out after any narration
before a microphone opens, in the picker, the overlay and the hazard hub —
the hub had a 200 ms version of this guard all along, which is where the idea
came from and which was evidently too short.

---

## 21. Narration outlived the screen that started it — FIXED

**Reported as a rule, not a bug:** "narration of a certain screen or function
or option should stop the moment that window is closed."

None of the three voice surfaces stopped text-to-speech on dispose. They all
stopped the *recognizer* and left the *voice* running, so the Show Screen
announcement — six seconds long, on an overlay that could be gone in one —
carried on explaining a screen that was no longer in front of the user.

`PasserbyHelperOverlay`, `CrowdsourceReportingHub` and `PasserbyMessagePicker`
now stop the TTS in `dispose()`.

One deliberate exception, in the picker: when it pops in order to *show* the
message, the overlay it is handing to has already begun its own announcement
and Flutter runs the picker's `dispose` after that push. Stopping
unconditionally there clips the first words off the screen the user actually
asked for, so the picker tracks the hand-off and stays quiet only when it is
being abandoned.

**The general rule, now applied in three places and worth applying in the
rest:** a screen owns its voice. Opening it starts the narration, closing it
ends the narration, and the microphone stays shut for the whole of it (see
item 9).

---

## 22. Gemini answers a half-heard command with an invented status — FIXED

**Observed 10 September, not yet fixed.** A bare "Screen." — the recognizer's
truncation of "show screen" — came back as *"Your screen is currently active
and ready."* with `overlay=null`. Nothing opened, and the reply describes a
state the app does not have and cannot report.

A confident non-answer is worse for a blind user than an admission: it sounds
like the command worked.

**Fix:** a prompt rule, first in the list — never describe the state of
anything the assistant cannot actually read (a screen, the camera, the
microphone, a connection), and treat a half-heard command as a request to
clarify rather than a cue to invent a status.

Related, same session: "I would like to go to my friend's place" resolved to
the junk saved place `"frequent place"` — see item 12, whose first half is now
fixed.

---

## 10. Auto-listen should follow from blindness, not from a separate toggle — FIXED

**Reported:** "mic auto open should be default if blind, and should be a
question in onboarding if otherwise." And separately: "auto listen is a weird
option, cos if hey jarvis is on, it should also be on by default right? maybe
not?"

Today `voiceAutoListen` defaults to `visionLevel != full || complexInstructionsHard`
and is then editable as its own switch in settings, next to the wake-word
switch, with no explanation of how the two relate. The reporter could not tell
what it meant — which is a strong signal that a user with no vision, arriving
at it through a screen reader, cannot either.

**Decided by the reporter:** on by default for blind users, an onboarding
question for everyone else.

`autoListenDefaultFor` is now simply `visionLevel == none`. A blind user
cannot find a mic button on a screen they cannot see, so a microphone that
does not open itself is a microphone they do not have — that one does not
need asking. Everyone else reaches a new `OnboardingStep.autoListenQuestion`,
which a blind user skips entirely: a question with one sensible answer is
worse than no question.

What made it "weird" was that nobody ever chose it. It was inferred from
vision level *and* "finds complex instructions hard", so it turned up in
settings beside the wake word, already on, with nothing saying what it was or
how the two related. It stays editable in settings; it is just no longer set
behind the user's back.

Note it is deliberately **not** tied to the wake word. They answer different
questions — "can you reach the button" versus "do you want the phrase" — and
a user who turns the wake word on has said nothing about whether the mic
should open itself when the assistant asks them something.

(`test/auto_listen_rule_test.dart`)

---

## 11. No list of saved places in settings — FIXED

**Reported:** "(there should be a proper places list in settings)."

`UserProfile.savedPlaces` is only reachable by voice — "take me to X",
"forget X". There is no way to see what is saved, which means no way to notice
that "hospital" was saved as the wrong hospital until you are walked to it.
See items 12 and 13, which are how wrong entries get in there.

---

## 12. The assistant cannot actually add a place — FIXED

**Reported, two separate failures.**

First: "i say add a new place, it asks where and what to call it, i only say
hospital, expecting to be asked about address of it, it then gives me list of
places with hospital keyword in it." The follow-up turn is being read as a
*destination* rather than as an answer to the question just asked, so it goes
to the geocoder instead of filling the empty slot.

Second, worse: "i just asked 'add a new place i go to frequently' it replied
'Saved where you are now as frequent place'." It took the phrasing of the
request as the place's *name* and the current GPS fix as its location — so a
sentence that named neither produced a saved place that is wrong in both
fields. Then: "upon me explaining im not talking about current location, it
asks me to tell the name of the place id like to add, i say it, and it goes
back to routing me straight to that place on the map."

So the conversation can be entered but not completed, and it silently
degrades into `request_route`.

**Fixed: the invented name.** `save_place` now refuses a label that is the
request restated — "a new place I go to frequently", "frequent place", "this
place" — and asks what to call it instead, mentioning the address for the case
where the user is not standing there. A place saved under a name nobody chose,
at a location nobody confirmed, is worse than no saved place at all: it is
found by being walked somewhere wrong, and in the meantime it matches
unrelated destinations.

**Fixed: the multi-turn fill.** `PendingPlaceSave` is the same shape
`DestinationClarification` already gave `request_route` — the executor returns
it when a save is missing a slot, `ChatState` holds it, and `ChatController`
reads the *next* message as the answer before the destination matcher ever
sees it. Answering "the clinic" now completes the save instead of routing
there.

Kept separate from `DestinationClarification` rather than generalised: the two
ask different kinds of question. A *name* is whatever the user wants to call
it and cannot be wrong; an address can be. Sharing one type would have meant
one of them inheriting the other's retry budget and wording.

It has the same escape hatches: an unmistakable command (a route request, an
emergency, an overlay) abandons the save rather than swallowing it, "never
mind" cancels it — through the same vocabulary the destination conversation
uses, now shared so the two cannot drift — and it gives up after three
questions with a sentence saying what does work.

(`test/place_save_conversation_test.dart`)

---

## 13. Saving needs an address path, not just "where you are now"

Implied by item 12 and worth stating on its own: `save_place` supports the
current location and a spoken address, but nothing asks for the address when
the current location is plainly not what was meant. `savedPlaceNeedsLocation`
is the only prompt that mentions an address, and it only fires when there is
no GPS fix at all.

---

## 14. The map does not follow the user — FIXED

**Reported:** "google maps when showing location should automatically zoom in
on me reorient on my direction, just like google maps does in drive mode."

The panel took a single `getCurrentPosition` fix and never moved again: the
camera was fitted to the route once and then sat there while the user walked
off the edge of it.

**Fix:** a position stream while a route is active. The whole-route fit still
happens first — the user should see where they are being taken before the
camera closes in — then it follows at zoom 18.5, oriented to travel direction.
Heading is only trusted above 0.6 m/s, because a stationary phone reports a
heading that wanders and a map that slowly spins while somebody stands still
is worse than one that never turns.

Touching the map releases the follow, because a camera that keeps yanking
itself back is unusable for the sighted companion this view exists for; a
recentre button appears to hand control back. The stream is torn down when the
route is retired, so it costs nothing when nobody is walking.

**Not covered by a test.** It needs a real `Geolocator` stream and a Google
Maps platform view, neither of which a widget test has. Verified by reading;
wants a look on the device.

---

## 15. The map's share of the screen should be draggable — FIXED

**Reported:** "the space the map takes up should be adjustable or draggable."

Fixed at 60/40 (`_chatFlex`) with a full-screen toggle and nothing in between.

---

## 16. Nothing is dictated as the route starts

**Reported:** "when routing me somewhere, it should start dictating which
direction i should go next and for how far."

This is the one item here that the code says should already work, which makes
it the most important to reproduce with logs. `NavigationController.start`
speaks `navigateStartedBrief`, then `NavigationNarrator` announces each
manoeuvre at 200 m, 50 m and 25 m. Candidates: the route had no `steps`
(`navigateNoStepsFallback` would have been spoken — did it?), the GPS stream
never delivered a fix accurate enough to act on, or nothing is being spoken at
all because of item 8's suspected TTS problem.

Determine which before changing anything: all three look identical from
outside and only one is a navigation bug.

---

## 17. The chat input does not grow with the text — FIXED

**Reported:** "keyboard text box should expand like that of any messaging apps
when filled up."

Single-line `TextField` in `ChatStreamPanel`. Wants `maxLines: null` with a
cap, the way every messaging app does it.

---

## 18. The map toggle is in the wrong corner — FIXED

**Reported:** "maps icon should be near the keyboard not on the top corner."

It is an `AppBar` action, which is the furthest point on the screen from the
thumb that is already on the input bar.

---

## 19. Release builds cannot be debugged

Not a user-facing bug, but it cost this session its evidence. See the note
under the 10 September heading: build **profile** for any voice-stack
investigation.

---

## Unlisted bugs found while fixing the above

Each is fixed, with the test that pins it.

- **Turn-by-turn guidance never reached a Deaf user.**
  `NavigationController.spokenCues` has existed since Module 4 with a doc
  comment saying the chat transcript would show them, and **nothing ever
  subscribed**. For a Deaf or hard-of-hearing user that is not a degraded
  experience: the app planned the route, announced it to an empty room, and
  said nothing they could perceive for the rest of the walk. `ChatController`
  now mirrors every cue into the chat as text, without re-speaking it.
  (`test/navigation_transcript_test.dart`)
- **A finished walk stayed "the active route" forever.**
  `ChatController.clearRoute` existed and was never called from anywhere, so
  the map kept drawing a line already walked and `resolve_hazard` stayed
  scoped to a journey that ended hours ago. Arrival now retires it.
- **The emergency escape route never reached the map.** It went straight to
  the navigation controller, which is enough to *speak* it and nothing else —
  so through an entire emergency the person most likely to be looking at the
  screen, a bystander or a caretaker holding the phone, could not see where
  the user was being sent.
- **`flutter analyze` and `flutter test` see different `WakeWordService`s.**
  The conditional export resolves to the stub for the analyzer and to the
  native class for the VM test host, so the two can drift silently and
  analysis will not catch native-only usage. The stub now carries the same
  surface, with a comment saying why.
- **`_recorder.dispose()` threw unguarded** in both `WakeWordService` and
  `CloudSttService`, from Riverpod's container teardown — where an unhandled
  async throw surfaces as an unrelated test failing.
- A duplicated `if (turn.clarification != null)` block in `ChatController`
  (harmless, applied the same state twice) and an unused `cloud_stt_config`
  import in `SttService`.

---

## Still needs a device

Nothing below has been confirmed on a phone. Ordered by what breaks worst if
it is wrong. Items marked **regression risk** touch code that was working.

### Voice stack

1. **Wake word survives a whole exchange** (items 1, 6). Both toggles on: say
   "Hey ANT", give a command, let it answer, say "Hey ANT" again. Watch for a
   *double* fire off one utterance — that is what the poisoned-buffer rule in
   item 2 guards against, and a regression there looks like eagerness rather
   than failure.
2. **The red mic button closes the mic** (item 7). Tap it mid-session. It has
   never worked, so any behaviour at all is new.
3. **Onboarding narration does not bleed into the next screen** (item 8).
   Answer role selection *fast*, before its narration finishes — that is the
   window the fix closes. The caretaker code should also now be spoken aloud,
   digit by digit.
4. **The "repeats" half of item 8 is unreproduced.** If narration still
   repeats, it needs a log; the guard to look at is
   `OnboardingScaffold._speakThenListen`'s `stepGeneration` check.
5. **The app no longer transcribes itself** (item 23). Open Show Screen and
   say nothing. The old build committed "What you need?" — the tail of its own
   prompt — as the message.
6. **Show Screen end to end** (item 9). Dictate, say "show it", let the cancel
   window run out. Then try "show it" with nothing dictated: it should say
   what is missing rather than looping.
7. **Narration stops when a screen closes** (item 21). Close Show Screen or
   the hazard hub mid-sentence; the voice should stop with it.

### Navigation and the map

8. **Turn-by-turn actually speaks** (item 16, **not fixed, needs diagnosis**).
   Three causes look identical from outside — the route came back with no
   `steps`, no GPS fix was accurate enough to act on, or nothing is being
   spoken at all. Reproduce with a log before anyone changes code:
   `navigateNoStepsFallback` being spoken points at the first.
9. **The map follows and reorients** (item 14, **regression risk**, and the
   only change here with no test at all — it needs a real `Geolocator` stream
   and a Maps platform view). Walk a route: the camera should fit the whole
   route first, then close in and turn with you. Panning should release it and
   show a recentre button. Watch for the map spinning while you stand still —
   that means the heading gate is too low.
10. **Route replies say which way** (item 4). "Take me to Labaid" should end
    with "via <road> — 1.2 km, about 15 minutes". On the Google backend, check
    turns actually name roads (item 3) — that path has never been run.
11. **"Give me a different route" and "re-route"** (item 4). The second is the
    one `navigateOffRoute` has always told users to say while nothing
    implemented it.
12. **Turn-by-turn appears in the chat** (item 21 write-up). The only channel
    a Deaf user has for it.
13. **Arrival retires the route.** The map should stop drawing a walked line.

### Onboarding and settings

14. **Auto-listen** (item 10, **regression risk** — it changes what a fresh
    profile gets). A blind user should never see the question and should have
    it on; everyone else should be asked once, after the hearing question.
15. **Saving a place is a conversation** (item 12). "Add a new place" → it
    should ask what to call it → answer with a name → it saves, rather than
    routing you there. Also check the junk `"frequent place"` entry can be
    deleted from settings (item 11).
16. **The chat input grows, the map toggle sits by the mic, the split drags**
    (items 17, 18, 15). With the map full-screen the toggle is offstage by
    design — the collapse button is the way back.

### Known-unverifiable here

17. **Anything on the Google routing backend.** `test/google_routes_backend_test.dart`
    opens by saying the path has never been run; every claim about its wire
    format is an assertion from documentation.
18. **Release builds emit no Dart logs** (item 19). Use a profile build for
    any voice-stack investigation.

## Fixed earlier, still awaiting tester confirmation

In the distributed build and not yet exercised by a tester:

- submit phrases ("show it", "submit") being sent as message text
- listen sessions dying 64 ms in, from timers outliving their own session
- Bangla voice labels shown to English users, in onboarding and in settings
- an unclear read-back looping forever without ever saying "yes or no"
- `voiceAutoListen` not re-derived when the vision answer changes
- the command tour losing its closing instruction to a 30 s playback timeout

---

## 37. The fullscreen button covers the map's current-location button — FIXED

**Reported:** "the map full screen button covers the current location button."

**Not two of this app's buttons.** Those sit in opposite corners — the
fullscreen toggle top-right, the recentre button bottom-right — which is why
this looked wrong at first reading. The button underneath is **Google's**,
drawn inside the platform view where nothing in `dashboard_map_panel.dart` can
see it.

`GoogleMap` is configured with `myLocationButtonEnabled`, `zoomControlsEnabled`,
`compassEnabled` and `mapToolbarEnabled` all on — deliberately, and the comment
there explains why. On Android those land at: my-location **top-right**, zoom
**bottom-right**, compass **top-left**, toolbar **bottom-right**. This app then
stacks its own chrome in the same corners. That is three collisions, not one;
the reported one is simply the one people hit first, because my-location is the
control a sighted companion reaches for most.

**Fix:** `GoogleMap.padding`, which is the supported way to move the native
controls. Vertical only — pushing them sideways would walk the zoom buttons
into the middle of the map and the compass under the route banner, whereas
dropping them below this app's top row and lifting them above its bottom one
puts each in free space. The Google logo, bottom-left, is left alone:
obscuring it breaks the Maps terms.

Symmetric top and bottom on purpose. `padding` also moves the camera's idea of
centre, so an asymmetric inset would quietly put the user off-centre on every
recentre — a worse bug than the one being fixed.

**Covered by:** `test/map_control_overlap_test.dart`. The padding and the
`Positioned` values are now derived from the same constants, so the tests fail
if a button changes size or position without the padding being revisited.

## 38. Speaking slowly turns the microphone off — FIXED

**Reported, Part 1:** "sometimes usually fast works but being too slow turns
the mic off", answering the interview in Bangla with long pauses mid-sentence.
The test plan itself calls that "how real people under stress talk" — and for
this app's users it is how many of them talk all the time.

**Both recognizer paths end a session on a mid-sentence pause**, and the
distinction matters because the obvious fix does not work:

- Cloud STT runs with `singleUtterance: false`, so it finalizes a **segment**
  once the speaker stops. `SttService` treats the first `isFinal: true` as the
  whole utterance and closes the session.
- The on-device recognizer hits its own `pauseFor`.

**Raising `pauseFor` cannot fix the cloud half** — the server finalizes the
fragment before that timer is ever reached. So `আমি ... একাই হাঁটি` said with a
beat in the middle arrived as `আমি`, matched nothing, and the screen apologised
over the top of somebody who was still answering. From the user's side, the mic
turned off while they were talking.

**Fix:** `listenForVoiceChoice` now treats a fragment that was *heard but
matched nothing* as an unfinished sentence rather than a failed answer. It
listens on without speaking, stitches the next fragment onto the last, and
matches against the join as well as the new piece alone. Up to two
continuations; past that the user is not pausing, they are saying something the
screen does not understand, and they need telling.

Silence is handled the opposite way on purpose: nothing heard at all is not
somebody mid-sentence, so the retry hint comes immediately — which is the
behaviour testers confirmed already works.

`SttService.listenOnce` gained an `initialSilence` override for this. The
default eight-second wait is right for someone gathering their thoughts before
answering; after they have already spoken it is just silence they sit in before
being told anything, so a continuation window asks for three.

**Covered by:** `test/slow_speech_onboarding_test.dart`, 6 tests, including
that a fast complete answer still takes exactly one listen and is not slowed
down by any of this.

## 39. The contact name read-back cannot be checked by ear — FIXED

**Reported, Part 3 step 13:** "Dictate a name that is not a common English word
(a relative's real name). Check what the read-back says." — *Misspellings.*

The phone number in that same read-back is spoken one digit at a time, for a
reason the string's own comment gives: a dictated number is easy for STT to get
subtly wrong, and this is an emergency contact. Testers confirmed that half
works (steps 11 and 12).

**The name had no equivalent, and it needed one more than the number did.** The
name was only ever *pronounced* — and "Rahima", "Rohima" and "Raheema" are the
same sound. The misspelling was not merely present, it was **undetectable**: a
user who cannot see the screen was being asked to confirm something they had no
way to check.

**Fix:** the name is said and then spelled. The pronunciation to recognise it
by, the letters to verify it by.

Spelled by **grapheme cluster**, not code unit, which is the whole difficulty
in Bangla. `'রাহিমা'.split('')` gives `র া হ ি ম া` — bare vowel signs, which
mean nothing said aloud and are not how anyone spells a name. The grapheme
clusters are `রা হি মা`: the syllables, which is exactly how a Bangla speaker
spells one out. Conjuncts hold together for the same reason — `আব্দুল্লাহ` is
`আ ব্দু ল্লা হ`.

**Covered by:** `test/spoken_name_test.dart`, 8 tests, including that two names
which sound alike now spell differently.

## 40. "Hey Jarvis" has to be said softly, gently, with a pause — DIAL SHIPPED

**Several testers:** the wake phrase only works said quietly and slowly, with
enough of a gap between the two words.

That is two complaints wearing one coat, and only one of them is a threshold.

**Where the line sits** was a compile-time constant
(`--dart-define=WAKE_WORD_THRESHOLD_PCT`, item 24), so every guess at it cost a
new APK and another round of testing. It is now a dial in My Settings,
persisted on the profile as `UserProfile.wakeWordThreshold` and applied live —
detection reads the threshold at comparison time, so a change takes effect on
the next scored window with no restart.

Stored per *user*, not per device: it is a property of somebody's voice and the
rooms they use the app in, and a tester who finds their setting should not lose
it to a reinstall. Null means never tuned, and the build default stands.

**The dial ships with a live score meter, and that is the half that matters.**
The measured gap between a real attempt that failed (0.30-0.34) and one that
succeeded (0.67+) is invisible from outside `WakeWordService`, so a slider on
its own would only have moved the guessing into the app. With the score on
screen, tuning becomes: say the phrase, read the number, put the marker under
it, say it again. `WakeWordService.lastScore` is a `ValueNotifier` the tile
listens to; the meter holds a peak for three seconds, because the classifier
scores every 80 ms and the phrase spans only a handful of windows.

The dial cannot travel to either extreme. At 0 every window fires and the
microphone never closes; at 1 nothing can fire and the wake word is silently
off while claiming to be on. The floor (0.05) still sits more than ten times
above the loudest measured background window (0.003), so no setting on it can
be triggered by a quiet room.

**What the dial does not fix, and should not be expected to.** "A pause between
the two words" is not a threshold at all — it is `hey_jarvis_v0.1`'s fit to
real voices. It is a placeholder model trained on synthetic English clips, it
is not this app's wake phrase, and it is not tuned for Bangladeshi speakers.
The point of shipping the score alongside the slider is that testers can now
**measure** that instead of describing it: if attempts score 0.6+ said gently
and 0.1 said normally, the model is the problem and no threshold rescues it.
That is the number to collect before building a real "Hey ANT" model.

**Covered by:** `test/wake_word_sensitivity_test.dart`, 15 tests — including
that the slider runs the opposite way to the threshold (dragging right must
make it *easier* to trigger), that it saves on drag end rather than per frame,
and that the tile fits a 360dp phone in both languages. That last one caught a
real overflow that would have painted a striped bar across the meter.
