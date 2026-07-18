# Technical Debt

> **Purpose**: A transparent register of known technical debt — shortcuts, suboptimal implementations, deferred work, and areas of the codebase that need improvement. AI agents must consult this before refactoring or working in a debt-heavy area.
> **Update when**: New debt is incurred (with justification), debt is paid off, or the impact/priority of a debt item changes.

---

## What Is Technical Debt?

Technical debt is any code or design decision that works today but creates future friction — slower development, harder maintenance, higher bug risk, or worse performance. All debt must be documented here with a justification for why it was incurred.

---

## Debt Severity Levels

| Level | Meaning |
|-------|---------|
| 🔴 Critical | Actively causing problems or blocking progress. Fix immediately. |
| 🟠 High | Will slow down future development significantly. Fix in next sprint. |
| 🟡 Medium | Creates friction but manageable. Schedule within the quarter. |
| 🟢 Low | Minor annoyance. Fix when touching the area anyway. |

---

## Debt Register (Impact / Effort)

| ID | Title | Severity | Area | Effort | Status |
|----|-------|----------|------|--------|--------|
| DEBT-001 | No automated tests, no CI | 🟠 High | Quality / DevEx | L | 🔴 Open |
| DEBT-002 | Release signed with debug keys | 🟠 High | Android / Release | S | 🔴 Open |
| DEBT-003 | `applicationId` still `com.beaty.music.beaty` | 🟠 High | Android / Branding | S | 🔴 Open |
| DEBT-004 | Deezer client `verify=False` (TLS off) | 🟠 High | Security / API | XS | 🔴 Open |
| DEBT-005 | `str(e)` error leakage + no schema validation | 🟠 High | Security / API | M | 🔴 Open |
| DEBT-006 | No rate limiting on paax-api | 🟠 High | Security / API | M | 🔴 Open |
| DEBT-007 | Orphaned paax-stream `resolve/` pipeline | 🟡 Medium | Streaming | M | 🔴 Open |
| DEBT-008 | Legacy `backend/` monolith superseded (broken `/stream`) | 🟡 Medium | Backend | M | 🔴 Open |
| DEBT-009 | Dead client code + dual config | 🟡 Medium | Frontend | S | 🔴 Open |
| DEBT-010 | Two overlapping image-cache generations | 🟡 Medium | Frontend / Perf | M | 🔴 Open |
| DEBT-011 | Branding inconsistency Beaty/Paax | 🟡 Medium | Branding | L | 🔴 Open |
| DEBT-012 | Ad-hoc spacing, no design tokens | 🟢 Low | Frontend / UI | M | 🔴 Open |
| DEBT-013 | `DynamicBackground` dormant (unmounted) | 🟢 Low | Frontend / Theming | S | 🔴 Open |
| DEBT-014 | `yt-dlp` unpinned lower bound (paax-api) | 🟡 Medium | Backend | XS | 🔴 Open |
| DEBT-015 | Dual-store period: Hive live + Supabase deployed-but-unconsumed | 🟡 Medium | Data / Architecture | L | 🔴 Open (deliberate) |
| DEBT-016 | Demo auth stub still live despite real Supabase Auth existing | 🟡 Medium | Auth | M | 🔴 Open |
| DEBT-017 | Stories cleanup job not scheduled (expired stories accumulate) | 🟢 Low | Supabase / Jobs | S | 🔴 Open |
| DEBT-018 | Cloud-hydrated library entities are sparse | 🟢 Low | Library / Sync | M | 🔴 Open |
| DEBT-019 | Track cloud resolution depends on a known Deezer track id | 🟡 Medium | Library / Sync | M | 🔴 Open |
| DEBT-020 | Onboarding search UUID coverage (null-id discoveries) | 🟢 Low | Onboarding | S | 🔴 Open |
| DEBT-021 | "Clear Data" doesn't reset cloud/sync bookkeeping | 🟢 Low | Library / Sync | S | 🔴 Open (deliberate) |

---

## Debt Template

```markdown
### DEBT-XXX — <Title>
**Status**: 🔴 Open | 🔄 In Progress | ✅ Paid Off
**Severity**: Critical | High | Medium | Low
**Area**:
**Incurred on**: YYYY-MM-DD
**Estimated effort to fix**: XS / S / M / L / XL
**Description**:
**Why it was incurred**:
**Impact if unaddressed**:
**Fix Plan**:
```

---

## 🔴 Critical Debt

*(None currently rated Critical. The broken legacy `/stream` — DEBT-008 — would be critical if the live app used it, but it does not.)*

---

## 🟠 High Priority Debt

### DEBT-001 — No automated tests, no CI

