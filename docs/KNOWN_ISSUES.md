# Known Issues

> **Purpose**: A permanent, searchable log of known bugs, limitations, and workarounds. AI agents must check this file before investigating a reported problem — it may already be documented.
> **Update when**: A new issue is confirmed, a workaround is found, an issue is resolved (mark as resolved, do not delete), or severity changes.

---

## How to Use This File

- Search this file before opening a bug report or spending time debugging.
- If you find and fix an issue listed here, mark it `✅ RESOLVED` with the date and PR/commit.
- Never delete resolved entries — they serve as historical context.

---

## Issue Template

```markdown
### ISSUE-XXX — <Title>

**Status**: 🔴 Open | 🟡 Workaround Available | ✅ Resolved
**Severity**: Critical | High | Medium | Low
**Affected Area**: <!-- e.g., Player, Auth, Downloads, API -->
**First Observed**: YYYY-MM-DD
**Resolved On**: <!-- YYYY-MM-DD or N/A -->
**PR / Commit**: <!-- Link or hash if resolved -->

**Description**:
<!-- What is the problem? What is the expected vs actual behavior? -->

**Reproduction Steps**:
1.
2.
3.

**Workaround**:
<!-- Describe any known workaround, or state "None" -->

**Root Cause** (if known):
<!-- -->

**Notes**:
<!-- Additional context, related issues, or links -->
```

---

## Summary Table

| ID | Title | Severity | Area | Status | Workaround |
|----|-------|----------|------|--------|------------|
| ISSUE-001 | Legacy backend `/stream` broken (`NameError`) | Critical | Streaming (legacy) | 🟡 | Use paax-api v2 + IFrame playback |
| ISSUE-002 | paax-api Deezer client `verify=False` (TLS off) | High | Security / API | 🔴 | None |
| ISSUE-003 | No per-user auth on write endpoints | High | Security / API | 🔴 | Do not expose write endpoints publicly |
| ISSUE-004 | Unbounded YouTube match memory cache (legacy paths) | High | Backend / Cache | 🟡 | Live path bounds via `MemoryCache(500)`+Redis |
| ISSUE-005 | `str(e)` error leakage to clients | High | Security / API | 🔴 | None |
| ISSUE-006 | Release APK signed with debug keys | High | Android / Release | 🔴 | Do not publish to Play Store as-is |
| ISSUE-007 | `applicationId` still `com.beaty.music.beaty` | High | Android / Branding | 🔴 | None (must change before store listing) |
| ISSUE-008 | HTTP 429 image throttling fragile on Web | Medium | Frontend / Images | 🟡 | Throttle queue + host backoff mitigate |
| ISSUE-009 | Dual/dead config files | Medium | Frontend / Config | 🟡 | Use `api_config.dart` only |
| ISSUE-010 | Branding inconsistency Beaty/Paax | Medium | Branding | 🔴 | None |
| ISSUE-011 | `DynamicBackground` dormant (not mounted) | Low | Frontend / Theming | 🟡 | Contrast still flows via `foregroundColor` |
| ISSUE-012 | paax-stream README stale + orphaned resolver | Low | Streaming / Docs | 🟡 | Ignore `resolve/` scaffolding |
| ISSUE-022 | Cloud-hydrated library entities are sparse | Low | Library / Sync | 🟡 | Fields refill on normal browsing |
| ISSUE-023 | Hidden/liked tracks only sync when a Deezer track id is known | Low–Med | Library / Sync | 🟡 | New likes carry the id; unresolved stay local-only |
| ISSUE-024 | Onboarding search UUID only for cataloged/lazily-resolved artists | Low | Onboarding | 🟡 | Popular grid + lazy `/v2/artists/deezer` resolve |
| ISSUE-025 | Hydrate can duplicate a local liked/hidden row if preferred videoId differs | Low | Library / Sync | 🟡 | Low likelihood; no deezer-id dedup fallback |
| ISSUE-026 | "Clear Data" wipes Hive but not cloud/sync bookkeeping | Low | Library / Sync | 🟡 | Same user re-hydrates from cloud on next login |
| ISSUE-027 | Genre Follow pill only appears for genres matching a catalog name | Low | Genres / Home | 🟡 | Hardcoded Search grid slugs vs. catalog names; fuzzy match |
| ISSUE-028 | "Recommended for you" often empty (sparse genre catalog) | Low | Home / Genres | 🟡 | Section hidden when empty; fills as `album_genres` grows |
| ISSUE-029 | Home does not auto-refresh on cross-tab follow changes | Low | Home | 🟡 | Refreshes on next open or pull-to-refresh |
| ISSUE-030 | Home section breadth bounded by current catalog size | Low | Home / Catalog | 🟡 | Grows as the Supabase catalog is ingested |

