# Performance

> **Purpose**: Documents performance budgets, known bottlenecks, optimization strategies, and measurement tooling. Agents should read this before making changes that could impact performance.
> **Update when**: A new performance budget is set, a bottleneck is identified, or a significant optimization is implemented.

---

## Performance Budgets

> No formal, instrumented budgets are enforced today (no APM/RUM). The targets below are **proposed** and marked accordingly; "Current" is qualitative until measurement tooling is added ([IDEAS.md](IDEAS.md)).

### Mobile App

| Metric | Budget (proposed) | Current | Status |
|--------|-------------------|---------|--------|
| App startup (cold) | < 2 s | Fast — Hive init + adapter registration only; no network on boot | 🟢 (unmeasured) |
| Screen transition | Instant on Android (by design) | `_FastPageTransitionBuilder` returns child unchanged | 🟢 |
| Frame rate | 60 fps steady | Generally smooth; risk areas are image-heavy scroll on web | 🟡 (unmeasured) |
| Memory usage | < 250 MB active | WebView player + image caches dominate | 🟡 (unmeasured) |

### API (paax-api)

| Metric | Budget (proposed) | Current | Status |
|--------|-------------------|---------|--------|
| p95 (cache HIT) | < 150 ms | Fast — Redis/memory return | 🟢 (unmeasured) |
| p95 (cache MISS, no match) | < 800 ms | Deezer round-trip | 🟡 |
| p95 (cache MISS, with YouTube match) | < 3 s | Multi-second — up to 3 `yt-dlp` searches/track | 🔴 (the real bottleneck) |
| Error rate | < 1% | Dominated by upstream YouTube blocks | 🟡 |

---

## Known Bottlenecks

| Bottleneck | Location | Impact | Status | Mitigation |
|------------|----------|--------|--------|------------|
| **Eager YouTube matching** | paax-api `hybrid_*` / `youtube_matcher` | Cold-cache track endpoints take seconds; rate-limit exposure | Open | 7-day match cache; `Semaphore(3/5)`; per-track 15–30 s timeout. Consider lazy/deferred matching |
| **Image 429s** | Google/Deezer image hosts on web | Broken/blank artwork under bursty load | Mitigated | Serial queue (web `maxConcurrent=1`), per-host backoff, domain sharding — see below |
| **`yt-dlp` search cost** | `ThreadPoolExecutor(max_workers=3)` | CPU + latency per uncached track | Open | Bounded pool + semaphore |
| **Full playlist/album track lists** | client rendering | Long lists | Mitigated | `SliverList`/`ListView.builder`, keep-alive tabs |
| **WebView memory** | mobile playback | RAM pressure | Accepted | Single hidden player instance reused |

---

## Optimization Strategies

### Frontend / Mobile (implemented)

- [x] **Lazy, on-screen-only image loading** — `AppImage` + `VisibilityDetector` never load off-screen images.
- [x] **Image request throttling** — `ImageRequestQueue` (web `maxConcurrent=1`, mobile 4), priority queues (onScreen/nearScreen/offScreen), global pause on 429.
- [x] **Per-host exponential backoff** — `HostThrottleState` (2 s → 60 s + jitter).
- [x] **Domain sharding** — `Lh3UrlBuilder` rotates `lh3`→`lh3/4/5/6` by `url.hashCode % 4` (stable per-URL) to spread load.
- [x] **Strict image sizing** — request `=w-h` sized variants (160/256/512/720/1080) instead of full-res.
- [x] **Disk + memory image caches** — `ImagePipeline`/`PlatformCacheManager` (mobile disk 30 d; web memory-only LRU).
- [x] **Minimal rebuilds** — high-frequency position/duration via `ValueNotifier` (`positionNotifier`/`durationNotifier`) instead of `notifyListeners`; `context.select`/`Selector` for narrow rebuilds.
- [x] **Throttled position stream** — 250 ms, ignores small backward jumps and pauses during scrubbing.
- [x] **60 fps interpolation** — `SmoothAudioProgressBar` uses a `Ticker` between 250 ms syncs.
- [x] **Two-phase artist rendering** — render `getArtistBasic` immediately, enrich releases in the background.
- [x] **Tab keep-alive** — `IndexedStack` + `AutomaticKeepAliveClientMixin` preserve scroll/state across tab switches.
- [x] **Instant Android page transitions** — deliberate, removes perceived nav latency.

> Two overlapping image-cache/throttle generations (`core/image/*` vs `core/network/*`) coexist; consolidating them is a debt item ([TECH_DEBT.md](TECH_DEBT.md)).

### Backend / API (implemented)

