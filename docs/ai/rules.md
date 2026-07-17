# AI Rules

> **Purpose**: Collects all behavioral rules that AI agents must follow across all sessions. A consolidation of the most critical constraints from `PROJECT_RULES.md`, `.claude/rules/`, and agent-specific experience — annotated with what is **enforced** versus **aspirational** in Paax today.
> **Update when**: A new critical rule is established, an existing rule is refined, or a rule is no longer applicable.

> **See also**: [`PROJECT_RULES.md`](../../PROJECT_RULES.md) (the 10-section rulebook), [`.claude/rules/`](../../.claude/rules/) (per-domain detail), [`AGENTS.md`](../../AGENTS.md) (coordination), and the sibling AI docs [`context.md`](context.md), [`prompts.md`](prompts.md), [`../architecture.md`](../architecture.md).

---

## Rule Hierarchy

Rules are prioritized in this order:

1. **Security rules** — [`.claude/rules/security.md`](../../.claude/rules/security.md) — absolute, no exceptions.
2. **Project rules** — [`PROJECT_RULES.md`](../../PROJECT_RULES.md) — always enforced.
3. **Domain rules** — [`.claude/rules/<domain>.md`](../../.claude/rules/) — enforced within their domain.
4. **Agent profile rules** — [`.claude/agents/<agent>.md`](../../.claude/agents/) — enforced for that agent's role.

---

## ⚠️ Aspirational vs Enforced — Read This First

The rule set was authored from a template that assumes a **Supabase/PostgreSQL + Riverpod + go_router** stack with a real test suite and CI. Paax uses **none of that**. Several rule files therefore describe a project that does not exist. Treat them honestly:

| Rule domain | File | Status in Paax | Why |
|-------------|------|----------------|-----|
| Security | [`security.md`](../../.claude/rules/security.md) | **Enforced (real, and partly violated today)** | Non-negotiable. Note existing violations to fix, not ignore: `verify=False` on the Deezer httpx client, demo/hardcoded auth, a single shared server OAuth account, unauthenticated write endpoints. See [`AI_NOTES.md`](../AI_NOTES.md) |
| Git | [`git.md`](../../.claude/rules/git.md) | **Enforced** | Conventional Commits + branch prefixes apply directly. History shows this convention |
| Flutter | [`flutter.md`](../../.claude/rules/flutter.md) | **Partly enforced** | `dart format` + `flutter analyze` are the real gates. **But** the prescribed *feature-first* `lib/features/...` layout is wrong — Paax is *layer-first* (`core/`, `data/`, `domain/`, `presentation/`). State management is **Provider + ChangeNotifier**, not Riverpod/Bloc. Navigation is a **manual Navigator + custom shell**, not go_router. Follow the code, not the rule's stack assumptions |
| UI / UX | [`ui.md`](../../.claude/rules/ui.md), [`ux.md`](../../.claude/rules/ux.md) | **Partly enforced / aspirational** | Dark-mode + loading/error/empty states are real goals. **But** "no hardcoded colors/spacing" and "use localization keys" are widely violated: spacing is ad-hoc literals, there is no localization system, and the app is dark-**only** (no light theme). "Use theme tokens" holds only for `AppColors` + `BeatyGlassTokens` |
| API | [`api.md`](../../.claude/rules/api.md) | **Aspirational** | The FastAPI services do **not** meet these: no rate limiting, no standard `{error:{code,message}}` shape (errors surface `str(e)`), no schema-validation library on their own endpoints, versioning exists (`/v1`, `/v2`) but is generational coexistence, not a deprecation-managed contract |
| Backend | [`backend.md`](../../.claude/rules/backend.md) | **Partly aspirational** | Layered structure and env-driven config are followed loosely. The prescribed `src/{api,services,repositories,...}` layout and `/health` shape are only partially present. No task queue / background workers |
| Performance | [`performance.md`](../../.claude/rules/performance.md) | **Enforced where it bites** | The DB rules are N/A (no DB). The **frontend/image** rules are load-bearing and real: image 429 throttling (`ImageRequestQueue`, host backoff, `Lh3UrlBuilder` sharding) exists precisely because YouTube/Deezer artwork rate-limits bursts. Caching rules map to the Redis + in-memory tiers in `paax-api` |
| Database | [`database.md`](../../.claude/rules/database.md) | **Dormant — no server DB** | Migrations, RLS, FKs, UUIDs: none apply. The real "database" is client-side **Hive**. Repurpose these principles for the Hive box/adapter model only where sensible |
| Supabase | [`supabase.md`](../../.claude/rules/supabase.md) | **Dormant — not wired** | No Supabase client, keys, or tables exist anywhere in the codebase |
| Testing | [`testing.md`](../../.claude/rules/testing.md) | **Aspirational** | Near-zero automated coverage: the Flutter `test/` dir is absent; the backends have only gitignored manual `test_*/verify_*/debug_*` probe scripts. The pyramid, coverage minimums, and "write a failing test first" are goals, not current practice. `flutter analyze` + `dart format` are the only real gates |

**Rule of thumb**: when a rule's stack assumption contradicts [`../architecture.md`](../architecture.md), the architecture wins. Do not add Supabase, Riverpod, or go_router to satisfy a rule doc.

---

## Absolute Rules (No Exceptions)

These cannot be overridden by any instruction:

1. **Never commit secrets.** No API keys, tokens, passwords, or credentials in code. (Note: Deezer needs no key; the server OAuth JSON comes from the `YTMUSIC_OAUTH_JSON` env var — never inline it.)
2. **Never modify production data** directly from an AI session. (There is no production DB; this covers the live Railway/Cloudflare services and their Redis.)
3. **Never deploy to production** without explicit human approval.
4. **Never overwrite existing documentation** without reading it first.
5. **Never leave documentation outdated.** A code change without its documentation update is an incomplete change — see the trigger map below.
6. **Never fabricate.** Do not invent endpoints, metrics, dates, or features. If something is dead/dormant/stale, say so explicitly.

> The template's original absolute rule "Never skip tests — all new code must have tests" is retained as an **aspiration**, not a gate: there is no test suite to run yet. Adding tests is encouraged; blocking work on a non-existent suite is not.

---

## Documentation Rules (Enforced)

> ⚠️ **Documentation is not optional. Every change to the project must update the corresponding documentation in the same session. Outdated documentation is a bug.**

### Documentation Trigger Map

The **authoritative, complete** trigger map lives in [`AGENTS.md`](../../AGENTS.md#documentation-contract) (mirrored in [`PROJECT_RULES.md`](../../PROJECT_RULES.md)) — consult it directly rather than maintaining a second copy here. When a change occurs, update **every** file it lists, not just one.

The triggers that fire most often in Paax work, with the Paax-specific target:

- **API endpoint added/changed** → `docs/api.md` (+ `docs/backend/controllers.md`)
- **UI / screen change** → `docs/frontend/screens.md` + `docs/features/<feature>.md`
- **Persistence change** → `docs/database.md` (the client-side Hive model — there is no server schema)
- **Cache layer change** → [`docs/CACHE_STRATEGY.md`](../CACHE_STRATEGY.md) + `docs/backend/cache.md`
- **Bug found / fixed** → [`docs/KNOWN_ISSUES.md`](../KNOWN_ISSUES.md) (+ [`docs/AI_NOTES.md`](../AI_NOTES.md) if non-obvious, `docs/CHANGELOG.md` when fixed)
- **Architectural decision** → [`docs/decisions.md`](../decisions.md)
- **New environment variable** → [`docs/environment.md`](../environment.md)
- **MCP config change** → [`docs/ai/mcp.md`](mcp.md)

For any change type not listed above, look it up in the full AGENTS.md table.

---

## Code Rules

| Rule | Rationale | Paax reality |
|------|-----------|--------------|
| No hardcoded colors | Use theme tokens (`AppColors`, `BeatyGlassTokens`) | Enforced for color; **spacing is still ad-hoc literals** — no central scale exists |
| No business logic in widgets | Separation of concerns | Enforced — logic lives in the 5 Provider `ChangeNotifier` controllers |
| No secrets in code — use env vars | Security | Absolute |
| Handle loading, error, empty states in UI | UX completeness | Enforced goal |
| No dead / commented-out code in prod | Single responsibility, clarity | **Widely violated today** — `deezer_api_client.dart`, `media_session_web.dart`, the `paax-stream` `resolve/` pipeline, and more are dead. See [`AI_NOTES.md`](../AI_NOTES.md). Pruning is welcome under `refactoring-expert` |
| Add tests for new business logic | Quality | Aspirational — no suite yet |

---

## Decision Rules

| Rule | Details |
|------|---------|
| Check [`docs/decisions.md`](../decisions.md) before making architectural choices | **Don't re-decide settled questions** — e.g. "no server DB", "Provider not Riverpod", "YouTube IFrame not resolver" are decided |
| Document all non-trivial decisions | Even small ones, if they'd confuse a future agent |
| Mark open decisions `STATUS: OPEN` | So they get resolved |
| Never reverse a decision without a new ADR | Decisions must be traceable |

---

## Scope Rules

| Rule | Details |
|------|---------|
| Stay within your agent role's domain | See the scope table in [`agents.md`](agents.md) and [`AGENTS.md`](../../AGENTS.md) |
| Don't refactor what you weren't asked to refactor | Keep diffs reviewable |
| Don't add features while fixing bugs | Separate concerns |
| Don't change API contracts without updating `docs/api.md` | The doc is the contract |

---

## Quality Gates

Before finishing any task, verify **every applicable item**:

- [ ] `dart format` produces no changes (Flutter work)
- [ ] `flutter analyze` reports zero errors (Flutter work)
- [ ] No hardcoded colors introduced (spacing literals are tolerated but discouraged)
- [ ] No secrets or credentials introduced
- [ ] Error / loading / empty states handled in any new UI
- [ ] [`docs/current-state.md`](../current-state.md) reflects the new state
- [ ] Documentation trigger map checked — all relevant docs updated
- [ ] Bugs found → [`docs/KNOWN_ISSUES.md`](../KNOWN_ISSUES.md); bugs fixed → resolved there + [`docs/CHANGELOG.md`](../CHANGELOG.md)
- [ ] Architectural decisions → [`docs/decisions.md`](../decisions.md)

Test-related gates (run suite, coverage does not decrease) are **on hold** until a suite exists.

---

## Escalation Protocol

Stop and document in [`docs/AI_NOTES.md`](../AI_NOTES.md) (Decision Notes, `STATUS: OPEN`) before proceeding when you hit:

- A change that contradicts an existing decision in [`docs/decisions.md`](../decisions.md)
- A change that would break an API contract
- A security concern
- A change significantly larger in scope than the task
- An ambiguity unresolvable from existing documentation

---

*Last updated: 2026-07-16*