**Status**: 🔴 Open
**Severity**: High
**Area**: Quality / DevEx
**Incurred on**: (project inception)
**Estimated effort**: L

**Description**: The Flutter app has **no** `test/` directory; only `flutter_lints`. Backends have only gitignored `test_*/verify_*/debug_*` probe scripts, not a suite. There is no GitHub Actions / CI pipeline. The only gates are `flutter analyze` + `dart format`.

**Why it was incurred**: Speed of iteration on a solo/small project chasing UX polish.

**Impact if unaddressed**: Every change is a regression risk; refactors (e.g. streaming unification, branding rename) are dangerous; no merge safety net. Contradicts [`.claude/rules/testing.md`](../.claude/rules/testing.md).

**Fix Plan**: Add unit tests for pure logic first (`deezer_mapper`, match scorer, Hive migrations, v2 mappers), then a few widget tests; wire `flutter analyze`/`flutter test`/`pytest` into CI. See [testing](testing.md), [ideas](IDEAS.md) IDEA-005.

---

### DEBT-002 — Release build signed with debug keys

**Status**: 🔴 Open · **Severity**: High · **Area**: Android / Release · **Effort**: S

**Description**: `frontend/android/app/build.gradle` signs the release build type with the debug config (default Flutter TODO).
**Why**: Never set up a production keystore.
**Impact**: Cannot safely ship to Play Store; not upgrade-compatible with a properly signed build. See [known issues](KNOWN_ISSUES.md) ISSUE-006, [deployment](deployment.md).
**Fix Plan**: Create keystore, add `signingConfigs.release`, keep credentials out of VCS.

---

### DEBT-003 — `applicationId` still `com.beaty.music.beaty`

**Status**: 🔴 Open · **Severity**: High · **Area**: Android / Branding · **Effort**: S

**Description**: Android id/label predates the Paax rebrand.
**Why**: Rebrand focused on UI/UX, not build identifiers.
**Impact**: Blocks a clean Paax store listing; changing `applicationId` after publish is effectively a new app, so it must be settled first. Coupled with TWA `assetlinks.json` fingerprints. See [known issues](KNOWN_ISSUES.md) ISSUE-007/010.
**Fix Plan**: Choose final id; update `build.gradle` + manifest label + `assetlinks.json` atomically.

---

### DEBT-004 — Deezer HTTP client disables TLS verification (`verify=False`)

**Status**: 🔴 Open · **Severity**: High · **Area**: Security / API · **Effort**: XS

**Description**: paax-api's Deezer `httpx` client sets `verify=False`.
**Why**: Likely a local cert-hiccup workaround left in.
**Impact**: MITM exposure on the metadata path; violates [`.claude/rules/security.md`](../.claude/rules/security.md). See [known issues](KNOWN_ISSUES.md) ISSUE-002, [security](security.md).
**Fix Plan**: Remove the flag; configure a proper trust store if a specific CA is needed.

---

### DEBT-005 — `str(e)` error leakage + no request schema validation

**Status**: 🔴 Open · **Severity**: High · **Area**: Security / API · **Effort**: M

**Description**: paax-api surfaces `str(e)` to clients and uses no schema-validation library on its own endpoints (relies on FastAPI path/query typing only).
**Why**: Fast prototyping; error handling never centralized.
**Impact**: Leaks internals ([known issues](KNOWN_ISSUES.md) ISSUE-005), inconsistent error contract (see [error codes](ERROR_CODES.md)), weak input validation.
**Fix Plan**: Centralized error handler returning generic messages + structured codes; validate inputs at the boundary.

---

### DEBT-006 — No rate limiting on paax-api

**Status**: 🔴 Open · **Severity**: High · **Area**: Security / API · **Effort**: M

**Description**: paax-api endpoints are not rate limited. CORS is permissive (configured origins + always-allow localhost/`10.0.2.2`/LAN, `allow_credentials=True`).
**Why**: Statelessness prioritized; abuse not yet a problem.
**Impact**: A hostile client can hammer expensive `yt-dlp` matching, amplifying cost and upstream bot-blocking. Contradicts [`.claude/rules/api.md`](../.claude/rules/api.md).
**Fix Plan**: Add per-IP rate limiting (edge or middleware), especially on match-heavy endpoints. See [security](security.md).

---

## 🟡 Medium Priority Debt

### DEBT-007 — Orphaned paax-stream `resolve/` multi-provider pipeline

**Status**: 🔴 Open · **Severity**: Medium · **Area**: Streaming · **Effort**: M

