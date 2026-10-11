# Guide — Technical Report

**Date:** 2026-10-11
**Repository:** `tassneem-ch/guide` (working copy: `Default Project/`)
**Components:** Flutter mobile client (`app/`), FastAPI backend (`backend/`), CI (`codemagic.yaml`)

Guide is a prayer-aware travel planner: it plans point-to-point routes (and multi-day
trips) and inserts mosque stops timed to prayers that fall *during* the journey, while
never inventing data — every fact carries provenance (`live` / `fixture`), every gap is
surfaced as an explicit uncertainty, and every rejected alternative is explained.

---

## 1. System architecture

```
┌─────────────────────────────┐         ┌──────────────────────────────────────┐
│  Flutter client (app/)      │  HTTP   │  FastAPI backend (backend/)          │
│  Riverpod + go_router      │ ──────► │  /v1/* JSON API                      │
│  flutter_map | Google Maps │  JSON   │  Engine: planner → solver → simulator│
│  Dio, SharedPreferences    │         │  Providers: routing/mosque/prayer/   │
└─────────────────────────────┘         │          geocode/places (env-selected)│
                                        └──────────────────────────────────────┘
                                                              │
                             OSRM · Overpass · Nominatim · AlAdhan (keyless, live)
                             Google Routes · Places (New) · Geocoding (keyed, live)
```

Hard boundary: **vendor API keys never enter the app binary.** All keyed Google calls
happen server-side. The only client-side secret surface is the optional *Maps renderer*
key (`GOOGLE_MAPS_API_KEY` in `android/secrets.properties` / `ios/Flutter/Secrets.xcconfig`,
both git-ignored), which is a display key restricted by package + SHA-1, never a web-service key.

Division of responsibility:

| Concern | Where | Notes |
|---|---|---|
| Prayer times | Backend (AlAdhan) + client fallback (AlAdhan direct) | `FallbackPrayerRepository`: backend first, direct AlAdhan only on *network* failure |
| Routing & alternatives | Backend (OSRM/Google) | client never routes |
| Mosque discovery + detour costing | Backend (Overpass/Google Places, routed matrix) | |
| Schedule optimization | Backend only (`services/scheduler.py`) | |
| Geocoding / place autocomplete | Backend (Nominatim/Google Places) | keyless mode returns real coordinates; Google mode needs a second `details` call |
| Map rendering | Client (flutter_map default, Google Maps opt-in) | compile-time `--dart-define=USE_GOOGLE_MAPS` |
| Persistence | Backend SQLite (auth, saved itineraries) + client SharedPreferences (settings, caches) | no location history stored server-side |

---

## 2. Backend (`backend/`, Python 3.12, FastAPI 0.143)

### 2.1 Layering

```
app/
├── api/          HTTP layer: schemas.py (wire contracts) + 8 route modules
├── domain/       Pure Pydantic models, no I/O: geo, prayer, mosque, route
├── services/     The engine: route_planner, prayer_sampling, candidate_eval,
│                 scheduler (DP solver), trip_planner
├── providers/    Only place that speaks HTTP to vendors; Protocols in base.py,
│                 env-driven construction in registry.py
├── core/         cache.TTLCache, timeutil.tz_at (timezonefinder, lru 4096),
│                 ratelimit (slowapi), polyline decoder
└── db/           SQLAlchemy 2.x: User, Preferences, Itinerary
```

### 2.2 API surface (all under `/v1`)

