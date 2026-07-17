# AI Prompts

> **Purpose**: A library of reusable prompts, instructions, and task templates that produce high-quality, consistent results when used with AI coding assistants on Paax.
> **Update when**: A new prompt pattern is discovered, an existing prompt is refined, or a prompt is deprecated.

> **See also**: [`agents.md`](agents.md) (which role to name), [`context.md`](context.md) (what each role should read), [`rules.md`](rules.md) (the constraints), [`AGENTS.md`](../../AGENTS.md#documentation-contract) (the Documentation Contract), [`../architecture.md`](../architecture.md).

---

## How to Use This File

1. Find the prompt category that matches your task.
2. Copy the template.
3. Fill in the `[placeholders]` with your specific values.
4. Use with any supported assistant (Claude, Gemini, Cursor, Codex, etc.).

Every good Paax prompt does five things — the **effective prompt principles**: (1) name the agent role, (2) point to context to read, (3) define the task precisely, (4) list constraints/what-not-to-do, (5) define the output format.

---

## Paax-Specific Prompting Conventions

These conventions matter more than generic prompt engineering because of how this repo is built:

- **"Read before writing."** Always instruct the agent to read the relevant docs first. Because [docs are authoritative and code is secondary](context.md#the-core-principle-docs-are-authoritative-code-is-secondary), and because the code contains dead paths and stale comments, an agent that reads code first will be misled. Point it at [`CLAUDE.md`](../../CLAUDE.md) → [`architecture.md`](../architecture.md) → the feature/rule doc → [`AI_NOTES.md`](../AI_NOTES.md).
- **Invoke the Documentation Contract trigger map.** End every implementation prompt with "update the docs required by the trigger map in `AGENTS.md`". A change without its doc update is incomplete. See [`AGENTS.md`](../../AGENTS.md#documentation-contract).
- **Name the stack honestly in the prompt.** The rule docs assume Supabase/Riverpod/go_router. Tell the agent the truth up front so it doesn't "helpfully" add them: *Provider + ChangeNotifier* for state, *manual Navigator + custom shell* for nav, *Hive* for persistence, *no server DB*, *YouTube IFrame* for playback. See [`rules.md`](rules.md#aspirational-vs-enforced--read-this-first).
- **Warn about dead code.** Reference [`AI_NOTES.md`](../AI_NOTES.md) so the agent doesn't "fix" `getStreamUrl`, `deezer_api_client`, `media_session_web`, or the `paax-stream` `resolve/` pipeline that are intentionally unused.
- **Require Conventional Commits.** Per [`.claude/rules/git.md`](../../.claude/rules/git.md): `type(scope): subject`, imperative, lowercase, ≤72 chars, on a `feat/` `fix/` `chore/` `docs/` `refactor/` branch — never directly on `main`.
- **Ask for `dart format` + `flutter analyze`, not "run the tests".** There is no test suite. Those two commands are the only real gates ([`rules.md`](rules.md#quality-gates)).

---

## Prompt Templates

---

### Feature Implementation (generic)

```
You are a [flutter-expert / backend-architect] working on Paax.

Read first (docs are authoritative, code is secondary):
- CLAUDE.md and docs/architecture.md for the system shape
- docs/features/[feature-name].md for requirements
- .claude/rules/[relevant].md — but note docs/ai/rules.md for what is
  aspirational vs enforced (no Supabase/Riverpod/go_router — this app uses
  Provider+ChangeNotifier, manual Navigator, Hive persistence)
- docs/AI_NOTES.md so you don't touch known dead code

Task:
Implement [description].

Constraints:
- Follow PROJECT_RULES.md; stay inside your agent's scope (docs/ai/agents.md)
- No hardcoded colors (use AppColors / BeatyGlassTokens); handle loading,
  error, and empty states
- Do not add new state-management, routing, or backend frameworks
- Do not modify files outside the [feature] area unless necessary

Output:
- List files created/modified (absolute or repo-relative paths)
- Summarize decisions made
- Update the docs required by the AGENTS.md trigger map
- Confirm `dart format` + `flutter analyze` are clean
```

---

### Add a New Screen (flutter-expert)

```
You are a flutter-expert on Paax.

Read first:
- docs/architecture.md and docs/frontend/screens.md
- docs/frontend/navigation.md — Paax uses a custom shell: MainWrapper hosts an
  IndexedStack of 4 tabs, each with its OWN nested Navigator; the full player is
  an overlay (not a route), toggled via MainWrapper.shellKey. There is NO
  go_router.
- lib/presentation/screens/ for sibling screens to match style
- .claude/rules/ui.md and .claude/rules/ux.md

Task:
Add a [screen name] screen that [does what], reachable from [entry point].

Constraints:
- One screen per file under lib/presentation/screens/; extract sub-widgets >~80 lines
- Consume state via Consumer/Selector/context.watch — no business logic in the widget
- Use AppColors tokens; handle loading / error / empty states explicitly
- Wire navigation through the existing nested-Navigator pattern, not a new router

Output:
- Files added/modified
- How the screen is pushed and popped
- Update docs/frontend/screens.md and docs/features/<feature>.md
- `dart format` + `flutter analyze` clean
```

---

### Add / Change an API Endpoint (backend-architect → api-reviewer)

```
You are a backend-architect on Paax, then hand off to api-reviewer.

Read first:
- docs/api.md — note the two coexisting generations: /v1 (legacy, ytmusicapi)
  and /v2 (Deezer metadata + eager YouTube-match playback, the LIVE path)
- docs/architecture.md — the backends are STATELESS proxies with Redis +
  in-memory caches; there is no server database and no per-user auth
- paax-api/main.py, deezer_mapper, cache.py
- .claude/rules/api.md AND docs/ai/rules.md (several api rules are aspirational:
  no rate limiting / standard error shape today — improve, don't assume they exist)

Task:
[Add endpoint /v2/... | change contract of ...].

Constraints:
- Preserve existing /v1 and /v2 contracts; version breaking changes
- Reuse the deezer_mapper normalization and the two-tier cache with an explicit TTL
- Do not add per-user auth assumptions — there are no server accounts
- Surface errors cleanly (do not just leak str(e) — that's an existing anti-pattern)

Output:
- Endpoint signature, response shape, cache key + TTL
- Update docs/api.md (the contract)
- api-reviewer pass: status APPROVED / CHANGES REQUESTED with severities
```

---

### Bug Investigation (bug-hunter)

```
You are a bug-hunter on Paax.

Bug Report:
- Description: [what is broken]
- Repro steps: [numbered]
- Expected: [...]   Actual: [...]
- First seen: [version/date]

Read first:
- docs/KNOWN_ISSUES.md — already documented?
- docs/AI_NOTES.md — is this actually intentional dead code? (e.g. getStreamUrl
  and the stream resolvers are DEFINED BUT UNUSED in the live playback path,
  which plays videoId directly through the YouTube IFrame)
- docs/features/[relevant].md — expected behavior

Task:
1. Find the ROOT CAUSE, not the symptom.
2. Make the minimal, targeted fix — no refactoring, no new features.
3. Verify by exercising the actual flow (there is no test suite to lean on; if you
   add a regression test, that's a bonus, not a blocker).
4. Update docs/KNOWN_ISSUES.md (+ CHANGELOG.md if fixed) and docs/current-state.md.
```

---

### Code Review (api-reviewer / security-reviewer / performance-reviewer)

```
You are a [security-reviewer] on Paax.

Review this change:
[paste diff or describe]

Evaluate against:
- .claude/rules/[relevant].md and PROJECT_RULES.md
- docs/ai/rules.md for what is actually enforced here
- Known live issues to weight heavily (security): verify=False on the Deezer
  httpx client, demo/hardcoded auth, a single shared server OAuth account,
  unauthenticated write endpoints

Output:
- Status: APPROVED / CHANGES REQUESTED
- Issues: each with severity (Critical/High/Medium/Low) and a specific fix
- Note anything worth recording in docs/AI_NOTES.md
```

---

### Remove Dead Code (refactoring-expert)

```
You are a refactoring-expert on Paax.

Read first: docs/AI_NOTES.md (the dead-code inventory) and docs/decisions.md.

Task:
Remove [deezer_api_client.dart / media_session_web.dart / the paax-stream
resolve/ pipeline / ...], which docs/AI_NOTES.md documents as dead.

Constraints:
- Confirm zero live references before deleting (grep the whole repo)
- Behavior-preserving only — no feature changes
- If a "dead" thing turns out to be reachable, STOP and log it in AI_NOTES.md
- Update docs/current-state.md and docs/CHANGELOG.md; commit with a
  `refactor(scope): ...` message on a refactor/ branch
```

---

### Documentation Update (documentation-writer)

```
You are a documentation-writer on Paax. You may edit docs/ only — never source.

Recent change: [describe what was implemented/changed]

Update the docs required by the AGENTS.md trigger map for this change, e.g.:
- [list the specific doc files]

Rules:
- Docs are the source of truth — be accurate; if something is dead/dormant, say so
- Preserve each template's skeleton (Purpose/Update-when header, --- sections,
  tables, the trailing *Last updated: 2026-07-16* line)
- Cross-link related docs with relative markdown links
- Do not invent endpoints, metrics, or dates
```

---

## Effective Prompt Principles (Recap)

1. **Give the agent a role** — name the profile from [`agents.md`](agents.md).
2. **Point to context** — direct it to the docs in [`context.md`](context.md), architecture first.
3. **Define the task precisely** — say what to do *and* what not to do.
4. **State the real stack** — pre-empt Supabase/Riverpod/go_router "help".
5. **Define output + doc obligations** — files changed, decisions, trigger-map doc updates, `dart format` + `flutter analyze`.

---

*Last updated: 2026-07-16*
