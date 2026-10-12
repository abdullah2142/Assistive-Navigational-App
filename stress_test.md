# ANT — Feature Showcase & Stress Test

> **Purpose:** A structured demo script that showcases every major ANT feature in a natural, story-driven sequence. Each scene flows into the next, building a compelling narrative of how a visually impaired person in Dhaka would actually use the app throughout their day.
>
> **For video:** Film each scene in order. The narrative arc is: *Setup → First walk → Seeing through the phone → Getting help → Staying connected → Handling danger → Customizing the experience → Wrapping up.*

---

## Scene 1 — First Launch & Onboarding

> *Show that ANT adapts to the person from the very first screen.*

| Step | What to do | What to capture |
|---|---|---|
| 1.1 | Open the app fresh. Select **"I need assistance"** | The spoken welcome, language choice (English / বাংলা) |
| 1.2 | Walk through the guided questions: set vision to **Low**, mobility to **White Cane**, hearing to normal | Each question being read aloud — the app narrates its own setup |
| 1.3 | When asked for emergency contacts, **search your phone contacts by name** | The contact search UI, voice input option, and the result appearing |
| 1.4 | Alternatively, tap **manual entry** and dictate a name and number by voice | Speech-to-text filling in the contact fields |
| 1.5 | Save a place — say **"Save this as home"** or add an address manually | The saved-places step in onboarding |
| 1.6 | Complete onboarding and arrive at the dashboard | The main chat screen, map, and microphone button |

**Key message:** *ANT sets itself up through a conversation — a blind user can complete the entire onboarding alone, by ear.*

---

## Scene 2 — Conversational Navigation

> *Show that ANT understands natural language, not just commands.*

| Step | What to say / do | Expected behavior | What to capture |
|---|---|---|---|
| 2.1 | **"I'm really hungry, I want something cheap to eat"** | `request_route` to nearby affordable food — no specific restaurant name invented | The AI understanding a *need*, not a place name, and starting navigation |
| 2.2 | **"Actually, cancel that"** | `cancel_route` — no "are you sure?" | Immediate cancellation, route clears from map |
| 2.3 | **"Take me to Dhanmondi"** | `request_route` with "Dhanmondi" — may ask transport preference for a medium trip | Route appearing on the map, distance/ETA shown |
| 2.4 | **"I don't like this road, give me another way"** | `request_alternative_route` — switches road, same destination | The route visibly changing on the map |
| 2.5 | **"আমাকে কাছের মসজিদে নিয়ে যাও"** *(Take me to the nearest mosque)* | `request_route` with "nearest mosque" — Bangla understood, no follow-up question | Bangla voice input working seamlessly |
| 2.6 | **Search for a destination** using the map search bar — type "Gulshan" | Google Places suggestions appearing, tap one to confirm | The autocomplete dropdown and the confirmation step |
| 2.7 | While on a route, say **"I think I went the wrong way"** | `replan_route` — same destination, new starting point | Route recalculating from current position |

**Key message:** *ANT acts on what you need, not just what you say. "I'm hungry" becomes a route to food. "Nearest mosque" goes straight to navigation — no menus, no lists.*

---

## Scene 3 — AI Vision: The Camera as Eyes

> *Show the camera features that let a blind person "see" through their phone.*

| Step | What to say / do | Expected behavior | What to capture |
|---|---|---|---|
| 3.1 | **"What's in front of me?"** | Camera takes one high-quality frame, viewfinder appears, AI describes the scene | The viewfinder opening, the photo being analyzed, the spoken description |
| 3.2 | After the description, ask a follow-up: **"Can you read that sign for me?"** | Same photo re-analyzed with the specific question | AI giving a targeted answer about the same image |
| 3.3 | **"What's around me?"** | Guided sweep: "Look left… now ahead… now right" — three frames captured | The spoken sweep cues, the user turning, the composite description |
| 3.4 | Use the **aiming viewfinder** — tap the shutter button manually to choose the exact frame | One high-quality frame captured at the user's chosen moment | The viewfinder UI, the shutter button, the result |
| 3.5 | Start walking on a route with a **blind/low-vision profile** — wait 30 seconds | Ambient hazard scan fires automatically, checks the forward view silently | The periodic scan happening in the background (show the debug log or a notification if visible) |

