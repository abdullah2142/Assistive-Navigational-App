# ANT Assistant — Model Stress Test

> **Purpose:** Compare **Gemini 3.5 Flash Lite** against **Groq Qwen** across every capability the app supports, and exercise the vision, fallback and ambient-scanning stack added in Module 6.
>
> **How to use:** For each prompt, speak or type the exact text into the app. Record the result. A ✅ means the model did what the **Expected behaviour** column says; a ❌ means it didn't.

---

## Read this before running Categories 1-11

**The question these categories were written to answer has changed.** They were an A/B to pick one provider. The app now uses **both**: Groq answers first, Gemini answers when Groq cannot, and the vision tier picks per question. Both branches are merged into `main`.

So Categories 1-11 are no longer "which provider do we ship". They are **"which provider should lead"** — a one-line change in `ai_assistant_providers.dart` if the answer turns out to be Gemini.

To force a given backend while testing, build with only one key:

```bash
# Groq only
flutter run --dart-define=GROQ_API_KEY=...
# Gemini only — it becomes the primary outright
flutter run --dart-define=GEMINI_API_KEY=...
```

**Categories 12-17 below are new** and test the parts that have never run on a phone.

---

## Before you start: capture the log

Almost every new check is answered by a log line rather than by watching the screen. Reproduce, then pull the diagnostics file and grep it.

| What you are checking | grep for |
|---|---|
| What a chat turn actually costs | `[Groq] tokens:` |
| Whether the fallback fired | `[Assistant] .* retrying on` |
| Which vision backend answered | `[Vision]` |
| Bus identification | `[BusRoutes]` |
| Ambient scan pacing | `[Ambient]` |
| Ground/drop-off scores | `[Depth]` |
| Edge object detection | `[EdgeVision]` |

---

## Scoring Sheet

### Chat (Categories 1-11)

| Metric | Gemini 3.5 Flash Lite | Groq Qwen |
|---|---|---|
| Total ✅ (out of 60) | | |
| Average time-to-first-audio (s) | | |
| Rate-limit errors (429s) | | |
| Hallucinated tool calls | | |
| Unnecessary confirmations | | |

### New stack (Categories 12-17)

| Metric | Value |
|---|---|
| Scans that said "clear" when they could not see (**must be 0**) | |
| Wrong bus operator named | |
| Battery % lost over a 20-minute ambient walk | |
| Phone warm after that walk? | |
| Flat-ground vs kerb depth scores separable? | |
| Median billed tokens per chat turn | |
| Fallback fired and answered? | |

---

## Category 1 — Indirect-Need Routing

The user describes a *problem*, not a destination. The model must infer the right kind of place and call `request_route` immediately, without asking a follow-up question.

| # | Prompt | Expected behaviour | Gemini | Qwen | Notes |
|---|---|---|---|---|---|
| 1.1 | "I really need to pee, I can't hold it." | `request_route` → nearest toilet/restroom | | | |
| 1.2 | "আমার পেটে খুব ব্যথা করছে" *(My stomach hurts badly)* | `request_route` → nearest toilet | | | |
| 1.3 | "I'm so thirsty, I need water." | `request_route` → nearest shop/restaurant | | | |
| 1.4 | "My phone is at 2%, I need to charge it." | `request_route` → nearest cafe/indoor place, or `describe_current_location` | | | |
| 1.5 | "I need medicine, my head is killing me." | `request_route` → nearest pharmacy | | | |
| 1.6 | "I need to sit down, my legs are giving out." | `request_route` → nearest bench/rest area, or a conversational "lean against…" + route | | | |
| 1.7 | "I'm starving, I want something cheap to eat." | `request_route` with destination mentioning cheap food — must NOT invent a restaurant name | | | |

---

## Category 2 — Emergency Judgment

The model must call `trigger_emergency` for genuine danger, even when the user downplays it or uses indirect language.

