# Module 4 — Crime & Contextual Safety

How a walking route gets a safety verdict, where every number in it comes
from, and which of them are current.

Written against the deployed system on 16 September 2026. Companion to
`04_module_plan_crime.md`, which is the plan; this is what actually runs.

---

## 1. What the module decides

One question, asked once per candidate route: **is this route safe enough to
walk right now?**

`RoutePlanningService` asks Google for every walking alternative, scores each
through the `checkRouteSafety` Cloud Function, and takes the **first safe
one**. If none are safe it takes the lowest-risk candidate and flags
`stillUnsafe`, so the assistant can say so rather than pretend.

The verdict is deliberately time-aware: the same route can be safe at 2pm and
unsafe at 11pm, because that is true of Dhaka.

---

## 2. The scoring pipeline

`checkRouteSafety` decodes the route's encoded polyline, finds which thanas it
passes through by ray-casting point-in-polygon against real boundary geometry,
and scores each one:

```
effectiveScore = baseCrimeScore
               × temporalMultiplier      (time of day × land use)
               × cityTrendMultiplier     (citywide, from DMP)
               × advisoryFactor          (current news, expires)
               × learnedFactor           (accumulated evidence months)
```

Then:

```
crimeRisk  = max(effectiveScore) across thanas on the route   (1 if none)
hazardRisk = max(hazardWeight) across Module 5 hazard pins    (0 if none)
riskScore  = max(crimeRisk, hazardRisk)

safe = no thana scores above 7  AND  no confirmed hazard on the route
```

`max`, not a sum or an average, and that is deliberate: one severe signal must
not be diluted by everything else being quiet.

### The five factors

| Factor | Source | Range | Currency |
| --- | --- | --- | --- |
| `baseCrimeScore` | 2009 DMP table via a 2011 paper, min-max normalised to 1–10 | 1–10 | **17 years old** |
| `temporalMultiplier` | land-use category × hour (Dhaka UTC+6) | 1.0–5.0 | current — land use, not crime |
| `cityTrendMultiplier` | DMP monthly citywide totals | ~1.0 | current, monthly |
| `advisoryFactor` | published news, expires in 60 days | 1.0–2.0 | current |
| `learnedFactor` | distinct months with evidence, 24-month window | 1.0–1.6 | accumulates |

### Temporal multiplier

Night is 8pm–5am; a *notorious hotspot* reacts from dusk (6pm) instead.

| Zone character | Day | Night |
| --- | --- | --- |
| notorious hotspot | 1.2 | **5.0** (3.0 from dusk) |
| commercial core / transit hub | 1.0 | 3.0 |
| institutional | 1.0 | 2.2 |
| industrial | 1.0 | 1.8 |
| mixed | 1.0 | 1.6 |
| residential | 1.0 | 1.2 |

Commercial cores spike hardest at night for the reason they are safe by day:
the risk is precisely that the footfall leaves.

### Advisory severities

| Severity | Multiplier | Reachable by |
| --- | --- | --- |
| elevated | 1.25 | news, social |
| high | 1.50 | news, social (social's ceiling) |
| severe | 2.00 | **news only** — also promotes the thana to hotspot timing |

Advisories live 60 days (social: 14) and taper over the final 14. They can
only ever *raise* risk. Provenance is mandatory and enforced by
`validateAdvisory`: a real `sourceUrl`, a real `sourceTitle`, an ISO
`publishedAt`.

### Learned baseline

Counts **distinct months in which independent evidence existed** — not
incidents, not articles. Needs 3 months before it moves anything at all, reaches
its 1.6 ceiling at 12, over a rolling 24-month window, and decays on its own as
evidence ages out.

Capped far below the temporal (5×) and advisory (2×) multipliers on purpose:
this corrects a stale figure, it does not replace it.

**Social signals can never reach it.** Corroborated chatter is enough to prefer
another street today; nowhere near enough to change what the app believes about
a neighbourhood.

---

## 3. Where the data comes from

### Per-thana baseline — stale, and unfixable from any official source

`data/dhaka_thana_crime_seed.js` holds 41 thanas with a `densityEstimate`
(crimes/km²) and a `categoryHint`. Source: Table 2 of Urmee Chowdhury,
*"Spatial Distribution of Street Crime Occurrences in Dhaka City"*, AUST
Journal of Science and Technology 3(2), 2011 — itself from DMP Headquarters'
**January–March 2009** figures.

Real, DMP-derived, citable. Also three months of data from seventeen years ago.
Every document carries `dataSource: 'estimated_2009_academic'` and it is never
shown in the app as a live figure.

**No public source publishes crime broken down by Dhaka thana.** Verified:
DMP's monthly tables are citywide totals (read directly off the published
scan), and `/archived-crime-data/` is dead links to 2013–2017 `.doc` files.

### Citywide trend — current, automated

