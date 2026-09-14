# Test round 3 — five packs, one owner each

**The biggest change this round is not a feature.** The app now records what it
is doing from the moment it opens, and you can send that recording to us in two
taps. See "Sending a report" below — it replaces most of what you would
otherwise have to write down, and for anything involving voice it is worth more
than any description.

**What changed since round 2** is listed at the bottom of this file. The short
version: onboarding no longer loses your answers when the app is killed, hazard
reports actually save, the microphone recovers on its own after airplane mode,
caretaker messages now reach the user at all, and the Magic Button's
Volume-Down hold no longer gets eaten by the volume panel.

Sections added this round are marked **"new in round 3"**. Every pack has some
— that is where the findings will be, because none of it has been used by
anyone but the developer.

Everything else in your pack still applies. A fix in one area routinely breaks
another, and the older sections are what catch that.

One person owns one area end to end. That is deliberate: this app has too
many interacting parts for everyone to poke at everything, and four shallow
passes over the whole app find less than four deep passes over a quarter of
it.

| Pack | Area | Modules | Budget | Owner |
| --- | --- | --- | --- | --- |
| [A](pack_a_onboarding.md) | Setup, entirely by voice | 1 — onboarding, pairing, command tour | ~3 h | |
| [B](pack_b_voice_commands.md) | Saying things the app didn't expect | 3 — commands, assistant, wake word | ~4 h | |
| [C](pack_c_navigation.md) | Actually walking somewhere | 4, 7 — routing, map, safety, haptics | ~4 h, outdoors | |
| [D](pack_d_reporting.md) | Asking for help, flagging trouble | 2, 5 — reporting, passer-by, caretaker | ~3.5 h | |
| [E](pack_e_emergency.md) | The Magic Button | 9 — emergency escalation | ~3 h | |

**My Settings belongs to Pack B this round.** It is referenced by three packs
and was owned by none, and it has grown a lot — the sensitivity dial, vibration
strength, the narration choice and the report button are all new, on top of
contacts, saved places, theme, text size and language.

Fill in the owner column before the round starts. Each pack file is
self-contained — send a person their file and nothing else.

Budgets are a guide, not a target. Finishing early almost always means the
"say it your own way" parts were skipped, and those are where the findings
are.

## Things that need two people

Agree these times at the start of the round, or they quietly never happen.

| What | Who |
| --- | --- |
| Caretaker pairing | A + one of C or D |
| Three-reporter hazard escalation | D, with A and C filing |
| Hazard warning received while walking | D files, C walks |
| Remote setting change from caretaker | D + A |
| Emergency alert reaching the caretaker | E + D |
| **Caretaker messages arriving at the user** (new in round 3) | D + A |
| **Checking a sent report leaks nothing** (new in round 3) | whoever sends one, with the developer |

## Recording coverage

Every pack ends with a coverage checklist. **Tick what you actually did and
send it back even if nothing broke.** "Nobody tested that" and "someone
tested it and it was fine" look identical in a bug list, and only one of
them is safe to ship on.

## The voice phrasebook

Every phrase the app accepts on purpose, in Bangla and English — all 22 ways
of asking for a route, every saved-place synonym, all 27 reportable hazards,
the submit and cancel vocabularies, and every phrasing of the nine settings.
It also lists the input that deliberately does nothing, which is as much a
part of the spec as the rest.

**Read it here:**
<https://claude.ai/code/artifact/9b6dbca5-3282-4e74-be27-d32aea57dc5e>

The source is [voice_phrasebook.html](voice_phrasebook.html). GitHub shows
that as code rather than rendering it, so use the link when you are actually
testing. It is kept here so it is versioned with the app and can be
republished without being rebuilt from scratch.

It is generated from the app's intent matcher, so it describes what the
build genuinely accepts rather than what we intended. **If you find a listed
phrase that does not work, that is a bug in the app or in this document, and
either way we want to know** — the same file is what the onboarding command
tour teaches from.

## Getting the app

Through Firebase App Distribution, not by building it. You need an Android
phone, the email address you were invited on, and a network connection —
no computer, no cable, no developer mode. See the "Installing as a tester"
section of the [root README](../README.md).

## Skipping onboarding

Only Pack A tests onboarding. Everyone else should use the **⏩ button in
the top-right of the first onboarding screen**, which fills in a dummy
profile and goes straight to the dashboard.

It leaves the **wake word** switched off on purpose. Turn it on by voice if
your pack needs it:

```
turn on hey jarvis
```

**Automatic listening now depends on the profile.** A user who answered "no
vision" gets it on without being asked; everyone else is asked once during
setup. The dummy profile the ⏩ button creates is sighted, so it will be
**off** — turn it on by voice if your pack needs it:

```
turn on auto listen
```

The wake phrase is **"Hey Jarvis"** — a placeholder model, not renamed to
match the app yet.

## Sending a report — new in round 3

**My Settings → "Send a report to the developers" → Send report.** The share
sheet opens with a text file attached; send it however you like.

**Send one the moment something goes wrong, before you carry on testing.** The
recording holds the last 2000 lines and continuing to test pushes the evidence
out of it. A report sent five minutes later may not contain the thing you are
reporting.

This is not instead of the written entry below — it is instead of having to
describe *what the app did internally*, which nobody can see from outside. Keep
telling us what you said and what you expected; the report supplies the rest.

### What is in it, and what is not

The file contains what the app did: which screen, which step, whether the
recognizer returned anything, what the wake word scored, what failed and with
which error.

**What you said is not in it.** Words, names, phone numbers and your location
are replaced before they are written down — only the shape is kept. A sentence
you spoke appears as `"<6 words, 32 chars>"`, a phone number as `+<digits:13>`,
your position as `<coord>`. That is deliberate: you are testing with your own
family's numbers and your own voice, and neither should end up in a file you
forward to somebody.

