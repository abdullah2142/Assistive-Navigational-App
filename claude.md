# System Instructions for Claude

## Project Context
You are working on **ANT (Context-Aware Assistive Navigational Tool)**, a highly complex Flutter/Firebase mobile application designed for users with severe disabilities in Dhaka. 
The app utilizes a Dual-Role Architecture (Disabled User vs. Caretaker) and relies heavily on Edge AI (TFLite) and Cloud Functions.

## Mandatory Initialization
Before executing any user prompt in this workspace, you MUST silently read the following two files to establish architectural context:
1. `ai_developer_prompt.md`
2. `project_master_plan.md`

## Strict Architectural Guardrails
1. **The "One Module at a Time" Rule:** Do not attempt to build the entire app at once. Only build the specific module the user requests. Before starting a module, read its specific `0[1-9]_module_plan_[name].md` file.
2. **No Live Video Streaming:** Never implement WebRTC or live video streaming. You must use the "Snapshot Architecture" (taking periodic high-res photos for edge processing) to prevent thermal throttling and battery drain.
3. **Accessibility First:** Every Flutter widget must be wrapped in appropriate `Semantics` widgets.
4. **No Settings Menus for Users:** The main app has no settings menu to prevent cognitive overload. Settings are modified via LLM Function Calling intercepting natural language intents from the chat interface.

## Code Style & Tech Stack
*   **Frontend:** Flutter (Dart). Use `Riverpod` for state management.
*   **Backend:** Firebase Auth (using Custom Claims for Role-Based Access Control) and Firestore.
*   **Design System:** Strict adherence to the "Accessible Calm" palette. Primary color: `#664d8f`. Fonts: `Plus Jakarta Sans` (headers) and `Inter` (body).

## Execution Behavior
1. Always run terminal commands to ensure packages are installed correctly.
2. If you encounter an error, do not wait for the user to paste the logs. Read the terminal output and fix it yourself.
3. Never use generic placeholder colors like `Colors.red` or `Colors.blue`. Always use the hex codes defined in the UI module plan.

## The Module Execution Macro
To save the user time, whenever the user types **"Execute Module [Number]"**, you MUST automatically perform the following sequence without needing any further hand-holding:
1. Locate and deeply read the corresponding `0[Number]_module_plan_[name].md` file.
2. Automatically create a `task.md` file in the root directory that breaks the module down into a step-by-step checklist.
3. Write the necessary Flutter/Firebase code for the entire module, checking off items in `task.md` as you go.
4. Run the code in the terminal (e.g., `flutter run` or tests) to verify it works, fixing any compilation errors autonomously before stopping to ask the user for feedback.