| Endpoint | Purpose |
|---|---|
| `POST /v1/prayer-times`, `GET /v1/prayer-times/capabilities` | Day prayers for a point; provider capability disclosure |
| `POST /v1/routes/alternatives` | Fastest / prayer-friendly / balanced plans |
| `POST /v1/routes/optimize` | Re-plan after an edit (same semantics, separate rate-limit intent) |
| `POST /v1/mosques/search` | Point or corridor search (~8 polyline anchors, merged/deduped) |
| `POST /v1/geocode`, `POST /v1/geocode/reverse` | Forward / reverse geocoding |
| `GET /v1/places/autocomplete`, `GET /v1/places/details` | Google Places (New) predictions + resolution; keyless Nominatim fallback |
| `POST /v1/trips/plan`, `/save`, `/saved`, `/{id}` GET/DELETE | Multi-day trips + itineraries |
| `POST /v1/community/mosques` | Community mosque submission (coords required, name optional; starts `unverified`, status absent from the schema; duplicate within 150 m + same normalized name → 409) |
| `GET /v1/community/mosques?ids=…` | Status of one's own submissions — server-issued UUIDs double as read capabilities; no list-all endpoint, no PII |
| `POST /v1/community/mosques/{id}/report` | Report an incorrect record; at `community_report_threshold` reports a verified record returns to `unverified` (drops out of routing) |
| `PATCH /v1/community/mosques/{id}/review` | Minimal moderation (verify/reject + optional name correction) via `X-Admin-Token`; 404 while `ADMIN_TOKEN` unset |
| `POST /v1/auth/register|login`, `GET/PUT /v1/me/preferences` | bcrypt + JWT HS256; anonymous mode acknowledged, never stored |
| `GET /v1/health` | status + per-slot provider report, e.g. `{"mosques": "google (live)"}` |

Provider failures surface as **HTTP 502** with detail — never masked, never replaced
with fabricated data (`providers/google_common.py: ProviderError`).

### 2.3 Planning engine (the core intellectual property)

`RoutePlanner.plan()` pipeline (`services/route_planner.py`):

1. **Routing alternatives** from the routing provider (OSRM driving alternatives, or Google).
2. **Journey prayer sampling** (`services/prayer_sampling.py`): sample points every
   ~40 km (`SAMPLE_SPACING_M = 40_000`, max 12 samples); each sample computes prayer
   times **in its own IANA zone and local date** — the departure city's times are never
   copied along the route. Midnight-crossing journeys fetch the next local day.
   `anchors_near_events()` adds corridor anchors exactly where prayers fall on the
   route (±1 polyline vertex per event), because a mosque 40 km off the anchor is the
   difference between a 2-minute and a 40-minute wait.
3. **Mosque discovery** (`services/candidate_eval.py`): Overpass/Google search within
   `CORRIDOR_RADIUS_M = 1500` of each anchor, deduped by id keeping the candidate
   closest to its anchor. Empty result → `no_data` with the explicit message that this
   *"does not confirm there are none; coverage may be incomplete."*
4. **Routed detour costing**: detour = d(anchor→mosque) + d(mosque→next anchor) −
   d(anchor→next anchor), from three batched matrix calls (batches ≤ 20, budget
   `max_matrix_elements=300`). On matrix failure, a **labelled** estimate is used:
   haversine dog-leg × 1.3 road factor, 13.9 m/s driving, method
   `great_circle_estimate`, plus an uncertainty note. Estimates are never presented as
   routed facts.
5. **Scheduling** (`services/scheduler.py`, DP solver `solve()`): layered dynamic
   program over prayer events; state = (extra time, detour) at 60 s grain; skip or
   stop per event. Hard constraints: total detour ≤ `max_detour_min` (default **25**),
   arrival ≤ prayer start + `prayer_buffer_min` (**10**), wait ≤
   `planning_window_min` (**30**); stop duration default **15** min.
   Objective: `w_detour·detour + w_wait·wait + w_missing·missed`, with profiles
   `balanced {1.0, 0.4, 20}`, `prayer_friendly {0.4, 0.25, 60}`, `strict {0.2, 0.15, 10000}`;
   `mandatory` mode raises the miss weight to ≥ strict.
   **Rejection notes are emitted in every mode** — code comment: *"Silence is not
   honesty: whenever candidates existed but were rejected, say why."*
   `_rejection_summary()` classifies each rejected candidate as `over_budget`,
   `wait_too_long`, or `too_late`, e.g. *"Dhuhr: nearby candidates existed but none
   were usable — 3 exceeded the 25 min detour limit, 1 would need more than 30 min of waiting."*
