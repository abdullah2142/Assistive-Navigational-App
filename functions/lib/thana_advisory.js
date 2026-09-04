/**
 * Current, sourced risk advisories for a single thana.
 *
 * ## The problem this exists for
 *
 * `dhaka_thana_crime_seed.js` is honest, citable, and **from 2009**. That
 * is fine for relative geography — which parts of Dhaka have historically
 * carried more street crime than others — and useless for "which
 * neighbourhood has gone bad this year". Mohammadpur is the worked example:
 * 9.35 crimes/km² in the source table, a score of 3.8, nowhere near the
 * hotspot threshold, while anyone living in Dhaka today would tell you it
 * belongs there. The citywide trend multiplier cannot fix this — it is one
 * number applied uniformly to all 41 thanas, so it can say "crime is up 12%
 * citywide" and nothing at all about *where*.
 *
 * ## Two source tiers, weighted differently
 *
 * `ai_developer_prompt.md` originally said *"do not attempt to scrape live
 * social media for crime"*; the project owner has since overruled that and
 * asked for social signals as well. They are in — but on their own tier,
 * because the reason behind the original rule does not stop being true just
 * because the rule was lifted.
 *
 * An unsourced post is weaker evidence than a published article. Rumour
 * about a neighbourhood propagates faster than correction, attaches
 * disproportionately to poorer areas, and this app converts whatever it
 * believes directly into "the app will not walk you through there" —
 * delivered to a user who cannot see the map and has no way to sanity-check
 * it. Getting that wrong is a real harm to real residents.
 *
 * So the tiers differ in what they are allowed to do, not merely in a
 * confidence number:
 *
 * - [SOURCE_NEWS] — a citable published article. Can reach any severity,
 *   including the one that promotes a thana to hotspot behaviour.
 * - [SOURCE_SOCIAL] — corroborated posts (see `social_signal.js`). Capped
 *   at [SOCIAL_MAX_SEVERITY], can never promote to hotspot on its own, and
 *   expires far sooner. It can make the router prefer another street; it
 *   cannot redraw the safety map by itself.
 *
 * Both tiers require provenance, and that is enforced ([validateAdvisory])
 * rather than merely expected — every score the routing engine produces
 * stays traceable to a URL and a date, the same discipline the seed data
 * already holds itself to.
 *
 * ## Why it is bounded and why it expires
 *
 * An advisory can only ever *raise* risk, never lower it, and only within a
 * hard cap — a news cycle should be able to make the router prefer a
 * different street, never to redraw the safety map on its own. And it
 * decays: neighbourhoods recover, coverage moves on, and a permanent
 * "dangerous" label applied to a real place on the strength of one bad month
 * is exactly the harm above with a longer half-life.
 */

const DAY_MS = 24 * 60 * 60 * 1000;

const SOURCE_NEWS = 'news';
const SOURCE_SOCIAL = 'social';
const SOURCE_TIERS = [SOURCE_NEWS, SOURCE_SOCIAL];

/**
 * The strongest a social-tier advisory is allowed to be, whatever the
 * volume behind it. A thousand posts is still a thousand posts.
 */
const SOCIAL_MAX_SEVERITY = 'high';

/**
 * Social advisories expire in a fortnight rather than two months.
 *
 * Social attention spikes and collapses far faster than a place changes,
 * so a long tail here would mostly preserve the memory of a news cycle,
 * not a fact about a neighbourhood.
 */
const SOCIAL_TTL_MS = 14 * DAY_MS;

/**
 * Severity tiers, and what each multiplies a thana's $w_1$ by.
 *
 * Capped at 2.0. Composed with the time-of-day multiplier rather than
 * replacing it, so an advisory raises the floor while the existing
 * day/night shape still does the work it already did.
 */
const ADVISORY_MULTIPLIERS = {
  // Isolated but credible reporting — a spate of snatchings, a specific
  // stretch of road.
  elevated: 1.25,
  // Sustained coverage across multiple reports.
  high: 1.5,
  // The level that also promotes the zone to notorious-hotspot temporal
  // behaviour (see `isHotspot` in `temporal_weighting.js`) — i.e. it starts
  // spiking from dusk rather than from 8 PM. Reserved for a thana under
  // active, repeated reporting, which is the Mohammadpur case.
  severe: 2.0,
};

/** Advisories at or above this tier change the zone's temporal shape. */
const HOTSPOT_SEVERITY = 'severe';

/**
 * How long an advisory stays live without being renewed.
 *
 * 60 days is long enough to outlast a single news cycle and short enough
 * that a neighbourhood is not labelled indefinitely by one. Re-reporting
 * refreshes it; silence retires it.
 */
const DEFAULT_TTL_MS = 60 * DAY_MS;

/** The last stretch of an advisory's life, over which its effect fades. */
const TAPER_MS = 14 * DAY_MS;

