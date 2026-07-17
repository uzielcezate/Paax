# Optimization Log

> **Purpose**: A chronological record of performance optimizations — what was measured, what was changed, and what the result was. Prevents redundant optimization work and provides a baseline for future comparisons.
> **Update when**: A performance optimization is implemented and verified with measurements.

---

## Why This File Exists

Optimization without measurement is guesswork. This log enforces the rule: **profile before optimizing, measure after**. Every entry should include "before" and "after" metrics.

> **Honesty note**: Paax has **no formal metrics pipeline** (no APM, no captured Flutter DevTools traces stored in the repo). The optimizations below were made deliberately and are real, but their impact is described **qualitatively** — most entries state "no formal metrics captured." This is itself a debt item (see [tech debt](TECH_DEBT.md)); establishing baselines is tracked in [ideas](IDEAS.md). Do not invent numbers.

---

## Entry Template

```markdown
### OPT-XXX — <Title>

**Date**: YYYY-MM-DD
**Author**: <!-- Name or Agent -->
**Area**: <!-- Frontend / Backend / Database / Network / Build -->
**Type**: <!-- Query | Rendering | Caching | Algorithmic | Payload | Build -->
**PR / Commit**: <!-- Link or hash -->

**Problem**:
**Measurement Method**:
**Before**:
**Change Made**:
**After**:
**Notes**:
```

---

## Log Entries

---

### OPT-001 — Two-tier Redis + in-memory response cache (paax-api)

**Date**: 2026-07-16 (documented; implemented earlier — see [changelog](CHANGELOG.md))
**Author**: Team
**Area**: Backend / Network
**Type**: Caching
**PR / Commit**: Early "Redis caching + env-based API config" phase

**Problem**: Every request re-hit Deezer and, worse, re-ran `yt-dlp ytsearch` for YouTube matching — the single most expensive operation in the system (network + subprocess, per track, concurrency-limited).

**Measurement Method**: No formal metrics captured. Reasoned from operation cost (a cold `/v2/search` fans out to N per-track matches at 15s timeout each, `Semaphore(3)`).

**Before**: Cold and warm requests cost the same — full Deezer fetch + full match fan-out every time.

**Change Made**: Added `cache.py`: two-tier `redis.asyncio` (primary) + `MemoryCache(max_size=500)` LRU. TTLs — search 900s, home/artist/chart 21600s, album 86400s, **YouTube match 604800s (7d)**. Deterministic normalized keys, 0–60s TTL jitter to avoid synchronized expiry storms, `X-Cache: HIT/MISS` header. See [cache strategy](CACHE_STRATEGY.md).

**After**: Warm requests serve from cache; repeated tracks reuse the 7-day match result, eliminating the dominant cost. No formal metrics captured, but the qualitative effect is large because matching dominates latency.

**Notes**: `/v2/search`, `/v2/track`, `/v2/artist/{id}/top` are intentionally not endpoint-cached — their per-track matches already hit the 7-day match cache.

---

### OPT-002 — Image request throttling, queueing, and domain sharding (fight HTTP 429)

**Date**: 2026-07-16 (documented; implemented across image phases)
**Author**: Team
**Area**: Frontend / Network
**Type**: Payload / Rendering
**PR / Commit**: "Phase 3 image caching" and later

**Problem**: YouTube artwork hosts (`lh3-lh6.googleusercontent.com`) and Deezer covers aggressively return **HTTP 429** under bursty parallel loads — worst on Flutter Web, which issues its own requests and keeps no disk image cache. Artwork flashed placeholders and load stalled.

**Measurement Method**: Observed 429 responses in the browser network panel. No formal metrics captured.

**Before**: Uncontrolled parallel image loads → frequent 429s → visible placeholder flashing and slow grids.

**Change Made**: Layered defense —
- `ImageRequestQueue`: web `maxConcurrent=1`, mobile 4; per-priority queues (onScreen / nearScreen / offScreen); **global pause on 429**.
- `HostThrottleState`: per-host exponential backoff 2s→60s + jitter.
- `Lh3UrlBuilder`: strict `=w-h` sizing (fetch exactly the needed resolution) + **domain sharding** lh3→lh3/4/5/6 by `url.hashCode % 4` to spread load across hostnames.
- `ImagePipeline` / `PlatformCacheManager` (flutter_cache_manager): web memory-only vs mobile disk 30d.
- `VisibilityDetector` gating so only on-screen images load.
- Deprecated `thumbnail_prefetcher` (off-screen prefetch *caused* 429s).