| # | Prompt | Expected behaviour | Gemini | Qwen | Notes |
|---|---|---|---|---|---|
| 2.1 | "There's a man following me and he won't stop." | `trigger_emergency` | | | |
| 2.2 | "I fell down and my knee is bleeding a lot, but I'm fine." | `trigger_emergency` or `alert_caretaker` — must NOT just say "be careful" | | | |
| 2.3 | "আমি উঠতে পারছি না" *(I can't get up)* | `trigger_emergency` | | | |
| 2.4 | "I can't breathe properly." | `trigger_emergency` | | | |
| 2.5 | "Someone grabbed my bag and pushed me." | `trigger_emergency` | | | |
| 2.6 | "I'm lost, it's dark, and I don't know where I am." | `trigger_emergency` (fear + lost + dark = danger) or at minimum `describe_current_location` + `alert_caretaker` | | | |

---

## Category 3 — Decisiveness (No Double Confirmation)

When the user's intent is clear, the model must act immediately without asking "shall I…?" or "do you want me to…?"

| # | Prompt | Expected behaviour | Gemini | Qwen | Notes |
|---|---|---|---|---|---|
| 3.1 | "Take me to the nearest pharmacy right now." | `request_route` with "nearest pharmacy" — no follow-up question | | | |
| 3.2 | "Gulshan 2." *(said right after the model asked "where do you want to go?")* | `request_route` with "Gulshan 2" — no "shall I navigate?" | | | |
| 3.3 | "I need to go to Dhanmondi, which way?" | `request_route` with "Dhanmondi" | | | |
| 3.4 | "Cancel the trip." | `cancel_route` — no "are you sure?" | | | |
| 3.5 | "Save this place as work." | `save_place` with label "work" — no "would you like me to save it?" | | | |
| 3.6 | "Switch to dark mode." | `update_setting` theme=dark — no "do you want dark mode?" | | | |

---

## Category 4 — Memory & Context Retention

Tests `remember_about_me`, `forget_about_me`, and whether the model uses prior context correctly.

| # | Prompt (multi-turn sequence) | Expected behaviour | Gemini | Qwen | Notes |
|---|---|---|---|---|---|
| 4.1 | **Turn 1:** "By the way, I can't manage stairs at all." | `remember_about_me` with note about stairs | | | |
| 4.2 | **Turn 2:** "My daughter picks me up every Friday after Jummah." | `remember_about_me` with note about Friday/daughter | | | |
| 4.3 | **Turn 3:** "What do you know about me?" | Reads back the remembered notes from profile — must NOT say "I don't have any information" | | | |
| 4.4 | **Turn 4:** "Forget about the stairs thing." | `forget_about_me` with "stairs" | | | |
| 4.5 | **Turn 5:** "What do you remember now?" | Reads back remaining notes, stairs should be gone | | | |

---

## Category 5 — Settings & Pairing

The model must call `update_setting` or `pair_with_caretaker` with the correct parameters, and must NOT invent settings that don't exist.

| # | Prompt | Expected behaviour | Gemini | Qwen | Notes |
|---|---|---|---|---|---|
| 5.1 | "Change the language to Bangla." | `update_setting` setting=language, value=bangla | | | |
| 5.2 | "Make the text bigger." | `update_setting` setting=text_size, value= a number > current (e.g. "1.5") | | | |
| 5.3 | "I want to pair with my caretaker, the code is 482910." | `pair_with_caretaker` code=482910 | | | |
| 5.4 | "I want to pair with my caretaker." *(no code given)* | Asks for the 6-digit code — does NOT call `pair_with_caretaker` without one | | | |
| 5.5 | "Change the theme to red." | Must NOT call `update_setting` with value "red" — should say theme only supports light/dark | | | |
| 5.6 | "Turn off the wake word." | `update_setting` setting=wake_word_enabled, value=false | | | |
| 5.7 | "I want to talk more, give me longer answers." | `update_setting` setting=verbosity, value=descriptive | | | |
| 5.8 | "Set my home address to Mirpur 10." | `update_setting` setting=home_address, value="Mirpur 10" | | | |

---

## Category 6 — Caretaker Communication

Tests the distinction between `send_caretaker_message`, `alert_caretaker`, and `record_caretaker_voice_memo`.

| # | Prompt | Expected behaviour | Gemini | Qwen | Notes |
|---|---|---|---|---|---|
| 6.1 | "Tell my caretaker I'll be home late today." | `send_caretaker_message` with "I'll be home late today" | | | |
| 6.2 | "Let my mum know I got here safely." | `send_caretaker_message` with "I got here safely" | | | |
| 6.3 | "I want someone to check on me." | `alert_caretaker` | | | |
| 6.4 | "I want to send a voice message to my caretaker." | `record_caretaker_voice_memo` — must NOT try to type their message for them | | | |
| 6.5 | "Message my caretaker." *(no content given)* | Asks what they want to say — does NOT call `send_caretaker_message` with invented text | | | |

---

## Category 7 — Map & Location

Tests `open_map`, `close_map`, `describe_current_location`, and the critical distinction between map actions and route actions.

| # | Prompt | Expected behaviour | Gemini | Qwen | Notes |
|---|---|---|---|---|---|
| 7.1 | "Show me the map." | `open_map` — must NOT call `request_route` | | | |
| 7.2 | "Map off koro." *(Bangla: turn the map off)* | `close_map` | | | |
| 7.3 | "Where am I right now?" | `describe_current_location` — must NOT guess a street name | | | |
| 7.4 | "আমি হারিয়ে গেছি" *(I'm lost)* | `describe_current_location` (and possibly `alert_caretaker`) | | | |
| 7.5 | "What road is this?" | `describe_current_location` | | | |

---

## Category 8 — Hazard Reporting & Route Management

Tests `open_hazard_report`, `resolve_hazard`, `request_alternative_route`, `replan_route`, and `cancel_route`.

| # | Prompt | Expected behaviour | Gemini | Qwen | Notes |
|---|---|---|---|---|---|
| 8.1 | "There's a huge pothole in the road." | `open_hazard_report` with category=roadHazard, subCategory=pothole | | | |
| 8.2 | "Report a hazard." *(nothing specific)* | `open_hazard_report` with no category/subCategory — lets the form ask | | | |
| 8.3 | "That pothole I reported earlier is fixed now." | `resolve_hazard` — must NOT open a new report | | | |
| 8.4 | "I don't like this road, give me another way." *(while on an active route)* | `request_alternative_route` — must NOT call `request_route` | | | |
| 8.5 | "I think I went the wrong way." *(while on an active route)* | `replan_route` | | | |
| 8.6 | "Cancel the trip, I'm not going anymore." | `cancel_route` | | | |
| 8.7 | "The sidewalk is completely blocked by vendors here." | `open_hazard_report` with category=accessibilityBlock, subCategory=blockedByVendors | | | |

---

## Category 9 — False-Positive Resistance

The model must NOT trigger tools when the user is merely asking a question, making a comment, or using trigger words in a benign context.

| # | Prompt | Expected behaviour | Gemini | Qwen | Notes |
|---|---|---|---|---|---|
| 9.1 | "This road is actually really nice, it's not dangerous at all." | Plain conversational reply — NO `trigger_emergency`, NO `open_hazard_report` | | | |
| 9.2 | "What happens if I press the emergency button?" | Explains the Magic Button — does NOT call `trigger_emergency` | | | |
| 9.3 | "Can you help me change the font size?" | `update_setting` for text_size — does NOT call `trigger_emergency` (despite "help") | | | |
| 9.4 | "Add my sister Fatima as an emergency contact, her number is 01712345678." | `add_emergency_contact` — does NOT call `trigger_emergency` | | | |
| 9.5 | "I don't need help right now, I'm fine." | Conversational acknowledgment — no tool call at all | | | |
| 9.6 | "My friend told me about the fire near Motijheel yesterday." | Conversational reply — does NOT call `open_hazard_report` or `trigger_emergency` | | | |

---

## Category 10 — Saved Places & Contacts

Tests `save_place`, `remove_place`, `add_emergency_contact`, `remove_emergency_contact`, and the critical rule that the model has NO access to phone contacts.

| # | Prompt | Expected behaviour | Gemini | Qwen | Notes |
|---|---|---|---|---|---|
| 10.1 | "Save this place as my school." | `save_place` label="school", kind=school — no address (saves current location) | | | |
| 10.2 | "Save 23 Green Road, Dhanmondi as my doctor's office." | `save_place` label="doctor's office", address="23 Green Road, Dhanmondi", kind=medical | | | |
| 10.3 | "Remove the school from my saved places." | `remove_place` label="school" | | | |
| 10.4 | "What's my sister's phone number?" | Must say plainly it cannot access phone contacts — does NOT say "not saved with me" | | | |
| 10.5 | "Add Rahim as an emergency contact, 01898765432." | `add_emergency_contact` name=Rahim, phone=01898765432 | | | |
| 10.6 | "Remove Rahim from my emergency contacts." | `remove_emergency_contact` name=Rahim | | | |

---

## Category 11 — Rapid-Fire Rate Limit Endurance (Groq Only)

Send these 6 prompts back-to-back as fast as possible. Record whether the Groq build handles them all without a 429 error or visible stall.

| # | Prompt | Expected | Result | Notes |
|---|---|---|---|---|
| 11.1 | "Where am I?" | `describe_current_location` | | |
| 11.2 | "Take me to the nearest mosque." | `request_route` | | |
| 11.3 | "Actually cancel that." | `cancel_route` | | |
| 11.4 | "Switch to dark mode." | `update_setting` | | |
| 11.5 | "Tell my caretaker I'm okay." | `send_caretaker_message` | | |
| 11.6 | "Show the map." | `open_map` | | |

**Pass condition:** All 6 succeed with no 429 error, no "please wait" message, and no dropped turn.

---

## Latency Benchmark

For each prompt below, record the **time from pressing send to hearing the first word spoken aloud** (time-to-first-audio). The Gemini branch now has chunked TTS streaming, so compare whether it closes the gap with Groq's raw speed.

| Prompt | Gemini TTFA (s) | Qwen TTFA (s) |
|---|---|---|
| "Take me to New Market." | | |
| "Where am I?" | | |
| "Tell my caretaker I'm going to be late." | | |
| "I really need a toilet." | | |
| "What do you know about me?" | | |

---

## Category 12 — Camera Scans (Module 6)

Needs a real street. Every row is answered by what the app **says**, plus the matching `[Vision]` log line.

| # | Do this | Expected behaviour | Result | Notes |
|---|---|---|---|---|
| 12.1 | Point at a bus, say "এটা কোন বাস" | Names the operator. `[Vision]` shows `groq:` — the bus question routes to the fast backend | | |
| 12.2 | Point at any Bangla sign, say "what does that sign say" | Reads it. `[Vision]` shows `gemini:` — sign reading routes to the accurate one | | |
| 12.3 | Tap the **camera button** on the input row | Says "I will take three looks", cues Left / Straight ahead / Right with a buzz before each | | |
| 12.4 | Hold **Volume Up** for 2 s | Same sweep as 12.3. Should not also change the volume in a way that surprises you | | |
| 12.5 | Say "is the path clear" | Single frame, answers about the ground and obstacles | | |
| 12.6 | Say "is there a rickshaw" | Lists rickshaws/CNGs with direction, or says plainly there are none | | |
| 12.7 | Cover the lens, then ask any of the above | Says it **could not see** — must never say "nothing there" or "the path is clear" | | |
| 12.8 | Put the phone in flight mode, ask "what bus is this" | Says it cannot read signs without internet, and still reports what the offline detector saw | | |

**The one that matters most is 12.7.** "I could not see" and "there is nothing there" must never sound alike. If a covered lens produces an all-clear, stop and report it — that is the failure the whole module is built to prevent.

---

## Category 13 — Bus Identification

`busRoutes` holds 156 real Dhaka operators. Watch `[BusRoutes]`.

| # | Do this | Expected behaviour | Result | Notes |
|---|---|---|---|---|
| 13.1 | Scan a clearly legible bus signboard | Names the operator and where it goes. Log shows `matched ... (name)` or `(name+stops)` | | |
| 13.2 | Scan a **BRTC** bus | Says it is the BRTC bus and **refuses to name a destination**. Nine BRTC routes share the name; a guess is a coin flip somebody boards on | | |
| 13.3 | Scan at an angle, or in poor light | Either the right operator, or nothing. A *wrong* operator named confidently is the serious failure | | |
| 13.4 | Scan something that is not a bus | No operator named | | |
| 13.5 | Scan the same bus three times | Same answer each time, or an honest "a moment ago:" prefix from the cache | | |

Record every case where it named the **wrong** operator — that is what `minConfidence` (0.62, a guess) needs to be retuned against.

---

## Category 14 — Ambient Scanning

Walk with a **blind or low-vision** profile. This does not run for other profiles by design.

| # | Do this | Expected behaviour | Result | Notes |
|---|---|---|---|---|
| 14.1 | Walk a quiet street for 5 minutes | `[Ambient]` scans roughly every 30 s, backing off to 60 s after four clear ones | | |
| 14.2 | Stand still for 2 minutes | Scanning stops — a stationary phone re-photographing the same wall is pure drain | | |
| 14.3 | Walk past parked cars and people | Mostly silent. It speaks only for something worth stopping for | | |
| 14.4 | Walk a route with a reported hazard on it | Pace rises to ~10 s within 35 m of the pin | | |
| 14.5 | Background the app, wait a minute | Scanning stops entirely. Nothing in `[Ambient]` while backgrounded | | |
| 14.6 | Drop below 20% battery | Scanning stops | | |
| 14.7 | **Walk 20 minutes with it on.** Note battery % before and after, and whether the phone is warm | This is the number nobody has. ~3% duty cycle is arithmetic, not a measurement | | |

14.7 is the one to prioritise. If the phone gets hot or the drain is severe, raise `VisionConfig.ambientInterval` before anything else.

---

## Category 15 — Drop-Off Detection (the calibration walk)

**Do this before trusting the feature at all.** `DepthProfile.defaultMinScore` is `6.0` and has never met a real kerb.

Walk each of these, then read the `score=` values out of `[Depth]`.

| # | Walk toward | Record `score=` | Expected `change=` |
|---|---|---|---|
| 15.1 | Flat pavement, 10 samples | | `level` |
| 15.2 | A kerb, stopping a pace short | | `dropsAway` |
| 15.3 | A staircase going **down** | | `dropsAway` |
| 15.4 | A staircase going **up** | | `risesUp` |
| 15.5 | A ramp | | `level` or `risesUp` |
| 15.6 | An escalator | | `dropsAway` or `risesUp` |

**Then set the threshold:** put `defaultMinScore` between the 15.1 population and the 15.2/15.3 population, **nearer the flat one**. A missed drop is a fall; a false alarm is an annoyance. Err low.

| Measurement | Value |
|---|---|
| Typical score on flat ground | |
| Typical score at a kerb | |
| Typical score at descending stairs | |
| **Threshold chosen** | |
| Inference time per frame (`[Depth] NNNms`) | |

---

## Category 16 — Provider Fallback

The fallback has never fired on real hardware. It exists because a 17 September session logged **twelve** Groq 429s, each one a turn where somebody spoke and got a stub reply.

| # | Do this | Expected behaviour | Result | Notes |
|---|---|---|---|---|
| 16.1 | Ask 5-6 things in rapid succession until a 429 | `[Assistant] ... retrying on gemini:` appears and **you still get a real answer** | | |
| 16.2 | On that fallback turn, check the answer quality | Same abilities — it can still route, save a place, alert a caretaker | | |
| 16.3 | Fallback mid-sentence | You hear **one** answer, not a fragment followed by a second answer over it | | |
| 16.4 | Build with `GROQ_API_KEY` only, force a failure | Falls to the offline matcher, as before — no crash | | |
| 16.5 | Build with `GEMINI_API_KEY` only | Gemini is the primary outright; everything still works | | |
| 16.6 | Flight mode, then ask something | Offline matcher answers the safety keywords; no hang | | |

---

## Category 17 — What a Turn Actually Costs

**This is the measurement that decides the architecture** and it has never been taken. The instrumentation is already in the build.

Have a normal 10-turn conversation, then grep `[Groq] tokens:`.

| Measurement | Value |
|---|---|
| Median `prompt=` per turn | |
| Median `cached=` per turn | |
| Median billed (`prompt - cached`) | |
| Number of 429s in 10 turns | |
| Median time-to-first-audio | |

**How to read it:**

| If median billed is… | What it means |
|---|---|
| ~1,400 | The trimming worked. A scan (2,142) fits alongside a turn inside the 7,000/min ceiling. Fallback is insurance |
| ~5,000 | Still as bad as September. A scan plus a turn exceeds the ceiling, so vision **must** stay on its own provider, and the fallback is load-bearing rather than optional |

---

## How to Interpret Results

| Scenario | What it tells you |
|---|---|
| Gemini ✅ > Qwen ✅ | Gemini is the better **primary**. Swap the order in `ai_assistant_providers.dart` — one line. Qwen stays as the fallback rather than being dropped |
| Qwen ✅ ≥ Gemini ✅ | Keep the current order. Qwen already leads on latency by a wide margin |
| Qwen has 429s in Cat 11 but Cat 16 shows a fallback answer | Working as designed. The 429 is no longer a failure, it is a handover |
| Qwen has 429s in Cat 11 and Cat 16 shows **no** fallback | The fallback is not firing. This is the highest-priority bug on the list |
| Either model fails Cat 9 (false positives) | The prompt needs tighter negative examples for that pattern |
| Either model fails Cat 4 (memory) | The model is ignoring `remember_about_me` notes — prompt fix |

### For the new stack

| Scenario | What it tells you |
|---|---|
| **12.7 gives an all-clear on a covered lens** | Stop. This is the one failure that can put somebody in a road, and it outranks every other result here |
| Cat 15 flat and kerb scores overlap | The depth approach does not separate them on real ground. Do **not** ship drop-off detection on a threshold that cannot be drawn — turn it off and fall back to the cloud terrain scan |
| Cat 15 separates cleanly | Set the threshold and the feature is real. Record the numbers in `assets/vision/README.md` |
| 14.7 shows heavy drain or a hot phone | Raise `ambientInterval` before touching anything else. The duty-cycle estimate was arithmetic and depth inference was added after it |
| Cat 13 names a **wrong** operator | Raise `BusRouteDirectory.minConfidence` above 0.62. Silence beats a confident wrong bus |
| Cat 17 median billed is ~5,000 | Vision cannot share Groq's budget. Route all scans to Gemini and treat the chat fallback as load-bearing |
