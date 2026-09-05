# Pack B — Saying things the app didn't expect

**Module 3 · voice commands, the assistant, the wake word**
**Budget: about 4 hours — the largest pack, and the most mechanical**

## What you own

Every spoken command on the dashboard, the wake word, and the boundary
between what the phone handles instantly and what gets sent to the AI.

Work from the [voice phrasebook](../README.md), but understand what your job
actually is: the phrasings that are **not** in it. The listed phrases are
examples of a shape, not passwords, and the app is supposed to cope with
however you naturally say it. Finding where it doesn't is the whole pack.

Use the ⏩ button on the first onboarding screen to skip setup.

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

18. Say `Hey Jarvis` **ten times over ten minutes**, doing other things in
    between. Count how many worked. This is a regression check for a bug
    where it fired once and never again.
19. From **across a room**, from **a pocket**, with a **TV or music
    playing**, and **outdoors**.
20. Say it **twice in quick succession**.
21. Say something that sounds similar but isn't — "hey Jarvis" vs "hey
    Travis", "হেই জার্ভিস" — and note false triggers.
22. Turn the wake word **off by voice**, confirm it stops responding, turn
    it back on.
23. Lock the screen and say it.

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

## Part 7 — Saved places

34. Route to each saved kind using **every synonym** in the phrasebook —
    home/house/my place, work/office/job, school/college/campus, and the
    family words.
35. Add a saved place by voice, then route to it.
36. Set up **two saved places with similar names** and confirm it asks
    rather than guessing.

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

## Coverage — tick what you actually did

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

Keep the [voice phrasebook](../README.md) open while you work; it lists every
phrase the app accepts on purpose.

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
