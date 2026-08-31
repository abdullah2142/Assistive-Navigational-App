# Magic Button Module Plan

## Objective
To provide a fail-proof, immediate SOS trigger that alerts family, emergency services, and hospitals, guaranteeing functionality even when the internet connection drops.

## Tech Stack
*   **Hardware Interface:** Flutter hardware button mapping (e.g., holding Volume Down).
*   **Offline Comms:** Native Android `SmsManager` and iOS `MFMessageComposeViewController` (via `url_launcher` or `flutter_sms`).
*   **Online Comms:** Google Places API (for finding nearest hospitals/police).

## Step-by-Step Implementation

### Step 1: The Triggers (Physical & Voice)
1. **Physical Button Mapping:** A virtual button on the screen is useless if a blind user is in a panic or a cognitive user is overwhelmed. The primary "Magic Button" will be hardcoded to a physical action: **Hold the Volume Down button for 3 uninterrupted seconds.**
2. **Voice Trigger (Emergency Keywords):** If the user's hands are occupied or they cannot reach the phone, the AI Assistant's always-on listening engine (both the Cloud STT and the offline Vosk fallback) will be programmed to instantly trigger upon recognizing specific high-priority emergency keywords. Given the prevalence of code-switching in Dhaka, the vocabulary will explicitly include both native Bangla phrases (e.g., "বাঁচাও", "সাহায্য করো") and common English loanwords used in a panic (e.g., "Help me", "Emergency", "SOS").
3. **Confirmation:** Upon a successful trigger (either physical or voice), the app outputs the "Confirmation Pulse" (Double Buzz) and the AI announces, *"Emergency mode activated. Sending alerts."*

### Step 2: The Offline Escalation (SMS & Auto-Dial)
1. **Why Cellular?** If the user is in a dense area or drops data, internet APIs fail. SMS and standard cellular calls operate on base bands and almost always succeed.
2. **Payload Construction:** The app constructs an SMS string: *"EMERGENCY: I need help. My battery is at [X]%. My exact location is: https://maps.google.com/?q=[Lat],[Lng]"*
3. **Silent Dispatch & Auto-Dial:** The app silently sends this SMS to the trusted contacts. Immediately after, it uses native platform channels (`url_launcher` with `tel://`) to automatically trigger a standard cellular phone call to the primary guardian, forcing the device into speakerphone mode.

### Step 3: The Online Escalation (Safe Haven Routing)
1. **Connectivity Check:** The app checks for active internet. If online, it proceeds to Step 3.
2. **Places API Query:** The app queries the Google Places API for `type: hospital` and `type: police` within a 1km radius, sorted by distance.
3. **Instant Reroute:** The app aborts the current navigation and instantly calculates a route to the nearest safe haven.
4. **AI Feedback:** The AI announces, *"I have alerted your family. I am now routing you to the nearest safe location. Please follow my instructions."*