---

## 🔴 Critical Issues

### ISSUE-001 — Legacy backend `/stream/{videoId}` throws `NameError: _FORMAT_FALLBACKS`

**Status**: 🟡 Workaround Available
**Severity**: Critical (for the legacy service only)
**Affected Area**: Streaming (legacy `backend/`)
**First Observed**: 2026-07-16 (documented)
**Resolved On**: N/A
**PR / Commit**: N/A

**Description**: The legacy monolith's in-process `yt-dlp` streaming endpoint references an undefined symbol `_FORMAT_FALLBACKS`, raising a `NameError` at request time. The endpoint is non-functional.

**Workaround**: The live app does not use it. Playback goes through paax-api v2 metadata + direct YouTube IFrame; the legacy backend is superseded. `ApiConfig.streamBaseUrl` / `MusicRepository.getStreamUrl` (`/stream/{videoId}`) are defined but unused in the live path.

**Root Cause**: Dead/half-refactored code left in a superseded service.

**Notes**: The legacy backend should be retired, not fixed. See [tech debt](TECH_DEBT.md) DEBT items and [error codes](ERROR_CODES.md).

---

## 🟠 High Severity Issues

### ISSUE-002 — paax-api Deezer HTTP client disables TLS verification (`verify=False`)

**Status**: 🔴 Open
**Severity**: High
**Affected Area**: Security / API (paax-api)
**First Observed**: 2026-07-16

**Description**: The `httpx` client that calls the Deezer public API is constructed with `verify=False`, disabling certificate validation. This exposes the metadata path to man-in-the-middle tampering.

**Workaround**: None. Violates [`.claude/rules/security.md`](../.claude/rules/security.md) ("HTTPS everywhere").

**Root Cause**: Likely a local debugging shortcut around a certificate hiccup that was never reverted.

**Fix**: Remove `verify=False`; if a specific CA is needed, configure the trust store explicitly. See [security](security.md).

---

### ISSUE-003 — No per-user auth on write endpoints

**Status**: 🔴 Open
**Severity**: High
**Affected Area**: Security / API (paax-api, backend)
**First Observed**: 2026-07-16

**Description**: `POST /rate`, `POST/DELETE /playlists`, and `POST/DELETE /playlists/{id}/items` mutate a **single shared** YTMusic OAuth account. There is no per-user authentication or ownership check — any caller who can reach the endpoint mutates the shared account.

**Workaround**: Do not expose these endpoints to untrusted clients. The live Flutter app stores all user state locally in Hive and does not depend on them for normal use.

**Root Cause**: Server intentionally stateless/accountless; these ytmusicapi passthroughs predate a real identity system.

**Fix**: Add real per-user auth or remove the write surface. See [security](security.md) and FR/auth items in [feature requests](FEATURE_REQUESTS.md).

---

### ISSUE-004 — Unbounded YouTube match memory cache (legacy code paths)

**Status**: 🟡 Workaround Available
**Severity**: High
**Affected Area**: Backend / Cache
**First Observed**: 2026-07-16

**Description**: Historic in-process memoization of YouTube match results could grow without bound, risking memory exhaustion on long-lived processes.

**Workaround**: The live paax-api path bounds matches with `MemoryCache(max_size=500)` LRU plus a Redis-backed 7-day `match:*` cache. Any new code that memoizes matches in a plain dict must adopt the same cap.

**Root Cause**: Ad-hoc dict caches without eviction.

**Fix**: Route all match memoization through the bounded `cache.py` helpers. See [cache strategy](CACHE_STRATEGY.md).

---

### ISSUE-005 — Internal error details leak to clients (`str(e)`)

