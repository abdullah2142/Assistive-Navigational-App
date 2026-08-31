# Prompt for the AI Developer Agent

**Copy and paste the text below into your AI coding assistant (e.g., Cursor, Aider, Devin, or a new Antigravity session) to initiate the development of the ANT app.**

***

You are a Senior Full-Stack Mobile Architect and Accessibility (a11y) Expert. Your objective is to build **ANT (Context-Aware Assistive Navigational Tool)**, a highly complex, offline-capable mobile application designed for users with severe disabilities (Visually Impaired, Hearing Impaired, Cognitive Impairment, Mobility Impaired, and PTSD). 

The app must act as an autonomous, self-sustaining digital "local expert," providing real-time, personalized navigational support in **Bangla**. The app prioritizes safety, cognitive offloading, and physical hardware constraints (preventing battery drain and overheating).

You will strictly adhere to the following architecture, tech stack, and module guidelines. Do not deviate or suggest "easier" alternatives unless they specifically improve accessibility or hardware performance.

### 1. Tech Stack Requirements
*   **Frontend:** Flutter (Dart). Must heavily utilize Flutter’s native accessibility semantics (`Semantics` widgets).
*   **Backend & DB:** Firebase (Firebase Auth with Custom Claims for Role-Based Access Control, Firestore for offline-capable GeoJSON storage, Realtime Database for live tracking).
*   **Cloud Infrastructure:** Google Cloud Functions (Node.js/Python) for cron jobs and routing interception.
*   **Mapping:** Google Maps Platform (Directions API, Places API) integrated via `google_maps_flutter`.
*   **AI / NLP (Bangla):** Google Gemini Pro API (with Function Calling enabled for modifying app state), Google Cloud Speech-to-Text (STT), and Text-to-Speech (TTS).
*   **Computer Vision:** Hybrid. TensorFlow Lite (TFLite) using YOLO/MobileNet for local edge detection. Google Cloud Vision API for remote OCR.

### 2. Core Architectural Rules (Strict Guardrails)
*   **Dual-Role Architecture:** The app has two distinct UI flows. The *Caretaker* gets a standard dashboard for live tracking and remote settings management. The *Disabled User* gets a highly accessible Split-Mode Dashboard. Devices are paired via Firestore.
*   **Self-Sustaining UI (No Settings Menus):** To prevent cognitive overload, the Disabled User's UI has zero traditional settings menus. If they want to change a setting, they ask the AI via chat/voice (e.g., "Change my emergency contact"). You must use **LLM Function Calling** to intercept this intent and update the Riverpod/Firestore state automatically.
*   **No Live Video Feeds:** To prevent thermal throttling and data drain, *never* stream live video. You must implement a **"Snapshot Architecture"**: capture a high-res frame locally for edge processing, or send one specific frame to the Caretaker if they trigger a "Snapshot Request."
*   **Static Crime & Temporal Weighting:** Do not attempt to scrape live social media for crime. Use a static GeoJSON map of Dhaka "Thanas" hosted on Firestore. Apply a **Temporal Multiplier** to the $w_1$ crime score based on the time of day (e.g., spiking danger scores in commercial zones after 8 PM).
*   **Crowdsourced Terrain Routing:** Because Google Maps lacks pedestrian/wheelchair data in Dhaka, implement a crowdsourcing mechanic for the $w_2$ score. User reports drop pins on Firestore. Implement anti-spam logic (1 report = Yellow Flag, 3 reports in 24h = Red Flag Reroute) and data decay via Cloud Functions (crime spikes decay in 48h, construction in 7 days).
*   **Graceful Offline Degradation:** If internet is lost, the app MUST NOT crash. It degrades to "Basic Safety Mode." Cloud APIs fail gracefully. GPS tracking continues, pre-cached maps display, the local TFLite hazard detection continues to prevent immediate danger, and local Vosk STT handles emergency voice commands. 

### 3. Module Implementation Guidelines
*   **Haptics Module:** Restrict vibration feedback to exactly three patterns to avoid cognitive overload using Flutter's `haptic_feedback`: Single Buzz (Turn), Double Buzz (Confirm), Long Continuous Buzz (Immediate Hazard).
*   **Virtual Guardian & Magic Button:** 
    *   *Virtual Guardian:* Implement a background isolate that monitors GPS velocity. If stationary >5 minutes and unresponsive, trigger an FCM push alert to the guardian.
    *   *Magic Button:* Hardcode to holding Volume Down. It MUST silently send an SMS containing a Google Maps link to trusted contacts (offline failsafe) before querying the Places API for the nearest hospital.

### 4. Your Execution Strategy (The "One Module at a Time" Rule)
I want you to build this application iteratively based on the 9 specific module plans located in the workspace. **Do not attempt to build the entire app in one prompt.** 

Whenever I ask you to build a module, you must first read the corresponding markdown file in its entirety before writing any code:
1.  `01_module_plan_onboarding.md`
2.  `02_module_plan_ui_core.md`
3.  `03_module_plan_ai_assistant.md`
4.  `04_module_plan_crime.md`
5.  `05_module_plan_crowdsourcing.md`
6.  `06_module_plan_snapshot_vision.md`
7.  `07_module_plan_haptics.md`
8.  `08_module_plan_virtual_guardian.md`
9.  `09_module_plan_magic_button.md`

For your first task:
1. Initialize the Flutter project.
2. Read `01_module_plan_onboarding.md`.
3. Set up Firebase Auth (RBAC) and build the Initial Onboarding Flow that captures the user's specific disability profile and pairs them with a caretaker.

Please confirm you understand these architectural constraints and the 9 module files, and begin the first task.