6. **Simulation & explanation**: `_simulate()` rebuilds the timeline independently of
   the solver (arrival = route time + detour + wait + stop), producing per-stop
   rationale such as *"Selected: arrival 12:06, 0.0 min after Dhuhr start; 1 min detour;
   data from google (live)."* and appending data-honesty lines
   ("Opening hours not published by the data source.").

Variants returned: **Fastest** (never stops; missed prayers listed), **Prayer-friendly**,
**Balanced** (user weights), capped at `MAX_PLANS = 5`.

`services/trip_planner.py` extends this to multi-day trips: journeys > 8 h are split
into day segments by polyline interpolation; each travel day runs the full planner;
stay days anchor a mosque stop to local Dhuhr; activities are greedily placed and
**conflicts are recorded, never silently dropped**; unbooked accommodation is marked
*"Accommodation not booked — plan only."*

### 2.4 Providers & selection

Selection is entirely environment-driven (`providers/registry.py`); nothing is
hardcoded to a country, timezone, or calculation method.

| Slot | Env var | Options (default bold) |
|---|---|---|
| Prayer | `PRAYER_PROVIDER` | **aladhan**, fixture |
| Routing | `ROUTING_PROVIDER` | **osrm**, google, fixture |
| Mosques | `MOSQUE_PROVIDER` | **osm**, google, fixture |
| Geocoding | `GEOCODING_PROVIDER` | **nominatim**, google, fixture |
| Places | `PLACES_PROVIDER` | **auto** (Google when key present), google, nominatim |
| Optimization | `OPTIMIZATION_PROVIDER` | **internal** (the DP), google (experimental stub, unwired) |

- **OSM mosques**: Overpass QL `amenity=mosque`, 8 s timeout, fallback instance list
  (kumi.systems, maps.mail.ru), preferred-instance memory, 60 s cooldown after total
  failure with an honest "coverage may be incomplete" message.
- **Google Places**: session tokens passed through (one typing+selection sequence = one
  billable session). Place Details uses an **unprefixed** field mask
  (`id,formattedAddress,location`) — the `places.*` prefix is valid only on the search
  endpoints and Google 400s it on the single-resource endpoint (bug found and fixed
  2026-10-11, commit `c0c08b7`; the previous test had asserted the buggy mask).
- **AlAdhan**: numeric method ids 1–23 (string ids silently fall back to ISNA upstream),
  uses the response's own `meta.timezone`, rejects `"-----" polar timings as errors.
- **Community layer** (`providers/mosques_community.py`): a decorator wrapping whichever
  mosque provider the environment selects (health reports e.g. `google+community (live)`).
  Only `verified` submissions join discovery by default; `COMMUNITY_INCLUDE_UNVERIFIED=true`
  is a labelled operator opt-in. Community records carry `provider: community` with
  explicit provenance notes, dedup against external results by 150 m + normalized name
  (external wins; proximity never implies verification), and any database error returns
  the primary provider's results untouched. New env vars: `COMMUNITY_MOSQUES_ENABLED`
  (default true), `COMMUNITY_INCLUDE_UNVERIFIED` (false), `COMMUNITY_REPORT_THRESHOLD`
  (3), `ADMIN_TOKEN` (empty = moderation off). Data model: `community_mosques` table
  (uuid, nullable name, lat/lon, address, opening_hours, server-assigned
  `unverified|verified|rejected`, optional `submitted_by`, report counters/JSON audit
  trail, timestamps) added non-destructively via `create_all`.

### 2.5 Time handling

