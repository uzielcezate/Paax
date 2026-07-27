# API Reference

> **Purpose**: Single source of truth for all API endpoints — request/response shapes, authentication requirements, versioning, and error codes. Agents must update this file whenever an endpoint is added or changed.
> **Update when**: Any endpoint is added, modified, deprecated, or removed.

---

## API Overview

Paax has **three HTTP surfaces**. The client (`YouTubeMusicDataSource`) talks almost exclusively to **paax-api**.

| Surface | Base URL (prod) | Role |
|---------|-----------------|------|
| **paax-api** | `https://api.paaxmusic.app` | Metadata, search, discovery, lyrics (the live client API) |
| **cloudflare-worker** | `https://stream.paaxmusic.app` | Resolve a `videoId` → direct audio CDN URL (Innertube) |
| **paax-stream** | `https://resolver.paaxmusic.app` | IPv6 audio **byte proxy** (deployed, not used by the app today) |

- **Protocol**: REST over HTTPS, `application/json`.
- **Authentication**: **None** for client-facing endpoints. paax-api's *authenticated* library endpoints use a single server-side YouTube Music account (`YTMUSIC_OAUTH_JSON`), not per-user auth — see [Authentication](#authentication) and [security.md](security.md).
- **Rate Limiting**: Not enforced by our services (a known gap — see [KNOWN_ISSUES.md](KNOWN_ISSUES.md)). Upstream Deezer is retried on `429`.
- **CORS**: paax-api allows configured `FRONTEND_ORIGINS` plus always-permits localhost / `10.0.2.2` / LAN ranges via regex; `allow_credentials=True`.

See also [backend/controllers.md](backend/controllers.md) (handler mapping), [backend/services.md](backend/services.md) (implementation), [backend/cache.md](backend/cache.md) (caching), and [ERROR_CODES.md](ERROR_CODES.md).

---

## Versioning

paax-api runs **two endpoint generations in one app**:

- **v1** (no prefix): thin proxy over `ytmusicapi` (YouTube Music). Legacy; still mounted.
- **v2** (`/v2/` prefix): the **hybrid Deezer-metadata + YouTube-playback** pipeline. This is what the Flutter app uses.

Versioning is by **URL path prefix** (`/v2/...`). There is no deprecation header mechanism today; v1 remains for compatibility and internal use. Breaking changes to v2 shapes must bump to a `/v3/` namespace and update this file. See [VERSIONING.md](VERSIONING.md).

---

## Authentication

Client-facing metadata/search/lyrics endpoints require **no** authentication.

paax-api's **library-mutation endpoints** (`/library/*`, `/rate`, `/playlists*`) operate against a *single shared* YouTube Music account initialized from the `YTMUSIC_OAUTH_JSON` env var (or a local `oauth.json`). They are **not** per-user and have **no auth gate** — any caller can invoke them. The Flutter app does not use these in the live path (its library is local Hive). Treat them as admin/experimental. See [backend/auth.md](backend/auth.md) and [features/authentication.md](features/authentication.md).

```http
# No Authorization header is used by the client.
GET https://api.paaxmusic.app/v2/search?q=daft%20punk&type=tracks
```

---

## Standard Error Format

paax-api endpoints raise FastAPI `HTTPException`, which serializes as:

```json
{ "detail": "human-readable message" }
```

> ⚠️ Many 500s surface `str(e)` directly (internal detail leakage) — flagged in [KNOWN_ISSUES.md](KNOWN_ISSUES.md). The streaming surfaces use a richer envelope (see [ERROR_CODES.md](ERROR_CODES.md)).

The **stream resolvers** use a structured envelope:

```json
{ "success": false, "videoId": "…", "provider": "…", "error": "ERROR_CODE", "detail": "…" }
```

### Common Status Codes

| HTTP Status | Meaning (in Paax) |
|-------------|-------------------|
| `200 OK` | Success |
| `400 Bad Request` | Missing/invalid param (e.g. unknown `type`, bad videoId, missing stream `url`) |
| `404 Not Found` | Resource/video unavailable |
| `422` | Semantic issue (no audio formats) |
| `429` | Upstream rate limit (Deezer retried; stream proxy returns `RATE_LIMITED`) |
| `500` | Unexpected server error (may leak `str(e)`) |
| `502 / 503 / 504` | Upstream (YouTube/CDN) unavailable, blocked, or timed out |

