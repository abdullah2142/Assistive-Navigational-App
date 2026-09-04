import { THANAS } from './thana_index.js';

/**
 * Decides which Dhaka thana — if any — a piece of text is actually about.
 *
 * ## Why this is the strictest thing in the collector
 *
 * Everything downstream trusts this. Get it wrong and the app tells a blind
 * user that a neighbourhood is dangerous on the strength of an article about
 * somewhere else entirely. The very first item in The Daily Star's
 * crime feed while this was being written was a killing in **Raozan,
 * Chattogram** — 250 km from Dhaka. A naive keyword match would have been
 * wrong on the first row of real data.
 *
 * Two named traps this exists to avoid:
 *
 * 1. **Shared thana names.** Dhaka has a Kotwali and a Cantonment; so does
 *    Chattogram. So does more or less every old district town. The name
 *    alone is not evidence of location.
 * 2. **Passing mentions.** An article datelined Sylhet that quotes a
 *    minister speaking in Gulshan is not about Gulshan.
 *
 * So a match requires the thana name *and* the absence of a competing
 * location, and returns null on anything doubtful. Null is the safe answer
 * and by far the most common one — most crime reporting in Bangladesh is
 * not about a Dhaka thana, and a collector that flags a neighbourhood only
 * when it is genuinely confident is worth far more than one with reach.
 */

/**
 * Districts and cities whose presence means the story is probably not
 * about Dhaka. Checked against the whole text; if one appears and "Dhaka"
 * does not, the item is discarded regardless of what else it mentions.
 */
const COMPETING_LOCATIONS = [
  'chattogram', 'chittagong', 'sylhet', 'khulna', 'rajshahi', 'barishal', 'barisal',
  'rangpur', 'mymensingh', 'cumilla', 'comilla', 'jashore', 'jessore', 'bogura', 'bogra',
  'narayanganj', 'gazipur', 'narsingdi', 'munshiganj', 'manikganj', 'tangail', 'faridpur',
  'kishoreganj', "cox's bazar", 'coxs bazar', 'raozan', 'savar', 'ashulia',
  'চট্টগ্রাম', 'সিলেট', 'খুলনা', 'রাজশাহী', 'বরিশাল', 'রংপুর', 'ময়মনসিংহ', 'কুমিল্লা',
  'নারায়ণগঞ্জ', 'গাজীপুর', 'সাভার',
];

/** Words that make a text a crime story rather than any other news. */
const CRIME_TERMS = [
  'mugging', 'mugged', 'snatching', 'snatcher', 'robbery', 'robbed', 'robber',
  'stabbed', 'stabbing', 'murder', 'killed', 'shot', 'assault', 'assaulted',
  'extortion', 'gang', 'mastaan', 'mastan', 'hijack', 'looted', 'looting',
  'harassment', 'harassed', 'rape', 'abduct', 'abducted', 'kidnap', 'kidnapped',
  'chhintai', 'theft', 'burglary', 'attacked', 'violence', 'crime',
  'ছিনতাই', 'ডাকাতি', 'খুন', 'হত্যা', 'ছুরিকাঘাত', 'চাঁদাবাজি', 'অপহরণ',
  'ধর্ষণ', 'মারধর', 'সন্ত্রাস', 'চুরি', 'অপরাধ',
];

/** Lowercased, punctuation-stripped words, Bangla block preserved. */
export function words(text) {
  return String(text || '')
    .toLowerCase()
    .split(/\s+/)
    .map((w) => w.replace(/[^\wঀ-৿]/g, ''))
    .filter(Boolean);
}

/**
 * The longest suffix a word may carry and still count as the same word.
 *
 * Covers English plurals and verb endings ("snatcher" -> "snatchers",
 * "mugging" -> "muggings") and, more importantly, Bangla case marking,
 * which attaches directly to the noun: গুলশান -> গুলশানে, মোহাম্মদপুর ->
 * মোহাম্মদপুরে. Almost every real Bangla sentence naming a place uses the
 * inflected form, so exact equality would miss the common case entirely.
 */
const MAX_SUFFIX = 3;

/** Short stems carry too little evidence to allow a suffix match. */
const MIN_STEM = 3;

function tokenMatches(token, target) {
  if (token === target) return true;
  if (target.length < MIN_STEM) return false;
  // Only ever a *trailing* extension, never arbitrary containment — this is
  // what keeps "Adabor" from matching "Adaborough" and keeps the whole
  // function from degenerating into the substring test it exists to avoid.
  return token.startsWith(target) && token.length - target.length <= MAX_SUFFIX;
}

/** Whole-word (or whole-phrase) containment. Never a substring test. */
export function containsPhrase(tokens, phrase) {
  const target = words(phrase);
  if (target.length === 0) return false;
  if (target.length === 1) return tokens.some((t) => tokenMatches(t, target[0]));
  for (let i = 0; i + target.length <= tokens.length; i++) {
    // Only the final word of a phrase may be inflected — "Tejgaon Ind Area"
    // takes its case marking at the end, not in the middle.
    if (target.every((t, j) => (j === target.length - 1 ? tokenMatches(tokens[i + j], t) : tokens[i + j] === t))) {
      return true;
    }
  }
  return false;
}

export function mentionsCrime(text) {
  return containsAnyPhrase(words(text), CRIME_TERMS);
}

function containsAnyPhrase(tokens, phrases) {
  return phrases.some((p) => containsPhrase(tokens, p));
}

/**
 * The thana [text] is about, or null.
 *
 * Returns null — deliberately — when more than one thana is named. An
 * article comparing crime across three neighbourhoods should not raise the
 * score of whichever happened to be mentioned first.
 */
export function matchThana(text) {
  const tokens = words(text);
  if (tokens.length === 0) return null;

  const mentionsDhaka = containsPhrase(tokens, 'dhaka') || containsPhrase(tokens, 'ঢাকা');
  if (!mentionsDhaka && containsAnyPhrase(tokens, COMPETING_LOCATIONS)) {
    // A Chattogram Kotwali is not a Dhaka Kotwali.
    return null;
  }

  const hits = THANAS.filter(
    (t) => containsPhrase(tokens, t.en) || containsPhrase(tokens, t.bn),
  );
  // Exactly one, or nothing. Ambiguity is not something to resolve by
  // picking.
  return hits.length === 1 ? hits[0] : null;
}

/**
 * Whether an item is worth spending a Gemini call on at all.
 *
 * The cheap filters run first on purpose: most items in a general news feed
 * are not crime, and most crime stories are not about a Dhaka thana. Paying
 * for a model call to establish that would be the single largest avoidable
 * cost in this pipeline.
 */
export function isCandidate(item) {
  const text = `${item.title || ''} ${item.summary || ''}`;
  if (!mentionsCrime(text)) return null;
  const thana = matchThana(text);
  return thana ? { ...item, thana } : null;
}

export { COMPETING_LOCATIONS, CRIME_TERMS };
