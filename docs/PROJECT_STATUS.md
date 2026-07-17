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
| Open Bugs (Critical) | 3 | Deezer `verify=False`; unauth v1 write endpoints; debug-key release signing |
| Open Bugs (Total) | ~8 | See [KNOWN_ISSUES.md](KNOWN_ISSUES.md) |
| Tech Debt Level | High | Dead/orphaned streaming code, dual config, no tests, ad-hoc spacing — [TECH_DEBT.md](TECH_DEBT.md) |

---

## Current Phase

```
Phase: [ ] Concept  [ ] Design  [ ] MVP  [x] Alpha  [ ] Beta  [ ] GA  [ ] Maintenance
```

**Description**: Feature-rich and demoable end-to-end (browse, play, library, lyrics, polished UI), and now with **real Supabase authentication** (Phase 3.1 — see [features/authentication.md](features/authentication.md)) replacing the old demo stub. Still **not production-ready** — no tests/CI, debug signing, and unconsolidated streaming block a real launch; the music library remains on-device (Hive), with cloud sync deferred to Phase 3.2+. Focus is on production hardening (see [roadmap.md](roadmap.md)).

---

## Milestone Progress

**Current Milestone**: v1.0 — Production Hardening
**Target Date**: TBD (solo maintainer)

| # | Goal | Status |
|---|------|--------|
| 1 | Consolidate streaming (one path + fallback), remove dead code | ⬜ Not started |
| 2 | Real signing config + Paax `applicationId` | ⬜ Not started |
| 3 | Fix Deezer `verify=False`; gate/remove unauth write endpoints | ⬜ Not started |
| 4 | Real per-user auth (replace demo stub) | 🟢 Done (Phase 3.1, 2026-07-17) — Supabase Auth wired into the Flutter app; demo stub removed. See [features/authentication.md](features/authentication.md) |
| 5 | Automated test baseline + CI | ⬜ Not started |

**Completion**: 1 / 5 goals complete (20%) — real per-user auth landed (Phase 3.1).

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
| No cloud library sync → no cross-device data (auth landed Phase 3.1; sync is Phase 3.2+) | Medium | uzielcezate | 2026 |
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
3. Cloud library sync: real Supabase auth is now live in the app (Phase 3.1 — see [features/authentication.md](features/authentication.md)); next is Phase 3.2+ cloud sync of the on-device Hive library, then automated tests + CI.

See [current-state.md](current-state.md), [roadmap.md](roadmap.md), [tasks/backlog.md](tasks/backlog.md).

---

## Backend health (paax-api, 2026-07-17)

- **Tests**: 85 passing (`pytest`).
- **Deploy**: Railway `paax-api` healthy (deployment `f2919948`), `/health` =
  `healthy` (supabase + redis healthy).
- **Latest fix**: Phase 2.6 catalog discography attribution (PR #3, `1ef1bd1`).

---

*Last updated: 2026-07-17*
