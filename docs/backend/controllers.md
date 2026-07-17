# Controllers

> **Purpose**: Documents all API controllers (route handlers) — their routes, request/response contracts, and which service they delegate to.
> **Update when**: A new controller or route is added, a route path changes, or the request/response shape changes.

> **See also**: [`api.md`](../api.md) for the full endpoint contract, [`services.md`](services.md) for the logic behind each handler, [`auth.md`](auth.md) for the (largely absent) auth model, [`cache.md`](cache.md) for the caching wrapped around handlers.

---

## What is a Controller?

The generic template below assumes an OOP `SomethingController` class per resource. **That pattern does not exist in Paax.** The backends are **FastAPI apps**, and a "controller" here is a **module-level `async def` route handler** decorated with `@app.get(...)` / `@app.post(...)` directly in the service's `main.py`. There is no controller class hierarchy, no dependency-injection container, and no per-resource file split — every route lives in one `main.py` per service.

In practice a Paax route handler:
- Reads path/query params straight from the function signature (FastAPI does the parsing/coercion).
- Calls into the `services/` layer (paax-api v2) or a helper function (v1 / legacy) — see [`services.md`](services.md).
- Returns a plain `dict`/`list`; FastAPI serializes it to JSON.
- Does **not** touch a database — there is none server-side (see [`database-schema.md`](database-schema.md)).
- Wraps work in `try/except` and re-raises as `HTTPException`.

The "thin handler, logic in services" ideal is **only genuinely realized in paax-api v2**. The v1 and legacy handlers are thicker — they call ytmusicapi and do response shaping inline.

---

## Controller Inventory

There are no controller classes. Instead, three FastAPI apps expose route groups. This table maps the template's notion of a "controller" onto the real route groups.

| Route group | File | Base Route | Responsibility |
|-----------|------|-----------|----------------|
| paax-api **v2 hybrid** (LIVE) | `paax-api/main.py` | `/v2` | Deezer metadata + eager YouTube match — the path the shipping app uses |
| paax-api **v1 legacy** | `paax-api/main.py` | `/` (root) | ytmusicapi-backed discovery/library, superseded by v2 but still mounted |
| paax-api **ops** | `paax-api/main.py` | `/health`, `/cache/*`, `/auth/*` | Health, cache introspection, OAuth reload |
| **legacy backend** | `backend/main.py` | `/` (root) | The original monolith: same v1 surface **plus** in-process yt-dlp streaming |
| **paax-stream** | `paax-stream/app/main.py` | `/`, `/health`, `/stream` | IPv6 byte-proxy for CDN audio (deployed, not consumed by the live app) |

> There is **no `AuthController`, `UserController`, or `PlaylistController` class**. Auth is a client-side demo stub ([`auth.md`](auth.md)); user/playlist state lives in client Hive ([`database-schema.md`](database-schema.md)). The v1 `/playlists*` and `/rate` routes below mutate a single **shared** YouTube Music account, not per-user data.

---

## Controller Specs

---

### paax-api v2 hybrid — `/v2` (the live path)

**File**: `paax-api/main.py`
**Service**: `services/hybrid/*`, `services/deezer/deezer_client`, `services/deezer/deezer_mapper`, `services/youtube/youtube_matcher` (see [`services.md`](services.md))

This is the only route group the shipping Flutter client depends on for metadata. Every track it returns carries a `playback` block (`{provider:"youtube", engine:"iframe", videoId, matchConfidence, matchStatus, matchReason}`) produced by eager YouTube matching. Full request/response contracts live in [`api.md`](../api.md); the tables below are a handler → service map, not the authoritative contract.