**Description**: An entire unused resolver framework ships in paax-stream: `routes/resolve.py`, `resolver/provider_manager.py`, `resolver/fallback_policy.py`, five providers (`cobalt`/`piped`/`invidious`/`youtube_ipv6_proxy`/`youtube_local_mp4`), `services/*`. Not mounted; `youtube_ipv6_proxy` imports missing modules; `yt_dlp` absent from requirements. The README is stale.
**Why**: Scaffolding for a multi-provider future that was never wired.
**Impact**: Large dead surface confuses readers; stale README misleads. See [known issues](KNOWN_ISSUES.md) ISSUE-012.
**Fix Plan**: Delete or move to a clearly-experimental branch; rewrite README to describe only `/`, `/health`, `/stream`.

---

### DEBT-008 — Legacy `backend/` monolith superseded (and `/stream` broken)

**Status**: 🔴 Open · **Severity**: Medium · **Area**: Backend · **Effort**: M

**Description**: The original ytmusicapi+yt-dlp monolith is fully superseded by paax-api; its `/stream` throws `NameError: _FORMAT_FALLBACKS`.
**Why**: Kept during the transition to the v2 hybrid.
**Impact**: Duplicate v1 surface + broken code invite accidental use. See [known issues](KNOWN_ISSUES.md) ISSUE-001.
**Fix Plan**: Retire the service; port any still-needed v1 behavior into paax-api, then delete.

---

### DEBT-009 — Dead client code + dual configuration

**Status**: 🔴 Open · **Severity**: Medium · **Area**: Frontend · **Effort**: S

**Description**: `deezer_api_client.dart` (fully commented out), `media_session_web.dart` (commented out), orphaned `artist_items` screen, deprecated `thumbnail_prefetcher`; plus dual config: legacy `app_config.dart` vs live `api_config.dart`, and `api_constants.dart` used only by the dead Deezer client.
**Why**: Iterative pivots (direct-Deezer → hybrid; web media session experiments) left husks behind.
**Impact**: Editing the wrong file has no effect; misleads new contributors. See [known issues](KNOWN_ISSUES.md) ISSUE-009.
**Fix Plan**: Delete dead files; keep `api_config.dart` as the single config source.

---

### DEBT-010 — Two overlapping image-cache generations

**Status**: 🔴 Open · **Severity**: Medium · **Area**: Frontend / Performance · **Effort**: M

**Description**: `core/image/*` (`ImageRequestQueue`, `HostThrottleState`, `Lh3UrlBuilder`, `ImagePipeline`, `app_image.dart`) and `core/network/*` (`ThrottledHttpClient`, `ImageLoadQueue`) plus legacy widget variants (`network_image_with_fallback`, `smart_network_image`, `queued_network_image`) coexist.
**Why**: The 429 fight evolved across phases; older attempts were never removed.
**Impact**: Two systems to reason about when debugging 429s; higher change cost. See [optimization log](OPTIMIZATION_LOG.md) OPT-002, [ideas](IDEAS.md) IDEA-002.
**Fix Plan**: Consolidate onto the `app_image.dart` pipeline; delete the rest.

---

### DEBT-011 — Branding inconsistency Beaty/Paax

**Status**: 🔴 Open · **Severity**: Medium · **Area**: Branding · **Effort**: L

**Description**: Flutter package `beaty`, `BeatyGlassTokens`, `com.beaty.music.beaty`, manifest label `beaty`, assorted comments remain post-rebrand.
**Why**: Rebrand prioritized visible UI over identifiers; the Flutter package rename is invasive (every import).
**Impact**: Confusion + externally-visible Android identity. See [known issues](KNOWN_ISSUES.md) ISSUE-010.
**Fix Plan**: Coordinated rename; do the invasive package rename deliberately with a working build at each step.

---

### DEBT-014 — `yt-dlp` unpinned lower bound (paax-api)

**Status**: 🔴 Open · **Severity**: Medium · **Area**: Backend · **Effort**: XS

**Description**: paax-api requires `yt-dlp>=2024.1.0` with no upper pin. `yt-dlp` breaks frequently as YouTube changes; an unpinned bound risks a silent deploy-time break of the core match pipeline.
**Why**: Convenience.
**Impact**: Non-reproducible builds; matching can break on an unattended dependency resolution. See [dependencies](DEPENDENCIES.md).
**Fix Plan**: Pin to a known-good version and bump deliberately with a smoke test.

---

### DEBT-015 — Dual-store period: Hive live + Supabase deployed-but-unconsumed

**Status**: 🔴 Open (deliberate) · **Severity**: Medium · **Area**: Data / Architecture · **Incurred on**: 2026-07-16 · **Effort**: L

