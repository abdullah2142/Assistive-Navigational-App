/**
 * The network-facing half of Module 4's crime-report ingestion: fetching the
 * newest **Dhaka Metropolitan Police** monthly crime table and extracting it
 * via Gemini.
 *
 * ## Why this targets DMP again
 *
 * The module plan always assumed `dmp.gov.bd`. Research on 2026-09-02 found
 * it behind a bot-check wall that could not be passed, so ingestion was
 * redirected to `police.gov.bd`'s national archive — which then turned out to
 * be unreachable from Cloud Functions entirely (`ECONNREFUSED`, later
 * `ETIMEDOUT`, from both `us-central1` and `asia-south1`), forcing the
 * fetch-and-extract step onto an external machine.
 *
 * **Re-probed from inside a deployed Cloud Function on 2026-09-16: DMP now
 * answers, and the national archive still does not.**
 *
 *     200   1661ms  dmp.gov.bd/crime-data/
 *     200    263ms  dmp.gov.bd/crime_data/august-2026/
 *     FAIL  9839ms  police.gov.bd/en/crime_statistic   ETIMEDOUT
 *
 * That reverses the earlier decision, and it is a strict improvement on every
 * axis that matters here:
 *
 * - **Dhaka-specific.** The national report gave one DMP row among every
 *   metropolitan and range unit in Bangladesh; this table *is* Dhaka.
 * - **Monthly and current.** August 2026 was published on 9 September 2026.
 * - **Automatable again.** No external machine, no GitHub Actions hop — the
 *   scheduled function can do the whole thing itself.
 *
 * ## What it still cannot do
 *
 * The table is **citywide totals only** — one row for all of DMP, no thana
 * breakdown, confirmed by reading the published image. So this refreshes
 * *how much* crime is happening across Dhaka, never *which neighbourhoods*
 * are relatively riskier. That axis comes from `thana_advisory.js` and
 * accumulates through `learned_baseline.js`; the 2009 academic seed remains
 * the starting geography.
 *
 * And the history only goes back to **January 2024** — not because of
 * anything in this code, but because DMP did not publish a crime table
 * before then. See [EARLIEST_CRIME_TABLE_PERIOD] for what the earlier pages
 * actually contain.
 *
 * ## Deliberately Firebase-free
 *
 * No `firebase-admin`, no Firestore, so it runs anywhere Node runs. The
 * network wall was real once and may return; keeping this module portable is
 * what let ingestion continue last time and what will let it continue again.
 * `functions/scripts/monthly_crime_ingest.js` uses the same module from a
 * different network.
 */

const DMP_CRIME_DATA_URL = "https://dmp.gov.bd/crime-data/";

/**
 * Categories a pedestrian could plausibly be a victim of.
 *
 * The table also carries narcotics, arms and explosives *recovery* counts —
 * police enforcement activity, not a danger-to-pedestrians signal — and those
 * are deliberately excluded, per the module plan's own instruction to keep
 * "specific street-level crimes relevant to pedestrians" and ignore the rest.
 * Unchanged from the national-source version, so nothing downstream moves.
 */
const PEDESTRIAN_RELEVANT_CATEGORIES = ["dacoity", "robbery", "burglary", "theft", "kidnapping"];

/** Bangla digits, which is how every number in this table is printed. */
const BENGALI_DIGITS = "০১২৩৪৫৬৭৮৯";

/** Attempts at the extraction call, and the base gap between them. */
const GEMINI_ATTEMPTS = 4;
const GEMINI_RETRY_BASE_MS = 5000;

/** Turns `১৫০৯` into `1509`, and leaves ASCII digits alone. */
function normaliseDigits(value) {
  if (typeof value === "number") return value;
  const ascii = String(value ?? "").replace(/[০-৯]/g, (d) => String(BENGALI_DIGITS.indexOf(d)));
  const digits = ascii.replace(/[^\d]/g, "");
  return digits === "" ? 0 : Number(digits);
}