**Key message:** *ANT doesn't just give directions — it can describe what's ahead, read signs, and automatically watch for hazards while you walk.*

---

## Scene 4 — Caretaker Connection (Guardian Hub)

> *Show the two-way communication system between the user and their caretaker.*

| Step | What to do | Expected behavior | What to capture |
|---|---|---|---|
| 4.1 | Open the **Guardian Hub** in a browser (`npm run dev` from `guardian_web/`) | The web dashboard loads with pairing UI | The browser-side Guardian Hub interface |
| 4.2 | **Generate a pairing code** in the browser | A 6-digit code appears, valid for 15 minutes | The code displayed prominently |
| 4.3 | In the app, say **"I want to pair with my caretaker, the code is 482910"** | `pair_with_caretaker` — accounts linked | The pairing confirmation in both the app and browser |
| 4.4 | Say **"Tell my caretaker I'll be home late today"** | `send_caretaker_message` — message appears in Guardian Hub | The message arriving in real-time on the browser |
| 4.5 | Say **"I want to send a voice message to my caretaker"** | `record_caretaker_voice_memo` — recorder opens | The recording UI, the voice memo appearing in both chats |
| 4.6 | **Tap a received voice memo** in the chat | Audio plays back | The tap-to-play interaction |
| 4.7 | From the browser, **send a text message** back to the user | Message appears in the app chat with a distinct caretaker bubble color | Side-by-side: browser sending, app receiving |
| 4.8 | From the browser, **request a snapshot** | User's phone asks for consent (based on settings), then shares a photo | The consent prompt on the phone, the image arriving in the browser |
| 4.9 | From the browser, **send an image** to the user | Image appears in the app chat | The image being received and displayed |
| 4.10 | Say **"I want someone to check on me"** | `alert_caretaker` — caretaker sees an alert with the user's location | The alert notification in the Guardian Hub |

**Key message:** *A caretaker can stay connected from any computer browser — exchanging messages, photos, voice memos, and checking the user's location in real time.*

---

## Scene 5 — Emergency & Safety

> *Show that ANT prioritizes safety above everything else.*

