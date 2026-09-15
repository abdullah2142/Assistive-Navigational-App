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
