# ANT Project Master Plan

This document provides a comprehensive breakdown of the Context-Aware Assistive Navigational Tool (ANT). It details the tech stack, implementation approach for each core module, and the development roadmap.

> **Implementation note (24 September 2026):** This is the original product plan, not a guarantee that every proposed service or behavior shipped exactly as written. The app has since changed its AI providers, vision routing, maps and pairing flows. For current module behavior, use [`docs/app_documentation.md`](docs/app_documentation.md); for camera specifics, use [`docs/vision_camera_module.md`](docs/vision_camera_module.md). Check the implementation and tests before applying a plan statement as a code-level requirement.

## Tech Stack & Tooling

To ensure the app is fast, offline-capable where needed, scalable, and highly accessible, we will use the following tech stack:

*   **Mobile Frontend Framework:** **Flutter**
    *   *Why:* Native compilation for both iOS and Android, incredible built-in accessibility features (TalkBack/VoiceOver support), and complete control over the UI layer for the "calming/soothing" aesthetic and the Deaf-accessible "Heads-Up" mode.
*   **Backend & Database:** **Firebase / Google Cloud Platform (GCP)**
    *   *Why:* Firebase Firestore provides offline data persistence (crucial for "Works Offline" requirements), real-time syncing, and excellent geospatial querying capabilities. Google Cloud Functions will host our serverless routing and data scraping scripts.
*   **Mapping & Routing:** **Google Maps Platform**
    *   *Why:* The Directions API and Maps SDK for Flutter are the industry standard for routing. We will layer our custom safety metrics on top of Google's base routes.
*   **Conversational AI (Bangla):** **Google Gemini API + Google Cloud Speech-to-Text/Text-to-Speech**
    *   *Why:* Google currently leads in Bengali language processing. This stack provides the lowest latency STT (Speech-to-Text) and the most natural-sounding TTS.
*   **Computer Vision (The "Snapshot" Engine):** **Hybrid Architecture**
    *   *Edge (Local):* **TensorFlow Lite (MobileNet/YOLO)** for instant, offline detection of immediate hazards (cars, curbs, people) with zero latency.
    *   *Cloud:* **Google Cloud Vision API** for on-demand complex analysis (e.g., reading a blurry Bangla bus sign).

---

## Module Implementation Breakdown

To ensure a clean development workflow, the app's architecture is divided into 9 distinct modules, each with its own dedicated Markdown specification file in the project root.

### 1. Onboarding & Dual-Role Architecture (`01_module_plan_onboarding.md`)
*   **Approach:** Handles the initial launch. Asks if the user is a Caretaker or Disabled User. Uses Firebase to securely pair the two devices. For disabled users, it initiates a granular AI interview to build the `UserProfile` and runs a Visual Calibration phase for Low Vision users.

### 2. Core Application & UI Module (`02_module_plan_ui_core.md`)
*   **Approach:** The frontend rendering engine. Follows the "Accessible Calm" design system (`#664d8f` muted purple). 
*   **Implementation:** Serves the *Split-Mode Dashboard* (AI Chat + Clean Map + Giant Arrow) to the disabled user, and the *Guardian Hub* to the caretaker. Employs LLM Function Calling so the user can change settings via natural language instead of menus.

### 3. The Bangla Conversational AI (`03_module_plan_ai_assistant.md`)
*   **Approach:** The central brain of the app.
*   **Implementation:** Continuous listening via Google Cloud STT/Vosk. Processes intent via Gemini Pro, and speaks back via Google Cloud TTS. Drives the "Passerby Helper" overlay.

### 4. Contextual Safety & Crime Data (`04_module_plan_crime.md`)
*   **Approach:** The static baseline for the $w_1$ routing metric.
*   **Implementation:** A Python scraper running on GCP downloads DMP police reports, uses Document AI to extract stats, and updates Thana safety scores in Firestore.

### 5. Community Crowdsourcing & Temporal Safety (`05_module_plan_crowdsourcing.md`)
*   **Approach:** The dynamic engine for $w_1$ and $w_2$ metrics.
*   **Implementation:** Features a drill-down reporting modal for users to flag hazards (with AI custom summarization). Implements a Temporal Crime Weighting multiplier (e.g., spiking danger scores in commercial zones at night) and automated data-decay cron jobs.

### 6. The Snapshot Vision Engine (`06_module_plan_snapshot_vision.md`)
*   **Approach:** Solves the battery/overheating problem by banning live video feeds.
*   **Implementation:** Captures high-res photos on demand. Processes immediate physical hazards locally via TensorFlow Lite (Edge), and reads complex text (like bus signs) via Google Cloud Vision API.

### 7. Multimodal Feedback (Haptics) (`07_module_plan_haptics.md`)
*   **Approach:** Instinctive, non-visual feedback.
*   **Implementation:** Three distinct vibration patterns: Single Buzz (Turn), Double Buzz (Confirm), Long Buzz (Hazard).

### 8. Virtual Guardian (`08_module_plan_virtual_guardian.md`)
*   **Approach:** Passive safety tracking for the Caretaker.
*   **Implementation:** Background isolate monitors GPS velocity. Triggers Firebase alerts if stationary > 5 mins. Rejects live video spectating in favor of Asynchronous Voice/Text Memos and permission-based "Snapshot Requests".

### 9. Magic Button (`09_module_plan_magic_button.md`)
*   **Approach:** The ultimate fail-safe.
*   **Implementation:** Triggered via holding Volume Down for 3s or yelling emergency Bangla/English keywords. Instantly dispatches a silent SMS with GPS coordinates, auto-dials the primary caretaker on speakerphone, and reroutes the user to the nearest hospital via Places API.

---

## API Strategy & Cost Mitigation
To ensure the app remains financially viable (and within free-tier limits during development), the architecture heavily relies on **Edge Processing and Caching**. 
*   Live video is *never* sent to the cloud, preventing massive Vision API bills.
*   The LLM is only pinged for complex logic; basic navigational routing uses standard Maps SDK caching.
*   The "Works Offline" feature ensures that if the user loses internet (or if API quotas are exceeded), the app gracefully degrades to local TFLite hazard detection and local offline STT for basic emergency survival mode.

---

## Development Roadmap

**Phase 1: Foundation (Weeks 1-4)**
*   Setup Flutter project architecture and Firebase backend.
*   Build the initial setup/onboarding flow for accessibility profiles.
*   Implement basic Google Maps routing and location tracking.

**Phase 2: The Conversational Brain (Weeks 5-8)**
*   Integrate Google Cloud STT and TTS for Bangla.
*   Integrate the Gemini API.
*   Implement the dynamic text interface for Deaf users.

**Phase 3: Contextual Safety (Weeks 9-12)**
*   Build the Python web scraper and Document AI pipeline for DMP reports.
*   Build the routing interception algorithm (the $R=w_1+w_2+w_3$ decision engine).
*   Build the Crowdsourcing data validation and Temporal Weighting logic (Module 7).

**Phase 4: Snapshot Vision & Emergency Protocols (Weeks 13-16)**
*   Deploy YOLO/MobileNet via TensorFlow Lite for edge detection.
*   Integrate Google Cloud Vision API for bus number OCR.
*   Build Virtual Guardian (Background isolate) and Magic Button (SMS logic).

**Phase 5: Polish & Real-World Testing (Weeks 17-20)**
*   Finalize haptic vibration patterns.
*   Conduct field testing with visually, hearing, and cognitively impaired users.
*   Final bug fixes and project submission.
