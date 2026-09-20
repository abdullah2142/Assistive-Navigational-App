# Module 4 — Crime & Contextual Safety

How a walking route gets a safety verdict, where every number in it comes
from, and which of them are current.

Written against the deployed system on 16 September 2026; revised 21
September. Companion to `04_module_plan_crime.md`, which is the plan; this is
what actually runs.

**Three things changed on 21 September and all are load-bearing.** The
citywide multiplier was found sitting on its floor because `cityTrend` has a
13-month hole (§3). A census showed the night threshold flagging 11 of 41
thanas before any crime data is involved (§6a) — now fixed, down to 4, by
separating "route around this" from "say something about this" (§8.0). The
two backfills that make scores larger are built and tested but still unrun.

---

## 1. What the module decides

One question, asked once per candidate route: **is this route safe enough to
walk right now?**

`RoutePlanningService` asks Google for every walking alternative, scores each
through the `checkRouteSafety` Cloud Function, and takes the **first safe
one**. If none are safe it takes the lowest-risk candidate.

Two questions, deliberately answered separately since §8.0: **`safe`** decides
whether to keep looking for a better route, and **`shouldWarn`** decides
whether to say anything. They are not the same question, and one number
answering both is what made the app warn about a quarter of Dhaka every
night.

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

Whether the app *says* anything is a separate calculation, because 7 is a
position in a 2009 ranking rather than a level of danger, and at night it
sits below the city's own 75th percentile:

```
warnThreshold = max( p90 of every thana's ambient risk at this hour , 7 )

shouldWarn = riskScore > warnThreshold
             OR a thana on the route has a live advisory and scores above 7
             OR the route passes a confirmed hazard
```

See §8.0. `safe` still decides routing; only the spoken warning moved.

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

### Citywide trend — current, automated, and with a hole in it

`scrapeDmpCrimeReports` runs monthly on the 12th (DMP publishes the previous
month around the 9th) and reads `dmp.gov.bd/crime_data/{month}-{year}/`.

**It reads exactly one month — the newest — so it can keep the series
current but can never repair it.** Read directly on 21 September 2026,
`cityTrend` held 66 months ending **2025-05**, plus a lone **2026-07**: a
13-month hole. Every row came from a Kaggle mirror of national PHQ reports
imported on 3 September, or from `police.gov.bd`. Not one came from the DMP
table this section describes.

`updateCityTrendMultiplier` divides the newest month by the average of the
three before it *in the collection*, with no notion of whether those are
adjacent months or a year apart. So it compared July 2026 (170
pedestrian-relevant) against March–May **2025** (~239) and produced **0.71**
— its clamp floor — which multiplied every route score in Dhaka from 3
September onward. Nothing errored and nothing logged.

`scripts/backfill_city_trend.js` fills the hole; `check_data_health.js` now
detects it. The Kaggle rows themselves are sound: 2024-01 and 2024-06 were
checked column-for-column against the DMP scans and match exactly, so the
backfilled months are comparable with what is already there.

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
| `checkRouteSafety` | callable | scores one route, and decides separately whether to warn about it (§8.0) |
| `seedCrimeZones` | callable | writes the 41 thana documents |
| `scrapeDmpCrimeReports` | 12th monthly | citywide trend from DMP |
| `ingestCrimeNews` | every 6 h | news → advisories |
| `recordThanaAdvisory` | callable | validated advisory write |
| `recordThanaIncident` | callable | validated incident write (feeds learned baseline) |
| `recordCityCrimeMonth` | callable | manual citywide write, if the site walls up again; also what `backfill_city_trend.js` writes through |
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
| `seedCrimeZones` has run | all 41 documents read from the collection by slug, 21 Sep | **Strong** |
| Kaggle/PHQ rows match the DMP scans | 2024-01 and 2024-06 agree column-for-column with the published images | **Strong** |
| The citywide multiplier means what it says | **No — it was 0.71 from comparing across a 13-month hole (§3)** | **Refuted** |
| The warning rule can never warn more than the old one | asserted over all 24 hours x 4 multipliers, `risk_threshold_test.js` | **Strong** |
| The warning rule still flags the one real outlier | Paltan warns at every hour tested | **Strong** |
| The new wording helps a real user | nobody has walked with it | **Unverified** |

---

## 6a. How much of Dhaka does this call unsafe?

*(Measured before §8.0. Kept as the baseline that change is judged against.)*

