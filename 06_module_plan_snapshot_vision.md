# Snapshot Vision Module Plan

## Objective
To implement the on-demand, camera-based visual analysis system that detects hazards and reads transit information without overheating the device or consuming excessive cellular data.

## Tech Stack
*   **Camera Integration:** Flutter `camera` plugin.
*   **Edge Processing (Local):** TensorFlow Lite (TFLite) running a quantized YOLOv8-Nano model.
*   **Cloud Processing:** Google Cloud Vision API.

## Step-by-Step Implementation

### Step 1: The "Stationary Sweep" Protocol
1. **Trigger:** The user arrives at a complex environment (e.g., a bus stop) and asks the AI, "What bus is this?" or presses a physical volume button mapped to the Sweep action.
2. **Audio Prompt:** The AI instructs: *"Please stand still and slowly pan your phone from left to right."*
3. **Capture:** The Flutter camera plugin silently captures 3 high-resolution frames over a 3-second window.

### Step 2: Edge Processing (The Immediate Hazard Check)
1. **Local Inference:** Before sending anything to the internet, the 3 frames are passed to the local TFLite YOLO model on the phone.
2. **Hazard Detection:** The YOLO model is trained on a specific dataset of physical dangers (Cars, Bikes, Open Manholes, Curbs).
3. **Instant Alert:** If a car or immediate threat is detected dangerously close, the app instantly aborts the sweep and triggers the "Long Continuous Buzz" haptic alarm, preventing accidents with zero latency.

### Step 3: Cloud Vision & OCR (The Information Extraction)
1. **Data Upload:** If the edge model determines the scene is physically safe, the clearest frame is compressed and sent to the Google Cloud Vision API.
2. **Text & Object Extraction:** The Vision API performs Optical Character Recognition (OCR) to extract Bangla text from signs and buses.
3. **Data Verification:** The extracted text (e.g., "Bus Route 6") is cross-referenced with a Firebase database of known Dhaka transit routes.
4. **Feedback:** The result is passed back to the Bangla AI Assistant, which calmly announces: *"The bus approaching is Route 6, heading to Mirpur."*

### Step 4: Vision-Based Micro-Location (Edge)
1. **Curb Detection:** When the GPS indicates the user is nearing an intersection, the camera periodically takes low-res background snapshots.
2. **Line/Edge Tracking:** A specialized OpenCV algorithm or TFLite model scans these snapshots strictly for sidewalk edges or zebra crossings to provide millimeter-level confirmation of when to stop walking, fixing the 10-meter GPS inaccuracy.
