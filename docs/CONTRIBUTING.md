# Contributing Guide

> **Purpose**: Defines how contributors — human or AI — should set up the project, follow conventions, submit changes, and participate in the review process.
> **Update when**: The development workflow changes, new tooling is introduced, or contribution rules are updated.

---

## Welcome

Thank you for contributing to **Paax** — a cross-platform (Android + Web/PWA/TWA) music streaming client that pairs **Deezer** metadata with **YouTube** playback. Before you start, read [CLAUDE.md](../CLAUDE.md) (the AI/agent entry point), [architecture](architecture.md), and [tech-stack](tech-stack.md) so you understand the real stack — which is **not** what the boilerplate `.claude/rules/*` assumes (no Riverpod, no go_router, no Supabase/Postgres). Please read this guide fully before opening a pull request.

---

## Repository Layout

Monorepo with four deployable components (frontend, paax-api, paax-stream, cloudflare-worker), the superseded legacy `backend/`, and docs. See [architecture](architecture.md) for detail.

```
Paax/
  frontend/         # Flutter app (package name "beaty"), Android + Web/PWA/TWA — the live client
    lib/core/       #   config, constants, image, network, playback, theme, utils
    lib/data/       #   api, local (Hive), repositories
    lib/domain/     #   entities, repositories (interfaces), services
    lib/presentation/  # screens, widgets, state (5 Provider/ChangeNotifier controllers)
    android/        #   Android host (foreground service, TWA assetlinks)
  paax-api/         # FastAPI — LIVE metadata service (v1 ytmusicapi + v2 Deezer/YouTube hybrid)
  paax-stream/      # FastAPI — IPv6 byte proxy (deployed, NOT consumed by the live app)
  cloudflare-worker/# Workers JS — edge stream-URL resolver (Innertube)
  backend/          # FastAPI legacy monolith — SUPERSEDED by paax-api (do not extend)
  docs/             # This documentation set
  .claude/rules/    # Coding rules (some aspirational — correct them, don't blindly follow)
```

> **Architecture is layer-first, not feature-first.** The Flutter code uses `core/data/domain/presentation`, contrary to `.claude/rules/flutter.md`'s feature-first prescription. Match the existing layout.

---

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Flutter SDK | >= 3.3 (Dart 3) | https://flutter.dev/docs/get-started/install |
| Android SDK / Studio | JDK 17 (Java & Kotlin target 17) | via Android Studio |
| Python | 3.11 | https://python.org (for the 3 backend services) |
| Redis | 5.x | Optional locally (paax-api caches, paax-stream sessions) |
| Node + Wrangler | current | Only if working on `cloudflare-worker/` |
| Git | >= 2.40 | https://git-scm.com |

---

## Setup Instructions

### 1. Clone

```bash
git clone https://github.com/uzielcezate/Paax.git
cd Paax
```

### 2. Frontend (Flutter)

```bash
cd frontend
flutter pub get
# Generate Hive adapters if you touch @HiveType entities:
dart run build_runner build --delete-conflicting-outputs

# Run against production API (default ENV=prod → api.paaxmusic.app):
flutter run

# Run against a local paax-api on your PC:
flutter run --dart-define=ENV=local            # http://127.0.0.1:8000
# Run against a LAN paax-api (real Android device):
flutter run --dart-define=ENV=lan --dart-define=LAN_IP=192.168.x.x
```

Config lives in `lib/core/config/api_config.dart` (dart-defines `ENV`, `LAN_IP`, `API_BASE_URL`, `STREAM_BASE_URL`). Ignore the legacy `app_config.dart`. See [environment](environment.md).

### 3. Backend services (Python)

Each service is independent. Example for **paax-api** (the live one):

```bash
cd paax-api
python -m venv .venv && source .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -r requirements.txt
# Optional env (see docs/environment.md): YTMUSIC_OAUTH_JSON, REDIS_URL, FRONTEND_ORIGINS
uvicorn main:app --reload --port 8000
```

paax-stream and the legacy backend follow the same pattern (`uvicorn app.main:app` / `uvicorn main:app`). Full env-var inventory is in [environment](environment.md). Note: paax-stream's `resolve/` provider pipeline is **orphaned/dead** — don't try to run it (see [known issues](KNOWN_ISSUES.md) ISSUE-012).

### 4. Environment variables

There is no `.env.example` committed. All variables are optional for local dev except where noted; the authoritative list is [environment](environment.md). **Never commit secrets** (`YTMUSIC_OAUTH_JSON`, any keys) — see [`.claude/rules/security.md`](../.claude/rules/security.md).

### 5. Verify it works

```bash
# Frontend gate (there is no test suite yet — see below):
cd frontend && flutter analyze && dart format --output=none --set-exit-if-changed .

# Backend smoke check:
curl http://localhost:8000/health     # {"ok": ..., "authenticated": ...}
```

