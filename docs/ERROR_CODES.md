# Error Codes

> **Purpose**: A complete reference of all application-defined error codes — their meaning, when they are returned, and how clients should handle them. The single source of truth for error codes across all layers.
> **Update when**: A new error code is added to the codebase, or the meaning of an existing code changes.

---

## Error Code Format

Paax does **not** implement the standardized `{ "error": { code, message, details } }` envelope prescribed by [`.claude/rules/api.md`](../.claude/rules/api.md). That envelope is aspirational. The real behavior differs per layer and is documented honestly below:

- **paax-api** (metadata): FastAPI `HTTPException` with a plain `{ "detail": "<message>" }` body. Several handlers surface `str(e)` directly (error-message leakage — see [security](security.md) / [known issues](KNOWN_ISSUES.md)). There is **no** structured `code` field on most paax-api errors.
- **paax-stream** (byte proxy): raises typed exceptions that map to stable string **error codes** returned to the client (documented below).
- **Cloudflare Worker** (stream resolver): returns JSON with an explicit `error`/`code` string identifying the failure class.
- **legacy backend** (`/stream`): `yt-dlp` failures are classified into stable string codes via `_classify_yt_error`.
- **Flutter client**: has no server error codes to rely on, so `error_state_widget.dart` classifies **error message strings** heuristically into an icon + retry affordance.

Code naming convention where codes exist: `SCREAMING_SNAKE_CASE`. Because the codes originate in different services rather than one schema, they are grouped by **originating layer** rather than by domain prefix.

---

## Code Groupings

| Layer | Where codes live |
|--------|--------|
| paax-stream | `paax-stream/app/` — byte-proxy stream errors + typed exceptions |
| Cloudflare Worker | `cloudflare-worker/` — Innertube resolver failures |
| legacy backend | `backend/` — `_classify_yt_error` yt-dlp classification |
| paax-api match | v2 hybrid pipeline — `matchStatus` values (not HTTP errors) |
| Flutter client | `error_state_widget.dart` — client-side string classification |

> The template's generic `AUTH_` / `VALIDATION_` / `MEDIA_` / `PLAYER_` / `RATE_` / `INTERNAL_` families below are retained as a **reference shape** for future work, annotated with what Paax actually does today. Paax currently ships **no auth error codes** (auth is a local demo stub — see [security](security.md)) and **no server-side validation error codes** (no schema-validation library on its own endpoints).

---

## paax-stream Stream Errors (byte proxy)

Returned by `GET /stream?url=<cdn_url>` on `resolver.paaxmusic.app`. (Deployed but not consumed by the live app — see [architecture](architecture.md).)

| Code | HTTP Status | Description | Client Action |
|------|------------|-------------|---------------|
| `MISSING_URL` | 400 | No `url` query parameter supplied | Fix request; supply a CDN url |
| `INVALID_URL` | 400 | `url` host not on the allowlist (`*.googlevideo.com` / `*.youtube.com` / `*.ytimg.com` / `*.ggpht.com`) | Do not proxy non-YouTube hosts (anti-abuse) |
| `RATE_LIMITED` | 429 | Upstream YouTube CDN rate-limited this source IPv6 | Retry (proxy rotates to another IPv6 in the /124 pool) |
| `UPSTREAM_UNAVAILABLE` | 502 | CDN returned a non-success, non-range status | Refetch stream URL; skip track |
| `RANGE_NOT_SATISFIABLE` | 416 | Requested Range cannot be served | Restart from byte 0 |
| `CDN_FORBIDDEN` | 403 | CDN rejected the request (expired/bot-flagged URL) | Re-resolve the `videoId` for a fresh URL |
| `UPSTREAM_TIMEOUT` | 504 | CDN read exceeded `UPSTREAM_TIMEOUT_S` (default 15s) | Retry once, then skip |
| `UPSTREAM_ERROR` | 502 | Generic upstream failure not otherwise classified | Retry, then surface a playback error |