Worth stating plainly, because it is not obvious from the design and it
bears on every other decision here. With **no evidence recorded at all** —
just `baseCrimeScore × temporalMultiplier × cityTrendMultiplier`:

| | 2pm | 11pm |
| --- | --- | --- |
| at the live 0.71 multiplier | **1** of 41 | **11** of 41 |
| at a neutral 1.0 | **1** of 41 | **13** of 41 |

At night that is Dhanmondi, Gulshan, Kotwali, Motijheel, New Market, Paltan,
Ramna, Shahbagh, Tejgaon, Bangshal and Jatrabari — essentially all of central
Dhaka.

Two things follow. First, the night figure is driven by the **temporal
multiplier**, not by crime data: commercial cores take ×3.0 and a hotspot
×5.0, so a mid-ranking base score clears 7 on the clock alone. Second,
`baseCrimeScore` is a min-max normalisation anchored on Demra and Paltan, so
"7" means *70% of the way from Dhaka's quietest thana to its noisiest in
early 2009* — a **relative rank**, never an absolute claim that a place is
dangerous.

The mitigation already in the design is that this is a *preference*, not a
refusal: `RoutePlanningService` takes the first safe alternative, and if none
are safe it takes the lowest-risk one and flags `stillUnsafe`. Nobody is left
without a route. But a warning that fires on a quarter of the city every
night is a warning users learn to talk over, and that failure mode — alarm
fatigue — is a real risk for someone who cannot see the map to disagree.
**Not a data problem and not fixable by any backfill; a threshold problem.**

**Fixed on 21 September — see §8.0.** The table above still describes what
`safe` does, because route *selection* was left alone deliberately. What
changed is what gets spoken: 11 of 41 at night became 4, by comparing a
route against the city's own spread at that hour instead of against a
constant. Daytime is unchanged at 1.

---

## 7. Known limitations

- **The per-thana baseline is 17 years old**, and no official source can
  refresh it. Section 8 is the plan.
- **News coverage is not incidence.** A thana nobody reports on scores low.
  Mitigated by crowdsourced hazards, which come from users standing in the
  place; not eliminated.
- **DMP gives citywide only** — it can say crime is up, never *where*.
- **DMP published no crime table before January 2024.** The 2019–2023 month
  pages carry one image each, and it holds three *recovery* tables — arms,
  stolen vehicles, narcotics — with no `অপরাধ চিত্র` table anywhere on the
  page. Checked by eye for 2019-05, 2019-12, 2022-04 and 2023-06, against
  every `wp-content/uploads` reference in the markup. This was previously
  recorded as a layout problem a widened prompt would fix; it is not a
  prompt problem and there is nothing there to recover.
- **A gap in `cityTrend` is silent and consequential**, because the
  multiplier compares across it rather than noticing it. See §3.
- **Google News is unreachable from Cloud Functions**, so the backfill cannot
  be scheduled in GCP as things stand.

---

## 8. To do — for the next session

Ordered by value. Everything here is built or scoped; none of it is research.

**8.0 is done, which unblocks the two held backfills.** Both make scores
larger, and the reason for holding them was that the threshold they are
compared against did not mean anything stable. It does now — and because the
new rule can only ever warn *less* than the old one, the backfills no longer
carry the risk that stopped them. They remain unrun pending a decision to
run them; see 8.1 and 8.3.

### 8.0 The threshold is relative, the cut-off is absolute — **done**

**Built 21 September 2026** in `functions/lib/risk_threshold.js`, wired into
`checkRouteSafety`, `SafetyVerdict` and the assistant's spoken replies.
Night-time warnings drop from **13 of 41 thanas to 4**; daytime stays at 1.
Route *selection* is untouched. What follows is the reasoning; the
implementation notes are at the end.

§6a is the measurement: **11 of 41 thanas are flagged at 11pm with no crime
evidence recorded at all**, and essentially all of central Dhaka is in that
list. Nothing in any backfill caused it and no backfill can fix it.

#### What is actually broken

Four things, and only the last one is the bug.

1. **The scale is relative.** `baseCrimeScore` is a min-max normalisation
   anchored on Demra (quietest) and Paltan (noisiest) in early 2009. A 7
   means "70% of the way up Dhaka's internal 2009 spread". It has never
   encoded an absolute claim that a place is dangerous, and it cannot.
2. **The stack is multiplicative and effectively unbounded.** base (1–10) ×
   temporal (1–5) × city (0.7–1.5) × advisory (1–2) × learned (1–1.6) tops
   out near 240, compared against a fixed 7. Past the threshold the number
   stops discriminating: Dhanmondi at 17.0 and Shahbagh at 7.3 are both just
   "unsafe".