| Method | Route | Auth | Description | Cached |
|--------|-------|------|-------------|--------|
| `GET` | `/v2/search?q=&type=tracks\|albums\|artists&limit=25` | No | Deezer search; tracks get YouTube matches | No (per-match 7d cache) |
| `GET` | `/v2/artist/{id}` | No | Artist profile (id is Deezer integer) | 6h |
| `GET` | `/v2/artist/{id}/top?limit=50` | No | Artist top tracks (matched) | No (per-match 7d) |
| `GET` | `/v2/artist/{id}/albums?limit=100` | No | Artist discography | — |
| `GET` | `/v2/album/{id}` | No | Album + tracklist (matched) | 24h |
| `GET` | `/v2/track/{id}` | No | Single track (matched) | No (per-match 7d) |
| `GET` | `/v2/chart` | No | Global chart (Semaphore(5) matching) | 6h |
| `GET` | `/v2/match?artist=&title=&album=&duration=` | No | Debug: raw match result for one track | 7d match cache |

---

### paax-api v1 legacy — `/` (ytmusicapi-backed)

**File**: `paax-api/main.py`
**Service**: `ytmusicapi` client directly (no service layer abstraction)

Superseded by v2 but still mounted. Discovery routes are cached; library/mutation routes require the shared OAuth account (`YTMUSIC_OAUTH_JSON`). The full per-route contract is in [`api.md`](../api.md); grouped here as a handler map:

| Route group | Routes | Auth | Handler behavior |
|-------------|--------|------|------------------|
| Ops | `/`, `/health`, `/cache/status`, `/auth/status`, `POST /auth/reload` | No | Banner, health, cache stats, OAuth (re)load |
| Discovery (cached) | `/search`, `/home*`, `/charts`, `/home/charts`, `/moods*`, `/genre/{slug}`, `/home/top` | No | ytmusicapi query → shape inline |
| Catalog (cached) | `/artist/{channelId}(/albums[/page])`, `/album/{browseId}`, `/song/{videoId}(/related)`, `/watch` | No | ytmusicapi lookup; `ctoken` paging on discography |
| Lyrics | `/lyrics/{videoId}`, `/lyrics?trackId&title&artist&album&duration` | No | LRCLIB → ytmusicapi fallback (logic in `main.py`) |
| Library (shared acct) | `GET /library/liked`, `GET /library/playlists`, `POST /rate`, `POST/DELETE /playlists[/{id}][/items]` | **Shared acct** | Read/mutate the single shared YouTube Music account |

> **"Auth" caveat**: the library/mutation routes have **no per-user authentication**. Anyone who can reach the endpoint mutates the one shared YouTube Music account. See the Security section and [`auth.md`](auth.md).

---

### legacy backend — `/` (`backend/main.py`)

**File**: `backend/main.py` ("Beaty YouTube Music Backend")
**Service**: ytmusicapi + in-process yt-dlp

The original monolith paax-api replaced. Same v1 discovery/library/lyrics surface as above, **plus** in-process streaming:

| Method | Route | Auth | Description |
|--------|-------|------|-------------|
| `GET` | `/playback/resolve?videoId=` | No | yt-dlp resolve → `{ok, streamUrl, sourceType, mimeType, expiresAt, cached}` |
| `POST` | `/playback/prefetch` | No | Fire-and-forget warm the resolve cache (see [`workers.md`](workers.md)) |
| `GET` | `/playback/debug-resolve` | No | Diagnostic resolve dump |
| `GET` | `/stream/{videoId}` | No | **BROKEN** — `NameError: _FORMAT_FALLBACKS`; superseded |

Its yt-dlp resolver classifies failures via `_classify_yt_error` into stable codes (`BOT_CHECK`, `GEO_BLOCKED`, `VIDEO_UNAVAILABLE`, `FORMAT_UNAVAILABLE`, `NETWORK_ERROR`, `RESOLVE_FAILED`) — the one piece of disciplined error mapping in the legacy service. See [`workers.md`](workers.md) and [`services.md`](services.md).

---

### paax-stream — `/stream` (byte proxy)

**File**: `paax-stream/app/main.py` ("Phase 8 Hybrid Proxy", v4.0.0)
**Service**: IPv6-bound httpx transport pool (see [`services.md`](services.md), [`workers.md`](workers.md))

