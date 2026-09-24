# ANT Guardian Hub

Standalone browser companion for testing the caretaker experience without a
second phone. It uses the app's existing Firebase anonymous-auth and pairing
code contract; the paired Android/iOS app continues to use the same Firestore
documents and rules.

## Local preview

1. Install Node.js 20 or later.
2. Create `.env.local` with the Firebase **web app** values as `VITE_` entries:
   `API_KEY`, `APP_ID`, `AUTH_DOMAIN`, `PROJECT_ID`, `STORAGE_BUCKET`, and
   `MESSAGING_SENDER_ID` (for example, `VITE_FIREBASE_API_KEY=...`). The
   local file is git-ignored. The repository's existing `DefaultFirebaseOptions.web`
   can be used to fill these values.
3. From this directory, run `npm install` once and then `npm run dev`.
4. Open the local URL in the browser, generate a code, and enter it in the ANT
   app's existing caretaker pairing flow.

For the usual same-computer test, Vite prints a URL such as
`http://localhost:5173/`. Leave the dev server and browser tab open while
pairing. The code is single-use and expires after 15 minutes. No Firebase
Hosting setup or deployment is needed for this local preview. Both clients
need an internet connection to reach Firebase. Use `npm run build` to verify
the TypeScript production build without deploying it.

The Firebase project must have anonymous Authentication enabled and the
preview host must be an authorized Firebase Auth domain. Microphone recording
requires a secure browser origin; localhost qualifies. There is no Firebase
Hosting target configured yet, so this preview has not been published.

## Supported caretaker actions

- Pair the browser caretaker to an existing ANT user with the app's one-time,
  15-minute code.
- See the user's latest shared location and caretaker-resolvable alerts.
- Exchange text, request a one-frame snapshot, and receive image/snapshot
  messages.
- Send a JPEG-reduced image and record a short WAV voice memo that the app's
  existing voice-message player can open. Incoming voice memos have native
  browser playback controls.

The client uses OpenStreetMap tiles with attribution. It does not include the
mobile app's route planning or remote settings controls.

See [`../docs/app_documentation.md`](../docs/app_documentation.md) for the full
ANT module and data-flow guide, including local Guardian Hub testing.
