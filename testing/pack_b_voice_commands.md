# Pack B — Saying things the app didn't expect

**Module 3 · voice commands, the assistant, the wake word**

> **New this round — send a report when something goes wrong.**
> My Settings → *Send a report to the developers* → **Send report**, then share
> it however you like. Do it **immediately**, before carrying on: the app keeps
> only the last part of the session, and continuing to test pushes the evidence
> out.
>
> It contains what the app *did*, never what you *said* — words, names, numbers
> and your location are replaced with their shape before they are written down.
> Keep writing down what you said and what you expected; the report supplies
> everything you cannot see.
**Budget: about 4 hours — the largest pack, and the most mechanical**

## What you own

Every spoken command on the dashboard, the wake word, and the boundary
between what the phone handles instantly and what gets sent to the AI.

Work from the [voice phrasebook](voice_phrasebook.html), but understand what your job
actually is: the phrasings that are **not** in it. The listed phrases are
examples of a shape, not passwords, and the app is supposed to cope with
however you naturally say it. Finding where it doesn't is the whole pack.

Use the **⏩ button in the top-right of the first onboarding screen** to
skip setup — you are not testing onboarding, Pack A is.

**Before Part 5, turn two things back on.** The skip button deliberately
leaves them off, because on a test device they fire constantly:

```
turn on hey jarvis
turn on auto listen
```

Doing that is itself a test — tell us if either command does not work.
Without it the wake word will appear completely dead and you will spend
Part 5 reporting a bug that is really just a switch.

The wake phrase is **"Hey Jarvis"**, not "Hey ANT". It is a placeholder
model we have not replaced, so it really is Jarvis.

---

## Part 1 — The baseline

1. Every command in the phrasebook, once, in **English**. Tick them off.
2. Every command in the phrasebook, once, in **Bangla**.
3. Anything that failed here is a **BLOCKS** — these are the documented
   phrases and they are supposed to work.

## Part 2 — Your own words (the actual test)

4. **Rephrase every command into words you would genuinely use** and try
   again. Three different rephrasings each for the nine settings.
5. Say them with filler and politeness — "um, could you maybe make the text
   a bit bigger please".
6. Say them **back to front** where the language allows it — "bigger, the
   text" / "গুলশান, নিয়ে চলো".
7. Say a command **with an unrelated sentence in front of it**: "it's really
   hot today, take me to Gulshan".
8. Say **two commands in one breath**: "make the text bigger and switch to
   dark mode". Does it do both, one, or neither? Any of the three is
   defensible — but silently doing one of two is the worst.

## Part 3 — Code-switching

Dhaka speech mixes English and Bangla constantly. This is where the app is
most likely to break and least likely to have been thought about.

9. With the app **in Bangla**, use English command words inside a Bangla
   sentence: "টেক্সট bigger করো", "dark mode করো", "send".
10. With the app **in English**, use Bangla place names: "take me to
    গুলশান".
11. Bangla place names **with case endings** — `গুলশানে`, `ধানমন্ডিতে`,
    `মিরপুরে` — and without.
12. Say English words that a Bangla recogniser will write in Bangla script
    and check they're still understood.

## Part 4 — Follow-ups

13. `make the text bigger`, then `even bigger`, then `a bit more`, then
    `again`. Four steps.
14. Same for verbosity: `keep it short`, then `even shorter`.
15. Now **change a different setting in between** and try the follow-up
    again — it should no longer apply. `make text bigger` → `switch to dark
    mode` → `even bigger` should do nothing or ask.
16. Wait two minutes, then say `even bigger`. Still working, or expired?
17. Say a **long sentence containing "bigger"** — "bigger crowds make me
    anxious" — and confirm it does not resize anything.

## Part 5 — The wake word

**This is the highest-value section in round 2.** The cause of "it works once
and then never again" was found and fixed: the assistant's own spoken reply
was taking permanent audio focus, which stopped its own microphone. Every one
of these is a check on that fix.

18. **The one that matters.** Say `Hey Jarvis`, give a command, **let it
    finish answering out loud**, then say `Hey Jarvis` again. Repeat five
    times without relaunching. Before the fix, the second wake word never
    worked. If it fails, note whether the reply was long or short.
19. Say `Hey Jarvis` **ten times over ten minutes**, doing other things in
    between. Count how many worked.
19. From **across a room**, from **a pocket**, with a **TV or music
    playing**, and **outdoors**.
20. Say it **twice in quick succession**.
20b. **Watch for it firing twice off one "Hey Jarvis".** The fix retains some
    audio across the pause, and a double trigger is what a mistake there looks
    like. It would show as the mic opening, closing and reopening on its own.
21. Say something that sounds similar but isn't — "hey Jarvis" vs "hey
    Travis", "হেই জার্ভিস" — and note false triggers.
22. Turn the wake word **off by voice**, confirm it stops responding, turn
    it back on.
