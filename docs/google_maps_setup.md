# Google Maps Platform setup

What ANT uses Google for, what it costs, how to make sure it can never cost
more than nothing, and the exact steps to switch it on.

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

## 3. Making it impossible to be billed

There are two controls and they are **not** interchangeable. Getting this wrong
is the single most expensive mistake available here.

### Budget alerts do not cap anything

A budget sends an email when spending crosses a threshold. It does not stop
requests. You already have this shape working for Gemini via Pub/Sub — same
principle, same limitation: **it tells you after the money is gone.**

### Quotas are the hard cap

This is the real control. Per API, per day.

**Cloud Console → Google Maps Platform → Quotas →** pick the API **→ Requests
per day →** edit.

Set each to comfortably below the monthly free tier divided by 31:

| API | Free/month | Set daily cap to |
|---|---|---|
| Geocoding API | 10,000 | **300** |
| Routes API | 10,000 | **300** |
| Places API | 5,000 | **150** |

300 × 31 = 9,300, under the 10,000 free tier with room for a short month and a
bad day. Once the cap is hit, Google returns `RESOURCE_EXHAUSTED` and **charges
nothing**.

The app is built for that outcome. `RoutingService` reads
`RESOURCE_EXHAUSTED` as a routing failure and falls straight through to
OpenStreetMap, so hitting the cap degrades quality — it does not take
navigation away from anyone. That is the reason the OSM path was kept rather
than deleted.

Do both anyway: quotas to make overspend impossible, a budget alert to tell you
that the quota did its job.

---

## 4. Restricting the key

**Do this before distributing any build.** The key ships inside the APK and can
be extracted by anyone holding the file — that is unavoidable for a client-side
Maps key, which is why Google's answer is restriction rather than secrecy. This
particular key has additionally been in public git history since `19c3d37`, so
treat it as already known to strangers.

Get the certificate fingerprints — **both**, or the map goes blank in whichever
build you forgot:

```bash
keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android -keypass android
```

**Credentials → the key →**

- **Application restrictions** → *Android apps* → add package
  `com.ant.assistive.ant_app` with the debug SHA-1, and again with the release
  SHA-1.
- **API restrictions** → *Restrict key* → tick exactly the four APIs above.

The API restriction is what stops a scraped key being spent on some unrelated
product billed to your project.

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

## 6. What I need from you

1. **Billing attached** to the `ant-assistive-nav` project. Required even to
   use the free tier — Google will not serve these APIs without a payment
   method on file. This is the step no one else can do.
2. **The four APIs enabled** on that project.
3. **Daily quotas set** (section 3) before the key is in any distributed build.
4. **The key restricted** (section 4), with both SHA-1 fingerprints.
5. **The new key value**, if you create a fresh one rather than restricting the
   existing one — it goes in `ant_app/lib/core/config/maps_config.dart`. Send it
   however you like; it is a public identifier by design, not a secret.

Then one thing only you can confirm: **walk a real route in Dhaka** with
`ROUTING_PREFER_GOOGLE=true` and check the directions match a footpath a person
could actually use. Every claim about the Google wire format in this codebase
is pinned by tests written against documentation — no request has ever reached
Google's servers from this code. The tests prove the parsing is self-consistent.
They cannot prove the route is walkable.