| Step | What to say / do | Expected behavior | What to capture |
|---|---|---|---|
| 5.1 | **"There's someone following me and I'm scared"** | `trigger_emergency` — alarm sequence begins, 5-second cancel window | The emergency UI, the countdown, the spoken warning |
| 5.2 | Say **"Cancel"** within 5 seconds | Emergency cancelled | The cancel interaction |
| 5.3 | **"আমি উঠতে পারছি না"** *(I can't get up)* | `trigger_emergency` — even an indirect Bangla phrase triggers it | Emergency firing from a subtle distress phrase |
| 5.4 | **"There's a huge pothole on this road"** | `open_hazard_report` with category=roadHazard, subCategory=pothole | The hazard report form opening pre-filled |
| 5.5 | **"The sidewalk is completely blocked by vendors"** | `open_hazard_report` with category=accessibilityBlock, subCategory=blockedByVendors | A different hazard type being correctly identified |
| 5.6 | **"That pothole I reported is fixed now"** | `resolve_hazard` — clears it, does NOT open a new report | The resolution flow |

**Key message:** *ANT errs on the side of safety. A frightened whisper triggers help. A hazard report takes one sentence. And the user always gets a chance to cancel.*

---

## Scene 6 — Memory & Personalization

> *Show that ANT learns about the user and remembers across sessions.*

| Step | What to say | Expected behavior | What to capture |
|---|---|---|---|
| 6.1 | **"By the way, I can't manage stairs at all"** | `remember_about_me` — saves the note | The confirmation that it's been remembered |
| 6.2 | **"My daughter picks me up every Friday after Jummah"** | `remember_about_me` — saves this too | A second memory being stored |
| 6.3 | **"What do you know about me?"** | Reads back the remembered notes from the profile | The AI reciting saved personal facts |
| 6.4 | **"Forget about the stairs thing"** | `forget_about_me` — removes that specific note | Selective forgetting working correctly |
| 6.5 | **"Save this place as my office"** | `save_place` — saves current GPS location with label "office" | The place being saved |
| 6.6 | **"Take me to my office"** | `request_route` using the saved place | Navigation starting to a personally saved location |

**Key message:** *ANT builds a personal understanding over time — your limitations, your routines, your places — and uses that knowledge to help you better.*

---

## Scene 7 — Accessibility Settings by Voice

> *Show that every setting can be changed by just asking.*

| Step | What to say | Expected behavior | What to capture |
|---|---|---|---|
| 7.1 | **"Switch to dark mode"** | `update_setting` theme=dark — UI changes immediately | The theme switching live on screen |
| 7.2 | **"Make the text bigger"** | `update_setting` text_size increases | Text visibly growing |
| 7.3 | **"Change the language to Bangla"** | `update_setting` language=bangla — all future replies in Bangla | The AI's next reply coming in Bangla |
| 7.4 | **"I want longer answers, more detail"** | `update_setting` verbosity=descriptive | The AI's reply style becoming more detailed |
| 7.5 | **"Turn off the wake word"** | `update_setting` wake_word_enabled=false | Setting confirmed changed |
| 7.6 | **"Change the theme to red"** | AI explains theme only supports light/dark — does NOT blindly set an invalid value | The AI correctly refusing an impossible setting |

**Key message:** *You never need to find a settings menu. Just tell ANT what you want changed, and it happens.*

---

## Scene 8 — Intelligence Under Pressure (False Positives & Edge Cases)

> *Show that ANT is smart enough to NOT overreact.*

| Step | What to say | Expected behavior | What to capture |
|---|---|---|---|
| 8.1 | **"This road is actually really nice, not dangerous at all"** | Conversational reply — NO emergency, NO hazard report | The AI responding calmly to the word "dangerous" in a positive context |
| 8.2 | **"What happens if I press the emergency button?"** | Explains the feature — does NOT trigger it | A question about emergency ≠ an emergency |
| 8.3 | **"Can you help me change the font size?"** | `update_setting` — does NOT call `trigger_emergency` despite "help" | "Help" in a benign context handled correctly |
| 8.4 | **"Add my sister Fatima as an emergency contact, 01712345678"** | `add_emergency_contact` — NOT `trigger_emergency` | Adding a contact with the word "emergency" in the sentence |
| 8.5 | **"What's my brother's phone number?"** | Says plainly it cannot access phone contacts | Honest about its limitations — no hallucination |
| 8.6 | **"I fell and scraped my knee a little, but I'm totally fine, don't worry"** | Conversational concern, possibly `alert_caretaker` — but respects "I'm fine" for a minor scrape | Nuanced judgment: minor injury + explicit "I'm fine" ≠ full emergency |

**Key message:** *ANT knows the difference between talking about danger and being in danger. It's smart enough to act when it matters and stay calm when it doesn't.*

---

## Rapid-Fire Endurance Test (Bonus)

> *Optional: demonstrate that the app handles rapid consecutive requests without crashing or rate-limiting.*

Send these 6 prompts back-to-back as fast as possible:

| # | Prompt | Expected |
|---|---|---|
| 1 | "Where am I?" | `describe_current_location` |
| 2 | "Take me to the nearest mosque" | `request_route` |
| 3 | "Cancel that" | `cancel_route` |
| 4 | "Switch to dark mode" | `update_setting` |
| 5 | "Tell my caretaker I'm okay" | `send_caretaker_message` |
| 6 | "Show the map" | `open_map` |

**Pass:** All 6 succeed with no error, no dropped turn, no stall.

---

## Video Narrative Summary

If editing the footage into a structured video, the story arc is:

1. **"Meet ANT"** — Onboarding by voice alone (Scene 1)
2. **"Just tell it where you need to go"** — Natural language navigation (Scene 2)
3. **"See through your phone"** — Camera vision, sign reading, ambient scanning (Scene 3)
4. **"Your family stays connected"** — Guardian Hub, messaging, voice memos, snapshots (Scene 4)
5. **"Safety first, always"** — Emergency detection, hazard reporting (Scene 5)
6. **"It remembers you"** — Personal memory, saved places (Scene 6)
7. **"Your way, your settings"** — Voice-controlled accessibility (Scene 7)
8. **"Smart enough to know the difference"** — False-positive resistance (Scene 8)
