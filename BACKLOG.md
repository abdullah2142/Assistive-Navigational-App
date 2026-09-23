# ANT — feature backlog

Deferred by explicit instruction while field-reported bugs are fixed first.
Each entry records who asked and why, so the reason survives the gap between
being written down and being built.

Ordered by the priority set on 23 September. Effort is the honest estimate,
not the hopeful one.

## Next up

1. **Voicemail-style replay.** Play received caretaker voice memos back like
   voicemail — repeat, previous, next — rather than once on arrival. *Small.*
2. **Guardian chat interface.** Turn the caretaker channel into a real
   two-way chat rather than one-shot memos and alerts. *Medium.*
3. **Voluntary image sending, both directions.** Separate from the snapshot
   scans: the user sends from the camera only, the guardian from camera or
   gallery. `CommunicationMessage.imageBase64` already exists from the
   snapshot-reply work. *Medium.*
4. **Reply to a specific message.** Let the user reply to a particular
   assistant message so the conversation knows which one they mean — "that
   one", "the second place you said". Today every turn is read against the
   whole recent history and an ambiguous reference resolves to whatever the
   model guesses. Needs a message id on the wire and a quoted-reply affordance
   in the chat. *Medium.*
5. **Camera aiming preview.** Open a viewfinder when the camera button is
   tapped, so a sighted helper can aim. `SnapshotCamera` bans a preview
   stream by design (the Snapshot Architecture's "no live video" rule) — this
   reopens that decision rather than just adding a widget. *Medium, and an
   architectural call first.*

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
- ~~**Transit proximity announcements.**~~ `NavigationNarrator` carries
  landmarks and announces each once within 40m. Crossings come from the route
  geometry; bus stops are an Overpass lookup fired after setting off, so a
  slow volunteer API never delays the start of a journey.
