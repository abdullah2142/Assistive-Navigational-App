# Google Maps Platform setup

What ANT uses Google for, what it costs, how the free tier is enforced, and
the exact steps to switch it on.

---

## 1. Which APIs, and why each one

Four. Not more — most of Maps Platform is irrelevant to a walking app for
blind users, and several products that sound relevant (Street View, Elevation,
Roads, Distance Matrix) either do nothing for us or are legacy.

| API | What it does here | Free tier | After that |
|---|---|---|---|
| **Maps SDK for Android** | Draws the map widget | **Unlimited, free** | never billed |
| **Geocoding API** | "Road 7, Dhanmondi" → coordinates | 10,000/month | ~$5 per 1,000 |
| **Routes API** | Walking directions with a **real pedestrian profile** | 10,000/month | ~$5 per 1,000 |
| **Places API** | Place *names* ("Labaid"), and hospitals near a point during an emergency | 5,000/month | ~$32 per 1,000 |

### Why Routes API and not Directions API

The Directions API is **Legacy** and cannot be enabled on a project that never
had it — which is this project. Routes API is its replacement, and it is the
better one for us anyway: `travelMode: WALK` is a genuine pedestrian routing
profile.

That is the whole reason this migration exists. The public OSRM demo server we
used before returns *car* routes under a walking label — its `foot` and
`driving` endpoints give byte-identical answers. For a sighted user that is an
annoyance. For someone following spoken turn-by-turn with no way to see that
the road has no pavement, it is the app narrating a route into traffic.

### Why Places API, when we already have Geocoding

They answer different questions. Geocoding resolves **addresses**; Places
resolves **names**. A voice-first app gets overwhelmingly the second kind —
"take me to Labaid", not "take me to house 6, road 4". A geocoder handed a
business name returns nothing, or something confidently wrong.

Places is also by far the most expensive of the four, so the code never calls
it first. `RoutingService.geocodeCandidates` runs the cheap Geocoding lookup
and only escalates to Places when that comes back empty. The second use —
finding hospitals and police stations during an emergency — is a call that
fires only when someone is already in trouble, so its volume is close to zero.

### What we deliberately do not enable

- **Street View, Elevation, Air Quality, Solar, Time Zone** — no use here.
- **Distance Matrix** — legacy, and we need one route, not a matrix.
- **Roads API** — snap-to-road is for vehicles.
- **Maps SDK for iOS** — only if iOS ships. Also free.

---

## 2. What it will actually cost you

**Nothing, at testing scale.** Five testers cannot generate 10,000 route
requests in a month; that is 300+ routes every day without pause.

The $300 new-account credit is not the relevant number and you should not plan
around it — it expires in 90 days and is not Maps-specific. The number that
matters is the **per-API monthly free tier**, which resets every month and does
not expire. Note that Google **retired the old flat $200/month credit in March
2025**; anything written before that describing a shared $200 pool is out of
date.

Rough sense of scale if this ever went past testing, assuming one route and one
geocode per trip:

| Daily active users | Trips/user/day | Monthly calls per API | Cost |
|---|---|---|---|
| 5 (testing) | 5 | ~750 | $0 |
| 50 | 4 | ~6,000 | $0 |
| 100 | 4 | ~12,000 | ~$10/month |

Places is the one to watch, because its free tier is half the size and its rate
is six times higher. The cascade design is what keeps it small.

---

## 3. Keeping spend at zero

Two ceilings, applied. Either alone would be leaky; together they are hard to
get past.

### Google's side — daily quotas (applied 2026-09-07)

Settable per-day, per-project caps **do** exist for all three billable APIs.
They are simply defaulted to effectively unlimited (int64-max, or 75,000/day
for Places — fifteen times its own monthly free tier), which is why they look
absent. The console's quota page is close to unreadable for these APIs; the
values below were found and set with `gcloud`.

| Metric | Per day | Per minute |
|---|---|---|
| `geocoding-backend.googleapis.com/billable_default` | **300** | 10 |
| `routes.googleapis.com/compute_routes_requests` | **300** | 10 |
| `places.googleapis.com/SearchTextRequest` | **100** | 5 |
| `places.googleapis.com/SearchNearbyRequest` | **50** | 5 |

300/day is at most 9,300 in a 31-day month against a 10,000 tier. The two
Places metrics together are at most 4,650 against 5,000. The per-minute caps
sit far above five testers and far below a runaway loop, so a bug is pinned at
pennies an hour rather than hundreds.

Note `billable_default` is the **v3** Geocoding metric — the classic
`maps.googleapis.com/maps/api/geocode/json` service this app calls. The four
`v4/*` metrics beside it belong to a different API version we do not use, and
are the main reason that page looks full of duplicates.

Re-apply any time with:

```bash
./scripts/maps_lockdown.sh quotas
```

### The client's side — `ApiBudget`

