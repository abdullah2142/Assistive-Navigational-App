/**
 * Calling the project's Cloud Functions from the edge.
 *
 * Lifted out of `index.js` so the monthly crime ingest and the two new
 * collectors share one implementation of the anonymous-sign-in dance
 * rather than three copies of it.
 */

export const FIREBASE_WEB_API_KEY = 'AIzaSyAXm0kMvv5odpkkrHKRNZz2Cm6mvTx2uDg';
const FUNCTIONS_BASE = 'https://us-central1-ant-assistive-nav.cloudfunctions.net';

export const USER_AGENT =
  'ANT-AssistiveNavigationalApp/1.0 (+https://github.com/abdullah2142/Assistive-Navigational-App)';

export async function signInAnonymously() {
  const res = await fetch(
    `https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=${FIREBASE_WEB_API_KEY}`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ returnSecureToken: true }),
    },
  );
  if (!res.ok) throw new Error(`Anonymous sign-in failed: HTTP ${res.status}`);
  return res.json();
}

/**
 * Deletes the throwaway account a run signed in with.
 *
 * Non-fatal on failure, but genuinely worth doing: without it every
 * scheduled run leaves a permanent anonymous user behind in Auth, and a
 * few years of hourly-ish runs turns into a directory nobody can read.
 */
export async function deleteAccount(idToken) {
  try {
    await fetch(`https://identitytoolkit.googleapis.com/v1/accounts:delete?key=${FIREBASE_WEB_API_KEY}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ idToken }),
    });
  } catch (err) {
    console.warn('Cleanup: failed to delete throwaway auth account (non-fatal):', err);
  }
}

/** Invokes an onCall function with the callable protocol's `{data: ...}` envelope. */
export async function callFunction(name, payload, idToken) {
  const res = await fetch(`${FUNCTIONS_BASE}/${name}`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${idToken}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ data: payload }),
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok || body.error) {
    throw new Error(`${name} failed: ${JSON.stringify(body)}`);
  }
  return body.result;
}

/**
 * Runs [work] with a short-lived anonymous session, cleaning up afterwards
 * whether it succeeded or not.
 */
export async function withAuth(work) {
  const { idToken } = await signInAnonymously();
  try {
    return await work(idToken);
  } finally {
    await deleteAccount(idToken);
  }
}
