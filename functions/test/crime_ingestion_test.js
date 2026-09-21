/**
 * Module 4's crime-report ingestion, retargeted at DMP.
 *
 * The parts worth pinning here are the ones that silently produce a wrong
 * *number* rather than an error: Bangla numerals, the site's own month
 * misspellings, and an extraction that reads plausibly but wrong. The network
 * and Gemini halves are exercised live rather than mocked — a fake of either
 * would only prove the fake works.
 */

const test = require("node:test");
const assert = require("node:assert");

const {
  normaliseDigits,
  monthIndexOf,
  validateExtraction,
  EARLIEST_CRIME_TABLE_PERIOD,
  PEDESTRIAN_RELEVANT_CATEGORIES,
} = require("../lib/crime_report_ingestion");

test("Bangla numerals become numbers", () => {
  // Every figure in this table is printed in Bangla digits. Reading ১৫০৯ as 0
  // would scale the whole city's risk to nothing, silently.
  assert.strictEqual(normaliseDigits("১৫০৯"), 1509);
  assert.strictEqual(normaliseDigits("৫৭১"), 571);
  assert.strictEqual(normaliseDigits("০"), 0);
});

test("ordinary digits and stray characters survive", () => {
  assert.strictEqual(normaliseDigits(1509), 1509);
  assert.strictEqual(normaliseDigits("1,509"), 1509);
  assert.strictEqual(normaliseDigits("৩৩ টি"), 33);
});

test("missing values are zero, not NaN", () => {
  // A NaN reaching the multiplier would poison every route score rather than
  // simply understating one category.
  assert.strictEqual(normaliseDigits(undefined), 0);
  assert.strictEqual(normaliseDigits(null), 0);
  assert.strictEqual(normaliseDigits("—"), 0);
});

test("month labels resolve, including the site's own misspelling", () => {
  // `februuary-2026` is live on dmp.gov.bd. Constructing month URLs from a
  // date would miss it entirely, which is why links are scraped.
  assert.strictEqual(monthIndexOf("August-2026"), 8);
  assert.strictEqual(monthIndexOf("Februuary-2026"), 2);
  assert.strictEqual(monthIndexOf("january-2026"), 1);
  assert.strictEqual(monthIndexOf("Crime Data"), 0);
});

test("a plausible-but-wrong extraction is refused", () => {
  // A language model reading a scan can return a well-formed object with the
  // columns misaligned. This number scales the risk score for every route in
  // Dhaka, so structural nonsense has to fail loudly rather than be recorded.
  assert.ok(validateExtraction({ period: "2026-13", totalCases: 100 }), "month 13 must be refused");
  assert.ok(validateExtraction({ period: "August", totalCases: 100 }), "a non-ISO period must be refused");
  assert.ok(validateExtraction({ period: "2026-08", totalCases: 0 }), "a zero total must be refused");
  assert.ok(
    validateExtraction({ period: "2026-08", totalCases: 10, dacoity: 50 }),
    "categories exceeding the table's own total means columns were misread",
  );
});

test("the real August 2026 row passes validation", () => {
  // The figures actually printed on dmp.gov.bd for August 2026, read off the
  // published scan by hand: ডাকাতি ৪, দস্যুতা ২২, সিঁধেল চুরি ৩৮,
  // গাড়ি চুরি ৩৩ + অন্যান্য চুরি ৬৮ = ১০১, অপহরণ ২১, সর্বমোট ১৫০৯.
  assert.strictEqual(
    validateExtraction({
      period: "2026-08",
      dacoity: 4, robbery: 22, burglary: 38, theft: 101, kidnapping: 21,
      totalCases: 1509,
    }),
    null,
  );
});

test("a month with no crime table is refused by name, not as a zero total", () => {
  // 2019-05, 2019-12, 2022-04 and 2023-06 publish only recovery tables —
  // arms, stolen vehicles, narcotics — and no `অপরাধ চিত্র` table at all
  // (read by eye off the scans, 2026-09-20). Extraction correctly returns
  // nothing, and the old message for that was "total cases is zero or
  // missing", which reads like a broken reading of a table that exists.
  // Whoever hits this in a log should be told what is actually true.
  const problem = validateExtraction({ hasCrimeTable: false, period: "2019-05", totalCases: 0 });
  assert.ok(problem, "a scan with no crime table must be refused");
  assert.match(problem, /recovery tables/, "the refusal must say why, not just that a number was zero");
});

test("the crime-table era starts at January 2024", () => {
  // Load-bearing: the backfill skips everything before this rather than
  // spending a model call per month to be refused. 2024-01 and 2024-06 were
  // checked by eye and do carry the table, with the existing prompt reading
  // them unchanged.
  assert.strictEqual(EARLIEST_CRIME_TABLE_PERIOD, "2024-01");
  assert.ok("2023-12" < EARLIEST_CRIME_TABLE_PERIOD, "string compare must order periods correctly");
  assert.ok("2024-01" >= EARLIEST_CRIME_TABLE_PERIOD);
});

test("a present crime table is unaffected by the new flag", () => {
  // The flag must only ever *add* a refusal. A row from before the prompt
  // carried `hasCrimeTable` has to keep validating, or the deployed
  // scheduled function starts refusing real months mid-rollout.
  assert.strictEqual(
    validateExtraction({
      period: "2026-08",
      dacoity: 4, robbery: 22, burglary: 38, theft: 101, kidnapping: 21,
      totalCases: 1509,
    }),
    null,
    "a row with no hasCrimeTable field must still pass",
  );
  // January 2024, read off the scan by hand and independently confirmed
  // against the Kaggle/PHQ row already in `cityTrend` — the two agree
  // column for column, which is what makes the backfill's months
  // comparable with the ones already recorded.
  assert.strictEqual(
    validateExtraction({
      hasCrimeTable: true,
      period: "2024-01",
      dacoity: 1, robbery: 25, burglary: 63, theft: 141, kidnapping: 8,
      totalCases: 1725,
    }),
    null,
  );
});

test("both Bangla spellings of a month are recognised in a filename", () => {
  // February 2026 was skipped by the backfill because its scan is uploaded
  // as `ফেব্রুয়ারী-২০২৬_page-0001.jpg` — final ী — while the list only had
  // `ফেব্রুয়ারি` with ি. The page and the image both existed; the month was
  // simply invisible. Same shape as the site's own `/februuary-2026/` slug.
  const { BANGLA_MONTHS } = require("../lib/crime_report_ingestion");
  for (const pair of [["জানুয়ারি", "জানুয়ারী"], ["ফেব্রুয়ারি", "ফেব্রুয়ারী"], ["আগস্ট", "আগষ্ট"]]) {
    for (const spelling of pair) {
      assert.ok(BANGLA_MONTHS.includes(spelling), `${spelling} must be recognised`);
    }
  }
});

test("enforcement activity stays out of the pedestrian signal", () => {
  // The table also counts narcotics, arms and explosives *recovery* — police
  // activity, not danger to someone walking. 571 narcotics cases dwarf every
  // street-crime column and would swamp the multiplier if included.
  assert.deepStrictEqual(
    PEDESTRIAN_RELEVANT_CATEGORIES,
    ["dacoity", "robbery", "burglary", "theft", "kidnapping"],
  );
  assert.ok(!PEDESTRIAN_RELEVANT_CATEGORIES.includes("narcotics"));
});
