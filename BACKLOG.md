# ANT — feature backlog

Deferred by explicit instruction while field-reported bugs are fixed first.
Each entry records who asked and why, so the reason survives the gap between
being written down and being built.

Ordered by the priority set on 23 September. Effort is the honest estimate,
not the hopeful one.

## Next up

1. **Reply to a specific message.** Let the user reply to a particular
   assistant message so the conversation knows which one they mean — "that
   one", "the second place you said". Today every turn is read against the
   whole recent history and an ambiguous reference resolves to whatever the
   model guesses. Needs a message id on the wire and a quoted-reply affordance
   in the chat. *Medium.*
2. **Camera aiming preview.** Open a viewfinder when the camera button is
   tapped, so a sighted helper can aim. `SnapshotCamera` bans a preview
   stream by design (the Snapshot Architecture's "no live video" rule) — this
   reopens that decision rather than just adding a widget. *Medium, and an
   architectural call first.*

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

## Commute planning

Dropped from this file in error on 23 September while it was being
reordered — they were in the 22 September list and were never built.

- **Jam-based ETA.** Live traffic in the commute estimate, so a trip can be
  planned around Dhaka congestion rather than walking distance alone. Today
  every estimate is walking speed over route length, which is honest for a
  footpath and useless for deciding when to leave. *Medium.*
- **Transport suggestion.** Narrate the sensible ways to reach a destination
  — bus, rickshaw, CNG, walk — chosen by distance and time of day, for
  planning rather than for setting off immediately. `busRoutes` already holds
  156 Dhaka operators and `place_categories.dart` can find the nearest stop;
  what is missing is the judgement about which mode suits a given trip.
  *Medium.*

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