/**
 * The first month whose page actually carries a crime table.
 *
 * ## Why this constant exists, and why it is not a prompt problem
 *
 * `findTableImage` happily resolves scans back to 2019, and extraction
 * returns all zeros for them. The standing theory was a changed table layout
 * that a widened prompt would absorb. **It is not.** The scans for
 * 2019-05, 2019-12, 2022-04 and 2023-06 were fetched and read by eye on
 * 2026-09-20, and each contains exactly three tables:
 *
 *     ... অস্ত্র গোলাবারুদ ও বিস্ফোরক উদ্ধারের বিবরণী   (arms recovery)
 *     ... চোরাইগাড়ী উদ্ধারের বিবরণী                     (stolen-vehicle recovery)
 *     ... মাদকদ্রব্য উদ্ধারের বিবরণী                      (narcotics recovery)
 *
 * There is no `অপরাধ চিত্র` table on the page at all — one image per month
 * page, checked against every `wp-content/uploads` reference in the markup,
 * and the WordPress media endpoint lists no siblings. Those three tables are
 * *recovery* counts: precisely the police-activity figures
 * [PEDESTRIAN_RELEVANT_CATEGORIES] exists to exclude. The extraction returns
 * zeros because the numbers genuinely are not there.
 *
 * From 2024-01 the layout changes and the crime table leads the page
 * (verified by eye for 2024-01 and 2024-06), read correctly by the existing
 * prompt with no change. So the recoverable history starts here, and asking
 * a model to read an earlier month is a guaranteed-wasted call against a
 * table that does not exist.
 */
const EARLIEST_CRIME_TABLE_PERIOD = "2024-01";

/** The years DMP offers on its crime-data index, newest first. */
async function listYears() {
  const cheerio = require("cheerio");
  const indexRes = await fetch(DMP_CRIME_DATA_URL, { redirect: "follow" });
  if (!indexRes.ok) throw new Error(`DMP crime-data index returned HTTP ${indexRes.status}`);
  const $index = cheerio.load(await indexRes.text());

  // Year pages look like `/?crime_data_year=crime-data-2026`. Take the highest
  // year offered rather than the current calendar year: in January the newest
  // published month is still the previous year's December.
  const years = [];
  $index("a[href*='crime_data_year=']").each((_, el) => {
    const match = /crime-data-(\d{4})/.exec($index(el).attr("href") || "");
    if (match) years.push(Number(match[1]));
  });
  if (years.length === 0) throw new Error("No crime-data year links found — DMP page markup may have changed.");
  return [...new Set(years)].sort((a, b) => b - a);
}

/**
 * Every month page published under one year, newest month first.
 *
 * Every link is **scraped, never constructed**, and the month comes from the
 * link's *text*, never its slug. The site's slugs are wrong in two separate
 * ways and both are live:
 *
 * - **Misspelled.** February 2026 is published at `/februuary-2026/`.
 * - **Collided.** WordPress derives a slug once and then suffixes duplicates,
 *   so May 2024 sits at `/april-2024-2/` and November 2020 at
 *   `/november-2019-2/` — each labelled correctly ("May-2024",
 *   "November 2020") and slugged as the wrong month, a year out in the
 *   second case.
 *
 * Constructing URLs from dates would miss the first kind and silently
 * mis-date the second. Checked against the whole archive on 2026-09-20:
 * reading the label recovers every month correctly, and no two links on a
 * year page resolve to the same period. The dedupe below is therefore
 * insurance rather than a fix for a known collision — first link wins,
 * because recording one month twice would double-count it in the trend.
 */
async function listMonthPages(year) {
  const cheerio = require("cheerio");
  const yearUrl = new URL(`/?crime_data_year=crime-data-${year}`, DMP_CRIME_DATA_URL).toString();
  const yearRes = await fetch(yearUrl, { redirect: "follow" });
  if (!yearRes.ok) return [];
  const $year = cheerio.load(await yearRes.text());

  const byPeriod = new Map();
  $year("a[href*='/crime_data/']").each((_, el) => {
    const href = $year(el).attr("href");
    const label = $year(el).text().trim();
    const month = monthIndexOf(label);
    if (!href || !month) return;
    const period = `${year}-${String(month).padStart(2, "0")}`;
    if (byPeriod.has(period)) return;
    byPeriod.set(period, {
      url: new URL(href, DMP_CRIME_DATA_URL).toString(),
      title: `DMP Crime Data — ${label}`,
      period,
    });
  });
  return [...byPeriod.values()].sort((a, b) => b.period.localeCompare(a.period));
}