3. **Night is a blanket step.** Every commercial core takes ×3.0 at 8pm.
   That is a statement about land use, not about a street, and combined with
   (1) it is what pushes the city centre over.
4. **One number answers two different questions.** *"Which of these
   alternatives should I prefer?"* is comparative, and the engine does it
   well — relative scores are exactly right for ranking. *"Should I warn
   this person?"* is absolute, and the same number cannot answer it.

**Only (4) is the defect.** The scoring is fine; deriving a spoken warning
from a fixed cut on a relative scale is not.

#### Why this matters more than it sounds

The planner takes the first safe alternative and, when none are safe, the
lowest-risk one with `stillUnsafe` set — so nobody is ever left without a
route, and the comparative path is genuinely working. The harm is narrower
and worse: a warning that fires on a quarter of the city every night is one
users learn to talk over. For someone who cannot see the map to disagree,
the warning *is* the information, and a warning trained to be ignored fails
exactly when it is real. Alarm fatigue is the risk here, not misrouting.

It also flattens a distinction a pedestrian actually needs. A thana that has
been mid-ranking for twenty years and a thana with a live advisory this week
produce the same score and the same sentence. Chronic and acute are
different facts and want different words.

#### The shape of the fix

Three changes, in order. No new data — all of this is computable from what
`crimeZones` already holds.

1. **Keep the score for ranking; stop deriving the spoken warning from a
   fixed cut on it.** `checkRouteSafety` keeps returning `riskScore`
   unchanged, so route *selection* does not move at all.
2. **Make the warning relative to the city at that hour.** Warn when a
   route's risk sits in roughly the top decile *for that time of day*,
   computed across all 41 thanas. This is self-calibrating: it means
   "unusually risky for a Dhaka night" instead of "risky compared with Demra
   at 2pm in 2009", and the 8pm cliff stops mattering because the whole
   distribution moves with it.
   - **The obvious objection, and the answer.** A purely relative rule
     always finds a top decile, even on a genuinely quiet night. So it needs
     an absolute floor underneath: below some level, say nothing regardless
     of rank. Relative for the ceiling, absolute for the floor.
3. **Say which kind of risk it is.** `advisoryFactor` and `learnedFactor`
   are already separable from `baseCrimeScore` — they are collapsed into one
   product before anything can use them. Keeping them apart in the response
   lets the assistant distinguish "this area has been rough for a while"
   from "something was reported here this week", which is the distinction
   §6a says is being lost.

#### What it actually does

`warnThreshold = max(p90 of the city at this hour, 7)`, and a route speaks
when its `riskScore` clears that — **or** when one of its thanas carries a
live advisory and clears 7. `safe`, `threshold` and `dangerousZones` are
untouched, so the planner's "first safe route, else lowest-risk" loop
behaves identically.

| | 2pm | 11pm |
| --- | --- | --- |
| `warnThreshold` | 7 (the floor binds) | 16.2 (the distribution binds) |
| warns | 1 of 41 — Paltan | 4 of 41 — Dhanmondi, Kotwali, Motijheel, Paltan |
| was | 1 of 41 | 13 of 41 |

**It cannot warn where the old rule did not.** The floor *is* the old
threshold and the rule takes the maximum, so the warned set is always a
subset. Asserted across all 24 hours × four multipliers rather than argued:
`risk_threshold_test.js`, "THE load-bearing property".

Worked examples, at 11pm with the live 0.71 multiplier:

| Route | `safe` | risk | speaks |
| --- | --- | --- | --- |
| Motijheel→Paltan→Shahbagh | false | 35.5 | **yes** — chronic |
| Ramna | false | 7.8 | no — unsafe, but ordinary for the hour |
| Shahbagh | false | 7.3 | no |
| Shahbagh, live `high` advisory | false | 11.0 | **yes** — acute |
| Mirpur→Pallabi | true | 2.7 | no |

That fourth row is why the advisory exception exists. A pure percentile
silenced 11.0 against a threshold of 16.2 — current, sourced reporting
naming a neighbourhood, buried by the ambient distribution. It was found by
simulating real routes, not by reading the code. Advisories now need only
clear the floor.

#### Chronic vs acute

`riskKind` is returned alongside, so the assistant distinguishes a place
that has been mid-ranking for years from one where something was reported
this week:

- chronic — *"passes through an area that's riskier than most at this hour"*
- acute — *"there have been recent reports about an area on the way"*

Only the second is something a pedestrian can act on tonight.

#### How to know it still works

The census in §6a is the before. Night should stay well below 11 of 41,
daytime at 1, and **Paltan must still warn at every hour** — the one thana
the source data genuinely supports as an outlier (3.1σ). A recalibration
that silences Paltan has overshot, which is a test rather than a note.

#### Still open

The two tuning constants are judgement, not measurement. `WARN_PERCENTILE`
0.9 selects four thanas at both hours; p95 would select two and drop Kotwali
and Motijheel, which seems the wrong pair to go quiet about, but nobody has
tested that against real walking. And `ABSOLUTE_FLOOR` stays at 7 purely to
keep the change conservative — lowering it is a real decision on its own
evidence, not a tweak to slip in here.

### 8.1 Run the news backfill — **built and verified; held pending 8.0**

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

It is idempotent — keyed on source URL, earliest article per month — so
re-running refreshes rather than duplicates.

**Whether it changes routing depends entirely on the citywide multiplier,
which is why the dry run now reads that multiplier and prints the
arithmetic.** At the live 0.71 (§3), *no* thana crosses the threshold from
this evidence: Mohammadpur reaches 6.6 at 11pm, Adabor 5.0. Repair the
multiplier to ~1.0 first and the same evidence takes Mohammadpur to 9.3 and
Adabor to 7.1, and Dhanmondi crosses in *daytime*.

So the order is not arbitrary. Repair the multiplier first, then re-read this
dry run — a table produced against a broken multiplier is describing an app
that does not exist. And both of those come after 8.0, because both make
scores larger and 8.0 is the question of what the threshold they cross
actually means.

**After running**, confirm it took:

```bash
firebase functions:log --only decayHazardZones --project ant-assistive-nav
```

The hourly line has said "0 thanas gained an evidence month" since the day it
shipped. It should stop saying that.

### 8.2 What happens to the 2009 `densityEstimate` — **decided: retire on a condition**

The two fields are different claims and stay treated differently:

- **`categoryHint`** — *land use* (commercial core, transit hub,
  residential). Not crime data, does not rot the same way, verifiable today.
  **Keep regardless.**
- **`densityEstimate`** — a 2009 *crime* measurement. Retire, but not yet,
  and on a stated trigger rather than a vibe.

#### Why not simply delete it, given it is seventeen years old

The fair challenge is: if it is stale, why does it get a vote today? Taking
it seriously, `densityEstimate` bundles two claims:

1. **How much crime there was.** A level. Worthless now, no argument.
2. **Which areas ranked above which.** A ranking, and partly durable —
   because it largely tracks land use, and land use moves slowly.

But claim 2's durable part is **already carried by `categoryHint`**, which is
current and checkable. So the field's useful content is mostly redundant and
its unique content is the stale part. That argues for deletion.

Two reasons it still survives this round — the first weak, the second not:

- *(weak, and not a good enough reason on its own)* `isNotoriousHotspot`
  derives from it. That is a coupling argument, not a truth argument, and it
  is fixable: hotspots could be re-derived as outliers in **evidence
  months**, which would be strictly better — current, citable, and still
  computed rather than hand-listed.
- *(the real reason)* **The evidence corpus cannot carry the geography
  yet.** 14 of 41 thanas have the 3+ months `learned_baseline` needs; 13
  have none at all. Delete the seed today and 27 thanas share one
  undifferentiated base. And a flat base does not rescue the low-ranked
  thanas either, because `learnedFactor` *multiplies*: Pallabi has 7
  evidence months and 1.27 × a flat 4.0 is still nowhere near 7. You would
  lose the 2009 geography without gaining current geography.

#### The decision

**Retire `densityEstimate` when ≥30 of 41 thanas hold 3+ evidence months.**
At that point the seed becomes a fallback for the remainder rather than the
base, and `isNotoriousHotspot` re-derives from evidence outliers instead of
2009 density outliers.

Running 8.1 is what starts the clock: it takes the count from 0 to 14 in one
pass. `check_data_health.js` is the natural place to report progress toward
the trigger.

Note the interaction with 8.0: if the warning becomes a *relative* judgement,
an undifferentiated base is much less harmful than it is today, because
everything is being compared to everything else rather than to a fixed line.
8.0 may well lower this threshold. Revisit it there rather than separately.

