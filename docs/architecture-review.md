# Architecture Review

> **Purpose**: A software-architect's assessment of the Paax codebase — every material improvement opportunity, categorized, with evidence, impact, and a recommendation. **This document records findings only; it does not implement them.**
> **Update when**: A finding is addressed (mark it Resolved with the commit), re-prioritized, or a new systemic issue is discovered.

**Reviewer**: architecture review (AI agent) · **Date**: 2026-07-16 · **Scope**: `frontend/`, `paax-api/`, `paax-stream/`, `cloudflare-worker/`, `backend/`.

This review complements the honest status docs already in the repo — [TECH_DEBT.md](TECH_DEBT.md), [KNOWN_ISSUES.md](KNOWN_ISSUES.md), [security.md](security.md), [performance.md](performance.md), [CACHE_STRATEGY.md](CACHE_STRATEGY.md), [database.md](database.md), [api.md](api.md) — by consolidating them into a single prioritized architectural view and adding new findings. Where a finding also lives in a canonical doc, that doc links back here.

---

## How to read this

- Each finding has an **ID** (`AR-<CATEGORY>-<n>`), a **severity** (Critical / High / Medium / Low), an **effort** (S ≤ 1 day · M ≤ 1 week · L > 1 week), **evidence** (file/behavior), **impact**, and a **recommendation**.
- Severity is *architectural* risk, not user-visible bug count. "Critical" = blocks a credible public launch or is an active data/security risk.
- Nothing here is a directive to change code now — it is the backlog an architect would hand to the team. Actionable items should graduate into [tasks/backlog.md](tasks/backlog.md) and [roadmap.md](roadmap.md).

---

## Executive summary

Paax is a well-conceived product with a genuinely clever core (Deezer metadata + YouTube playback) and a surprisingly polished client. Its weaknesses are the classic ones of a fast-moving solo project: **no seams for testing** (no DI, no test suite), **several half-finished parallel implementations** (three streaming generations, two image-cache stacks, v1/v2 endpoints, demo auth), and **production-hardening gaps** (TLS disabled on one client, debug signing, no rate limiting, no observability). None of these are hard to fix individually; the risk is that they compound.

The three things that most limit the project today:

1. **Eager YouTube matching** is the central scalability and latency bottleneck (`AR-PERF-01`, `AR-SCALE-01`).
2. **Client-only Hive storage with demo auth** caps the product at "single-device demo" — no accounts, no sync, data lost on uninstall (`AR-SCALE-06`, `AR-DB-05`).
3. **No test seams / no tests** make every change riskier than it should be (`AR-MA-01`, `AR-FL-06`).

### Top 12 by priority

| # | ID | Finding | Severity | Effort |
|---|----|---------|----------|--------|
| 1 | AR-SEC-01 | Deezer HTTP client disables TLS verification (`verify=False`) | Critical | S |
| 2 | AR-SEC-02 | Unauthenticated write endpoints act on a shared YouTube account | Critical | M |
| 3 | AR-SEC-03 | Release Android build signs with debug keys | Critical | S |
| 4 | AR-PERF-01 | Eager per-track YouTube matching (multi-second cold path) | High | L |
| 5 | AR-MA-01 | No dependency injection → no test seams; fragmented repo instances | High | M |
| 6 | AR-CACHE-01 | `/v2/search`, `/v2/track`, `/v2/artist/top`, `/lyrics` not endpoint-cached | High | S |
| 7 | AR-SEC-04 | No rate limiting or input validation on paax-api | High | M |
| 8 | AR-API-01 | Inconsistent error contract; `str(e)` leaked to clients | High | M |
| 9 | AR-SCALE-06 | Client-only storage: no sync/backup, data lost on uninstall | High | L |
| 10 | AR-TD-01 | Three parallel streaming generations; large dead-code surface | High | M |
| 11 | AR-FL-06 | Zero automated tests / no CI | High | M |
| 12 | AR-UX-01 | No offline/network-loss feedback in the player | Medium | S |