---

## Development Workflow

1. **Create a branch** from `main` using the convention in [`.claude/rules/git.md`](../.claude/rules/git.md):
   ```
   git checkout -b feat/short-description   # feat|fix|hotfix|chore|docs|refactor|test|perf
   ```

2. **Make changes** following the applicable rules in `.claude/rules/` — but **correct rules that contradict reality** rather than following them blindly (they assume a different stack). When in doubt, match the existing code and the docs in this folder.

3. **Read the relevant docs first**: the feature doc under [docs/features/](features/), plus [architecture](architecture.md) / [api](api.md) / [database](database.md) as relevant. Don't re-decide settled matters — check [decisions](decisions.md).

4. **Tests**: `.claude/rules/testing.md` mandates tests, and new pure logic (mappers, the match scorer, Hive migrations) **should** ship with unit tests. Be aware the repo currently has **no test suite** (see [testing](testing.md), [tech debt](TECH_DEBT.md) DEBT-001) — adding the first tests for code you touch is strongly encouraged.

5. **Analyze & format** (the real, enforced gates):
   ```bash
   cd frontend
   flutter analyze
   dart format .
   ```

6. **Commit** using [Conventional Commits](https://www.conventionalcommits.org/) (see [`.claude/rules/git.md`](../.claude/rules/git.md)):
   ```
   feat(player): add crossfade support between tracks
   fix(cache): bound the youtube match memory cache
   docs(api): document the /v2/match endpoint
   ```
   Subject: imperative, lowercase, ≤ 72 chars, no trailing period.

7. **Open a Pull Request** against `main`.

---

## The Documentation Contract

Docs are part of the definition of done. Per [CLAUDE.md](../CLAUDE.md) and the rules, a change is not complete until its docs are updated:

- **API change** → update [`docs/api.md`](api.md) (and [versioning](VERSIONING.md) if a namespace is affected). Never break an existing namespace's contract silently.
- **New/changed cache or TTL** → update [`docs/CACHE_STRATEGY.md`](CACHE_STRATEGY.md).
- **New/removed dependency** → update [`docs/DEPENDENCIES.md`](DEPENDENCIES.md).
- **New error code** → update [`docs/ERROR_CODES.md`](ERROR_CODES.md).
- **New env var** → update [`docs/environment.md`](environment.md).
- **Notable change** → add a [`docs/CHANGELOG.md`](CHANGELOG.md) entry (Keep a Changelog format).
- **Incurred a shortcut** → log it in [`docs/TECH_DEBT.md`](TECH_DEBT.md) with justification.
- **Found a bug you can't fix now** → record it in [`docs/KNOWN_ISSUES.md`](KNOWN_ISSUES.md).
- **A performance change** → add an entry to [`docs/OPTIMIZATION_LOG.md`](OPTIMIZATION_LOG.md) (measure if you can; "no formal metrics captured" is acceptable but discouraged).
- **An architectural decision** → record it in [`docs/decisions.md`](decisions.md).
- Set the `*Last updated:*` footer of every doc you edit to the current date.

---

## Pull Request Guidelines

- Descriptive title in Conventional Commits format.
- Description explains **what** and **why** (not just what changed).
- Link related tasks: `Closes #42` or `Relates to TASK-007` (see [tasks](TASKS.md)).
- Ensure `flutter analyze` + `dart format` pass before requesting review (there is no CI to catch it for you yet).
- Squash commits when merging feature branches.
- Do not resolve others' review comments yourself — the reviewer resolves.

---

## Code Review Expectations

**As an author:**
- Expect detailed feedback; address all comments before re-requesting review.
- Disagree respectfully in-thread.

**As a reviewer:**
- Review for correctness, security (see the checklist in [`.claude/rules/security.md`](../.claude/rules/security.md)), performance, and doc-contract compliance.
- Pay special attention to the known sharp edges: image 429 throttling, playback/WebView lifecycle, Hive migrations (data-loss risk), and anything touching the shared-account write endpoints.
- Approve only when confident the code is correct and the docs are updated.

---

## Commit Sign-Off

*(No DCO/CLA required currently. Remove this note when one is added.)*

---

## Reporting Bugs

1. Search [`docs/KNOWN_ISSUES.md`](KNOWN_ISSUES.md) first — it may already be documented (many current gaps are).
2. If new, open an issue with: steps to reproduce, expected vs actual behavior, platform (Android / Web), and app/service version ([versioning](VERSIONING.md)).

---

## Getting Help

- Start with this `docs/` set — [CLAUDE.md](../CLAUDE.md) has a navigation table.
- Check [decisions](decisions.md) before re-litigating architectural choices.
- Open a GitHub Discussion/issue for anything the docs don't cover.

---

*Last updated: 2026-07-16*