Every prayer instant is carried as **aware UTC datetime + IANA zone string + naive local
wall time + `local_date`** (`domain/prayer.py`). Display uses the local zone; comparisons
use UTC. `core/timeutil.py::tz_at()` resolves zones offline via timezonefinder (lru 4096),
with `"UTC"` only as a last resort. `/v1/prayer-times` converts a UTC instant to the
**location's** local calendar date server-side, so day boundaries follow the destination,
not the caller. Tests cover DST spring-forward (Paris 2025-03-30), the date line
(Kiritimati UTC+14), and midnight-crossing journeys.

### 2.6 Caching & resilience

- `core/cache.py::TTLCache`: bounded (2048 entries), deduplicates concurrent identical
  requests via per-key `asyncio.Lock`.
- Route cache TTL 900 s; prayer cache TTL 21 600 s. Nominatim/Overpass/Places
  autocomplete are deliberately **uncached** (upstream fair-use policy).
- Google cache keys are canonical `json.dumps(body, sort_keys=True)` — a raw dict key
  is unhashable and crashed the first live call with a 500 (fixed, regression-tested).
- Graceful degradation ladder: matrix failure → labelled estimate; mosque provider
  failure → mosque-free plans *with explanation*; per-section prayer failure → visible
  note; total provider failure → 502. A failed plan is always explained, never faked.

### 2.7 Data honesty (cross-cutting invariant)

- Every payload carries provenance: `RouteResult.live`, `DayPrayers.source/live`,
  `MosqueCandidate.data_quality` (`provider`, `source`, `fetched_at`, `notes`),
  `MosqueSearchResult.status ∈ ok|no_data|provider_error|fixture`.
- Per-field verification on mosques: `Verification ∈ verified|unverified|unknown|absent`;
  `congregation_verified` defaults False and **nothing in the codebase ever sets it true** —
  iqama times are never inferred from calculation.
- Fixtures self-label end-to-end: `"Dev Mosque N (fixture)"`, response-level notes
  (`"MOSQUE FIXTURE ACTIVE…"`), provider report `osm (FIXTURE)`.
- Absence of data ≠ verified absence: `no_data` responses say so explicitly.
- Unnamed mosques render as `"Unnamed mosque (lat, lon)"` — never a fabricated name.

### 2.8 Tests — 81 passing

| File | Tests | Focus |
|---|---|---|
| `test_api.py` | 10 | endpoint contracts, fixture labeling, auth round-trip |
| `test_prayer_scheduling.py` | 10 | solver constraints: detour budget, wait window, buffer, budget coupling |
| `test_candidate_selection.py` | 10 | discovery, dedup, routed detours, **rejection notes in optional mode**, fixture preservation |
| `test_places.py` | 10 | Google stubs, **unprefixed details mask regression**, sorted-JSON cache-key regression |
| `test_route_feasibility.py` | 7 | metrics self-consistency, alternatives, uncertainty propagation |
| `test_reschedule.py` | 6 | departure shifts, mode suppression, cross-region zones |
| `test_timezones.py` | 6 | DST, date line, midnight crossing, per-sample zones |
| `test_community_mosques.py` | 22 | **submission validation (422s), client-can't-set-status, 409 duplicate detection, id-capability lookup, report→demotion, admin review gating (404/403), rejected-record invisibility, discovery integration with provenance, unverified excluded by default + opt-in, hours always unverified, dedup vs fixture, community-failure isolation, health label** |

`tests/conftest.py` pins all providers to `fixture` and sets `GOOGLE_MAPS_API_KEY=""`
**before app import**, so a developer's real `backend/.env` can never leak into tests.

### 2.9 Dependencies (installed)

fastapi 0.143 · uvicorn 0.54 · pydantic 2.14 · pydantic-settings 2.15 · httpx 0.28 ·
SQLAlchemy 2.1 · PyJWT 2.15 · bcrypt 5.0 · slowapi 0.1.10 · timezonefinder 9.0 (+tzdata
2026.5) · email-validator 2.3 · pytest 9.1 + pytest-asyncio 1.4 (dev).

---