**Status**: 🔴 Open
**Severity**: High
**Affected Area**: Security / API (paax-api)
**First Observed**: 2026-07-16

**Description**: Several handlers return `str(e)` in the response body, exposing stack-trace-adjacent internals (upstream URLs, exception text) to clients. Violates [`.claude/rules/backend.md`](../.claude/rules/backend.md) ("never expose internal error details").

**Workaround**: None currently.

**Fix**: Centralized error handler returning a generic message + a structured code; log the detail server-side only. See [error codes](ERROR_CODES.md).

---

### ISSUE-006 — Release build signed with debug keys

**Status**: 🔴 Open
**Severity**: High
**Affected Area**: Android / Release
**First Observed**: 2026-07-16

**Description**: `frontend/android/app/build.gradle` signs the **release** build type with the debug signing config (default Flutter TODO left in place). A debug-signed APK cannot be safely shipped to the Play Store and is not upgrade-compatible with a properly signed one.

**Workaround**: Do not publish the current release artifact.

**Fix**: Create a real keystore, wire a `signingConfigs.release`, and store credentials outside VCS. See [deployment](deployment.md) and [tech debt](TECH_DEBT.md).

---

### ISSUE-007 — `applicationId` still `com.beaty.music.beaty`

**Status**: 🔴 Open
**Severity**: High (blocks a clean Paax store listing)
**Affected Area**: Android / Branding
**First Observed**: 2026-07-16

**Description**: The Android `applicationId` remains `com.beaty.music.beaty` from the pre-rebrand era, and the manifest `label` is `beaty`. TWA digital-asset-links (`assetlinks.json`) and any published identity must match the final id, so this must be settled **before** first publish (changing an `applicationId` after publish is effectively a new app).

**Workaround**: None.

