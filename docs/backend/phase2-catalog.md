# Phase 2 — Supabase-first Catalog Backend (`paax-api`)

> **Status**: Implemented + deployed (ADR-009 Phase 2 / ADR-010). Backend-only.
> Flutter still uses the legacy `/v2/*` endpoints; it adopts the normalized ones
> in Phase 3. The YouTube IFrame engine is unchanged.

The catalog read flow:

```
Flutter → paax-api → Redis response cache
  ↓ miss
Supabase persistent catalog
  ↓ missing/stale
Deezer API → normalize + reconcile graph → Supabase transactional upsert
  ↓
Redis cache → normalized response
```

YouTube is only the playback-ID provider (matched IDs stored on `tracks`, audio
bytes never stored). Deezer metadata is canonical for names, art, titles,
durations, explicit flags, track numbers, album type, credits, and genres.

## Layout (`paax-api/`)

| Package | Responsibility |
|---------|----------------|
| `config.py` | Env-driven settings (TTLs, freshness, concurrency, artwork, limits) |
| `repositories/supabase_client.py` | One shared async gateway (service-role, injectable) + Storage upload |
| `repositories/catalog/` | artist/album/track/genre/search repos; batched (non-N+1) graph loads; YT-match writes |
| `schemas/catalog/` | Domain graphs + normalized camelCase API models; vocab pinned to DB CHECKs |
| `mappers/` | row→graph, graph→response, Deezer→payload, discovery items |
| `ingestion/` | `CatalogIngestionService` + `relationship_reconciler` |
| `cache/` | `store` (Redis+memory), `cache_keys`, `cache_policy`, `distributed_lock`, `response_cache` |
| `services/catalog/` | `CatalogService` (SWR), `SearchService`, `HomeService`, `PlaybackMatchingService`, `jobs` |
| `services/youtube/` | `candidate_classifier`, `track_matcher` (persistent matcher, Phase 2.4) |
| `services/artwork/` | `ArtworkService` (download→WebP→Storage) |
| `services/rate_limit.py` | Redis fixed-window limiter (degrades open) |
| `observability.py` | correlation IDs + structured logging |
| `app_container.py` | builds the service graph once at startup |
| `api/v2_catalog_router.py` | normalized `/v2/*` endpoints |

## Database (RPCs, migrations)

Migrations live in the repo-root `supabase/migrations/` (single canonical
history, mirrored 1:1 with the live project):

- `20260717082812_catalog_phase2_1_match_types_and_search` — `tracks.youtube_audio_match_type`
  / `youtube_music_video_match_type` (+CHECKs); `catalog_normalize(text)`;
  `catalog_search(type,query,limit,offset)` (service-role only).
- `20260717145607_catalog_phase2_2_ingestion_upserts` — atomic
  `catalog_upsert_{artist,album,track}_graph(jsonb)` (+ private helpers,
  service-role only). Invariants: preserve `youtube_*` + cached artwork; never
  downgrade `full`→`partial`; bump `metadata_updated_at` only on `full`; prune
  junctions only when the payload is `complete`.

## Cache key registry & TTLs

Keys are built only via `cache/cache_keys.py::CacheKeys`.

| Key | TTL (default) |
|-----|---------------|
| `catalog:artist:{id}` / `catalog:artist:deezer:{id}` | 24h |
| `catalog:artist:{id}:discography` | 6h |
| `catalog:album:{id}` / `:deezer:{id}` | 24h |
| `catalog:track:{id}` / `:deezer:{id}` | 24h |
| `search:{type}:{query}:{limit}:{offset}` | 30m |
| `home:chart:{country}:{limit}` | 2h |
| `youtube:match:{track_id}` | 14d |
| `negative:deezer:{type}:{id}` | 5m |
| `lock:ingest:{type}:{id}` / `lock:refresh:{type}:{id}` | 30s |
| `ratelimit:{bucket}:{client}` | window |

Supabase freshness windows (trigger background refresh): artist 7d, album/track 30d.

## Endpoints (normalized, additive)

Legacy `/v2/artist|album|track|search|chart|match` are unchanged. New:

```
GET  /v2/artists/{artist_id}                     (internal UUID)
GET  /v2/artists/deezer/{deezer_id}              (ingest-on-miss)
GET  /v2/artists/{artist_id}/discography
GET  /v2/artists/{artist_id}/top
GET  /v2/albums/{album_id}
GET  /v2/albums/deezer/{deezer_id}
GET  /v2/tracks/{track_id}
GET  /v2/tracks/deezer/{deezer_id}
POST /v2/tracks/{track_id}/resolve-playback          (rate-limited 30/min)
POST /v2/tracks/{track_id}/report-playback-failure   (rate-limited 20/min)
GET  /v2/find    ?q=&type=tracks|albums|artists      (normalized search; 60/min)
GET  /v2/home    ?country=&limit=                    (normalized chart/home)
```

`/v2/find` and `/v2/home` are the normalized discovery/home surfaces (named to
avoid clobbering the live `/v2/search` and `/v2/chart`). `X-Cache: hit|miss|stale`
is returned on cached reads. Missing → 404; ingesting → 503+`Retry-After`;
upstream degraded → 503; Supabase not configured → 503.

## Playback selection (mandatory rule, Phase 2.4)

`preferred_youtube_video_id` = audio slot (Topic/official-audio/album-art, then
lyric-video); the official music video is stored as the secondary
`youtube_music_video_id`. Preferred falls back to the MV only when no valid
audio exists, and a valid audio preferred is **never** replaced by a later MV.
Both IDs and their `youtube_*_match_type` are persisted. Renditions (live, cover,
remix/sped/slowed/nightcore/karaoke/reaction/instrumental) absent from the Deezer
title are rejected.

## Errors

Normalized Deezer errors (`services/deezer/errors.py`): 404→NotFound,
403/5xx→Unavailable(503), 429→RateLimited(+Retry-After), timeout→504, malformed
→502, including Deezer's HTTP-200-with-`error`-body quirk. A Deezer 403/429 on
home serves stale cache + opens a short circuit-breaker cooldown (never a
blanket 500). Raw stack traces are never returned to Flutter.

## Health

`GET /health` → `{ok, status: healthy|degraded|unavailable, authenticated,
dependencies:{supabase,redis,deezer,matcher}}`. No secrets/connection strings.
Degraded = Supabase not ready or Redis down (legacy endpoints still serve).

## Security

Service-role key is backend-only (env, never logged/returned). All catalog-write
RPCs are `service_role`-only (revoked from anon/authenticated). Artwork download
is host-allowlisted (Deezer CDN), size/timeout capped, MIME+image validated,
entity-scoped destination paths. TLS verification enabled on all clients.
Rate limiting on expensive endpoints. Correlation IDs on every request/log.

## Discography attribution (Phase 2.6)

Deezer `/artist/{id}/albums` entries frequently omit the nested `artist` field.
`ingest_artist_profile` therefore injects the authoritative parent-artist context
(deezer_id + canonical name) into each album graph, and `_album_artists` /
`album_graph_payload` accept `artist_context`: explicit Deezer album-artist data
is used and preserved (deduped); otherwise the parent context is used; when
neither exists the album graph carries **no** album artists and is marked
`partial`. A null-`deezer_id` "Unknown Artist" catalog row is **never** persisted
from this flow. This keeps the `artist_discography` / `artist_latest_release`
views populated and correctly sorted (`release_date desc nulls last`).

See also: [CACHE_STRATEGY.md](../CACHE_STRATEGY.md), [api.md](../api.md),
[security.md](../security.md), [decisions.md](../decisions.md) ADR-009/ADR-010.