23. Lock the screen and say it.
24. **Play music, then say a command.** The reply should duck the music and
    let it come back, not stop it for good.

## Part 5b — The mic button (new)

25. Tap the mic button, then **tap it again while it is red**. It must close.
    This has never worked in any build you have seen — the button was dead for
    the whole session once opened.
26. Do the same after a wake-word trigger rather than a tap.
27. Open it and say nothing at all. Confirm it closes by itself and that the
    button is usable afterwards.

## Part 6 — Questions that must do nothing

Every one of these should be answered or ignored, never acted on. Any that
**acts** is a **BLOCKS**.

24. `should I go to Uttara?` / `is it worth going to Gulshan?`
25. `how far is it to Mirpur?` / `গুলশান কতদূর?`
26. `how long will it take?`
27. `is it safe around here?`
28. `is it getting dark?` / `it's getting dark outside`
29. `the street light is broken`
30. `is the text bigger now?`
31. `is there a manhole near here?`
32. `আমি অফিসে যাব না` / `I'm not going to work today`
33. `is it going to rain before I get there?`

**New in round 2 — it must not invent a status.** Say a single word that is
only half a command:

34. Just `Screen.` — nothing else.
35. Just `Route.` — nothing else.

    It used to answer "Your screen is currently active and ready", which is a
    state the app cannot read and does not have. It should now **ask which
    command you meant**. A confident answer to a half-heard command is a
    **BLOCKS**: you cannot see that nothing happened.

## Part 7 — Saved places

34. Route to each saved kind using **every synonym** in the phrasebook —
    home/house/my place, work/office/job, school/college/campus, and the
    family words.
35. Add a saved place by voice, then route to it.
36. Set up **two saved places with similar names** and confirm it asks
    rather than guessing.

**New in round 2 — saving is now a conversation.** These are the reported
failures, so run all of them:

37. Say `add a new place`. It should **ask what to call it**. Answer with a
    short name. It must **save**, not route you there. Routing on the answer
    was the bug.
38. Say `add a new place I go to frequently`. It must **not** create a place
    called "frequent place" at wherever you are standing. It should ask for a
    real name.
39. Start the same conversation and say `never mind`. It should stop cleanly.
40. Start it and then say `take me to Gulshan` instead. The route should win
    and the save should be dropped, not queued.
41. Open **My Settings** and confirm your saved places are listed, each with a
    delete. Delete one and confirm it is gone. If an old junk entry like
    "frequent place" is on your device, this is how to clear it.

## Part 8 — Failure and fallback

37. Say complete nonsense. What happens?
38. Fail the same command **twice in a row** and confirm it then offers you a
    short phrase that always works. Write down the phrase it gives you and
    check that phrase actually works.
39. Say something genuinely ambiguous and watch whether it asks or guesses.
    **Guessing is the bug**, even when it guesses right.
40. Put the phone in airplane mode and try (a) a local command like
    `make text bigger` and (b) something that needs the AI. The first must
    still work.

## Part 9 — Latency

41. For each command, note roughly whether it was **instant** or took a
    **second or more**. Group them into two lists.
42. Anything in the slow list that feels like it should obviously be instant
    is worth flagging — it may belong in the on-device matcher.

---

## Hunt for

- A phrasing an ordinary person would obviously use that **isn't
  understood**. Write your exact words.
- Worse: a phrasing that does **the wrong thing** rather than nothing.
- Negatives being ignored.
- A wake word that stops working after the first use.
- The app failing twice **without offering a fallback phrase**.
- A setting that changes without saying so — every change should be
  confirmed out loud.

## Passes if

You operated every dashboard function using words you chose yourself, in
both languages, without memorising anything — and the wake word worked at
least nine times out of ten across a session.


## New in round 3

### The sensitivity dial — the most useful hour in this pack

**The old question "does the wake word trigger?" is retired.** It depended on a
threshold we were guessing at from one person's voice in one room. There is now
a dial and a live meter, so the question is **what number does your voice
score** — which is answerable, and is what we need from you.

My Settings → **"Hey ANT" sensitivity**. Make sure the wake word itself is on
above it, or the meter has nothing to show.

1. Say **"Hey Jarvis"** normally, at the distance and volume you would really
   use. Watch the bar.
2. Write down the number under it — it reads **"Triggers at 0.30"**. **Send us
   that number, not the percentage.** The raw number is what matches our logs.
3. Say it again five times and note the range. Ours scored 0.30 to 0.97.
4. Now say it the way the app currently seems to want it — softly, gently, with
   a gap between the two words. Note that number too.

**The gap between those two numbers is the finding.** If normal speech scores
0.1 and careful speech scores 0.7, the problem is the recognition model and no
setting will fix it. If normal speech scores 0.28 and the line sits at 0.30,
moving the line fixes it today.

