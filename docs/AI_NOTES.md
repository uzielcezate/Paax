# AI Notes

> **Purpose**: A scratchpad for AI agents to leave context, observations, warnings, and institutional knowledge for future AI sessions. Think of this as inter-agent memory — notes from one session that benefit all future sessions.
> **Update when**: An AI agent discovers something non-obvious, makes a decision that future agents should know about, or identifies a pattern worth documenting.

> **See also**: [`ai/context.md`](ai/context.md), [`ai/memory.md`](ai/memory.md), [`current-state.md`](current-state.md), [`KNOWN_ISSUES.md`](KNOWN_ISSUES.md), [`architecture.md`](architecture.md).

---

## How to Use This File

- **Read this file at the start of every session** before making decisions — especially the Warnings section.
- **Add a note** whenever you discover something that wasn't in the existing docs.
- Notes are organized by category and dated so they can be assessed for freshness.
- Old notes can be marked `[STALE?]` if you believe they may no longer apply.
- Do not delete notes — mark them `[SUPERSEDED by: ...]` if they are replaced.

---

## Note Template

```markdown
### [YYYY-MM-DD] — <Short Title>

**Added by**: <Agent name or model>
**Category**: <Architecture | Bug | Pattern | Warning | Decision | Integration | Performance | Security>
**Confidence**: <High | Medium | Low>
**Still valid as of**: <YYYY-MM-DD or "unknown">

<Note body — be specific and actionable. Future agents need to understand this without context.>
```

---

## ⚠️ Warnings (Read First)

> These are the traps most likely to waste a session or cause a wrong "fix." Every one is sourced from the codebase as of 2026-07-16.

### [2026-07-16] — The stream resolvers are NOT on the live playback path

**Added by**: documentation baseline · **Category**: Warning · **Confidence**: High · **Still valid as of**: 2026-07-16

The live Flutter app does **not** stream through any resolver. It plays the YouTube `videoId` **directly** through the YouTube IFrame API (mobile: `flutter_inappwebview`; web: `youtube_player_iframe`). Do not "fix" playback by touching stream resolvers:

- `ApiConfig.streamBaseUrl` and `MusicRepository.getStreamUrl` (`/stream/{videoId}`, returns `result['url']`) are **defined but unused** in the current path.
- The Cloudflare Worker (`stream.paaxmusic.app`) and the `paax-stream` IPv6 byte-proxy (`resolver.paaxmusic.app`) are **deployed alternate generations**, not consumed by the app.

If a session is asked to "fix streaming," first confirm whether the request is about the live IFrame path (in the Flutter client) or about a dormant resolver. They are different worlds.

### [2026-07-16] — There is no server database and no real auth `[SUPERSEDED in part by ADR-009, 2026-07-16]`

**Added by**: documentation baseline · **Category**: Warning · **Confidence**: High · **Still valid as of**: 2026-07-16 (amended same day)

> **[SUPERSEDED in part by ADR-009 (2026-07-16)]** — A Supabase project (`jecgmiuypuathhvjuhea`) now **EXISTS** with a fully deployed Phase-1 schema (34 RLS-enabled tables, views, functions, Storage buckets — see [`backend/database-schema.md`](backend/database-schema.md)). However, the second half of this warning remains **fully valid**: the running app still uses **Hive + the demo auth stub**, and neither Flutter nor `paax-api` consumes Supabase. **Do not assume integration** — it is a deployed-but-unconnected foundation.

