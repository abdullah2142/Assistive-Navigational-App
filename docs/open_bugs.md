# Open bugs

Carried over from the device session on 9 September 2026. Everything here was
observed on the Redmi 10C, not inferred from code.

---

## 1. "Hey ANT" and auto-listen do not work together — REGRESSION

**Reported:** with both toggles on, neither works properly. With one on at a
time, that one works — either the wake word fires, or voice option selection
works, but not both.

**Crucially, this used to work.** The user reports that before the first APK
went to testers, both ran in unison, "Hey Jarvis" fired every time, and option
selection was picked up reliably. So this is a regression introduced somewhere
between the 6 September build and the first tester release, not a
long-standing gap.

**Not diagnosed.** Candidates, all of which landed in that window:

- the `<queries>` entries added to `AndroidManifest.xml` for
  `RecognitionService` / `TTS_SERVICE`
- restoring `CLOUD_STT_API_KEY` to the build, which switched voice input from
  the on-device recognizer back to Cloud STT — a *second* `AudioRecorder`
  competing with the wake word's own, where before there was only one
- the Module 9 emergency work, which added another microphone consumer

The second is the most suspicious: with the key missing, STT ran on Android's
`SpeechRecognizer` and the wake word had the `AudioRecorder` to itself.
Restoring the key put two recorder instances in play. That matches "it worked
before the first tester APK" exactly, because the missing key is what that
APK fixed.

**Next step:** bisect rather than guess. Build with `CLOUD_STT_API_KEY`
deliberately omitted and check whether the pairing works again. That isolates
the recorder-contention hypothesis in one build.

**Note:** a separate bug made this look worse than it is — `voiceAutoListen`
carried a stale persisted `false` that answering the vision question never
overrode (fixed in `49b7863`). Anyone testing "both on" before that fix may
have had auto-listen genuinely off.

---

## 2. Wake word is deaf for ~2 seconds after every voice exchange

**Measured, not reported.** After each listen session the wake word restarts,
and `start()` clears `_pendingBytes`, `_melFrames` and `_embeddings`. The
model needs 16 embedding windows — about 1.3 s of audio — before it can score
anything, and `pauseAround` waits a further 500 ms before restarting at all.

So for roughly two seconds after any command completes, "Hey ANT" cannot be
detected. Say it too soon and it is silently missed, which reads as the wake
word being flaky rather than warming up.

**Fix direction:** keep a rolling audio buffer across a suspend/resume instead
of clearing it, so the model is warm the moment the recorder returns. Touches
the detection path, so it wants doing carefully.

**Do not** try to detect this via `peak=0.000` in the log. That was tried on
9 September and disproved on device within minutes: three consecutive 0.000
windows were followed immediately by a clean detection at 0.783, and later
0.997. An exact zero is simply what silence scores on this hardware. A
self-heal keyed off it would restart the recorder after any few seconds of
quiet and cause the starvation it was meant to repair. See `4b3067e`.

---

## 3. The navigation arrow is confusing; no route line, no distance

**Reported:** "that stupid big arrow is confusing, i wanna see the route lines
as well like in google maps, as well as info about how far to go in which
direction."

The map already receives the route polyline and draws it
(`DashboardMapPanel`'s `polylines`), and `RouteCandidate` carries
`distanceMeters`, `durationSeconds`, `initialBearingDegrees` and the full
`steps` list. So the data is all present; what is missing is the presentation:
the giant directional arrow is doing the job that a drawn route plus a
"250 metres, then turn left onto Satmasjid Road" readout should be doing.

Note the arrow predates turn-by-turn — Module 2 shipped it as a static
placeholder and its own comment says "Modules 4-5 will feed it real turn
instructions". Those modules exist now.

---

## 4. Route replies give no context and no way to ask for another

**Reported:** after "take me to Labaid", the assistant said only that the
safest route passes through a somewhat risky area. The user wants to know
*which* way it is taking them, and to be able to say "give me a different
route".

`RoutingService.walkingRoutes` already requests
`computeAlternativeRoutes: true` and returns every alternative;
`RoutePlanningService` picks the safest and discards the rest. Nothing keeps
them, so there is nothing to switch to.

**Fix direction:** hold the alternatives on the chat state, describe the
chosen one when announcing it ("via Satmasjid Road, 1.2 km"), and add a tool
for "a different route" that walks to the next candidate.

---

## 5. Map auto-open is not covered by a test

Fixed in this session — a non-null `pendingRoute` reveals the map. Verified by
reading the code path and by the map behaving correctly on device, but there is
no widget test: it needs a `RouteChoice` fixture and a `ProviderScope`
override, which was more setup than the assertion was worth at the time.

---

## Fixed this session, awaiting tester confirmation

These are in the build being distributed and have *not* been exercised by a
tester yet:

- submit phrases ("show it", "submit") being sent as message text
- listen sessions dying 64 ms in, from timers outliving their own session
- Bangla voice labels shown to English users, in onboarding and in settings
- an unclear read-back looping forever without ever saying "yes or no"
- `voiceAutoListen` not re-derived when the vision answer changes
- the command tour losing its closing instruction to a 30 s playback timeout
