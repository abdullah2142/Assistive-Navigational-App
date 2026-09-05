# Pack C — Actually walking somewhere

**Modules 4 and 7 · routing, map, route safety, haptics**
**Budget: about 4 hours, and most of it outdoors on your feet**

## What you own

Everything from "take me to X" through to arrival: destination lookup, the
safety scoring that steers around bad areas, the map, spoken turn-by-turn,
and the vibration cues.

**This pack has to be done outdoors, walking.** Nothing in it can be tested
sitting down, and results from a desk are worse than no results because they
look like coverage. Plan on at least **four real walks**, one of them after
dark.

Take a power bank. You are also measuring battery.

---

## Part 1 — Real walks

1. Route somewhere **ten minutes away on foot** and walk the whole thing,
   following only what you hear. English.
2. The same walk again **in Bangla**.
3. A walk with **the phone in your pocket and the screen off** the entire
   time. Turn cues must still reach you.
4. A walk **after dark**, and note whether the route differs from the
   daytime one to the same place.
5. One walk where you **do not look at the phone once**, start to finish.
   Have someone with you for safety.

## Part 2 — When you leave the route

6. **Deliberately walk the wrong way** at a turn. Time how long before it
   notices and write the number down.
7. Keep going wrong for two more minutes. Does it re-plan from where you
   are, or try to walk you back?
8. Stop dead for three minutes mid-route, then continue.
9. **Take a genuinely better shortcut** it didn't suggest and see how it
   copes.
10. Go into a building and come out of a different exit.

## Part 3 — Finding the destination

11. Ask for somewhere **vague** — `the eye hospital`, `that big market`,
    `the nearest pharmacy`. Judge whether its questions actually narrow
    things down or just repeat.
12. Answer its questions **with an area**, then with **a landmark**.
13. Pick from the offered list by **ordinal** (`the first one`, `number
    two`), by **bare number** (`two`), and by **saying a word from the
    option itself**.
14. Say `cancel` / `never mind` / `বাদ দাও` partway through the questions.
15. Ask for a place that **does not exist**. It must say so, not quietly
    route you somewhere approximate. Quietly approximating is a **BLOCKS**.
16. Ask for somewhere **very far away** — another district — and see what it
    does with a walking route it cannot reasonably offer.
17. When it does find a hard-to-describe place, accept its offer to **save
    it**, then route there again by name.

## Part 4 — Timing of the cues

This is the part most likely to be wrong in a way that matters.

18. For every turn on one walk, note **where you were when each cue came**:
    the 200 m one, the 50 m one, the 25 m one, and "now".
19. Flag any turn announced **too late to act on**, or after you passed it.
20. Check the **distances against reality**. "In fifty metres" when it is
    clearly two hundred is a finding.
21. Walk a stretch with **turns close together** and see whether the cues
    overlap or queue sensibly.
22. Check what it says at **arrival**, and whether you are actually there.

## Part 5 — Vibration

23. With the phone **in your pocket**, can you tell the three patterns
    apart — turn coming, turn now, hazard? Answer honestly; for some users
    this is the only channel.
24. Same test **in a bag**.
25. Same test **while walking on a rough footpath**, where your whole body is
    already being jostled.
26. Does the buzz for "your turn to speak" feel clearly different from the
    navigation cues?

## Part 6 — Hard conditions

27. Walk somewhere with **poor GPS** — a covered market, a narrow lane
    between tall buildings. Note what it does as the fix degrades.
28. Walk with **mobile data off** and see how far you get.
29. Walk in **rain** if you get the chance, with wet hands.
30. Let the battery get **below 20%** and see whether anything changes.
31. Measure **battery used over a 30-minute walk** with the screen off. Write
    the number down — a navigation app a blind user cannot trust to last the
    trip is not usable regardless of how good the directions are.

## Part 7 — Safety routing

32. Route through an area **you personally know to be rough at night**, after
    dark. Does it avoid it, warn you, or route you straight through?
33. Have Pack D file a hazard on a route you are about to walk, then walk it
    and confirm you are **warned before you reach it**.
34. Compare the same route at 2pm and 10pm and describe the difference.

## Part 8 — The map

35. Confirm the map **shows streets, not a blank panel** — on your phone
    specifically. Say what model it is either way.
36. Confirm it is **centred on you** and follows as you walk.
37. Confirm you can read the street names at your normal text size.
38. Open the full-screen map and come back.

---

## Hunt for

- A turn announced **too late to act on**.
- "Arrived" while you are visibly not there.
- The map blank, not centred, or not following.
- Vibration patterns you **cannot tell apart** through a pocket.
- Any route through somewhere you consider unsafe at that hour. **Name the
  road.** Local knowledge is the thing none of us can get from the data.
- Distances that do not match reality.
- Cues that stop arriving once the screen has been off for a while.

## Passes if

You completed **four real walks**, one after dark and one with the phone
pocketed and screen off, using only audio and vibration — and every turn
arrived in time for you to take it.

## Coverage — tick what you actually did

- [ ] Walk 1: English, screen on
- [ ] Walk 2: Bangla
- [ ] Walk 3: pocket, screen off
- [ ] Walk 4: after dark
- [ ] A walk without looking at the phone at all
- [ ] Deliberate wrong turn, timed
- [ ] Sustained off-route / re-plan
- [ ] Stopping for several minutes mid-route
- [ ] Vague destination, narrowed by questions
- [ ] Option picked by ordinal, by bare number, by word
- [ ] Cancelled the clarification
- [ ] Non-existent place
- [ ] Very distant place
- [ ] Saved a clarified place and re-routed to it
- [ ] Cue distances checked against reality
- [ ] Turns close together
- [ ] Vibration told apart: pocket, bag, rough ground
- [ ] Poor GPS
- [ ] Mobile data off
- [ ] Low battery
- [ ] Battery used over 30 minutes: ______ %
- [ ] Night vs day route compared
- [ ] Hazard warning received on route (with Pack D)
- [ ] Map renders on my phone: model ____________

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
