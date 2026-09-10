# Test round 2 — four packs, one owner each

**What changed since round 1** is listed at the bottom of this file. The short
version: the wake word dying after one command is fixed and is the single most
valuable thing to confirm, the giant map arrow is gone, and saving a place is
now a conversation. Every pack has new sections marked "new in round 2" —
those are where the findings will be, because none of it has been used by
anyone but the developer.

Everything else in your pack still applies. A fix in one area routinely breaks
another, and the round-1 sections are what catch that.

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


## What changed since round 1

Ordered by how much it should change your testing. Everything here is fixed in
the build you have been sent, and **only two of them have been confirmed on a
phone** — the rest are verified by test and by reading, which is not the same
thing.

| # | What | Pack | Confirmed on a device? |
| --- | --- | --- | --- |
| 6 | "Hey ANT" no longer dies after one command. The assistant's own reply was taking permanent audio focus and stopping its own microphone. | B | Yes |
| 9 | Show Screen says what it is for before opening the mic, and "show it" with nothing dictated no longer loops. | D | Yes |
| 7 | The red mic button can be turned off. It never could. | B | No |
| 8 | Onboarding narration no longer bleeds into the next screen, and the caretaker code is now spoken. | A | No |
| 23 | The app no longer transcribes its own prompts into your message. | D, B | No |
| 3 | The map shows the next turn, its distance and the road name instead of a giant arrow. | C | No |
| 14 | The map follows you and turns with your direction. **No automated test covers this at all** — it needs a real GPS stream. | C | No |
| 4 | Route replies say which way and how far. "Give me a different route" and "re-route" work. | C | No |
| 21 | Turn-by-turn also appears as text in the chat — the only channel a Deaf user has for it. Narration now stops when its screen closes. | C, D | No |
| 12 | Saving a place is a conversation it can finish, and it will not invent a name from your request. | B | No |
| 10 | Auto-listen is on for blind users and asked once of everyone else, instead of being inferred. | A | No |
| 11, 15, 17, 18 | Saved places listed in settings; draggable chat/map split; chat input grows; map toggle moved beside the mic. | B, C | No |
| 22 | It no longer answers a half-heard command by inventing a status. | B | No |

### Still broken, and we want your help pinning it down

**Directions sometimes are not spoken when a route starts.** We have not fixed
this, because three different causes look identical from outside and guessing
would risk breaking the parts that work. Pack C Part 11 explains what to
listen for — the opening sentence tells us which of the three it is, and that
one detail is worth more than any amount of description.

### New this round: Pack E, the Magic Button

Module 9 was in no pack in round 1 — it landed the day *after* the packs were
written, and the only thing testers were told was what to do if it went off by
accident. It has since been fired on real hardware, so it now gets a pack of
its own rather than a section inside someone else's: it needs its own safety
briefing, and that briefing does not belong halfway down a page about
reporting potholes.

**It is still in rehearsal mode** — the sequence runs and speaks, nothing is
sent to anyone. That is what makes it testable. Pack E opens with what that
does and does not protect, and testers should read it before touching the
volume keys.

### Two changes most likely to have broken something

- **The map following you** (item 14) is the only change shipped with no test
  behind it.
- **Auto-listen** (item 10) changes what a newly created profile gets, so it
  affects every fresh install, not just the setting screen.
