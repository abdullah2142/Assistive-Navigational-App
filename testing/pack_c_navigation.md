# Pack C — Actually walking somewhere

**Modules 4 and 7 · routing, map, route safety, haptics**

## What you own

Everything from "take me to X" through to arrival: destination lookup, the
safety scoring that steers around bad areas, the map, spoken turn-by-turn,
and the vibration cues.

**This pack has to be done outdoors, walking.** Nothing in it can be tested
sitting down, and results from a desk are worse than no results because they
look like coverage.

## Runs

1. Route somewhere **ten minutes away on foot** and walk the whole thing,
   following only what you hear.
2. Do one full walk with **the phone in your pocket and the screen off**.
   Turn cues must still reach you.
3. **Deliberately walk the wrong way** at a turn. How long before it
   notices, and what does it say when it does?
4. Ask for somewhere vague — `the eye hospital`, `that big market` — and
   judge whether the questions it asks actually narrow it down, or just
   repeat themselves.
5. Ask for a place that does not exist. It should say so, not quietly route
   you somewhere approximate.
6. Route to the same place at night and in daylight. Note whether the route
   differs, and whether the difference makes sense to you.
7. Walk somewhere with poor GPS — a covered market, a narrow lane between
   tall buildings. Note what it does as the fix degrades.

## Hunt for

- A turn announced **too late to act on**, or after you have already passed
  it.
- "Arrived" while you are visibly not there.
- The map not centred on you, or not following as you walk.
- Vibration patterns you **cannot tell apart through a pocket**. This
  matters more than it sounds — for some users it is the only channel.
- Any route through somewhere you personally consider unsafe at that hour.
  **Name the road.** Local knowledge is the thing none of us can get from
  the data.
- Distances that do not match reality — "in fifty metres" when it is clearly
  two hundred.

## Passes if

You completed a real walk to a real destination using only audio and
vibration, and every turn arrived in time for you to take it.

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
