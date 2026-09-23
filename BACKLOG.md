# ANT — feature backlog

Deferred by explicit instruction while field-reported bugs are fixed first.
Each entry records who asked and why, so the reason survives the gap between
being written down and being built.

## From the 22 September field report

- **Phone contacts.** Import emergency contacts from the phone's own address
  book instead of dictating name and number. The assistant currently has no
  access and says so; typing a Bangladeshi mobile number by voice is the
  slowest interaction in the app.
- **Voicemail-style replay.** Play back received caretaker voice memos like
  voicemail — repeat, previous, next — rather than once on arrival.
- **Transit proximity announcements.** Say when a bus stop, pedestrian
  crossing or intersection is coming up. Route geometry already carries
  `ManeuverKind.crossing`; nothing announces it ahead of time.
- **Jam-based ETA.** Live traffic in the commute estimate, so a trip can be
  planned around Dhaka congestion rather than walking distance alone.
- **Transport suggestion.** Narrate the sensible ways to reach a destination
  — bus, rickshaw, CNG, walk — chosen by distance and time of day.
- **Guardian web interface.** Everything the phone can do, on a browser, for
  a caretaker who is not holding the user's device. No Firebase Hosting is
  configured yet; this is greenfield.
- **Camera aiming preview.** Open a viewfinder when the camera button is
  tapped, so a sighted helper can aim. `SnapshotCamera` bans a preview
  stream by design (Snapshot Architecture) — this reopens that decision.
- **Show which frame was used.** Surface the sharpest frame the sweep
  actually uploaded, so the user can see what the answer was based on.

## From the 23 September field report

- **Weather warnings.** Warn about rain or heat before setting out, and
  during a walk. Dhaka rain changes whether a route is walkable at all.
- **Battery warnings.** Warn on low battery. The ambient scanner already
  stops below 20% (`AmbientScanPolicy`) and says nothing about why, so the
  feature silently disappears.
- **Guardian communication as a chat.** Turn the caretaker channel into a
  real two-way chat rather than one-shot messages and alerts.
- **Voluntary image sending, both directions.** Separate from the snapshot
  scans: the user sends from the camera only, the guardian from camera or
  gallery. Deliberately distinct from Module 6, which is the assistant
  looking on the user's behalf — this is a person choosing to share a photo.
