# Vision and Camera Module

This document describes the implementation in `ant_app/lib/core/services/vision/` and the dashboard camera UI. It reflects the current source, including the online ambient scanner; the older `06_module_plan_snapshot_vision.md` describes an earlier Google Cloud Vision design and is not the current backend specification.

## What the module is for

The phone captures still photographs to answer a user's visual question, show the user what they are aiming at, share a selected image with their caretaker, and periodically look for forward-path hazards for blind and low-vision users. It does not upload a live video stream. The camera viewfinder may show a local preview while the user aims; analysis and sharing use JPEG stills.

The main orchestration is `SnapshotVisionService`. `SnapshotCamera` owns the camera controller. The local object detector is `EdgeHazardDetector` (SSD MobileNet), the optional ground-change detector is `DepthDropoffDetector`, and `VisionRouter` chooses cloud vision backends. `AmbientHazardScanner` shares the camera and local detectors while keeping its frames out of the conversation transcript.

## User-facing capture modes

### Front Snap / direct visual question

Requests such as “what's in front of me?”, reading a sign, identifying an object, and a direct shutter action take one frame. The aiming viewfinder is available for deliberate aiming; its captured frame is the one analyzed or sent. The captured image first receives a local SSD pass. An imminent local hazard can cause a haptic and spoken warning before any cloud request. Otherwise the image is encoded and sent to the vision router.

For detailed one-frame questions, the upload is bounded to 1280 × 960 at JPEG quality 86, preserving aspect ratio and never upscaling. The physical sensor uses `ResolutionPreset.high`; the resulting camera dimensions vary by device. The 1280 × 960 figure is an upload ceiling, not a promise that every image has those exact dimensions.

### Guided 3-way sweep

An explicit surroundings sweep cues left, ahead, and right in order. Each cue can be spoken through the app's narration queue and paired with a haptic; capture waits 700 ms after each cue so the user can aim and stop moving. It captures up to three separate stills, 900 ms apart when no guided cue is required.

Sweep frames are uploaded in left/centre/right order to the Gemini vision cascade, bounded to 640 × 480, JPEG quality 86, with aspect ratio preserved. If Gemini cannot answer, the Groq/Qwen single-image backend receives only the sharpest selected frame. If no multi-image cloud backend is configured, the router reduces the sweep to one frame before opening the camera.

### Camera aiming and caretaker image sharing

The dashboard's explicit camera action opens the local aiming preview. The shutter captures a still; depending on the action, that same still is sent to the caretaker or analyzed. It is not converted into sweep mode. The camera is released when the operation completes or the user dismisses the viewfinder. A short 20-second warm window is used for ordinary capture reuse, but explicit UI flow closes it after send/analysis; app backgrounding and dashboard disposal release it immediately.

Images sent to the caretaker use the dedicated caretaker image path and should not be assumed to use the AI upload dimensions. The vision upload encoder described above applies to AI analysis. The chat attachment payload's actual compression is controlled separately by the image/message service.

## Online model routing

`VisionRouter` selects a backend order by request type:

| Request | Preferred order |
| --- | --- |
| Front Snap, one image | Qwen 3.8 27B on Groq, then Gemini cascade: 3.7 Flash → 3.6 Flash → Gemma 4 31B → 3.5 Flash → 3.5 Flash-Lite |
| Three-frame sweep | Gemini cascade: 3.7 Flash → 3.6 Flash → Gemma 4 31B → 3.5 Flash, then Qwen on the sharpest single frame |
| Ambient scan | Gemini 3.5 Flash-Lite directly; offline detectors if it is unavailable or times out |

The exact model IDs and order are in `GeminiConfig` and provider construction. Model cooldowns are shared by model/provider across chat and vision where the same model is used. A quota/rate-limit or overload response records a cooldown, skips that model for later requests, and lets it rejoin its preferred place when its cooldown expires. A fallback can add latency because the request tries a failed model before continuing; the service does not wait for a quota reset during an individual request.

Ambient scanning intentionally has its own fixed online model (3.5 Flash-Lite) and does not run the full interactive fallback cascade. It has a four-second online timeout so offline checks can run promptly. This keeps periodic work bounded and avoids turning a background scan into a chain of expensive cloud attempts.

## Periodic ambient hazard checks

Ambient scanning is enabled for blind and low-vision profiles. It checks a single forward-facing still and does not put the frame into chat. The normal interval is 30 seconds; it shortens to 15 seconds near route hazards or crossings, and backs off to 60 seconds after four consecutive clear scans. The policy also requires movement since the previous scan (8 m by default), skips while an explicit scan or conversation is active, stops below 20% battery, and does not run in the background or after dashboard disposal. A battery warning is spoken when scanning stops and when charge recovers.