---

## 1. Technical Debt

See [TECH_DEBT.md](TECH_DEBT.md) for the living register; the highest-leverage items are consolidated here.

- **AR-TD-01 — Three coexisting streaming generations + dead resolver code.** *(High, M)* IFrame (live), Cloudflare Worker (Innertube), and `paax-stream` (IPv6 proxy) all resolve YouTube audio differently; the legacy `backend` `/stream` is broken. `paax-stream`'s entire `resolver/`, `providers/`, `services/` tree is orphaned (imports missing modules; `yt_dlp` not in `requirements.txt`). **Impact**: operational confusion, rot, "which one is real?" onboarding cost. **Recommendation**: pick one server resolver as the IFrame fallback, delete the rest. Tracked by [decisions.md](decisions.md) ADR-006.
- **AR-TD-02 — Dead client code.** *(Medium, S)* `data/api/deezer_api_client.dart` and `core/playback/media_session_web.dart` are fully commented out; `core/constants/api_constants.dart` and `core/config/app_config.dart` are unreferenced by the live v2 path; `playback_diagnostics.dart` models an obsolete resolve-based architecture. **Recommendation**: delete (git preserves history) or gate behind a clearly-labeled experiments module.
- **AR-TD-03 — Two overlapping image pipelines.** *(Medium, M)* `core/image/*` and `core/network/*` are two generations of the same concern, with two separate `WebMemoryCache` classes. **Impact**: double the surface area, unclear which path a given widget uses. **Recommendation**: converge on one pipeline (`AR-FL-04`).
- **AR-TD-04 — v1/v2 duplication in the client repository.** *(Medium, M)* `MusicRepositoryImpl` still carries the full set of legacy v1 mappers (`_mapTrack`, `_mapAlbumDetail`, …) alongside the v2 mappers, plus an unused private `_enrichArtistReleases`. **Recommendation**: excise v1 mappers once v1 endpoints are retired.
- **AR-TD-05 — Branding & config drift.** *(High for release, S)* Package is `beaty`, Android `applicationId` is `com.beaty.music.beaty`, several READMEs still say "Beaty," dual config files (`api_config.dart` live vs `app_config.dart` legacy). **Recommendation**: complete the rename; delete `app_config.dart`.
- **AR-TD-06 — Stale/lying comments.** *(Low, S)* `playback_factory.dart` claims `just_audio`; `app_theme.dart` comment says "Manrope" while code uses Roboto. **Recommendation**: fix comments in the same PRs that touch those files.
- **AR-TD-07 — Unbounded process cache.** *(Medium, S)* `paax-api/services/youtube/youtube_cache.py` keeps a plain-dict `_memory_cache` with no eviction (unlike the bounded `MemoryCache(500)` in `cache.py`). **Impact**: unbounded memory growth per process. **Recommendation**: bound it (LRU + TTL) or rely solely on Redis.

---

## 2. Missing Abstractions

