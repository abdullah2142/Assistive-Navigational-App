# ANT tester release notes — round 5

Paste the block below into `--release-notes`. Keep it short: this is the
only instruction most testers read, and it is read on a phone.

The tester group alias is **`fydp`**. Verify with
`firebase appdistribution:group:list` before distributing — a wrong alias
fails after the upload has already succeeded, with a 404 that names
nothing.

---

```
Round 5. A safety fix: cancelling a trip or raising an alarm through plain
conversation (not a fixed phrase) used to silently do nothing. Found live,
now fixed and tested. Please try:

- Start a route, then cancel it in your own words — not just "cancel the
  trip", also try "actually, never mind" or "stop, I'm not going" —
  and confirm the map and narration actually stop.
- Describe being unsafe without saying "help" or "emergency" outright —
  e.g. "someone's following me" or "I can't get up" — and confirm the
  alarm still fires. Say "cancel" within 5 seconds to stop it; nothing is
  sent to anyone in that window.
- If paired with a caretaker, say something reassuring like "tell my
  caretaker I'm okay" and check the caretaker actually receives those
  words, not just a generic alert.

Also: ambiguous destinations ("take me to the one you just mentioned"),
mid-route changes of mind, and bus/sign reading should all feel more
reliable this round — report anything that still guesses wrong.

Report the exact words you said. That matters more than anything else
you can tell us.
```

---

## Why each line is there

**The headline bug** is the one worth naming plainly: both AI backends
built their final response after a tool call without ever carrying
`cancelsRoute`/`triggersEmergency` out of the aggregation step — so a
cancellation or an emergency the model correctly *decided on its own*
(not matched by a fixed local phrase) reached the app as if nothing had
happened at all. Confirmed live with a logging executor before the fix:
the model called `cancel_route` correctly, and nothing after that point
acted on it. This is exactly the gap `trigger_emergency`'s own tool
declaration exists to close, reopened silently by this bug — so it gets
top billing rather than being buried in a changelog.

**"not just 'cancel the trip'"** — the fixed local phrase list already
worked before this round; the whole point of this round's fix is the
phrasing *outside* that list, which only the model (not a keyword match)
can resolve.

**"without saying 'help' or 'emergency' outright"** — same reasoning:
local matching has always needed an explicit cry word, and still does.
What changed is the model's own judgement now actually reaching the app
when the local matcher has nothing to go on.

**The caretaker line** catches a second, related bug in the same fix: a
reassurance was being swallowed into a bare "please check on me" flag
that never carried the actual words — the caretaker would see concern for
a message that meant the opposite.

**"exact words you said"** — unchanged from round 1; still the single
most useful thing in a report.

## Known constraints for this round

- Built with Google routing preferred and OSM fallback, same as round 4.
- Cloud TTS still has no dedicated key in this build (item 63, unchanged)
  — spoken output uses the handset's own engine.
- The new on-screen debug error banner (shows the real error when an AI
  call fails, instead of only the console) is a **developer-mode-only**
  feature and will not appear in this release build — nothing to test
  here, it is for `flutter run` during development.

## Build and verification

Built with `scripts/release_google_build.sh build` — Google Routes
preference with OSM fallback, tester onboarding skip, raw diagnostic
transcripts, and configured Groq/Gemini/Cloud STT keys, each verified
present in the compiled APK (not just the build command) by the script's
own post-build checks. Full Flutter test suite passed: 1,500 tests.
