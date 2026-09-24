# ANT — feature backlog

Deferred by explicit instruction while field-reported bugs are fixed first.
Each entry records who asked and why, so the reason survives the gap between
being written down and being built.

Ordered by the priority set on 23 September. Effort is the honest estimate,
not the hopeful one.

## Next up

1. **Map menu and nearby places.** Let users browse saved places and explore
   nearby places from the map instead of only dropping a pin. *Medium.*


## Locations and maps

Asked for twice. The first round of this shipped and was **unreachable** — the
পথ chip appended a bubble and did nothing, because it fell through to a
`break` while the sheet that answers it lives on the dashboard. That wiring
is fixed; what follows is what is genuinely still missing.

- **A map menu, not just a picker.** `MapPinPickerScreen` drops one pin and
  returns. It cannot show saved places on the map, cannot show what is
  nearby, and cannot be panned to explore an area before choosing. *Medium.*
- ~~**Bus line names for transit routes.**~~ Commute planning now asks Google
  Routes API for a bus itinerary and speaks its line name, boarding stop,
  alighting stop, direction, and estimated duration when Google returns them.
  It uses the shared Routes API monthly cap and falls back to the existing
  approximate bus-time estimate when transit data is unavailable.

## Later, by instruction


## Done

- ~~**Caretaker web hub (local preview).**~~ A standalone browser client now
  reuses the existing anonymous Firebase sign-in and one-time pairing flow.
  It provides paired-user location, alerts, and a caretaker chat with text,
  snapshot requests, compressed image sharing, and replayable WAV voice
  memos. Firebase Hosting is still not configured; the hub has been built and
  previewed locally but has not been published.

- ~~**Phone contacts search and import.**~~ Onboarding and Settings share an
  in-app contact search that filters the phone's local address book by typed
  or spoken name/number. The user can instead enter a new name and number;
  both manual fields support voice dictation. Only the chosen contact is
  saved to the emergency profile.

- ~~**Battery warnings.**~~ The ambient scanner announces once when it stops
  below 20%, and again when charge recovers.
- ~~**Show the frame that was sent.**~~ A scan's reply carries the frame it
  was answered from, shown above the text in the chat. Not persisted — the
  transcript is restored on launch and tens of kilobytes per scan would grow
  without bound.
- ~~**Weather warnings.**~~ Open-Meteo, keyless. Appended to a route only
  when it clears a high bar — rain now, rain likely within the hour, a
  thunderstorm, or an apparent temperature over 36°C.
- ~~**Jam-based ETA** and **transport suggestion.**~~ One feature, because
  the option and its cost are the same question. `CommutePlanner` offers
  walk/rickshaw/CNG/bus with a time against each; the car time comes from a
  traffic-aware Routes API call, and everything else is a ratio of it.
  Falls back to a time-of-day model, and says which kind of number it gave.
- ~~**Reply to a specific message.**~~ Long-press an assistant bubble to
  quote it; the quote is sent to the model as context and shown in the
  bubble. Carried as text rather than an id because the model reads a
  transcript, not a database.
- ~~**Camera aiming preview.**~~ An explicit camera action opens a bounded
  viewfinder. Its shutter frame is the frame analyzed or sent to the caretaker;
  one-shot capture stays separate from spoken multi-frame sweeps. The camera
  closes after analysis or dismissal.
- ~~**"What's in front of me?" snapshot.**~~ The ahead-scene intent now takes
  one high-quality frame and sends it for analysis. Explicit sweeps still use
  multiple frames.
- ~~**Search that actually searches.**~~ The destination sheet and map pin
  picker now show debounced Google Places Autocomplete candidates, biased to
  the user's location; selecting a candidate resolves its place details.
  Legacy geocoding and OSM suggestions remain fallbacks when Places is
  unavailable. Queries require three characters and return at most four
  candidates.
- ~~**Confirm a pin before routing.**~~ A selected map pin is shown for
  confirmation before it is returned as the destination, so an accidental
  tap can be corrected.