- **AR-MA-01 — No dependency injection; fragmented repository instances.** *(High, M)* `MusicRepositoryImpl()` is constructed directly inside `SearchController` and **seven screens** (`home_screen`, `album_detail_screen`, `artist_detail_screen`, `artist_items_screen`, `genre_results_screen`, `track_detail_screen`, …). **Two impacts**: (1) nothing can be mocked → the code is effectively untestable at the unit level; (2) each instance owns its **own** `_albumDetailCache`, so the album-detail cache is **fragmented across screens** — the same album is re-fetched when opened from different screens. **Recommendation**: provide a single `MusicRepository` via `Provider`/`get_it` and inject it; makes the cache shared and the controllers testable.
- **AR-MA-02 — No typed error/result model.** *(High, M)* Errors are handled by try/catch-and-`debugPrint`-and-skip in mappers, `rethrow` in the repo, and string classification in `ErrorStateWidget` (it parses "404"/"network"/"timeout" out of exception text). **Impact**: brittle, lossy, untestable error handling. **Recommendation**: introduce a `Result<T, Failure>` (or sealed `Failure` types) at the repository boundary; map failures to UI states explicitly.
- **AR-MA-03 — Leaky playback identity.** *(Medium, M)* `Track.id` is overloaded to hold the **YouTube videoId** (v2), conflating *identity* with *how to play*. **Impact**: a track has no stable catalog identity independent of its current match; re-matching or multi-source playback becomes awkward. **Recommendation**: keep a stable `deezerId` as identity and a separate `PlaybackRef { provider, videoId, confidence }`.
- **AR-MA-04 — `List<dynamic>` in the domain model.** *(Medium, M)* `Artist.albums/singles/topTracks` are `List<dynamic>` to dodge a Hive-gen circular dependency with `SavedAlbum`. **Impact**: type safety lost across the whole artist-profile path. **Recommendation**: store ids/references and hydrate, or split into separate typed boxes, or use a codegen-friendly reference type.
- **AR-MA-05 — No use-case / service layer on the client.** *(Medium, M)* Controllers call the repository directly and hold business logic (queue math, enrichment orchestration, dedup). **Impact**: logic is coupled to `ChangeNotifier`s and hard to reuse/test. **Recommendation**: extract domain use-cases (`PlayQueue`, `EnrichArtist`, `ToggleLike`) invoked by thin controllers.
- **AR-MA-06 — Duplicated mapping logic.** *(Low, M)* Artist-list parsing / view-count filtering is repeated across `Track`, `SavedAlbum`, `Artist` mappers and again server-side in `deezer_mapper`. **Recommendation**: a single shared "artist credits" parser.
- **AR-MA-07 — No provider/HTTP abstraction on the backend.** *(Medium, M)* `paax-stream` providers duplicate `client`/`selector` logic; paax-api's `YouTubeMusicDataSource` client-side and the Deezer client have no shared retry/backoff/interceptor base. **Recommendation**: a `BaseProvider` + a shared HTTP client with interceptors (retry, backoff, cache headers).
- **AR-MA-08 — Fake pagination abstraction.** *(Low, S)* `getArtistAlbumsPage(id, params, token)` returns a `(items, null)` token because Deezer paginates by offset/limit, not tokens. **Recommendation**: replace with an honest offset/limit cursor or drop the token parameter.

---

## 3. Performance Bottlenecks

See [performance.md](performance.md) for budgets and mitigations already in place.

- **AR-PERF-01 — Eager YouTube matching on the request path.** *(High, L)* Every uncached track triggers up to **three** `yt-dlp ytsearch` calls through a `ThreadPoolExecutor(max_workers=3)` + `Semaphore(3)` (chart `Semaphore(5)`). Cold-cache `/v2/search`/`/v2/album` responses are multi-second. **Recommendation**: make matching **lazy** — return metadata immediately with `matchStatus: pending` and resolve the `videoId` on demand (a dedicated `/v2/resolve/{trackId}` the client calls at play time), and/or precompute matches for popular catalog offline.
- **AR-PERF-02 — `yt-dlp` is a heavyweight, fragile matcher.** *(High, M)* Spawning `yt-dlp` per query is CPU-heavy and breaks with YouTube changes. **Recommendation**: evaluate a lighter search (Innertube search, already used in the Worker) and share one matcher implementation across services.
- **AR-PERF-03 — Uncached hot endpoints.** *(High, S)* `/v2/search`, `/v2/track`, `/v2/artist/{id}/top`, and `/lyrics` are **not endpoint-cached** (confirmed: no `cache_set` around the `/lyrics` handler). Repeated identical queries redo Deezer + matching + LRCLIB work. See `AR-CACHE-01`.
- **AR-PERF-04 — No response compression.** *(Medium, S)* paax-api mounts only `CORSMiddleware`; JSON responses (large artist/album/chart payloads) are uncompressed. **Recommendation**: add `GZipMiddleware`.
- **AR-PERF-05 — Web image loading is serialized.** *(Medium, M)* To survive 429s, web `ImageRequestQueue` runs `maxConcurrent=1`. **Impact**: slow first paint on image-dense screens. **Recommendation**: a server/edge image proxy (below) would let the client parallelize safely.
- **AR-PERF-06 — Fragmented client album cache.** *(Medium, S)* Per-screen repository instances (`AR-MA-01`) defeat the in-memory album cache. **Recommendation**: shared repository instance.
- **AR-PERF-07 — Small server memory cache under multi-user load.** *(Low, M)* `MemoryCache(max_size=500)` per instance is tiny for many concurrent users; Redis is the real cache, and per-instance memory caches can diverge. **Recommendation**: treat Redis as authoritative; size/monitor the memory tier.

