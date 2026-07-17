# Paax — Project Knowledge Index

> **This is the first document every AI agent must read.** It is not a normal README. Its job is to give you maximum understanding of Paax for the minimum number of tokens, and to route you to the exact document you need so you never have to scan the codebase. Read this, then read the [AI Reading Order](#ai-reading-order), then read only the docs and code your task requires.

---

## 🚀 Quick Context (30 seconds)

**Project:** Paax — a cross-platform (Android + Web/PWA/TWA) music app that **owns no music**: it shows **Deezer** metadata and plays **YouTube** audio.

**Architecture (accurate — the live path below is unchanged; a Supabase foundation now exists but is NOT yet consumed by any app code):**

```
Flutter client  ──►  paax-api (Python/FastAPI)  ──►  Deezer API (metadata)
   │  (package: beaty)         │  Deezer + YouTube "hybrid v2"   └► YouTube search (videoId match)
   │                           └► Redis + in-memory cache
   ├─► YouTube IFrame  ──────────────────────────────────►  YouTube / googlevideo CDN (audio)
   └─► Hive (on-device)  ◄── still the ONLY live user datastore (library, playlists, settings)

Standby stream resolvers (not on the live path): Cloudflare Worker (Innertube) · paax-stream (IPv6 byte proxy)

Deployed but NOT connected (Phase 1, ADR-009): Supabase project (Postgres 34-table schema + RLS,
Auth, Storage buckets, billing readiness) — see backend/database-schema.md. Nothing consumes it yet.
```

**Current Phase:** **Alpha** — feature-complete and demoable end-to-end, not production-hardened.

**Main Goals:**
- Deliver a Spotify/Apple-Music-class experience for free by composing Deezer metadata + YouTube playback.
- Stay cheap and private: thin stateless backends, all user data on-device.
- Ship a polished, cohesive "cinematic black" UI across Android and Web.

**Current Priorities:**
1. Consolidate streaming to one path + fallback and remove dead code ([decisions.md](decisions.md) ADR-006).
2. Production hardening — real signing config + Paax `applicationId`, fix Deezer `verify=False`, gate/remove unauthenticated write endpoints.
3. Real per-user auth + cloud sync — the Supabase foundation is now deployed ([decisions.md](decisions.md) ADR-009); the next step is integration (Flutter/paax-api still use Hive + demo auth).

**Last Updated:** 2026-07-16

---

## AI Reading Order

**Before reading any source code, always read these files in this exact order:**

1. [docs/current-state.md](current-state.md) — what works / is broken / in progress right now
2. [docs/architecture.md](architecture.md) — system design and the reasoning behind it
3. [docs/decisions.md](decisions.md) — settled architectural decisions (ADRs)
4. [docs/PROJECT_STATUS.md](PROJECT_STATUS.md) — health dashboard
5. [docs/roadmap.md](roadmap.md) — where the product is going
6. [docs/database.md](database.md) — the client-side Hive data model (still the live store; the deployed-but-unconnected Supabase schema is in [backend/database-schema.md](backend/database-schema.md))
7. [docs/api.md](api.md) — the paax-api contract (v1 + v2) and stream resolvers

Only inspect source code **after** reading these documents.

- **Never scan the entire repository.**
- **Never recursively index folders.**
- **Never inspect unrelated code.**
- **Prefer documentation over source code whenever possible.**

New to the project? Read [onboarding.md](onboarding.md) first (mental model, local run, request trace) and keep [glossary.md](glossary.md) open for terminology.

---

## Documentation Map

The core, cross-cutting documents. (Feature, architecture-detail, development, AI, and process docs are indexed in their own sections below; together these tables cover every file in `docs/`.)

| File | Purpose | When to read | Owner |
|------|---------|--------------|-------|
| [README.md](README.md) | This knowledge index & AI entry point | First, always | Both |
| [onboarding.md](onboarding.md) | Getting started: mental model, local run, request trace, first-task playbooks | When new to the repo | Both |
| [glossary.md](glossary.md) | Canonical definitions of every domain/architecture term | When a term is unclear | Both |
| [current-state.md](current-state.md) | Live snapshot: working / broken / in-progress | Before every task | Both |
| [PROJECT_STATUS.md](PROJECT_STATUS.md) | Health dashboard (build, tests, bugs, milestone) | Before planning work | Both |
| [architecture.md](architecture.md) | System topology, data flow, architecture & dependency graphs | Before any structural change | Both |
| [architecture-review.md](architecture-review.md) | Architect's prioritized improvement backlog (debt, perf, security, etc.) | Before large refactors / planning | Both |
| [decisions.md](decisions.md) | ADRs — why the system is built this way | Before any architectural choice | Both |
| [feature-map.md](feature-map.md) | Feature dependency map + change blast-radius | Before touching a feature | Both |
| [tech-stack.md](tech-stack.md) | Every technology & library (and what's deliberately *not* used) | Before adding a dependency | Both |
| [api.md](api.md) | paax-api v1/v2 + Worker + paax-stream contracts | Before any API work | Both |
| [database.md](database.md) | Hive data model + ER diagram (client-side only) | Before any persistence change | Both |
| [CACHE_STRATEGY.md](CACHE_STRATEGY.md) | Every cache layer, key, and TTL | Before touching caching | Both |
| [environment.md](environment.md) | Every environment variable across all services | Before deploy/config work | Both |
| [deployment.md](deployment.md) | How to run & deploy each component | Before running or deploying | Both |
| [roadmap.md](roadmap.md) | Vision, milestones, feature roadmap | For direction / prioritization | Both |
| [release-notes.md](release-notes.md) / [CHANGELOG.md](CHANGELOG.md) | Release history / running change log | When releasing or checking history | Both |
| [VERSIONING.md](VERSIONING.md) | SemVer + API versioning policy | Before a version bump or breaking change | Both |
| [AI_NOTES.md](AI_NOTES.md) | ⚠️ Gotchas, dead code, stale comments | Before debugging / editing unfamiliar code | Both |
| [KNOWN_ISSUES.md](KNOWN_ISSUES.md) | Current bugs & gaps | Before fixing a bug (it may be logged) | Both |
| [TECH_DEBT.md](TECH_DEBT.md) | Structural debt register | Before refactors | Both |
| [OPTIMIZATION_LOG.md](OPTIMIZATION_LOG.md) | History of performance optimizations | Before/after perf work | Both |
| [ERROR_CODES.md](ERROR_CODES.md) | Catalog of error codes across services | When handling/returning errors | Both |
| [DEPENDENCIES.md](DEPENDENCIES.md) | Full dependency inventory | Before adding/upgrading deps | Both |
| [PROJECT_GOALS.md](PROJECT_GOALS.md) | Product mission, users, non-goals | For product context | Both |
| [FEATURE_REQUESTS.md](FEATURE_REQUESTS.md) / [IDEAS.md](IDEAS.md) | Requested features / forward ideas | For backlog grooming | Both |
| [TASKS.md](TASKS.md) | Live task checklist | Before starting work | Both |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Contributor & setup guide | When setting up / contributing | Both |
| [meeting-notes/](meeting-notes/README.md) | Meeting notes (seed/empty) | Rarely — historical context | Human |

---

## Feature Documentation

Every document in [`docs/features/`](features/). Read the one matching your task; cross-check [feature-map.md](feature-map.md) for dependencies.

| File | Purpose |
|------|---------|
| [features/home.md](features/home.md) | Home screen: greeting, charts, genre rows, "For You" |
| [features/search.md](features/search.md) | Debounced parallel search; genre browse grid |
| [features/library.md](features/library.md) | Liked / playlists / albums / artists tabs (Hive-backed) |
| [features/albums.md](features/albums.md) | Album detail, save/unsave, track lists |
| [features/artists.md](features/artists.md) | Artist profiles (2-phase load), discography, follow |
| [features/playlist.md](features/playlist.md) | Playlist CRUD, reorder, pin (Hive `Playlist`) |
| [features/player.md](features/player.md) | The player: YouTube-IFrame engine, queue, media session |
| [features/profile.md](features/profile.md) | Local profile, stats, recently played |
| [features/authentication.md](features/authentication.md) | **Demo/stub** auth (no real accounts) |
| [features/recommendations.md](features/recommendations.md) | Charts / related artists (no ML recommender) |
| [features/downloads.md](features/downloads.md) | **Planned/not implemented** (inert download button) |
| [features/offline.md](features/offline.md) | **Planned** — library browses offline, playback needs network |
| [features/settings.md](features/settings.md) | **Stub** — real settings limited to a few Hive keys |
| [features/notifications.md](features/notifications.md) | OS media notification (implemented); push (not implemented) |

---

## Architecture Documentation

High-level system design plus the layer-specific detail docs.

**System-level:** [architecture.md](architecture.md) · [architecture-review.md](architecture-review.md) · [decisions.md](decisions.md) · [feature-map.md](feature-map.md) · [tech-stack.md](tech-stack.md) · [database.md](database.md) · [api.md](api.md) · [CACHE_STRATEGY.md](CACHE_STRATEGY.md)

**Backend detail** ([`docs/backend/`](backend/)) — three Python services + Cloudflare Worker (no queue, no ORM; a Supabase Postgres foundation is deployed but not yet on the live path — ADR-009):

| File | Purpose |
|------|---------|
| [backend/controllers.md](backend/controllers.md) | FastAPI route handlers (maps to [api.md](api.md)) |
| [backend/services.md](backend/services.md) | Deezer/hybrid/YouTube services; paax-stream IPv6 proxy |
| [backend/repositories.md](backend/repositories.md) | External-API data-access clients (no server repo/DB layer) |
| [backend/cache.md](backend/cache.md) | Redis + in-memory caching (backend view of [CACHE_STRATEGY.md](CACHE_STRATEGY.md)) |
| [backend/auth.md](backend/auth.md) | Demo auth + single shared YouTube account |
| [backend/database-schema.md](backend/database-schema.md) | Supabase Postgres schema reference (Phase 1 deployed, not yet consumed) |
| [backend/queue.md](backend/queue.md) | Async model (`asyncio` + semaphores; no message queue) |
| [backend/workers.md](backend/workers.md) | Cloudflare Worker stream resolver |
| [backend/storage.md](backend/storage.md) | No object storage — where assets actually live |

**Frontend detail** ([`docs/frontend/`](frontend/)) — Flutter, layer-first, Provider + ChangeNotifier:

| File | Purpose |
|------|---------|
| [frontend/state-management.md](frontend/state-management.md) | Provider controllers (Auth/Library/Playback/Search/Theme) |
| [frontend/navigation.md](frontend/navigation.md) | Shell, per-tab Navigators, nav-flow diagram |
| [frontend/routing.md](frontend/routing.md) | Imperative routing model (no go_router) |
| [frontend/screens.md](frontend/screens.md) | Every screen |
| [frontend/widgets.md](frontend/widgets.md) | Every widget group |
| [frontend/theming.md](frontend/theming.md) | Dark-only theme + dynamic color pipeline |

**Design system** ([`docs/design/`](design/)): [design-system.md](design/design-system.md) · [colors.md](design/colors.md) · [typography.md](design/typography.md) · [spacing.md](design/spacing.md) · [components.md](design/components.md) · [animations.md](design/animations.md) · [icons.md](design/icons.md) · [responsive.md](design/responsive.md)

---

## Development Documentation

Standards and operational docs for building, testing, deploying, and securing Paax.

| File | Purpose |
|------|---------|
| [coding-standards.md](coding-standards.md) | Style, naming, error handling, file organization |
| [testing.md](testing.md) | Testing strategy (**near-zero coverage today**; targets defined) |
| [deployment.md](deployment.md) | Run & deploy each component (Railway / Cloudflare / Flutter) |
| [environment.md](environment.md) | Every environment variable, per service |
| [security.md](security.md) | Security posture, risks, and non-negotiables |
| [performance.md](performance.md) | Budgets, bottlenecks, optimization strategies |

Related standards live in [`.claude/rules/`](../.claude/rules/) (git, api, backend, flutter, database, performance, security, testing, ui, ux) and the AI-operations docs in [`docs/ai/`](ai/): [agents.md](ai/agents.md) · [context.md](ai/context.md) · [rules.md](ai/rules.md) · [prompts.md](ai/prompts.md) · [memory.md](ai/memory.md) · [mcp.md](ai/mcp.md). Task tracking: [tasks/backlog.md](tasks/backlog.md) · [tasks/in-progress.md](tasks/in-progress.md) · [tasks/completed.md](tasks/completed.md).

---

## Decision Records

Architectural decisions are stored in [**decisions.md**](decisions.md) as ADRs (Accepted / Rejected / Superseded / Deprecated / Open). **These decisions must never be ignored or re-litigated.** Before proposing an architectural change, read the relevant ADR; if you believe a decision should change, write a *new* superseding ADR rather than silently contradicting the old one. Key settled decisions include: Deezer+YouTube hybrid (ADR-001), Provider state management (ADR-003), IFrame playback (ADR-004), dark-only "cinematic black" UI (ADR-007), and Supabase adoption for auth/catalog/social/sync (ADR-009 — which **supersedes** ADR-002's "no server DB"; Hive remains the live client store until migration).

---

## Current Project Status

[**current-state.md**](current-state.md) and [**PROJECT_STATUS.md**](PROJECT_STATUS.md) always represent the latest project state — read them before starting any task, and keep them in sync (they must agree).

**If documentation conflicts with source code:** the docs are authoritative *as intent*, but reality wins. Verify the actual implementation in the code, then **update the documentation** to match what you verified (noting the correction). Never leave a known conflict unresolved — stale documentation is a bug ([PROJECT_RULES.md](../PROJECT_RULES.md) §10).

---

## AI Rules

Every AI agent must:

1. **Read this document first.**
2. **Read documentation before code** (in the [AI Reading Order](#ai-reading-order)).
3. **Inspect only files related to the requested task.**
4. **Avoid unnecessary repository scans** — no full-repo or recursive folder indexing unless explicitly requested.
5. **Avoid duplicate implementations** — reuse existing abstractions; add one only when genuinely missing.
6. **Respect architectural decisions** in [decisions.md](decisions.md).
7. **Update documentation after every significant change** (per the Documentation Contract in [AGENTS.md](../AGENTS.md) / [PROJECT_RULES.md](../PROJECT_RULES.md) §10).
8. **Treat documentation as production code** — same accuracy and review bar; leave it more complete than you found it.

The canonical, always-on version of these rules lives in [`CLAUDE.md`](../CLAUDE.md) → Operating Protocol.

---

## Context Optimization

- The documentation is the project's **long-term memory**.
- **Prefer documentation over source code** whenever it answers the question.
- **Inspect source code only when documentation is missing or outdated** — and when you do, update the docs so the next agent doesn't have to.
- The goal is to **reduce token consumption while preserving architectural understanding** — read the index and the targeted doc, not the repository.

---

## Quick Start — do this before writing a single line of code

1. Read the [AI Reading Order](#ai-reading-order) (7 docs), then [AI_NOTES.md](AI_NOTES.md) for gotchas.
2. Open the **one** doc matching your task — a [feature](#feature-documentation), an [architecture](#architecture-documentation) layer, or a [development](#development-documentation) concern — and, if relevant, check [feature-map.md](feature-map.md) for blast radius.
3. Confirm no [decision](decisions.md) constrains your approach; if adding a dependency, check [tech-stack.md](tech-stack.md).
4. Inspect **only** the specific source files the doc points to. Do not scan folders.
5. Make the **minimal, convention-respecting** change; verify it (`flutter analyze` / manual run — see [testing.md](testing.md)).
6. **Update every doc the Documentation Contract requires** in the same change, and reconcile [current-state.md](current-state.md) if project state shifted.

---

*Last updated: 2026-07-16*