**Fix**: Decide the final Paax package id, update `build.gradle`, `AndroidManifest.xml` label, and `assetlinks.json` fingerprints together. See [known issues](#issue-010--branding-inconsistency-beatypaax) ISSUE-010.

---

## 🟡 Medium Severity Issues

### ISSUE-008 — HTTP 429 image throttling is fragile on Web

**Status**: 🟡 Workaround Available
**Severity**: Medium
**Affected Area**: Frontend / Images
**First Observed**: 2026-07-16

**Description**: YouTube artwork hosts (`lh3-lh6.googleusercontent.com`) and Deezer covers return HTTP 429 under bursty parallel loads, worst on Flutter Web where the browser issues its own requests and keeps no disk image cache. Under 429 storms, artwork can flash placeholders or load slowly.

**Workaround**: A layered defense mitigates it — `ImageRequestQueue` (web `maxConcurrent=1`, mobile 4), `HostThrottleState` (per-host exponential backoff 2s→60s + jitter), `Lh3UrlBuilder` domain sharding (lh3→lh3/4/5/6), and a global pause on 429. `thumbnail_prefetcher` was deprecated because off-screen prefetch caused 429s. See [performance](performance.md) and [optimization log](OPTIMIZATION_LOG.md).

**Root Cause**: Third-party rate limits + no web disk cache; two overlapping image-cache generations (`core/image/*` vs `core/network/*`) add complexity.

**Fix**: Consolidate the two image-cache generations; consider a same-origin image proxy. See [ideas](IDEAS.md).

---

### ISSUE-009 — Dual / dead config files

**Status**: 🟡 Workaround Available
**Severity**: Medium
**Affected Area**: Frontend / Config
**First Observed**: 2026-07-16

**Description**: `core/config/app_config.dart` (legacy, default `http://localhost:8000`) coexists with the live `api_config.dart`. `api_constants.dart` holds Deezer direct URLs used only by the fully-commented-out `deezer_api_client.dart`. Editing the wrong file has no effect.

**Workaround**: Treat `api_config.dart` as the only source of truth for base URLs.

**Fix**: Delete `app_config.dart`, `api_constants.dart`, and `deezer_api_client.dart`. See [tech debt](TECH_DEBT.md).

---

### ISSUE-010 — Branding inconsistency Beaty/Paax

**Status**: 🔴 Open
**Severity**: Medium
**Affected Area**: Branding (app-wide)
**First Observed**: 2026-07-16

**Description**: The product rebranded Beaty → Paax, but many identifiers remain: Flutter package name `beaty`, Android `applicationId`/`label`, `BeatyGlassTokens`, `com.beaty.music.beaty`, and assorted comments. This is confusing and blocks a clean store identity.

**Workaround**: None; cosmetic in code but externally visible on Android.

**Fix**: Coordinated rename pass. Note the Flutter package rename is invasive (touches every import). See [tech debt](TECH_DEBT.md) and ISSUE-007.

---

### ISSUE-012 — paax-stream README stale + orphaned resolver pipeline

**Status**: 🟡 Workaround Available
**Severity**: Low–Medium
**Affected Area**: Streaming / Docs
**First Observed**: 2026-07-16

**Description**: paax-stream ships a large dead `resolve/` pipeline — `routes/resolve.py`, `resolver/provider_manager.py`, `resolver/fallback_policy.py`, five providers (`cobalt`, `piped`, `invidious`, `youtube_ipv6_proxy`, `youtube_local_mp4`), and `services/*` — none mounted in `app/main.py`. `youtube_ipv6_proxy/provider.py` imports missing modules (`resolver.py`, `_cdn_cache.py` — only stale `.pyc`), and `yt_dlp` is absent from requirements, so it cannot run. The README describes capabilities the live service does not expose (it mounts only `/`, `/health`, `/stream`).

**Workaround**: Ignore everything under `resolve/`; the live service is the IPv6 byte proxy only.

**Fix**: Delete the orphaned pipeline or move it to a clearly-labeled experimental branch; rewrite the README. See [tech debt](TECH_DEBT.md).

---

## 🟢 Low Severity Issues

### ISSUE-011 — `DynamicBackground` implemented but dormant

**Status**: 🟡 Workaround Available
**Severity**: Low
**Affected Area**: Frontend / Theming
**First Observed**: 2026-07-16

**Description**: `DynamicBackground` (RouteAware, extracts a `CinematicColor` and pushes it to `ThemeState`) is fully implemented but **not mounted by any screen** — the "Apple Music-style color environment" driver is dormant. Ambient contrast still works because many widgets receive an explicit `foregroundColor`.

**Workaround**: N/A — no user-visible breakage; the feature simply isn't active as originally envisioned.

**Fix**: Either mount `DynamicBackground` at the shell level or remove it. See [tech debt](TECH_DEBT.md) and [ideas](IDEAS.md).

**Notes**: Related: the "glass/blur" system is intentionally solid (`forceSolidGlass=true`, `BlurCapability.canBlur()` always false); the only live `BackdropFilter` is in `player_screen.dart`. That is by design (Phase-1 "Cinematic Black"), not a bug.

---

## 🟡 Phase 3.2A cloud-sync limitations

### ISSUE-022 — Cloud-hydrated library entities are sparse

**Status**: 🟡 Workaround Available · **Severity**: Low · **Affected Area**: Library / Sync · **First Observed**: 2026-07-17

**Description**: After `hydrateFromCloud`, liked/album/artist entities come back **sparse** — a liked track's `artistName`/`artworkUrl` and a saved album's `artistName` are empty until the entity is re-fetched by normal browsing. The cloud stores relations/ids, not the full display payload.

**Workaround**: Fields refill when the user opens the artist/album/track through normal navigation. See [decisions.md](decisions.md) ADR-011, [TECH_DEBT.md](TECH_DEBT.md).

---

### ISSUE-023 — Hidden/liked tracks resolve to cloud only when a Deezer track id is known

**Status**: 🟡 Workaround Available · **Severity**: Low–Medium · **Affected Area**: Library / Sync · **First Observed**: 2026-07-17

**Description**: A track syncs to Supabase only when its Deezer track id is resolvable (via `Track.deezerTrackId`, HiveField 11). New likes carry it; **pre-3.2A likes may not**. Hidden tracks recover the Deezer id best-effort from a locally-known `Track` (liked/recently-played) — a hidden track with no locally-known `Track` stays local-only.

**Workaround**: Unresolved items remain fully functional locally; they simply do not appear cross-device until re-encountered with an id.

---

### ISSUE-024 — Onboarding search yields a usable UUID only for cataloged/resolved artists

**Status**: 🟡 Workaround Available · **Severity**: Low · **Affected Area**: Onboarding · **First Observed**: 2026-07-17

**Description**: `GET /v2/find?type=artists` can return a freshly-discovered artist with a **null Supabase id**; only already-cataloged artists (or ones resolved via the lazy `/v2/artists/deezer/{id}` call on selection) produce a real catalog UUID submittable to `complete_artist_onboarding`.

**Workaround**: The popular grid (top 30 from `artists`) is always real UUIDs; selection triggers the lazy resolve so submitted ids are always valid. See [features/onboarding.md](features/onboarding.md).

---

### ISSUE-025 — Hydrate can create a duplicate local liked/hidden row on videoId drift

**Status**: 🟡 Workaround Available · **Severity**: Low · **Affected Area**: Library / Sync · **First Observed**: 2026-07-17

**Description**: If the catalog's `preferred_youtube_video_id` ever differs from the `videoId` a track was originally liked with, `hydrateFromCloud` could create a **duplicate** local liked/hidden row (rows are keyed by videoId; there is no deezer-id dedup fallback).

**Workaround**: Low likelihood. No action needed today; a deezer-id-based dedup pass would eliminate it. See [TECH_DEBT.md](TECH_DEBT.md).

---

### ISSUE-026 — "Clear Data" wipes Hive but not the cloud or sync bookkeeping

**Status**: 🟡 Workaround Available · **Severity**: Low · **Affected Area**: Library / Sync · **First Observed**: 2026-07-17

**Description**: The Profile → "Clear Data" action wipes local Hive but **not** the Supabase rows nor the sync bookkeeping (`lastUserId`/migrated flags). So the same user's next login re-hydrates the library from the cloud — "Clear Data" is not a full account reset.

**Workaround**: Expected behavior for a cloud-backed library; a separate server-side deletion flow would be needed for a true erase. See [decisions.md](decisions.md) ADR-011.

---

## 🟡 Phase 3.2B followed-genres + personalized-Home limitations

### ISSUE-027 — Genre Follow pill only appears for genres whose name matches a catalog row

**Status**: 🟡 Workaround Available · **Severity**: Low · **Affected Area**: Genres / Home · **First Observed**: 2026-07-17

**Description**: The Search genre grid uses **hardcoded display slugs** that do not always match catalog `genres.name`. `GenreResultsScreen` resolves the slug to a catalog genre by exact case-insensitive name match, then a deterministic substring fallback; when neither matches (or the genre has no Deezer id), the Follow pill is **hidden**, so some genres show no way to follow.

**Workaround**: Genres whose display name matches (or substring-matches) a catalog row show the pill and follow normally. A future cleanup would source the Search grid from the catalog itself. See [AI_NOTES.md](AI_NOTES.md), [features/library.md](features/library.md).

---

### ISSUE-028 — "Recommended for you" is often empty (sparse genre catalog)

**Status**: 🟡 Workaround Available · **Severity**: Low · **Affected Area**: Home / Genres · **First Observed**: 2026-07-17

**Description**: The personalized Home *Recommended for you* section lists albums in the user's followed genres via `album_genres` links. The genre catalog and `album_genres` links are **sparse today**, so the section frequently resolves empty.

**Workaround**: Empty sections are **hidden** (no fake data). The section fills in as the Supabase catalog's genre links grow. See [features/home.md](features/home.md).

---

### ISSUE-029 — Home does not auto-refresh when follows change on another tab

**Status**: 🟡 Workaround Available · **Severity**: Low · **Affected Area**: Home · **First Observed**: 2026-07-17

**Description**: Following/unfollowing an artist or genre on another tab does not live-update the Home sections. `HomeController` refreshes on next open or on **pull-to-refresh**, not reactively.

**Workaround**: Pull-to-refresh (or re-open the tab) to pick up the new follows.

---

### ISSUE-030 — Home section breadth bounded by current catalog size

**Status**: 🟡 Workaround Available · **Severity**: Low · **Affected Area**: Home / Catalog · **First Observed**: 2026-07-17

**Description**: Trending / Recently added / genre-recommendation breadth is limited by how much of the catalog has been ingested into Supabase. Small catalog = thin rails.

**Workaround**: Sections grow as the catalog is ingested; no action needed. See [backend/phase2-catalog.md](backend/phase2-catalog.md).

---

### ISSUE-031 — Cached artist response can show a stale Paax follower count

**Status**: 🟡 Workaround Available · **Severity**: Low · **Affected Area**: Catalog / Artist · **First Observed**: 2026-07-26 (Phase 3.3)

**Description**: `GET /v2/artists/deezer/{id}` returns `platformFollowersCount` from the DB row, but the response is cached (24 h TTL / 7 d freshness). Follows are written client-side straight to Supabase (`user_followed_artists`), so paax-api has no hook to invalidate the artist cache — a fresh fetch on a cache hit can show a count that lags the true value by up to the TTL.

**Workaround**: The artist detail screen applies an **optimistic per-screen delta** on follow/unfollow, so the visible count is correct in-session. Cross-device/other-viewer counts self-correct when the cache expires.

**Root Cause**: No cross-writer cache invalidation between the Flutter→Supabase follow path and the paax-api response cache (by design; acceptable for this phase).

---

### ISSUE-032 — Cache-source observability limited to `X-Cache` + ingest logs

**Status**: 🟡 Workaround Available · **Severity**: Low · **Affected Area**: API / Observability · **First Observed**: 2026-07-26 (Phase 3.3)

**Description**: Phase 3.3 §3 suggested explicit source labels (`memory`/`redis`/`supabase-fresh`/`supabase-stale`/`deezer-miss`/`background-refresh`). Implemented today: the `X-Cache: hit|miss|stale` header plus structured ingest timing logs (`core=…ms total=…ms discography=…`). The richer per-source labels were deferred to avoid changing the well-tested SWR cache-status enum.

**Workaround**: Use `X-Cache` + the `[ingest]` timing logs. Richer labels are a future enhancement.

---

### ISSUE-033 — Playback state truthfulness fixed in-app; audible switch needs device QA

**Status**: 🟡 Workaround Available · **Severity**: Low · **Affected Area**: Player · **First Observed**: 2026-07-27 (Phase 3.3.1)

**Description**: Phase 3.3.1 §4 added a play-transaction state machine so the UI never shows a track as "playing" before the YouTube iframe accepts the load (empty/invalid videoId → "Unable to play this track", previous track restored/re-cued, unplayable tracks skipped on auto-advance). The state logic is covered by unit tests, but **whether audio actually switches on a physical device cannot be verified in a headless environment** — it requires manual QA (e.g. JACKBOYS 2 "CHAMPAIN & VAC…": start another song, tap the affected track, confirm displayed track == audible track or the error UI shows).

**Workaround**: Manual on-device QA per the Phase 3.3.1 checklist.

---

### ISSUE-034 — Followed-artist artwork backfills on next app launch, not live

**Status**: 🟡 Workaround Available · **Severity**: Low · **Affected Area**: Home / Library · **First Observed**: 2026-07-27 (Phase 3.3.1)

**Description**: The stale-Hive artwork fix (§1) re-resolves followed-artist images during cloud hydration, which runs on session start (`onUserSession` → `hydrateFromCloud`). An artist whose stored `picture` was empty gets its image on the **next app launch / session**, not instantly within the current session.

**Workaround**: Relaunch the app (or switch account) to trigger hydration. A live refresh is a possible future enhancement.

---

### ISSUE-035 — Cross-user follower count can lag when the API cache is stale (>0 case)

**Status**: 🟡 Workaround Available · **Severity**: Low · **Affected Area**: Artist / Follow · **First Observed**: 2026-07-29 (Phase 3.3.2)

**Description**: The follower pill reconciles against local follow state (`max(base+delta, isFollowing?1:0)`), which fixes the user's own follow showing "0 Followers" while followed (the Drake case). But if the paax-api cached count is stale at a value **> 0** that excludes the user (e.g. cache 1000, real 1001) and the follow happened in a prior session (no in-session delta), the pill shows 1000, not 1001 — off by one until the API cache refreshes. Invisible at scale. Related to ISSUE-031.

**Workaround**: None needed for the reported symptom; self-corrects when the paax-api artist cache refreshes/expires.

---

### ISSUE-036 — Re-cuing a *paused* confirmed track after a failed valid video may briefly blip

**Status**: 🟡 Workaround Available · **Severity**: Low · **Affected Area**: Player · **First Observed**: 2026-07-29 (Phase 3.3.2)

**Description**: On the rare error path where the confirmed track was **paused** and the user taps a **valid-but-unavailable** video, the rollback re-cues the confirmed track via the engine's `load()` (which auto-plays), then immediately pauses — so the paused track may audibly blip for a moment. The common case (empty-id track, e.g. JACKBOYS "CHAMPAIN & VAC…") does **not** re-cue at all (the engine is never touched), so it has no blip. Avoiding the blip would require a non-autoplay `cue` path in the engine, which is out of scope for this patch ("do not change the playback engine").

**Workaround**: None; brief and rare. A `cue`-based re-cue is a possible future enhancement. **Needs on-device confirmation** (audio).

---

## ✅ Resolved Issues

*(None resolved yet — this log was seeded on 2026-07-16.)*

---

### ISSUE-021 — Artist discography empty / "Unknown Artist" placeholders

**Status**: ✅ Resolved
**Severity**: Medium
**Affected Area**: paax-api catalog ingestion (artist profile)
**First Observed**: 2026-07-17
**Resolved On**: 2026-07-17
**PR / Commit**: PR #3 · `1ef1bd1`

**Description**: `GET /v2/artists/deezer/{id}` ingested the artist but its
discography returned empty, and duplicate null-`deezer_id` "Unknown Artist" rows
accumulated (one per album).

**Root Cause**: Deezer `/artist/{id}/albums` entries often omit the nested
`artist` field; the album mapper fell back to an "Unknown Artist" placeholder, so
albums were linked to placeholders instead of the requested artist.

**Fix**: `ingest_artist_profile` injects the authoritative parent-artist context;
the album mapper uses explicit data or that context and never persists a
placeholder. Production data cleaned (Daft Punk: 38 albums relinked, 38
placeholders removed). Verified generic on Pink Floyd (64 albums, 0 placeholders).

**Residual**: none for the artist-profile flow. `mappers/deezer_common.build_track_artists`
retains a separate track-level "Unknown Artist" fallback (out of scope; tracks
reliably carry an artist) — tracked in TECH_DEBT.

---

> **Note (Phase 3.2A)**: ISSUE-022–026 above are the documented cloud-library-sync
> limitations, not bugs — they follow directly from the offline-first design
> ([decisions.md](decisions.md) ADR-011).
>
> **Note (Phase 3.2B)**: ISSUE-027–030 are the documented followed-genres +
> personalized-Home limitations, not bugs — they follow from reusing the offline-first
> pipeline for genres and building Home from deterministic client-side catalog queries
> over a still-sparse catalog ([decisions.md](decisions.md) ADR-012).

---

## Phase 3.3.6 — known limitations (2026-08-01)

- **Playlists are still device-local.** They are not yet cloud-synced (Phase 3.4).
  The Phase 3.3.6 model is cloud-*ready* but no Supabase writes occur; playlists
  and their order live in Hive only.
- **Owner username is the live profile name.** Legacy playlists store no owner
  username; the header derives it from the current signed-in profile
  (`AuthController.profile.username`). If signed out with no stored owner, the
  contributor line is hidden (only Line 3 shows).
- **Per-account pins reset on first upgrade for signed-in accounts.** Legacy flat
  pins migrate to the `_local` scope; a signed-in account starts with an empty
  per-account pin set (re-pin as needed). This is intentional to guarantee no
  cross-account leak; pins are a trivial device-local convenience.
- **Collaborators are always empty locally.** The collaborator/role/status model
  exists for Phase 3.4; there is no invitation or permission flow yet.
- **Library header inset uses a one-frame fallback.** Before the header is
  measured (`GlobalKey`), tabs use a composed fallback (`safeTop + 158 + 8`); the
  measured value refines it. The difference is sub-visible in practice.

---

## Phase 3.4.1 — known limitations (2026-08-02)

Adversarial-review HIGH + MEDIUM findings were fixed (see the review-fixes
commit). Remaining LOW items, accepted for this phase:

- **Live follower count isn't pushed to open viewers** (review L9). Following
  doesn't bump `version`, and the realtime version-guard (which prevents an
  optimistic-follow 2→1→2 clobber) drops non-version-bumping `playlists` events,
  so an open Playlist Detail reflects *others'* follows on open/resume or on the
  next content change, not instantly. A dedicated follower realtime path (like
  artists have) is a follow-on.
