# Tasks

> **Purpose**: A high-level, always-current task list for the project. This is the single source of truth for "what needs to be done" at any given moment. More granular task tracking is in `docs/tasks/`.
> **Update when**: A task is added, started, completed, blocked, or cancelled. Update at the start and end of every work session.

> This list was seeded on 2026-07-16 from the codebase's visible stubs, [tech debt](TECH_DEBT.md), [known issues](KNOWN_ISSUES.md), and [feature requests](FEATURE_REQUESTS.md). Keep it live — check items off and move them as work progresses.

---

## Quick Status

| Category | Open | In Progress | Done |
|----------|------|-------------|------|
| Features | 5 | 1 | 0 |
| Bugs | 5 | 0 | 0 |
| Tech Debt | 8 | 0 | 0 |
| Docs | 0 | 0 | 14 (this doc pass) |

---

## 🔥 Immediate (Do Now)

Limit to 3 — the highest-leverage, lowest-effort items that unblock a real Paax release.

- [ ] **TASK-101** — Configure a real Android release signing config (kill debug signing). *(DEBT-002 / ISSUE-006, effort S)*
- [ ] **TASK-102** — Change Android `applicationId` from `com.beaty.music.beaty` to the final Paax id; update manifest label + TWA `assetlinks.json` fingerprints atomically. *(DEBT-003 / ISSUE-007, effort S)*
- [ ] **TASK-103** — Remove `verify=False` from the paax-api Deezer `httpx` client. *(DEBT-004 / ISSUE-002, effort XS)*

---

## 📋 Current Sprint

### Features

- [ ] **TASK-201** — Implement offline **downloads** (download queue, offline library, storage mgmt). Prereq: a real audio path (TASK-204). *(FR-001)*
- [ ] **TASK-202** — Real **per-user auth + cloud library sync** to replace the demo stub. *(FR-002)* — **Supabase Phase-1 foundation complete (2026-07-16, ADR-009)**: schema (34 RLS tables), storage buckets, and billing readiness deployed. Remaining: backend ingestion (Phase 2) + Flutter integration (Phase 3) — the app still runs on Hive + the demo stub and consumes nothing from Supabase yet.
- [ ] **TASK-203** — Build a working **Settings** screen (storage/cache, playback prefs, about/version). *(FR-003)*
- [ ] **TASK-204** — Wire a server-side **streaming path** into playback (choose Worker vs paax-stream) instead of the direct IFrame. *(FR-004 / IDEA-006)*
- [ ] **TASK-205** — Genuine **personalized recommendations** from local play history (not just recent searches). *(FR-005)*
- [ ] **TASK-206** — **Push notifications** for followed-artist releases. *(FR-006 — depends on server infra from TASK-202)*

### Bugs

- [ ] **FIX-301** — Fix or retire legacy backend `/stream` (`NameError: _FORMAT_FALLBACKS`). *(ISSUE-001)*
- [ ] **FIX-302** — Stop leaking `str(e)` to clients; add a centralized error handler. *(ISSUE-005 / DEBT-005)*
- [ ] **FIX-303** — Add rate limiting to paax-api (protect the `yt-dlp` match path). *(DEBT-006)*
- [ ] **FIX-304** — Ensure all YouTube match memoization uses the bounded `MemoryCache(500)` (no unbounded dicts). *(ISSUE-004)*
- [ ] **FIX-305** — Harden web image loading against 429 (consolidate the two image-cache generations). *(ISSUE-008 / DEBT-010)*

### Tech Debt

- [ ] **TASK-401** — Add the **first automated tests** + CI gate (mappers, match scorer, Hive migrations, v2 mappers). *(DEBT-001 / IDEA-005)*
- [ ] **TASK-402** — Delete dead client code + dual config (`app_config.dart`, `api_constants.dart`, `deezer_api_client.dart`, `media_session_web.dart`, orphaned `artist_items`). *(DEBT-009 / IDEA-011)*
- [ ] **TASK-403** — Delete/relocate paax-stream's orphaned `resolve/` pipeline; rewrite its stale README. *(DEBT-007 / ISSUE-012)*
- [ ] **TASK-404** — Retire the legacy `backend/` monolith once v1 needs are covered by paax-api. *(DEBT-008)*
- [ ] **TASK-405** — Pin `yt-dlp` to a known-good version in paax-api. *(DEBT-014)*
- [ ] **TASK-406** — Introduce a design-token spacing/type scale; migrate ad-hoc literals. *(DEBT-012 / IDEA-001)*
- [ ] **TASK-407** — Mount or remove `DynamicBackground`. *(DEBT-013 / ISSUE-011)*
- [ ] **TASK-408** — Complete the Beaty → Paax rename (incl. invasive Flutter package rename). *(DEBT-011 / ISSUE-010)*

### Documentation

- [x] **DOCS-501** — Backfill the honest doc set (cache, dependencies, error codes, known issues, optimization log, goals, feature requests, ideas, tech debt, versioning, changelog, contributing, tasks, meeting-notes README). *(completed 2026-07-16)*

---

## 📌 Backlog (Next Up)

1. iOS build reaching Android parity. *(FR-007)*
2. Crossfade / gapless playback (builds on prefetch; likely needs a real audio path). *(IDEA-007)*
3. Lyrics improvements — tap-line-to-seek, translation, better fuzzy matching. *(IDEA-008)*
4. Cache hit-rate + performance observability (aggregate `X-Cache`, capture baselines). *(IDEA-010)*
5. Same-origin image proxy to eliminate 429s at the source. *(IDEA-003)*

---

## 🚧 Blocked

| Task | Blocker | Waiting On | Since |
|------|---------|------------|-------|
| TASK-201 (downloads) | No first-party audio byte path in the app | TASK-204 (streaming path decision) | 2026-07-16 |
| TASK-206 (push) | Server infra **foundation** now exists (`user_devices`/`notifications` tables, ADR-009) but delivery pipeline + client integration still pending | TASK-202 (Phase 2/3 integration) | 2026-07-16 |

---

## ✅ Recently Completed

| Task | Completed | By |
|------|-----------|-----|
| DOCS-501 — honest documentation backfill | 2026-07-16 | Docs pass |
| Supabase Phase 1 foundation (schema, RLS, storage, billing readiness, owner bootstrap) | 2026-07-16 | AI agent |

---

## 🗑️ Cancelled

| Task | Reason | Date |
|------|--------|------|
| — | *(none cancelled yet)* | — |

---

*Last updated: 2026-07-16*