Only three routes are mounted: `/`, `/health`, `/stream`.

| Method | Route | Auth | Description |
|--------|-------|------|-------------|
| `GET` | `/stream?url=<cdn_url>` | No (host allowlist) | Proxies audio **bytes** from a `*.googlevideo.com`/`youtube.com`/`ytimg.com`/`ggpht.com` CDN URL through a rotating pool of 16 local IPv6 source addresses; supports HTTP Range/206 |
| `GET` | `/health` | No | Liveness |
| `GET` | `/` | No | Banner |

> The entire `resolve/` router (`/resolve/stream/{id}`, `/resolve/formats/{id}`) and its multi-provider stack are **NOT mounted** — dead scaffolding. See [`services.md`](services.md) and [`workers.md`](workers.md).

---

## Controller Rules

How the template rules map to reality:

- **Thin handlers**: Aspired to, achieved in v2 (delegates to `services/`). v1/legacy handlers are thicker (call ytmusicapi + shape inline). New v2 work must keep handlers thin.
- **Validation**: FastAPI coerces path/query types (e.g. `{id}` as `int` on v2 rejects non-numeric with 422). There is **no schema-validation library** on request bodies and no custom validators — a gap vs. the [`api.md`](../api.md) rule requiring schema validation.
- **Status codes**: Handlers raise `HTTPException`; success paths return `200`. There is no `201/204` discipline. See [`api.md`](../api.md).
- **Error formatting**: **Not compliant.** Handlers surface `str(e)` directly to the client (leaking internal exception text) instead of the standard `{error:{code,message}}` envelope. Flagged in Security below and in [`api.md`](../api.md).
- **Request ID logging**: Not implemented. No structured request-scoped logging exists.

---

## Middleware Applied

Real middleware is minimal — **CORS only**. The template's auth/logging/rate-limit/validation middleware **do not exist**.

| Middleware | Scope | Purpose | Status |
|-----------|-------|---------|--------|
| `CORSMiddleware` | All routes (paax-api, backend, paax-stream) | Allow browser origins | **Active** |
| `AuthMiddleware` | — | JWT validation | **Not applicable** — no server-side user auth ([`auth.md`](auth.md)) |
| `LoggingMiddleware` | — | Request/response logging | **Not implemented** |
| `RateLimitMiddleware` | — | Rate limiting | **Not implemented** (a real DoS/abuse gap — flagged in [`security.md`](../security.md)) |
| `ValidationMiddleware` | — | Schema validation | **Not implemented** (FastAPI type coercion only) |

### CORS configuration (paax-api)

- Allows configured `FRONTEND_ORIGINS` (comma-separated env), **plus** always permits `localhost` / `10.0.2.2` (Android emulator) / LAN addresses via an origin **regex**.
- `allow_credentials=True`.

> **Why the LAN regex**: development runs the Flutter web build and Android emulator against a dev machine's LAN IP; the regex avoids hand-maintaining an origin allowlist per dev. The trade-off — a permissive regex combined with `allow_credentials=True` — is documented as a risk in [`security.md`](../security.md). It is low-impact here only because there are no server-side credentials/cookies worth stealing.

---

## Security Notes (flagged)

These are real, current issues in the route layer (from the codebase, not aspirational):

- **`str(e)` leakage**: exception text is returned to clients across handlers — replace with the standard error envelope from [`api.md`](../api.md).
- **`verify=False` on the Deezer httpx client** (paax-api): TLS certificate validation is disabled on upstream metadata calls — a MITM risk. See [`services.md`](services.md) and [`security.md`](../security.md).
- **No auth on mutation routes**: v1 `/rate`, `/playlists*` mutate one shared account with no caller identity.
- **No rate limiting**: any route can be hammered; YouTube-matching routes are especially expensive (each spawns yt-dlp searches).

---

*Last updated: 2026-07-16*
