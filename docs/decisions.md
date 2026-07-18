# Architectural Decisions

> **Purpose**: A permanent record of all significant architectural and technical decisions. Prevents re-litigating settled choices and gives agents context for why the system is built the way it is.
> **Update when**: A significant technical decision is made. Never delete entries — mark them as superseded instead.

---

## How to Add an Entry

Copy the template, assign the next ADR number, fill in the fields, set the status.

**Status options**: `ACCEPTED` | `REJECTED` | `SUPERSEDED` | `DEPRECATED` | `OPEN`

---

## Decision Log

---

### ADR-001 — Deezer metadata + YouTube playback ("hybrid v2")

**Date**: 2026 (v2 migration) · **Status**: ACCEPTED · **Author**: uzielcezate · **Deciders**: maintainer

#### Context
Paax needs a large, clean music catalog (correct titles, artists, albums, cover art, release types) **and** actual audio playback — without a music license or hosting costs. YouTube Music metadata (`ytmusicapi`, used by the legacy `backend`) was messy: view-count-strings as artists, OMV vs ATV confusion, inconsistent release types.

#### Decision
Split the two concerns. Use **Deezer's public API** for catalog metadata and **YouTube** for audio. `paax-api` fetches Deezer metadata and, for each track, matches it to the best YouTube `videoId` (scored on duration/title/artist/trust) and returns both together in a `playback` block. The client sets `Track.id = playback.videoId`.

#### Rationale
Deezer gives clean, normalized metadata with no key required; YouTube has the audio. Matching is cacheable (7-day match cache) so the cost is amortized. Alternative — ytmusicapi-only — produced dirtier data and coupled metadata to playback.

#### Consequences
- **Positive**: Clean UI data; free catalog + free audio; metadata cacheable and cheap on repeat.
- **Negative**: Eager matching makes cold-cache endpoints multi-second and rate-limit-exposed; matches can be wrong/low-confidence.
- **Risks**: YouTube anti-bot/format changes; Deezer API changes.

#### Related Decisions
ADR-004 (playback), ADR-006 (streaming generations). See [architecture.md](architecture.md), [backend/services.md](backend/services.md).

---

### ADR-002 — Client-side Hive is the only user datastore (no server DB)

**Date**: 2026 · **Status**: SUPERSEDED by ADR-009 (2026-07-16) — Hive remains the *live client store* until migration, but the "no server DB" decision is reversed.

#### Context
A music app needs to persist a library (liked, playlists, saved albums, followed artists, history). The team is a single maintainer; running/securing a database and per-user accounts is costly.

#### Decision
Store **all** user state on-device in **Hive**. Keep backends **stateless** (caches only). No Postgres, no Supabase, no accounts.

#### Rationale
Zero server-data liability, zero hosting cost for user data, works offline for browsing the library, and dramatically simpler ops. Alternatives (Supabase/Postgres + RLS, as `.claude/rules/*` describe) were deferred as premature.

#### Consequences
- **Positive**: Cheap, private, offline-capable, simple.
- **Negative**: No cross-device sync; **uninstall/logout destroys the library** (no backup); no social features.
- **Risks**: Users lose data; motivates future opt-in cloud sync.

#### Related Decisions
Supersedes the Supabase/Postgres assumptions in `.claude/rules/{database,supabase}.md` (not implemented). See [database.md](database.md), [backend/database-schema.md](backend/database-schema.md).

---

### ADR-003 — Provider + ChangeNotifier for state management

**Date**: 2026 · **Status**: ACCEPTED

#### Context
The app needs app-wide state (auth, library, playback, search, theme). `.claude/rules/flutter.md` suggests Riverpod; templates assumed Riverpod/freezed.

#### Decision
Use **Provider + `ChangeNotifier`** with 5 global controllers, mutable state, and `Consumer`/`Selector`/`context.select` in the UI. Use `ValueNotifier` for high-frequency values (playback position/duration).

#### Rationale
Minimal ceremony for a solo maintainer; no codegen; easy mental model. Performance concerns are handled with targeted `Selector`/`ValueNotifier` rather than a heavier framework.

#### Consequences
- **Positive**: Low friction, small dependency surface.
- **Negative**: Mutable state is easier to misuse; no compile-time immutability (no freezed).
- **Risks**: Rebuild storms if `context.watch` is overused — mitigated by conventions in [coding-standards.md](coding-standards.md).

#### Related Decisions
See [frontend/state-management.md](frontend/state-management.md).

---

### ADR-004 — YouTube IFrame for playback (not stream extraction / `just_audio`)

