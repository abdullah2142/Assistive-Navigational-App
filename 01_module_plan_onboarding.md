# Onboarding & Setup Module Plan (Dual-Role Architecture)

## Objective
To construct a highly guided initial setup phase that first separates users into two distinct roles: the **Disabled User** and the **Caretaker**. It then captures specific accessibility needs, calibrates visual settings, and securely pairs the two devices.

## Tech Stack
*   **Framework:** Flutter
*   **Auth & Database:** Firebase Auth (Role-Based Access Control) and Firestore.

## Step-by-Step Implementation

### Step 1: Role Selection & Pairing
1. **Launch:** Upon first opening, the app asks: `[I need assistance]` or `[I am a Caretaker]`.
2. **Caretaker Setup:** If Caretaker is selected, the app generates a 6-digit pairing code (or QR code) and waits.
3. **Disabled User Setup:** If Disabled User is selected, they enter the 6-digit code provided by their caretaker. This securely links their Firestore profiles.

### Step 2: Granular Disability Profiling & Calibration
The AI conducts a nuanced interview to build a deeply personalized `UserProfile`:
1. **Vision Level:** *"Do you have no vision, partial/low vision, or full vision?"* 
    *   *If Low Vision:* The app triggers a **Visual Calibration Phase**. It displays sample text blocks and colors, asking the user to adjust a slider until the contrast and font size are perfectly legible for their specific eye condition. This activates the specialized "Low Vision Theme".
2. **Mobility Aids:** *"Do you use a white cane, a wheelchair, or walk unassisted?"*
3. **Cognitive & Anxiety Thresholds:** *"Do crowded places make you anxious? Do you find complex instructions hard to follow?"*
4. **Deaf/Hearing Profiling:** *"Are you deaf or hard of hearing?"*

### Step 3: AI Verbosity & Safety Nets
1. **Information Density:** The user chooses how "chatty" the AI should be (Minimalist vs. Descriptive) and selects a voice.
2. **Magic Button Contacts:** The user (or caretaker remotely) assigns trusted contacts.
3. **Safe Havens:** The user sets "Home" and a "Safe Place".

### Step 4: The Automation Lock-In & Natural Language Settings
1. **The Lock:** The setup screen disappears forever. The app enters **Self-Sustaining Mode**. To prevent accidental clicks and cognitive clutter, traditional settings menus are completely removed.
2. **How to Change Settings:** If the user wants to change a setting, they simply tell the AI via chat or voice (e.g., *"Change my emergency contact to Mom"*, or *"Make the text larger"*). The LLM processes this intent and updates the internal state.
3. **Remote Management:** Alternatively, the Caretaker can open their companion app and remotely toggle settings, which push instantly to the user's phone via Firestore.