## 3. Flutter client (`app/`, Flutter 3.47.7, Dart ^3.13.5)

### 3.1 Layering

```
lib/
├── app/           app.dart (MaterialApp.router), router.dart (go_router), theme.dart
├── application/   Riverpod controllers: planner.dart, settings.dart, trips.dart
├── domain/        models.dart (~870 lines, hand-written fromJson/toJson),
│                  repositories.dart (Failure/FailureKind + 4 interfaces)
├── data/          api_client.dart (Dio), api_repositories.dart, local_store.dart,
│                  aladhan_service.dart + aladhan_prayer_repository.dart,
│                  fallback_prayer_repository.dart, mock_repositories.dart
├── core/          format.dart, map_engine.dart (compile-time renderer switch)
├── l10n/          app_{en,ar,fr}.arb (156 keys, full parity) + generated (checked in)
└── presentation/  screens/ (6) + widgets/ (AdaptiveMap, PlaceField, honesty widgets)
```

`domain/` imports no Flutter — entities and repository interfaces are pure Dart.

### 3.2 State management (Riverpod 3.4)

Single switch point: `repositoriesProvider` (settings.dart) returns either the `Api*`
repository set (production; prayer wrapped in `FallbackPrayerRepository`) or the `Mock*`
set (`fixtureMode: true`, demo mode). Other key providers: `settingsProvider` (15-field
immutable `AppSettings`, JSON-persisted), `routeProvider` (`AsyncNotifierProvider`),
`prayerTimesProvider` + `prayerDayTickerProvider` (a 30 s ticker that only re-fetches at
UTC **day** change — no per-second network polling), `tripResultProvider`.
Geocoding deliberately has no global provider: it lives inside `PlaceField` with a
350 ms debounce and a monotonic sequence counter that drops stale in-flight responses.

### 3.3 Routing (go_router 18)

Global `goRouter`: `/` Home · `/route` comparison · `/route/journey?plan=n` journey ·
`/trip` multi-day · `/settings` · `/mosque` details (via `extra`). All navigation state
lives in Riverpod, not the router — a refresh of `/route/journey` legitimately shows
"no results".

### 3.4 Screens & features

1. **Home** — full-bleed map, floating search card (From/To `PlaceField`, swap, plan),
   draggable sheet: waypoints, departure (leave now / picker → `.toUtc()`), travel mode,
   preference & prayer-stop policy, 4 advanced sliders (detour 5–90, stop 5–60, window
   10–120, buffer 0–30), and a live prayer card (next-prayer countdown, all five
   prayers, source badge, cached-copy indicator, automatic next-day rollover).
2. **Route comparison** — one card per alternative: metrics, detour chip, served/missed
   ratio, "Why this route" explanation, uncertainties; infeasible plans are flagged and
   cannot be selected.
3. **Journey** — route polyline + mosque markers, stop timeline with arrive/depart/
   prayer/rationale; mosque stops deep-link to details. Includes an optional
   **"Navigate with Google Maps"** handoff (`core/google_maps_export.dart`): the
   selected plan's own stops are exported in order to a
   `https://www.google.com/maps/dir/?api=1…` URL (app first, browser fallback via
   `LaunchMode.externalApplication`). Journeys with more intermediate stops than the
   conservative 9-waypoint cap are split into sequential legs — every stop preserved,
   none reordered or dropped — with an explanatory per-leg sheet. Launch success is
   claimed only when `launchUrl` actually returns true; Guide's planner state is never
   mutated, and the UI notes that Google Maps may recalculate its own route.
4. **Mosque details** — verification-aware rendering: opening hours at their actual
   verification level; iqama only when `congregationVerified`; `tel:`/website via
   url_launcher; "Open in maps" via `geo:` URI; detour chip marked `≈` when estimated.
   Community-sourced records additionally show a "Report incorrect information" action.
5. **Trip planner** — days 1–21, activities with optional time windows, pace slider,
   overnight policy; conflicts shown as chips, never dropped.
