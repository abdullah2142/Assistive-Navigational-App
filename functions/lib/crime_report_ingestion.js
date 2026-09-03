/**
 * The network-facing half of Module 4's crime-report ingestion — fetching
 * the newest Bangladesh Police monthly report and extracting the DMP row
 * from it via Gemini. Deliberately has **no Firebase-specific dependency**
 * (no `firebase-admin`, no Firestore) so it can run from anywhere Node
 * runs, not just inside a Cloud Function — which matters because Cloud
 * Functions in this project are refused a connection to `police.gov.bd`
 * entirely (confirmed live from two GCP regions; see
 * `functions/index.js`'s `recordCityTrendEntry` doc comment for the full
 * story). `functions/index.js`'s `ingestCrimeReport` uses this module
 * directly; `functions/scripts/monthly_crime_ingest.js` (run from GitHub
 * Actions, a different network) uses the exact same module — one real
 * implementation, two vantage points, instead of duplicated logic that
 * could drift apart.
 */

const CRIME_STATS_ARCHIVE_URL = "https://www.police.gov.bd/en/january_2020";

/** Categories a pedestrian could plausibly be a victim of, out of the
 * report's full column set (which also includes narcotics/arms/explosives
 * *recovery* cases — police enforcement activity, not a danger-to-pedestrians
 * signal, deliberately excluded). Mirrors the module plan's own instruction
 * to keep "specific street-level crimes relevant to pedestrians" and ignore
 * the rest. */
const PEDESTRIAN_RELEVANT_CATEGORIES = ["dacoity", "robbery", "burglary", "theft", "kidnapping"];

/** One row of the archive's "List of Crime Statistics" table — the newest
 * report's title and PDF URL. */
async function fetchLatestCrimeReportPdf() {
  const cheerio = require("cheerio");
  const res = await fetch(CRIME_STATS_ARCHIVE_URL);
  if (!res.ok) {
    throw new Error(`Crime statistics archive returned HTTP ${res.status}`);
  }
  const html = await res.text();
  const $ = cheerio.load(html);
  // The archive's table is [SL, Title, Issuing Authority, Upload Date,
  // Files, Details] rows, sorted newest-first (confirmed live) — SL=1's
  // title (e.g. "Crime Statistics, July-2026") and its Files column's
  // ".pdf" link is the newest report.
  const firstRow = $("table tbody tr").first();
  const title = firstRow.find("td").eq(1).text().trim();
  const href = firstRow.find("a[href$='.pdf']").first().attr("href");
  if (!href) return null;
  return { title, url: new URL(href, CRIME_STATS_ARCHIVE_URL).toString() };
}

/**
 * Sends the report PDF directly to Gemini (multimodal — PDF bytes as
 * `inlineData`, no separate OCR step) and asks it to find the DMP row
 * specifically (the table covers every metropolitan/range unit in
 * Bangladesh, DMP is just one row) and extract it.
 */
async function extractDmpRowViaGemini(pdfBuffer, geminiApiKey) {
  const prompt = `This is a scanned Bangladesh Police "Crime Statistics" report. It's a table
with one row per unit (DMP, CMP, KMP, RMP, BMP, SMP, RPMP, GMP, and several
"Range" rows) and columns for different crime categories.

Find the row where "Names of Unit" is "DMP" (Dhaka Metropolitan Police) and
extract ONLY that row's values for these columns: Dacoity, Robbery,
Burglary, Theft, Kidnapping, and Total Cases. Also read the report's period
from its title (e.g. "Crime Statistics in July 2026" -> "2026-07").

Return ONLY this JSON shape, numbers only (no commas/text in the values):
{"period": "YYYY-MM", "dacoity": 0, "robbery": 0, "burglary": 0, "theft": 0, "kidnapping": 0, "totalCasesDMP": 0}`;

  const res = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/gemini-3.6-flash:generateContent?key=${geminiApiKey}`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        contents: [{
          role: "user",
          parts: [
            { text: prompt },
            { inlineData: { mimeType: "application/pdf", data: pdfBuffer.toString("base64") } },
          ],
        }],
        generationConfig: { responseMimeType: "application/json" },
      }),
    },
  );
  if (!res.ok) {
    throw new Error(`Gemini extraction call returned HTTP ${res.status}`);
  }
  const json = await res.json();
  const text = json.candidates?.[0]?.content?.parts?.[0]?.text;
  if (!text) throw new Error("Gemini returned no extractable text");
  return JSON.parse(text);
}

/** Fetches the newest report and extracts its DMP row in one call — what
 * both call sites actually want. */
async function fetchAndExtractLatestReport(geminiApiKey) {
  const latest = await fetchLatestCrimeReportPdf();
  if (!latest) {
    throw new Error("No PDF link found on the crime statistics archive page — table markup may have changed.");
  }
  const pdfRes = await fetch(latest.url);
  const pdfBuffer = Buffer.from(await pdfRes.arrayBuffer());
  const extracted = await extractDmpRowViaGemini(pdfBuffer, geminiApiKey);
  return { ...extracted, sourceTitle: latest.title, sourceUrl: latest.url };
}

module.exports = {
  CRIME_STATS_ARCHIVE_URL,
  PEDESTRIAN_RELEVANT_CATEGORIES,
  fetchLatestCrimeReportPdf,
  extractDmpRowViaGemini,
  fetchAndExtractLatestReport,
};