---

## Endpoints — paax-api v2 (LIVE client API)

Every track carries a `playback` block:

```json
"playback": {
  "provider": "youtube",
  "engine": "iframe",
  "videoId": "dQw4w9WgXcQ",
  "matchConfidence": 0.92,
  "matchStatus": "matched",
  "matchReason": "dur=35 title=30 artist=20 trust=7"
}
```
`matchStatus` ∈ `matched | low_confidence | failed | timeout | pending`. The client sets `Track.id = playback.videoId`.

---

#### `GET /v2/search`

**Description**: Hybrid search. Tracks are YouTube-matched; albums/artists are metadata-only.
**Auth Required**: No · **Cache**: not endpoint-cached (matches use the 7-day match cache).

**Query Parameters**:

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `q` | string | Yes | Query |
| `type` | string | No | `tracks` (default) · `albums` · `artists`. Unknown → `400` |
| `limit` | int | No | Default `25` |

**Response `200`**:
```json
{ "data": [ { "id": "3135556", "title": "Get Lucky", "artist": {"id":"27","name":"Daft Punk"},
  "artists": [{"name":"Daft Punk","id":"27"}], "album": {"id":"302127","title":"Random Access Memories","coverUrl":"https://…"},
  "duration": 369, "explicit": false, "trackNumber": 8, "discNumber": 1, "source": "deezer",
  "playback": { "provider":"youtube","engine":"iframe","videoId":"5NV6Rdv1a3I","matchConfidence":0.9,"matchStatus":"matched","matchReason":"…" } } ] }
```

---

#### `GET /v2/artist/{artist_id}`

**Description**: Full artist profile (Deezer id, int). Top tracks are YouTube-matched; albums pre-split into `albums` vs `singles`.
**Auth Required**: No · **Cache**: 6 h.

**Response `200`**: `{ id, name, picture, nbFans, topTracks:[track], albums:[album], singles:[album], relatedArtists:[artist], source }`

---

#### `GET /v2/artist/{artist_id}/top`

**Description**: Artist top tracks (YouTube-matched, 15 s per-track timeout). **Query**: `limit` (default 50). **Auth**: No.
**Response `200`**: `{ "data": [track] }`

---

#### `GET /v2/artist/{artist_id}/albums`

**Description**: Artist discography (metadata only, no matching). **Query**: `limit` (default 100). **Auth**: No.
**Response `200`**: `{ "data": [album] }` where album `type` ∈ `album|single|ep`.

---

#### `GET /v2/album/{album_id}`

**Description**: Album detail + full tracklist (each track YouTube-matched). Deezer id (int). **Auth**: No · **Cache**: 24 h.
**Response `200`**: `{ id, title, artist:{id,name}, artists:[], coverUrl, releaseDate, trackCount, type, duration, explicit, source, tracks:[track] }`

---

#### `GET /v2/track/{track_id}`

**Description**: Single track (YouTube-matched, 15 s timeout). Deezer id (int). **Auth**: No.
**Response `200`**: a single `track` object (shape as in `/v2/search`).

---

#### `GET /v2/chart`

**Description**: Global charts. Tracks matched (concurrency `Semaphore(5)`); albums/artists metadata-only. **Auth**: No · **Cache**: 6 h.
**Response `200`**: `{ "tracks": [track], "albums": [album], "artists": [artist] }`

---

#### `GET /v2/match` (debug)

**Description**: Raw YouTube-match result for a `(artist, title, album, duration)`. `400` if `artist`/`title` missing.

---

## Endpoints — Lyrics

#### `GET /lyrics`

**Description**: Unified lyrics. Priority: LRCLIB exact (`lrclib.net/api/get`) → LRCLIB fuzzy (`/api/search`, scored by synced-bonus + duration closeness) → ytmusicapi plain text.
**Query**: `trackId` (=videoId), `title`, `artist`, `album`, `duration` (seconds). **Auth**: No.

**Response `200`**:
```json
{ "lyricsAvailable": true, "type": "synced", "source": "lrclib",
  "lyrics": [ { "timeMs": 12000, "endTimeMs": 15000, "text": "…" } ] }
```
`type` ∈ `synced | plain`; `source` ∈ `lrclib | ytmusicapi`. Consumed by `LyricsService` → `SyncedLyricsView`. See [features/player.md](features/player.md).

