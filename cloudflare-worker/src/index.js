/**
 * Module 4's monthly crime-report ingestion — the working automation,
 * after two failed attempts on other clouds. Google Cloud Functions
 * (us-central1 and asia-south1) and GitHub Actions runners were both
 * refused a TCP connection to police.gov.bd (identical ECONNREFUSED on
 * the same IP from both — see functions/index.js's `recordCityTrendEntry`
 * doc comment and task.md's Module 4 history). Cloudflare's edge network
 * was tried next specifically because it's architecturally different (edge
 * PoPs, not a datacenter VM/serverless block) and confirmed live — a
 * diagnostic fetch to the same URL came back a real 200 with real content.
 * This is that diagnostic Worker upgraded to the real pipeline.
 *
 * Logic is a direct, deliberate port of `functions/lib/crime_report_ingestion.js`
 * and `functions/scripts/monthly_crime_ingest.js` — same DMP-row extraction
 * prompt, same pedestrian-relevant category list, same recordCityCrimeMonth
 * call — kept in sync by hand since Workers run on `workerd`, not Node, so
 * the two can't literally share a file the way the Cloud Function and the
 * GitHub Action script do.
 *
 * Runs on a Cron Trigger (see wrangler.toml — 12th of each month, matching
 * the ~10-day report-upload lag confirmed live) and exposes a manual GET
 * endpoint for on-demand runs/testing.
 */

const CRIME_STATS_ARCHIVE_URL = 'https://www.police.gov.bd/en/january_2020';
const PEDESTRIAN_RELEVANT_CATEGORIES = ['dacoity', 'robbery', 'burglary', 'theft', 'kidnapping'];
const FIREBASE_WEB_API_KEY = 'AIzaSyAXm0kMvv5odpkkrHKRNZz2Cm6mvTx2uDg';
const RECORD_FN_URL = 'https://us-central1-ant-assistive-nav.cloudfunctions.net/recordCityCrimeMonth';

/** Finds the newest report's title + PDF URL from the archive's table —
 * regex-based rather than a DOM/cheerio parse, since Workers run on
 * `workerd` (no Node APIs by default) and the real table markup (confirmed
 * live against the actual page) is simple enough not to need one. */
function extractLatestReport(html) {
  const tbodyMatch = html.match(/<tbody>([\s\S]*?)<\/tbody>/);
  if (!tbodyMatch) return null;
  const firstRowMatch = tbodyMatch[1].match(/<tr>([\s\S]*?)<\/tr>/);
  if (!firstRowMatch) return null;
  const row = firstRowMatch[1];
  const cells = [...row.matchAll(/<td>([\s\S]*?)<\/td>/g)].map((m) => m[1].replace(/<[^>]+>/g, '').trim());
  const title = cells[1] || 'unknown';
  const hrefMatch = row.match(/href="([^"]+\.pdf)"/);
  if (!hrefMatch) return null;
  return { title, url: new URL(hrefMatch[1], CRIME_STATS_ARCHIVE_URL).toString() };
}

function arrayBufferToBase64(buffer) {
  let binary = '';
  const bytes = new Uint8Array(buffer);
  const chunkSize = 0x8000;
  for (let i = 0; i < bytes.length; i += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunkSize));
  }
  return btoa(binary);
}

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
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        contents: [{
          role: 'user',
          parts: [
            { text: prompt },
            { inlineData: { mimeType: 'application/pdf', data: arrayBufferToBase64(pdfBuffer) } },
          ],
        }],
        generationConfig: { responseMimeType: 'application/json' },
      }),
    },
  );
  if (!res.ok) throw new Error(`Gemini extraction call returned HTTP ${res.status}`);
  const json = await res.json();
  const text = json.candidates?.[0]?.content?.parts?.[0]?.text;
  if (!text) throw new Error('Gemini returned no extractable text');
  return JSON.parse(text);
}

async function signInAnonymously() {
  const res = await fetch(`https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=${FIREBASE_WEB_API_KEY}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ returnSecureToken: true }),
  });
  if (!res.ok) throw new Error(`Anonymous sign-in failed: HTTP ${res.status}`);
  return res.json();
}

async function deleteAccount(idToken) {
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

async function runIngestion(geminiApiKey) {
  const archiveRes = await fetch(CRIME_STATS_ARCHIVE_URL);
  if (!archiveRes.ok) throw new Error(`Archive page HTTP ${archiveRes.status}`);
  const html = await archiveRes.text();
  const latest = extractLatestReport(html);
  if (!latest) throw new Error('No PDF link found on the crime statistics archive page.');

  const pdfRes = await fetch(latest.url);
  const pdfBuffer = await pdfRes.arrayBuffer();
  const extracted = await extractDmpRowViaGemini(pdfBuffer, geminiApiKey);
  const period = extracted.period || new Date().toISOString().slice(0, 7);

  const { idToken, localId } = await signInAnonymously();
  try {
    const recordRes = await fetch(RECORD_FN_URL, {
      method: 'POST',
      headers: { Authorization: `Bearer ${idToken}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ data: { ...extracted, period, sourceTitle: latest.title, sourceUrl: latest.url } }),
    });
    const body = await recordRes.json();
    if (!recordRes.ok || body.error) throw new Error(`recordCityCrimeMonth failed: ${JSON.stringify(body)}`);
    return { period, sourceTitle: latest.title, result: body.result };
  } finally {
    await deleteAccount(idToken);
  }
}

export default {
  async fetch(request, env, ctx) {
    if (!env.GEMINI_API_KEY) {
      return new Response(JSON.stringify({ ok: false, error: 'GEMINI_API_KEY secret not configured' }), {
        status: 500, headers: { 'content-type': 'application/json' },
      });
    }
    try {
      const result = await runIngestion(env.GEMINI_API_KEY);
      return new Response(JSON.stringify({ ok: true, ...result }, null, 2), { headers: { 'content-type': 'application/json' } });
    } catch (err) {
      return new Response(JSON.stringify({ ok: false, error: String(err) }, null, 2), {
        status: 500, headers: { 'content-type': 'application/json' },
      });
    }
  },

  async scheduled(controller, env, ctx) {
    ctx.waitUntil(
      runIngestion(env.GEMINI_API_KEY)
        .then((r) => console.log('Monthly ingestion succeeded:', JSON.stringify(r)))
        .catch((err) => console.error('Monthly ingestion failed:', err)),
    );
  },
};
