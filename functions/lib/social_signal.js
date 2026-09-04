/**
 * Turns individual social-media posts about a Dhaka neighbourhood into a
 * corroborated advisory — or, far more often, into nothing.
 *
 * ## The rule this is built on
 *
 * Module 5 already answered the question "when do you believe an
 * unverified report?", for crowdsourced hazard pins: **three independent
 * reporters inside a window**, counted by distinct author, never by volume.
 * One person posting four times is one person. That rule exists because a
 * single account must not be able to close a road for everybody, and the
 * reasoning transfers to social posts exactly — with the stakes raised,
 * because the subject here is a whole neighbourhood rather than one pothole.
 *
 * So a scraped post does nothing on its own. It sits as a signal until
 * enough *separate* accounts have said something compatible about the same
 * thana in the same short window, and only then does it become a
 * social-tier advisory — which is itself capped, unable to trigger hotspot
 * behaviour, and expires in a fortnight (`thana_advisory.js`).
 *
 * ## What this deliberately does not do
 *
 * It does not attempt sentiment analysis, virality weighting, or engagement
 * scoring. A post with ten thousand shares is still one person's claim, and
 * amplification correlates with outrage rather than with accuracy. Counting
 * distinct accounts is a cruder signal and a far more honest one.
 *
 * It also stores the post URL and author handle for every signal, so any
 * elevated score traces back to specific, checkable posts. An advisory that
 * cannot be audited should not be able to change what the app tells a
 * blind user about a real place.
 */

const HOUR_MS = 60 * 60 * 1000;

/**
 * Distinct accounts required before social chatter counts at all.
 *
 * Matches Module 5's Red Flag threshold deliberately — the same question,
 * answered the same way, so there is one anti-spam rule in this codebase
 * rather than two that can drift apart.
 */
const MIN_DISTINCT_AUTHORS = 3;

/** Signals older than this stop counting toward corroboration. */
const CORROBORATION_WINDOW_MS = 72 * HOUR_MS;

/**
 * Volume needed for the higher of the two severities social is allowed to
 * reach. Still counted in distinct accounts, not posts.
 */
const HIGH_SEVERITY_AUTHORS = 6;

/**
 * A signal is admissible only with provenance. Returns an error string, or
 * null when it is fine.
 *
 * `authorHandle` matters as much as the URL: without it, corroboration
 * cannot be counted by *account*, and a single actor posting from one
 * timeline would satisfy the threshold on their own — which is the exact
 * failure the threshold exists to prevent.
 */
function validateSignal(signal) {
  if (!signal || typeof signal !== 'object') return 'signal must be an object';
  if (typeof signal.thanaSlug !== 'string' || signal.thanaSlug.length === 0) {
    return 'thanaSlug is required';
  }
  if (typeof signal.authorHandle !== 'string' || signal.authorHandle.trim().length === 0) {
    return 'authorHandle is required — corroboration is counted per account';
  }
  if (typeof signal.postUrl !== 'string' || !/^https?:\/\/\S+$/.test(signal.postUrl)) {
    return 'a postUrl is required so the claim stays checkable';
  }
  if (Number.isNaN(Date.parse(signal.postedAt))) return 'postedAt must be an ISO date';
  return null;
}

/** Signals still inside the corroboration window. */
function liveSignals(signals, nowMs) {
  return (signals || []).filter((s) => {
    const posted = Date.parse(s.postedAt);
    return !Number.isNaN(posted) && nowMs - posted <= CORROBORATION_WINDOW_MS;
  });
}

/**
 * The advisory a thana's accumulated signals justify, or null.
 *
 * Null is the normal, expected answer. Most chatter about most places most
 * of the time should change nothing, and a function like this earns its
 * place by how reliably it declines rather than by how often it fires.
 */
function deriveAdvisory(thanaSlug, signals, nowMs) {
  const live = liveSignals(signals, nowMs);
  const authors = new Set(live.map((s) => s.authorHandle.trim().toLowerCase()));
  if (authors.size < MIN_DISTINCT_AUTHORS) return null;

  // Newest post is what the advisory is dated from, so it tapers out from
  // the last time anyone actually said anything rather than from whenever
  // it happened to be derived.
  const newest = live.reduce((latest, s) => {
    const posted = Date.parse(s.postedAt);
    return posted > latest ? posted : latest;
  }, 0);

  const representative = live.find((s) => Date.parse(s.postedAt) === newest) || live[0];

  return {
    thanaSlug,
    sourceTier: 'social',
    severity: authors.size >= HIGH_SEVERITY_AUTHORS ? 'high' : 'elevated',
    // Attributed honestly as aggregated chatter, not dressed up as
    // reporting — this string is what surfaces to the client alongside an
    // elevated score.
    sourceTitle: `${authors.size} separate accounts posted about ${thanaSlug} in the last 3 days`,
    sourceUrl: representative.postUrl,
    publishedAt: new Date(newest).toISOString(),
    corroboratingAuthors: authors.size,
    postCount: live.length,
  };
}

module.exports = {
  MIN_DISTINCT_AUTHORS,
  HIGH_SEVERITY_AUTHORS,
  CORROBORATION_WINDOW_MS,
  validateSignal,
  liveSignals,
  deriveAdvisory,
};