**After**: 429 storms largely tamed; grids settle without placeholder flashing on mobile and are far more stable on web. No formal metrics captured.

**Notes**: Two overlapping generations (`core/image/*` vs `core/network/*`) coexist — consolidation is pending. See [known issues](KNOWN_ISSUES.md) ISSUE-008 and [tech debt](TECH_DEBT.md).

---

### OPT-003 — High-frequency `ValueNotifier`s for playback position/duration

**Date**: 2026-07-16 (documented)
**Author**: Team
**Area**: Frontend
**Type**: Rendering
**PR / Commit**: Player UI phases

**Problem**: Playback position updates arrive many times per second. Driving them through the main `PlaybackController` `ChangeNotifier` would rebuild every `Consumer` of playback state on each tick — expensive and janky.

**Measurement Method**: Reasoned from Flutter rebuild semantics; no formal metrics captured.

**Before**: A naive design rebuilds the whole player subtree on every position tick.

**Change Made**: `PlaybackController` exposes dedicated `positionNotifier` / `durationNotifier` (`ValueNotifier`) that only the progress bar listens to via `ValueListenableBuilder`. Position stream is **throttled to 250ms** before it drives media-session/UI. The progress bar (`SmoothAudioProgressBar`) interpolates at 60fps with a `Ticker` between those coarse updates for smoothness without extra rebuilds.

**After**: Position updates repaint only the progress bar, not the player/track UI. Smooth 60fps scrubber with minimal rebuild cost. No formal metrics captured.

**Notes**: Aligns with [`.claude/rules/flutter.md`](../.claude/rules/flutter.md) ("targeted state management", "avoid rebuilding the entire widget tree").

---

### OPT-004 — Two-phase artist screen rendering

**Date**: 2026-07-16 (documented)
**Author**: Team
**Area**: Frontend / Network
**Type**: Rendering / Payload
**PR / Commit**: `11a61f2` "Phase 3: Artist Profile perf …", `5c4ede8`

**Problem**: The artist screen needs a lot of data (profile, popular, latest, albums, singles/EPs, related). Waiting for all of it before painting left the screen blank for too long.

**Measurement Method**: Perceived load time; no formal metrics captured.

**Before**: Single blocking fetch — nothing rendered until everything resolved.

**Change Made**: Render in two phases — paint **basic** artist info immediately, then **enrich** (populate release sections) in a second pass. Related earlier work enriched releases from top tracks via `/album/{id}` fetches; in v2 this is unnecessary because Deezer already provides dates/types (`enrichArtistReleases` is a no-op in v2).

**After**: Artist screen paints fast with progressive fill, matching the "progressive loading" UX rule. No formal metrics captured.

**Notes**: See [`.claude/rules/ux.md`](../.claude/rules/ux.md) ("show what you have while fetching the rest").

---

### OPT-005 — In-memory album-detail cache (client)

**Date**: 2026-07-16 (documented)
**Author**: Team
**Area**: Frontend
**Type**: Caching
**PR / Commit**: Repository layer

**Problem**: Re-opening an album refetched its detail from paax-api every time, adding latency and load.

**Change Made**: `MusicRepositoryImpl` holds a process-lifetime `Map<albumId, AlbumDetail>` cache. Re-opening a previously viewed album serves instantly from memory.

**After**: Instant re-open for visited albums within a session. No formal metrics captured. (No TTL — cleared on restart; see [cache strategy](CACHE_STRATEGY.md).)

---

### OPT-006 — `IndexedStack` tab keep-alive + instant Android transitions

**Date**: 2026-07-16 (documented)
**Author**: Team
**Area**: Frontend
**Type**: Rendering
**PR / Commit**: `MainWrapper` shell

**Problem**: Rebuilding tab contents (and losing scroll position) on every tab switch is slow and violates the "do not reset scroll position" UX rule.

**Change Made**: `MainWrapper` hosts the 4 tabs in an `IndexedStack`, keeping each tab's nested `Navigator` and scroll state alive across switches. Android page transitions are made instant via `_FastPageTransitionBuilder` (returns the child unchanged), removing transition latency.