`scrapeDmpCrimeReports` runs monthly on the 12th (DMP publishes the previous
month around the 9th) and reads `dmp.gov.bd/crime_data/{month}-{year}/`.

The table is a **scanned image with no text layer**, so Gemini reads it
multimodally — no OCR infrastructure. Only pedestrian-relevant categories
count: dacoity, robbery, burglary, theft, kidnapping. Narcotics, arms and
explosives are *recovery* figures — police activity, not danger to a
pedestrian — and are excluded.

August 2026, verified by hand against the scan: dacoity 4, robbery 22,
burglary 38, theft 101 (গাড়ি চুরি 33 + অন্যান্য চুরি 68), kidnapping 21,
total 1509.

Extraction is validated before recording — the period must be a real month, and
pedestrian categories must not exceed the table's own total, which would mean
columns were misread. A plausible-but-wrong reading scales risk for every route
in the city, so it fails loudly instead.

### Per-thana currency — news

`ingestCrimeNews` runs every 6 hours over RSS from TBS News and The Daily Star
(crime and city sections). An article becomes an advisory only if it is street
crime against a person, names exactly **one** thana, is under 21 days old, and
carries a URL and a date.

**One article can never reach `severe`.** That severity is a standing claim
about a neighbourhood; a place that genuinely deteriorates accumulates evidence
months instead.

### Crowdsourced hazards — Module 5

Users report hazards from where they are standing, with no media filter at all.

- **Yellow flag** — one report. Warned about, not avoided.
- **Red flag** — 3 *distinct reporters* within 24 hours. Actively avoided, and
  enough alone to make a route unsafe.

Counting distinct reporters is the anti-spam design: one device cannot
manufacture a confirmed hazard and close a road. The aggregate is written only
by Cloud Functions through the Admin SDK; `hazardZones` is `allow write: if
false` to every client.

---

## 4. Network constraints, discovered the hard way

Three sources have blocked Google Cloud datacenter IPs. Each was found by
probing **from a deployed Cloud Function**, because reachability from a laptop
proves nothing:

| Source | From a laptop | From Cloud Functions |
| --- | --- | --- |
| `dmp.gov.bd` | 200 | **200** — bot wall gone as of 16 Sep |
| `police.gov.bd` | 200 | **ETIMEDOUT** |
| `news.google.com/rss` | 200 | **503** |
| Dhaka Tribune, bdnews24, New Age | 403 | 403 — publisher bot block, not GCP |

Consequence: anything needing Google News runs **outside** GCP and writes
through a callable. `lib/news_backfill.js` and `lib/crime_report_ingestion.js`
are deliberately Firebase-free so they run anywhere Node runs.

---

## 5. Deployed pieces

| Function | Trigger | Job |
| --- | --- | --- |
| `checkRouteSafety` | callable | scores one route |
| `seedCrimeZones` | callable | writes the 41 thana documents |
| `scrapeDmpCrimeReports` | 12th monthly | citywide trend from DMP |
| `ingestCrimeNews` | every 6 h | news → advisories |
| `recordThanaAdvisory` | callable | validated advisory write |
| `recordThanaIncident` | callable | validated incident write (feeds learned baseline) |
| `recordCityCrimeMonth` | callable | manual citywide write, if the site walls up again |
| `onHazardReportCreated` | Firestore | clusters reports into zones |
| `decayHazardZones` | scheduled | expires stale evidence |
| `resolveHazardZone` | callable | clears a fixed hazard |

Collections: `crimeZones`, `thanaAdvisories`, `thanaIncidents`, `socialSignals`,
`hazardReports`, `hazardZones`, `cityTrend`, `meta/cityTrendMultiplier`. All are
client-readable and **none are client-writable** except `hazardReports`, which
allows create-only under the caller's own uid.

---

## 6. Verification status

| Claim | Evidence | Strength |
| --- | --- | --- |
| Scores real geometry with time weighting | 3 live calls, real polylines, day and night. Motijheel→Paltan→Shahbagh: daytime flags only Paltan (10); at 11pm commercial cores ×1.6 take Paltan to 16; low-crime Demra returns `safe, riskScore 1` | **Strong** |
| Hazard clustering works | scheduled-function log, 15 Sep: 10 live reports → 7 zones | **Strong** |
| DMP extraction is accurate | Aug 2026 and Apr 2025 both match the scan by hand | **Strong** |
| News pipeline produces admissible advisories | live run: 58 items → 5 street-crime → 1 advisory | **Strong** |
| Per-thana risk reflects Dhaka today | 2009 data | **Weak — stated** |
| Backfilled baseline is accurate | dry run only, never recorded | **Unverified** |

---

## 7. Known limitations

- **The per-thana baseline is 17 years old**, and no official source can
  refresh it. Section 8 is the plan.
- **News coverage is not incidence.** A thana nobody reports on scores low.
  Mitigated by crowdsourced hazards, which come from users standing in the
  place; not eliminated.