- **Follow/unfollow bumps `playlists.updated_at`** via the pre-existing
  `set_updated_at` trigger (L8). `last_modified_at`/`version` are correctly
  untouched, and Library sort keys on name/pinned, so impact is nil.
- **N+1 reads** on hydration and on realtime refresh (L10): `hydrateEntity` does
  tracks+collaborators+usernames per playlist; `_onRealtime` refetches on every
  event. Bounded but scales poorly with a large library / very active
  collaboration.
- **Activity metadata is visible to any viewer** of a public collaborative
  playlist (collaborator ids, rename/visibility history) — expected for public
  playlists (L11).
- **Client edit policy ignores a live `collaborative=false` toggle** (L12): an
  accepted editor's UI still offers edits after the owner disables collaboration;
  the server rejects with `FORBIDDEN` (no data risk, minor UX mismatch).
- **Hydrated (cross-device/followed/collaborating) tracks lack an artist-name
  join**, so their subtitle can be empty until edited locally.
- **A follow reflects in the Library on the next session hydration**, not
  instantly.
- **Multi-device realtime delivery and audible playback are on-device QA** — not
  verifiable headless.

### Phase 3.4.1.1 (2026-08-03)

- **Notifications are in-app only, delivered via Supabase Realtime while the app
  is open** — there is no device push (FCM/APNs), so events raised while the app
  is closed are seen on next open/refresh, not pushed.
