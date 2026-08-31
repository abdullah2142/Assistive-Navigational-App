# Virtual Guardian Module Plan

## Objective
To provide peace of mind to trusted contacts by enabling live location tracking and automated distress alerts if the user becomes unresponsive or enters a hazardous area.

## Tech Stack
*   **Database:** Firebase Realtime Database (better suited for high-frequency, low-latency live GPS updates than Firestore).
*   **Background Processing:** Flutter background isolates / `flutter_background_service`.
*   **Notifications:** Firebase Cloud Messaging (FCM) for push notifications to the guardian's companion app.

## Step-by-Step Implementation

### Step 1: The Location Broadcasting Pipeline
1. **Permission Handling:** The app requests "Always Allow" location permissions during onboarding.
2. **Foreground/Background Service:** We implement a persistent background service in Flutter.
3. **Throttled Updates:** While moving, the app sends GPS coordinates (Lat, Lng, Heading, Speed) to Firebase Realtime Database every 5 seconds. If stationary, it throttles to every 30 seconds to save battery.

### Step 2: The Inactivity Detection Algorithm
1. **Sensor Fusion:** The background service continually monitors the GPS speed and the device accelerometer.
2. **The Timer:** If GPS speed == 0 AND accelerometer variance is below a threshold (meaning the phone is completely flat/still) for > 5 minutes:
   - The app triggers a local "Are you okay?" voice prompt and haptic pulse.
3. **Escalation:** If the user does not respond to the local prompt within 30 seconds, the app escalates.

### Step 3: Triggering Alerts & Companion View
1. **Automated Alert:** The app writes an `EMERGENCY_STATUS = true` flag to Firebase.
2. **Push Notification:** A Firebase Cloud Function listens for this flag and instantly sends a high-priority push notification (via FCM) to the trusted guardian's phone: *"ANT Alert: [User] has stopped moving and is unresponsive."*
3. **Companion Web/App View:** The guardian clicks the notification and opens a lightweight web-view or companion app. It displays a live Google Map showing the user's exact coordinate, battery level, and last known trajectory.

### Step 4: Asynchronous Check-In (Privacy-Preserving)
To prevent cognitive overload and preserve dignity, live video/audio spectating is strictly prohibited. Instead, the companion app supports asynchronous check-ins:
1. **Asynchronous Memos:** The guardian can type or record a memo. The AI waits for a safe moment (e.g., when the user is not actively crossing a road) and announces: *"Message from [Guardian]: Are you okay?"* The user can reply via voice without touching the screen.
2. **Snapshot Requests:** If the guardian is highly concerned, they can trigger a "Snapshot Request." The user receives a prompt: *"Your guardian requests a photo of your surroundings. Allow?"* If approved, the camera takes one high-res picture and sends it securely to the companion app, saving battery and preserving privacy.
