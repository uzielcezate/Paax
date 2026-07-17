# Environment Variables

> **Purpose**: Documents every environment variable required by the application. Values are never stored here — only names, descriptions, and which environments require them.
> **Update when**: A new environment variable is introduced or an existing one changes purpose.

---

## Rules

- Never commit actual secret values. Use `.env.example` with placeholder values (present in `paax-api/` and `paax-stream/`).
- Every required variable must be listed here.
- `oauth.json` / `*oauth*.json` are gitignored (root `.gitignore`) — never commit them.
- Frontend "env" is **compile-time** (`--dart-define`, `String.fromEnvironment`), not runtime — values are baked into the build.

---

## Variable Index

Paax spans four deployables. The tables below are grouped by where the variable is consumed.

### paax-api (`api.paaxmusic.app`)

| Variable | Required | Description | Example Value |
|----------|----------|-------------|---------------|
| `YTMUSIC_OAUTH_JSON` | Prod (for auth'd endpoints only) | Full `oauth.json` content; written to a temp file to init an authenticated `ytmusicapi` client. Unset → unauthenticated (public content only) | `{ "access_token": "...", ... }` |
| `REDIS_URL` | Optional | Redis connection for response cache. Unset → in-memory cache only | `redis://default:pass@host:6379` |
| `FRONTEND_ORIGINS` | Optional | Comma-separated production CORS origins (localhost/LAN always allowed via regex) | `https://paaxmusic.app` |
| `PORT` | Railway auto-sets | uvicorn listen port | `8080` |

### paax-stream (`resolver.paaxmusic.app`)

| Variable | Required | Description | Example Value |
|----------|----------|-------------|---------------|
| `SOURCE_PLATFORM_URL` | Optional | Origin/Referer + session-handshake target | `https://www.youtube.com` |
| `IPV6_SUBNET_BASE` | Optional | First address of the routed /124 IPv6 rotation block | `2604:A880:0004:01D0:0000:0002:7D72:C000` |
| `IPV6_POOL_SIZE` | Optional | Number of consecutive IPv6 addresses to rotate | `16` |
| `REDIS_URL` | Optional | Session/cookie store (`paax:session:<ipv6>`) | `redis://localhost:6379/0` |
| `SESSION_COOKIE_TTL` | Optional | Sticky session TTL (seconds) | `1800` |
| `STREAM_CHUNK_SIZE` | Optional | `StreamingResponse` chunk size (bytes) | `65536` |
| `UPSTREAM_TIMEOUT_S` | Optional | CDN byte-read timeout (seconds) | `15.0` |
| `FRONTEND_ORIGINS` | Optional | CORS origins (`*` allowed) | `*` |
| `PORT` / `HOST` | Railway auto-sets / Optional | Bind port/host | `8080` / `0.0.0.0` |
| `LOG_LEVEL` | Optional | Log verbosity | `info` |
| `INVIDIOUS_BASE_URL`, `REQUEST_TIMEOUT_MS`, `CACHE_TTL_SECONDS`, `COBALT_INSTANCES`, `PIPED_INSTANCES` | Optional | **Only used by the orphaned resolver stack** (unmounted) — kept for the future multi-provider path | see `.env.example` |

### legacy backend

| Variable | Required | Description | Example Value |
|----------|----------|-------------|---------------|
| `YTMUSIC_OAUTH_JSON` | Prod (auth'd) | Same as paax-api | — |
| `FRONTEND_ORIGINS` | Optional | CORS origins | — |
| `REDIS_URL` | Optional | Response/stream cache | — |
| `PORT` | Railway | uvicorn port | `8000` |

### Cloudflare Worker

No environment variables. `wrangler.toml` `[vars]` is empty; the YouTube Innertube API is called unauthenticated.

### Supabase / bootstrap script (Phase 1 — used by `scripts/bootstrap-owner.mjs` only; no service consumes these yet)

| Variable | Required | Secret? | Description | Example Value |
|----------|----------|---------|-------------|---------------|
| `SUPABASE_URL` | Optional (has default) | No | Supabase project URL | `https://jecgmiuypuathhvjuhea.supabase.co` (default) |
| `SUPABASE_SERVICE_ROLE_KEY` | Required by the bootstrap script | **YES — SECRET** | Service-role key. **Server/scripts only — never in Flutter or any client bundle.** See [security.md](security.md) | `eyJ...` |
| `PAAX_OWNER_EMAIL` | Optional (bootstrap only) | No | Owner account email for `scripts/bootstrap-owner.mjs` | `owner@example.com` |
| `PAAX_OWNER_USERNAME` | Optional (bootstrap only) | No | Owner account username | `owner` |
| `PAAX_OWNER_PASSWORD` | Optional (bootstrap only) | **YES — SECRET** | Owner account password; if unset the script may prompt interactively | — |

**FUTURE (Phase 5, NOT set anywhere yet)** — Supabase Edge Function secrets for the undeployed Stripe scaffolds (`supabase/functions/`):

| Variable | Required | Secret? | Description |
|----------|----------|---------|-------------|
| `STRIPE_SECRET_KEY` | Not yet | **YES — SECRET** | Stripe API key (Edge Function secret, never client-side) |
| `STRIPE_WEBHOOK_SIGNING_SECRET` | Not yet | **YES — SECRET** | Stripe webhook signature verification (Edge Function secret) |

### Frontend (`--dart-define`, compile-time)

| Variable | Required | Description | Example Value |
|----------|----------|-------------|---------------|
| `ENV` | Optional | Environment selector | `local` / `lan` / `prod` (default `prod`) |
| `LAN_IP` | Required when `ENV=lan` | Dev PC LAN IP for on-device testing | `192.168.1.10` |
| `API_BASE_URL` | Optional | Override the metadata backend base URL | `https://api.paaxmusic.app` |
| `STREAM_BASE_URL` | Optional | Override the stream backend base URL (currently unused by playback) | `https://resolver.paaxmusic.app` |

`ApiConfig` resolution (`core/config/api_config.dart`): `prod` → `api.paaxmusic.app` / `resolver.paaxmusic.app`; `local` → `127.0.0.1:8000` / `:8080`; `lan` → `<LAN_IP>:8000` / `:8080`. The legacy `app_config.dart` (`API_BASE_URL` default `http://localhost:8000`) is superseded.

---

## `.env.example`

`paax-api/.env.example`:
```env
YTMUSIC_OAUTH_JSON=
REDIS_URL=
FRONTEND_ORIGINS=
```

`paax-stream/.env.example` (abridged):
```env
SOURCE_PLATFORM_URL=https://www.youtube.com
IPV6_SUBNET_BASE=2604:A880:0004:01D0:0000:0002:7D72:C000
IPV6_POOL_SIZE=16
REDIS_URL=redis://localhost:6379/0
SESSION_COOKIE_TTL=1800
STREAM_CHUNK_SIZE=65536
UPSTREAM_TIMEOUT_S=15.0
FRONTEND_ORIGINS=*
LOG_LEVEL=info
```
The legacy `backend/` has no `.env.example` (governed by the root `.gitignore`).

---

## Per-Environment Variable Matrix

| Variable | Development (local) | LAN test | Production |
|----------|---------------------|----------|------------|
| `ENV` (frontend) | `local` | `lan` | `prod` |
| `LAN_IP` (frontend) | — | required | — |
| `REDIS_URL` (services) | optional (memory cache) | optional | set (Railway Redis) |
| `YTMUSIC_OAUTH_JSON` | local `oauth.json` file | local file | env var (auth'd endpoints) |
| `FRONTEND_ORIGINS` | localhost auto-allowed | LAN auto-allowed | `https://paaxmusic.app` |
| `PORT` | 8000/8080 | 8000/8080 | Railway-injected |

See [deployment.md](deployment.md) for how these are set per platform and [security.md](security.md) for secret handling.

---

## Phase 2 catalog backend variables (`paax-api`)

Required in production (fail-fast; without them the normalized `/v2` endpoints
return 503 and the legacy endpoints still work):

| Variable | Notes |
|----------|-------|
| `SUPABASE_URL` | Project URL, e.g. `https://<ref>.supabase.co` (not secret) |
| `SUPABASE_SERVICE_ROLE_KEY` | **Secret** — backend-only, bypasses RLS. Never ship to Flutter/logs. From Supabase Dashboard → Project Settings → API |
| `REDIS_URL` | Already set (Railway Redis plugin) |

Optional (sensible defaults in `config.py`): `SUPABASE_ENABLED`,
`SUPABASE_IMAGES_BUCKET` (default `music-images`), `DEEZER_BASE_URL`,
`DEEZER_TIMEOUT_SECONDS`, `LOG_LEVEL`, and the TTL / freshness / concurrency /
artwork tunables (`CATALOG_*_TTL_SECONDS`, `SEARCH_CACHE_TTL_SECONDS`,
`HOME_CACHE_TTL_SECONDS`, `YOUTUBE_MATCH_TTL_SECONDS`, `NEGATIVE_CACHE_TTL_SECONDS`,
`INGEST_LOCK_TTL_SECONDS`, `*_FRESHNESS_SECONDS`, `MAX_DEEZER_CONCURRENCY`,
`MAX_YOUTUBE_MATCH_CONCURRENCY`, `ARTWORK_MAX_BYTES`,
`ARTWORK_DOWNLOAD_TIMEOUT_SECONDS`). Full list + defaults in `paax-api/.env.example`.

---

*Last updated: 2026-07-17*
