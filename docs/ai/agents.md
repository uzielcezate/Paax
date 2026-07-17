# AI Agents

> **Purpose**: Documents the AI agents configured for this project — their roles, capabilities, scope, and how to invoke them. This is the operational reference for the multi-agent system.
> **Update when**: A new agent is added, an agent's scope changes, or the coordination model changes.

> **See also**: [`AGENTS.md`](../../AGENTS.md) for coordination rules, [`.claude/agents/`](../../.claude/agents/) for the raw agent profiles, [`../architecture.md`](../architecture.md) for the system the agents operate on, and the sibling AI docs [`context.md`](context.md), [`rules.md`](rules.md), [`prompts.md`](prompts.md), [`memory.md`](memory.md), [`mcp.md`](mcp.md).

---

## Agent Overview

Paax is a heavily AI-agent-driven codebase. Almost all engineering work — the Flutter client, the FastAPI metadata/stream services, and the docs themselves — is produced by AI coding assistants (Claude Code plus Gemini, Antigravity, Cursor, Codex, etc.). To keep that work coherent, the project defines **12 specialized agent profiles** under [`.claude/agents/`](../../.claude/agents/). Each profile scopes a role: what it owns, what it may touch, what it must not touch, and which rules in [`.claude/rules/`](../../.claude/rules/) it must follow.

All agents share one memory: the `docs/` tree. There is no runtime multi-agent orchestrator wiring these profiles together — they are **behavioral contracts**, not services. An operator (human or a driving agent) selects a profile per task, and the profile constrains that session's behavior. Coordination between sessions happens exclusively through documentation, per [`AGENTS.md`](../../AGENTS.md).

> **Reality check.** Two profiles — `supabase-architect` and `database-reviewer` — describe a Supabase/PostgreSQL backend that **does not exist** in Paax. All user state lives client-side in Hive; the Python backends are stateless proxies with only caches. Those two profiles are aspirational boilerplate carried over from the template. See the notes in the registry below and in [`rules.md`](rules.md).

---

## Agent Registry

The 12 profiles, their domains, and their read/write boundaries. The "Can touch" / "Cannot touch" columns are the authoritative scope from the [`AGENTS.md`](../../AGENTS.md) roles table; the "Applicability" column flags how much of the profile maps to Paax as it actually exists today.

| Agent ID | Profile | Primary Domain | Can Touch | Cannot Touch | Applicability |
|---------|---------|----------------|-----------|--------------|---------------|
| `frontend-architect` | [profile](../../.claude/agents/frontend-architect.md) | UI architecture, routing, state | Frontend code, UI docs | Backend services, DB schema | Full — `frontend/` is the largest surface |
| `backend-architect` | [profile](../../.claude/agents/backend-architect.md) | Service design, infrastructure | Backend code (`paax-api/`, `paax-stream/`, `cloudflare-worker/`, `backend/`), infra docs | Frontend code | Full |
| `flutter-expert` | [profile](../../.claude/agents/flutter-expert.md) | Dart/Flutter implementation | Flutter code, `pubspec.yaml`, native config (with care), `docs/features/` | Backend logic directly | Full — the core day-to-day role |
| `supabase-architect` | [profile](../../.claude/agents/supabase-architect.md) | Auth, DB, RLS, realtime | Supabase config, migrations, `docs/database.md` | Application logic | **Dormant — no Supabase/Postgres in Paax.** Persistence is Hive (client-side). Do not invoke unless a real server DB is introduced |
| `database-reviewer` | [profile](../../.claude/agents/database-reviewer.md) | Schema review | `docs/database.md`, migration files | Application code | **Limited — no server schema to review.** Repurpose for reviewing the Hive box/adapter model if needed |
| `api-reviewer` | [profile](../../.claude/agents/api-reviewer.md) | API contract review | `docs/api.md`, route handlers | Business logic, DB layer | Partial — reviews FastAPI `/v1` + `/v2` contracts; many rule-book expectations (versioned URLs, rate limiting, standard error shapes) are **not yet met** by the services |
| `performance-reviewer` | [profile](../../.claude/agents/performance-reviewer.md) | Performance audits | Profiling, docs | Core logic | Full — image 429 throttling and YouTube-match latency are the live hotspots |
| `security-reviewer` | [profile](../../.claude/agents/security-reviewer.md) | Security audits | Security configs, docs | Feature code | Full — real findings exist (see [`AI_NOTES.md`](../AI_NOTES.md)): `verify=False` TLS, demo auth, shared server OAuth account, unauthenticated write endpoints |
| `bug-hunter` | [profile](../../.claude/agents/bug-hunter.md) | Debugging | Any file (read + targeted fix), test files, `docs/tasks/completed.md`, `docs/current-state.md` | Unrelated refactors, new features, infra | Full — but note the "write a failing test first" step is aspirational; there is no test suite yet |
| `refactoring-expert` | [profile](../../.claude/agents/refactoring-expert.md) | Code quality | Any code file | Feature scope changes | Full — plenty of dead code to prune (see [`AI_NOTES.md`](../AI_NOTES.md)) |
| `documentation-writer` | [profile](../../.claude/agents/documentation-writer.md) | Documentation | `docs/` only | Source code | Full — the profile that maintains this doc set |
| `release-manager` | [profile](../../.claude/agents/release-manager.md) | Releases, versioning | CI/CD, `docs/release-notes.md` | Feature code | Partial — no CI pipeline yet; releases are manual (1 tag: `v0.1-mobile-stable`) |

