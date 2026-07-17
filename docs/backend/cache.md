# Cache (Backend)

> **Purpose**: Documents backend-side caching — the cache technology, keys, TTLs, and invalidation strategies used in the server layer.
> **Update when**: A new cache key is introduced, TTLs are changed, or the cache technology changes.

> **See also**: [`../CACHE_STRATEGY.md`](../CACHE_STRATEGY.md) for the full cross-layer strategy, [`../performance.md`](../performance.md) for budgets, [`services.md`](services.md) / [`repositories.md`](repositories.md) for what gets cached.

---

## Why caching is the backbone here

Because the backends are **stateless proxies with no database** ([`database-schema.md`](database-schema.md)), caching is not an optimization bolted on — it *is* the persistence story. Every request re-derives data from Deezer/YouTube; caches are what keep p95 latency and upstream cost sane, and what shield us from YouTube's aggressive bot-blocking and 429s. Four independent caches exist across the components; only paax-api's is on the live hot path.

---

## Cache Technology

| Component | Primary | Secondary | Library | Hosting |
|-----------|---------|-----------|---------|---------|
| **paax-api** | Redis (`redis.asyncio`) | in-memory LRU `MemoryCache(max_size=500)` | `redis` 5.0.8 | Railway Redis plugin (optional; `REDIS_URL`) |
| **paax-stream** | Redis (session store) | orphaned in-memory `StreamCache` | `redis` ≥5.0 | Railway Redis (`REDIS_URL`, default `redis://localhost:6379/0`) |
| **Cloudflare Worker** | `caches.default` (edge cache) | — | Workers runtime | Cloudflare edge |
| **legacy backend** | Redis + in-memory stream cache | — | `redis` 5.0.8 | Railway Redis |

- **Connection**: paax-api opens one async Redis client; if `REDIS_URL` is unset, caching degrades gracefully to the in-memory tier only (no crash).
- **Two-tier rationale (paax-api)**: Redis is shared across instances/restarts; the 500-entry in-memory LRU absorbs hot keys without a network round-trip. Reads try memory → Redis → upstream.

---

## Cache Key Naming Convention

Keys are **deterministic, normalized** strings derived from the request (entity + identifier + variant), so identical logical requests collide on the same key regardless of superficial formatting.

```
paax-api:    v2:{entity}:{id}         e.g. v2:album:302127
             match:{norm(artist,title,album,duration)}   (YouTube match cache)
paax-stream: paax:session:{ipv6}      per source-address device fingerprint
```

Every cached response carries an `X-Cache: HIT|MISS` header (paax-api) so cache behavior is observable from the client/curl without server access.

---

## Cache Key Registry

### paax-api (the live cache)

The canonical TTL table lives in [`../CACHE_STRATEGY.md`](../CACHE_STRATEGY.md); the backend-scoped summary: search **900s** (15m), home/artist/chart **21600s** (6h), album **86400s** (24h), YouTube match **604800s** (7d). **TTL jitter** of 0–60s is added to every TTL to avoid synchronized expiry stampedes (many keys expiring at once → thundering herd on Deezer/YouTube).

The distinction that only lives here (not in the canonical table) is **what** gets cached at the endpoint layer:

**Endpoint-cached** (full response cached): `/v2/artist/{id}`, `/v2/album/{id}`, `/v2/chart`, plus all v1 discovery routes.
**NOT endpoint-cached** (but their per-track matches still hit the 7-day `match:` cache): `/v2/search`, `/v2/track/{id}`, `/v2/artist/{id}/top`.

> **Why the split**: album/artist/chart are stable and heavily re-requested → cache the whole response. Search/track/top vary too much per query to cache wholesale, but the expensive part — the YouTube match — is shared across all of them via the 7-day match cache. This is the highest-leverage cache in the system: matching is the slow, fragile, rate-limited step ([`services.md`](services.md)).

### paax-stream

| Key Pattern | TTL | Invalidation | Data Stored |
|------------|-----|--------------|-------------|
| `paax:session:{ipv6}` | **1800s** (`SESSION_COOKIE_TTL`) | TTL only | Sticky device fingerprint (UA + harvested cookies) per source IPv6 |
| in-memory `StreamCache` | **600s** (`CACHE_TTL_SECONDS`) | TTL only | **ORPHANED** — belongs to the unmounted resolver stack ([`services.md`](services.md)) |