- [x] **Two-tier caching** — Redis + in-memory LRU(500); TTLs: search 15 m, home/artist/chart 6 h, album 24 h; **YouTube match cache 7 days** (video IDs are stable). See [CACHE_STRATEGY.md](CACHE_STRATEGY.md), [backend/cache.md](backend/cache.md).
- [x] **TTL jitter (0–60 s)** — thundering-herd mitigation.
- [x] **Concurrency caps** — `asyncio.gather` + `Semaphore(3)` (chart 5) bound parallel matching; `yt-dlp` in a bounded thread pool.
- [x] **Parallel Deezer fetches** — artist profile fetches (`get_artist`/`top`/`albums`/`related`) run via `asyncio.gather`.
- [ ] Response compression / pagination limits — not explicitly configured.
- [x] **Edge caching** — Cloudflare Worker caches resolved stream URLs 5 min.

### Streaming (implemented)

- [x] **Client-side playback** — audio streams directly from the `googlevideo` CDN via the YouTube IFrame, so Paax serves **no audio bytes** on the live path (the biggest bandwidth save).
- [x] **IPv6 rotation** (paax-stream, standby) — spreads CDN requests across 16 source IPs to dodge per-IP rate limits.

### Database

- **Live path**: unchanged — client Hive access is O(1) box lookups; the only tuning is the startup de-dup migrations (run once). See [database.md](database.md).
- **Supabase (Phase 1, deployed but unconsumed)**: performance groundwork is in place — every FK indexed, `pg_trgm` GIN indexes on normalized names (artists/albums/tracks) for similarity search, and partial indexes for the hot subsets (pending YouTube matches, active stories, active subscriptions, active devices, unread notifications). Trigger-maintained **counter denormalization** (followers/likes/plays/playlist totals) avoids hot-path aggregation. **No measured baselines exist yet** — nothing queries this database, so all Supabase-side numbers are unmeasured; do not cite latency figures until Phase 2 integration produces real measurements. See [backend/database-schema.md](backend/database-schema.md).

---

## Profiling & Measurement

| Tool | What It Measures | Usage |
|------|-----------------|-------|
| Flutter DevTools | Rebuild counts, frame timing, memory | `flutter run --profile` |
| `PlaybackDiagnostics` overlay | Playback stage timing (dev-only) | `PlaybackDiagnosticsNotifier` + `playback_debug_overlay` |
| paax-api `/cache/status` | Redis reachability, memory-cache hits/misses/size | `GET /cache/status` |
| `X-Cache` header | Per-response cache HIT/MISS | inspect responses |
| `[Perf]` debug logs | e.g. `getArtist($id) v2 completed in Xms` | debug builds only |

No Sentry/Datadog/Firebase Performance is wired — adding RUM + APM is a backlog item.

---

## Caching Strategy

Paax caches at three layers — **server** (Redis + in-memory LRU in paax-api), **edge** (Cloudflare Worker), and **client** (repo in-memory + on-disk images). Server TTLs are summarized under [Backend / API](#backend--api-implemented) above (search 15 m; home/artist/chart 6 h; album 24 h; YouTube match 7 days). The Worker caches resolved stream URLs 5 min; paax-stream keeps IPv6 sessions 30 min; the client keeps an album-detail cache for the app session and images on disk (mobile 30 d) / memory (web).

The **canonical, per-layer cache registry** — every key, TTL, and invalidation rule — lives in [CACHE_STRATEGY.md](CACHE_STRATEGY.md); the backend-scoped view is [backend/cache.md](backend/cache.md).

---

## Performance Review Checklist

- [ ] No new synchronous work on the UI thread (isolate heavy work)
- [ ] New list screens use `ListView.builder`/`SliverList` (never a giant `Column`)
- [ ] New images go through `AppImage` (throttled + sized), never raw `Image.network` on hot paths
- [ ] New metadata endpoints are cached with an explicit TTL
- [ ] New per-track YouTube matching respects the shared semaphore + match cache
- [ ] `flutter run --profile` shows no new jank on the affected screen

See also [OPTIMIZATION_LOG.md](OPTIMIZATION_LOG.md) for the change history and [`.claude/rules/performance.md`](../.claude/rules/performance.md).

---

## Architecture Review Findings (2026-07-16)

The [Architecture Review](architecture-review.md) §3 (Performance) and §6 (Scalability) expand on the bottlenecks above:

- **Lazy matching** — return metadata immediately with `matchStatus: pending` and resolve the `videoId` on demand, moving the multi-second `yt-dlp` cost off the metadata path (`AR-PERF-01`, `AR-API-05`).
- **Offline pre-compute worker** — match the popular catalog into the 7-day cache ahead of demand (`AR-SCALE-01`) — the single biggest scalability lever.
- **Add `GZipMiddleware`** — responses are currently uncompressed (`AR-PERF-04`).
- **Cache the uncached hot endpoints** (`/v2/search`, `/v2/track`, `/v2/artist/top`, `/lyrics`) and emit HTTP cache headers so Cloudflare/browsers can cache (`AR-CACHE-01`, `AR-CACHE-02`).
- **Observability** (APM/RUM/structured logs) is a prerequisite for enforcing the budgets above (`AR-SCALE-05`).

Full detail with evidence: [architecture-review.md](architecture-review.md).

---

*Last updated: 2026-07-16*