---

## When to Invoke Which Agent

| Scenario | Recommended Agent(s) |
|----------|---------------------|
| Planning a new screen or UI feature | `frontend-architect` |
| Writing Flutter widgets or screens | `flutter-expert` |
| Designing / changing a FastAPI endpoint | `backend-architect` → `api-reviewer` |
| Investigating a crash or playback bug | `bug-hunter` |
| Improving image-load or match latency | `performance-reviewer` |
| Security pass before a release | `security-reviewer` |
| Removing dead code (see `AI_NOTES.md`) | `refactoring-expert` |
| Updating documentation | `documentation-writer` |
| Cutting a release / bumping version | `release-manager` |
| ~~Designing database tables~~ | ~~`supabase-architect` → `database-reviewer`~~ — **N/A**, no server DB. Client state changes go through `flutter-expert` (Hive model) |

For deeper task-to-context mapping (which docs each agent should read first), see [`context.md`](context.md). For ready-to-use invocation prompts, see [`prompts.md`](prompts.md).

---

## Agent Scope Boundaries (Why They Exist)

The scope columns are not bureaucracy — they prevent the two failure modes that hurt AI-driven codebases most:

1. **Scope creep.** A `bug-hunter` that "just also refactors this while I'm here" produces unreviewable diffs. Profiles hard-stop that: bug-hunter cannot refactor, refactoring-expert cannot change features, documentation-writer cannot touch source.
2. **Silent divergence.** A frontend change that quietly alters an API contract breaks the backend agent's mental model. Profiles route cross-cutting changes through the reviewer chain and force the [Documentation Contract](../../AGENTS.md#documentation-contract) trigger map to fire.

When a task genuinely spans two domains (e.g. a new endpoint plus the screen that consumes it), run the domains **sequentially** and let each update the docs the other reads — never edit a shared file without re-reading the latest version first ([`AGENTS.md` › Parallel Work Guidelines](../../AGENTS.md#parallel-work-guidelines)).

---

## Agent Memory System

Agents have no memory between sessions. The documentation system **is** the memory. See [`memory.md`](memory.md) for the full protocol; the anchors:

| Memory Type | Location |
|-------------|----------|
| Project context / entry point | [`CLAUDE.md`](../../CLAUDE.md) |
| Coordination rules | [`AGENTS.md`](../../AGENTS.md) |
| Rules and standards | [`PROJECT_RULES.md`](../../PROJECT_RULES.md), [`.claude/rules/`](../../.claude/rules/) |
| Architectural decisions (ADRs) | [`docs/decisions.md`](../decisions.md) |
| Current status | [`docs/current-state.md`](../current-state.md) |
| Cross-session gotchas | [`docs/AI_NOTES.md`](../AI_NOTES.md) |
| Task tracking | [`docs/tasks/`](../tasks/) |
| Feature context | [`docs/features/`](../features/) |

---

## Multi-Agent Coordination

The full protocol lives in [`AGENTS.md`](../../AGENTS.md):

- **Core principle**: docs are the single source of truth; code is secondary.
- **Handoff protocol**: update the relevant `docs/` file, log completed tasks, record decisions.
- **Conflict resolution**: most-recent code wins; documentation wins over assumptions; unresolved ambiguity becomes a `STATUS: OPEN` entry in [`docs/decisions.md`](../decisions.md).
- **Parallel work**: different features may proceed in parallel; shared modules must coordinate through `docs/`.

---

*Last updated: 2026-07-16*
