# Completed Tasks

> **Purpose**: A permanent log of completed work. Provides a historical record of what was built and when. Helps agents understand what has already been done.
> **Update when**: A task is merged, deployed, and verified complete.

---

## How to Add

Move the task block from [`in-progress.md`](in-progress.md), add a **Completed** date and a summary of how it was resolved.

---

## Reading Note

Paax is built by a single maintainer, so there is no formal ticketing history — the record below is reconstructed from git history (163 commits, tag `v0.1-mobile-stable`) and the shipped codebase. Dates are grouped into **phases** rather than precise per-task completion dates, because the work landed as continuous streams of commits rather than discrete tracked tickets. Where a subsystem is shipped but intentionally dormant or superseded, that is called out explicitly — see [`../TECH_DEBT.md`](../TECH_DEBT.md) and [`../current-state.md`](../current-state.md) for the honest current picture, and [`../roadmap.md`](../roadmap.md) for where each thread is heading next.

---

## Completed Log

---

### TASK-C-P2.6 — Catalog integrity: discography attribution fix

**Type**: Bug fix (backend data quality)
**Completed**: 2026-07-17 · merged `1ef1bd1` (PR #3), deployed Railway `f2919948`
**Resolved By**: AI agent (directed by uzielcezate)
**Summary**: Partial Deezer artist-album payloads now inherit the authoritative
parent-artist context; no "Unknown Artist" placeholders are persisted; artist
discography populates and sorts correctly. Production data cleaned (Daft Punk: 38
albums relinked, 38 placeholders removed, 0 albums lost) and verified generic on
Pink Floyd (64 albums, 0 placeholders). +9 regression tests (85 total). No schema,
Flutter, playback, or iframe changes. See [KNOWN_ISSUES.md](../KNOWN_ISSUES.md)
ISSUE-021.

---

### TASK-C01 — Deezer + YouTube "v2" hybrid metadata pipeline

**Type**: Feature (core architecture)
**Completed**: Phase 6 (metadata re-platforming) — landed as the current `paax-api` v2 surface
**PR / Commit**: `paax-api/main.py` `/v2/*` route family; superseded the ytmusicapi-only `backend/`
**Resolved By**: Solo maintainer (uzielcezate)

**Summary**:
Replaced the original ytmusicapi-driven metadata backend with a hybrid pipeline: clean catalog metadata is pulled from the **Deezer public API** (no key), and each track is matched to a YouTube `videoId` via `yt-dlp ytsearch`, scored 0–100 on duration (±60s hard reject), title similarity (difflib), artist match, and trust signals (Topic/VEVO/"Official Audio"). Confidence ≥0.5 yields `matchStatus:"matched"`, otherwise `low_confidence`. The API returns Deezer metadata plus a `playback` block `{provider:"youtube", engine:"iframe", videoId, matchConfidence, matchStatus, matchReason}`. Matching is eager (at request time), concurrency-limited by `asyncio.Semaphore(3)` (chart uses 5), per-track timeout 15s. This is the **live** metadata path.

**Files Changed**:
- `paax-api/main.py` (v2 endpoints: `/v2/search`, `/v2/artist/{id}`, `/v2/artist/{id}/top`, `/v2/artist/{id}/albums`, `/v2/album/{id}`, `/v2/track/{id}`, `/v2/chart`, `/v2/match`)
- `paax-api/deezer_mapper.py` (response normalization)
- `frontend/lib/data/api/youtube_music_data_source.dart` (`searchV2`/`getArtistV2`/… methods)
- `frontend/lib/data/repositories/music_repository_impl.dart` (v2 mappers set `Track.id = playback.videoId`)

---

### TASK-C02 — Client-side YouTube-IFrame playback (mobile background audio + web)

**Type**: Feature (core playback)
**Completed**: Phase 2 (mobile playback stabilization) → Phase 3 (client-side playback / PWA-TWA)
**PR / Commit**: `frontend/lib/core/playback/*`
**Resolved By**: Solo maintainer (uzielcezate)

**Summary**:
The app plays the matched `videoId` **directly through the YouTube IFrame API** — no server stream resolver is on the live path. An abstract `PlaybackEngine` is selected by `playback_factory.dart` via conditional imports: web uses `youtube_player_iframe`; mobile uses `flutter_inappwebview` hosting inline HTML that loads `iframe_api`, creates a `YT.Player`, muted-autoplays then unmutes, and bridges JS↔Dart via `PaaxBridge`. Background audio on Android survives via a silent Web Audio oscillator, a 5s heartbeat, and `visibilitychange` resume. `flutter_inappwebview` was chosen over `webview_flutter` specifically because it supports `allowBackgroundAudioPlaying:true`. Note: `just_audio` is **not** used (only a stale factory comment references it).

**Files Changed**:
- `frontend/lib/core/playback/playback_engine_mobile.dart`
- `frontend/lib/core/playback/playback_factory.dart`
- `frontend/lib/presentation/widgets/hidden_video_player.dart`
- `frontend/lib/presentation/state/playback_controller.dart`

---

### TASK-C03 — OS media session / Android Foreground Service

**Type**: Feature (platform integration)
**Completed**: Phase 2–3
**PR / Commit**: `frontend/lib/core/playback/paax_audio_handler.dart`; `AndroidManifest.xml`
**Resolved By**: Solo maintainer (uzielcezate)

**Summary**:
`PaaxAudioHandler extends BaseAudioHandler` (`audio_service`) acts as a **Foreground Service proxy** — it does not play audio itself. Its job is to keep the Android service alive so the OS will not kill the playback WebView, render the media notification, and forward transport controls (play/pause/next/prev/seek) back to `PlaybackController`. The manifest declares `com.ryanheise.audioservice.AudioService` with `foregroundServiceType=mediaPlayback` and a `MediaBrowserService` intent-filter, plus `MediaButtonReceiver` and the `FOREGROUND_SERVICE` / `FOREGROUND_SERVICE_MEDIA_PLAYBACK` / `WAKE_LOCK` permissions. Web builds shipped a Media Session integration as well (`media_session_web.dart`, later commented out).

**Files Changed**:
- `frontend/lib/core/playback/paax_audio_handler.dart`
- `frontend/android/app/src/main/AndroidManifest.xml`

---

### TASK-C04 — Hive-based client-side library ("the real database")

**Type**: Feature (persistence)
**Completed**: Phases 1–3 (foundational), refined through Phase 5
**PR / Commit**: `frontend/lib/data/local/hive_storage.dart`; `frontend/lib/presentation/state/library_controller.dart`
**Resolved By**: Solo maintainer (uzielcezate)

**Summary**:
All user state lives **client-side in Hive** — there is no server database of any kind. Five typed adapters (Track, Playlist, SavedAlbum, UserProfile, Artist) back nine boxes covering liked tracks, playlists, saved albums, followed artists, recently played, plus untyped `settings` (onboarding flag, hidden track ids, pinned-playlist map capped at 5), `recent_searches` (max 10), and a declared-but-unused `stream_candidates` box. `init()` registers adapters with hot-restart guards, opens the boxes, and runs one-time dedup migrations for liked/recently-played (keeping the richest artists list and re-keying by id). `LibraryController` performs all CRUD, persists to Hive, then notifies listeners. See [`../database.md`](../database.md) for the full box/adapter schema.

**Files Changed**:
- `frontend/lib/data/local/hive_storage.dart`
- `frontend/lib/presentation/state/library_controller.dart`
- `frontend/lib/domain/entities/track.dart` / `track.g.dart` (and Playlist/SavedAlbum/Artist/UserProfile adapters)

---

### TASK-C05 — Search with debounce (parallel multi-type)

**Type**: Feature
**Completed**: Phase 1–2, re-pointed to v2 in Phase 6
**PR / Commit**: `frontend/lib/presentation/state/search_controller.dart`
**Resolved By**: Solo maintainer (uzielcezate)

**Summary**:
`SearchController` debounces input at 400ms and issues a parallel `Future.wait([searchTracks, searchAlbums, searchArtists])` against `/v2/search`, with explicit loading/error states. The empty state renders 19 hardcoded genre cards; results support All/Tracks/Albums/Artists filters. This satisfies the performance rule requiring debounced expensive input.

**Files Changed**:
- `frontend/lib/presentation/state/search_controller.dart`
- `frontend/lib/presentation/screens/search_screen.dart`

---

### TASK-C06 — Artist profiles + discography

**Type**: Feature
**Completed**: Phase 3 (artist discography + playlist management)
**PR / Commit**: `frontend/lib/presentation/screens/artist_detail_screen.dart`, `artist_discography_screen.dart`
**Resolved By**: Solo maintainer (uzielcezate)

**Summary**:
Two-phase artist screen (basic render, then enrich) surfacing Popular / Latest / Albums / Singles & EPs / "Fans also like". A dedicated discography screen adds All / Albums / Singles & EPs filters. Backed by `/v2/artist/{id}`, `/v2/artist/{id}/top`, and `/v2/artist/{id}/albums`. Because Deezer already carries release dates and types, `enrichArtistReleases` is a deliberate no-op in v2.

**Files Changed**:
- `frontend/lib/presentation/screens/artist_detail_screen.dart`
- `frontend/lib/presentation/screens/artist_discography_screen.dart`

---

### TASK-C07 — Playlist CRUD + reorder + pin

**Type**: Feature
**Completed**: Phase 3
**PR / Commit**: `frontend/lib/presentation/screens/playlist_detail_screen.dart`, `add_to_playlist_sheet.dart`
**Resolved By**: Solo maintainer (uzielcezate)

**Summary**:
Full playlist lifecycle stored as Hive `Playlist` objects: create (library FAB), add/remove tracks (`add_to_playlist_sheet`), drag-to-reorder (`ReorderableListView`), and pin (pinned-first ordering, capped at 5 via `pinned_playlist_map`). Playlist detail shows a blurred-artwork header, search, and sort. Covers render as a 2×2 collage (`playlist_cover`).

**Files Changed**:
- `frontend/lib/presentation/screens/playlist_detail_screen.dart`
- `frontend/lib/presentation/widgets/add_to_playlist_sheet.dart`
- `frontend/lib/presentation/widgets/playlist_cover.dart`

---

### TASK-C08 — Image 429-throttling pipeline

**Type**: Chore / Performance (reliability)
**Completed**: Phases 2–5 (two overlapping generations)
**PR / Commit**: `frontend/lib/core/image/*`, `frontend/lib/core/network/*`
**Resolved By**: Solo maintainer (uzielcezate)

**Summary**:
YouTube artwork hosts (`lh3-lh6.googleusercontent.com`) and Deezer covers aggressively return **HTTP 429** under bursty parallel loads (worst on Flutter Web). The defense stack: `ImageRequestQueue` (web `maxConcurrent=1`, mobile 4; onScreen/nearScreen/offScreen priority queues; global pause on 429), `HostThrottleState` (per-host exponential backoff 2s→60s + jitter), `Lh3UrlBuilder` (strict `=w-h` sizing + domain sharding lh3→lh3/4/5/6 by `url.hashCode%4`), `ImagePipeline`/`PlatformCacheManager` (web memory-only vs mobile disk 30d), and `ThrottledHttpClient` (concurrency 6, retry on 429). The off-screen `thumbnail_prefetcher` was **deprecated** because prefetching itself triggered 429s. Two generations (`core/image/*` and `core/network/*`) coexist — consolidation is tracked in [`../TECH_DEBT.md`](../TECH_DEBT.md).

**Files Changed**:
- `frontend/lib/core/image/*` (`app_image.dart`, `image_request_queue`, `lh3_url_builder`, `image_pipeline`)
- `frontend/lib/core/network/*` (`throttled_http_client`, `host_throttle_state`)

---

### TASK-C09 — Redis caching in paax-api

**Type**: Performance
**Completed**: Phase 1 (env-based config + caching) → carried into v2
**PR / Commit**: `paax-api/cache.py`
**Resolved By**: Solo maintainer (uzielcezate)

**Summary**:
Two-tier cache: Redis (`redis.asyncio`, primary) plus an in-memory LRU `MemoryCache(max_size=500)`. TTLs: search 900s, home/artist/chart 21600s (6h), album 86400s (24h), and a 7-day YouTube **match cache** (604800s). Keys are deterministic/normalized with 0–60s TTL jitter, and responses carry an `X-Cache: HIT/MISS` header. Endpoint-cached: `/v2/artist/{id}`, `/v2/album/{id}`, `/v2/chart` and all v1 discovery. `/v2/search`, `/v2/track`, and `/v2/artist/{id}/top` are not endpoint-cached, but their individual matches still hit the 7-day match cache. Redis is optional — the service degrades gracefully to memory-only.

**Files Changed**:
- `paax-api/cache.py`
- `paax-api/main.py`

---

### TASK-C10 — Cloudflare Worker stream resolver (edge, Innertube)

**Type**: Feature (infrastructure)
**Completed**: Phase 4-ish ("v6" resolver generation)
**PR / Commit**: `cloudflare-worker/`
**Resolved By**: Solo maintainer (uzielcezate)

**Summary**:
An edge resolver at `stream.paaxmusic.app` that calls the YouTube Innertube player API (`youtubei/v1/player`) with a client waterfall (ANDROID → ANDROID_VR → ANDROID_TESTSUITE → TVHTML5_SIMPLY_EMBEDDED → IOS) to obtain a direct progressive audio CDN URL, preferring itag 140 (m4a/AAC) and rejecting webm/opus/DASH. Uses `caches.default` (TTL 300s), no env vars, unauthenticated Innertube. **Deployed but not consumed by the live app** — the live playback path uses the IFrame directly. This is an alternate/parallel streaming generation; see [`../TECH_DEBT.md`](../TECH_DEBT.md) for the "consolidate streaming approach" thread.

**Files Changed**:
- `cloudflare-worker/` (Worker script + `wrangler` config)

---

### TASK-C11 — paax-stream IPv6 byte proxy (deployed)

**Type**: Feature (infrastructure)
**Completed**: Phase 8 ("Hybrid Proxy", v4.0.0)
**PR / Commit**: `paax-stream/app/`
**Resolved By**: Solo maintainer (uzielcezate)

**Summary**:
A FastAPI service at `resolver.paaxmusic.app` exposing `/`, `/health`, `/stream`. `GET /stream?url=<cdn_url>` **proxies audio bytes** (not a redirect) through a rotating pool of 16 local IPv6 source addresses (a /124 block), each with a sticky device fingerprint (random UA + harvested cookies cached in Redis `paax:session:<ipv6>`, TTL 1800s). Supports HTTP Range/206 for seeking in 64KiB chunks, with an anti-abuse host allowlist (`*.googlevideo.com` / `*.youtube.com` / `*.ytimg.com` / `*.ggpht.com`). Rationale: datacenter IPs get bot-blocked by YouTube's CDN, and per-source IPv6 rotation dodges per-IP limits. **Deployed but not consumed by the live app.** The service's `resolve/` multi-provider pipeline is orphaned scaffolding (not mounted, missing modules, `yt_dlp` absent from requirements) — documented as dead in [`../TECH_DEBT.md`](../TECH_DEBT.md).

**Files Changed**:
- `paax-stream/app/main.py`, `paax-stream/app/routes/stream.py` (or equivalent), IPv6 session/transport modules

---

### TASK-C12 — PWA / TWA packaging (web installability)

**Type**: Feature (platform)
**Completed**: Phase 3 (client-side playback / PWA-TWA)
**PR / Commit**: `frontend/web/` (service worker, `assetlinks.json`, manifest, viewport-fit)
**Resolved By**: Solo maintainer (uzielcezate)

**Summary**:
The web build ships as an installable PWA and is packaged as a Trusted Web Activity: service worker, Digital Asset Links (`assetlinks.json`), web app manifest, and `viewport-fit` handling. This is how `paaxmusic.app` reaches Android as an app shell alongside the native build.

**Files Changed**:
- `frontend/web/` (manifest, service worker, `.well-known/assetlinks.json`)

---

### TASK-C13 — Cinematic-black / "liquid glass" UI system (Phases 3–5)

**Type**: Feature (design system)
**Completed**: Phase 3 → Phase 4 (iOS-style white glass blur) → Phase 5 (dynamic dominant-color backgrounds) → recent liquid-glass polish
**PR / Commit**: `frontend/lib/presentation/widgets/glass_surface.dart` and the glass/blur widget family
**Resolved By**: Solo maintainer (uzielcezate)

**Summary**:
The visual language evolved from an iOS-style white glass blur (Phase 4) into Phase 5 "Apple Music-style color environments" (dynamic dominant-color backgrounds, orange accents removed) and finally the current **Cinematic Black** treatment. Real `BackdropFilter` blur is now **disabled** app-wide (`BlurCapability.canBlur()` returns false, `forceSolidGlass=true`): every "glass" surface renders solid `AppColors.surface` (#111) + white@0.08 0.5px border + soft shadow, governed by `BeatyGlassTokens`. "Liquid glass" is simulated with static blurred-artwork headers, solid dark chrome, and gradient edge fades (`DynamicEdgeFade`). The only live `BackdropFilter` remaining is in the full player (blur 55 over blurred artwork + 55% scrim). `DynamicBackground` is implemented but **not mounted** by any screen (dormant). The latest commits (`224eb0f`, `4293f28`, `c7c282c`) continue rim/shadow/edge tuning — that ongoing polish is tracked in [`in-progress.md`](in-progress.md).

**Files Changed**:
- `frontend/lib/presentation/widgets/glass_surface.dart`, `black_glass_blur_surface.dart`, `paax_glass_container.dart`, `dynamic_background.dart`
- `frontend/lib/core/theme/app_colors.dart`, `app_theme.dart`

---

### TASK-C14 — Synced lyrics (LRCLIB)

**Type**: Feature
**Completed**: Phase 5-ish
**PR / Commit**: `paax-api` `/lyrics`; `frontend/.../synced_lyrics_view.dart`, `lyrics_service.dart`
**Resolved By**: Solo maintainer (uzielcezate)

**Summary**:
The `/lyrics` endpoint prefers **LRCLIB** (`/api/get` exact match, then `/api/search` fuzzy scored by synced-bonus + duration closeness) and falls back to ytmusicapi plain text. It returns `{lyricsAvailable, type:"synced"|"plain", source, lyrics:[{timeMs,endTimeMs,text}]}`. On the client, `LyricsService` fetches by title/artist/album/duration (10s timeout, in-memory cache by videoId), and the player's Lyrics mode renders `synced_lyrics_view` with auto-advance, glow, and center-scroll.

**Files Changed**:
- `paax-api/main.py` (`/lyrics`)
- `frontend/lib/domain/services/lyrics_service.dart` (or `data/`)
- `frontend/lib/presentation/widgets/synced_lyrics_view.dart`

---

### TASK-C15 — Supabase Phase 1 foundation (schema, RLS, storage, billing readiness)

**Type**: Feature (infrastructure / persistence foundation)
**Completed**: 2026-07-16 (Phase 1 of ADR-009)
**PR / Commit**: `supabase/migrations/*.sql` (11 files, applied via Supabase MCP, mirrored 1:1 in the repo); `scripts/bootstrap-owner.mjs`
**Resolved By**: AI agent (directed by uzielcezate)

**Summary**:
Deployed the full Supabase foundation per **ADR-009**: 34 tables with **RLS on every table** (catalog, profiles, library/social relations, listening history, download sync-state, friendships, playlists + collaborators, 24h stories, provider-agnostic billing, notifications + user_devices), constraints/indexes (incl. `pg_trgm`), secure views (`public_profiles`, `active_stories`, catalog views), `security definer` functions/triggers (counter maintenance, privileged-column guards, play qualification), 3 Storage buckets + policies (`music-images`, `user-avatars`, `story-media`), seeded subscription plans + plan features (premium prices are provisional placeholders), and an owner bootstrap script. A **24-test verification suite passed 24/24**; advisor lints addressed (documented exceptions: `public_profiles` definer view, `billing_events` zero-policy RLS). Docs landed alongside: [`../backend/database-schema.md`](../backend/database-schema.md) + ADR-009 in [`../decisions.md`](../decisions.md). **Crucially, nothing consumes this yet** — the app still runs on Hive + the demo auth stub; Deezer ingestion, YouTube matcher jobs, Stripe, push delivery, and all Flutter integration are Phase 2/3 (see [`backlog.md`](backlog.md) TASK-B14…B21).

**Files Changed**:
- `supabase/migrations/` (11 migration files)
- `scripts/bootstrap-owner.mjs`
- `docs/backend/database-schema.md`, `docs/decisions.md` (ADR-009)

---

<!-- Add more completed tasks above this line as they are finished. -->

---

## Stats

> Reconstructed from git history rather than a ticket tracker; counts reflect the shipped feature groups logged above, not formal tickets.

| Metric | Value |
|--------|-------|
| Total Completed | 15 feature groups (14 reconstructed from ~163 commits, tag `v0.1-mobile-stable`, + Supabase Phase 1 on 2026-07-16) |
| This Sprint | Liquid-glass UI polish (ongoing — see [`in-progress.md`](in-progress.md)); Supabase Phase 1 foundation completed |
| This Month | UI edge/shadow tuning; branding migration in progress; Supabase Phase 1 deployed (ADR-009) |

---

*Last updated: 2026-07-16*
