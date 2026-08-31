# Community Crowdsourcing & Temporal Safety Module Plan

## Objective
To build a self-sustaining data engine that dynamically updates the routing weights for Crime ($w_1$) and Terrain Hazards ($w_2$). Because Dhaka lacks reliable digital infrastructure for pedestrian accessibility and real-time noise/safety levels, ANT relies entirely on its users and time-based predictive modeling to stay accurate.

## Tech Stack
*   **Database:** Firebase Firestore (for storing geospatial hazard pins and Thana typologies).
*   **Backend Logic:** Google Cloud Functions (to handle the data decay cron jobs and the Temporal Weighting algorithms).

## Step-by-Step Implementation

### Step 1: Multi-Modal Reporting (The Inputs)
Users must be able to report hazards instantly without breaking their stride or looking at the screen.
1. **Voice Input (Primary):** The STT engine recognizes specific reporting intents (e.g., "Report a broken road here," "Flag an open manhole," "Report a mugging").
2. **UI Input (Deaf/Cognitive):** A persistent, high-contrast "Report Hazard" button on the main screen that expands into three massive icons: *Crime*, *Road Blocked*, and *Stairs/Unpaved*.
3. **Passive Input (Automated):** When the edge TFLite camera detects an immediate structural hazard (like an open sewer) with high confidence, it silently drops a background pin to Firestore without bothering the user.

### Step 2: Data Validation & Anti-Spam (The Logic)
We cannot blindly trust a single user report to shut down a major road in the routing engine.
1. **Yellow Flag (Warning):** When 1 report is received, a pin is dropped. The app warns the next user approaching the area ("Caution: a user reported a broken road ahead") but does *not* reroute them.
2. **Red Flag (Active Reroute):** If 3 independent users report the exact same hazard type within a 10-meter radius in a 24-hour window, the hazard is confirmed. The $w_1$ or $w_2$ score mathematically spikes, and the app actively reroutes all future users away from that path.

### Step 3: Time-to-Live (Data Decay)
Hazards aren't permanent. A Cloud Function cron job runs every hour to scrub old data and prevent Dhaka from becoming entirely "red-zoned."
1. **Crime Spikes (e.g., Mugging):** Decays back to baseline after 48 hours.
2. **Temporary Blocks (e.g., Construction/Waterlogging):** Decays after 7 days unless re-flagged.
3. **Structural Blocks (e.g., Stairs/No Ramp):** Permanent, until a user explicitly flags it as "Resolved."

### Step 4: Temporal Crime Weighting (Time-of-Day Multiplier)
Crime is not static; it is deeply tied to the time of day. Relying *only* on crowdsourcing is reactive. We need a proactive system.
1. **The Multiplier Formula:** $w_1(t) = \text{Base Score} \times \text{Temporal Multiplier}$.
2. **Zone Typologies:** When building the static DMP crime map, tag areas (Thanas/polygons) with a typology:
    *   *Commercial/Office (e.g., Motijheel):* Safe at 2:00 PM, highly dangerous and empty at 11:00 PM. The multiplier automatically spikes $w_1$ by 3x after 8 PM.
    *   *Notorious Hotspots (e.g., specific alleys in Mirpur):* High base score always, but multiplier maxes out at 5x after dusk.
    *   *Residential:* Relatively stable multiplier.
3. **The Outcome:** Even without active crowdsourced reports, if a disabled user requests a route at 11:30 PM, the temporal algorithm mathematically forces them to stay on brightly lit main arterial roads and entirely avoids "notorious" shortcuts or empty commercial districts.
