/**
 * A ledger of individual crime incidents attributed to a Dhaka thana.
 *
 * ## The gap this closes
 *
 * The safety engine had two ways to learn that a neighbourhood is currently
 * worse than its 2009 baseline, and both were starved:
 *
 * - **Advisories** (`thana_advisory.js`) require a model to judge that an
 *   article describes an *ongoing pattern*. The classifier is told — for
 *   good reasons — that `none` is the most common and correct answer, so a
 *   single reported mugging never becomes an advisory.
 * - **The learned baseline** (`learned_baseline.js`) counts months in which
 *   a thana had evidence, and the only news-shaped thing feeding it was an
 *   advisory.
 *
 * The result, measured against live feeds: the news collector produces
 * roughly one confirmed Dhaka-thana crime story per run, every one of them
 * an isolated incident, every one correctly classified `none` — and so the
 * `thanaAdvisories` collection had never been written to *at all*, and the
 * memory that was supposed to stop a neighbourhood reverting to its 2009
 * score had never had anything to remember.
 *
 * ## What changes
 *
 * A single incident is not evidence of anything, and this does not treat it
 * as such. But *counting* incidents is a different question from *judging*
 * them, and the matcher already answers the counting question reliably: it
 * confirmed the story is about crime and names exactly one Dhaka thana,
 * with no competing location. That is a fact, not an interpretation, and it
 * costs no model call to record.
 *
 * So incidents are recorded individually and turn into evidence only in
 * bulk: [INCIDENTS_PER_EVIDENCE_MONTH] distinct incidents inside one
 * calendar month makes that month count, and the existing baseline still
 * needs three such months before it moves the score at all, still saturates
 * at 1.6x, and still decays out of a 24-month window on its own.
 *
 * ## What deliberately does not change
 *
 * Incidents never touch the score directly. They can only ever reach it
 * through the slow, capped, self-decaying path that already exists — the
 * one designed so that no news cycle can label a real neighbourhood. And
 * social posts are still excluded entirely: corroborated chatter can raise
 * a temporary advisory, and it still cannot edit what the app believes
 * about a place.
 */

/**
 * Distinct incidents inside one calendar month for that month to count as
 * evidence.
 *
 * Three, matching every other corroboration threshold in this codebase —
 * Module 5's Red Flag, social corroboration, and the baseline's own
 * minimum. One report is news; three separate reports in one month in one
 * thana is a month worth remembering.
 */
const INCIDENTS_PER_EVIDENCE_MONTH = 3;

/**
 * How long a recorded incident is kept.
 *
 * A little over the baseline's own 24-month window, so an incident is
 * always still present when the month it belongs to is still countable, and
 * is swept shortly after that month ages out. Keeping them longer would be
 * accumulating data nothing can read.
 */
const INCIDENT_RETENTION_MS = 25 * 31 * 24 * 60 * 60 * 1000;

/** The shape every generated thana slug takes. */
const SLUG_PATTERN = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;

/** `YYYY-MM` in Dhaka's fixed UTC+6 offset — the same clock the baseline uses. */
function periodOf(ms) {
  return new Date(ms + 6 * 60 * 60 * 1000).toISOString().slice(0, 7);
}

/**
 * A stable document id for an incident, derived from its source URL.
 *
 * Dedup is by URL and it has to be, because the same story appears in a
 * section feed and the outlet's general feed, and every run re-reads the
 * last three weeks of articles. Without this, one article would be counted
 * dozens of times and three re-reads of a single mugging would manufacture
 * an evidence month on their own — exactly the failure the threshold exists
 * to prevent.
 *
 * FNV-1a rather than a crypto hash: this is a dedup key, not a secret, and
 * it has to produce the same id from the Worker and from a backfill script
 * without either depending on a hashing library.
 */
