# Changelog

> **Purpose**: A human-readable, chronological record of all notable changes to this project. Distinct from `release-notes.md` (which is user-facing) — this file is for developers and AI agents, with more technical detail.
> **Update when**: Any notable change is merged: features, fixes, refactors, dependency upgrades, breaking changes, or migrations.

---

## Format

Follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) conventions.
Versions follow [Semantic Versioning](https://semver.org/).

- **Added** — New features or capabilities.
- **Changed** — Changes to existing behavior.
- **Deprecated** — Features that will be removed in a future version.
- **Removed** — Features that have been removed.
- **Fixed** — Bug fixes.
- **Security** — Security patches or vulnerability mitigations.
- **Refactored** — Internal code restructuring with no behavior change.
- **Performance** — Performance improvements.
- **Docs** — Documentation-only changes.

> **Reconstructed history.** This changelog was backfilled on 2026-07-16 from ~163 commits of git history (the repo predates the changelog and has only one tag, `v0.1-mobile-stable`). Entries are grouped into the **development phases** the commit history reveals rather than into SemVer releases, because the project was never versioned per-release. Dates other than the top entry are approximate/relative. See [versioning](VERSIONING.md) and [decisions](decisions.md).

---

## [Unreleased]

> Accumulate changes here as they are merged. Move to a version section at release time.

### Phase 2.2 — Deezer ingestion & reconciliation (2026-07-17)

- **Added (DB)** — migration `20260717145607_catalog_phase2_2_ingestion_upserts`:
  atomic `catalog_upsert_{artist,album,track}_graph(jsonb)` RPCs (+ private
  helpers), service-role-only. Enforce: preserve existing `youtube_*` and
  cached-artwork columns on refresh; never downgrade `full`→`partial`; bump
  `metadata_updated_at` only on `full`; prune junction rows only when the
  payload is `complete`. Integration-tested against production, then cleaned up.
- **Added** — `paax-api` ingestion layer: Deezer→payload mappers
  (`mappers/deezer_*`), `CatalogIngestionService` (complete album graph with
  per-track collaborators fetched from `/track/{id}` under bounded concurrency),
  `relationship_reconciler` (artist-genre enrichment), repository graph-upsert
  write methods. +18 unit tests (31 total).
- **Security / Fixed** — Deezer client now uses **secure TLS** (`verify=True`,
  certifi) instead of `verify=False`; normalized upstream errors (404→NotFound,
  403/5xx→Unavailable, 429→RateLimited, timeout→Timeout, malformed→BadResponse,
  including Deezer's HTTP-200-with-`error`-body quirk); bounded concurrency +
  in-flight request de-duplication.
- Backend-only: no Flutter, playback engine, or `/v2` endpoint changes yet.

### Phase 2.1 — Supabase catalog data layer (2026-07-17)

- **Added** — `paax-api` Supabase-first catalog data layer (ADR-009 Phase 2):
  centralized `config.py`; reusable async Supabase gateway (service-role,
  backend-only, injectable); typed catalog schemas (domain graphs + normalized
  camelCase API responses) with vocabularies pinned to the live DB CHECK
  constraints; artist/album/track/genre/search repositories with batched
  (non-N+1) entity-graph loading; row→graph and graph→response mappers; 13 unit
  tests via an in-memory fake gateway.
- **Added (DB)** — migration `20260717082812_catalog_phase2_1_match_types_and_search`:
  `tracks.youtube_audio_match_type` / `youtube_music_video_match_type` columns
  (+ CHECKs); `public.catalog_normalize(text)`; `public.catalog_search(...)`
  trigram RPC (service-role-only). Applied to production.
- **Changed (DB history)** — Phase 1's `supabase/migrations` (previously
  untracked) is now committed as the single canonical history; local filenames
  reconciled to the live version timestamps.
- **Deps** — `paax-api` adds `supabase>=2.9,<3`, `Pillow>=10.3,<12`; dev adds
  `pytest`, `pytest-asyncio`, `respx`.
- Backend-only: no Flutter, playback engine, or `/v2` endpoint changes yet.

### Added
- (nothing pending)

### Changed
- (nothing pending)

### Fixed
- (nothing pending)

### Security
- (nothing pending — but see open items in [known issues](KNOWN_ISSUES.md): TLS `verify=False`, `str(e)` leakage, no rate limiting)

---

## Supabase Phase 1 foundation — 2026-07-16

> **Supabase Phase 1 foundation deployed — 34-table schema, RLS, storage buckets, billing readiness, owner bootstrap (ADR-009).** Deployed foundation only: nothing consumes it yet — Flutter still runs on Hive + demo auth and `paax-api` is unchanged. See [decisions](decisions.md) ADR-009 and [backend/database-schema.md](backend/database-schema.md).

### Added
- feat(db): Supabase project (`jecgmiuypuathhvjuhea`) with 34 RLS-enabled Postgres tables (catalog, profiles, library/social, playlists, stories, billing, notifications), 6 views, secure `private`-schema functions/triggers, `pg_trgm` search indexes — 11 migrations in `supabase/migrations/` (repo ↔ remote 1:1).
- feat(storage): 3 Storage buckets with policies (`music-images`, `user-avatars`, `story-media`).
- feat(billing): provider-agnostic billing schema with seeded subscription plans/features (provisional prices; no live Stripe); Stripe Edge Function scaffolds in `supabase/functions/` (**not deployed**).
- chore(auth): `scripts/bootstrap-owner.mjs` for the owner test account.

### Changed
- docs(adr): ADR-009 accepted — supersedes ADR-002 ("no server DB"); Hive remains the live client store until the Phase-3 migration.

---

## Phase 5 — "Liquid Glass" polish & dynamic color environments — 2026-07-16

> The most recent arc: solid "cinematic black" surfaces standing in for real glass, Apple-Music-style dominant-color backgrounds, full removal of the old orange accent, and slimmer chrome. Blur remains globally disabled (`forceSolidGlass=true`) except the single `BackdropFilter` in the full player.

### Changed
- style(theme): match "OC Liquid Glass" reference settings; slimmer mini player (67px) and nav bar; partial glass rim lightband (`224eb0f`, `4293f28`, `c7c282c`).
- feat(theme): Phase 5 — dynamic **dominant-color backgrounds** for artist/album/playlist detail screens; "Apple Music-style color environments"; color-matched fades with adaptive contrast (`d14425c`, `50fcb8e`, `100117f`).
- feat(ui): remove all **orange accents**, standardize adaptive foregrounds across detail/library screens; white Play button, glass secondary buttons, bold titles (`f9e2c0e`, `7fc2b31`, `23f2867`).
- feat(ui): dynamic bottom menus, play-button cutout, nav-bar consistency; exclude pure-black covers from dynamic backgrounds (`bbbf1c0`, `818c0de`, `d7a9a2e`).

### Fixed
- fix(ui): stale fades, black-glass artifacts, liquid-glass transition artifacts, readability, animation speeds, route-fade lifecycle (`a10dc8f`, `d546d6f`, `925f932`, `5b5fe7b`).
- fix(genre): genre background now a flat solid color (no darkening gradient), matching album/artist/playlist (`7785fef`, `92c5d9b`).
- fix(build): resolve `const` errors in `main_wrapper` and discography screen (`af52d44`).

---

## Phase 4 — iOS-style glass UI system — (pre-2026-07-16)

### Added
- feat(ui): Phase 4 iOS-style white glass blur UI system; floating glass navigation — remove all traditional top bars (`24b3967`, `30327a7`).

### Changed
- refine(ui): Phase 4 polish — lower opacity, fix double-blur, match widths; thinner borders, blur chips, stable controls, deeper gradients; pure-black final polish (`161d022`, `4d645f9`, `ec97da3`).

> Note: the "glass" system later converged to **solid** surfaces (`BlurCapability.canBlur()` always false) for performance/readability; the live blur is only in `player_screen.dart`. See [architecture](architecture.md).

---

## Phase 3 — Artist discography, playlist management & image caching — (pre-2026-07-16)

### Added
- feat(artist): artist **discography** with "Último lanzamiento / Álbumes / Sencillos y EPs" sections + full discography screen (`46545a9`); enrich releases from top tracks via `/album/{id}` (`5c4ede8`).
- feat(player): full-player UI polish + playback **queue with drag-to-reorder**; Song/Lyrics modes; English translation; play-icon fix (`e9563ff`, `72d3c10`, `0079c4f`).
- feat(library): **playlist management** — create/edit-order (`ReorderableListView`), pin (cap 5), per-tab search + sort (`11a61f2`, `21e5a98`, `1b02ec7`).

### Performance
- perf(artist): two-phase artist rendering (basic → enrich) + image caching improvements (`11a61f2`). See [optimization log](OPTIMIZATION_LOG.md) OPT-004.

### Fixed
- fix(artist): Singles not appearing; metadata formatting; UI translated to English (`c0e9fc4`).

---

## Client-side playback, PWA & TWA — (pre-2026-07-16)

### Added
- feat(pwa): offline-first **service worker** for TWA cold start; `.well-known/assetlinks.json` for TWA digital asset links; maskable icons & splash; PWA manifest ("Paax Music", dark `#0D0D0D`) (`b89ff5e`, `03a9903`, `4eae54b`, `9e97239`, `20232e8`).
- feat(web): **Web Media Session API**; production web build for Vercel — all metadata routes to `api.paaxmusic.app`, direct CDN streaming on web (no proxy) (`eb00652`, `9e97239`).
- feat(playback): hidden-WebView identity provider experiment (Phase 10) — HeadlessInAppWebView cookie/visitorData extraction, `flutter_inappwebview` added as a direct dependency (`c25ae64`). *(Later superseded by the direct-IFrame v2 path.)*

### Fixed
- fix(pwa): `viewport-fit=cover` for safe-area support; splash/screen unification; `CardTheme`→`CardThemeData` Flutter compatibility (`496797a`, `06c77ac`, `938cf07`).

---

## v2 hybrid pipeline & caching foundation — (pre-2026-07-16)

### Added
- feat(api): **v2 Deezer + YouTube hybrid** — `/v2/*` endpoints serving clean Deezer metadata with per-track YouTube `videoId` matching (`yt-dlp ytsearch`, scored on duration/title/artist/trust). paax-api becomes the live metadata backend, superseding the legacy `backend/` monolith. See [api](api.md).
- feat(cache): two-tier **Redis + in-memory `MemoryCache(500)`** with TTL jitter; 7-day YouTube match cache; `X-Cache` header; env-based API config. See [cache strategy](CACHE_STRATEGY.md), [optimization log](OPTIMIZATION_LOG.md) OPT-001/007.

### Changed
- chore(brand): begin **Beaty → Paax** rebrand (manifest, icons, titles); some identifiers (`beaty` package, `com.beaty.music.beaty`) still remain. See [known issues](KNOWN_ISSUES.md) ISSUE-010.

---

## [0.1.0] — v0.1-mobile-stable (initial monorepo) — (project inception)

> The only tagged milestone. Initial Flutter client + FastAPI ytmusicapi backend, then mobile playback stabilization.

### Added
- Initial monorepo: Flutter client (`beaty`) + FastAPI backend (ytmusicapi metadata + yt-dlp streaming).
- Core layered Flutter architecture (`core`/`data`/`domain`/`presentation`), Provider + ChangeNotifier state, Hive local persistence, manual `Navigator` + `IndexedStack` shell.
- Mobile playback via `flutter_inappwebview` with background-audio survival + Android foreground service (`PaaxAudioHandler`).
- v1 API surface: search/home/charts/moods/genre/artist/album/song/watch/lyrics + authenticated library/playlist/rate (single shared YTMusic OAuth).

### Security
- Auth is a **local demo stub** (`user@gmail.com`/`12345`); no server accounts. Documented, not a regression. See [security](security.md).

---

*Last updated: 2026-07-16*
