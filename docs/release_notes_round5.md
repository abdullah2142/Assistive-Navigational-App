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

One more fix in this build: pointing the camera at something ("what's
in front of me?") was failing almost every time — it would say "I have
no internet" even on a good connection. That's fixed; please try it on
a real bus, sign, or street scene and tell us what it got wrong, if
anything.

Also new in this build:

- Typing in the chat box used to close the keyboard after the first
  letter. Please type a full message and confirm it works.
- Ask "what time is it" (it used to invent the time) and "what can you do"
  or "what is the Magic Button" (it now explains everything, including how
  to hold Volume Down for three seconds in an emergency).
- When an emergency starts you now see a red box with a big "Cancel alert"
  button, and typing "cancel" also stops it. Nothing is sent in practice
  mode.

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

## Vision fallback timeout fix (this build)

Confirmed live on a physical device: the Gemini vision fallback chain's
per-model timeout was 2800ms, transplanted from a different, much faster
dedicated vision backend's calibration (measured 0.43-0.70s there). The
general-purpose Gemini generativelanguage API is far slower — a
same-session text call took 14027ms — so every Gemini model in the
cascade timed out on every real capture, and once Groq's own 12s budget
was also exhausted, the camera-description feature failed 100% of the
time and told the user it had no internet. Raised to 6000ms per model.
Verified against the full test suite (1500 passing) and a fresh live
capture that correctly described a real scene.

## Known constraints for this round

- Built with Google routing preferred and OSM fallback, same as round 4.
- Cloud TTS still has no dedicated key in this build (item 63, unchanged)
  — spoken output uses the handset's own engine.
- The on-screen debug error banner (shows the real error when an AI call
  fails, instead of only the console) now **also shows in this build** —
  corrected after the first upload, which gated it to `kDebugMode` alone
  and so it never appeared in any build testers actually receive. If you
  see a bordered box with a bug icon and raw error text after a reply
  that seems off, that is it working as intended — screenshot it, it is
  exactly the detail a report needs.

## Build and verification

Built with `scripts/release_google_build.sh build` — Google Routes
preference with OSM fallback, tester onboarding skip, raw diagnostic
transcripts, and configured Groq/Gemini/Cloud STT keys, each verified
present in the compiled APK (not just the build command) by the script's
own post-build checks. Full Flutter test suite passed: 1,500 tests.

Google routing itself confirmed live on a real device (not just the
build-time check above): installed via `adb`, requested a route to a
saved place, and `adb logcat` showed no app-level `"[Routing] Google ...
failed"` line, `[Map] building` reporting `openStreetMap=false`, and the
Places API returning real nearby bus stops along the route — Google was
genuinely reached, not silently falling back to OpenStreetMap.