- ~~**No Postgres, no Supabase, nothing.**~~ *(Superseded — a Supabase server DB now exists, unconnected.)* All **live** user state (library, playlists, liked, followed, recently played, settings) still lives client-side in **Hive**. The rule docs [`.claude/rules/database.md`](../.claude/rules/database.md) and [`.claude/rules/supabase.md`](../.claude/rules/supabase.md) and the `supabase-architect`/`database-reviewer` profiles now apply to the real Supabase project — but only for schema/migration work, not for app code, which has no Supabase wiring.
- ~~**Auth is a demo stub.**~~ **[SUPERSEDED by Phase 3.1 (2026-07-17)]** — the demo stub is **removed**; the app now uses real **Supabase Auth** (see [`features/authentication.md`](features/authentication.md)). And **[Phase 3.2A]** the library liked/saved-albums/followed-artists/hidden-tracks + profile/avatar + onboarding, plus **[Phase 3.2B]** followed genres + the personalized Home sections, now read/write Supabase directly (see the 2026-07-17 architecture notes above). The remaining valid caveat: **playlists, recent searches, and the residual local profile are still Hive-only**, and **paax-api still serves the legacy `/v2` browsing path** (unmodified — 3.2B added no backend change).

### [2026-07-16] — Stale comments will lie to you; the docs are authoritative

**Added by**: documentation baseline · **Category**: Warning · **Confidence**: High · **Still valid as of**: 2026-07-16

Trust [`docs/`](.) over in-code comments. Confirmed lies in the source:

- A factory comment implies **`just_audio`** is used for playback. **It is not** — `just_audio` is not even in `pubspec.yaml`. Playback is a YouTube IFrame inside a WebView.
- `AppTheme` comments say the font is **Manrope**; the code actually locks **Roboto** globally (via `google_fonts`) to defeat OEM font overrides.
- `playback_diagnostics.dart` reflects an **older resolve-based architecture** that no longer matches the live IFrame path.

### [2026-07-16] — Blur is disabled; "liquid glass" is faked

**Added by**: documentation baseline · **Category**: Warning · **Confidence**: High · **Still valid as of**: 2026-07-16

