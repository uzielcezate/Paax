# Cache Strategy

> **Purpose**: Documents every caching layer in the system — what is cached, where, for how long, and how it is invalidated. Agents must read this before adding, modifying, or removing caching logic.
> **Update when**: A new cache layer is added, a TTL is changed, an invalidation strategy changes, or a caching bug is discovered.

---

## Caching Principles

1. **Cache close to the consumer.** Cache at the layer closest to where data is consumed.
2. **Define TTL explicitly.** Every cache entry must have a finite lifetime. No indefinite caching.
3. **Define invalidation clearly.** Know exactly when and how each cache entry becomes invalid.
4. **Cache the right thing.** Cache the output of expensive operations — not inputs.
5. **Measure cache effectiveness.** Track hit rate; low hit rate may indicate wrong caching strategy.

Two facts shape everything below. First, **Paax has no relational database** — all user state lives client-side in Hive, and the backends are stateless metadata/stream proxies whose only persistence *is* cache. Caching is therefore not an optimization bolted onto a database; it is the primary mechanism that keeps the product responsive against slow third-party sources (Deezer, YouTube/`yt-dlp`, LRCLIB). Second, the most expensive operation in the whole system is the **YouTube match** (running `yt-dlp ytsearch` to turn a Deezer track into a playable `videoId`); its 7-day cache is the single highest-value cache in the project. See [architecture](architecture.md) and the hybrid pipeline in [api](api.md).

---

## Cache Layers Overview

| Layer | Technology | Purpose |
|-------|-----------|---------|
| Edge (CDN) | Cloudflare Worker `caches.default` | Caches resolved YouTube progressive-audio CDN URLs at the edge (300s) — `stream.paaxmusic.app` |
| Server-side (metadata) | Redis (`redis.asyncio`) + in-memory `MemoryCache(500)` LRU — paax-api | Two-tier cache of Deezer metadata and, critically, YouTube match results |
| Server-side (stream sessions) | Redis — paax-stream | Per-IPv6 device fingerprint/cookie sessions for the byte proxy (`paax:session:<ipv6>`, 1800s) |
| Server-side (legacy) | Redis + in-memory — `backend/` | Superseded v1 response + resolved-stream cache (see [known issues](KNOWN_ISSUES.md)) |
| Mobile/Web in-memory | Dart maps + `flutter_cache_manager` memory store | Album-detail cache, lyrics cache, decoded-image cache |
| Mobile disk | `flutter_cache_manager` (`PlatformCacheManager`) | Downloaded image bytes, 30-day retention (mobile only; web is memory-only) |
| Client persistent store | Hive (9 boxes) | **Not a cache** — this is the authoritative user data store (library, playlists, profile, settings). See note below. |

> **Hive is a data store, not a cache.** The user's library, playlists, liked tracks, followed artists, recently played, and settings persist in Hive with *no TTL and no invalidation* — losing them is data loss, not a cache miss. It is listed here only so readers do not mistake it for a cache and add eviction to it. See [database](database.md).

---

## Cache Registry

> One row per distinct cached item. This is the authoritative record of what is cached. Source files: `paax-api/cache.py`, `paax-stream/app/`, `cloudflare-worker/`, `frontend/lib/core/image/`, `frontend/lib/data/`.

| Cache Key Pattern | Layer | TTL | Invalidation Trigger | Data Cached |
|------------------|-------|-----|---------------------|-------------|
| `search:<normalized-q>:<type>:<limit>` | paax-api Redis + Memory | **900s** (15m) + jitter 0–60s | TTL expiry only | `/v2/search` results (also v1 `/search`) |
| `home` / `home:discover` / `moods…` | paax-api Redis + Memory | **21600s** (6h) + jitter | TTL expiry only | v1 discovery feeds |
| `artist:<id>` (`/v2/artist/{id}`) | paax-api Redis + Memory | **21600s** (6h) + jitter | TTL expiry only | Deezer artist profile |
| `chart:<country>` (`/v2/chart`, v1 `/charts`) | paax-api Redis + Memory | **21600s** (6h) + jitter | TTL expiry only | Chart/top lists |
| `album:<id>` (`/v2/album/{id}`) | paax-api Redis + Memory | **86400s** (24h) + jitter | TTL expiry only | Album + track list |
| `match:<artist>:<title>:<album>:<duration>` | paax-api Redis + Memory | **604800s** (7d) + jitter | TTL expiry only | Resolved YouTube `videoId` + confidence/score — the most valuable cache |
| `paax:session:<ipv6>` | paax-stream Redis | **1800s** (30m) | TTL expiry; recreated per source IPv6 on next request | Sticky device fingerprint: random UA + harvested YouTube cookies |
| `<cdn_url>` (implicit key) | Cloudflare Worker `caches.default` | **300s** (5m) | TTL expiry only | Resolved progressive-audio CDN URL for a `videoId` |
| v1 `search:*` / `home:*` / `resolve:<videoId>` | legacy `backend/` Redis + Memory | 900s / 21600s / 1800s (+ 600s in-memory stream) | TTL expiry only | Superseded — do not extend |
| album-detail (`Map<albumId, AlbumDetail>`) | Flutter in-memory (`MusicRepositoryImpl`) | Process lifetime (no TTL) | Cleared on app restart | Fetched album detail objects, to avoid refetch on re-open |
| lyrics (`Map<videoId, …>`) | Flutter in-memory (`LyricsService`) | Process lifetime (no TTL) | Cleared on app restart | Fetched `/lyrics` payloads |
| image bytes (`Lh3UrlBuilder` sized URL) | Flutter `flutter_cache_manager` | Mobile disk **30 days**; web memory-only (session) | LRU / cache-manager policy | Decoded/downloaded artwork bytes |
| decoded image (`ImagePipeline` / web memory) | Flutter in-memory | Process lifetime | Memory pressure eviction | Decoded image for fast re-paint |