**Typed exceptions** (internal → mapped to the codes above): the proxy raises typed exception classes (e.g. missing/invalid URL, rate-limited, CDN-forbidden, upstream-timeout, upstream-error) that the route handler translates into the `CODE` + HTTP status pairs above. Range/`206` streaming uses 64 KiB chunks and echoes `X-Proxy-IPv6` / `X-Provider: ipv6_proxy` headers on success.

---

## Cloudflare Worker Resolver Errors (Innertube)

Returned by `stream.paaxmusic.app/<videoId>` ("v6" edge resolver). It walks a client waterfall (ANDROID → ANDROID_VR → ANDROID_TESTSUITE → TVHTML5_SIMPLY_EMBEDDED → IOS) to obtain a progressive audio CDN URL (prefers itag 140, rejects webm/opus/DASH).

| Code | HTTP Status | Description | Client Action |
|------|------------|-------------|---------------|
| `MISSING_VIDEO_ID` | 400 | No video id in the path | Provide the last path segment |
| `INVALID_VIDEO_ID` | 400 | Id fails `^[a-zA-Z0-9_-]{11}$` | Fix the id |
| `PLAYABILITY_BOT_CHECK` | 403 | Innertube flagged the request as a bot / requires sign-in | Retry later; this URL/client is blocked |
| `PLAYABILITY_GATED` | 403 | Age/login-gated content | Not resolvable by an unauthenticated edge worker |
| `PLAYABILITY_UNAVAILABLE` | 404 | Video removed/private/region-blocked | Skip track; mark unavailable |
| `NO_STREAMING_DATA` | 502 | Player response contained no `streamingData` | Skip track |
| `NO_AUDIO_FORMAT` | 502 | No acceptable progressive audio format (itag 140 / m4a) found | Skip track |
| `ALL_CLIENTS_BLOCKED` | 502 | Every client in the waterfall failed to produce a URL | Skip track; likely broad bot-blocking |

---

## Legacy backend yt-dlp Classification (`_classify_yt_error`)

Emitted by the legacy `backend/` `/stream` and `/playback/resolve` paths. **The `/stream` endpoint itself is currently broken** (`NameError: _FORMAT_FALLBACKS`), so these codes are documented for historical completeness and because `/playback/resolve` shares the classifier. See [known issues](KNOWN_ISSUES.md).

| Code | Meaning | Typical Cause |
|------|---------|---------------|
| `BOT_CHECK` | YouTube demanded bot verification / sign-in | Datacenter IP flagged |
| `GEO_BLOCKED` | Content not available in the server's region | Regional licensing |
| `VIDEO_UNAVAILABLE` | Removed, private, or deleted | — |
| `FORMAT_UNAVAILABLE` | No acceptable audio format (audio-only mp4/m4a/AAC; rejects webm/opus/DASH/`sq=`) | Live/DASH-only video |
| `NETWORK_ERROR` | Transport failure reaching YouTube/CDN | Timeout / connection reset |
| `RESOLVE_FAILED` | Generic catch-all resolve failure | Uncategorized `yt-dlp` error |

---

## paax-api Match Statuses (not HTTP errors)

The v2 hybrid pipeline attaches a `playback` block to each track with a `matchStatus`. These are **result states**, not error responses — a `failed` match still returns HTTP 200 with metadata, just without a reliable `videoId`.

| `matchStatus` | Meaning | How the client treats it |
|--------------|---------|--------------------------|
| `matched` | Confidence ≥ 0.5; `videoId` is trustworthy | Playable normally |
| `low_confidence` | A candidate was found but scored < 0.5 | Playable, but may be the wrong recording |
| `failed` | No acceptable candidate (e.g. duration outside ±60s hard reject) | Not reliably playable; surface a skip/error |
| `timeout` | Match exceeded the per-track budget (15s main / 30s hybrid) | Treat as unresolved; may retry |
| `pending` | Match not yet completed (async) | Wait / show loading |

Scoring inputs (0–100): duration proximity (±60s is a hard reject), title similarity (`difflib`), artist match, and trust signals (Topic channel / VEVO / "Official Audio"). See [api](api.md) and [architecture](architecture.md).

