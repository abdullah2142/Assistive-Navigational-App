# Bangla Conversational AI Module Plan

## Objective
To build the "Always-On" voice assistant that acts as the primary interface for visually impaired users. It must handle conversational Bangla with low latency and provide a lightweight offline fallback.

## Tech Stack
*   **Wake Word Engine:** Porcupine (Picovoice) for local, offline wake-word detection (e.g., "Hey ANT").
*   **Speech-to-Text (STT):** Google Cloud Speech-to-Text API (configured for `bn-BD` language code).
*   **Brain/LLM:** Google Gemini Pro API.
*   **Text-to-Speech (TTS):** Google Cloud Text-to-Speech (Neural Bangla Voices).

## Step-by-Step Implementation

### Step 1: The Audio Input Pipeline
1. **Wake Word Detection:** Integrate Picovoice Porcupine to listen continuously with near-zero battery drain. When the wake word is detected, the app triggers a short haptic buzz to confirm it is listening.
2. **Audio Streaming:** Start recording audio via the device microphone. Compress the audio stream (e.g., FLAC or Opus) and send it via gRPC to the Google Cloud STT API.
3. **Transcription:** Receive the Bangla text string from the STT API.

### Step 2: The LLM Decision Engine
1. **Contextual System Prompt:** We will construct a dynamic prompt that is injected before the user's text. It will contain:
   - User's GPS Location & Heading.
   - User's Disability Profile.
   - Current App State (e.g., "Currently routing to Hospital").
2. **Gemini Processing:** Send the prompt and the transcribed user command to the Gemini API.
3. **Action vs. Conversation:** The LLM is instructed to output JSON. It will return an `action_code` (e.g., `START_ROUTE`, `PANIC_BUTTON`, `CHAT`) and a `response_text` in conversational Bangla.

### Step 3: The Output Pipeline
1. **TTS Conversion:** Send the `response_text` to Google Cloud TTS.
2. **Audio Playback:** Play the generated audio file to the user with a calm, friendly vocal profile, as specified in the Non-Functional requirements.

### Step 4: The Offline Fallback Architecture
1. **Local STT:** Bundle a highly compressed, offline STT model (like Vosk) trained on a very limited vocabulary of essential Bangla commands (e.g., "Help", "Stop", "Where am I").
2. **Static Responses:** If the app loses internet connection, the LLM is bypassed. The local STT maps recognized commands to pre-recorded audio files stored on the device (e.g., playing a pre-recorded file saying "Internet lost, but tracking is active" in Bangla).