### 8.3 ~~Widen extraction to pre-2025 layouts~~ — done, and the premise was wrong

**Superseded on 21 September 2026.** The scans were fetched and looked at.
There is no pre-2024 layout to widen the prompt for: DMP published no crime
table at all before January 2024, only recovery tables (§7). The zeros were
correct.

What *was* missing was any way to read a month other than the newest, which
is why `cityTrend` had a 13-month hole and the citywide multiplier sat on its
0.71 floor (§3). Now built:

- `EARLIEST_CRIME_TABLE_PERIOD`, `listMonthPages`, `listCrimeTableMonths`
  and `fetchAndExtractMonth` in `lib/crime_report_ingestion.js`
- `scripts/backfill_city_trend.js` — records every published month that is
  missing, skipping the ones already held
- the extraction prompt now returns `hasCrimeTable`, so a recovery-only
  scan is refused by name rather than as "total cases is zero"

```bash
GEMINI_API_KEY=... node functions/scripts/backfill_city_trend.js --dry-run
```

The dry run needs no key and writes nothing. To record, the key can be fed
straight from Secret Manager without it ever being pasted anywhere:

```bash
GEMINI_API_KEY="$(firebase functions:secrets:access GEMINI_API_KEY --project ant-assistive-nav)" node functions/scripts/backfill_city_trend.js
```

**The recording step is held, deliberately.** Filling the hole takes the
multiplier from 0.71 to roughly 1.0, which raises **every route score in
Dhaka by about 41%** the moment it lands, and takes the night-flagged count
from 11 of 41 to 13 (§6a). It is the correct number — 0.71 is an artefact of
comparing July 2026 against spring 2025 — but "more correct" and "safe to
ship to people walking tonight" are different claims, and §8.0 is the one
that decides the second. Verified ready on 21 September: 13 missing months
identified, all 24 published months resolve, tooling tested.

### 8.4 Wire more news sources — done, pending one deploy-time check

Two Google News queries added to the Cloudflare Worker's `NEWS_FEEDS`
(`src/collectors/news.js`). The Worker, not the Cloud Function: Google News
answers 503 to GCP, and this is the project's one always-on host outside it.

It is not a marginal addition. Probed against the live feeds on 21
September, the four direct feeds produced **zero** candidates and Google News
produced one — a Shah Ali stabbing published by The Daily Star that the Daily
Star's *own two feeds* did not surface.

Two details that matter:

- **Direct feeds are ordered first.** `collectNews` keeps the first version
  of a story, and an advisory's `sourceUrl` is its entire provenance. A
  `news.google.com/rss/articles/CBMi…` redirect is a much worse record than
  the publisher's own URL.
- **Dedupe is by title as well as URL.** Google News rewrites every link, so
  URL dedupe cannot see across sources and one story would be classified —
  and paid for — twice.

**Still unverified: whether Cloudflare's edge can reach Google News.** It
works from a laptop, and this project's own rule is that this proves nothing.
Hit the deployed `/news` endpoint and read the per-feed counts. If Google
answers 503 there too, `fetchFeed` logs it and returns `[]`, so the four
direct feeds carry on unchanged — this can only add, never subtract.

```bash
node cloudflare-worker/scripts/probe_feeds.mjs   # local funnel, free, no model calls
```

### 8.5 ~~Confirm `seedCrimeZones` has actually run~~ — done

**Closed 21 September 2026. All 41 thana documents are present**, read
directly from the collection, checked by slug against the seed rather than
merely counted.

The credentials barrier is gone rather than worked around:
`check_data_health.js` no longer uses the Admin SDK and needs no `gcloud`.
It signs in anonymously and reads over the Firestore REST API — every
collection is `allow read: if request.auth != null`, and this is the same
throwaway-token pattern two other scripts already use to *write*.

```bash
node functions/scripts/check_data_health.js
```

It also now watches `cityTrend` for mid-series gaps, which is how §3's
13-month hole surfaced, and knows about `hazardZones`' timestamp fields,
which it previously reported as "no timestamp field found".

### Not planned

- **Social signals.** `lib/social_signal.js` and the tiering exist and work. Left
  off deliberately: news carries provenance a post does not, and this app turns
  belief directly into "will not walk you through there" for someone who cannot
  see the map to disagree. Revisit only if news coverage proves too sparse.
- **A formal DMP data request.** If per-thana figures were ever released
  officially, they would beat every scraper here. Worth asking; not worth
  blocking on.