6. **Settings** — locale/theme/clock/units; prayer source (auto/backend/aladhan);
   **capabilities-driven** prayer section (only shows method/school/high-latitude/adjust
   controls the active provider supports); demo mode; backend URL override; a
   **Community** section with "Suggest a missing mosque" (disabled in demo mode with an
   honest note — submissions need the real backend).
7. **Community submission screen** (`/community/mosque`, from Settings only — no new
   nav tab): location via search (`PlaceField`), device fix, or map tap; optional
   name/address/opening-hours fields with "unverified" helper text; unnamed mosques are
   valid (coordinates are what matters). Server-side duplicate 409 is surfaced verbatim;
   success shows the pending-review status; "My submissions" lists this device's stored
   ids with their live server-side status (unverified/verified) — ids live in local
   prefs, no account required.

Cross-cutting honesty widgets (`presentation/widgets/common.dart`): `FixtureBanner`
(amber, demo or any FIXTURE provider), `StaleBanner` (cached data + fetch time),
`SourceBadge` (live vs fixture), `ErrorCard` (message + retry).

### 3.5 Localization & RTL

gen-l10n with `en`/`ar`/`fr`, 191 keys each, verified full key parity (now
test-enforced by `test/l10n_parity_test.dart`); generated files checked in.
Locale is user-selectable. RTL is **implicit** — no `Directionality`
overrides anywhere; Arabic works through Flutter's default bidi. One caveat: the client
has no explicit RTL audit, so hardcoded-direction assumptions could only exist in
asymmetric paddings (current ones are symmetric).

### 3.6 Time handling in the client