---

## Endpoints — paax-api v1 (legacy, ytmusicapi)

Still mounted; used for a few discovery paths and internally. Returns raw `ytmusicapi` shapes (little normalization). All `GET` unless noted.

| Path | Params | Returns |
|------|--------|---------|
| `/` , `/health` | — | status / `{ok, authenticated}` |
| `/cache/status`, `/auth/status`, `POST /auth/reload` | — | cache/auth diagnostics |
| `/search` | `q`, `filter`, `limit=20` | `{data:[…]}` (cached, `X-Cache`) |
| `/home`, `/home/discover` | — | home feed |
| `/charts`, `/home/charts` | `country=US` (`Global`→`ZZ`) | charts / `{tracks,albums,artists}` |
| `/moods`, `/moods/{params}` | — | mood categories/playlists |
| `/genre/{slug}` | `country=US` | `{title, playlists, tracks, artists}` (hardcoded `GENRE_PARAMS`) |
| `/home/top` | `genre`, `country=US` | `{tracks, albums, artists}` |
| `/artist/{channelId}` | — | artist dict |
| `/artist/{channelId}/albums` | `params` | album list |
| `/artist/{channelId}/albums/page` | `params`, `ctoken` | `{items, nextPageToken}` (continuation) |
| `/album/{browseId}` | — | album + tracks (falls back to `get_playlist`) |
| `/song/{videoId}`, `/song/{videoId}/related` | — | song / watch playlist |
| `/watch` | `videoId`, `playlistId` | watch playlist (radio) |
| `/lyrics/{videoId}` | — | legacy lyrics |

**Authenticated (shared account, no per-user gate):** `GET /library/liked?limit=100`, `GET /library/playlists?limit=25`, `POST /rate` (`videoId`,`rating`), `POST /playlists` (`title`,`description`), `DELETE /playlists/{id}`, `POST|DELETE /playlists/{id}/items` (`videoIds`).

---

## Endpoints — Streaming resolvers

### Cloudflare Worker — `stream.paaxmusic.app`

**Description**: Resolves a `videoId` (last URL path segment, `^[a-zA-Z0-9_-]{11}$`) to a direct progressive audio CDN URL via YouTube **Innertube** (`youtubei/v1/player`), trying an ANDROID → ANDROID_VR → ANDROID_TESTSUITE → TVHTML5 → IOS client waterfall. Prefers itag 140 (audio mp4/m4a). **Cache**: 5 min (`caches.default`). Query `?client=`/`?exclude=` to force clients (bypasses cache).
**Response `200`**: `{ url, mimeType, sourceType, expiresAt, clientUsed, itag, candidates, … }`
**Errors**: `ALL_CLIENTS_BLOCKED`/`PLAYABILITY_BOT_CHECK`/`GATED`→503, `PLAYABILITY_UNAVAILABLE`→404, `NO_STREAMING_DATA`/`NO_AUDIO_FORMAT`→502, `MISSING/INVALID_VIDEO_ID`→400.

### paax-stream — `resolver.paaxmusic.app` (deployed, unused by app)

| Path | Description |
|------|-------------|
| `GET /` | banner `{service, version:"4.0.0", mode:"hybrid_proxy", …}` |
| `GET /health` | `{status:"ok", service:"paax-stream", provider:"youtube_ipv6_proxy"}` (Railway healthcheck) |
| `GET /stream?url=<cdn_url>` | **Proxies audio bytes** (not redirect) through a 16-address IPv6 pool with sticky per-IP session/UA. Host allowlist (`*.googlevideo.com`/`.youtube.com`/`.ytimg.com`/`.ggpht.com`). Honors `Range`/`206`. Headers `X-Proxy-IPv6`, `X-Provider: ipv6_proxy`. |

Errors: `MISSING_URL`, `INVALID_URL`, `RATE_LIMITED`(429), `UPSTREAM_UNAVAILABLE`(502), `RANGE_NOT_SATISFIABLE`(416), `CDN_FORBIDDEN`(403), `UPSTREAM_TIMEOUT`(504), `UPSTREAM_ERROR`(502). The `/resolve/*` router and multi-provider stack in the repo are **orphaned/unmounted** — see [backend/workers.md](backend/workers.md).