---

## 4. Missing Indexes

Paax has **no relational database**, so "indexes" reinterpret across the two stores that exist plus the future server DB.

- **AR-IDX-01 — Client library operations are linear and recomputed.** *(Medium, M)* `LibraryController._loadData()` reloads **all** boxes into lists on every mutation, and library tabs filter/sort **in memory** on each rebuild. Keyed lookups (`isLiked`, `isAlbumSaved`) are O(1), but list rebuilds and sorts are O(n) per change. **Impact**: fine at hundreds of items, degrades at thousands. **Recommendation**: maintain in-memory indexes (e.g., a `Set<String>` of liked ids already exists conceptually; add sorted views / lazy box queries) or move to a queryable local store (`AR-DB-06`).
- **AR-IDX-02 — No reverse index for match cache.** *(Low, S)* `yt_match:<hash>` is keyed by artist/title/duration; there is no index from `videoId` → tracks, so invalidating a bad match means scanning. **Recommendation**: add a secondary key if match invalidation becomes a need.
- **AR-IDX-03 — Future server schema needs an index plan.** *(High when auth lands, M)* When cloud sync/auth is introduced (`AR-DB-05`), the tables (`users`, `playlists`, `playlist_tracks`, `likes`, `follows`, `saved_albums`) must index every FK and filter/sort column (`user_id`, `playlist_id`, `track_id`, `created_at`) per [`.claude/rules/database.md`](../.claude/rules/database.md). **Recommendation**: capture the index plan in [database.md](database.md) *before* building the schema.

---

## 5. Missing Cache

See [CACHE_STRATEGY.md](CACHE_STRATEGY.md) for the current registry.

- **AR-CACHE-01 — Uncached hot endpoints.** *(High, S)* Add endpoint caching for `/v2/search` (short TTL, e.g. 5–15 min), `/v2/track`, `/v2/artist/{id}/top`, and `/lyrics` (long TTL — lyrics are stable). Today only search(v1)/home/artist/album/chart are endpoint-cached. **Impact**: avoidable Deezer/LRCLIB/matching load.
- **AR-CACHE-02 — No HTTP cache headers / CDN in front of paax-api.** *(High, M)* Responses carry no `Cache-Control`/`ETag`, so browsers and Cloudflare cannot cache GET metadata. **Recommendation**: emit `Cache-Control` matching the internal TTLs and put metadata GETs behind Cloudflare edge caching (paax-api already lives behind Cloudflare DNS).
- **AR-CACHE-03 — No persistent client metadata cache.** *(Medium, M)* The client's album cache is in-memory only (lost on restart); the `stream_candidates` Hive box is declared but unused; lyrics cache is in-memory (`LyricsService`). **Impact**: cold starts re-fetch everything; browsing isn't available offline. **Recommendation**: persist a bounded metadata cache (recently viewed albums/artists) to Hive for instant cold start and basic offline browse (feeds `AR-UX-02`).
- **AR-CACHE-04 — No image proxy/CDN.** *(Medium, L)* Artwork is fetched directly from Google/Deezer hosts, forcing the 429 throttling that serializes web loads (`AR-PERF-05`). **Recommendation**: an edge image-resize proxy (Cloudflare Images / a Worker) would cache, resize, and remove the client throttling burden.
- **AR-CACHE-05 — No negative cache for hard failures.** *(Low, S)* Beyond the match cache's no-match entries, transient upstream failures aren't negatively cached, so a flapping upstream is retried hot. **Recommendation**: short-TTL negative caching for 5xx upstreams.