function incidentId(sourceUrl) {
  const url = String(sourceUrl || '').trim().toLowerCase();
  let hash = 0x811c9dc5;
  for (let i = 0; i < url.length; i++) {
    hash ^= url.charCodeAt(i);
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return `i_${hash.toString(16).padStart(8, '0')}_${url.length}`;
}

/**
 * Normalises an incident submission, or throws with a reason.
 *
 * A citable URL and a real publication date are both mandatory, for the
 * same reason they are mandatory on advisories: anything that can influence
 * what the app tells a blind user about a real neighbourhood has to be
 * traceable back to something a person can go and read.
 */
function validateIncident(input, nowMs) {
  const thanaSlug = String(input?.thanaSlug || '').trim();
  if (!thanaSlug) throw new Error('thanaSlug is required');
  // The slug is used directly as a Firestore document id, and Firestore
  // rejects some shapes outright — anything matching `__.*__` is reserved,
  // `.`/`..` are illegal, and `/` would silently address a subcollection.
  // Without this check those come back to the caller as a bare INTERNAL,
  // which is what a malformed slug actually produced when probed against
  // the deployed function. Every real slug is lowercase-alphanumeric with
  // hyphens (`biman-bandar`, `tejgaon-industrial-area`), so the tight
  // pattern costs nothing and turns a 500 into a sentence.
  if (!SLUG_PATTERN.test(thanaSlug)) throw new Error(`Malformed thanaSlug: ${thanaSlug}`);

  const sourceUrl = String(input?.sourceUrl || '').trim();
  if (!/^https?:\/\//i.test(sourceUrl)) throw new Error('a citable sourceUrl is required');

  const publishedAtMs = Date.parse(input?.publishedAt);
  if (!Number.isFinite(publishedAtMs)) throw new Error('a real publishedAt is required');
  // A future date is a parsing bug in a feed, not a scoop. Silently
  // accepting one would put an incident in a month that has not happened.
  if (publishedAtMs > nowMs + 24 * 60 * 60 * 1000) throw new Error('publishedAt is in the future');
  if (nowMs - publishedAtMs > INCIDENT_RETENTION_MS) throw new Error('publishedAt is older than the window');

  return {
    thanaSlug,
    sourceUrl,
    headline: String(input?.headline || '').slice(0, 300),
    outlet: String(input?.outlet || '').slice(0, 120),
    publishedAt: new Date(publishedAtMs).toISOString(),
    period: periodOf(publishedAtMs),
    recordedAt: new Date(nowMs).toISOString(),
  };
}

/** Whether a stored incident has aged past [INCIDENT_RETENTION_MS]. */
function isStale(incident, nowMs) {
  const ms = Date.parse(incident?.publishedAt);
  if (!Number.isFinite(ms)) return true;
  return nowMs - ms > INCIDENT_RETENTION_MS;
}

/**
 * The evidence months a thana's incidents justify.
 *
 * Counts **distinct source URLs** per month rather than documents, so a
 * re-import or a backfill that wrote the same story under two ids cannot
 * inflate a month past the threshold.
 */
function evidenceMonthsFromIncidents(incidents, nowMs) {
  const byPeriod = new Map();
  for (const incident of incidents || []) {
    if (!incident || isStale(incident, nowMs)) continue;
    const period = incident.period || periodOf(Date.parse(incident.publishedAt));
    if (!/^\d{4}-\d{2}$/.test(period)) continue;
    if (!byPeriod.has(period)) byPeriod.set(period, new Set());
    byPeriod.get(period).add(String(incident.sourceUrl || '').toLowerCase());
  }
  return [...byPeriod.entries()]
    .filter(([, urls]) => urls.size >= INCIDENTS_PER_EVIDENCE_MONTH)
    .map(([period]) => period)
    .sort();
}

/**
 * Merges newly derived evidence months into a zone's stored list.
 *
 * Returns null when nothing changed, so the hourly sweep can skip the
 * write — which is the overwhelmingly common case and the difference
 * between a free sweep and one that rewrites every thana document every
 * hour.
 *
 * Unlike `recordEvidenceMonth`, this can add *past* months: an incident
 * ledger is evidence about when things happened, and a month that crosses
 * the threshold on the third article should count from the month those
 * articles were published, not from the day we noticed.
 */
function mergeEvidenceMonths(existing, derived, isWithinWindow, nowMs) {
  const current = Array.isArray(existing) ? existing : [];
  const merged = [...new Set([...current, ...(derived || [])])]
    .filter((p) => isWithinWindow(p, nowMs))
    .sort();

  const before = [...new Set(current)].sort();
  if (merged.length === before.length && merged.every((p, i) => p === before[i])) return null;
  return merged;
}

module.exports = {
  INCIDENTS_PER_EVIDENCE_MONTH,
  INCIDENT_RETENTION_MS,
  periodOf,
  incidentId,
  validateIncident,
  isStale,
  evidenceMonthsFromIncidents,
  mergeEvidenceMonths,
};