---

## Flutter Client Error Classification (`error_state_widget.dart`)

The app has no reliable server error codes to switch on, so `ErrorStateWidget` inspects the **error message string** and picks an icon + copy + a "Try Again" affordance, satisfying the "no dead ends" UX rule ([`.claude/rules/ux.md`](../.claude/rules/ux.md)). Broad buckets:

| Heuristic match | Presented as | Recovery |
|-----------------|--------------|----------|
| network/timeout/socket phrases | Connectivity error icon + message | Retry button |
| not found / 404 phrases | "Not found" empty-ish state | Back / retry |
| generic/unknown | Generic warning icon | Retry button |

This is best-effort UX, not a typed contract. Adopting real structured error codes end-to-end is tracked in [ideas](IDEAS.md) / [tech debt](TECH_DEBT.md).

---

## Reference Shape (aspirational — mostly not implemented)

The following families come from [`.claude/rules/api.md`](../.claude/rules/api.md). They are kept as the **target design** for when Paax gains real auth, validation, and a unified error envelope. Annotations state current reality.

### Authentication Errors (`AUTH_`)

Not implemented — Paax has no server-side per-user auth (local demo stub only; see [security](security.md)). Server "auth" is a single shared YTMusic OAuth account with no token errors surfaced to clients.

| Code | HTTP Status | Description | Current reality |
|------|------------|-------------|-----------------|
| `AUTH_TOKEN_MISSING` | 401 | No auth token | N/A — no tokens exist |
| `AUTH_TOKEN_INVALID` | 401 | Malformed/invalid token | N/A |
| `AUTH_TOKEN_EXPIRED` | 401 | Expired token | N/A |
| `AUTH_INSUFFICIENT_PERMISSIONS` | 403 | Valid token, no permission | N/A |

### Validation Errors (`VALIDATION_`)

Not implemented — no schema-validation library guards paax-api's own endpoints. Bad input typically surfaces as an unclassified `HTTPException`/`str(e)`.

| Code | HTTP Status | Description | Current reality |
|------|------------|-------------|-----------------|
| `VALIDATION_REQUIRED` | 400 | Required field missing | Ad hoc — no `code` field |
| `VALIDATION_*` | 400 | Field-level validation | Not emitted |

### Media / Content Errors (`MEDIA_`)

| Code | HTTP Status | Description | Current reality |
|------|------------|-------------|-----------------|
| `MEDIA_NOT_FOUND` | 404 | Content does not exist | paax-api returns 404 with `detail`, no `code` |
| `MEDIA_UNAVAILABLE` | 451/404 | Region/rights restricted | Manifests as Worker `PLAYABILITY_*` / backend `GEO_BLOCKED` |
| `MEDIA_STREAM_EXPIRED` | 410 | Stream URL expired | Manifests as stream `CDN_FORBIDDEN` / Worker re-resolve |

### Player / Rate / Internal

| Code | HTTP Status | Current reality |
|------|------------|-----------------|
| `PLAYER_SOURCE_UNAVAILABLE` | 502 | Corresponds to stream `UPSTREAM_UNAVAILABLE` / Worker `ALL_CLIENTS_BLOCKED` |
| `RATE_LIMIT_EXCEEDED` | 429 | paax-api has **no rate limiting**; only the stream proxy emits `RATE_LIMITED` (upstream CDN). See [tech debt](TECH_DEBT.md) |
| `INTERNAL_SERVER_ERROR` | 500 | Surfaces as FastAPI 500 with `str(e)` — leakage risk |

---

## Adding a New Error Code

1. Decide the originating layer (paax-api / paax-stream / Worker / backend / client).
2. Name it descriptively in `SCREAMING_SNAKE_CASE`.
3. Add it to the correct section above with HTTP status + client action.
4. Implement it (and prefer a structured body over `str(e)` — do not leak internals).
5. Update [`docs/api.md`](api.md) for the affected endpoints.

---

*Last updated: 2026-07-16*