---

## 6. Future Scalability Concerns

- **AR-SCALE-01 — Matching throughput ceiling.** *(High, L)* The `ThreadPoolExecutor(3)` + `Semaphore(3)` matching path caps per-instance throughput and is CPU-bound. Under many concurrent cold users it will queue and time out. **Recommendation**: lazy matching (`AR-PERF-01`) + an **offline pre-compute worker** that matches the popular catalog into the 7-day cache (this is the single biggest scalability lever).
- **AR-SCALE-02 — Single shared YouTube account.** *(High, M)* `YTMUSIC_OAUTH_JSON` is one account for all authenticated ytmusicapi calls — a rate-limit and single-point-of-failure risk, and a correctness risk (all users share its library). **Recommendation**: remove reliance on it for anything user-facing; if kept, pool credentials.
- **AR-SCALE-03 — YouTube IP blocking.** *(High, M)* Both matching (`yt-dlp`) and the IPv6 proxy depend on not being blocked by YouTube. The IPv6 pool is a fixed 16 addresses. **Recommendation**: monitor block rates; make the pool/credentials horizontally scalable; keep the Worker (Innertube) path as a diversified fallback.
- **AR-SCALE-04 — No rate limiting → cost/abuse exposure.** *(High, M)* Open metadata and (worse) open stream resolvers can be driven at will. **Recommendation**: per-IP/token rate limits at the edge (Cloudflare) and in paax-api.
- **AR-SCALE-05 — No observability.** *(High, M)* No APM/RUM/error tracking/structured logs with request IDs. **Impact**: you cannot see, alert on, or diagnose the bottlenecks above at scale. **Recommendation**: structured JSON logs + request IDs, Sentry (client + server), and basic RUM. This is a prerequisite for the performance budgets in [performance.md](performance.md).
- **AR-SCALE-06 — Client-only storage blocks the product.** *(High, L)* Hive-only means no cross-device, no backup, guaranteed data loss on uninstall/`clearAll()`. **Impact**: caps Paax at "single-device demo." **Recommendation**: introduce real auth + a server datastore with sync (the first legitimate reason to add a DB — see `AR-DB-05`).
- **AR-SCALE-07 — Per-instance cache divergence.** *(Low, M)* `MemoryCache` and the process-level match cache diverge across horizontally-scaled instances; only Redis is shared. **Recommendation**: prefer Redis for anything correctness-sensitive.

---

## 7. Security Risks

Consolidated with [security.md](security.md); new items flagged.

