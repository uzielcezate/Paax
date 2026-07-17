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

## ✅ Resolved Issues

*(None resolved yet — this log was seeded on 2026-07-16.)*

---

*Last updated: 2026-07-16*
