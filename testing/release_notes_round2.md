# Release notes — test round 2 (camera)

Paste the block below into `--release-notes`. Keep it short: this is the
only instruction most testers read, and it is read on a phone.

The tester group alias is **`fydp`**. Verify with
`firebase appdistribution:group:list` before distributing — a wrong alias
fails after the upload has already succeeded, with a 404 that names
nothing.

## What changed since round 1

The camera. None of it has ever run on a phone, which is the whole point of
this round.

- A **camera button** on the input row, beside the mic and the map.
- Ask out loud: *"what bus is this"*, *"what does that sign say"*, *"is the
  path clear"*, *"what's around me"*, *"is there a rickshaw"*.
- **Hold Volume Up** for two seconds to look around hands-free.
- For blind and low-vision profiles the app now **looks around on its own**
  while you walk, and speaks only if something is in the way.
- Bus signboards are matched against 156 real Dhaka operators.
- The assistant **keeps listening after it answers**, so you can carry on
  talking without saying the wake word again.

## Why this round is different from round 1

Round 1 asked whether the assistant understood people. This round asks
whether the camera **tells the truth**, which is a harder and more dangerous
question — the app is now saying things about a street to somebody who cannot
check them.

The single most important test in the whole round takes ten seconds:
**cover the lens with your thumb and ask "is the path clear".** It must say
it could not see. If it says the path is clear, stop and report that first,
before anything else in the pack.

---

```
Round 2 — the camera. Please read this bit, it is short.

NEW: camera button next to the mic. Or just ask out loud: "what bus is
this", "what does that sign say", "is the path clear", "what's around
me". Holding Volume Up for 2 seconds also works.

The app also keeps listening after it answers now — you should not need
to say the wake word again to carry on talking. Tell us if you still do.

DO THIS FIRST, it takes 10 seconds:
Cover the camera with your thumb and ask "is the path clear".
It MUST say it could not see. If it says the path IS clear, stop and
report that immediately — that is the worst bug this app can have.

Also please try:
- A real bus signboard. Does it name the right bus? Write down what the
  bus actually said vs what the app said.
- Walking 20 minutes with the app open. Note battery % before and after,
  and whether the phone got warm. Nobody has measured this yet.
- Asking 5-6 things very fast. If it ever says it is busy, tell us.

Not in scope: the emergency button. If it goes off by accident it is
safe — practice mode, nothing is sent — say "cancel" and carry on.

Known and no need to report: caretaker screens are English-only. The app
cannot read signs or name a bus without internet; it should say so.

The app is bigger this round (~150MB) because the camera needs it.
Download on wifi.

Report the exact words you said, and what it said back. That matters
more than anything else.
```
