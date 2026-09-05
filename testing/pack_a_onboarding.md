# Pack A — Setup, entirely by voice

**Modules 1 · onboarding, pairing, the command tour**
**Budget: about 3 hours, across two sittings**

## What you own

The full setup interview, from choosing a language to the final lock-in,
including caretaker pairing and the spoken command tour at the end.

This is the longest uninterrupted stretch of voice interaction in the app,
and the one place a user cannot skip past a mistake. After lock-in the
settings screens disappear for good, so anything set wrong here is set wrong
by voice only from then on.

You will run the interview **at least four times**. That is not repetition
for its own sake — each run below changes one thing that the interview has
to survive.

---

## Part 1 — The interview, straight through

1. **Screen off, or eyes closed. Not negotiable.** Complete the whole
   interview without looking once. If you get stuck, note exactly which
   question stranded you — that is the finding.
2. Repeat the whole thing **in Bangla**, again without looking.
3. Run it once **outdoors with traffic noise**. Note every question that
   needed more than two attempts.
4. Run it once **speaking unusually fast**, and once **slowly with long
   pauses mid-sentence**. Both are how real people under stress talk.

## Part 2 — Answering the way people actually answer

The interview offers you options. Nobody repeats options verbatim.

5. Answer each question with **a full sentence instead of the option** —
   "I can't really see anything at all" rather than "no vision", "I use a
   stick to get around" rather than "white cane".
6. Answer **before the narration finishes**. Does it hear you, or does it
   talk over you and miss it?
7. Answer with a **synonym it never offered you**. Write down which ones
   worked and which didn't — this list is directly useful to us.
8. Give a **deliberately ambiguous answer** ("sometimes", "it depends") and
   see whether it asks again or picks one.
9. Say **nothing at all** for a full question. Does it re-prompt, re-read
   the options, and eventually help you — or go silent?

## Part 3 — Numbers and names, where mistakes are permanent

10. Dictate an emergency contact's phone number and **deliberately let it
    mishear a digit** — say it fast, or over noise. Confirm the read-back
    catches it, and that saying no lets you dictate it again.
11. Dictate a number using **Bengali numerals** — `শূন্য এক সাত এক এক...` —
    and confirm the read-back is right.
12. Dictate a **name that is not a common English word** (a relative's real
    name). Check what the read-back says.
13. Confirm the read-back reads digits **in groups, not as one huge
    number**. "Zero one seven one two..." is correct; "one billion seven
    hundred and twelve million..." is a bug.
14. Say **no** to a read-back three times in a row. Does it keep letting you
    retry, or give up on you?

## Part 4 — Pairing

Needs a second phone. Borrow one from Pack C or D and agree a time.

15. Pair with a caretaker, **reading the six-digit code aloud** rather than
    typing it.
16. Try a **wrong code** and confirm the error is spoken, not just shown.
17. Try an **already-used code** and confirm you're told that specifically.
18. Have the caretaker generate a code and leave it for **over an hour**,
    then try it.

## Part 5 — Interruptions and failure

19. **Kill the app halfway** through the interview and reopen it. You should
    resume where you were, not start again.
20. Put the phone in **airplane mode** mid-interview, answer a question, then
    turn it back on. Is anything lost? Are you told?
21. Take a **phone call** mid-question and come back.
22. **Deny the microphone permission** at the start and complete as much as
    you can. Everything should still be reachable by touch, and you should be
    told why the voice isn't working.
23. Turn narration **off** with the speaker button in the corner, then back
    on, and confirm both take effect immediately.

## Part 6 — The command tour

24. Reach the command tour at the end. Say `hear it again`, listen fully,
    then continue.
25. Say `I am ready`, `ready`, `next`, `ok`, `got it` — confirm each moves on.
26. **Take every example it teaches you and try it on the dashboard.** If the
    tour teaches a phrase the app doesn't accept, that is the most serious
    kind of bug in this pack: we told a blind user to say something that
    doesn't work.
27. Reach lock-in, confirm, and check the summary it reads back matches what
    you actually chose.

---

## Hunt for

- A question that **re-reads itself after you have already answered it**. To
  someone who can't see the screen this is indistinguishable from the
  previous screen coming back.
- Any point where **the app goes quiet and never re-opens the mic**. Note
  what you said immediately before it happened.
- A value saved **without being read back to you first**. There should be
  none, anywhere.
- The interview accepting an answer you didn't give — especially on the
  hearing question, where "I can't hear well" and "I hear fine" are one word
  apart.
- Numbers coming back with a digit missing, and the read-back not noticing.
- Anything that only worked because you could see the screen.

## Passes if

You finished setup **four times with your eyes closed** — twice in each
language, once outdoors — every number and name you spoke was read back
before it was stored, and every phrase the command tour taught you actually
worked on the dashboard.

## Coverage — tick what you actually did

- [ ] English, eyes closed, indoors
- [ ] Bangla, eyes closed, indoors
- [ ] Outdoors with traffic noise
- [ ] Fast speech / slow speech with pauses
- [ ] Full-sentence answers instead of options
- [ ] Barge-in during narration
- [ ] Silence on a question
- [ ] Phone number with a deliberate mishear
- [ ] Bengali numerals
- [ ] Rejecting a read-back three times
- [ ] Pairing: good code, wrong code, used code, expired code
- [ ] App killed mid-interview
- [ ] Airplane mode mid-interview
- [ ] Microphone permission denied
- [ ] Narration toggled off and on
- [ ] Command tour repeated, then every taught phrase tried

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
