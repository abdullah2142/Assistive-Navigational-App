# Pack B — Saying things the app didn't expect

**Module 3 · voice commands and the AI assistant**

## What you own

Every spoken command on the dashboard, and the boundary between what the
phone handles instantly and what gets sent to the AI.

Work from the voice phrasebook, but understand what your job actually is:
the phrasings that are **not** in it. The listed phrases are examples of a
shape, not passwords, and the app is supposed to cope with however you
naturally say it. Finding where it doesn't is the whole pack.

Use the ⏩ button on the first onboarding screen to skip setup — you don't
need to sit through the interview.

## Runs

1. Every command in the phrasebook, once, to confirm the baseline works.
2. Now **rephrase every one of them into your own words** and try again.
   This is the actual test; step 1 was just the warm-up.
3. Chain adjustments: `make the text bigger`, then `even bigger`, then
   `a bit more`.
4. Say the same commands in Bangla with the words in a different order, and
   with case endings attached — `গুলশানে` as well as `গুলশান`.
5. Ask **questions** that contain command words, and confirm nothing
   happens:
   - `should I go to Uttara?`
   - `is it getting dark?`
   - `is there a manhole near here?`
   - `আমি অফিসে যাব না`
6. Say something genuinely ambiguous and watch whether the assistant asks or
   guesses. **Guessing is the bug**, even when it guesses right.
7. Roughly time each command. Flag anything that feels slow — instant and
   "a second or two" are different code paths, and something in the second
   group may belong in the first.

## Hunt for

- A phrasing an ordinary person would obviously use that **isn't
  understood**. Write down your exact words.
- Worse: a phrasing that does **the wrong thing** rather than nothing.
- English words spoken inside a Bangla sentence, and the reverse. Dhaka
  speech mixes constantly and the app has to cope.
- Negatives being ignored. `আমি অফিসে যাব না` must not start a route.
- The app failing to understand you twice **without then offering a short
  phrase that always works**. It is supposed to give you a way out.

## Passes if

You can operate every dashboard function using words you chose yourself,
without having memorised anything.

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
