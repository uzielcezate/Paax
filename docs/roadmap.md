# Roadmap

> **Purpose**: Tracks the product vision, planned features, and milestone schedule. Helps agents understand what to build next and what is out of scope for the current cycle.
> **Update when**: A new milestone is planned, priorities shift, or a milestone is completed.

---

## Vision

Paax aims to be a **free, beautiful, cross-platform music app** that delivers a Spotify/Apple-Music-class experience by composing Deezer's clean catalog metadata with YouTube's audio — with no catalog licensing and minimal server cost. Over the next cycle the focus shifts from "feature-complete demo" to **production-ready**: durable user data, real accounts, a single reliable streaming path, and store-shippable Android/iOS builds.

---

## Current Milestone

**Milestone**: v1.0 — Production Hardening
**Target Date**: TBD (solo maintainer)
**Status**: At Risk (blocking gaps: demo auth, debug signing, streaming fragmentation)

### Goals for This Milestone

- [ ] Consolidate streaming to one reliable path + fallback (ADR-006); remove dead resolver code
- [ ] Real signing config + Paax `applicationId`; remove debug-key release signing
- [ ] Fix Deezer `verify=False`; gate or remove unauthenticated write endpoints
- [ ] Replace demo auth with real per-user authentication — **Supabase Phase-1 foundation deployed 2026-07-16** ([decisions.md](decisions.md) ADR-009); Flutter/paax-api integration still pending
- [ ] Finish Beaty → Paax rebrand across app id, READMEs, manifests
- [ ] Establish an automated test baseline + CI

---

## Upcoming Milestones

| Milestone | Description | Target | Status |
|-----------|-------------|--------|--------|
| v1.1 — Durable Library | Cloud sync + backup/restore so uninstall no longer destroys data — server foundation deployed (ADR-009 Phase 1); rollout: Phase 2 backend ingestion (Deezer upsert + YouTube matcher + Redis jobs) → Phase 3 Flutter integration + Hive migration → Phase 4 social (friends/stories/notifications) → Phase 5 Stripe activation | After v1.0 | Foundation deployed; integration planned |
| v1.2 — Offline | Functional downloads + offline playback (wire `stream_candidates`, local file cache) | After v1.1 | Planned |
| v1.3 — Discovery | Personalized recommendations beyond charts/related | Later | Planned |
| v2.0 — Multi-platform | iOS build + parity; possible desktop | Later | Exploratory |

---

## Feature Roadmap

### Now (current work)
- Liquid-glass UI polish (Phase 5).
- Streaming consolidation investigation.
- Branding migration Beaty → Paax.

### Next (next cycle)
- Real authentication + cloud sync integration — the Supabase server datastore now exists (deployed Phase 1, [decisions.md](decisions.md) ADR-009, [backend/database-schema.md](backend/database-schema.md)); next: Phase 2 backend ingestion, then Phase 3 Flutter Auth + Hive migration.
- Working Settings screen (currently a stub — [features/settings.md](features/settings.md)).
- Downloads + offline mode ([features/downloads.md](features/downloads.md), [features/offline.md](features/offline.md)).
- Automated tests + CI ([testing.md](testing.md)).
- Backend hardening: rate limiting, input validation, error-code envelope, observability.

### Later (backlog / future)
- Push notifications (FCM) — [features/notifications.md](features/notifications.md).
- Personalized recommendations — [features/recommendations.md](features/recommendations.md).
- iOS release.
- Design-token + spacing scale adoption ([design/spacing.md](design/spacing.md)).
- Library export/import; crossfade/gapless (limited by IFrame playback).

### Won't Do / Descoped

| Feature | Reason Descoped |
|---------|-----------------|
| Own music catalog / licensing | Out of scope — Paax composes Deezer + YouTube by design |
| ~~Supabase/Postgres for current features~~ | **No longer descoped** — ADR-009 (2026-07-16) supersedes ADR-002; the Phase-1 Supabase foundation is deployed (integration pending) |
| Server-side audio hosting | Playback goes CDN-direct via IFrame; hosting bytes is unnecessary |
| Native `just_audio` stream extraction | Rejected (ADR-004) — fragile against YouTube changes |

---

## Success Metrics

> No analytics are instrumented yet (a prerequisite backlog item). Targets are aspirational.

| Metric | Target | Current |
|--------|--------|---------|
| Crash-free sessions | > 99% | Unmeasured |
| Play success rate (track → audio) | > 95% | Unmeasured |
| Metadata p95 (warm cache) | < 200 ms | Unmeasured |
| Library retained across sessions | 100% on-device | Achieved (no cross-device) |

See [tasks/backlog.md](tasks/backlog.md), [PROJECT_GOALS.md](PROJECT_GOALS.md), and [current-state.md](current-state.md).

---

*Last updated: 2026-07-16*
