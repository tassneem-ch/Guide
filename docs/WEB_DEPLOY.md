# Web version

The `web-version` branch adds **Flutter Web** support to the existing app. It
reuses the same codebase, backend, providers, and design — there is no web
rewrite, no redesign, and no second app. The mobile (Android/iOS) targets are
untouched and still build.

- Branch: `web-version` (mobile stays on `main`)
- Map renderer on web: the **keyless OpenStreetMap** engine (`flutter_map`).
  No Google Maps key is required, and no map provider or code path changed.
- Backend: the **same** FastAPI service the phone app uses.

---

## 1. Run it locally

### Option A — dev server (fastest)

```powershell
cd backend
.\.venv\Scripts\uvicorn app.main:app --reload          # API on :8000

cd ..\app
flutter run -d chrome --dart-define=BACKEND_URL=http://localhost:8000
```

> On web the app already defaults to `http://localhost:8000`, so the
> `--dart-define` is optional locally. Pass it only if your API runs elsewhere.

### Option B — release build (what you would deploy)

```powershell
cd app
flutter build web --release
python tool\serve_web.py 8081     # static server + SPA fallback on :8081
```

Open <http://localhost:8081>.

> **Port note:** `tool/serve_web.py` defaults to **8081**, not 8080, because
> 8080 is commonly occupied (e.g. by Tomcat). Pass another port as an argument
> if needed: `python tool\serve_web.py 9000`.

### URL strategy (deep links & refresh)

Flutter Web uses the **hash** URL strategy by default, so routes look like:

```
http://localhost:8081/#/
http://localhost:8081/#/route
http://localhost:8081/#/trip
http://localhost:8081/#/settings
http://localhost:8081/#/mosque
http://localhost:8081/#/community/mosque
```

Because everything after `#` stays in the browser, **refresh and direct links
work on any static host with no server configuration at all.** The SPA fallback
in `tool/serve_web.py` (and the rewrite rule below) additionally keeps things
working if you later opt into the prettier *path* strategy by calling
`usePathUrlStrategy()` (from `flutter_web_plugins`) in `app/lib/main.dart`.

---

## 2. Deploy

The web app and the API are **two separate deployments** — the browser talks to
the API over HTTPS. (Exception: **Vercel can host both in one project** — see
§2.5, which is what this repo is currently deployed with.)

| Piece | What it is | Where to host |
| --- | --- | --- |
| Web app | static files from `app/build/web` | Firebase Hosting, Netlify, Cloudflare Pages, GitHub Pages, Azure Static Web Apps, S3 + CloudFront |
| Backend | FastAPI + Python 3.12 | Railway, Render, Fly.io, Cloud Run, Azure App Service, any VPS |

Any static host works; the ones above all serve HTTPS and support SPA rewrites.

### 2.1 Build with the real API URL

The web default is `localhost:8000`, which only exists on your machine. Point a
release build at the deployed API:

```powershell
cd app
flutter build web --release --dart-define=BACKEND_URL=https://api.example.com
```

`BACKEND_URL` is a **public endpoint address, not a secret** — provider API keys
never enter the app (see §4).

### 2.2 SPA rewrite rule

Only needed if you switch to the path strategy. Equivalent of
`tool/serve_web.py`'s fallback — serve real files, else return `index.html`:

- **Netlify** — `public/_redirects`:
  `/*  /index.html  200`
- **Firebase Hosting** — `firebase.json`:
  ```json
  { "hosting": {
      "public": "build/web",
      "rewrites": [ { "source": "**", "destination": "/index.html" } ]
  } }
  ```
- **Nginx** — `try_files $uri $uri/ /index.html;`
- **Cloudflare Pages / GitHub Pages** — use a 404 → `index.html` rule, or stay on
  the hash strategy and skip this entirely.

### 2.3 Tell the API to allow your web origin (CORS)

Browsers enforce CORS. The API only accepts requests from origins listed in
`CORS_ORIGINS` (comma-separated). Localhost dev origins are already included by
default; for production, set the env var on the backend host:

```powershell
# example
$env:CORS_ORIGINS = "https://www.example.com,https://example.com"
.\.venv\Scripts\uvicorn app.main:app
```

If you skip this, the app loads but every API call is blocked by the browser.

### 2.4 HTTPS

Serve the web app over HTTPS. Beyond being standard for production, browsers
only expose the **Geolocation API** ("Use my location") and other
powerful features in a **secure context** — that means HTTPS, or `localhost`
during development. Plain-HTTP hosting would silently break location features.

### 2.5 Vercel — one project for both (what this repo ships)

**Live:** <https://guide-app-omega.vercel.app>

A single Vercel project (`guide-app`) serves the Flutter build from the CDN
**and** runs the FastAPI app as one Vercel Function. Frontend and API share one
origin, so §2.3's CORS configuration is unnecessary there — no cross-origin
request ever happens.

| Repo file | Role |
| --- | --- |
| `main.py` (root) | Vercel entrypoint; re-exports `backend.app.main:app` (the same instance `uvicorn app.main:app` runs locally) |
| `requirements.txt` (root) | flat copy of `backend/requirements.txt` — Vercel's parser rejects `-r` includes, keep the two in sync |
| `vercel.json` | `functions["main.py"].maxDuration = 60` |
| `.vercelignore` | keeps `backend/.env` (server-side key), `*.db`, and Flutter sources out of the upload; **`public/` must never be listed** |
| `backend/__init__.py` | makes `backend.app.main` a deterministic import for the entrypoint |
| `public/` | the Flutter release build — git-ignored, copied in before each deploy |

Environment variables (project settings — never in the repo):

- `DATABASE_URL=sqlite:////tmp/guide.db` — Vercel's filesystem is read-only
  outside `/tmp`; `init_db()` only runs `create_all`, so this needed **zero
  code changes**.