- **Notification tap does not deep-link into the playlist** in this phase (tap =
  mark read). Opening the referenced playlist is manual.
- **"Start a Party" is a non-functional entry scaffold** (`AppConfig.partyEnabled`
  default OFF): it shows an informational prep sheet and creates nothing. There is
  no Party backend/session yet.
- **Pre-existing empty smoke test** `test/widget_test.dart` fails under headless
  `flutter test` (its `setUp` calls `Hive.initFlutter()` → `path_provider`
  `MissingPluginException`). Not introduced by this phase; the test body is
  commented out. The rest of the suite (250+) is green.

### Phase 3.4.1.2 (2026-08-04)

- **Two "uziel" accounts exist.** `iamleizu@gmail.com` (username `uziel`) is the
  active account and owns all 3 playlists; `uziel.sando@hotmail.com` (username
  `iamleizu`) has **never signed in** and owns none. Signing into the hotmail
  account shows an empty library — this is correct behavior, not a hydration bug.
- **Unfollow is silent by design** — no inbox notification (avoids
  follow/unfollow spam). Documented product decision, not a bug.
- **Notification deep-nav uses one generic "no longer available" message** for
  deleted / private-inaccessible / blocked targets (RLS collapses all three to a
  null read); distinct per-reason messages are intentionally not shown to avoid
  leaking whether a private/blocked playlist exists.
- **Follower `+1/-1` across two devices and audible playback remain on-device QA**
  — not verifiable headless.

### Phase 3.4.1.2B (2026-08-04)

- **Soft-delete keeps the row.** A deleted playlist remains in `public.playlists`
  with a non-null `deleted_at` by design. The Table Editor showing it is expected;
  the app never treats it as active. This is the delete contract, not a bug.
- **Activity timeline grouping is presentation-only.** The DB stores each event
  separately; the sheet groups adjacent same-actor/same-type track events within
  5 minutes. Group boundaries are a UI convenience, not persisted.
- **Party is still backend-less.** The track "Start a Party with this song" and
  the Library "Start a Party" are both gated by `AppConfig.partyEnabled` (OFF in
  production → hidden) and, when enabled in dev, open the informational prep sheet
  — no Party session is created (full Party not implemented).
- **On-device QA still required:** notification-tap navigation, activity-timeline
  realtime append in an open sheet, and audible playback are not verifiable
  headless.

---

*Last updated: 2026-08-04*