**Description**: Two persistence layers coexist: client-side Hive remains the **live** user datastore, while the full Supabase Postgres foundation (34 tables, RLS, Storage) is deployed and consumed by **nothing** ([database](database.md), [backend/database-schema.md](backend/database-schema.md)).
**Why it was incurred**: **Deliberate transitional debt** per [decisions.md](decisions.md) ADR-009's phased rollout — deploying the foundation first de-risks integration, but the gap between "deployed" and "used" is real debt until Phase 3 (Hive → cloud migration).
**Impact if unaddressed**: Docs/agents can mistake the Supabase schema for live behavior; schema may drift from actual client data shapes; the longer the gap, the harder the Hive migration.
**Fix Plan**: Execute ADR-009 Phases 2–3 (backend integration, then Flutter auth + Hive migration with Hive demoted to offline cache).

---

### DEBT-016 — Demo auth stub still live despite real Supabase Auth existing

**Status**: 🔴 Open · **Severity**: Medium · **Area**: Auth · **Incurred on**: 2026-07-16 · **Effort**: M

**Description**: The client still ships the hardcoded demo login (`user@gmail.com`/`12345`, always-succeed signup — ADR-008), while a real identity authority (Supabase Auth, with signup trigger, password policy, and owner bootstrap) is deployed and idle ([backend/auth.md](backend/auth.md)).
**Why it was incurred**: Phase 1 scope deliberately excluded Flutter integration.
**Impact if unaddressed**: Two "auth" systems to reason about; the cosmetic stub must never be mistaken for the real one; every week widens the UX/data gap to close at Phase 3.
**Fix Plan**: Phase 3 — wire `AuthController` to Supabase Auth (`supabase_flutter`), retire the stub, migrate the local profile.

---

## 🟢 Low Priority Debt

### DEBT-017 — Stories cleanup job not scheduled

**Status**: 🔴 Open · **Severity**: Low · **Area**: Supabase / Jobs · **Incurred on**: 2026-07-16 · **Effort**: S

**Description**: Expired stories are **soft-hidden** (visibility helpers + `active_stories` exclude them) but never purged — no pg_cron/backend job deletes expired rows or their `story-media` objects ([backend/database-schema.md](backend/database-schema.md)).
**Why it was incurred**: Phase 1 shipped schema only; no job infrastructure exists yet.
**Impact if unaddressed**: Expired stories and media accumulate — storage cost and stale private data retained beyond user expectation. Harmless today (no stories can be created yet), grows with Phase 4.
**Fix Plan**: Schedule a purge job (pg_cron or backend worker) deleting stories N days after expiry plus their `story-media` objects, before stories launch.

---

### DEBT-012 — Ad-hoc spacing, no design-token scale

**Status**: 🔴 Open · **Severity**: Low · **Area**: Frontend / UI · **Effort**: M

**Description**: Spacing is numeric literals throughout; only `AppColors` + `BeatyGlassTokens` exist as tokens. No central spacing/typography scale (the `.claude/rules/ui.md` 4px scale is unimplemented). `Responsive` provides breakpoints but not spacing.
**Impact**: Visual inconsistency; global tuning is find-and-replace. See [ideas](IDEAS.md) IDEA-001.
**Fix Plan**: Introduce `Spacing`/type scale and migrate incrementally when touching screens.

---

### DEBT-013 — `DynamicBackground` dormant

**Status**: 🔴 Open · **Severity**: Low · **Area**: Frontend / Theming · **Effort**: S

**Description**: Implemented Phase-5 color-environment driver mounted by no screen.
**Impact**: Confusing "is this used?" ambiguity; the intended cinematic-color feature isn't fully realized. See [known issues](KNOWN_ISSUES.md) ISSUE-011.
**Fix Plan**: Mount at shell level or delete.

---

## Phase 3.2A cloud-sync debt

### DEBT-018 — Cloud-hydrated library entities are sparse

**Status**: 🔴 Open · **Severity**: Low · **Area**: Library / Sync · **Incurred on**: 2026-07-17 · **Effort**: M

**Description**: `hydrateFromCloud` returns relation ids only, so a hydrated liked track's `artistName`/`artworkUrl` and a saved album's `artistName` are empty until re-fetched by browsing ([KNOWN_ISSUES.md](KNOWN_ISSUES.md) ISSUE-022).
**Why it was incurred**: The cloud stores durable relations, not the full display payload; a full denormalized mirror was out of scope for 3.2A.
**Impact if unaddressed**: Freshly hydrated lists on a new device look incomplete until the user navigates into each item.
**Fix Plan**: Batch-refetch sparse entities on hydrate (or store a minimal display cache server-side).

---