- ~~**Search and pin wherever a place is added.**~~ `PlacePickerField` in
  settings, `MapPickButton` in onboarding, and the map picker now searches
  and offers candidates. Settings can also create a saved place, which it
  never could.
- ~~**Voicemail-style replay.**~~ `replay_voice_message(which)` steps through
  the session's memos — latest, repeat, previous, next — announcing the
  position before each. Ends clamp rather than wrap. Voice messages are also
  tap-to-play in both the user and caretaker chat interfaces.
- ~~**Guardian chat interface.**~~ A caretaker-side composer now mirrors the
  user chat with request-snapshot and send-image actions, a text field, and a
  speech-input mic plus a separate voice-message pill. Both chat composers
  expand sideways and hide action pills while text is being composed. Caretaker
  and AI messages have distinct colors, and voice messages are tap-to-play in
  both chats. On the user chat, the caretaker pill manually toggles message
  routing and stays selected until toggled off; voice-directed caretaker
  sends route once and then turn the pill off again.
- ~~**Voluntary image sending.**~~ Guardian sends from gallery or camera, the
  user from the camera only. An arriving photo is read aloud by the vision
  tier — a picture on a screen the user cannot see is not a delivered
  message. Kept as its own message type so the snapshot-consent setting does
  not silently govern ordinary photo sharing.
- ~~**Transit proximity announcements.**~~ `NavigationNarrator` carries
  landmarks and announces each once within 40m. Crossings come from the route
  geometry; bus stops are an Overpass lookup fired after setting off, so a
  slow volunteer API never delays the start of a journey.
- ~~**One-frame capture for direct scene requests.**~~ “What's in front of
  me?” and explicit camera shutter actions analyze one high-quality frame;
  “what's around me?” remains the guided multi-frame sweep. Volume Up also
  takes an immediate single frame.
- ~~**Accessibility preferences for scanning and maps.**~~ Depth scanning is
  configurable and defaults on for blind profiles. Opening the map after a
  route is configurable and defaults off for blind profiles.
- ~~**Direct voice actions for common requests.**~~ Current-weather questions
  fetch live weather; food and toilet needs route to the nearest matching
  place; open-camera and cancel/close-trip phrasings now dispatch locally.
- ~~**Voice-memo recording controls.**~~ The user-side recorder listens to
  streaming speech recognition for send, stop, and cancel commands, and still
  has a 20-second safety limit.
- ~~**AI model cascades and timed recovery.**~~ Chat runs GPT-OSS 120B (Groq)
  → Qwen 3.8 27B (Groq) → Gemma 4 31B (AI Studio) → Gemini 3.7 Flash →
  3.6 Flash → 3.5 Flash → 3.5 Flash-Lite. Front Snap runs Qwen first, then
  Gemini 3.7 → 3.6 → Gemma 4 → 3.5 → 3.5 Flash-Lite. Three-way sweep uses
  Gemini 3.7 → 3.6 → Gemma 4 → 3.5, then Qwen with only the sharpest single
  frame. Cooldowns are shared by provider/model across chat and vision, so
  overlapping models share their provider quota; expired timers restore their
  preferred position automatically. Picture follow-ups resend the captured
  frame with the follow-up question.
- ~~**Online ambient vision checks.**~~ Blind and low-vision profiles now use
  Gemini 3.5 Flash-Lite for one bounded forward-facing frame on a 30-second
  walking cadence, 15 seconds near mapped hazards/crossings, and 60 seconds
  after four clear scans. Ambient images never enter chat. Foreground work,
  movement, battery level, and app lifecycle gate the work; a failed/slow
  online check falls back to local SSD and optional depth detection. This
  remains advisory and does not claim a route is safe.
- ~~**Vision and camera technical documentation.**~~ Added a module reference
  covering camera ownership, aiming, one-frame scans, sweeps, ambient scans,
  model routing, image caps, fallback behavior, token-cost limits, and known
  safety constraints.