/** Walks DMP's crime-data index to the newest published month. */
async function findLatestMonthPage() {
  for (const year of await listYears()) {
    const months = await listMonthPages(year);
    // Newest month on the newest year page that actually has one.
    if (months.length > 0) return months[0];
  }
  throw new Error("No monthly crime-data pages found on any year index.");
}

/**
 * Every month page in the archive that should carry a crime table, oldest
 * first — the backfill's work list.
 *
 * Months before [EARLIEST_CRIME_TABLE_PERIOD] are dropped here rather than
 * attempted and refused: see that constant for what is actually on those
 * pages.
 */
async function listCrimeTableMonths() {
  const months = [];
  for (const year of await listYears()) {
    months.push(...await listMonthPages(year));
  }
  return months
    .filter((m) => m.period >= EARLIEST_CRIME_TABLE_PERIOD)
    .sort((a, b) => a.period.localeCompare(b.period));
}

const MONTH_NAMES = [
  "january", "february", "march", "april", "may", "june",
  "july", "august", "september", "october", "november", "december",
];

/**
 * 1-12 for a month label, tolerating the site's own misspellings.
 *
 * `februuary` is real and live. Prefix matching on the first four letters
 * absorbs that class of typo without accepting arbitrary words.
 */
function monthIndexOf(label) {
  const lower = String(label || "").toLowerCase();
  for (let i = 0; i < MONTH_NAMES.length; i++) {
    const name = MONTH_NAMES[i];
    if (lower.includes(name) || lower.includes(name.slice(0, 4))) return i + 1;
  }
  return 0;
}

/**
 * Bangla month names as they appear in DMP upload filenames, **with every
 * spelling variant the site actually uses**.
 *
 * Three variant pairs are live, and each one silently costs a month if it is
 * missing:
 *
 * - `আগস্ট` / `আগষ্ট` — স vs ষ.
 * - `জানুয়ারি` / `জানুয়ারী` and `ফেব্রুয়ারি` / `ফেব্রুয়ারী` — the final
 *   vowel sign, ি vs ী. January 2024 is uploaded with ি and February 2026
 *   with ী, so neither spelling can be treated as canonical.
 *
 * February 2026 was skipped by the backfill for exactly this reason: the
 * page and the scan both existed, `findTableImage` simply did not recognise
 * `ফেব্রুয়ারী-২০২৬_page-0001.jpg` as a crime scan. Same failure shape as the
 * site's `/februuary-2026/` slug — DMP spells things more than one way, and
 * anything matching its text has to expect that.
 */
const BANGLA_MONTHS = [
  "জানুয়ারি", "জানুয়ারী", "ফেব্রুয়ারি", "ফেব্রুয়ারী", "মার্চ", "এপ্রিল", "মে", "জুন",
  "জুলাই", "আগস্ট", "আগষ্ট", "সেপ্টেম্বর", "অক্টোবর", "নভেম্বর", "ডিসেম্বর",
];

/**
 * Whether an upload filename is a crime-data scan rather than site furniture.
 *
 * Naming has changed three times across the archive — `April-2022.jpg`,
 * `Crime-Data-April-2025.jpg`, `আগষ্ট-2026_page-0001-1.jpg` — and so has the
 * folder: 2022 scans sit under `/uploads/2022/09/`, later ones go straight
 * into `/uploads/`. So neither the path nor a fixed filename pattern is a
 * reliable discriminator, and an earlier version that keyed on the folder
 * silently found nothing on every page before 2025.
 *
 * A month name or the word "crime" is what every scan has and no piece of
 * furniture does.
 */
function looksLikeCrimeScan(src) {
  const name = decodeURIComponent(src).split("/").pop().toLowerCase();
  if (/logo|webmail|icon|banner|avatar/.test(name)) return false;
  if (name.includes("crime")) return true;
  if (MONTH_NAMES.some((m) => name.includes(m))) return true;
  return BANGLA_MONTHS.some((m) => decodeURIComponent(src).includes(m));
}

/**
 * WordPress links a scaled copy on some pages and the original on others, and
 * the scaled copies are not reliably still on disk — April 2022's page links
 * `April-2022-864x380.jpg`, which 404s, while `April-2022.jpg` is there.
 *
 * Stripping the dimensions is therefore both the legibility fix and the
 * availability fix: a downscaled crop of a dense Bangla table is what makes an
 * extraction guess, and sometimes it is not fetchable at all.
 */
