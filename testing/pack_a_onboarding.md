# Pack A — Setup, entirely by voice

**Modules 1 · onboarding and caretaker pairing**

## What you own

The full setup interview, from choosing a language to the final lock-in,
including caretaker pairing and the spoken command tour at the end.

This is the longest uninterrupted stretch of voice interaction in the app,
and the one place a user cannot skip past a mistake. After lock-in the
settings screens disappear for good, so anything set wrong here is set wrong
by voice only from then on.

## Runs

1. **Screen off, or eyes closed. Not negotiable.** Complete the whole
   interview without looking once. If you get stuck, note exactly which
   question stranded you — that is the finding.
2. Repeat the whole thing in Bangla, again without looking.
3. Dictate an emergency contact's phone number and **deliberately let it
   mishear a digit** — say it fast, or over noise. Confirm the read-back
   catches it, and that saying no lets you dictate it again.
4. Pair with a caretaker. Needs a second phone — borrow one from Pack C or D.
   **Read the six-digit code aloud** rather than typing it.
5. Kill the app halfway through the interview and reopen it. You should
   resume where you were, not start again.
6. Reach the command tour at the end. Say `hear it again`, listen, then
   continue. Then try one command it taught you on the dashboard and confirm
   it actually works.

## Hunt for

- A question that **re-reads itself after you have already answered it**. To
  someone who can't see the screen this is indistinguishable from the
  previous screen coming back.
- Answering with a full sentence instead of the exact option — "I can't hear
  very well" rather than "deaf". Does it understand you?
- Bangla numbers spoken as `শূন্য এক সাত` instead of English digits.
- Any point where **the app goes quiet and never re-opens the mic**. Note
  what you said immediately before it happened.
- A value that gets saved **without being read back to you first**. There
  should be none.
- The read-back reading a phone number as one enormous number rather than
  digit by digit.

## Passes if

You finished setup twice without opening your eyes, and every number and
name you spoke was read back to you before it was stored.

## Before you start

Get the app through **Firebase App Distribution** — you need an Android
phone, the email you were invited on, and a network connection. No computer,
no cable, no developer mode. Details in the [root README](../README.md).

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
