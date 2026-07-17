# Tech Stack

> **Purpose**: Authoritative list of all technologies, libraries, frameworks, and services used in this project. Agents must not introduce new dependencies without updating this document and justifying the addition.
> **Update when**: A dependency is added, upgraded, or removed.

---

## Frontend / Mobile

| Technology | Version | Purpose | Notes |
|------------|---------|---------|-------|
| Flutter | SDK `>=3.3.0 <4.0.0` | UI framework, Android + Web targets | Package name is `beaty`; brand is Paax |
| Dart | 3.x | App language | Sound null safety |
| Provider | ^6.1.5 | State management (`ChangeNotifier`) | **Not** Riverpod/Bloc — see [frontend/state-management.md](frontend/state-management.md) |
| Hive + hive_flutter | ^2.2.3 / ^1.1.0 | Local persistence (the app's only datastore) | Typed adapters via `hive_generator` — see [database.md](database.md) |

Targets: **Android** (native APK/AAB) and **Web** (deployed as PWA/TWA at `paaxmusic.app`). No iOS build is produced today (the `ios/` folder exists but is not part of the release pipeline).

---

## Backend / API

| Technology | Version | Purpose | Notes |
|------------|---------|---------|-------|
| Python | 3.11 | Backend language (all 3 services) | — |
| FastAPI | 0.115.0 | REST framework for `paax-api`, `paax-stream`, legacy `backend` | Async |
| Uvicorn | 0.30.6 (`[standard]`) | ASGI server | Start via Railway/Procfile |
| ytmusicapi | 1.7.4 | YouTube Music metadata (v1 endpoints + lyrics fallback) | `paax-api`, legacy `backend` |
| yt-dlp | ≥2024.1.0 (`paax-api`), 2024.10.7 (`backend`) | YouTube search (match) / stream extraction | `ThreadPoolExecutor`-wrapped |
| httpx | 0.27.x | Async HTTP to Deezer / LRCLIB / CDN | `paax-api`, `paax-stream` |
| pydantic + pydantic-settings | 2.7.1 / ≥2.2 | Typed config/models (`paax-stream`) | — |
| Cloudflare Workers | `compatibility_date 2024-09-23` | Edge stream-URL resolver (`worker.js`) | No build step, no env vars |

---

## Database

| Technology | Version | Purpose | Notes |
|------------|---------|---------|-------|
| **Hive** (client-side) | ^2.2.3 | The **only** persistent datastore — user library, playlists, settings | On-device; see [database.md](database.md) |
| Redis | server 5.x (`redis` client 5.0.8 / ≥5.0.0) | Response cache (`paax-api`), IPv6 session store (`paax-stream`) | Optional; caches only, not a system of record |

There is **no relational database, no Supabase, no ORM, and no migrations.** The `.claude/rules/database.md` and `.claude/rules/supabase.md` describe an aspirational Postgres/Supabase setup that is **not implemented**. See [backend/database-schema.md](backend/database-schema.md) for the honest picture.

---

## Infrastructure & DevOps

| Technology | Purpose | Notes |
|------------|---------|-------|
| Railway (NIXPACKS) | Hosts the 3 Python services | `restartPolicyType=ON_FAILURE`, max 5 retries; see [deployment.md](deployment.md) |
| Cloudflare (Workers + DNS) | Edge stream resolver + `*.paaxmusic.app` DNS/CDN | `wrangler.toml`, route bound in dashboard |
| Redis (Railway plugin) | Cache / session store | Via `REDIS_URL` |
| Git / GitHub (`uzielcezate/Paax`) | Version control | No CI configured — see [testing.md](testing.md) |
| PWA / TWA | Android app can be delivered as a Trusted Web Activity | `assetlinks.json`, service worker |

No Docker, Kubernetes, Terraform, or GitHub Actions are in use.

---

## External Services & APIs

| Service | Purpose | Documentation |
|---------|---------|---------------|
| Deezer API (`api.deezer.com`) | Catalog **metadata** (tracks/albums/artists/covers) — public, no key | [deezer.com/developers](https://developers.deezer.com/api) |
| YouTube / YouTube Music | **Audio playback** (matched `videoId` via IFrame) + Innertube stream resolution | — |
| YouTube Innertube (`youtubei/v1/player`) | Direct stream-URL resolution in the Cloudflare Worker | Reverse-engineered internal API |
| `googlevideo.com` CDN | Actual audio byte delivery | — |
| LRCLIB (`lrclib.net`) | Synced/plain lyrics (primary source) | [lrclib.net](https://lrclib.net) |
| Google image hosts (`lh3-lh6.googleusercontent.com`) | Artwork | Heavily rate-limited (429) — see [performance.md](performance.md) |

---

## Key Libraries

### Frontend / Mobile

| Library | Purpose | Docs |
|---------|---------|------|
| `audio_service` ^0.18.18 | Android Foreground Service + OS media session | [pub.dev](https://pub.dev/packages/audio_service) |
| `flutter_inappwebview` ^6.1.5 | **Mobile playback** — YouTube IFrame with background audio | [pub.dev](https://pub.dev/packages/flutter_inappwebview) |
| `youtube_player_iframe` ^5.1.0 | **Web playback** — YouTube IFrame | [pub.dev](https://pub.dev/packages/youtube_player_iframe) |
| `cached_network_image` ^3.4.0 | Image caching (pulls `flutter_cache_manager`) | [pub.dev](https://pub.dev/packages/cached_network_image) |
| `palette_generator` ^0.3.3 | Dominant color extraction for the cinematic UI | [pub.dev](https://pub.dev/packages/palette_generator) |
| `google_fonts` ^8.0.2 | Roboto font (locked to defeat OEM overrides) | [pub.dev](https://pub.dev/packages/google_fonts) |
| `flutter_svg` ^2.0.17 | SVG nav icons | [pub.dev](https://pub.dev/packages/flutter_svg) |
| `shimmer` ^3.0.0 | Loading skeletons | [pub.dev](https://pub.dev/packages/shimmer) |
| `visibility_detector` ^0.4.0 | Lazy, on-screen-only image loading | [pub.dev](https://pub.dev/packages/visibility_detector) |
| `share_plus` ^13.1.0 | Share sheet | [pub.dev](https://pub.dev/packages/share_plus) |
| `rxdart` ^0.28.0 | Stream utilities in playback | [pub.dev](https://pub.dev/packages/rxdart) |
| `intl` ^0.20.2 | Formatting | [pub.dev](https://pub.dev/packages/intl) |
| `hive_generator` / `build_runner` (dev) | Hive adapter codegen | — |
| `flutter_lints` ^6.0.0 (dev) | Lint rules | — |

> **Deliberately NOT used** (despite being common in this space): `just_audio` (mentioned only in a stale comment), `youtube_explode_dart`, `go_router`, `riverpod`, `freezed`, `supabase_flutter`. Do not add these without an [ADR](decisions.md).

### Backend

| Library | Purpose | Docs |
|---------|---------|------|
| `fastapi` / `uvicorn[standard]` | API framework + server (all 3 services) | [fastapi.tiangolo.com](https://fastapi.tiangolo.com) |
| `ytmusicapi` | YouTube Music metadata + auth'd library ops | [ytmusicapi.readthedocs.io](https://ytmusicapi.readthedocs.io) |
| `yt-dlp` | YouTube search & stream extraction | [github.com/yt-dlp](https://github.com/yt-dlp/yt-dlp) |
| `httpx` | Async HTTP client | [python-httpx.org](https://www.python-httpx.org) |
| `redis` (asyncio) | Cache / session store | [redis-py](https://redis.readthedocs.io) |
| `pydantic-settings` | Env-based typed config (`paax-stream`) | [docs.pydantic.dev](https://docs.pydantic.dev) |
| `python-multipart` | Form/body parsing | — |

Full per-service inventory: [DEPENDENCIES.md](DEPENDENCIES.md).

---

## Dependency Policy

- All direct dependencies must be listed in this document and in [DEPENDENCIES.md](DEPENDENCIES.md).
- New dependencies require justification (see [decisions.md](decisions.md)).
- Prefer well-maintained packages with active communities.
- Security-audit all new dependencies before adoption (`flutter pub audit`, `pip-audit`).
- Keep dependencies current. No Dependabot/Renovate is configured yet (a backlog item — see [IDEAS.md](IDEAS.md)).

---

## Upgrade History

| Dependency | From | To | Date | Notes |
|------------|------|----|------|-------|
| Metadata backend | ytmusicapi-only (`backend`) | Deezer+YouTube hybrid (`paax-api` v2) | 2026 (pre-07) | The "v2" migration — see [decisions.md](decisions.md) ADR-001 |
| Playback | server stream resolution | client-side YouTube IFrame | 2026 | See [features/player.md](features/player.md) |
| Mobile webview | `webview_flutter` | `flutter_inappwebview` | 2026 | Needed `allowBackgroundAudioPlaying` |

*(Formal version-bump history is not tracked in git tags beyond `v0.1-mobile-stable`; see [VERSIONING.md](VERSIONING.md).)*

---

*Last updated: 2026-07-16*
