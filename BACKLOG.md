# ANT — feature backlog

Deferred by explicit instruction while field-reported bugs are fixed first.
Each entry records who asked and why, so the reason survives the gap between
being written down and being built.

Ordered by the priority set on 23 September. Effort is the honest estimate,
not the hopeful one.

## Next up

1. **Phone contacts import.** Pull emergency contacts from the phone's
   address book instead of dictating name and number. Needs a new runtime
   permission and a picker. *Medium.*


## Locations and maps

Asked for twice. The first round of this shipped and was **unreachable** — the
পথ chip appended a bubble and did nothing, because it fell through to a
`break` while the sheet that answers it lives on the dashboard. That wiring
is fixed; what follows is what is genuinely still missing.

- **Search that actually searches.** The destination sheet's field submits
  its text to the same path a spoken destination takes — a geocode, or a
  category lookup for "nearest X". There is no *as-you-type* search, no list
  of matching places to choose from, and no way to see what a query would
  resolve to before committing to walking there. *Medium.*
- **A map menu, not just a picker.** `MapPinPickerScreen` drops one pin and
  returns. It cannot show saved places on the map, cannot show what is
  nearby, and cannot be panned to explore an area before choosing. *Medium.*
- **Confirm a pin before routing.** A pin is reverse-geocoded for the
  *sentence* only; if that lookup fails the user is walked to "the place you
  picked on the map" with no name. Reading back a candidate and waiting for
  a yes would make a mis-aimed pin recoverable. *Small.*

## Later, by instruction

- **Guardian web interface.** Everything the phone can do, in a browser, for
  a caretaker who is not holding the user's device. No Firebase Hosting is
  configured yet; this is greenfield. *Large.*
- **Phone contacts import.** Pull emergency contacts from the phone's address
  book instead of dictating name and number. Needs a new permission and a
  picker. *Medium.*

## Done

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
- ~~**Camera aiming preview.**~~ A bounded exception to the no-live-video
  rule: the preview lives only while the aiming screen is on top, is capped
  at 45s, and is released on dispose however the screen is left. Offered
  only to users with some usable vision — for a blind user a preview is a
  screen between them and the answer, and the spoken sweep cues are their
  aiming interface.
- ~~**Search and pin wherever a place is added.**~~ `PlacePickerField` in
  settings, `MapPickButton` in onboarding, and the map picker now searches
  and offers candidates. Settings can also create a saved place, which it
  never could.
- ~~**Voicemail-style replay.**~~ `replay_voice_message(which)` steps through
  the session's memos — latest, repeat, previous, next — announcing the
  position before each. Ends clamp rather than wrap.
- ~~**Guardian chat interface.**~~ Inline composer and sender-aligned
  bubbles, replacing three buttons that each opened a modal and a read-only
  list of the last five.
- ~~**Voluntary image sending.**~~ Guardian sends from gallery or camera, the
  user from the camera only. An arriving photo is read aloud by the vision
  tier — a picture on a screen the user cannot see is not a delivered
  message. Kept as its own message type so the snapshot-consent setting does
  not silently govern ordinary photo sharing.
- ~~**Transit proximity announcements.**~~ `NavigationNarrator` carries
  landmarks and announces each once within 40m. Crossings come from the route
  geometry; bus stops are an Overpass lookup fired after setting off, so a
  slow volunteer API never delays the start of a journey.