The online prompt asks about visible forward-path obstacles, vehicles/crowds in the path, broken or slippery ground, drains/manholes, kerbs/crossings/platform edges, level changes, stairs, ramps, escalators, tactile paving, and lift/elevator entrances. It tells the model not to invent distance, depth, travel direction, hidden hazards, or a guarantee that the route is safe. Findings are deduplicated for two minutes; serious findings can trigger haptics and are sent through the normal narration stream.

Ambient uploads use the same cap as a sweep: maximum 640 × 480, JPEG quality 86, aspect ratio preserved, no upscaling. With no usable online answer, the scanner runs local SSD MobileNet and, if enabled in the user's profile and its model is available, MiDaS-based depth/drop-off analysis. These models are fallback signals, not a complete substitute for visual understanding.

## Local checks and depth

The SSD MobileNet model accepts a 300 × 300 uint8 image and emits at most ten detections. It is used as an early hazard check before interactive uploads and as an offline ambient fallback. Its class vocabulary is limited to the classes in the bundled model; it cannot reliably identify every street hazard, read signs, or understand access infrastructure.

The optional depth detector estimates relative ground continuity/drop-off from a still. The profile preference controls its use and defaults on for blind profiles. It does not provide calibrated metric distance or a certified measurement of a step. An unreadable/uncertain frame is not treated as proof of a hazard-free path.

## Scene memory and follow-up questions

The last cloud scene can answer a repeat request for up to 45 seconds, subject to the same question/focus matching and a 12-second cloud cooldown. A different question should not receive a mismatched cached answer. For a follow-up about a photo in chat, the application resends the same JPEG with the new question and the initial description as context. Vision models are stateless, and the follow-up may use a different model from the first description; the image itself is supplied again as the source of truth.

## Image dimensions and token implications

The app's upload caps are dimensions, not fixed token counts. Providers tokenize images according to their own image-processing rules, aspect ratio, detail tier, and model; the client does not calculate or guarantee an exact image-token charge. A 640 × 480 cap reduces image payload and inference work compared with a 1280 × 960 cap, while 1280 × 960 retains more sign detail for explicit close reading. JPEG quality affects byte size and visual artifacts, but does not by itself establish an exact provider token count.

Current AI upload settings:

| Path | Maximum size | JPEG quality | Frames per request |
| --- | ---: | ---: | ---: |
| Detailed one-frame/front snap | 1280 × 960 | 86 | 1 |
| Sweep | 640 × 480 | 86 | Up to 3 for Gemini; 1 sharpest for Qwen fallback |
| Ambient | 640 × 480 | 86 | 1 |

## Camera lifecycle and concurrency

`SnapshotCamera` opens the rear camera (or the first available camera), requests high resolution, autofocus, and flash off. Optional focus/flash setup failures do not prevent capture. Concurrent capture attempts are serialized; a second in-flight attempt is declined rather than opening the sensor twice. Failed frames in a sweep do not invalidate other successful frames. Camera permission or initialization failure returns an accessible spoken error path.

Ambient checks yield while foreground scanning/conversation is busy. The dashboard releases camera resources on pause/disposal. Explicit camera workflows own closing the viewfinder after the image has been sent or analyzed.

## What to try as a tester

1. Ask “what's in front of me?” and confirm a single aiming frame is captured and the camera closes after the spoken result.
2. Ask to read a sign or identify an object; check small text at a reasonable distance and try a follow-up question about the same photo.
3. Say “what's around me?” and follow the left/ahead/right aiming cues; confirm it behaves as a sweep rather than a one-shot.
4. Use the shutter to send a picture to the caretaker; confirm the caretaker receives the selected view and can open it.
5. Walk with a blind/low-vision profile and confirm ambient scanning stays out of chat, speaks only actionable results, and yields during a foreground interaction.
6. Disable network access to exercise the local SSD/depth fallback. Treat a quiet result as limited detector output, not a safety guarantee.

## Limitations and safety boundaries

- A single camera view cannot prove a path is clear; hazards outside the frame, hidden by people/objects, or behind the phone are not observed.
- The model can miss or misdescribe hazards. Follow spoken guidance and haptics as additional cues, not a replacement for mobility aids or human judgement.
- GPS/map proximity only changes scan cadence; it does not aim the camera at a mapped hazard.
- The offline object model has limited classes. Depth inference is relative and may fail on poor lighting, textureless surfaces, motion blur, or unusual camera angles.
- Network delay, quota limits, provider outages, camera permissions, device-specific sensor resolutions, and image compression affect results.
- Tester diagnostic builds may retain raw transcripts when explicitly configured. Diagnostic exports can include personal or location data and should be handled privately.