5. Set the marker just under where your normal voice reaches, then use the app
   for a while. Does it fire when you did not say it? That is the cost of
   moving it, and we need to know how bad it is.
6. **Say it with the phone in your pocket**, screen off. Then send a report
   immediately — see below.

### Saying commands badly on purpose

The app now tries to recognise commands through a mis-hearing. "Report a
hazard" came back from the recognizer as "People of the hazard" on a real
phone, and that now still opens the hazard report.

Try each of these and note which are understood:

- say a command with a word slurred or half-swallowed
- say it quickly enough that two words run together
- say it over traffic noise
- say it with a cough or "um" in the middle

Then the other direction, which matters just as much:

- **"what happens if I report a hazard"** — must *not* open the report screen
- **"the pavement here is a real hazard"** — must not either

If describing your day opens screens, that is worse than a command being
missed.

### The microphone after an interruption

1. Start the wake word, then **put the phone in airplane mode** for ten
   seconds and take it out again. Does "Hey Jarvis" still work?
2. Take a real phone call, hang up, try again.
3. Play music in another app, stop it, try again.

The recorder used to die silently in all three cases while the app carried on
believing it was listening. Send a report if any of them stays dead.

### My Settings belongs to you this round

It was referenced by three packs and owned by none. Go through every control
once: wake word, sensitivity, reading choices out, auto-listen, vibration
strength, contacts, saved places, theme, text size, language. For each one —
does it take effect **immediately**, and does it still hold after the app is
closed and reopened?

## Coverage — tick what you actually did

**New in round 3**

- [ ] Wake-word score recorded for normal speech (number: ______)
- [ ] Score recorded for careful/soft speech (number: ______)
- [ ] Marker moved, false triggers counted over real use
- [ ] Wake word tried with the phone in a pocket, report sent
- [ ] Commands said badly on purpose
- [ ] "What happens if I report a hazard" did NOT open it
- [ ] Mic after airplane mode / phone call / other audio
- [ ] Every My Settings control changed, and checked after a restart
- [ ] Report sent at least once

- [ ] Full phrasebook sweep, English
- [ ] Full phrasebook sweep, Bangla
- [ ] Three rephrasings for each of the nine settings
- [ ] Commands with leading filler / trailing politeness
- [ ] Two commands in one breath
- [ ] Code-switched English-in-Bangla
- [ ] Code-switched Bangla place names in English
- [ ] Case-ending place names
- [ ] Four-step follow-up chain
- [ ] Follow-up after an unrelated setting change
- [ ] Wake word × 10 over ten minutes
- [ ] Wake word: room, pocket, noise, outdoors, locked screen
- [ ] Wake word near-misses / false triggers
- [ ] All ten must-do-nothing questions
- [ ] Every saved-place synonym
- [ ] Two similar saved places
- [ ] Fallback phrase after two failures
- [ ] Airplane mode: local vs AI commands
- [ ] Latency split into instant / slow

## Before you start

Get the app through **Firebase App Distribution** — you need an Android
phone, the email you were invited on, and a network connection. No computer,
no cable, no developer mode. Details in the [root README](../README.md).

Keep the **voice phrasebook** open while you work — it lists every phrase the
app accepts on purpose, in both languages. Read it at
<https://claude.ai/code/artifact/9b6dbca5-3282-4e74-be27-d32aea57dc5e>; the
source lives here as [voice_phrasebook.html](voice_phrasebook.html), which
GitHub shows as code rather than rendering.

Ground rules for every run:

- **A real phone, not an emulator.** Check with the others that you are all
  on different handsets — the worst bug found so far appeared on one GPU
  family only.
- **At least one run outdoors, with street noise.** Quiet-room results tell
  us almost nothing about speech.
- **Everything twice** — once in English, once in Bangla. They fail
  differently.
- **Say it wrong on purpose.** Half your value is mumbling, rephrasing and
  stopping mid-sentence. Perfect diction finds nothing.
- **Stay in your pack.** Anything you notice outside it: one line, then move
  on. Don't chase it.
- **Record what passed, not only what failed.** Tick the coverage list at the
  end of your pack. "Nobody tested that" and "someone tested it and it was
  fine" look identical in a bug list, and only one of them is safe.

## How to report what you find

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
existed on one GPU family only and would have been dismissed as "works on
mine" without the model written down. A bug that happens once and a bug that
happens every time are different bugs.

### Severity

Mark each finding with one of these. It decides what gets fixed first.

- **BLOCKS** — a blind user cannot complete the task at all, or the app does
  something harmful (sends what you cancelled, routes you the wrong way,
  saves a wrong phone number silently).
- **HURTS** — the task is completable but painful: several retries, a
  phrasing that should work and doesn't, something you only got past because
  you can see the screen.
- **NOTE** — cosmetic, or a suggestion.

The middle one is the category people under-report. If you found yourself
looking at the screen to get past something, that is a **HURTS**, even if it
worked.
