# Backlog

> **Purpose**: Tracks all planned but not yet started tasks, features, bugs, and improvements. This is the team's "to-do" list for future work.
> **Update when**: A new task is identified, a task is moved to `in-progress.md`, or a task is cancelled.

---

## Reading Note

This backlog is derived honestly from the current state of the codebase: stubs that are wired for a feature that does not exist yet, subsystems that are deployed but dead, and the security/quality debt cataloged in [`../TECH_DEBT.md`](../TECH_DEBT.md). Priorities reflect a single-maintainer reality — "High" means it blocks a credible public release or is an active risk, not that a sprint is committed. See [`completed.md`](completed.md) for what is done, [`in-progress.md`](in-progress.md) for active threads, and [`../roadmap.md`](../roadmap.md) for sequencing.

---

## How to Add a Task

Copy the template below, assign the next sequential ID, and place it in the appropriate priority section.

---

## Task Template

```markdown
### TASK-XXX — <Title>

**Type**: Feature / Bug / Chore / Refactor / Docs
**Priority**: Critical / High / Medium / Low
**Estimate**: XS (< 2h) / S (< 1d) / M (< 3d) / L (< 1w) / XL (> 1w)
**Labels**: frontend, backend, database, auth, ...
**Reporter**: Name or Agent
**Created**: YYYY-MM-DD

**Description**:
<!-- What needs to be done and why. -->

**Acceptance Criteria**:
- [ ] Criterion 1
- [ ] Criterion 2

**Notes**:
<!-- Additional context, links, or constraints. -->
```

---

## 🔴 Critical Priority

*(No critical items — the app is functional end-to-end today. The items that gate a public release are grouped under High.)*

---

## 🟠 High Priority

### TASK-B01 — Real per-user authentication + cloud sync (replace demo auth)

**Type**: Feature
**Priority**: High
**Estimate**: XL (> 1w)
**Labels**: auth, backend, frontend, data
**Reporter**: Solo maintainer (uzielcezate)
**Created**: 2026-07-16

**Description**:
Authentication is currently a **local demo stub**: `AuthController.login` hardcodes `user@gmail.com`/`12345`, `signup` always succeeds, and the profile is stored only in Hive. There is no server-side identity and no cross-device sync — all library state (liked, playlists, followed, recently played) lives client-side in Hive and is lost on uninstall or device change. Introduce real accounts and sync the Hive-backed library to a server. Note the templates/rules assume Supabase/Postgres, but **none is wired today** (see [`../TECH_DEBT.md`](../TECH_DEBT.md)); adopting Supabase Auth + Postgres, or an equivalent, is itself part of this task's design decision.

**Acceptance Criteria**:
- [ ] Users can register and log in with real credentials (no hardcoded creds)
- [ ] Access tokens are short-lived with refresh rotation; logout invalidates refresh tokens
- [ ] Library state syncs across devices (server is source of truth or CRDT-merged with Hive)
- [ ] Existing local-only libraries migrate into the account on first login
- [ ] Server write endpoints authorize by the authenticated user's id, not client-supplied ids

**Notes**:
Blocks any multi-device story and any monetization. Also see TASK-B12 (server auth on write endpoints) — the current `/rate`/`/playlists*` endpoints mutate a single shared YTMusic OAuth account, which is unacceptable for multi-user.
**Update 2026-07-16**: the design decision is settled — **ADR-009** adopted Supabase, and the **Phase-1 foundation is deployed** (34 RLS tables, storage, billing readiness; see [`../backend/database-schema.md`](../backend/database-schema.md)). Nothing consumes it yet: remaining work is Phase 2 (TASK-B14/B15/B16/B17/B18/B19) and Phase 3 (TASK-B20/B21).

---

### TASK-B02 — Functional downloads + offline playback

**Type**: Feature
**Priority**: High
**Estimate**: XL (> 1w)
**Labels**: frontend, playback, offline
**Reporter**: Solo maintainer (uzielcezate)
**Created**: 2026-07-16