No `timezone` package — deliberately. Instants are UTC end-to-end; local wall time is an
opaque naive `DateTime`; the IANA zone is carried as a string. `aladhan_service.dart`
parses offset-bearing ISO strings with a hand-written regex and computes
`utc = DateTime.utc(wall…).subtract(offset)` — a comment explains that
`DateTime.parse` would normalize into the *device's* zone, "exactly the timezone lie
this app must never make". A timing without an offset is a `Failure`, not a guess.
Countdowns are pure instant math against `DateTime.now().toUtc()`. Known soft spot:
mosque iqama display uses `toLocal()` (device zone rather than the mosque's).

### 3.7 Maps

`core/map_engine.dart`: `const bool useGoogleMaps = bool.fromEnvironment('USE_GOOGLE_MAPS')`
— compile-time, tree-shaken. `AdaptiveMap` gives both renderers feature parity (gestures,
shared controls, markers, polyline, camera refit only on actual point change). The OSM
build is honestly labeled *"OpenStreetMap preview — set the Google Maps key to use
Google Maps"* on the map and in the search card. Secrets load from
`secrets.properties` / `Secrets.xcconfig` (both git-ignored, examples committed), with
an env-var fallback; the iOS xcconfig include is optional so keyless builds work.

### 3.8 Backend communication & client caching

`GuideApi` (Dio 5.11, 25 s timeouts) maps every `DioException` to a typed
`Failure(kind: network|server)` reading FastAPI `detail` bodies. `BACKEND_URL` is a
dart-define (default `http://10.0.2.2:8000` — emulator loopback) and runtime-editable
in Settings. Every repository caches successful responses under a canonical sorted-JSON
`cacheKey()` as `{fetched_at, body}` in SharedPreferences; on **network-only** failure
the last cached body is served with `stale: true` (→ `StaleBanner`). Server/validation
errors are rethrown. Demo mode is the only synthetic data path and is labeled everywhere.

### 3.9 Tests — 57 passing (`flutter test`)

`widget_test` (3: home, fixture banner, sheet-shrink on field focus), `place_field_test`
(10: debounce, details resolution, stale-response dropping, retry, coordinate input),
`models_test` (5: wire contract mirrors `backend/app/api/schemas.py`, honesty metadata),
`aladhan_service_test` (13: UTC/naive parsing incl. negative offsets, polar `-----`
rejection, day correction via fake adapter), `aladhan_prayer_repository_test` (4:
caching, stale-serving), `google_maps_export_test` (11: endpoint extraction, stop
order, no-stops case, waypoint-cap leg-splitting (incl. cap=1 stress) proving every
stop survives in order with a continuous chain, null on missing coordinates, leg-endpoint
fallback, canonical URL shape, pipe-encoded waypoints, travel-mode mapping incl.
cycling→bicycling, coordinate round-trip), `community_mosque_test` (8: record parsing,
unnamed label, mocked-transport repo contract — no `status` ever sent, blank-field
omission, `community-` prefix stripping on ids/report, empty-id no-op, 409 → typed
`Failure`), `l10n_parity_test` (3: ARB existence, exact en/ar/fr key-set equality,
presence of all 35 new feature keys). No tests yet for route/trip repositories, other
screens, or settings persistence.

### 3.10 Dependencies

flutter_riverpod 3.4.3 · go_router 18.0.2 · dio 5.11.1 · flutter_map 8.3.2 ·
google_maps_flutter 2.18.2 · latlong2 0.10.1 · shared_preferences 2.5.6 · intl 0.20.3 ·
geolocator 14.1.1 · url_launcher 6.3.3 · flutter_lints 6.0.
Android: JVM 17, AGP 9.1.0, Kotlin 2.4.0, Gradle 9.3.1, appId `com.guide.guide`,
permissions INTERNET + COARSE/FINE location. iOS: bundle `com.guide.guide`,
location-usage string with an honest privacy sentence.

---

## 4. DevOps

- **CI** (`codemagic.yaml`): one workflow `ios-testflight` on `mac_mini_m2`, Flutter
  pinned **3.47.7** (matches local), `flutter test` gate, auto-signing via App Store
  Connect API, TestFlight **internal-testing-only** export. `app_id` is a placeholder
  and `BACKEND_URL` is baked at build time (currently a laptop hotspot IP) — both must
  be maintained. CI builds use the OSM renderer (no maps key in CI).
- **Backend runtime**: `uvicorn app.main:app` from `backend/` (so `.env` loads);
  `backend/.env` holds exactly one secret (`GOOGLE_MAPS_API_KEY`, git-ignored;
  `.env.example` documents the rest). CORS and slowapi rate limiting
  (`rate_limit_per_minute=60`) configured in `main.py`.
- **Docs**: `docs/ARCHITECTURE.md`, `docs/SETUP.md`, `docs/PROVIDERS.md` exist.

## 5. Verification status (as of 2026-10-12)

Verified live, end-to-end **in the Android emulator** with the real Google key:
autocomplete predictions → prediction selection → Place Details resolution → map
recenter to real coordinates; live prayer card (`mwl`, "Live data"); full planning flow
(Manouba→Rades, depart 12:00, prayer-friendly + mandatory) returning a real Google
mosque stop — *Mosquée Al Salam, arrive 12:06 = Dhuhr 12:06, 1 min detour* — with the
fastest alternative honestly stating *"Prayers not stopped for: Dhuhr"*; journey
timeline with provenance "data from google (live)" and explicit unknown-hours caveats.

Community submissions verified live against the running backend (Google mosque
provider): submit → `unverified` · id lookup · duplicate 409 · admin review via
`X-Admin-Token` → `verified` · the verified record appearing in `/v1/mosques/search`
with `provider: community`, explicit provenance notes and `opening_hours_verification:
unverified` · a full prayer-aware plan (3 alternatives, prayer-friendly + balanced with
a real mosque stop) with the community layer active (`google+community (live)`) and
Google's nearer candidate correctly winning dedup. The smoke-test record was deleted
from the dev database afterwards.

The Google Maps export is verified by unit tests (URL shape, order preservation,
leg-splitting); the actual `maps/dir` handoff **launch itself was not exercised on a
device** in this pass — `launchUrl` success-honesty is coded and covered at the logic
level, but on-device app-opens-browser behavior deserves a manual check.

Not verified: physical iPhone (blocked on Apple/Codemantic account setup —
`app_id` placeholder in `codemagic.yaml`); Google Maps *client* renderer (only the OSM
preview has been exercised; no client maps key provisioned); physical Android device
(A06 unreachable on the current network); moderation UI (none exists — the token-guarded
`PATCH …/review` endpoint is the documented minimal path).

## 6. Known issues, debt, and doc mismatches (honest list)

1. **iOS release signing**: Android release build currently signs with debug keys
   (template TODO).
2. **`NSAppTransportSecurity → NSAllowsArbitraryLoads = true`** in `Info.plist` —
   development convenience for the plain-HTTP LAN backend; must be removed for production.
3. **Saved trips are write-only on the client**: `saved_trips:` keys are written but
   never read back (no list/resume UI), though backend `/v1/trips/saved` works. The
   `SavedItinerary` model is unused client-side.
4. **Prayer-stop reminders**: the Settings switch saves the preference but no
   notification plugin is installed; the UI says so honestly.
5. **`flutter_secure_storage` is a declared but unused dependency**; prefs are plain
   SharedPreferences.
6. **`docs/ARCHITECTURE.md` drift**: describes a `trip_days` table (trips are a JSON
   blob in `itineraries`), a `PrayerWindow` entity (doesn't exist), a greedy-insertion
   pass for user-forced stops (unimplemented), `backtracking`/`schedule_conflict_penalty`
   objective terms (the DP objective is detour + waiting + missing only), and a
   `/v1/optimize` path (actual: `/v1/routes/optimize`). Code is the source of truth.
7. **`optimize_google.py` is an unwired experimental stub**; only the internal DP runs.
8. **Public keyless upstreams** (OSRM demo, Overpass, Nominatim) have no SLA and
   fair-use policies; Overpass was globally degraded during development — the Google
   mosque provider is the mitigation, OSM remains fallback.
9. **`cacheKey()` canonicalizes only top-level key order** — nested `config` relies on
   fixed insertion order; works, but subtle.
10. **Client RTL is implicit, not audited**; iqama display uses device-local time.
11. **`google_maps_flutter ^2.12.1` resolves to 2.18.2** — a wide caret that could drift.
12. Unused l10n keys (10) and the untouched Flutter-template `README.md`.
13. "Phase 0" is a planning-milestone name used in commit messages, not a code symbol —
    the optimizer is `services/scheduler.py`.
14. **Community moderation is endpoint-only**: `PATCH /v1/community/mosques/{id}/review`
    with `X-Admin-Token` is the entire moderation surface — no admin UI, no accounts
    with roles, no per-user report de-duplication (one device can report repeatedly; the
    demotion threshold counts raw reports). Acceptable minimal path, documented as the
    follow-up target in `docs/PROVIDERS.md`.
15. **Community duplicate detection is bbox+haversine in Python** — fine at SQLite
    community scale, but a geospatial index (PostGIS) would be the production upgrade
    if submissions grow.
16. **The Google Maps multi-leg handoff requires the user to return to Guide between
    legs** — sequential URLs cannot chain automatically once Google Maps has the route;
    the UI explains this explicitly rather than pretending otherwise.

## 7. Repository state

All prior work is on `main` (latest before this feature pass: `c0c08b7`, the Place
Details field-mask fix). This pass adds community mosque submissions (backend +
client) and the Google Maps journey export; it is committed on top. Backend suite
81/81 green; Flutter suite 57/57 green; `dart analyze lib test` clean. Whole-repo
`dart format` deliberately not run (repo style predates the current formatter — only
semantic edits are committed). The user's local `app/run_phone.ps1` remains
untracked-by-choice (a personal helper, not part of the deliverable).