- **DMP gives citywide only** — it can say crime is up, never *where*.
- **Extraction fails below 2025.** May 2019's layout returns zeros and is
  refused rather than recorded. Widening the prompt would recover that history.
- **Google News is unreachable from Cloud Functions**, so the backfill cannot
  be scheduled in GCP as things stand.

---

## 8. To do — for the next session

Ordered by value. Everything here is built or scoped; none of it is research.

### 8.1 Run the news backfill — **built, dry-run only, not yet recorded**

This is the one that retires the 2009 ranking as the app's idea of Dhaka.

```bash
node functions/scripts/backfill_thana_evidence.js --dry-run   # inspect first
node functions/scripts/backfill_thana_evidence.js             # record
```

Must run **outside GCP** — Google News returns 503 to Cloud Functions.

Dry run on 16 September found **97 incidents across 28 thanas**, 13 of them with
the 3+ months `learned_baseline` needs before it moves a score:

| Thana | 2009 score | News months | Rank 2009 → news |
| --- | --- | --- | --- |
| Mohammadpur | 3.8 | 10 | 6th → **1st** |
| Dhanmondi | 6.0 | 8 | 1st → 2nd |
| Jatrabari | 4.9 | 8 | 3rd → 3rd |
| Gulshan | 5.4 | 7 | 2nd → 4th |
| Mirpur | 2.4 | 7 | 8th → 5th |
| Pallabi | 1.7 | 7 | 11th → 6th |
| Uttara | 4.1 | 5 | 5th → 7th |
| Hazaribagh | 1.3 | 4 | 13th → 8th |
| Shahbagh | 4.7 | 4 | 4th → 10th |
| Rampura | 3.7 | 4 | 7th → 12th |
| Demra | 1.0 | 0 | 14th → 14th |

Mohammadpur going 6th to 1st is the point. `lib/thana_advisory.js`'s own doc
comment says the seed scores it 3.8, "nowhere near the hotspot threshold, while
anyone living in Dhaka today would tell you it belongs there." That was an
assertion in a comment; it is now dated, citable evidence.

Demra bottom on both sources is a useful control.

**Before running, know that it changes routing** for an app currently in
testers' hands. It is idempotent — keyed on source URL, earliest article per
month — so re-running refreshes rather than duplicates.

**After running**, confirm it took:

```bash
firebase functions:log --only decayHazardZones --project ant-assistive-nav
```

The hourly line has said "0 thanas gained an evidence month" since the day it
shipped. It should stop saying that.

### 8.2 Decide what happens to the 2009 `densityEstimate`

Once 8.1 has run, the baseline has a current per-thana signal for the first
time, and the seed's role should be an explicit decision rather than drift.

The two fields are different claims and should be treated differently:

- **`densityEstimate`** — a 2009 *crime* measurement. Stale. Candidate for
  removal, replaced by a baseline derived from evidence months.
- **`categoryHint`** — *land use* (commercial core, transit hub, residential).
  Not crime data, does not rot the same way, verifiable today, and it drives
  the temporal multiplier, which is one of the genuinely defensible parts of
  the engine. **Keep this regardless.**

If `densityEstimate` goes, `baseCrimeScore` needs a replacement — a flat
neutral base, with evidence months providing all the geography. Note the cost
honestly: the app then flags nothing on day one in thanas with no evidence yet.

### 8.3 Widen extraction to pre-2025 layouts

`findTableImage` resolves scans back to 2019, but `extractCityRowViaGemini`
returns all zeros for May 2019 — a different table layout — and
`validateExtraction` correctly refuses it.

Recovering 2019–2024 would give a real multi-year citywide trend instead of a
multiplier computed from a few months. Worth an hour: fetch a 2019 and a 2022
scan, look at them, and add their column headings to the prompt.

### 8.4 Wire more news sources

Currently two outlets, four feeds. Dhaka Tribune, bdnews24 and New Age all 403
from everywhere, so they cannot be fetched directly — but **Google News
aggregates them**, and the backfill already benefits. If the 6-hourly live
pipeline needs more volume, routing it through Google News from outside GCP is
the same trade the backfill already makes.

### 8.5 Confirm `seedCrimeZones` has actually run

`task.md` records it returning `{"written":41}`, and `checkRouteSafety`
verifiably found real zones on real polylines, so it has. But no one has read
the collection directly this session — there are no application-default
credentials on the dev machine, so counts came from function logs. Worth one
direct read to close the loop.

### Not planned

- **Social signals.** `lib/social_signal.js` and the tiering exist and work. Left
  off deliberately: news carries provenance a post does not, and this app turns
  belief directly into "will not walk you through there" for someone who cannot
  see the map to disagree. Revisit only if news coverage proves too sparse.
- **A formal DMP data request.** If per-thana figures were ever released
  officially, they would beat every scraper here. Worth asking; not worth
  blocking on.