function stripScaledSuffix(src) {
  return src.replace(/-\d+x\d+(\.(?:jpe?g|png))$/i, "$1");
}

/** The scanned table image on a monthly page. */
async function findTableImage(monthPageUrl) {
  const cheerio = require("cheerio");
  const res = await fetch(monthPageUrl, { redirect: "follow" });
  if (!res.ok) throw new Error(`DMP month page returned HTTP ${res.status}`);
  const $ = cheerio.load(await res.text());

  const candidates = [];
  $("img").each((_, el) => {
    const el$ = $(el);
    // `data-breeze` first: the site runs the Breeze lazy-loader on newer
    // pages, which moves the real URL out of `src` entirely.
    const src = el$.attr("data-breeze") || el$.attr("src") || el$.attr("data-src") || "";
    if (!/wp-content\/uploads\/.*\.(jpe?g|png)/i.test(src)) return;
    if (!looksLikeCrimeScan(src)) return;
    candidates.push(stripScaledSuffix(src));
  });
  if (candidates.length === 0) {
    throw new Error("No table image found on the DMP month page — markup or upload naming may have changed.");
  }
  return new URL(candidates[0], monthPageUrl).toString();
}

/**
 * Sends the scanned table to Gemini and asks for the citywide row.
 *
 * Multimodal rather than a separate OCR step: the image is a scan with no
 * text layer, and the same approach already worked against the national
 * report's PDF. The prompt names the Bangla column headings because that is
 * what is actually printed — asking for "robbery" against a table that says
 * দস্যুতা invites the model to guess which column it meant.
 */
