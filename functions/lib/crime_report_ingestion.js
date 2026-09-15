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
 * Walks DMP's crime-data index to the newest published month.
 *
 * Every link is **scraped, never constructed**. The site's own month slugs are
 * not reliably spelled — February 2026 is published at `/februuary-2026/` —
 * so building a URL from a date would silently miss months. The year index is
 * likewise read rather than assumed.
 */
async function findLatestMonthPage() {
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

  for (const year of [...new Set(years)].sort((a, b) => b - a)) {
    const yearUrl = new URL(`/?crime_data_year=crime-data-${year}`, DMP_CRIME_DATA_URL).toString();
    const yearRes = await fetch(yearUrl, { redirect: "follow" });
    if (!yearRes.ok) continue;
    const $year = cheerio.load(await yearRes.text());

    const months = [];
    $year("a[href*='/crime_data/']").each((_, el) => {
      const href = $year(el).attr("href");
      const label = $year(el).text().trim();
      const month = monthIndexOf(label);
      if (href && month) months.push({ href, label, month });
    });
    if (months.length === 0) continue;

    // Newest month on the newest year page that actually has one.
    months.sort((a, b) => b.month - a.month);
    const newest = months[0];
    return {
      url: new URL(newest.href, DMP_CRIME_DATA_URL).toString(),
      title: `DMP Crime Data — ${newest.label}`,
      period: `${year}-${String(newest.month).padStart(2, "0")}`,
    };
  }
  throw new Error("No monthly crime-data pages found on any year index.");
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

/** The scanned table image on a monthly page. */
async function findTableImage(monthPageUrl) {
  const cheerio = require("cheerio");
  const res = await fetch(monthPageUrl, { redirect: "follow" });
  if (!res.ok) throw new Error(`DMP month page returned HTTP ${res.status}`);
  const $ = cheerio.load(await res.text());

  // `data-breeze` first: the site runs the Breeze lazy-loader, which moves the
  // real URL out of `src` entirely — reading `src` alone finds nothing at all
  // on a page that plainly has the image on it.
  const candidates = [];
  $("img").each((_, el) => {
    const el$ = $(el);
    const src = el$.attr("data-breeze") || el$.attr("src") || el$.attr("data-src") || "";
    if (!/wp-content\/uploads\/.*\.(jpe?g|png)/i.test(src)) return;
    // Site furniture lives under dated upload folders and is not the scan:
    // the logo is `/uploads/2017/08/dmp_logo-1-1.png`, and the table is
    // published straight into `/uploads/`. Requiring a page-number suffix is
    // the reliable half of that — every scan is `..._page-0001-1.jpg`.
    if (/_page-\d+/i.test(src)) candidates.push(src);
  });
  if (candidates.length === 0) {
    throw new Error("No table image found on the DMP month page — markup or upload naming may have changed.");
  }

  // WordPress publishes several scaled copies of the same scan
  // (`-768x1085`, `-1087x1536`). The unsuffixed original is the largest, and
  // legibility is the whole job here — a downscaled scan of a dense Bangla
  // table is what makes an OCR pass guess.
  const full = candidates.find((src) => !/-\d+x\d+\.(jpe?g|png)$/i.test(src));
  return new URL(full || candidates[0], monthPageUrl).toString();
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
  const prompt = `This is a scanned monthly crime table published by Dhaka Metropolitan Police
(DMP), titled "ঢাকা মহানগর এলাকায় ... মাসের অপরাধ চিত্র". It is a single row of
citywide totals with Bangla column headings and Bangla numerals.

Read the FIRST table only (the "অপরাধ চিত্র" one) and map these columns:
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
{"period":"YYYY-MM","dacoity":0,"robbery":0,"murder":0,"kidnapping":0,"burglary":0,"theft":0,"totalCases":0}`;

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
  if (!/^\d{4}-(0[1-9]|1[0-2])$/.test(row.period || "")) return `period "${row.period}" is not YYYY-MM`;
  const total = normaliseDigits(row.totalCases ?? row.totalCasesDMP);
  if (total <= 0) return "total cases is zero or missing";
  const relevant = PEDESTRIAN_RELEVANT_CATEGORIES
    .reduce((sum, key) => sum + normaliseDigits(row[key]), 0);
  if (relevant > total) return `pedestrian categories (${relevant}) exceed total cases (${total})`;
  return null;
}

/** Fetches the newest DMP month and extracts its citywide row. */
async function fetchAndExtractLatestReport(geminiApiKey) {
  const month = await findLatestMonthPage();
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

module.exports = {
  DMP_CRIME_DATA_URL,
  PEDESTRIAN_RELEVANT_CATEGORIES,
  normaliseDigits,
  monthIndexOf,
  validateExtraction,
  findLatestMonthPage,
  findTableImage,
  extractCityRowViaGemini,
  fetchAndExtractLatestReport,
};
