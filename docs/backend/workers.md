# Workers

> **Purpose**: Documents all background worker processes — what they do, how they are triggered, their schedule (if any), and their failure handling behavior.
> **Update when**: A new worker is created, a worker's schedule changes, or error handling behavior changes.

> **See also**: [`queue.md`](queue.md) (why there is no job queue), [`services.md`](services.md) (stream resolvers), [`cache.md`](cache.md), [`../ERROR_CODES.md`](../ERROR_CODES.md).

---

## What is a Worker?

> **There are no classic background workers in Paax** — no Celery, no BullMQ, no Sidekiq, no scheduled cron jobs, no long-running consumer processes. The template assumes a queue-fed worker fleet; that does not exist (see [`queue.md`](queue.md)).

Two things legitimately occupy the "worker" role, and this doc documents them honestly:

1. **The Cloudflare Worker** — the only thing literally called a "worker" in the stack: an **edge stream-URL resolver**. It is the primary subject of this file.
2. **Fire-and-forget prefetch** in the legacy backend — an un-awaited coroutine that warms a cache, the nearest thing to a background task.

---

## Worker Infrastructure

- **Worker Runtime**: **Cloudflare Workers** (V8 isolate at the edge, JS). No Celery/BullMQ/asyncio worker daemon.
- **Message Broker**: **Not applicable** — the Worker is invoked by HTTP request, not by a queue ([`queue.md`](queue.md)).
- **Scheduler**: **Not applicable** — no cron, no scheduled/recurring jobs anywhere.

---

## Worker Inventory

| Worker | Trigger | Schedule | File | Description |
|--------|---------|----------|------|-------------|
| **Cloudflare stream resolver** ("v6") | HTTP `GET /{videoId}` | — (on-demand) | `cloudflare-worker/` | Resolves a direct progressive-audio CDN URL for a videoId via YouTube Innertube |
| **legacy prefetch** | HTTP `POST /playback/prefetch` | — (fire-and-forget) | `backend/main.py` | Un-awaited resolve to warm the resolve cache before playback |
| `EmailWorker` / `ThumbnailWorker` / `SyncWorker` / `CleanupWorker` | — | — | — | **Do not exist** — no email, no server-side image processing, no scheduled sync/cleanup |

---

## Worker Specs

---

### Cloudflare stream resolver (`stream.paaxmusic.app`, "v6")

**File**: `cloudflare-worker/`
**Trigger**: HTTP request; the **last path segment is the videoId**, validated against `^[a-zA-Z0-9_-]{11}$`.
**Concurrency**: handled by the Cloudflare runtime (per-request isolates); no app-level concurrency control.
**Env vars**: **none** (`[vars]` empty; Innertube is called unauthenticated).

**What it does**: calls YouTube's Innertube player API (`youtubei/v1/player`) to obtain a direct progressive audio CDN URL, trying a **client waterfall** until one returns a usable format:

```
ANDROID → ANDROID_VR → ANDROID_TESTSUITE → TVHTML5_SIMPLY_EMBEDDED → IOS
```

**Format selection**: prefers **itag 140** (audio-only mp4/m4a/AAC). Rejects webm/opus and DASH/adaptive-only responses — the goal is a single progressive URL a plain `<audio>`/IFrame can consume.

**Caching**: the resolved URL is stored in `caches.default` (edge cache) with **TTL 300s** ([`cache.md`](cache.md)). Cheap re-hits within 5 minutes avoid re-calling Innertube.

```mermaid
flowchart TD
  Q["GET /{videoId}"] --> V{videoId matches<br/>^[A-Za-z0-9_-]{11}$?}
  V -- no --> E1[400]
  V -- yes --> C{caches.default hit?}
  C -- yes --> R[return cached CDN URL]
  C -- no --> W["Innertube client waterfall<br/>ANDROID → … → IOS"]
  W --> F{itag 140 progressive<br/>audio found?}
  F -- yes --> P[cache 300s + return URL]
  F -- no, next client --> W
  F -- all exhausted --> E2[error map]
```

**Error map** (from the Innertube `playabilityStatus`, surfaced as stable outcomes — see [`../ERROR_CODES.md`](../ERROR_CODES.md)):

| Upstream condition | Meaning |
|--------------------|---------|
| `LOGIN_REQUIRED` / bot check | Video needs auth / bot-gated |
| `UNPLAYABLE` | Geo-block or restricted |
| `ERROR` / not found | Video unavailable |
| no acceptable format after waterfall | Format unavailable |

**On success**: returns the CDN URL (and caches it). **On failure**: returns the mapped error; there is no retry queue — the waterfall *is* the retry strategy, across clients.

> **Status**: this is a live, deployed edge resolver ("v6"), but note the **shipping Flutter app does not currently route playback through it** — it plays the `videoId` directly in a YouTube IFrame. The Worker is a parallel/alternative generation of the streaming path ([`services.md`](services.md), [`architecture`](../architecture.md)).

---

### Legacy prefetch (fire-and-forget)

**File**: `backend/main.py` (`POST /playback/prefetch`)
**Trigger**: HTTP call from the client ahead of playback.
**Schedule**: none.
**Concurrency**: none managed — it launches an un-awaited coroutine.

**Input**: a `videoId` to warm.
**Behavior**: kicks off the yt-dlp resolve **without awaiting**, populating the resolve cache (TTL 1800s) so a subsequent `/playback/resolve` is a cache hit ([`cache.md`](cache.md)). This is the closest thing to a background task in the codebase — but it is **not durable, not retryable, and not idempotent-by-design**; if the process restarts, the in-flight prefetch is lost. Superseded along with the rest of the legacy backend.

> The legacy resolver it feeds classifies failures via `_classify_yt_error` → `BOT_CHECK`/`GEO_BLOCKED`/`VIDEO_UNAVAILABLE`/`FORMAT_UNAVAILABLE`/`NETWORK_ERROR`/`RESOLVE_FAILED` ([`services.md`](services.md)).

---

## Worker Rules

Mapped to reality:
- **Idempotent**: the Cloudflare resolver is naturally idempotent (pure function of videoId + cache). The legacy prefetch is best-effort, not guaranteed idempotent.
- **Structured logging / heartbeats / last-run tracking**: **not implemented** — there are no long-running or scheduled workers to instrument. The Cloudflare Worker relies on Cloudflare's request logs.
- **Workers must not call other workers**: trivially satisfied — the resolver calls only Innertube.

---

## Monitoring

- **Dashboard**: Cloudflare's built-in Workers analytics/logs for the resolver. No Flower/Bull Board (nothing to show — no queue/worker fleet).
- **Alerts**: none wired. Failure visibility for the resolver is via Cloudflare logs and the error map returned to callers.
- The orphaned paax-stream resolver stack ([`services.md`](services.md)) is **not** a worker and is not deployed as one — it is unmounted dead code.

---

*Last updated: 2026-07-16*
