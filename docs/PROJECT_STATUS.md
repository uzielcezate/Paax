# Project Status

> **Purpose**: A dashboard-style snapshot of the project's overall health, progress, and readiness. Designed for AI agents and team members who need to understand the current state at a glance before starting work.
> **Update when**: At the start/end of every sprint, after a release, or when the overall project state changes significantly.

---

## Overall Health

| Dimension | Status | Notes |
|-----------|--------|-------|
| Build | 🟢 Passing | Flutter builds (web/Android); `flutter analyze` is the gate |
| Tests | 🔴 None | No automated tests / CI — see [testing.md](testing.md) |
| Deployments | 🟢 Healthy | paax-api, Worker, paax-stream, web PWA up; no uptime monitoring |
| Open Bugs (Critical) | 3 | Deezer `verify=False`; unauth write endpoints; debug-key release signing |
| Open Bugs (Total) | ~8 | See [KNOWN_ISSUES.md](KNOWN_ISSUES.md) |
| Tech Debt Level | High | Dead/orphaned streaming code, dual config, no tests, ad-hoc spacing — [TECH_DEBT.md](TECH_DEBT.md) |

---

## Current Phase

```
Phase: [ ] Concept  [ ] Design  [ ] MVP  [x] Alpha  [ ] Beta  [ ] GA  [ ] Maintenance
```

**Description**: Feature-rich and demoable end-to-end (browse, play, library, lyrics, polished UI), but **not production-ready** — demo auth, no tests/CI, debug signing, and unconsolidated streaming block a real launch. Focus is shifting to production hardening (see [roadmap.md](roadmap.md)).

---

## Milestone Progress

**Current Milestone**: v1.0 — Production Hardening
**Target Date**: TBD (solo maintainer)

| # | Goal | Status |
|---|------|--------|
| 1 | Consolidate streaming (one path + fallback), remove dead code | ⬜ Not started |
| 2 | Real signing config + Paax `applicationId` | ⬜ Not started |
| 3 | Fix Deezer `verify=False`; gate/remove unauth write endpoints | ⬜ Not started |
| 4 | Real per-user auth (replace demo stub) | 🟨 Foundation deployed (Supabase Phase 1, ADR-009, 2026-07-16); integration pending — app still on demo auth |
| 5 | Automated test baseline + CI | ⬜ Not started |

**Completion**: 0 / 5 goals complete (0%) — milestone just defined.

---

## Environment Status

| Environment | Status | Version | Last Deploy | URL |
|-------------|--------|---------|-------------|-----|
| Development | 🟢 Up | local | — | `127.0.0.1:8000` / `:8080` |
| Staging | ⚪ None | — | — | none |
| Production | 🟢 Up | app `1.0.0+1` / tag `v0.1-mobile-stable` | continuous | `*.paaxmusic.app` |

---

## Team Velocity (Current Sprint)

Single maintainer (`uzielcezate`); no formal sprints. Development is continuous (163 commits, one tag). Recent activity concentrated on liquid-glass UI polish and the v2 hybrid metadata pipeline.

---

## Active Blockers

| Blocker | Impact | Owner | Since |
|---------|--------|-------|-------|
| Streaming fragmentation (IFrame vs Worker vs IPv6 proxy) unresolved | Medium | uzielcezate | 2026 |
| No real auth → no cross-device data, blocks public launch | High | uzielcezate | 2026 |
| Debug-key release signing + Beaty `applicationId` | High | uzielcezate | 2026 |

---

## Key Metrics

> No analytics/APM instrumented — metrics are unmeasured. Instrumentation is a prerequisite backlog item.

| Metric | Value | Target | Trend |
|--------|-------|--------|-------|
| Crash-free rate | N/A | > 99% | — |
| Metadata p95 (warm cache) | N/A | < 200 ms | — |
| Play success rate | N/A | > 95% | — |
| Active users | N/A | — | — |

---

## What's Next

1. Consolidate streaming and delete dead resolver code (ADR-006).
2. Production hardening: signing, `applicationId`, TLS, endpoint auth.
3. Real auth + cloud sync: the Supabase Phase-1 foundation is deployed (ADR-009; see [backend/database-schema.md](backend/database-schema.md)) — next is Phase 2 backend ingestion, then Phase 3 Flutter integration; then automated tests + CI.

See [current-state.md](current-state.md), [roadmap.md](roadmap.md), [tasks/backlog.md](tasks/backlog.md).

---

## Backend health (paax-api, 2026-07-17)

- **Tests**: 85 passing (`pytest`).
- **Deploy**: Railway `paax-api` healthy (deployment `f2919948`), `/health` =
  `healthy` (supabase + redis healthy).
- **Latest fix**: Phase 2.6 catalog discography attribution (PR #3, `1ef1bd1`).

---

*Last updated: 2026-07-17*