- **AR-SEC-01 — TLS verification disabled on the Deezer client.** *(Critical, S)* `paax-api/services/deezer/deezer_client.py` builds `httpx.AsyncClient(verify=False)`. **Impact**: MITM on all catalog metadata, for no benefit (Deezer serves valid certs). **Recommendation**: remove `verify=False`.
- **AR-SEC-02 — Unauthenticated write endpoints on a shared account.** *(Critical, M)* `/rate`, `/playlists*` mutate the shared YouTube account with no auth gate. **Recommendation**: remove from public routing or gate behind operator auth.
- **AR-SEC-03 — Release signed with debug keys.** *(Critical, S)* `android/app/build.gradle` uses `signingConfig signingConfigs.debug` for release. **Recommendation**: real keystore before any store release; keep `assetlinks.json` in sync.
- **AR-SEC-04 — No rate limiting / no input validation.** *(High, M)* paax-api validates nothing (bare `Query(default=…)`) and has no rate limiting. **Recommendation**: pydantic request models + edge/app rate limits.
- **AR-SEC-05 — Error detail leakage.** *(Medium, S)* 500s return `str(e)`. **Recommendation**: stable error codes ([ERROR_CODES.md](ERROR_CODES.md)); log internally, return a generic message. (Also `AR-API-01`.)
- **AR-SEC-06 — Permissive CORS with credentials.** *(Medium, M)* paax-api sets `allow_credentials=True` with `allow_methods=["*"]`, `allow_headers=["*"]`, plus a broad LAN/localhost origin regex. **Impact**: broad browser trust; combined with unauthenticated writes, worth tightening. **Recommendation**: scope methods/headers, drop credentials if unused, restrict the regex to dev builds.
- **AR-SEC-07 — Cleartext traffic enabled in production manifest.** *(Medium, S)* `usesCleartextTraffic="true"` (needed for LAN dev) ships to release. **Recommendation**: scope to debug via manifest placeholders / a network-security config.
- **AR-SEC-08 — Open stream resolvers.** *(Medium, M)* The Cloudflare Worker returns `Access-Control-Allow-Origin: *` with no auth (usable as a general YouTube resolver); `paax-stream` mitigates open-proxy abuse with a host allowlist but is otherwise open. **Recommendation**: token/referrer gating + rate limits on both.
- **AR-SEC-09 — No encryption at rest for Hive.** *(Low, M)* Hive boxes are unencrypted. Low risk today (no server PII), but enable encryption before storing anything sensitive.
- **AR-SEC-10 — No dependency/secret hygiene automation.** *(Medium, S)* No `pub audit`/`pip-audit` in CI, no secret-rotation policy, no Dependabot. **Recommendation**: add scanning + a rotation runbook.
- **AR-SEC-11 — Demo auth in shipping builds.** *(High before launch, M)* Hardcoded `user@gmail.com`/`12345`. **Recommendation**: replace with real auth (`AR-DB-05`).

---

## 8. Database Improvements

Applies to the client Hive store today and the future server DB. See [database.md](database.md).

- **AR-DB-01 — Add a schema-version field + real migration framework.** *(Medium, M)* Evolution is currently imperative de-dup passes in `HiveStorage.init()`. **Recommendation**: store a `schemaVersion` in the settings box and run ordered, idempotent migrations keyed off it.
- **AR-DB-02 — Split card vs detail models for `SavedAlbum`.** *(Medium, M)* `SavedAlbum` persists 5 fields but carries 7 more runtime-only fields — an ambiguous, error-prone model. **Recommendation**: a persisted `AlbumCard` and a transient `AlbumDetail`.
- **AR-DB-03 — Remove `List<dynamic>` from `Artist`.** *(Medium, M)* See `AR-MA-04` — store references/ids or separate boxes instead of untyped lists.
- **AR-DB-04 — Provide export/import.** *(Medium, S)* No way to back up or move a library. **Recommendation**: JSON export/import of the boxes (a cheap stopgap before full sync).
- **AR-DB-05 — Design the server schema for auth + sync.** *(High when it lands, L)* When accounts arrive, model `users`, `playlists`, `playlist_tracks` (junction), `liked_tracks`, `followed_artists`, `saved_albums` with UUID PKs, FK constraints, `created_at/updated_at`, indexes on every FK/filter column, and RLS if Supabase. Store the ER + index plan in [database.md](database.md) first. Note: adopting a server DB reverses [decisions.md](decisions.md) ADR-002 — write a superseding ADR.
- **AR-DB-06 — Consider a queryable local store.** *(Low, L)* If library grows large and client-side sort/filter/search (`AR-IDX-01`) becomes hot, a queryable embedded DB (Isar/Drift) would replace linear Hive scans with indexed queries. Evaluate only if profiling shows a need.

---

## 9. API Improvements

See [api.md](api.md).