**Date**: 2026 · **Status**: ACCEPTED

#### Context
Playing YouTube audio can be done by (a) extracting a CDN stream URL and playing it with `just_audio`, or (b) embedding a YouTube IFrame player. Extraction (server yt-dlp / client `youtube_explode`) breaks constantly against YouTube's format/anti-bot changes and risks ToS issues.

#### Decision
Play the matched `videoId` through a **YouTube IFrame**: `youtube_player_iframe` on web, `flutter_inappwebview` on mobile (chosen over `webview_flutter` for `allowBackgroundAudioPlaying`). A JS↔Dart bridge (`PaaxBridge`) plus background-survival tricks (silent oscillator, heartbeat, visibility resume) keep audio alive; `audio_service`/`PaaxAudioHandler` provides the Foreground Service + media notification.

#### Rationale
The IFrame is robust to YouTube changes and requires no fragile extraction. Audio streams directly from Google's CDN, so Paax serves no audio bytes.

#### Consequences
- **Positive**: Resilient, low bandwidth cost, background audio works.
- **Negative**: Heavier than a native audio player; WebView quirks; harder to do gapless/crossfade.
- **Risks**: YouTube could restrict embedded playback.

#### Related Decisions
Makes ADR-006's server resolvers optional. See [features/player.md](features/player.md).

---

### ADR-005 — Aggressive image throttling, backoff, and domain sharding

**Date**: 2026 · **Status**: ACCEPTED

#### Context
Artwork comes from Google (`lh3-lh6.googleusercontent.com`) and Deezer (`dzcdn.net`), which return **HTTP 429** under bursty parallel loads — worst on Flutter Web (the browser, not our client, issues requests).

#### Decision
Build a throttling layer: `ImageRequestQueue` (web `maxConcurrent=1`), per-host exponential backoff (`HostThrottleState`), domain sharding (`Lh3UrlBuilder`, `lh3`→`lh3/4/5/6`), strict `=w-h` sizing, and disk/memory caches. Off-screen prefetch was removed (`thumbnail_prefetcher` deprecated) because it triggered 429s.

#### Rationale
Without this, artwork visibly fails to load. Measured behavior forced serialization on web.

#### Consequences
- **Positive**: Stable artwork under load.
- **Negative**: Slower first paint of many images on web; complexity — **two overlapping generations** (`core/image/*` vs `core/network/*`) now coexist (debt).
- **Risks**: Fragile; consolidation needed.

#### Related Decisions
See [performance.md](performance.md), [design/responsive.md](design/responsive.md), [TECH_DEBT.md](TECH_DEBT.md).

---

### ADR-006 — Multiple streaming generations coexist (IFrame live; Worker + IPv6 proxy standby)

**Date**: 2026 · **Status**: OPEN (needs consolidation)

#### Context
Getting YouTube audio to the player has been attempted several ways as YouTube tightened access: legacy `backend` yt-dlp resolution (now broken), a Cloudflare Worker Innertube resolver (`stream.paaxmusic.app`), and a Python IPv6 byte-proxy (`paax-stream`, `resolver.paaxmusic.app`). Meanwhile the live app plays via IFrame (ADR-004) and doesn't call any resolver.

#### Decision
Keep the IFrame as the live path; retain the Worker and IPv6 proxy as **standby generations** in case IFrame playback is blocked. `ApiConfig.streamBaseUrl` / `MusicRepository.getStreamUrl` remain wired but unused.

#### Rationale
Hedging against YouTube blocking any single method. Deleting the alternatives would remove a fallback if IFrame breaks.

#### Consequences
- **Positive**: Resilience optionality.
- **Negative**: Significant dead/orphaned code (paax-stream resolver stack, legacy backend), operational confusion, stale READMEs.
- **Risks**: Rot; the standby paths may not actually work when needed.

#### Decision needed
Pick one server resolver, wire it as a real fallback behind the IFrame, and delete the rest. Tracked in [tasks/backlog.md](tasks/backlog.md), [TECH_DEBT.md](TECH_DEBT.md).

---

### ADR-007 — Dark-only, "Cinematic Black" UI with disabled blur

**Date**: 2026 (Phase 4/5) · **Status**: ACCEPTED

#### Context
The app pursued an iOS-style "liquid glass" look. Live `BackdropFilter` blur was expensive and buggy across web/OEM devices, causing artifacts and jank.

