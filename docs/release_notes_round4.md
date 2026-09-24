# ANT tester release notes — round 4

This build brings the recent navigation, vision, AI reliability, caretaker, and accessibility work together. It is intended for trusted testers. The Google release build uses the release variant, Google Routes preference with OSM fallback, tester onboarding skip, and configured speech-to-text / Gemini / Groq keys from the local ignored defines file.

For the system architecture and what each module does, see the [ANT Application Guide](app_documentation.md). For detailed camera behavior, see [Vision and Camera Module](vision_camera_module.md).

## New things to try

- **Ask “what's in front of me?”** The app takes one high-quality frame for analysis. Use the aiming viewfinder and shutter when you want to choose the exact frame. The viewfinder closes after analysis or sending.
- **Ask “what's around me?”** Follow the left, ahead, and right sweep cues. The sweep sends up to three 640 × 480 frames to Gemini; a Qwen fallback receives the sharpest single frame.
- **Try an image follow-up.** After a photo is described, ask a specific follow-up about that same scenery or sign.
- **Try ambient checks during a walk** with a blind/low-vision profile. They run every 30 seconds, every 15 seconds near mapped hazards/crossings, then every 60 seconds after four clear scans. These single frames are not added to chat.
- **Exercise offline vision** by temporarily disabling data: local object detection and enabled depth/drop-off inference are used when the online ambient model is unavailable.
- **Try route requests** such as “I need to eat,” “I need a bathroom,” “take me to…,” and “how do I get there?” Check nearest-place routing, transport questions/suggestions, bus itinerary details when available, traffic-aware ETA, and relevant weather alerts.
- **Search for a destination** in the map and destination fields using Google Places suggestions; select a suggestion and confirm the destination.
- **Try caretaker messaging** in the Guardian Hub: pair a browser, send text or an image, request a snapshot, and tap a voice memo to replay it. The user and caretaker chats both support tap-to-play voice messages.
- **Run the Guardian Hub locally** without deploying it: from `guardian_web/`, run `npm install` once and `npm run dev`, then open the printed localhost URL (normally `http://localhost:5173/`). With `guardian_web/.env.local` configured, generate a pairing code in the browser and enter it in the app's caretaker pairing flow. Keep the tab open; the one-time code expires after 15 minutes. Localhost supports microphone recording. See [Guardian Hub README](../guardian_web/README.md).
- **Try emergency contact setup** in onboarding and Settings. Search phone contacts by name/number, use voice input, or choose manual name and number entry with dictation.
- **Try the model fallback behavior** after hitting a provider limit or forcing a temporary provider error. A limited model should be skipped during its cooldown and regain priority when the cooldown ends.

## Changes and improvements

### Vision and camera

- Added one-frame high-detail front snaps, guided three-frame sweeps, camera aiming/shutter flows, photo follow-ups, and automatic camera release after the task.
- Added an online-first periodic hazard scan for blind and low-vision profiles using Gemini 3.5 Flash-Lite, with bounded timeout and offline SSD/depth fallback.
- Added cadence changes for ordinary walking, nearby hazards/crossings, and repeated clear scans, plus route context, movement/battery gates, deduplicated hazard announcements, and foreground-work yielding.
- Ambient frames remain private to the scan path and do not appear in chat.
- Documented the camera ownership, model routes, image-size limits, token-cost interpretation, fallback behavior, and practical limitations in [Vision and Camera Module](vision_camera_module.md).

### AI responses and reliability

- Added the requested cascading chat lineup: GPT-OSS 120B (Groq), Qwen 3.8 27B (Groq), Gemma 4 31B (AI Studio), then Gemini 3.7, 3.6, 3.5 Flash, and 3.5 Flash-Lite.
- Added separate front-snap and sweep model orders, with sweep fallback reducing to the sharpest frame for single-image Qwen.
- Added shared model cooldown tracking and automatic return to preferred models after cooldown expiry.
- Added a Gemma-oriented system prompt and updates to fallback/quota handling.
- Improved voice command routing for current weather, common destination needs, camera launch, and cancel/close trip wording.

### Navigation and maps

- Added Google Places Autocomplete suggestions to destination, map-pin, onboarding, and saved-place selection flows, retaining existing fallbacks.
- Expanded Google Routes support for traffic-aware ETAs and bus itineraries when provider data is available; route requests retain the configured fallback behavior.
- Added nearby food/bathroom routing, transport choice behavior, weather advisories, and transit landmark announcements.
- Added accessibility settings for depth scanning and whether the map opens automatically after route selection.

### Caretaker and communication

- Added the Guardian Hub browser companion with pairing, user status/location, alerts, chat, snapshot requests, image sharing, and voice memo replay.
- Added a full caretaker-side chat composer with snapshot/image actions, text input, voice input, and a separate voicemail action.
- Added tap-to-play voice messages in both chats, distinct colors for AI and caretaker messages, and improved compact composer behavior.
- Added phone contact search/import and manual voice-assisted contact entry in onboarding and Settings.
- Improved user-side voice memo send/stop/cancel recognition and caretaker message-routing controls.

## Known constraints for this round

- Model availability, quotas, and latency depend on provider status and project-level limits. A fallback may take longer if the first request waits for an error/timeout.
- Ambient scanning is advisory. A still image and limited offline detectors cannot establish that a walking route is safe.
- Google Places/Routes may be unavailable or omit transit details; existing fallback behavior remains in place.
- Guardian Hub is a local web client in this repository. Publishing it requires separate Firebase Hosting configuration and is not part of this APK build.
- Tester diagnostics can contain raw speech and other personal context when enabled. Share exports only with the project team.

## Build and verification

Built with `scripts/release_google_build.sh build` as a release APK with Google Routes preference and OSM fallback, tester onboarding skip, and configured Groq/Gemini/Cloud STT keys. The APK checks confirmed those keys plus `TESTER_BUILD` and raw diagnostic transcript flags. The full Flutter test suite passed (1,468 tests). Targeted static analysis completed with two non-fatal lint warnings: the Gemma prompt helper is annotated for test use, and an existing flow-control statement could use braces. Cloud TTS has no dedicated key in the local build configuration, so spoken output falls back to the device engine.