**Cache key construction (paax-api).** Keys are deterministic and normalized (lowercased/trimmed query params) so semantically identical requests collapse onto one entry. A **0–60s random jitter** is added to every TTL to avoid a synchronized "thundering herd" of expirations hammering Deezer/`yt-dlp` at the same instant. Every cached response carries an `X-Cache: HIT|MISS` header for observability.

**What is NOT endpoint-cached.** `/v2/search`, `/v2/track/{id}`, and `/v2/artist/{id}/top` are deliberately not cached at the endpoint level, because their per-track YouTube matches already hit the 7-day `match:*` cache — the expensive part is memoized even when the envelope is recomputed. `/v2/artist/{id}`, `/v2/album/{id}`, `/v2/chart`, and all v1 discovery endpoints *are* endpoint-cached.

---

## Invalidation Strategies

Paax caching is **overwhelmingly TTL-based (passive)**. There is no server-side event bus and no relational source of truth to invalidate against — the "source of truth" for metadata is a third-party API (Deezer), so the only correctness question is staleness tolerance, which is encoded directly in the TTLs above.

### TTL-Based (Passive)

Items expire after a fixed time; no active invalidation. This is the strategy for **every server and edge cache** in Paax.
- Best for: Data that changes infrequently or where slight staleness is acceptable.
- Examples: Album metadata (24h) — album track lists effectively never change. Charts/home (6h) — refreshed a few times a day. YouTube match (7d) — a track's best video match is extremely stable, and re-matching is the most expensive operation in the system, so a long TTL is a deliberate cost decision.

### Event-Based (Active)

- Not used server-side. The only "event-driven freshness" is client-side: Hive mutations (like/unlike, playlist edits) update the persistent store immediately and notify listeners via `ChangeNotifier`. This is state mutation, not cache invalidation.

### Cache-Aside

The pattern used throughout paax-api and the legacy backend:
```
value = await cache.get(key)          # Redis, then MemoryCache(500)
if value is None:                     # X-Cache: MISS
    value = await fetch_from_source() # Deezer / yt-dlp / LRCLIB
    await cache.set(key, value, ttl=TTL + jitter(0, 60))
return value                          # X-Cache: HIT on subsequent calls
```
Reads consult Redis first (primary), then the in-memory `MemoryCache(max_size=500)` LRU as a hot second tier; on total miss the source is queried and both tiers are populated.

### Write-Through

- Not applicable — there are no server-side writes to a cached data source. (Server-authenticated `/rate` and `/playlists*` mutate a single shared YTMusic account, not a cache; see [security](security.md).)

---

## Cache Failure Handling

- **Cache miss**: Fall through to the source of truth (Deezer / `yt-dlp` / LRCLIB / Innertube). Never fail the request on a miss.
- **Redis unavailable**: `REDIS_URL` is **optional** for paax-api and the legacy backend. If Redis is unset or unreachable, caching degrades to the in-memory `MemoryCache(500)` LRU (paax-api) or is effectively off. Requests still succeed, latency rises, and third-party load increases. For **paax-stream**, Redis is required-ish: without it, per-IPv6 device sessions cannot persist, weakening the anti-bot fingerprint stickiness (defaults to `redis://localhost:6379/0`).
- **Edge (Worker) miss/error**: The Worker re-resolves the stream URL via the Innertube client waterfall; `caches.default` is best-effort.
- **Cache corruption**: Entries are self-describing JSON with finite TTL; a bad entry expires on its own. Manual remedy is flushing the affected key(s) and letting the next read repopulate.