#### Decision
Ship a **dark-only** theme and **disable runtime blur** in the glass system (`BlurCapability.canBlur()` → false; solid `#111` surfaces + white@0.08 borders + gradient edge fades + static blurred-artwork headers). Keep exactly one live `BackdropFilter` — the full player (blur 55).

#### Rationale
Achieves the intended depth/cinematic feel cheaply and consistently across platforms. The dynamic album-color pipeline (`DominantColorService`→`ThemeState`) provides adaptivity without live blur; `DynamicBackground` is implemented but currently dormant.

#### Consequences
- **Positive**: Consistent, performant, no blur artifacts.
- **Negative**: "Glass" is simulated; no light mode; some dead/dormant color code.
- **Risks**: Naming ("glass", "liquid glass") misleads readers — documented in [design/design-system.md](design/design-system.md).

---

### ADR-008 — Client demo auth; no real user identity

**Date**: 2026 · **Status**: ACCEPTED (interim) — replacement path defined by ADR-009 (Supabase Auth foundation deployed; the client stub remains live until Flutter integration)

#### Context
The app needs an onboarding/login shell, but there is no server user store (ADR-002) and building real auth is out of scope for the current phase.

#### Decision
Ship a **demo auth stub**: hardcoded credentials, always-succeed signup, a locally stored `UserProfile`. Server-side "auth" is a single shared YouTube account for ytmusicapi library ops (not per-user).

#### Rationale
Unblocks the full app flow without standing up an identity provider.

#### Consequences
- **Positive**: Full UX demoable now.
- **Negative**: Not shippable to real users; unguarded shared-account write endpoints.
- **Risks**: Must be replaced before public launch — see [security.md](security.md), [features/authentication.md](features/authentication.md).

---

### ADR-009 — Adopt Supabase for authentication, persistent catalog, social data, and cloud synchronization

**Date**: 2026-07-16 · **Status**: ACCEPTED (Phase 1 deployed) · **Author**: AI agent (directed by uzielcezate) · **Deciders**: maintainer