### Cloudflare Worker

| Key | TTL | Invalidation | Data Stored |
|-----|-----|--------------|-------------|
| `caches.default` keyed by request URL (videoId) | **300s** | TTL only | Resolved progressive-audio CDN URL ([`workers.md`](workers.md)) |

### legacy backend

| Key | TTL | Data Stored |
|-----|-----|-------------|
| search | 900s | ytmusicapi search |
| home | 21600s | home payloads |
| resolve | 1800s | yt-dlp stream URL |
| in-memory stream | 600s | resolved stream metadata |

---

## Cache-Aside Pattern (Standard)

paax-api uses read-through cache-aside across the two tiers. Note there is **no database fetch** — the miss path calls an **external API**, not a repository.

```python
# paax-api pattern (illustrative)
async def get_album(album_id: int):
    key = f"v2:album:{album_id}"

    # 1. memory tier
    if (hit := memory_cache.get(key)) is not None:
        return hit, "HIT"           # -> X-Cache: HIT

    # 2. redis tier
    if redis and (cached := await redis.get(key)):
        memory_cache.set(key, cached)
        return cached, "HIT"

    # 3. miss -> upstream (Deezer + eager YouTube match), then populate both tiers
    data = await hybrid_album.build(album_id)      # external API, not a DB
    ttl = 86400 + random.randint(0, 60)            # jitter
    memory_cache.set(key, data)
    if redis:
        await redis.setex(key, ttl, data)
    return data, "MISS"
```

---

## Cache Invalidation

**TTL-only. There is no explicit invalidation and no mutation to invalidate around** — the servers never write catalog data, so cached entries simply expire. This is the correct model for a read-only proxy: freshness is a function of TTL choice, not of write events.

```python
# Not applicable — there are no server-side mutations of cached catalog data.
# The only "writes" (v1 shared-account /rate, /playlists*) do NOT populate
# any read cache, so nothing needs invalidating. Catalog freshness is bounded
# by the TTLs above.
```

If Deezer/YouTube data changes, the cache heals within one TTL window (24h worst case for albums). That staleness is acceptable for a music catalog.

---

## Rate Limiting via Cache

**Not applicable — no rate limiting is implemented on any Paax endpoint** ([`controllers.md`](controllers.md)). There is no `rate:limit:*` key.

- **Nearest real analog**: paax-api's own **outbound** protection — the 7-day match cache + `asyncio.Semaphore(3/5)` throttle how often *we* hit YouTube ([`services.md`](services.md)) — and the Flutter client's image-throttling layer that backs off on upstream 429s. These protect upstreams, not our own endpoints.
- Adding inbound rate limiting (e.g. a Redis fixed/sliding-window counter) is a documented gap in [`../security.md`](../security.md), especially given the expensive matching routes.

---

## Cache Health

- **Observability**: `X-Cache: HIT/MISS` header on every paax-api response; `GET /cache/status` returns the active backend + entry stats.
- **Degradation**: if Redis is unavailable, paax-api falls through to the in-memory tier and ultimately to upstream — it **does not crash**. This matches the template's "fall through, log, don't crash" rule.
- **No monitoring/alerting stack is wired** (no Datadog/Sentry). Hit-rate and memory alerts described in the template are aspirational — see [`../performance.md`](../performance.md).

---

## Phase 2 target (ADR-009) — planned, NOT implemented

With the Supabase catalog deployed ([`database-schema.md`](database-schema.md)), Phase 2 moves metadata freshness from pure Redis TTLs to a **persistent catalog + staleness model**. Target TTLs (computed from `metadata_updated_at` / `youtube_match_updated_at`):

| Data | Target TTL |
|------|-----------|
| Artist metadata | 7 d |
| Album metadata | 30 d |
| Track metadata | 30 d |
| Home / charts | 1–3 h |
| Search cache | 15–60 min |
| YouTube mapping | 30 d, or until playback verification fails |

Documented ingestion model: Flutter → backend → **Supabase check** → fresh returns immediately / stale returns **and** schedules a refresh → Deezer upsert → relationship reconciliation → missing YouTube IDs queued for matching → **Redis dedups refresh jobs**. **Redis job infrastructure is NOT implemented yet** — everything above this section remains the live caching behavior.

---

*Last updated: 2026-07-16*