async function extractCityRowViaGemini(imageBuffer, mimeType, geminiApiKey) {
  const prompt = `This is a scanned page published by Dhaka Metropolitan Police (DMP). It may
contain a monthly crime table titled "ঢাকা মহানগর এলাকায় ... মাসের অপরাধ চিত্র" —
a single row of citywide totals with Bangla column headings and Bangla numerals.

FIRST, decide whether that "অপরাধ চিত্র" table is present on this page at all.
Some months publish only recovery tables (অস্ত্র গোলাবারুদ / চোরাইগাড়ী /
মাদকদ্রব্য উদ্ধারের বিবরণী) and no crime table. If there is no "অপরাধ চিত্র"
table, set "hasCrimeTable" to false and leave every number at 0 — do NOT read
figures out of a recovery table instead.

If the "অপরাধ চিত্র" table IS present, set "hasCrimeTable" to true, read that
table only, and map these columns:
  ডাকাতি              -> dacoity
  দস্যুতা              -> robbery
  খুন                 -> murder
  অপহরণ               -> kidnapping
  সিঁধেল চুরি          -> burglary
  গাড়ি চুরি + অন্যান্য চুরি -> theft   (add these two together)
  সর্বমোট রুজুকৃত মামলা  -> totalCases

Convert every Bangla numeral to an ordinary number (০=0 … ৯=9). Also read the
month and year from the title and give it as YYYY-MM.

Return ONLY this JSON, numbers only:
{"hasCrimeTable":true,"period":"YYYY-MM","dacoity":0,"robbery":0,"murder":0,"kidnapping":0,"burglary":0,"theft":0,"totalCases":0}`;

  const body = JSON.stringify({
    contents: [{
      role: "user",
      parts: [
        { text: prompt },
        { inlineData: { mimeType, data: imageBuffer.toString("base64") } },
      ],
    }],
    // Zero temperature: this is transcription, not composition. The same scan
    // must produce the same numbers every run, or a re-ingest could silently
    // disagree with what was recorded the first time.
    generationConfig: { responseMimeType: "application/json", temperature: 0 },
  });

  // Retried, because 503 is routine here rather than exceptional — it took
  // two attempts on the very first live run of this code. Nothing is watching
  // a scheduled monthly job, and a transient upstream blip should not cost a
  // month of data that is only published once.
  let res;
  for (let attempt = 1; attempt <= GEMINI_ATTEMPTS; attempt++) {
    res = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/gemini-3.6-flash:generateContent?key=${geminiApiKey}`,
      { method: "POST", headers: { "Content-Type": "application/json" }, body },
    );
    if (res.ok) break;
    // 4xx is a bad request or a bad key; retrying changes nothing.
    if (res.status < 500 || attempt === GEMINI_ATTEMPTS) {
      throw new Error(`Gemini extraction call returned HTTP ${res.status}`);
    }
    await new Promise((r) => setTimeout(r, GEMINI_RETRY_BASE_MS * attempt));
  }
  const json = await res.json();
  const text = json.candidates?.[0]?.content?.parts?.[0]?.text;
  if (!text) throw new Error("Gemini returned no extractable text");
  return JSON.parse(text);
}

/**
 * Whether an extracted row is worth recording.
 *
 * A scan read by a language model can come back plausible and wrong, and this
 * number ends up scaling the risk score for every route in the city. Two
 * cheap structural checks catch the failure modes that matter: a period that
 * is not a real month, and pedestrian-relevant categories that exceed the
 * table's own total (which means columns were misread, not that crime rose).
 */
function validateExtraction(row) {
  if (!row || typeof row !== "object") return "extraction did not return an object";
  // Checked before the period, because a month with no crime table is a fact
  // about DMP's publishing rather than a fault in the reading, and saying
  // "total cases is zero" about it sends whoever reads the log hunting for a
  // bug in the extraction. See [EARLIEST_CRIME_TABLE_PERIOD].
  if (row.hasCrimeTable === false) {
    return "this month's scan carries only recovery tables (arms / stolen vehicles / narcotics) "
      + "— DMP published no crime table for it";
  }
  if (!/^\d{4}-(0[1-9]|1[0-2])$/.test(row.period || "")) return `period "${row.period}" is not YYYY-MM`;
  const total = normaliseDigits(row.totalCases ?? row.totalCasesDMP);
  if (total <= 0) return "total cases is zero or missing";
  const relevant = PEDESTRIAN_RELEVANT_CATEGORIES
    .reduce((sum, key) => sum + normaliseDigits(row[key]), 0);
  if (relevant > total) return `pedestrian categories (${relevant}) exceed total cases (${total})`;
  return null;
}

/**
 * Fetches one DMP month page and extracts its citywide row.
 *
 * Split out of [fetchAndExtractLatestReport] so the archive can be walked
 * month by month — the scheduled function only ever wants the newest one,
 * but the citywide trend is computed from a history, and until this existed
 * there was no way to read a month that had already been published and
 * missed.
 */
async function fetchAndExtractMonth(month, geminiApiKey) {
  const imageUrl = await findTableImage(month.url);
  const imageRes = await fetch(imageUrl, { redirect: "follow" });
  if (!imageRes.ok) throw new Error(`DMP table image returned HTTP ${imageRes.status}`);
  const mimeType = /\.png$/i.test(imageUrl) ? "image/png" : "image/jpeg";
  const buffer = Buffer.from(await imageRes.arrayBuffer());

  const extracted = await extractCityRowViaGemini(buffer, mimeType, geminiApiKey);
  const problem = validateExtraction(extracted);
  if (problem) throw new Error(`Refusing the extracted row: ${problem}`);

  return {
    // The page's own period wins over the model's reading of the title: it
    // comes from a scraped link rather than an OCR pass on a scanned heading.
    period: month.period || extracted.period,
    dacoity: normaliseDigits(extracted.dacoity),
    robbery: normaliseDigits(extracted.robbery),
    burglary: normaliseDigits(extracted.burglary),
    theft: normaliseDigits(extracted.theft),
    kidnapping: normaliseDigits(extracted.kidnapping),
    totalCasesDMP: normaliseDigits(extracted.totalCases ?? extracted.totalCasesDMP),
    sourceTitle: month.title,
    sourceUrl: month.url,
  };
}

/** Fetches the newest DMP month and extracts its citywide row. */
async function fetchAndExtractLatestReport(geminiApiKey) {
  return fetchAndExtractMonth(await findLatestMonthPage(), geminiApiKey);
}

module.exports = {
  DMP_CRIME_DATA_URL,
  EARLIEST_CRIME_TABLE_PERIOD,
  BANGLA_MONTHS,
  PEDESTRIAN_RELEVANT_CATEGORIES,
  normaliseDigits,
  monthIndexOf,
  validateExtraction,
  listYears,
  listMonthPages,
  listCrimeTableMonths,
  findLatestMonthPage,
  findTableImage,
  extractCityRowViaGemini,
  fetchAndExtractMonth,
  fetchAndExtractLatestReport,
};