#### Context (prior state)
ADR-002 kept all user data in on-device Hive with stateless backends: cheap and private, but **uninstall destroys the library**, no cross-device sync, no real accounts (ADR-008's demo stub), no social features, and no monetization path. Metadata was proxied live from Deezer per request (multi-second cold-cache latency), and YouTube matches lived only in a 7-day Redis cache — nothing was durable.

#### Decision
Adopt **Supabase** as Paax's persistent foundation. Responsibility split:

| Component | Responsibility |
|-----------|----------------|
| **Deezer** | Initial canonical external *metadata provider* (source for ingestion) |
| **Supabase Postgres** | Persistent catalog + all user data (library, social, playlists, stories, history) + billing state |
| **Supabase Auth** | Identity & credentials (single authority; server-validated JWT) |
| **Supabase Storage** | Cached artwork (`music-images`), avatars (`user-avatars`), story media (`story-media`) |
| **YouTube** | *Playback-video-ID provider only* — matched IDs stored on `tracks`, no audio bytes ever stored |
| **YouTube IFrame** | **Unchanged** — remains the playback engine (ADR-004 stands) |
| **Redis** | Temporary cache, locking, rate limiting, job state, short-lived query cache (never source of truth) |
| **Billing schema** | Provider-agnostic, Stripe-ready (no live credentials in Phase 1) |

Target flow: `Deezer API + YouTube matcher → Paax backend → Supabase → Flutter`, with Redis as the transient layer.

#### Phase 1 (this ADR's deployed scope)
Schema (34 tables), constraints, indexes (incl. `pg_trgm`), RLS on every table, secure views/functions/triggers, Storage buckets + policies, subscription/billing readiness with seeded plans (premium prices are **provisional placeholders**: 9 900/99 900 mxn minor units), notifications foundation, owner bootstrap script. **Explicitly NOT in Phase 1**: Flutter/paax-api integration, Hive data migration, Deezer ingestion, YouTube matching jobs, Redis jobs, Stripe deployment, playback/queue/UI changes.

#### Security implications
- RLS everywhere; catalog writes, billing, notification creation, counters, and play qualification are service-role/backend-only.
- Clients can never self-assign roles or paid tiers (trigger-guarded privileged columns + policy checks).
- `service_role` key never ships to Flutter; the `private` schema is not API-exposed; all `security definer` functions pin `search_path`.
- Deliberate, documented exceptions: `public_profiles` is a definer view (safe columns only); `billing_events` has RLS with zero policies.
- **Manual step**: Auth password complexity (≥8, upper+lower+digit+symbol) must be set in Dashboard (not MCP-configurable); app-side validation uses `^(?=.*[a-z])(?=.*[A-Z])(?=.*\d)(?=.*[^A-Za-z0-9]).{8,}$`.

#### Migration approach
Versioned SQL in `supabase/migrations/` (11 files), applied via authenticated Supabase MCP, mirrored 1:1 in the repo, each with a documented rollback strategy. No Dashboard-only changes. Hive → Supabase user-data migration is a **later phase** (Hive remains live until then).

#### Rejected alternatives
- **Stay Hive-only** (ADR-002): blocks sync, social, monetization; data-loss-on-uninstall unacceptable long-term.
- **Custom Postgres + hand-rolled auth**: more ops burden, no RLS/Auth/Storage integration for a solo maintainer.
- **Firebase**: NoSQL fits the relational catalog poorly; SQL + RLS + open Postgres preferred.
- **Postgres enums**: rejected for controlled-value text + CHECK (cheap future expansion).
- **pgvector now**: rejected — no consumer yet (revisit with recommendations).

#### Consequences
- **Positive**: durable cross-device data; real identity; social + billing groundwork; catalog becomes cacheable server-side (kills eager per-request matching long-term); clean phased path.
- **Negative**: server data liability (PII → privacy obligations), Supabase dependency/cost, RLS complexity to maintain, dual-store period (Hive + Supabase) until migration completes.
- **Risks**: RLS mistakes = data exposure (mitigated: advisor lints + 24-test verification suite); schema churn during ingestion design; free-tier limits.

#### Phased rollout
1. **Phase 1 (done)** — this foundation.
2. **Phase 2** — backend integration: Deezer ingestion + upsert reconciliation, YouTube matcher writing `tracks.youtube_*`, Redis job dedup/rate limiting.
3. **Phase 3** — Flutter: Supabase Auth sign-in, Hive → cloud migration, cloud-backed library/playlists (Hive as offline cache).
4. **Phase 4** — social (friends/stories UI), notifications delivery.
5. **Phase 5** — Stripe activation (checkout/portal/webhook Edge Functions; scaffolds exist, undeployed).

#### Related
Supersedes ADR-002 · replaces the interim path of ADR-008 · preserves ADR-001 (Deezer+YouTube split) and ADR-004 (IFrame playback). Full schema: [backend/database-schema.md](backend/database-schema.md).

---

### ADR-010 — Phase 2 backend: cache-first catalog, transactional graph upserts, persistent matches

**Date**: 2026-07-17 · **Status**: ACCEPTED (deployed) · **Author**: AI agent (directed by uzielcezate)

#### Context
ADR-009 Phase 1 shipped the schema; the app still proxied Deezer live per request
(multi-second cold latency, eager YouTube matching) with matches only in a 7-day
Redis cache. Phase 2 makes Supabase the persistent catalog source of truth.

#### Decision
`paax-api` becomes Supabase-first with Redis as a transient layer:
- **Reads**: Redis response cache → Supabase (fresh / stale-while-revalidate) →
  distributed-locked Deezer ingest → cache. Deezer is touched only on miss/stale.
- **Writes**: atomic plpgsql RPCs (`catalog_upsert_{artist,album,track}_graph`,
  service-role only) upsert the whole entity graph in one transaction, preserving
  existing `youtube_*` IDs + cached artwork, pruning junctions only on a
  `complete` payload, and never downgrading `full`→`partial`.
- **Search**: DB-first (`pg_trgm` via `catalog_search`) + Deezer discovery merge.
- **Home**: one bounded chart refresh + circuit-breaker (serve stale on 403/429).
- **YouTube**: persistent matcher writes `tracks.youtube_*` with an audio-first
  preferred id (see ADR-004; the IFrame engine is unchanged).
- **Artwork**: backgrounded download→WebP→Supabase Storage.
- **API**: normalized `/v2/*` added additively; legacy endpoints untouched until
  Phase 3 migrates Flutter.

#### Rejected alternatives
- PostgREST-only writes (no multi-table transactions) → chose plpgsql RPCs.
- Direct `asyncpg` pool → chose `supabase-py` + RPCs for one client + RLS/Storage.
- Overwriting `/v2/search` & `/v2/chart` → would break the live app; normalized
  discovery/home added at `/v2/find` & `/v2/home`.

#### Consequences
- **Positive**: durable catalog, sub-ms cache hits, no eager per-request matching,
  correct multi-artist credits, backend-only writes.
- **Negative**: in-process background jobs don't survive restarts (durable queue
  is future work); dual endpoint surface until Phase 3.

