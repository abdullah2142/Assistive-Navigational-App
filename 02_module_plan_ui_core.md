# Core Application & UI Module Plan (Dual-Role)

## Objective
To build the foundational Flutter application that serves two completely different interfaces based on the user's role: The highly accessible "Split-Mode Dashboard" for the disabled user, and the "Guardian Hub" for the caretaker.

## Visual Design System (Aesthetics)
The core philosophy is "Accessible Calm." The app uses **Plus Jakarta Sans** (headers) and **Inter** (body) for a professional, relaxed feel with generous spacing.

### The Themes
The UI renders dynamically based on the profile set during Onboarding.

1. **Standard "Calm" Mode (For Cognitive/PTSD/Deaf users):**
   *   *Primary Accent:* Muted Purple (`#664d8f`).
   *   *Dark Mode:* Deep Plum/Charcoal background (`#120F1D`) with soft Off-White text (`#EAE8F2`).
   *   *Light Mode:* Soft Cream background (`#F8F7FA`) with Deep Slate text (`#2D2A3B`).
2. **Low Vision / High Contrast Mode (Calibrated during Onboarding):**
   *   *Typography:* Radically increased font scaling (24pt+ base size). Hyper-spaced line heights.
   *   *Contrast:* Pure Black (`#000000`) background with Pure Yellow (`#FFFF00`) or stark White (`#FFFFFF`) text, avoiding the muted palette entirely to guarantee maximum noticeability.
   *   *Mixed Mode:* A heavy mix of immense, legible text chunks paired constantly with the AI Voice Assistant reading the text aloud.

## Step-by-Step Implementation

### Step 1: Role-Based Routing
Upon login, the app reads the user's Firebase Auth custom claims. If `role == 'caretaker'`, it routes to the Guardian Hub. If `role == 'user'`, it routes to the Split-Mode Dashboard.

### Step 2: The User Interface (Split-Mode Dashboard)
1. **The Dynamic Chat Stream (Top 60%):**
   *   Displays the AI dialogue. The AI actively prompts the user: *"You can tap the mic to speak to me, or use the keyboard to type."*
   *   Features Contextual "Suggested Chips" (e.g., [Route to Work], [Scan the next bus]) to eliminate typing.
   *   *Settings via Chat:* Users can tell the AI to "Make the text bigger," and the AI updates the app settings using Function Calling.
2. **The Interactive AI-Assisted Map (Bottom 40%):**
   *   A "Clean" Map Layout stripping away POIs. Only displays the route line and safety overlays (red shading for crime).
   *   **Massive Directional Overlays:** A giant, high-contrast directional arrow overlaid directly on the map.

### Step 3: The Caretaker Interface (Guardian Hub)
Since caretakers do not require extreme accessibility features, this interface is a standard, modern mobile dashboard (using the Standard "Calm" Theme).
1. **The Overwatch Map:** A live map showing the disabled user's current GPS location, trajectory, and battery percentage.
2. **Alert Center:** Flashes red and sounds an alarm if the disabled user presses the Magic Button or if the Virtual Guardian inactivity timer triggers.
3. **Communication Hub:** Buttons to send an *Asynchronous Memo* or trigger a *Snapshot Request*.
4. **Remote Management:** A standard settings menu where the caretaker can remotely adjust the disabled user's `UserProfile`.

### Step 4: Essential User Overlays
1. **The "Show Screen" Passerby Helper:** The user tells the AI what they need. The screen flips to landscape, turns solid bright yellow (`#E5C05C`), and displays massive black text (e.g., **"I AM VISUALLY IMPAIRED. IS THIS ROAD FLOODED?"**).
2. **The Crowdsource Reporting Hub:** A massive glassmorphism overlay with three icons: [🚨 Crime], [🚧 Road Hazard], [🧱 Accessibility Block].
    *   **Drill-Down Menus:** Clicking a main card opens specific sub-options (e.g., Clicking 'Crime' expands into [Mugging], [Harassment], [Suspicious Crowd]).
    *   **AI Custom Input:** A voice field allows the user to describe complex hazards, which the AI summarizes and pins to Firestore.