If you ever open one of these and find something that looks like real content,
**tell us immediately** — that is a serious bug, not a small one.

## Ground rules

These apply to every pack.

- **Use a real phone, not an emulator**, and use *different* phones between
  you. The worst bug found so far appeared on one GPU family only.
- **At least one run outdoors, with street noise.** Quiet-room results tell
  us almost nothing about speech recognition.
- **Every run twice** — once in English, once in Bangla. They fail
  differently, and Bangla fails in ways English never will.
- **Say it wrong on purpose.** Half your value is mumbling, rephrasing and
  stopping mid-sentence. Perfect diction finds nothing.
- **Stay inside your pack.** If you hit something outside it, write it down
  in one line and move on. Don't chase it.
- **Cold-start at least once, on a bad connection** (new in round 3). Kill the
  app, turn mobile data *off*, open it, then turn data back on. Several of the
  worst bugs this round only appeared in that order — the app asks its
  database a question, the database answers "nothing" before the network can
  correct it, and the app believes it. A normal restart on wifi will not find
  them.

## Reporting

One entry per problem, in this shape. The exact words you spoke matter more
than anything else you can give us — a voice bug without the transcript is
usually not actionable.

```
PACK:      C
PHONE:     Redmi 10C, Android 13, MIUI 14
LANGUAGE:  Bangla
WHERE:     Walking, Mohammadpur, ~9pm, light rain

I SAID:    "আমি মোহাম্মদপুর যেতে চাই"
EXPECTED:  Route starts
HAPPENED:  "I don't know where that is"
AGAIN?:    Yes, 3 of 3 tries

NOTES:     Worked when I said just "মোহাম্মদপুর"
REPORT:    sent 21:04
```

**"REPORT: sent"** is the new line. If you sent one, say roughly when, so we
can find it among the others.

**Always include the phone model and whether it repeats.** The blank-map bug
existed only on one GPU family and would have been dismissed as "works on
mine" without the model written down. A bug that happens once and a bug that
happens every time are different bugs.


## What changed since round 2

Ordered by how much it should change your testing. **None of it has been
confirmed on a phone** — it is verified by automated test and by reading, which
is not the same thing. That is what this round is for.

| # | What | Pack |
| --- | --- | --- |
| 26 | **Onboarding no longer loses your answers when the app is killed.** Reported twice. Two separate faults: nothing recorded which step you had reached, and picking your role wrote a blank profile over the saved one. The second fix is the one that matters on a real phone — the first only worked when your profile loaded instantly. | A |
| 27 | **Hazard reports actually save.** The write was never even attempted: it was stuck waiting for a GPS fix that never arrived. | D |
| 32 | **The microphone recovers by itself** after airplane mode, a phone call, or another app taking it. It used to stay dead while the app still believed it was listening. | B, all |
| 28 | **Caretaker messages now reach the user.** The sending half worked all along; nothing on the user's phone was listening. Voice memos play, snapshot requests say plainly that photos are not built yet. | D |
| — | **Magic Button hold fixed.** Holding Volume Down opens the system volume panel, and that was cancelling the hold. It also buzzes the moment your press registers. | E |
| 43 | "Help me" inside a longer sentence now triggers. So does a polite Bangla request. | E |
| — | **SOS responds immediately.** "Save me" was waiting on a location fix it never used. | E |
| 38 | Answering **slowly, with pauses mid-sentence**, no longer cuts the microphone off. | A, B |
| — | **Mis-heard commands still work.** "Report a hazard" heard as "People of the hazard" now opens the hazard report. | B |
| 30 | The hazard hub no longer replays the previous page's instructions when you pick a category by tapping. | D |
| 33 | Mobility question accepts "আমি একাই হাঁটি" and its variants. | A |
| 39 | A dictated contact name is now **spelled out** in the read-back, so a misspelling can be caught by ear. Bangla names are spelled by syllable. | A |
| 37 | The map's fullscreen button no longer covers the current-location button. | C |
| — | The map closes when you cancel a trip. | C |
| 44, 45 | System back gesture no longer leaves the app; "my own message" works on the passer-by screen. | A, D |

### New features to exercise

| What | Where | Pack |
| --- | --- | --- |
| **Send a report** | My Settings | everyone |
| **"Hey ANT" sensitivity dial**, with a live score meter | My Settings | B |
| **Vibration strength**, and three distinct patterns | My Settings | C |
| **Narration choice** — read the options every time, or only when you ask | asked during setup, changeable in My Settings | A |
| **Caretaker inbox** on the user's side | arrives on its own | D |

### Stop testing this

**"Does the wake word trigger?"** is no longer a useful question — it depended
on a threshold we were guessing at. There is now a dial and a live score, so
the question is **"what number does your voice score?"**. That is answerable,
and it is what we need. Pack B has the procedure.

### Still broken, and we know

- **Wake word with the screen off.** If you try it, send a report immediately
  afterwards — the report now names the exact Android error, and that single
  line should settle a problem we have been unable to pin down for two rounds.
- **Unpairing a caretaker.** Not possible yet. It needs a database permission
  change we are not willing to ship without verifying properly.
- **Sending photos.** The camera side does not exist; snapshot requests arrive
  and say so.
- **Directions sometimes not spoken when a route starts** (carried over from
  round 2). Pack C Part 11 explains what to listen for.

### Most likely to have broken something

- **Vibration is a brand-new native component.** If turns stopped buzzing
  entirely, that is this. Worth checking early rather than at the end.
- **The caretaker inbox** listens continuously on the user's phone for the
  first time. If the app got slower or hotter, say so.
