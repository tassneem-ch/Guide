# Guide

A travel planner that works around your prayer times. Plan a real route,
see which mosques you can stop at along the way, and get an honest answer
about how each option treats your prayers — including when the answer is
"not well."

Built with Flutter (Android and iOS from one codebase) and a FastAPI
backend. Works worldwide: no hardcoded country, timezone, language, or
calculation method — just UTC instants and local IANA timezones. Available
in English, Arabic (right-to-left), and French.

## What you get

- **Route planning with prayer awareness.** Three alternatives with
  distance, duration, and arrival time, plus a plain-language explanation
  of why each route is what it is.
- **Mosque discovery along the way.** Named mosques with opening hours and
  phone numbers when the provider has them, and clearly marked gaps when
  it doesn't.
- **Community submissions.** Know a mosque the maps are missing? Submit it
  from Settings → Community. It stays out of route planning until a
  moderator verifies it, and the app says so at every step.
- **Hand off to Google Maps.** One tap on the journey screen sends your
  planned route — origin, stops in order, destination — to Google Maps.
  Google recalculates its own timings; Guide's prayer plan stays put.
- **Multi-day trips.** Activities, overnight stays, and surfaced conflicts
  when the plan doesn't add up.
- **Settings that respect the source.** Language, theme, time format,
  units, and the prayer calculation method the backend actually exposes.

## What it won't do

Every screen carries provenance, because a planner that invents data is
worse than one that admits what it doesn't know:

- Development fixtures are labeled as such — a persistent banner in the UI,
  `source: fixture` in the data. Demo mode runs fully offline and is
  obviously marked.
- Mosque names, hours, and phone numbers come from the data provider or
  from nowhere. Missing stays missing: `no_data` doesn't mean "no mosques."
- Congregation (iqama) times only appear when a provider supplied them.
  Otherwise the UI explains why they're absent instead of guessing.
- Uncertainty gets surfaced: estimated detours versus actually-routed ones,
  stale cached responses, and plans that don't quite work.

## Screens

A full-screen map (Google Maps when a key is configured, labeled
OpenStreetMap preview otherwise) with a floating search card and a
draggable sheet:

| Screen | What it does |
|--------|--------------|
| **Home** | Plan a route, see today's prayers |
| **Route comparison** | 3 alternatives, each with its reasoning |
| **Journey details** | Stop timeline on the map, Google Maps handoff |
| **Mosque details** | Hours, phone, provenance |
| **Trip planner** | Multi-day itineraries with activities and stays |
| **Settings** | Prayer methods, language, theme, backend URL, community submissions |

## Repository layout

| Path | Contents |
|------|----------|
| `backend/` | FastAPI app, provider adapters, scheduling engine, 81 tests |
| `app/` | Flutter client, l10n (en/ar/fr), widget tests |
| `docs/` | [Architecture](docs/ARCHITECTURE.md) · [Setup](docs/SETUP.md) · [Providers](docs/PROVIDERS.md) |

## Quick start

Backend (Python 3.12):

```powershell
cd backend
python -m venv .venv
.\.venv\Scripts\pip install -r requirements.txt
Copy-Item .env.example .env   # defaults work for keyless dev providers
.\.venv\Scripts\uvicorn app.main:app --reload
```

App (Flutter 3.47+):

```powershell
cd app
flutter pub get
flutter run --dart-define=BACKEND_URL=http://10.0.2.2:8000   # Android emulator
```

No API keys needed to develop: the backend defaults to AlAdhan (prayers),
OSRM (routing), OpenStreetMap/Overpass (mosques), and Nominatim
(geocoding). Keys live only on the server, never in the app — see
[docs/PROVIDERS.md](docs/PROVIDERS.md) for quotas, costs, and switching to
Google providers.

### Google Maps (optional, recommended for release)

Without a key the map falls back to a clearly labeled OpenStreetMap view,
so the app always works. To use Google Maps:

1. In a **billing-enabled** Google Cloud project, create an API key with
   **Maps SDK for Android** and **Maps SDK for iOS** enabled.
2. Restrict it: Android → package `com.guide.guide` + your signing key's
   SHA-1; iOS → bundle id `com.guide.app`.
3. Keep it local (git-ignored, never committed):
   - Android: copy `app/android/Secrets.properties.example` →
     `app/android/secrets.properties` and set `GOOGLE_MAPS_API_KEY`.
   - iOS: copy `app/ios/Flutter/Secrets.xcconfig.example` →
     `app/ios/Flutter/Secrets.xcconfig` and set `GMSS_MAPS_KEY`.
4. Build with the Google engine selected:

```powershell
flutter run --dart-define=BACKEND_URL=http://10.0.2.2:8000 --dart-define=USE_GOOGLE_MAPS=true
```

## Tests

```powershell
# backend — offline, fixture providers
cd backend; Remove-Item guide_test.db -ErrorAction SilentlyContinue
.\.venv\Scripts\python.exe -m pytest -q        # 81 passed

# app
cd app; flutter analyze                         # No issues found
flutter test                                    # 57 passed
```

## Known limitations

Being honest about these is the whole point of the project, so:

- **Notifications aren't wired up.** The "prayer stop reminders" toggle is
  saved, but on-device scheduling isn't implemented — the UI says so.
- **Google Route Optimization is experimental** and marked unverified. The
  internal solver is the default.
- **Trips are local-only in the MVP.** The backend supports authenticated
  persistence when `AUTH_REQUIRED=true`, but the app stores trips on the
  device for now.
- **Verified on emulators and tests, not physical hardware.** The
  Google Maps handoff and community flows have been exercised end-to-end on
  an Android emulator; iOS and physical-device testing are still pending.