The whole "glass" system runs in a solid-black mode. `glass_surface.dart` is on "Phase 1 (Cinematic Black) — no BackdropFilter"; `BlurCapability.canBlur()` always returns `false` and `forceSolidGlass = true`. Every "glass" widget renders a **solid** `AppColors.surface` (#111) + white@0.08 0.5px border + soft shadow. The **only** live `BackdropFilter` in the app is in `player_screen.dart` (blur 55 over blurred artwork + 55% scrim). Do not assume `BackdropFilter` is active elsewhere.

---

## Architecture Notes

### [2026-07-16] — Supabase Phase-1 gotchas (deployed foundation, not connected)

**Added by**: AI agent (ADR-009 deployment) · **Category**: Architecture · **Confidence**: High · **Still valid as of**: 2026-07-16

Non-obvious facts about the new Supabase schema ([`backend/database-schema.md`](backend/database-schema.md)) that will trip up future sessions:

- The **`private` schema** holds the security-definer helpers (`can_view_playlist`, `record_qualified_play`, `bump_*` counters, `handle_new_user`, …) and is **not API-exposed** — do not try to call it from a client or move functions into `public`.
- **Denormalized counters** (`platform_likes_count`, `platform_followers_count`, playlist totals, …) are **trigger-maintained only**. Never write them directly; the relation/event tables are authoritative.
- **`profiles.subscription_tier/status/expires_at` is a cache** — the authoritative record is `user_subscriptions` (synced by `private.sync_profile_subscription_cache()`). Privileged profile columns are trigger-guarded; clients can never set role or tier.
- **`billing_events` has RLS enabled with ZERO policies on purpose** — that means service-role-only access. Do not "fix" it by adding policies.
- **`public_profiles` is a deliberate `security definer` view** (safe columns only, `security_barrier`) — a documented advisor exception, not a vulnerability. See [`security.md`](security.md).
- **Migrations must go through `supabase/migrations/` + the Supabase MCP** (repo ↔ remote 1:1, forward-only with documented rollback strategies). **Never** make Dashboard-only schema changes.

### [2026-07-17] — Phase 3.2A: offline-first cloud library sync boundary

**Added by**: AI agent (Phase 3.2A) · **Category**: Architecture · **Confidence**: High · **Still valid as of**: 2026-07-17

The library is now **offline-first**: **Hive is the fast local cache; Supabase is the durable cross-device authority** (ADR-011, [`features/library.md`](features/library.md)). Traps for future sessions:

- **Reads render from Hive; writes go Hive-first then a best-effort cloud `pushX`.** Never make the UI await the cloud write — failures are journaled in `LibrarySyncState` (dedup `kind+deezerId`, last-write-wins) and replayed by `flushPending`.
- **Deezer-id → catalog-UUID resolution** is the linchpin: `CatalogResolver` maps local Deezer ids to Supabase UUIDs via the public `artists/albums/tracks.deezer_id` columns (cached in memory + SharedPreferences). `Track.deezerTrackId` (**HiveField 11**, additive) exists solely so tracks resolve to `tracks.id`. A track with no known Deezer id **stays local-only** — don't treat missing cloud rows as a bug.
- **`hydrateFromCloud` is ADD-ONLY and skips items with a pending `remove` op** — do not "fix" it to also delete or it will resurrect unlikes/unfollows. `migrateLocalToCloud` runs **once per user** (guarded).
- **Counters are still trigger-only** (`bump_*` maintains `platform_likes_count`/`platform_followers_count`). `LibraryRemoteDataSource` writes **only** relation rows and idempotent inserts (ignores `23505`); never write a counter.
- **`profiles.onboarding_completed` is RPC-only** — flipped exclusively by `complete_artist_onboarding` (SECURITY DEFINER, authenticated-only, ≥5 unique existing artists). It is **excluded** from `ProfileRepository.updateOwn`'s whitelist; don't try to set it via a profile update.
- **Multi-account isolation**: `LibraryRepository.onUserSession(uid)` clears local library boxes (`HiveStorage.clearLibraryBoxes`) + the pending journal on a real account switch; a pre-existing library with `lastUserId == null` is kept local-only and **never bulk-uploaded** (prevents cross-account cloud writes on the pre-3.2A upgrade path).
- **Browsing still calls the LEGACY `/v2` endpoints** (via `MusicRepositoryImpl` — unchanged). Only **onboarding + the sync resolver** use the normalized `/v2/find`, `/v2/artists/deezer/{id}` and **direct Supabase reads** (`artists`/`albums`/`tracks`, `profiles`, `user_*` tables, `user-avatars` Storage). **paax-api was NOT modified in 3.2A** (no Railway redeploy); the YouTube IFrame playback engine is unchanged.

### [2026-07-17] — Phase 3.2B: followed genres mirror the artist pipeline; Home is client-side catalog queries

**Added by**: AI agent (Phase 3.2B) · **Category**: Architecture · **Confidence**: High · **Still valid as of**: 2026-07-17

Phase 3.2B (branch `feat/phase-3.2b-genres-home`) connected the **existing** UI to real data — no redesign, no new screens, state stays Provider + ChangeNotifier (ADR-012, [`features/home.md`](features/home.md)). Traps for future sessions:

- **Followed genres are the artist follow pipeline, copied.** `Genre` entity (Hive **typeId 5**), `followed_genres` box, `CatalogResolver.resolveGenre(s)` (resolve by `genres.deezer_id` → uuid), `LibraryRemoteDataSource.followGenre`/`unfollowGenre`/`fetchFollowedGenreIds`/`fetchCatalogGenres`, `LibraryRepository.pushFollowGenre` + genre cases in the exhaustive `_resolveForKind`/`_applyRemote` switches, hydrate/migrate blocks, `_hasLocalLibrary`, `SyncOpKind.genreFollow`. Same rules as artists: pending-ops journal for unresolved follows, add-only hydrate, clear-on-account-switch, **counters trigger-only** (`private.bump_genre_followers`; never client-written). **No migration** (the genres tables pre-existed) and **paax-api was NOT modified** (no redeploy).
- **The genre Follow UI is a pill on the EXISTING `GenreResultsScreen`** — no standalone browse/detail screen was built. It resolves the display slug → catalog genre by **exact case-insensitive name match, then a deterministic substring fallback**, and **hides the pill** when unmatched or the genre has no Deezer id. The exploratory agents' standalone Genre Browse/Detail screens, a genre chip widget, and a new Home skeleton widget were **discarded** — only their data/controller/repository logic was kept.
- **The Search genre grid still uses hardcoded display slugs** that don't always match catalog `genres.name` — that's why some genres show no Follow pill (ISSUE-027). A future cleanup would source the grid from the catalog. Don't treat a missing pill as a bug.
- **Home is now built from client-side deterministic Supabase catalog queries** — `HomeRepository` (batched public-catalog reads → typed `HomeAlbum`) + `HomeController` (parallel loads; followed artist/genre UUIDs resolved **once** and shared by *new*/*popular* to avoid N+1; **monotonic-token** stale-request cancellation; **per-user** `SharedPreferences` offline cache; debounced pull-to-refresh). Wired via `ChangeNotifierProxyProvider<AuthController, HomeController>` → `onUserSession(uid)` so the persistent Home tab drops the prior user's sections on account switch (per-user cache + in-memory reset = no cross-account bleed). **No RPC/edge function, no backend change.** Sections hide when empty; albums without a Deezer id are hidden (detail screen keyed by Deezer id); no "Continue Listening" placeholder. Home does **not** live-refresh on cross-tab follow changes (ISSUE-029).

### [2026-07-16] — The layout is layer-first, not feature-first

**Added by**: documentation baseline · **Category**: Architecture · **Confidence**: High · **Still valid as of**: 2026-07-16

`.claude/rules/flutter.md` prescribes a feature-first `lib/features/...` tree. The actual code is **layer-first (Clean-ish)**: `lib/core/`, `lib/data/`, `lib/domain/`, `lib/presentation/`. Follow the real layout when adding files. Likewise: state is **Provider + ChangeNotifier** (5 global controllers: `AuthController`, `LibraryController`, `PlaybackController`, `SearchController`, `ThemeState`) — **not** Riverpod/Bloc/freezed; navigation is a **manual Navigator + custom shell** (`MainWrapper` with an `IndexedStack` of 4 tabs, each with its own nested `Navigator`; the full player is an **overlay**, not a route) — **not** go_router.

### [2026-07-16] — Two config files; one is legacy

**Added by**: documentation baseline · **Category**: Architecture · **Confidence**: High · **Still valid as of**: 2026-07-16

`core/config/api_config.dart` is **LIVE** (dart-defines `ENV`/`LAN_IP`/`API_BASE_URL`/`STREAM_BASE_URL`; prod base `https://api.paaxmusic.app`). `core/config/app_config.dart` is **legacy/superseded** (`API_BASE_URL` default `http://localhost:8000`). `core/config/api_constants.dart` holds Deezer direct URLs used **only** by the dead `deezer_api_client`. When changing API wiring, edit `api_config.dart`, not the other two.

### [2026-07-16] — `ThemeState` is not a light/dark toggle

**Added by**: documentation baseline · **Category**: Architecture · **Confidence**: High · **Still valid as of**: 2026-07-16

The app is **dark-only**. `ThemeState` holds ambient `backgroundColor`/`foregroundColor` derived from album art (`DominantColorService`) and adapts status-bar icon brightness. The `DynamicBackground` widget that would drive it live is **implemented but not mounted by any screen** (dormant), though contrast still flows through many widgets' `foregroundColor` params. Don't look for a theme switch — there isn't one.

---

## Bug Notes

### [2026-07-16] — Legacy `backend/` stream resolver is broken

**Added by**: documentation baseline · **Category**: Bug · **Confidence**: High · **Still valid as of**: 2026-07-16

The legacy `backend/` `/stream/{videoId}` yt-dlp resolver throws a `NameError` on an **undefined `_FORMAT_FALLBACKS`**. It is superseded by `paax-api` and off the live path, so this is not user-facing — but don't cite `backend/` streaming as working. The whole `backend/` service is the OLD v1 API that `paax-api` replaced.

### [2026-07-16] — `paax-stream` orphaned providers can't even import

**Added by**: documentation baseline · **Category**: Bug · **Confidence**: High · **Still valid as of**: 2026-07-16

In `paax-stream`, the `youtube_ipv6_proxy/provider.py` imports modules that don't exist as source (`resolver.py`, `_cdn_cache.py` — only stale `.pyc` remain), and `yt_dlp` is **not in `requirements.txt`**. So the entire `resolve/` pipeline would crash if mounted — but it isn't mounted (`app/main.py` only mounts `/`, `/health`, `/stream`). Treat all of `resolve/`, `resolver/`, `providers/`, and `services/` in `paax-stream` as dead scaffolding for a multi-provider future.

---

## Integration Notes

### [2026-07-16] — The "v2" pipeline: Deezer metadata + eager YouTube match

**Added by**: documentation baseline · **Category**: Integration · **Confidence**: High · **Still valid as of**: 2026-07-16

Core product flow: Flutter calls `paax-api` `/v2/*` → `paax-api` pulls clean catalog metadata from the **Deezer public API** (`https://api.deezer.com`, no key) → for each **track** it runs a **YouTube match** via `yt-dlp ytsearch`, scoring 0–100 on duration (±60s hard reject), title similarity (difflib), artist match, and trust signals (Topic channel / VEVO / "Official Audio"); confidence ≥0.5 → `matchStatus:"matched"` else `low_confidence` → returns Deezer metadata + a `playback` block `{provider:"youtube", engine:"iframe", videoId, matchConfidence, matchStatus, matchReason}`. Flutter then sets **`Track.id = playback.videoId`** and plays that videoId. Album/artist cards are **not** matched (no playback needed). Matching is **eager** (at request time), `asyncio.Semaphore(3)` (chart 5), per-track timeout 15s (30s in hybrid services).

### [2026-07-16] — Artwork endpoints aggressively return HTTP 429

**Added by**: documentation baseline · **Category**: Integration · **Confidence**: High · **Still valid as of**: 2026-07-16

YouTube artwork (`lh3–lh6.googleusercontent.com`) and Deezer covers return **429 under bursty parallel loads**, worst on Flutter Web. This is *why* the elaborate image-throttling machinery exists (`ImageRequestQueue` web `maxConcurrent=1`/mobile 4, per-host exponential backoff 2s→60s, `Lh3UrlBuilder` strict `=w-h` sizing + lh3→lh3/4/5/6 domain sharding, `ThrottledHttpClient`). **Do not** add off-screen image prefetching — `thumbnail_prefetcher` is deprecated precisely because prefetch caused 429 storms. Two overlapping image generations coexist (`core/image/*` vs `core/network/*`).

### [2026-07-16] — Server "auth" is a single shared YouTube Music account

**Added by**: documentation baseline · **Category**: Integration · **Confidence**: High · **Still valid as of**: 2026-07-16

The `YTMUSIC_OAUTH_JSON` env var provides **one** shared YouTube Music OAuth account used by `paax-api`/`backend` for ytmusicapi library/playlist/rate endpoints. It is **not per-user** — every authenticated write hits the same shared account. This is a v1-legacy surface; the live `/v2` path doesn't use it.

---

## Performance Notes

### [2026-07-16] — Caching tiers and TTLs (paax-api)

**Added by**: documentation baseline · **Category**: Performance · **Confidence**: High · **Still valid as of**: 2026-07-16

`paax-api/cache.py` is two-tier: Redis (`redis.asyncio`, primary) + in-memory LRU `MemoryCache(max_size=500)`. TTLs: search 900s (15m), home/artist/chart 21600s (6h), album 86400s (24h), **YouTube match cache 604800s (7d)**. Deterministic normalized keys, TTL jitter 0–60s, `X-Cache: HIT/MISS` header. Endpoint-cached: `/v2/artist/{id}`, `/v2/album/{id}`, `/v2/chart` (+ all v1 discovery). **Not** endpoint-cached: `/v2/search`, `/v2/track`, `/v2/artist/{id}/top` — but their individual matches still hit the 7-day match cache. Redis is optional; without `REDIS_URL` caching falls back to in-memory only.

### [2026-07-16] — High-frequency playback state uses ValueNotifier, not setState

**Added by**: documentation baseline · **Category**: Performance · **Confidence**: High · **Still valid as of**: 2026-07-16

`PlaybackController` exposes `positionNotifier`/`durationNotifier` as `ValueNotifier`s and throttles position updates to 250ms, to avoid rebuilding the whole tree 60×/s. `SmoothAudioProgressBar` interpolates at 60fps with its own `Ticker`. When adding progress UI, subscribe to the notifiers — don't call `notifyListeners()` on every tick.

---

## Security Notes

### [2026-07-16] — Real, currently-live security issues to flag (not hypotheticals)

**Added by**: documentation baseline · **Category**: Security · **Confidence**: High · **Still valid as of**: 2026-07-16

A `security-reviewer` pass should weight these heavily — they exist in the code today:

- **TLS validation disabled**: the Deezer `httpx` client in `paax-api` uses **`verify=False`**. Real MITM risk; flag on any change near it.
- **Unauthenticated write endpoints**: `POST /rate`, `POST/DELETE /playlists*` mutate the server's single shared YTMusic OAuth account with **no per-user auth**.
- **Error leakage**: endpoints surface `str(e)` directly to clients (stack/internal detail leak; also violates `.claude/rules/api.md`'s standard error shape, which is not implemented).
- **No rate limiting / no schema validation lib** on the services' own endpoints.
- **CORS** allows configured `FRONTEND_ORIGINS` **plus always-permitted** localhost / `10.0.2.2` / LAN via regex, with `allow_credentials=True`.
- **Demo auth** (see Warnings) — no real authentication anywhere in the client.
- **Android release signs with DEBUG keys** (see below).

### [2026-07-16] — Android identifiers still say "Beaty"

**Added by**: documentation baseline · **Category**: Security · **Confidence**: High · **Still valid as of**: 2026-07-16

Branding migrated Beaty → Paax, but `build.gradle` still has **`applicationId = "com.beaty.music.beaty"`** (with a leftover default-Flutter TODO), the app label is `beaty`, and the Flutter package name is `beaty`. **Release builds sign with DEBUG keys** (a `// TODO real signing` remains). `usesCleartextTraffic=true` is set (for LAN/HTTP dev). Any store-release work must fix the applicationId and signing first.

---

## Pattern Notes

### [2026-07-16] — Dead / dormant code inventory (do not "fix," prune deliberately)

**Added by**: documentation baseline · **Category**: Pattern · **Confidence**: High · **Still valid as of**: 2026-07-16

Confirmed non-live code. If asked to touch any of it, first decide whether the correct action is *deletion* (via `refactoring-expert`), not repair:

| Item | Location | Status |
|------|----------|--------|
| `deezer_api_client.dart` | `frontend/lib/data/api/` | **Fully commented out** (dead) |
| `media_session_web.dart` | `frontend/lib/core/playback/` | **Fully commented out** |
| `getStreamUrl` / `/stream/{videoId}` | data source + repo | Defined, **unused** by playback |
| `ApiConfig.streamBaseUrl` | `core/config/api_config.dart` | Referenced only within the config file |
| `paax-stream` `resolve/`, `resolver/`, `providers/`, `services/` | `paax-stream/` | **Orphaned**, not mounted; can't import (`yt_dlp` missing) |
| `backend/` service | `backend/` | Superseded by `paax-api`; stream resolver `NameError`-broken |
| `DynamicBackground` widget | `presentation/widgets/` | Implemented, **not mounted** by any screen |
| `thumbnail_prefetcher` | image layer | **Deprecated** (caused 429s) |
| `artist_items` screen | `presentation/screens/` | **Orphaned** paginated grid |
| `app_config.dart` / `api_constants.dart` | `core/config/` | Legacy / only feeds dead code |
| `just_audio` | — | Referenced only in a **stale comment**; not a dependency |
| `stream_candidates` Hive box | `hive_storage.dart` | Declared for a stream-URL cache, **currently unused** |

### [2026-07-16] — No automated tests exist

**Added by**: documentation baseline · **Category**: Pattern · **Confidence**: High · **Still valid as of**: 2026-07-16

The Flutter `test/` directory is **absent** (only `flutter_lints`). The backends have only gitignored manual `test_*/verify_*/debug_*/explore_genres.py` probe scripts — not a real suite. The `.claude/rules/testing.md` pyramid and "write a failing test first" steps in the `bug-hunter` profile are **aspirational**. The real gates are `dart format` + `flutter analyze`. Don't block work waiting for a suite that doesn't exist; adding tests is welcome but not currently a gate.

---

## Decision Notes

### [2026-07-16] — Settled architectural decisions (don't re-decide)

**Added by**: documentation baseline · **Category**: Decision · **Confidence**: High · **Still valid as of**: 2026-07-16

Per [`ai/memory.md`](ai/memory.md), these are settled and should only change via a new ADR in [`decisions.md`](decisions.md): ~~**no server database** (Hive is the store)~~ *(superseded by ADR-009, 2026-07-16 — Supabase adopted; Hive remains the live client store until migration)*; **Provider + ChangeNotifier** (not Riverpod/Bloc); **manual Navigator + custom shell** (not go_router); **YouTube IFrame direct playback** (resolvers off the live path); **Deezer metadata + eager YouTube match** as the "v2" pipeline; **dark-only** theme. If a task seems to require reversing one of these, stop and log a `STATUS: OPEN` note here before proceeding.

---

## Stale / Superseded Notes Archive

*(None yet — move outdated notes here with a `[SUPERSEDED by: ...]` marker instead of deleting them.)*

---

*Last updated: 2026-07-17*

## Phase 3.4.2 — startup gotchas (2026-08-07)

**Never route on a nullable remote value.** `ProfileRepository.fetchOwn` returns
`Profile?`, where null means "server reached, no row". It is retained for
non-routing callers. **Startup routing MUST use `fetchOwnResult`**, which returns
`RemoteResult<Profile?>` and distinguishes an authoritative absence from an
unreachable server. Using `fetchOwn` in a routing path reintroduces the exact
production defect (503/504 → "Complete profile").

**`initialSession` is deliberately dropped** in `AuthController._onAuthEvent`
once `bootstrap()` has run. It is not dead code — removing the guard restores the
duplicate-request behaviour (paired requests 3 ms apart in the production logs).

**`tokenRefreshed` deliberately does NOT refetch the profile.** It previously did,
producing a profile read every ~50 minutes per device, forever.

**Privileged profile fields are NOT cached** (`app_role`, `subscription_*`).
`ProfileBootstrapRecord.toProfile()` reconstructs them at safe defaults, so a
premium user shows as free while offline. This is intentional — a stale or
tampered local cache must not be able to grant a role or paid tier.

**The 100% CPU was never the app.** If Supabase CPU spikes again, check
`pg_stat_statements` for the PostgREST preamble (`set_config('request.method'…)`)
call count versus actual data-query counts. A huge ratio (662 M vs ≤193) means
PostgREST is looping, not that the app is chatty — the fix is a project restart,
not a code change. `realtime.subscription` was 0 throughout; pg_cron/pg_net have
no queue tables in this project.

**No `Timer.periodic` exists in the startup path.** The repeated
`playlist_get_activity` calls in the API logs were user-driven sheet opens.

## Phase 3.4.3 — the 40001 retry storm (2026-08-08/09)

**NEVER raise an application-level conflict with SQLSTATE class 40 (`40001`
serialization_failure, `40P01` deadlock).** PostgREST maps class 40* to HTTP 500
and the request is RETRIED. A deterministic business conflict signalled this way
retries forever: one stale playlist Save produced ~2,565 DB executions/sec for
hours, 872M transactions, 99.92% rollbacks, ~92% CPU — with ZERO matching API
Gateway requests, because the multiplication was entirely inside PostgREST.

Measured with a self-limiting probe (sequence counter, which survives rollback),
one HTTP request each: `40001` -> 21+ executions and still looping; `P0001` -> 1;
`sqlstate PGRST` (409) -> 1. Use `private.raise_playlist_version_conflict`.

**`pg_stat_statements` does NOT record statements that error.** During this
incident the RPC showed ~0 calls while executing thousands of times per second.
Use `pg_stat_database.xact_rollback` and the PostgREST preamble
(`set_config('request.method'...)`, queryid 5360251647081715348) as the real
signal. A huge preamble-to-data-query ratio means requests are aborting, not that
the app is idle. This is what made me wrongly conclude "infrastructure, not code"
on 2026-08-07.

**A client UUID does not mean the cloud knows the playlist.** Offline-created
playlists get a client-generated UUID, so `isUuid(id)` cannot decide whether to
call `playlist_delete`. Use `PlaylistRepository.isLocalOnly` (checks for a queued
`create` op) or the delete throws NOT_FOUND and the playlist becomes undeletable.

**Conflicts are terminal on the client too.** `PlaylistSyncService` quarantines a
conflict, pauses that playlist, and never maps it to `retry`. Do not "helpfully"
add a retry path for `OpOutcome.conflict`.


## Phase 3.4.14 — an add can be IN FLIGHT for minutes (2026-08-16)

**"Offline" does not mean "the request failed".** A request already on the wire
when connectivity drops does not fail fast — it stalls until the socket times
out or the network returns. Production proof (playlist `biza`): the Add tap
happened ~15:42 while offline, `tracks.created_at` is 15:44:29.207 and
`playlist_tracks.added_at` is 15:44:29.476 — the ingest inside `_resolveOrThrow`
simply hung for two minutes and then succeeded. So an add can be neither
committed nor journaled nor failed for an arbitrarily long time.

**A journal-gated guard cannot protect such an add.** `preservePendingAdds` is
gated on a queued op, and a Top Track that is not in the catalog yet can never
HAVE one: its catalog UUID does not exist while offline, so nothing can be
enqueued. Reconnect flushes and hydrates concurrently with that still-running
add; the read misses it, nothing is queued, and reconciliation deleted the
optimistic row moments before the add committed. Server right, UI wrong.

**Use the add fence, not "is one in flight right now".** An add that finishes
between the read and the check is exactly the losing race.
`PlaylistRepository.captureAddFence()` is taken BEFORE the read and
`addOverlapped()` answers the causal question (`startedNow > completedBefore`).
Both live adds and journal replays are fenced. It is bounded: once no add
overlaps the window, a genuine remote removal removes the row as before.

**Divergent membership is what breaks reorder.** While the UI held 6 and the
server held 7, `playlist_save_order` correctly rejected the short set with
`ORDER_SET_MISMATCH`. Do not add a reorder special case — fix membership.

**Canonical identity comes from the resolver caches, not a new map.**
`canonicalTrackUuids` reads only what the app already recorded (deezer→uuid,
videoId→uuid, both seeded by hydration and by the add itself), so the optimistic
copy (`Track.id == videoId`) and the authoritative copy (`Track.id == catalog
UUID`, YouTube match pending) resolve to one `u:<uuid>` key. Cache-only: never a
query, and never dependent on a later resolver side effect. The videoId cache
was persisted but never restored on cold start — that is now fixed too.
