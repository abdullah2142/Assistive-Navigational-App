# Open bugs

Carried over from the device session on 9 September 2026. Everything in the
"Reported" lines below was observed on the Redmi 10C, not inferred from code.

Items 1-5 were worked on 9 September 2026 and are **fixed but not yet
confirmed on a device** — see "Still needs a device" at the bottom for the
specific claims that only a phone can settle.

---

## 1. "Hey ANT" and auto-listen do not work together — REGRESSION — FIXED

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

Nothing here can be settled off-device, and none of it should be assumed to
work because the tests pass.

1. **The wake-word fix.** The tests prove the ownership state machine, not
   that Android hands the microphone over cleanly on a Redmi 10C. Test it the
   way it broke: both toggles on, say "Hey ANT", ask for a hazard report,
   answer the hub by voice, close it, then say "Hey ANT" again.
2. **Warm restarts (item 2).** Watch for a *double* trigger — the failure mode
   the poisoned-buffer rule guards against. If "Hey ANT" ever fires twice off
   one utterance, the detection path is keeping buffers it should not.
3. **Street names on the Google backend.** The extractor is asserted against
   the documented response shape, which is the same standing caveat
   `test/google_routes_backend_test.dart` opens with: the Google path has
   never been run. Listen for "turn left onto" actually naming roads.
4. **The banner at 40% height, outdoors, in sunlight.** It was checked at the
   real split-view size in a widget render; it has not been looked at on
   glass.

## Fixed earlier, still awaiting tester confirmation

In the distributed build and not yet exercised by a tester:

- submit phrases ("show it", "submit") being sent as message text
- listen sessions dying 64 ms in, from timers outliving their own session
- Bangla voice labels shown to English users, in onboarding and in settings
- an unclear read-back looping forever without ever saying "yes or no"
- `voiceAutoListen` not re-derived when the vision answer changes
- the command tour losing its closing instruction to a 30 s playback timeout