---

## Cache Monitoring

There is **no formal cache metrics pipeline today** (no Datadog/Sentry-Performance cache dashboards — see the TODOs in [performance](performance.md)). The observability that exists:

| Metric | Tool | Alert Threshold |
|--------|------|----------------|
| Hit/miss per request | `X-Cache: HIT\|MISS` response header (paax-api) | None wired — inspect manually |
| Redis health | Railway Redis plugin metrics / `redis-cli INFO` | None configured |
| Memory-cache size | `MemoryCache(max_size=500)` LRU cap (self-bounding) | N/A — hard-capped at 500 entries |
| `X-Cache` / `X-Provider` / `X-Proxy-IPv6` | paax-stream response headers | None wired — inspect manually |

Establishing real hit-rate monitoring is tracked as a follow-up (see [tech debt](TECH_DEBT.md) and [ideas](IDEAS.md)).

---

## Known Cache Bugs / Gotchas

- **Unbounded YouTube match memory cache (legacy path).** The historical in-process match cache could grow without bound; the live paax-api path bounds it via `MemoryCache(max_size=500)` + Redis TTL, but any code path that memoizes matches in a plain dict must adopt the same cap. Tracked in [known issues](KNOWN_ISSUES.md).
- **In-memory tiers do not survive restarts or scale horizontally.** `MemoryCache(500)`, the Flutter album/lyrics maps, and web image memory cache are per-process/per-session. On Railway with `restartPolicyType=ON_FAILURE`, a restart cold-starts them; only Redis and disk survive.
- **Match cache can pin a bad match for 7 days.** If a track resolves to a wrong/low-quality `videoId`, that decision is cached for a week. There is no targeted invalidation — the workaround is to change the normalized match key inputs or wait out the TTL.
- **Web image cache is memory-only.** Flutter Web keeps no disk image cache, so a hard refresh re-downloads artwork — which is exactly the burst that triggers HTTP 429 from `lh3-lh6.googleusercontent.com`. This is why the image throttling system (`ImageRequestQueue`, `HostThrottleState`) exists; see [performance](performance.md) and [optimization log](OPTIMIZATION_LOG.md).

See also: [`.claude/rules/backend.md`](../.claude/rules/backend.md), [`.claude/rules/performance.md`](../.claude/rules/performance.md), [environment](environment.md), [deployment](deployment.md).

---

## Missing / Recommended Caches (Architecture Review, 2026-07-16)

Gaps identified in the [Architecture Review](architecture-review.md) §5:

| Gap | Recommendation | ID |
|-----|----------------|----|
| `/v2/search`, `/v2/track`, `/v2/artist/{id}/top`, `/lyrics` are not endpoint-cached | Add TTL caching (short for search, long for lyrics — they're stable) | `AR-CACHE-01` |
| No `Cache-Control`/`ETag` headers → browsers/Cloudflare can't cache | Emit cache headers matching internal TTLs; put metadata GETs behind Cloudflare edge cache | `AR-CACHE-02` |
| Client metadata cache is in-memory only (lost on restart); `stream_candidates` box unused | Persist a bounded recently-viewed cache to Hive for instant cold start + offline browse | `AR-CACHE-03` |
| No image proxy/CDN → forces client 429 throttling | Edge image-resize proxy (Cloudflare Images / Worker) to cache + resize artwork | `AR-CACHE-04` |
| No negative caching for transient upstream 5xx | Short-TTL negative cache | `AR-CACHE-05` |

Full detail: [architecture-review.md](architecture-review.md#5-missing-cache).

---

## Phase 2 target (ADR-009) — planned, NOT implemented

The Supabase Phase 1 foundation ([backend/database-schema.md](backend/database-schema.md), [decisions.md](decisions.md) ADR-009) adds a **persistent catalog** that Phase 2 will put in front of Deezer/YouTube, replacing pure TTL expiry with staleness computed from `metadata_updated_at` / `youtube_match_updated_at`:

| Data | Target TTL |
|------|-----------|
| Artist metadata | 7 d |
| Album metadata | 30 d |
| Track metadata | 30 d |
| Home / charts | 1–3 h |
| Search cache | 15–60 min |
| YouTube mapping | 30 d, or until playback verification fails |

Documented ingestion model: Flutter → backend → **Supabase check** → fresh returns immediately / stale returns **and** schedules a refresh → Deezer upsert → relationship reconciliation → missing YouTube IDs queued for matching → **Redis dedups refresh jobs**. **The Redis job layer is NOT implemented** — the registry above remains the authoritative record of live caching until Phase 2 ships.

---

*Last updated: 2026-07-16*