- **AR-API-01 — Adopt one consistent error envelope.** *(High, M)* The project's own [`.claude/rules/api.md`](../.claude/rules/api.md) defines `{error:{code,message,details}}`, but paax-api returns FastAPI `{detail}` and leaks `str(e)`; the stream resolvers use a third shape. **Recommendation**: standardize on one envelope + stable codes ([ERROR_CODES.md](ERROR_CODES.md)) across all services.
- **AR-API-02 — Validate requests with pydantic models.** *(High, S)* Replace bare `Query(default=…)` with typed, bounded params (enforce `type ∈ {tracks,albums,artists}`, `limit` max, id formats).
- **AR-API-03 — Cursor pagination + enforced max page size.** *(Medium, M)* List endpoints take `limit` but have no cursor and no hard cap; large artist discographies return everything. **Recommendation**: `?limit=&cursor=` with a max, per [`.claude/rules/api.md`](../.claude/rules/api.md).
- **AR-API-04 — Emit cache headers; publish OpenAPI.** *(Medium, S)* Add `Cache-Control`/`ETag` (`AR-CACHE-02`); FastAPI already generates OpenAPI — expose and document `/docs` as the contract surface.
- **AR-API-05 — Separate metadata from playback resolution.** *(High, L)* A `/v2/resolve/{trackId}` (or reuse the Worker contract) called at play time lets `/v2/*` return instantly with `matchStatus: pending` (`AR-PERF-01`). This also unifies the streaming story (`AR-TD-01`).
- **AR-API-06 — Version deliberately; retire v1.** *(Medium, M)* v1 and v2 coexist without a deprecation policy. **Recommendation**: announce v1 deprecation, add `Deprecation` headers, and plan a `/v3` for the next breaking change.
- **AR-API-07 — Readiness vs liveness; add metrics.** *(Low, S)* `/health` conflates liveness with auth status. **Recommendation**: split `/livez` and `/readyz`, add a `/metrics` endpoint (`AR-SCALE-05`).

---

## 10. Flutter Improvements

See [frontend/state-management.md](frontend/state-management.md), [frontend/widgets.md](frontend/widgets.md), [coding-standards.md](coding-standards.md).

- **AR-FL-01 — Introduce dependency injection.** *(High, M)* Inject `MusicRepository` (and its data source) rather than constructing it in screens/controllers (`AR-MA-01`). Enables testing and a shared cache.
- **AR-FL-02 — Immutable state + explicit async states.** *(Medium, M)* Controllers hold mutable fields and expose ad-hoc booleans. **Recommendation**: immutable state objects (freezed or disciplined `copyWith`) and an explicit `AsyncValue`-style loading/data/error per section — the `.claude/rules` already ask for this.
- **AR-FL-03 — Extract business logic into use-cases.** *(Medium, M)* See `AR-MA-05`; keeps controllers thin and testable.
- **AR-FL-04 — Converge the image pipelines.** *(Medium, M)* One `AppImage` + one cache/throttle stack (`AR-TD-03`).
- **AR-FL-05 — Type-safe persistence.** *(Medium, M)* Remove `List<dynamic>` (`AR-MA-04`); add a schema version (`AR-DB-01`).
- **AR-FL-06 — Add a test suite + CI.** *(High, M)* Start with pure units (mappers, `string_utils`, matcher scoring, `PlaybackController` queue logic, `HiveStorage`), then widget tests for the 5 UI states, then one E2E play-a-track journey. Wire `flutter analyze` + `flutter test` + `pytest` into CI. See [testing.md](testing.md).
- **AR-FL-07 — Localization.** *(Medium, M)* UI strings are hardcoded English, contrary to [`.claude/rules/ui.md`](../.claude/rules/ui.md). **Recommendation**: `flutter_localizations` + ARB files; at minimum en/es (the maintainer and early docs are bilingual).
- **AR-FL-08 — Accessibility.** *(Medium, M)* Missing semantic labels on icon buttons/images, no Reduce-Motion handling, `Responsive.fontSize` does width-based scaling that can fight system text scaling. **Recommendation**: add `Semantics`/`semanticsLabel`, honor `MediaQuery.disableAnimations`, and respect system text scale.
- **AR-FL-09 — Split oversized screens.** *(Low, M)* Some screens exceed the ~80-line guidance and mix layout with data orchestration. **Recommendation**: extract sub-widgets and move loading into controllers/use-cases.
- **AR-FL-10 — Adopt a spacing/token scale.** *(Low, M)* Spacing is ad-hoc numeric literals (`AR-UX`/[design/spacing.md](design/spacing.md)). **Recommendation**: an `AppSpacing` scale and finish tokenizing color usage (some `#121212`/`#080808` hardcoding remains).