**Description**:
There is no offline/download capability. This is complicated by the streaming architecture: the live path plays through the YouTube IFrame with no accessible audio bytes, so real downloads require committing to a byte-yielding resolver (Cloudflare Worker or paax-stream IPv6 proxy) first. Depends on TASK-B07 (streaming consolidation).

**Acceptance Criteria**:
- [ ] User can download a track/album/playlist for offline listening
- [ ] Downloaded content plays with no network and survives app restart
- [ ] Storage is manageable (view usage, delete downloads) with a confirm on "remove all downloads" per UX rules
- [ ] Offline indicator shown where applicable (per UI rules' required states)

**Notes**:
Hard-blocked by the streaming decision — you cannot cache bytes you never touch. Sequence after [`in-progress.md`](in-progress.md) TASK-IP03.

---

### TASK-B03 — Working Settings screen

**Type**: Feature
**Priority**: High
**Estimate**: M (< 3d)
**Labels**: frontend, ux
**Reporter**: Solo maintainer (uzielcezate)
**Created**: 2026-07-16

**Description**:
There is no real Settings surface. The `settings` Hive box holds only `onboarding_completed`, `hidden_track_ids`, and `pinned_playlist_map`; there is no user-facing screen to manage playback quality, data usage, cache/storage, account, or about/version info. Profile only offers clear-data/logout.

**Acceptance Criteria**:
- [ ] A Settings screen reachable from Profile
- [ ] Manage cache/storage (clear image + playlist caches)
- [ ] Playback preferences (once quality is controllable — see TASK-B07)
- [ ] About/version, licenses, and a data-deletion entry point (privacy)

**Notes**:
Several backlog features (downloads, notifications, account) need a settings home. Cheap to scaffold now, fill in as features land.

---

### TASK-B04 — Release signing config (stop signing release with debug keys)

**Type**: Chore (release blocker)
**Priority**: High
**Estimate**: S (< 1d)
**Labels**: android, release, security
**Reporter**: Solo maintainer (uzielcezate)
**Created**: 2026-07-16

**Description**:
`frontend/android/app/build.gradle` currently **signs release builds with debug keys** (carries the default Flutter TODO). This must be replaced with a real keystore and signing config before any Play Store or production TWA distribution, because the signing key permanently binds app identity and update continuity.

**Acceptance Criteria**:
- [ ] Release builds use a dedicated, securely stored release keystore
- [ ] Keystore credentials come from environment/secure storage, never committed
- [ ] `assetlinks.json` fingerprint matches the release key (TWA continuity)

**Notes**:
Sequence together with the `applicationId` rename ([`in-progress.md`](in-progress.md) TASK-IP01) — both are one-shot identity changes that should land in the same release cut.

---

### TASK-B05 — Disable `verify=False` on the Deezer HTTP client

**Type**: Bug / Security
**Priority**: High
**Estimate**: XS (< 2h)
**Labels**: backend, security, paax-api
**Reporter**: Solo maintainer (uzielcezate)
**Created**: 2026-07-16

**Description**:
`paax-api`'s Deezer `httpx` client uses `verify=False`, disabling TLS certificate validation and exposing the metadata fetch to MITM tampering. This violates the "HTTPS everywhere" non-negotiable in `.claude/rules/security.md`. Restore verification; if a specific cert-chain issue motivated the flag, fix it properly (CA bundle / pinning) instead of disabling validation.

**Acceptance Criteria**:
- [ ] Deezer client validates TLS (`verify=True` or a proper CA bundle)
- [ ] Deezer requests still succeed against `api.deezer.com`
- [ ] No other client in the service disables verification

**Notes**:
Small change, real risk. Tracked in [`../TECH_DEBT.md`](../TECH_DEBT.md).

---

### TASK-B06 — Rate limiting + input validation on paax-api

**Type**: Chore / Security
**Priority**: High
**Estimate**: M (< 3d)
**Labels**: backend, security, api, paax-api
**Reporter**: Solo maintainer (uzielcezate)
**Created**: 2026-07-16

**Description**:
`paax-api` has no rate limiting and no schema-validation library on its own endpoints, and it surfaces raw `str(e)` error strings to clients (leaking internals). CORS also always permits localhost/`10.0.2.2`/LAN via regex with `allow_credentials=True`. Per `.claude/rules/api.md` and `.claude/rules/security.md`: add rate limiting with the standard headers, validate/normalize query inputs, and return the standard error envelope instead of raw exceptions.

**Acceptance Criteria**:
- [ ] Public endpoints are rate limited with `X-RateLimit-*` + `Retry-After` on 429
- [ ] Query params validated at the boundary (types, bounds, enum for `type`)
- [ ] Errors return the standard `{error:{code,message,details}}` shape; no `str(e)` leakage
- [ ] CORS regex reviewed so the permissive LAN allowance is dev-only

**Notes**:
The eager YouTube-match pipeline (yt-dlp per track) makes uncontrolled request volume expensive — rate limiting is also a cost control, not just security.

---

### TASK-B07 — Wire a stream resolver into playback, or remove the dead stream code

**Type**: Refactor / Decision
**Priority**: High
**Estimate**: L (< 1w)
**Labels**: playback, backend, refactor
**Reporter**: Solo maintainer (uzielcezate)
**Created**: 2026-07-16

**Description**:
Three streaming generations coexist and the live app uses none of the server resolvers (IFrame-direct only). `ApiConfig.streamBaseUrl` and `MusicRepository.getStreamUrl` are defined but unused. Decide the path of record, then either wire the chosen resolver in or delete the unused plumbing. Also remove clearly dead code: the entire `paax-stream/resolve/` provider pipeline (not mounted, imports missing modules, `yt_dlp` absent from requirements) and the broken legacy `backend/` resolver (`_FORMAT_FALLBACKS` NameError). This is the active decision in [`in-progress.md`](in-progress.md) TASK-IP03 — this backlog entry captures the follow-through code work.

**Acceptance Criteria**:
- [ ] A single streaming strategy is documented as the path of record
- [ ] Either `getStreamUrl`/`streamBaseUrl` are wired into playback, or removed
- [ ] `paax-stream/resolve/` orphaned pipeline deleted (or revived with real deps if kept)
- [ ] Legacy `backend/` resolver removed or fixed

**Notes**:
Highest-leverage cleanup: unblocks downloads (TASK-B02) and quality control, and shrinks confusing surface area. Cross-ref [`../TECH_DEBT.md`](../TECH_DEBT.md).

---

### TASK-B14 — Deezer ingestion service writing to the Supabase catalog (Phase 2)

**Type**: Feature
**Priority**: High
**Estimate**: XL (> 1w)
**Labels**: backend, database, supabase, catalog
**Reporter**: AI agent (ADR-009)
**Created**: 2026-07-16

**Description**:
The Supabase Phase-1 catalog tables (genres/artists/albums/tracks + junctions) are deployed but empty — the app still proxies Deezer live per request through paax-api. Build the backend ingestion service that fetches Deezer metadata and upserts it into the Supabase catalog (service-role writes), reconciling relations (album/track artists, genres) and maintaining `metadata_source/status/updated_at` per the freshness TTLs in [`../backend/database-schema.md`](../backend/database-schema.md).

**Acceptance Criteria**:
- [ ] Deezer entities upsert idempotently into `genres/artists/albums/tracks` + junction tables
- [ ] Relation reconciliation (artist roles/positions, genre relevance) matches the schema's constraints
- [ ] `metadata_status`/`metadata_updated_at` maintained; stale entities re-fetched per TTL policy
- [ ] Catalog writes are service-role only (never from clients)

**Notes**:
Foundation deployed (2026-07-16); this is the first Phase-2 integration step per ADR-009. Nothing in the app reads the Supabase catalog until this lands.

---

### TASK-B15 — YouTube matcher job populating `tracks.youtube_*` (Phase 2)

**Type**: Feature
**Priority**: High
**Estimate**: L (< 1w)
**Labels**: backend, supabase, playback-metadata
**Reporter**: AI agent (ADR-009)
**Created**: 2026-07-16

**Description**:
The `tracks` table carries a deployed-but-unpopulated YouTube mapping block (`youtube_audio_video_id`, `preferred_youtube_video_id`, `youtube_match_status/confidence/reason`, verification/failure fields) with the `idx_tracks_youtube_pending` partial index as the work queue. Build the matcher job that consumes that queue and writes durable matches, replacing the current 7-day Redis-only match cache. IFrame playback itself is unchanged (ADR-004).

**Acceptance Criteria**:
- [ ] Job drains `youtube_match_status = 'pending'` (and stale/failed per policy) via the partial index
- [ ] Writes video ids + confidence/reason/status; never audio URLs or bytes
- [ ] Re-verification honors the 30-day / playback-failure staleness rules

**Notes**:
Depends on TASK-B14 (tracks must exist in the catalog first). Reuses the existing scoring logic from paax-api's `/v2/match` path.

---

### TASK-B19 — Verify Auth password policy in the Supabase Dashboard (manual step)

**Type**: Chore / Security
**Priority**: High
**Estimate**: XS (< 2h)
**Labels**: auth, supabase, security
**Reporter**: AI agent (ADR-009)
**Created**: 2026-07-16

**Description**:
ADR-009 requires Auth password complexity (min 8, upper + lower + digit + special; app-side regex `^(?=.*[a-z])(?=.*[A-Z])(?=.*\d)(?=.*[^A-Za-z0-9]).{8,}$`) to be enforced **in the Supabase Dashboard** — this setting is not MCP/migration-configurable, so it is a manual step that must be verified before any real signup flow ships (Phase 3).

**Acceptance Criteria**:
- [ ] Dashboard password policy set to ≥8 chars with lower + upper + digit + symbol
- [ ] Confirmed by attempting a weak-password signup against the project (rejected)

**Notes**:
Pairs with the client-side validation in TASK-B20's auth forms. See [`../features/authentication.md`](../features/authentication.md).

---

### TASK-B20 — Flutter Supabase Auth integration (Phase 3)

**Type**: Feature
**Priority**: High
**Estimate**: L (< 1w)
**Labels**: frontend, auth, supabase
**Reporter**: AI agent (ADR-009)
**Created**: 2026-07-16

**Description**:
Replace the demo auth stub (`AuthController` hardcoded creds — see [`../features/authentication.md`](../features/authentication.md)) with real Supabase Auth sign-up/sign-in in the Flutter app. The server side is ready: profiles are auto-created on signup with safe username derivation, and privileged columns (role/tier) are trigger-guarded. Client uses the `anon` key only; enforce the password regex in the forms (see TASK-B19 for the Dashboard side).

**Acceptance Criteria**:
- [ ] Sign-up/sign-in/sign-out via Supabase Auth (no hardcoded credentials)
- [ ] Password forms validate with `^(?=.*[a-z])(?=.*[A-Z])(?=.*\d)(?=.*[^A-Za-z0-9]).{8,}$`
- [ ] Session persistence + refresh handled by the Supabase client; logout no longer wipes the local library indiscriminately
- [ ] `service_role` key never present in the Flutter app

**Notes**:
Phase 3 of ADR-009; the concrete first slice of TASK-B01. Sequence after Phase-2 ingestion so a signed-in app has a catalog to read.

---

### TASK-B21 — Hive → Supabase user-data migration (Phase 3)

**Type**: Feature / Refactor
**Priority**: High
**Estimate**: XL (> 1w)
**Labels**: frontend, data, supabase, migration
**Reporter**: AI agent (ADR-009)
**Created**: 2026-07-16

**Description**:
Migrate the on-device Hive library (liked tracks, playlists, saved albums, followed artists, recently played) into the deployed Supabase user-data tables (`user_liked_tracks`, `playlists`/`playlist_tracks`, `user_saved_albums`, `user_followed_artists`, `user_listening_history`) on first login, then make the cloud the source of truth with Hive as an offline cache. Hive remains the live store until this lands (ADR-002 → ADR-009 transition).

**Acceptance Criteria**:
- [ ] Existing local library imports into the account on first login (idempotent, resumable)
- [ ] Local tracks map onto Supabase catalog rows (depends on TASK-B14 ingestion)
- [ ] Post-migration reads/writes go through Supabase with own-row RLS; Hive demoted to cache
- [ ] No data loss on interrupted migration

**Notes**:
Depends on TASK-B14/B15 (catalog + matches) and TASK-B20 (auth). Completes the TASK-B01 story.

---

## 🟡 Medium Priority

### TASK-B08 — Automated test suite (bootstrap coverage)

**Type**: Chore / Test
**Priority**: Medium
**Estimate**: L (< 1w)
**Labels**: frontend, backend, test
**Reporter**: Solo maintainer (uzielcezate)
**Created**: 2026-07-16

**Description**:
There are **no automated tests**. The Flutter app has no `test/` directory (only `flutter_lints`); the backends have only gitignored manual `test_*/verify_*/debug_*` probe scripts. `.claude/rules/testing.md` prescribes a test pyramid with coverage minimums — none of which are met. Bootstrap real coverage starting with the highest-value/lowest-flakiness units.

**Acceptance Criteria**:
- [ ] Unit tests for the v2 mappers (`deezer_mapper`, repository `Track.id = playback.videoId` mapping)
- [ ] Unit tests for the YouTube match scorer (duration/title/artist/trust scoring)
- [ ] Widget tests for at least the player and library screens
- [ ] Tests run in CI and block regressions

**Notes**:
Given the UI-polish churn ([`in-progress.md`](in-progress.md) TASK-IP02) touches many widgets at once with only manual verification, even a thin widget-test net would catch regressions early.

---

### TASK-B09 — Push notifications (FCM)

**Type**: Feature
**Priority**: Medium
**Estimate**: L (< 1w)
**Labels**: frontend, android, backend
**Reporter**: Solo maintainer (uzielcezate)
**Created**: 2026-07-16

**Description**:
No push notification support today. Add FCM for new-release / recommendation / re-engagement notifications. Per `.claude/rules/ux.md`, defer the notification permission prompt until after the user has experienced value (not at first launch).

**Acceptance Criteria**:
- [ ] FCM integrated on Android; permission requested contextually, not on launch
- [ ] Server can send targeted notifications (needs real accounts — depends on TASK-B01)
- [ ] User can manage notification preferences in Settings (TASK-B03)

**Notes**:
Practically gated by real auth (who to notify) and a settings home. Medium until those land.
**Update 2026-07-16**: the server *foundation* now exists — `user_devices` (protected push tokens) and `notifications` (backend-created inbox) tables are deployed (ADR-009) — but there is still no delivery pipeline (FCM) and no client integration.

---

### TASK-B10 — Adopt a design-token + spacing scale

**Type**: Refactor
**Priority**: Medium
**Estimate**: M (< 3d)
**Labels**: frontend, ui, design-system
**Reporter**: Solo maintainer (uzielcezate)
**Created**: 2026-07-16

**Description**:
Spacing is ad-hoc numeric literals throughout; there is no central spacing scale and no design-token file beyond `AppColors` + `BeatyGlassTokens`. `.claude/rules/ui.md` requires a consistent spacing scale and theme-token usage. Introduce spacing/typography tokens and migrate high-traffic widgets to them.

**Acceptance Criteria**:
- [ ] A spacing scale constant file (4px base: 4/8/12/16/24/32/48/64)
- [ ] Player, library, and card widgets use tokens instead of literals
- [ ] No new hardcoded spacing literals in migrated files

**Notes**:
Directly reduces the "stale fade / shadow artifact" churn in the ongoing liquid-glass polish. Reasonable to do incrementally alongside TASK-IP02.

---

### TASK-B11 — Personalized recommendations

**Type**: Feature
**Priority**: Medium
**Estimate**: L (< 1w)
**Labels**: frontend, backend, discovery
**Reporter**: Solo maintainer (uzielcezate)
**Created**: 2026-07-16

**Description**:
"For You" is currently derived only from recent searches; there is no real personalization. Build recommendations from listening history (recently played / liked / followed artists). Meaningfully personalized (vs. per-device heuristic) recommendations need server-side history, so this depends on TASK-B01.

**Acceptance Criteria**:
- [ ] Recommendations reflect actual listening behavior, not just recent search strings
- [ ] Home surfaces personalized rows with sensible cold-start fallback (charts/genres)

**Notes**:
Deezer + YouTube-match pipeline gives clean seed metadata; the missing piece is durable per-user history (TASK-B01).

---

### TASK-B16 — Artwork caching into the `music-images` Storage bucket (Phase 2)

**Type**: Feature
**Priority**: Medium
**Estimate**: M (< 3d)
**Labels**: backend, supabase, storage, images
**Reporter**: AI agent (ADR-009)
**Created**: 2026-07-16

**Description**:
The `music-images` bucket (public read via URL, no listing, service-role writes) is deployed but empty. As part of ingestion (TASK-B14), cache Deezer/Google artwork into the bucket and store the cached URLs on the catalog rows (the artwork cache fields already exist), so the client can eventually stop hammering `dzcdn.net`/`lh3-lh6` hosts — the root cause of the 429 pipeline (TASK-C08).

**Acceptance Criteria**:
- [ ] Ingestion writes artwork objects to `music-images` (service-role) and records cached URLs on catalog rows
- [ ] Idempotent re-caching keyed by source URL/entity; no duplicate objects
- [ ] No client writes to the bucket

**Notes**:
Depends on TASK-B14. Long-term this can retire much of the client 429-throttling complexity (ISSUE-008 / DEBT-010).

---

### TASK-B17 — Scheduled stories cleanup job (Phase 2)

**Type**: Chore
**Priority**: Medium
**Estimate**: S (< 1d)
**Labels**: backend, supabase, database
**Reporter**: AI agent (ADR-009)
**Created**: 2026-07-16

**Description**:
Expired stories are currently only *hidden* (visibility functions + `active_stories` view filter them out) — nothing hard-deletes them or their media. Implement the documented cleanup: a scheduled job (pg_cron or a backend cron) that purges stories N days after expiry and deletes the corresponding `story-media` Storage objects.

**Acceptance Criteria**:
- [ ] Scheduled purge of stories past expiry + retention window (soft-deleted included)
- [ ] Orphaned `story-media` objects deleted alongside their story rows
- [ ] Job is idempotent and logged

**Notes**:
See the Stories section of [`../backend/database-schema.md`](../backend/database-schema.md). No urgency until stories have users (Phase 4 UI), but cheap to land with Phase-2 backend work.

---

### TASK-B18 — Redis job-dedup / rate-limit layer for ingestion (Phase 2)

**Type**: Chore / Infrastructure
**Priority**: Medium
**Estimate**: M (< 3d)
**Labels**: backend, redis, supabase
**Reporter**: AI agent (ADR-009)
**Created**: 2026-07-16

**Description**:
Per ADR-009, Redis stays the transient layer (never source of truth): dedup concurrent metadata-refresh jobs, rate-limit outbound Deezer/YouTube calls, and hold short-lived query caches, while Supabase holds the durable results. Build this layer alongside TASK-B14/B15 so stale-entity refreshes don't stampede.

**Acceptance Criteria**:
- [ ] Refresh jobs deduped (same entity scheduled once) with locks/TTLs in Redis
- [ ] Outbound provider calls rate-limited; limits configurable via env
- [ ] Redis outage degrades gracefully (jobs still run, just without dedup)

**Notes**:
Extends the existing paax-api Redis usage (TASK-C09) rather than introducing new infra.

---

## 🟢 Low Priority

### TASK-B12 — Scope server write endpoints to the authenticated user

**Type**: Bug / Security
**Priority**: Low (blocked-by, not urgent while single-user)
**Estimate**: M (< 3d)
**Labels**: backend, security, auth, paax-api
**Reporter**: Solo maintainer (uzielcezate)
**Created**: 2026-07-16

**Description**:
The v1 write endpoints (`POST /rate`, `POST/DELETE /playlists*`) have no per-user auth — they mutate the server's single shared YTMusic OAuth account. This is fine only because the app never calls them for real user data today (library lives in Hive). If/when server accounts arrive (TASK-B01), these must authorize by the authenticated user or be removed.

**Acceptance Criteria**:
- [ ] Write endpoints require an authenticated user and act on that user's data
- [ ] Or: endpoints removed if superseded by the account-sync design

**Notes**:
Low now because unreachable with user data; escalates to High the moment real accounts land. Tightly coupled to TASK-B01.

---

### TASK-B13 — iOS build

**Type**: Feature (platform)
**Priority**: Low
**Estimate**: XL (> 1w)
**Labels**: ios, platform, playback
**Reporter**: Solo maintainer (uzielcezate)
**Created**: 2026-07-16

**Description**:
No iOS build today (Android + Web/PWA/TWA only). Bringing up iOS requires validating the WebView-based playback + background-audio strategy on iOS (`flutter_inappwebview` background-audio behavior differs from Android's Foreground Service model) and setting up the Apple distribution pipeline.

**Acceptance Criteria**:
- [ ] App builds and runs on iOS
- [ ] Background audio works within iOS constraints (likely needs a different keep-alive than the Android Foreground Service)
- [ ] Media controls integrate with the iOS Now Playing / control center

**Notes**:
High effort, low current priority given the Android + web focus. The playback keep-alive tricks are the main technical risk, not the UI.

---

## ❌ Cancelled / Descoped

> Items descoped rather than backlogged. The multi-provider stream pipeline is not listed as "cancelled" because a cleanup decision (keep vs. delete) is still pending under TASK-B07 / [`in-progress.md`](in-progress.md) TASK-IP03.

| Task ID | Title | Reason | Date |
|---------|-------|--------|------|
| — | Supabase/Postgres server database | Descoped in Phase 3 in favor of client-side Hive + stateless backends. **Reversed by ADR-009 (2026-07-16)** — the Supabase Phase-1 foundation is now deployed (see TASK-B14…B21), though the app does not consume it yet | Phase 3 → reversed 2026-07-16 |
| — | `deezer_api_client.dart` (direct client-side Deezer calls) | Superseded by server-side Deezer fetch in paax-api; file left fully commented out (dead) | Phase 6 |

---

## Phase 2.6 residual (low priority)

- Invalidate the Daft Punk `catalog:artist:deezer:27` response-cache key (holds a
  pre-cleanup empty-discography response; self-heals on ≤24h TTL). Blocked only by
  Redis MCP availability — a one-line `redis-cli DEL` clears it immediately.
- Apply the "no persistent placeholder" rule to `build_track_artists` for
  consistency (see [TECH_DEBT.md](../TECH_DEBT.md)).

---

*Last updated: 2026-07-17*