#### Related
Extends ADR-009 · preserves ADR-001/ADR-004. Full reference:
[backend/phase2-catalog.md](backend/phase2-catalog.md).

---

### ADR-011 — Offline-first cloud library sync (Hive cache + Supabase authority)

**Date**: 2026-07-17 · **Status**: ACCEPTED (Phase 3.2A) · **Author**: AI agent (directed by uzielcezate) · **Deciders**: maintainer

#### Context
Phase 3.1 landed real Supabase Auth, but the music **library** (liked tracks, saved albums, followed artists, hidden tracks) still lived only in on-device Hive — no cross-device durability, and the ADR-009 Phase-3 goal of cloud-backed library remained open. Local entities are keyed by YouTube `videoId` / Deezer ids, while the Supabase catalog is keyed by internal UUIDs, so a durable sync needs an id-resolution strategy that never blocks the UI or resurrects deleted rows. paax-api is **not** involved (unchanged this phase); the client talks to Supabase directly under RLS.

#### Decision
Adopt an **offline-first** model: **Hive is the fast local cache; Supabase is the durable cross-device authority.**

- **Resolve by `deezer_id`** — `CatalogResolver` maps local Deezer ids → catalog UUIDs via the publicly-readable `artists/albums/tracks.deezer_id` columns (cached in memory + `SharedPreferences`). `Track` gained an additive nullable `deezerTrackId` (HiveField 11) so tracks resolve to `tracks.id`.
- **Optimistic local write, best-effort cloud push** — every toggle writes Hive first, then `LibraryController` fires a best-effort `pushX` (cloud side only) with the post-toggle state. `LibraryRemoteDataSource` does RLS-safe, `auth.uid()`-scoped CRUD (idempotent inserts ignoring `23505`) and **never** writes trigger-maintained counters.
- **Pending-ops journal, last-write-wins** — on an unresolved id or network failure the op is journaled in `LibrarySyncState` (deduped by `kind + deezerId`); `flushPending` replays it.
- **`hydrateFromCloud` is add-only** and **skips any cloud item with a pending `remove` op** — an unlike/unfollow is never resurrected.
- **`migrateLocalToCloud` runs once per user** (guarded); unresolvable legacy items stay local-only.
- **Clear-on-account-switch** — `onUserSession(uid)` clears the local library boxes + pending journal when the recorded `lastUserId` differs from the new uid (playlists/profile preserved).
- **Unowned local not uploaded** — a pre-existing local library with no recorded owner (`lastUserId == null`, the pre-3.2A upgrade path) is kept local-only, never bulk-uploaded, preventing a cross-account cloud write.
- **Hidden tracks** — new `user_hidden_tracks` table (own-row RLS); hidden = excluded from automatic playback + future recommendation inputs, catalog track not deleted.

Artist onboarding is completed by the companion **`complete_artist_onboarding(p_artist_ids uuid[])` SECURITY DEFINER RPC** (`search_path=''`, authenticated-only, ≥5 unique existing artists, idempotent follows, atomically flips `profiles.onboarding_completed`) — the only path allowed to set that flag (see [features/onboarding.md](features/onboarding.md)).

#### Rejected alternatives
- **Realtime subscriptions / full two-way merge** — overkill for a per-user library; a best-effort push + add-only hydrate with a small journal is simpler and sufficient.
- **Resolve by videoId** — the catalog is keyed on Deezer ids; videoId has no stable catalog mapping.
- **Block the UI on cloud writes** — rejected; sync must never degrade the offline-first feel.
- **Bulk-upload any pre-existing local library on first login** — rejected; it would leak a prior/unowned device's library into a new account's cloud rows.

#### Consequences
- **Positive**: durable, cross-device library; offline-first UX preserved; multi-account safe; counters stay trigger-only.
- **Negative**: hydrated liked/album/artist entities are **sparse** until re-fetched by browsing; hidden/liked tracks only resolve to cloud when a Deezer track id is known (new likes carry it; some pre-3.2A likes may not); "Clear Data" wipes Hive but not the cloud/sync bookkeeping, so the same user re-hydrates on next login. See [KNOWN_ISSUES.md](KNOWN_ISSUES.md), [TECH_DEBT.md](TECH_DEBT.md).

#### Related
Executes part of ADR-009 Phase 3 · preserves ADR-001/ADR-004 (playback unchanged; paax-api not modified). Full reference: [features/library.md](features/library.md), [features/onboarding.md](features/onboarding.md).

---

*Last updated: 2026-07-17*