- `JWT_SECRET` — a random value (auth is optional by default; this keeps
  issued tokens unforgeable versus the repo's placeholder).

Redeploy (Vercel CLI, authenticated with `vercel login`):

```powershell
cd app
flutter build web --release --dart-define=BACKEND_URL=https://guide-app-omega.vercel.app
cd ..
New-Item -ItemType Directory -Path public -ErrorAction SilentlyContinue
Copy-Item app\build\web\* public\ -Recurse -Force
vercel deploy --prod --yes
```

> **The GitHub integration is deliberately disconnected.** A Git-connected
> build would deploy *without* `public/` (it is git-ignored and Flutter is not
> built on Vercel), silently replacing the working site with a frontend-less
> one. Deploys go through the CLI command above; `vercel git connect` should
> only be re-enabled alongside a CI step that builds Flutter.

Vercel-specific caveats:

- **`/tmp` data is ephemeral** — saved trips, community submissions, and
  registered users vanish on redeploy and on cold starts of a fresh instance.
  Fine for testing; point `DATABASE_URL` at a real Postgres before anyone
  relies on the data.
- **Function timeout** is 60 s (`vercel.json`); every provider client timeout
  (AlAdhan 15 s, etc.) sits well inside it.
- **Mosque discovery depends on the public Overpass instances**, which were
  globally unavailable at deploy time (502/504/timeouts from four probe
  countries). The API answers its honest `status: no_data` message — "mosque
  data could not be checked" — never a fake-empty list. Re-run
  `POST /v1/mosques/search` once the instances recover.

---

## 3. What changed (small on purpose)

| File | Change |
| --- | --- |
| `app/web/` | generated by `flutter create --platforms web`; branded title + teal manifest. Android/iOS files untouched. |
| `app/lib/application/settings.dart` | `kDefaultBackendUrl` becomes `localhost:8000` when `kIsWeb`, still `const`. Mobile keeps `10.0.2.2`. |
| `app/lib/app/app.dart` | wide windows center a phone-width (560px) column; ≤560px is the unchanged mobile layout |
| `backend/app/config.py` | `cors_origins` default adds common local web dev origins |
| `app/tool/serve_web.py` | local static server with SPA fallback (not part of the bundle) |
| `app/analysis_options.yaml`, `app/.metadata` | exclude `web/**` from analysis; record the web platform |

**No new dependencies.** `pubspec.lock` still lists the same 129 packages
(only transitive version bumps).

---

## 4. Security

- The web bundle was scanned after a release build: **no API keys, tokens, or
  private keys** are present. Provider keys (AlAdhan, Google Maps, etc.) live
  only in the backend's `.env`, which is git-ignored.
- `--dart-define=BACKEND_URL` is a public address by design.
- `flutter_secure_storage` stays declared for mobile use; on web, anything
  sensitive still belongs server-side.

---

## 5. Verified on web (release build, headless Chrome)

| Check | Result |
| --- | --- |
| `flutter build web --release` | succeeded |
| Home screen (map, sheet, card, swap, Plan route) | renders identically to mobile |
| `/#/settings` deep link + refresh | renders Settings (Appearance, prayer source, method, adjustments, provider status) |
| `/#/community/mosque` deep link | renders submission form; submit correctly disabled until a location is set |
| `/#/trip` deep link | renders trip planner (days, overnight, activity slider) |
| API calls from the browser (CORS) | succeed — Settings showed live "Prayer provider: aladhan" |
| Desktop window (1280px) | app centered in a phone-width column, not stretched |
| Narrow window (480px) | full-bleed mobile layout, nothing clipped |
| `flutter analyze lib` | no issues |
| `flutter test` | 57/57 passed |
| `backend pytest` | 83/83 passed (2 prayer-502 regression tests added) |
| `flutter build apk --debug` | succeeded (mobile unaffected) |

### 5.1 Deployed on Vercel (2026-11-02)

| Check | Result |
| --- | --- |
| `GET /` + `main.dart.js` + canvaskit over HTTPS | 200, correct types, publicly reachable (no auth wall) |
| App boots in a real browser | renders Plan-a-journey card, map area, bottom sheet; **0 console errors** |
| In-app `GET /v1/prayer-times/capabilities` | **200** (the deployed bundle calling the deployed API) |
| In-app places autocomplete (`?q=Riyadh`) | 200 — suggestions rendered |
| In-app `POST /v1/prayer-times` after picking a location | **200** — card rendered "Today's prayers … ⚡ Live data", Riyadh times for 2026-11-02, method `mwl`, working next-prayer countdown |
| `POST /v1/prayer-times` direct (AlAdhan from Vercel) | 200, `source: aladhan, live: true` — the local machine's blocked network does not affect Vercel |
| `POST /v1/routes/alternatives` (OSRM) | 200 live |
| `POST /v1/geocode` (Nominatim) | 200 live |
| `GET /v1/health` | 200 — all providers report live modes |
| `POST /v1/mosques/search` (Overpass) | honest `status: no_data` — all public Overpass instances were down globally at the time (502/504/timeouts from NL/UA/US/VN/CA/RU probes), not a Vercel or app fault |
| OSM map tiles | could not be verified **live** from this machine (the local hotspot MTU issue blocks `tile.openstreetmap.org`; the interactive browser's tiles came from its cache). On a normal network they are plain HTTPS requests from the client to OSM. |

---

## 6. Known limitations

- **iOS build not re-verified** on this Windows machine (no Xcode). The web
  changes do not touch `ios/`, and the Android build passes, but an iOS build
  should be re-run on a Mac before a store release.
- **Physical-device web testing** was not performed; verification used a
  desktop browser (the deployed URL is ready for other devices to open).
- **Browser geolocation** needs HTTPS in production (§2.4).
- Google Maps' client renderer is not used on web — the web app renders the
  keyless OpenStreetMap layer, and "Navigate with Google Maps" still hands off
  to the real Google Maps app/plans page as on mobile.
- **Vercel deployment state** (§2.5): database is ephemeral `/tmp` SQLite;
  mosque discovery waits on the public Overpass instances to recover; Git-based
  deploys are intentionally off (CLI only).