const SEVERITIES = Object.keys(ADVISORY_MULTIPLIERS);

/**
 * Checks an advisory is admissible before it is allowed anywhere near a
 * routing decision. Returns an error string, or null when it is fine.
 *
 * Provenance is mandatory. An advisory without a real source URL and a real
 * publication date cannot be audited later, and an unauditable claim about a
 * real neighbourhood is precisely what this whole module is structured to
 * refuse.
 */
function validateAdvisory(advisory) {
  if (!advisory || typeof advisory !== 'object') return 'advisory must be an object';
  if (typeof advisory.thanaSlug !== 'string' || advisory.thanaSlug.length === 0) {
    return 'thanaSlug is required';
  }
  if (!SEVERITIES.includes(advisory.severity)) {
    return `severity must be one of ${SEVERITIES.join(', ')}`;
  }
  const tier = advisory.sourceTier || SOURCE_NEWS;
  if (!SOURCE_TIERS.includes(tier)) {
    return `sourceTier must be one of ${SOURCE_TIERS.join(', ')}`;
  }
  if (tier === SOURCE_SOCIAL && advisory.severity === HOTSPOT_SEVERITY) {
    return `social-tier advisories cannot exceed "${SOCIAL_MAX_SEVERITY}" severity`;
  }
  if (typeof advisory.sourceUrl !== 'string' || !/^https?:\/\/\S+$/.test(advisory.sourceUrl)) {
    return 'a citable sourceUrl is required';
  }
  if (typeof advisory.sourceTitle !== 'string' || advisory.sourceTitle.trim().length === 0) {
    return 'sourceTitle is required';
  }
  const published = Date.parse(advisory.publishedAt);
  if (Number.isNaN(published)) return 'publishedAt must be an ISO date';
  return null;
}

/**
 * The multiplier an advisory contributes at [nowMs], including its taper.
 *
 * Returns 1.0 (no effect) once expired, and never returns less than 1.0 —
 * an advisory is only ever able to make the router more cautious, never
 * less. Nothing here can talk the safety engine *down*.
 */
function advisoryMultiplier(advisory, nowMs) {
  if (!advisory) return 1;
  const published = Date.parse(advisory.publishedAt);
  if (Number.isNaN(published)) return 1;
  const tier = advisory.sourceTier || SOURCE_NEWS;
  const defaultTtl = tier === SOURCE_SOCIAL ? SOCIAL_TTL_MS : DEFAULT_TTL_MS;
  const ttl = typeof advisory.ttlMs === 'number' ? advisory.ttlMs : defaultTtl;
  const age = nowMs - published;
  if (age >= ttl) return 1;

  const peak = ADVISORY_MULTIPLIERS[advisory.severity] ?? 1;
  // Full strength until the taper window, then a straight line back to
  // neutral — a cliff-edge expiry would flip a route's verdict overnight
  // for no reason the user could perceive.
  const taperStart = ttl - TAPER_MS;
  if (age <= taperStart) return peak;
  const remaining = (ttl - age) / TAPER_MS;
  return Math.max(1, 1 + (peak - 1) * remaining);
}

/**
 * Whether a live advisory is strong enough to change the temporal shape.
 *
 * Social-tier advisories never are, regardless of severity or volume —
 * promoting a real neighbourhood to a 5x night multiplier is the single
 * heaviest lever in the safety engine, and it should not be reachable
 * without a citable published source behind it.
 */
function advisoryImpliesHotspot(advisory, nowMs) {
  if (!advisory || advisory.severity !== HOTSPOT_SEVERITY) return false;
  if ((advisory.sourceTier || SOURCE_NEWS) === SOURCE_SOCIAL) return false;
  return advisoryMultiplier(advisory, nowMs) > 1;
}

/**
 * Picks the advisory that should apply when a thana has several.
 *
 * The strongest currently-live one — not the newest. A severe advisory from
 * six weeks ago says more about a place than a mild one from yesterday, and
 * quietly downgrading risk because a gentler story was published later is
 * the wrong direction to be wrong in.
 */
function strongestAdvisory(advisories, nowMs) {
  let best = null;
  let bestMultiplier = 1;
  for (const advisory of advisories || []) {
    const multiplier = advisoryMultiplier(advisory, nowMs);
    if (multiplier > bestMultiplier) {
      best = advisory;
      bestMultiplier = multiplier;
    }
  }
  return best;
}

module.exports = {
  SOURCE_NEWS,
  SOURCE_SOCIAL,
  SOURCE_TIERS,
  SOCIAL_MAX_SEVERITY,
  SOCIAL_TTL_MS,
  ADVISORY_MULTIPLIERS,
  SEVERITIES,
  HOTSPOT_SEVERITY,
  DEFAULT_TTL_MS,
  TAPER_MS,
  validateAdvisory,
  advisoryMultiplier,
  advisoryImpliesHotspot,
  strongestAdvisory,
};
