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
- **Auth is a demo stub.** `AuthController.login` hardcodes `user@gmail.com` / `12345` and saves a local `UserProfile(name:"Uziel")`; `signup` always succeeds; `logout` = `HiveStorage.clearAll()`. No tokens, no server accounts. See [Security Notes](#security-notes).

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

*Last updated: 2026-07-16*