### DEBT-019 — Track cloud resolution depends on a known Deezer track id

**Status**: 🔴 Open · **Severity**: Medium · **Area**: Library / Sync · **Incurred on**: 2026-07-17 · **Effort**: M

**Description**: A liked/hidden track syncs only when its Deezer track id is resolvable (`Track.deezerTrackId`, HiveField 11). Pre-3.2A likes may lack it; hidden tracks recover it best-effort from a locally-known `Track`. Unresolved tracks stay local-only ([KNOWN_ISSUES.md](KNOWN_ISSUES.md) ISSUE-023).
**Why it was incurred**: The field is additive; older rows predate it and there is no backfill.
**Impact if unaddressed**: A subset of the pre-existing library never becomes cross-device.
**Fix Plan**: Backfill `deezerTrackId` by matching videoId→catalog, or resolve on next play.

---

### DEBT-020 — Onboarding search UUID coverage

**Status**: 🔴 Open · **Severity**: Low · **Area**: Onboarding · **Incurred on**: 2026-07-17 · **Effort**: S

**Description**: `/v2/find` can return artists with a null Supabase id; only cataloged or lazily-resolved (`/v2/artists/deezer/{id}`) artists yield a submittable UUID ([KNOWN_ISSUES.md](KNOWN_ISSUES.md) ISSUE-024).
**Why it was incurred**: Deezer-discovered artists aren't guaranteed to be in the catalog at search time; lazy resolve covers selection.
**Impact if unaddressed**: A search hit that fails to resolve can't be selected — minor UX friction.
**Fix Plan**: Pre-warm/ingest search results, or surface a clear "not yet available" affordance.

---

### DEBT-021 — "Clear Data" doesn't reset cloud/sync bookkeeping

**Status**: 🔴 Open (deliberate) · **Severity**: Low · **Area**: Library / Sync · **Incurred on**: 2026-07-17 · **Effort**: S

**Description**: Profile → "Clear Data" wipes Hive but not the Supabase rows nor `lastUserId`/migrated flags, so the same user re-hydrates on next login ([KNOWN_ISSUES.md](KNOWN_ISSUES.md) ISSUE-026).
**Why it was incurred**: Intended behavior for a cloud-backed library; a true erase needs a server-side deletion flow (not yet built).
**Impact if unaddressed**: "Clear Data" is easily mistaken for a full account reset.
**Fix Plan**: Add an explicit server-side "delete my library / account" flow; keep local clear separate.

---

## ✅ Paid Off Debt

| Debt # | Title | Fixed On | PR/Commit |
|--------|-------|----------|-----------|
| — | *(none paid off yet — register seeded 2026-07-16)* | — | — |

---

## Debt Metrics

| Metric | Value |
|--------|-------|
| Total open debt items | 21 |
| Critical + High items | 6 |
| Paid off this quarter | 0 |

---

## Architecture Review Findings (2026-07-16)

The [Architecture Review](architecture-review.md) adds structural debt beyond the register above — most notably **missing abstractions**:

- **No dependency injection** — `MusicRepositoryImpl()` is constructed directly in `SearchController` + 7 screens, so nothing is testable and the album cache is fragmented per-instance (`AR-MA-01`).
- **No typed error/result model** — try/catch-and-skip plus string-parsed errors in `ErrorStateWidget` (`AR-MA-02`).
- **Leaky playback identity** — `Track.id` overloaded to hold the YouTube `videoId` (`AR-MA-03`).
- **`List<dynamic>` in `Artist`** — type safety traded away to dodge a Hive-gen cycle (`AR-MA-04`).
- **Three streaming generations + orphaned resolver code** (`AR-TD-01`); **two image pipelines** (`AR-TD-03`); **unbounded process cache** in `youtube_cache.py` (`AR-TD-07`).

See [architecture-review.md](architecture-review.md) §1–§2 for the full list with evidence and recommendations.

---

## Phase 2.6 residuals (low)

- **`build_track_artists` "Unknown Artist" fallback** — `mappers/deezer_common`
  still emits a null-`deezer_id` "Unknown Artist" for a track with no artist. Not
  the discography bug (that flow is fixed) and tracks reliably carry an artist, so
  low risk; consider applying the same "no persistent placeholder" rule for
  consistency.
- **Response-cache invalidation depends on the Redis MCP** — there is no
  application endpoint to invalidate a specific `catalog:*` key. When the Redis
  MCP is unavailable, a stale artist/album response self-heals only on TTL
  (≤24h). A small internal/admin invalidation hook (or reconnected Redis access)
  would make post-cleanup revalidation immediate.

---

*Last updated: 2026-07-17*

