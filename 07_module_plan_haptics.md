# Haptics & Multimodal Feedback Module Plan

## Objective
To create a simple, instinctive physical language using the smartphone's native vibration motor to guide users without causing sensory or cognitive overload.

## Tech Stack
*   **Hardware Interface:** Flutter `haptic_feedback` and `vibration` packages (to access native iOS CoreHaptics and Android Vibrator APIs).

## Step-by-Step Implementation

### Step 1: Defining the Haptic Language
We will restrict the haptic dictionary to exactly three distinct patterns to completely eliminate cognitive overload.
1. **The Navigational Pulse (Single Buzz):**
   - *Pattern:* 100ms vibration.
   - *Meaning:* A gentle nudge to indicate a standard navigation turn (e.g., "Turn Left in 10 meters"). Always accompanied by a voice prompt.
2. **The Confirmation Pulse (Double Buzz):**
   - *Pattern:* 100ms vibration -> 50ms pause -> 100ms vibration.
   - *Meaning:* Positive reinforcement. Used when arriving at the destination, when the correct bus is detected, or when the "Magic Button" SOS is successfully sent.
3. **The Hazard Alarm (Long Continuous Buzz):**
   - *Pattern:* 1000ms harsh, max-intensity vibration.
   - *Meaning:* Immediate danger. Stop moving immediately. Triggered by the Edge Vision model detecting a fast-approaching vehicle or an open manhole.

### Step 2: System Triggers & Integration
1. **Routing Engine Triggers:** The Map/Routing module calculates distance to the next waypoint. When distance < 10 meters, it triggers the Navigational Pulse.
2. **Computer Vision Triggers:** The TFLite edge model is directly wired to the hardware vibrator. If a bounding box for an "Obstacle" exceeds a certain size threshold (indicating it is very close), it bypasses the UI thread and instantly triggers the Hazard Alarm.

### Step 3: Accessibility Customization
1. **Intensity Scaling:** The initial setup phase allows users to test the vibrations. Older devices have weaker motors, so the app will allow setting the default vibration amplitude to High, Medium, or Low.
2. **Sensory Overload Protection:** If the app detects continuous hazards in a crowded environment, it will throttle the Hazard Alarm (e.g., no more than 1 alarm every 5 seconds) to prevent panicking the user, relying instead on the AI's calming voice to suggest moving to a quieter area.
