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
