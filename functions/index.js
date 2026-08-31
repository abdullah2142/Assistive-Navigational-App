const { onDocumentWritten } = require("firebase-functions/v2/firestore");
const { initializeApp } = require("firebase-admin/app");
const { getAuth } = require("firebase-admin/auth");

initializeApp();

/**
 * Module 1 — Role-Based Access Control.
 *
 * The client never sets its own Firebase Auth custom claim (that would let
 * a compromised/rooted client grant itself Caretaker access to someone
 * else's data). Instead the client writes a plain `role` field on
 * `users/{uid}` during onboarding, and this trigger is the only thing
 * allowed to promote that into a verified custom claim on the user's ID
 * token. Firestore security rules (not included here) should then key off
 * `request.auth.token.role`, not the `users/{uid}.role` field, wherever a
 * read/write needs to be role-gated.
 */
exports.onUserRoleWritten = onDocumentWritten("users/{uid}", async (event) => {
  const uid = event.params.uid;
  const after = event.data?.after?.data();
  if (!after || !after.role) return;

  const before = event.data?.before?.data();
  if (before && before.role === after.role) return;

  await getAuth().setCustomUserClaims(uid, { role: after.role });
});