`lib/core/services/api_budget.dart` counts calls project-wide in Firestore at
`api_usage/{YYYY-MM}` and stops at 9,000 / 9,000 / 4,500.

It is not redundant with the quotas. Google's cap is per calendar *day*, so 31
maxed-out days still overshoot a 30-day month slightly, and Google cannot see
that the two Places metrics share one allowance the way the client can. It
also fails closed, degrades to OpenStreetMap silently rather than erroring,
and gives this project its first readable usage figure — `api_usage` doubles
as the dashboard the console refuses to be.

### Budget alerts still do not cap anything

They email you after the money is spent. Keep one — a $1 budget wired to the
Pub/Sub kill switch already built for Gemini — as the thing that *tells* you
the other two failed.

---

## 4. The key, and why the Dart code sends two extra headers

A new key was created on `ant-assistive-nav` (the old one in git history
belonged to a personal project with no billing and is no longer used). It was
restricted at creation:

- **Application**: Android, package `com.ant.assistive.ant_app`, SHA-1
  `8F:9E:40:5C:1D:C3:D8:41:10:56:FE:19:FB:E1:78:32:F8:95:4A:FA`
- **API targets**: Maps SDK for Android, Geocoding, Routes, Places — nothing
  else

One SHA-1 covers every build because release currently reuses the debug key
(`android/app/build.gradle.kts` has no release `signingConfig`). **Adding a
real release keystore later without registering its fingerprint will break
Google in exactly the build testers receive** — and break it invisibly, see
below.

### The trap that nearly shipped

An Android application restriction blocks *web-service REST* calls, and this
app calls Geocoding, Routes and Places over plain HTTPS rather than through
the Maps SDK. Measured against the live restricted key on 2026-09-07:

| Request | Result |
|---|---|
| Plain REST, no extra headers | `REQUEST_DENIED` |
| Routes API, plain | 403 — *"Android client application ⟨empty⟩ are blocked"* |
| With `X-Android-Package` + `X-Android-Cert` | **OK** |
| Same, but SHA-1 written with colons | `REQUEST_DENIED` |

So `MapsConfig.androidRestrictionHeaders` is sent on every Google REST call,
with the fingerprint stored **colon-free** — `keytool` prints it with colons,
which is exactly the mistake someone re-deriving the value would make.

This matters more than it looks. Had the headers been missing, the app would
not have appeared broken: `RoutingService` would have caught the denial and
fallen back to OpenStreetMap, so every route would still work while Google was
never called at all. Tests now assert both headers and the colon-free format.

### What restriction does and does not buy

The key ships inside the APK and the package name and fingerprint are both in
this public repo, so anyone who wants to forge those two headers can. That is
true of every Android Maps key — the fingerprint is extractable from any APK —
and it is why the real protections are the API restriction (a stolen key can
reach four services, not the whole platform) and the quotas above (a stolen
key can spend 300 requests a day, not 300,000).

---

## 5. Switching it on

Nothing is on by default. The code ships with Google **off**, because a build
that spends money should be a deliberate build.

**First, prove the key actually works.** Run once with the fallback disabled —
otherwise a misconfigured key looks like a working app, because every failed
call is quietly answered by OpenStreetMap:

```bash
flutter run --dart-define=ROUTING_PREFER_GOOGLE=true --dart-define=ROUTING_OSM_FALLBACK=false
```

Ask for a route. If it fails, the log names the cause — and the three causes
need different fixes:

- `PERMISSION_DENIED` — key wrong, API not enabled, or restrictions don't match
  this build's SHA-1
- `RESOURCE_EXHAUSTED` — the daily quota cap worked
- `INVALID_ARGUMENT` — a bug in the request; report it

Once a route comes back, build normally with the fallback restored:

```bash
flutter build apk --release --dart-define=ROUTING_PREFER_GOOGLE=true
```

---

## 6. State, and what is left

**Done** (2026-09-07, verified live):

- Four APIs enabled on `ant-assistive-nav`, billing attached
- New key created, Android- and API-restricted
- Daily and per-minute quotas set on all four metrics
- `ApiBudget` enforcing the monthly ceiling client-side
- All four endpoints called successfully against the live APIs; every response
  field matches the parsers

**Not done, and only you can do it:**

1. **Walk a real route in Dhaka** with `ROUTING_PREFER_GOOGLE=true` and check
   the directions follow a footpath a person could actually use. The wire
   format is now verified against Google's servers; whether the *route* is
   walkable is not something any test here can establish.
2. **A release signing key.** Release reuses the debug key today. When that
   changes, add the new SHA-1 both to `MapsConfig.androidCertSha1` and to the
   key's restriction in Cloud Console, or Google goes dark in the build that
   matters.
3. **A $1 budget alert** wired to the Gemini Pub/Sub kill switch, as the thing
   that tells you the two ceilings above both failed.
