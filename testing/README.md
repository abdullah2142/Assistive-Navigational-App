# Test round 1 — four packs, one owner each

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

## Recording coverage

Every pack ends with a coverage checklist. **Tick what you actually did and
send it back even if nothing broke.** "Nobody tested that" and "someone
tested it and it was fine" look identical in a bug list, and only one of
them is safe to ship on.

## Getting the app

Through Firebase App Distribution, not by building it. You need an Android
phone, the email address you were invited on, and a network connection —
no computer, no cable, no developer mode. See the "Installing as a tester"
section of the [root README](../README.md).

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
```

**Always include the phone model and whether it repeats.** The blank-map bug
existed only on one GPU family and would have been dismissed as "works on
mine" without the model written down. A bug that happens once and a bug that
happens every time are different bugs.