---

## 11. UX Improvements

See [features/](README.md#features-docsfeatures) and [design/](README.md#design-docsdesign).

- **AR-UX-01 — No offline/network-loss feedback in the player.** *(Medium, S)* On network loss the IFrame silently stalls; there is no banner, retry, or "no connection" state. **Recommendation**: detect connectivity and surface a recoverable state ([features/player.md](features/player.md)).
- **AR-UX-02 — Library browses offline, but nothing else does.** *(Medium, M)* Hive renders the saved library offline, yet metadata screens and playback need network with no graceful degradation. **Recommendation**: persistent metadata cache (`AR-CACHE-03`) + clear offline affordances.
- **AR-UX-03 — Inert Download button.** *(Medium, L)* Album/playlist screens show a download affordance that does nothing. **Impact**: broken-promise UX. **Recommendation**: hide it until downloads exist, or implement offline ([features/downloads.md](features/downloads.md), [features/offline.md](features/offline.md)).
- **AR-UX-04 — Incomplete 5-state coverage.** *(Medium, M)* Not every screen handles all of loading/loaded/empty/error/offline (the [`.claude/rules/ui.md`](../.claude/rules/ui.md) requirement). **Recommendation**: audit each screen against the five states.
- **AR-UX-05 — Settings is a stub.** *(Low, M)* The Settings entry is a no-op. **Recommendation**: a real screen (playback quality, cache management, theme, about) — see [features/settings.md](features/settings.md).
- **AR-UX-06 — Dark-only; no theme choice.** *(Low, L)* Intentional today ([decisions.md](decisions.md) ADR-007), but a light mode is a common expectation. **Recommendation**: keep dark-first; consider light later.
- **AR-UX-07 — Data loss is a UX problem.** *(High, L)* Uninstall/clear-data destroys the library with no backup (`AR-SCALE-06`). **Recommendation**: sync/backup, or at minimum export/import (`AR-DB-04`) and a clear warning on destructive actions.
- **AR-UX-08 — Discovery is shallow.** *(Low, M)* Recommendations are charts + related artists; "For You" is derived from the single most recent search. **Recommendation**: richer, explainable discovery once analytics/history exist ([features/recommendations.md](features/recommendations.md)).
- **AR-UX-09 — Player feature gaps.** *(Low, M)* No sleep timer, no crossfade/gapless (limited by IFrame), no lyric-driven seek. **Recommendation**: prioritize by demand; note the IFrame constraint on gapless.

---

## Themes & sequencing (architect's recommendation)

Four cross-cutting themes tie most findings together. Address them roughly in this order:

1. **Harden for production** — `AR-SEC-01/02/03/04`, `AR-API-01/02`. Small, high-value, unblock a launch.
2. **Create test seams** — `AR-MA-01` (DI) → `AR-FL-06` (tests + CI). Everything else is safer afterward.
3. **Fix the matching bottleneck** — `AR-PERF-01`/`AR-API-05` (lazy resolve) + `AR-SCALE-01` (pre-compute worker) + consolidate streaming (`AR-TD-01`). This is the core scalability work.
4. **Make data durable** — real auth + server sync (`AR-SCALE-06`, `AR-DB-05`), which also retires demo auth and unlocks the product.

Graduate specific findings into [tasks/backlog.md](tasks/backlog.md) as they are scheduled; record any decision that reverses an ADR (e.g. adopting a server DB) in [decisions.md](decisions.md).

---

*Last updated: 2026-07-16*
