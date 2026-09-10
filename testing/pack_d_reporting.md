# Pack D — Asking for help, and flagging trouble

**Modules 2 and 5 · hazard reporting, passer-by helper, caretaker side**
**Budget: about 3.5 hours, plus one session with a second phone**

## What you own

Hazard reporting, the passer-by helper screen, and the caretaker half of the
app — the paired dashboard, remote settings, and the alert list.

Everything here is either **shown to a stranger or sent to another person**,
so the cost of getting it wrong is different from the rest of the app. A
wrong hazard report closes a road for every other user; a garbled passer-by
message is held up to someone in the street by the one person present who
cannot see what it says.

You will need a second phone for Parts 4 and 5. Coordinate with Pack A, who
also needs one.

---

## Skipping onboarding

You are not testing onboarding — Pack A is. Sitting through the full
accessibility interview every time you reinstall is a waste of your round.

On the **first onboarding screen** there is a **⏩ button in the top-right
corner**. Tap it. It fills in a complete dummy profile and drops you
straight on the dashboard.

Two things it leaves **switched off**, because they would otherwise fire
constantly on a test device:

- **"Hey Jarvis"** — the wake word. Turn it on by saying
  `turn on hey jarvis` if you need it.
- **Automatic listening** — the mic reopening after each reply. Turn it on
  by saying `turn on auto listen`.

The wake phrase is **"Hey Jarvis"**, not "Hey ANT". That is a placeholder
model we have not replaced yet, so it really is Jarvis.

---

## Part 1 — Filing reports

1. File a hazard by voice, start to finish, **without touching the screen**.
   Say `send` to submit.
2. The same in **Bangla**, saying `পাঠাও`.
3. File one where you **name the hazard up front** — `there's an open
   manhole` — and check it skips straight past the menus.
4. Do that for **all fifteen named shortcuts** in the phrasebook. Note which
   ones don't jump straight to the form.
5. Navigate the menus **by voice only**, saying the category then the
   sub-category name, for all three categories.
6. Use **Something else** and describe a hazard in your own words.
7. File a report while **walking**, outdoors, with traffic noise.
8. File one with the screen **off**, using the wake word to start.

## Part 2 — Describing, and the words that end it

9. Describe a hazard across **three separate utterances with pauses** — stop,
   think, continue. All of it should be kept.
10. Try every submit word: `send`, `send it`, `submit`, `submit report`,
    `done`, `finish` — and `পাঠাও`, `সাবমিট`, `সেন্ড`, `শেষ`, `হয়ে গেছে`.
11. Use the word **"send" in the middle of a sentence** — "someone tried to
    send me down the alley" — and confirm it does not submit early. This
    misfiring is a **BLOCKS**.
12. Do the same with `শেষ` mid-sentence in Bangla.
13. Say a submit word **before describing anything** on a category that
    needs a description. It should not file an empty report.

## Part 3 — The cancel window

After you submit, it reads the report back and waits five seconds.

14. Say `cancel`. Nothing should be filed. Verify it wasn't.
15. Say `stop`, `wait`, `don't send` — each should also cancel.
16. Say `বাতিল`, `থামো`, `দাঁড়াও`.
17. Say `change it`. You should get another go, **with the old text
    cleared**.
18. Say `that's wrong`, `edit`, `say again`, `বদলাও`, `ভুল`.
19. Say **nothing at all**. It should send on its own.
20. Say **"no"** and confirm it does **not** cancel — this is deliberate, and
    we want to know if it feels wrong to you as a user.
21. Say something unrelated during the window — "okay", "thanks", "hmm" —
    and confirm it still sends.
22. **Leave the screen** during the window. Nothing should be filed.
23. Check whether the buzz at the start of the window feels different from
    the "your turn to speak" buzz. If you can't tell them apart, say so.

## Part 4 — Confirmation and escalation

24. File **the same hazard from three different phones** at the same spot,
    within a day. It should escalate to a confirmed hazard. Coordinate with
    Packs A and C.
25. Have **Pack C walk a route through it** and confirm they are warned.
26. Say a hazard is resolved: `it's fixed`, `the broken ramp is fixed`,
    `it's been repaired`, `the path is clear`, `আর নেই`, `ঠিক হয়ে গেছে`.
27. Confirm a report you filed is **visible somewhere afterwards**. If you
    cannot find it at all, that is a finding.

## Part 5 — The passer-by helper

28. Open it by voice and pick a **prepared message**.
29. **Dictate a new message** and show that.