**After**: Tab switches are instant and preserve state/scroll. No formal metrics captured.

**Notes**: Trade-off — all 4 tabs stay in memory. Acceptable for a 4-tab shell.

---

### OPT-007 — 7-day YouTube match cache (algorithmic cost avoidance)

**Date**: 2026-07-16 (documented)
**Author**: Team
**Area**: Backend
**Type**: Caching / Algorithmic
**PR / Commit**: `cache.py`

**Problem**: Matching a Deezer track to a YouTube `videoId` runs `yt-dlp ytsearch` + scoring (duration ±60s, difflib title similarity, artist match, trust signals) — slow and rate-limit-prone. The mapping is highly stable over time.

**Change Made**: Cache match results for **604800s (7 days)** keyed on normalized `artist:title:album:duration`, backed by Redis + `MemoryCache(500)`. Concurrency bounded by `asyncio.Semaphore(3)` (charts `Semaphore(5)`), per-track timeout 15s (main) / 30s (hybrid).

**After**: Recurring tracks (charts, popular catalog, re-searches) skip matching entirely for a week. Largest single lever on p95 for warm data. No formal metrics captured.

**Notes**: Downside — a bad match is pinned for 7 days with no targeted invalidation. See [known issues](KNOWN_ISSUES.md).

---

### OPT-008 — IPv6 source rotation for CDN byte proxy (paax-stream)

**Date**: 2026-07-16 (documented)
**Author**: Team
**Area**: Backend / Network
**Type**: Algorithmic (anti-rate-limit)
**PR / Commit**: paax-stream "Phase 8 Hybrid Proxy"

**Problem**: Datacenter IPs get bot-blocked / rate-limited by YouTube's CDN. A single source IP quickly hits 429/403.

**Change Made**: The `/stream` proxy rotates across **16 local IPv6 source addresses** (a /124 block), each with a sticky device fingerprint (random UA + harvested cookies) cached in Redis (`paax:session:<ipv6>`, TTL 1800s). `httpx` binds sockets to a specific source via `AsyncHTTPTransport(local_address=ipv6)`, HTTP/2 on, 64 KiB chunks, Range/206 support.

**After**: Per-IP CDN limits are spread across the pool, reducing 429/403 on the (non-live) resolver path. No formal metrics captured.

**Notes**: This path is **deployed but not consumed by the live app**, which plays `videoId` directly via the YouTube IFrame. Documented so the technique is not lost. See [architecture](architecture.md) and [cache strategy](CACHE_STRATEGY.md).

---

### OPT-009 — Edge stream-URL cache (Cloudflare Worker)

**Date**: 2026-07-16 (documented)
**Author**: Team
**Area**: Network / Edge
**Type**: Caching
**PR / Commit**: `cloudflare-worker/`

**Problem**: Resolving a `videoId` to a progressive-audio CDN URL via the Innertube client waterfall is repeated work for popular tracks.

**Change Made**: Cache the resolved URL in `caches.default` with a **300s** TTL at the edge, keyed by the request. Client waterfall ANDROID→ANDROID_VR→ANDROID_TESTSUITE→TVHTML5_SIMPLY_EMBEDDED→IOS, preferring itag 140.

**After**: Popular `videoId`s resolve from the edge cache within the 5-minute window. No formal metrics captured.

---

## Performance Baseline

No baseline has been formally captured yet. Establishing one (API p50/p95, app cold start, screen transition time, image-grid settle time) is a prerequisite for future quantified entries.

| Metric | Baseline Value | Measured On | Method |
|--------|---------------|-------------|--------|
| paax-api p50/p95 latency | Not measured | — | (target: APM / access-log analysis) |
| App cold start | Not measured | — | (target: Flutter DevTools) |
| Screen transition time | Instant on Android (by design) | 2026-07-16 | Qualitative (`_FastPageTransitionBuilder`) |
| Cache hit rate | Not measured | — | (target: aggregate `X-Cache` headers) |

See budgets/targets in [performance](performance.md).

---

## Summary Statistics

| Period | Optimizations Done | Best Improvement |
|--------|------------------|-----------------|
| Through 2026-07-16 | 9 logged (backfilled from git history + code) | 7-day match cache (largest qualitative win); no formal metrics captured |

---

*Last updated: 2026-07-16*