> **Note**: The live Flutter app does **not** call any stream resolver — it plays the `videoId` directly via a YouTube IFrame. `MusicRepository.getStreamUrl` (`/stream/{videoId}`) exists but is unused. See [features/player.md](features/player.md).

---

## Webhooks

None. Paax sends no outbound webhooks.

---

## Deprecated Endpoints

| Endpoint | Deprecated Since | Removal | Replacement |
|----------|-----------------|---------|-------------|
| paax-api v1 discovery (`/search`, `/artist/*`, `/album/*`) | v2 launch (2026) | TBD | `/v2/*` hybrid endpoints |
| legacy `backend` `/stream/{videoId}` | superseded | — | Worker / paax-stream (currently broken: `_FORMAT_FALLBACKS` NameError) |

---

## Recommended API Improvements (Architecture Review, 2026-07-16)

From the [Architecture Review](architecture-review.md) §9:

- **One consistent error envelope** — paax-api returns FastAPI `{detail}` and leaks `str(e)`; the stream resolvers use a third shape. Standardize on `{error:{code,message,details}}` (the project's own [`.claude/rules/api.md`](../.claude/rules/api.md)) + stable codes ([ERROR_CODES.md](ERROR_CODES.md)) (`AR-API-01`, `AR-SEC-05`).
- **Validate requests with pydantic models** — replace bare `Query(default=…)`; enforce `type` enums, `limit` caps, id formats (`AR-API-02`).
- **Cursor pagination + max page size** on list endpoints (`AR-API-03`).
- **Emit `Cache-Control`/`ETag`; publish the OpenAPI `/docs`** as the contract surface (`AR-API-04`).
- **Separate metadata from playback resolution** — a `/v2/resolve/{trackId}` called at play time lets `/v2/*` return instantly with `matchStatus: pending` (`AR-API-05`, `AR-PERF-01`), which also unifies the streaming story.
- **Version deliberately; retire v1** with a deprecation policy + `Deprecation` headers (`AR-API-06`).
- **Split `/livez` vs `/readyz`; add `/metrics`** (`AR-API-07`).

Full detail: [architecture-review.md](architecture-review.md#9-api-improvements).

---

## Phase 2 — normalized Supabase-first `/v2/*` (additive)

Introduced in Phase 2.5 alongside the unchanged legacy `/v2/artist|album|track|
search|chart` endpoints. **Phase 3.3**: Flutter now consumes these for the
browsing **display** — artist detail (`/v2/artists/deezer/{id}`) and search
artists/albums (`/v2/find`) — while the eager legacy endpoints remain the
**playback** path (unchanged). All return one normalized camelCase model; reads
carry `X-Cache: hit|miss|stale`.

```
GET  /v2/artists/{artist_id}                    GET  /v2/albums/{album_id}
GET  /v2/artists/deezer/{deezer_id}             GET  /v2/albums/deezer/{deezer_id}
GET  /v2/artists/{artist_id}/discography        GET  /v2/tracks/{track_id}
GET  /v2/artists/{artist_id}/top                GET  /v2/tracks/deezer/{deezer_id}
POST /v2/tracks/{track_id}/resolve-playback     POST /v2/tracks/{track_id}/report-playback-failure
GET  /v2/find ?q=&type=tracks|albums|artists    GET  /v2/home ?country=&limit=
```

Normalized track shape includes `id`, `deezerId`, `title`, `artists[]`
(role+position), `artistDisplayName`, `album`, `durationSeconds`, `explicit`,
`genres`, and `playback:{provider,engine,videoId,audioVideoId,musicVideoId,
preferredType,matchStatus}` where `videoId` = audio-preferred YouTube id.

The artist response exposes `platformFollowersCount` (Paax followers,
trigger-maintained) and `deezerFansCount` (external), plus a
deterministically-ordered `discography:{albums,eps,singles,compilations}` and
`latestRelease`. Each release carries `releaseDate` **and** `releaseYear`
(Phase 3.3), ordered by exact date → year → title.

Full reference: [backend/phase2-catalog.md](backend/phase2-catalog.md).

---

*Last updated: 2026-07-26*