**New in round 2 — the order changed.** It now tells you what the screen is
for *before* opening the mic, because it used to open the mic underneath its
own announcement and stop hearing you.

29a. Open it and **listen without speaking**. It should say what the screen
    does and what to say, and only then open the mic. If the mic opens while
    it is still talking, that is the bug returning.
29b. Open it, say nothing at all, and see what ends up in the message box. It
    must be **empty** — it used to transcribe the tail of its own prompt
    ("What you need?") and show that to the passer-by.
29c. Say `show it` **with nothing dictated**. It should say it has no message
    yet and ask you for one. It used to repeat the same prompt forever.
29d. Dictate, say `show it`, and let the cancel window run out. Confirm the
    screen actually appears.
30. **Actually show it to someone who doesn't know the app.** Watch whether
    they understand what to do — **their reaction is the result**, not your
    opinion of the screen. Do this with at least **three different people**,
    ideally one who reads Bangla only.
31. Note what each person did: did they read it? hesitate? hand it back? ask
    you something? Write down their first reaction verbatim.
32. Check it is **readable at arm's length** in daylight, and at night.
33. Dictate a message and use the cancel window on it too.

## Part 5b — Narration stops with the screen (new)

A screen's voice now belongs to that screen.

33a. Open the passer-by helper and **close it while it is still talking**. The
    voice must stop with it, not carry on over the dashboard.
33b. Do the same with the hazard reporting hub, mid-sentence.
33c. Confirm the message you were shown is not left half-spoken when you go
    back.

## Part 5c — Saved places in settings (new)

34a. Open **My Settings** and find the saved-places list. It is new — before
    this, saved places could only be reached by voice, so a wrong one could
    not be seen or removed.
34b. Delete one and confirm it is gone, and that routing to it no longer works.

## Part 6 — The caretaker side

34. Pair with a disabled-user phone (Pack A can do the other half).
35. **Change a setting remotely** and confirm it lands on the other device,
    and that the other device says so out loud.
36. Try to change the setting **from both phones at once**.
37. Set the disabled user's profile to **Bangla** and check the caretaker
    screens — are they in Bangla, or still English? Every screen.
38. Check the alert list and the location view. Note anything that is empty,
    stale, or clearly not implemented yet.
39. Unpair, or try to, and note what happens.

---

## Hunt for

- A command word ending up **inside the description text** instead of acting
  on it.
- Anything filed that you did not confirm, or a `cancel` that did not
  cancel. Either is a **BLOCKS**.
- The five-second window feeling **too short to react to** — say so if it
  does, with what you were trying to say.
- The stranger hesitating, looking confused, or handing the phone straight
  back.
- Caretaker screens still in English when the profile is Bangla.
- A report you filed that you cannot find anywhere afterwards.
- Anything in the caretaker half that looks finished but does nothing.

## Passes if

You filed, cancelled, edited and resolved reports **entirely by voice** in
both languages, three separate people understood the passer-by screen with
no explanation, and a remote setting change from a caretaker phone reached
the other device.

## Coverage — tick what you actually did

- [ ] Show Screen narrated before opening the mic
- [ ] Said nothing — message box stayed empty
- [ ] "show it" with nothing dictated said what was missing, did not loop
- [ ] Dictated, said "show it", screen actually appeared
- [ ] Closed a screen mid-sentence, voice stopped with it
- [ ] Saved places list found in settings, delete worked

- [ ] Report by voice, English, no touching
- [ ] Report by voice, Bangla
- [ ] All fifteen named shortcuts
- [ ] Menus navigated by voice, all three categories
- [ ] "Something else" free description
- [ ] Report while walking outdoors
- [ ] Report with screen off, started by wake word
- [ ] Description across three pauses
- [ ] All submit words, both languages
- [ ] "send" mid-sentence does not submit
- [ ] Cancel window: cancel / stop / wait / don't send
- [ ] Cancel window: Bangla cancel words
- [ ] Cancel window: change it / that's wrong / edit
- [ ] Cancel window: silence sends
- [ ] Cancel window: "no" does not cancel
- [ ] Cancel window: leaving the screen
- [ ] Three-reporter escalation (with Packs A and C)
- [ ] Pack C warned on route
- [ ] Hazard resolved by voice
- [ ] Passer-by: prepared message
- [ ] Passer-by: dictated message
- [ ] Passer-by shown to 3 real strangers — reactions written down
- [ ] Caretaker: remote setting change
- [ ] Caretaker: simultaneous change from both phones
- [ ] Caretaker: every screen checked in Bangla
- [ ] Caretaker: alerts and location view

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
