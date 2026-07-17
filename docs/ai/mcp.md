# MCP (Model Context Protocol)

> **Purpose**: Documents the MCP servers configured for this project — what tools they expose, how they are configured, and how AI agents should use them.
> **Update when**: A new MCP server is added or removed, a tool's behavior changes, or configuration changes. This file is the required doc update for the trigger **"MCP config change → `docs/ai/mcp.md`"** in [`AGENTS.md`](../../AGENTS.md#documentation-contract) and [`PROJECT_RULES.md`](../../PROJECT_RULES.md).

> **See also**: [`agents.md`](agents.md), [`context.md`](context.md), [`../environment.md`](../environment.md) (env vars), [`../security.md`](../security.md).

---

## What is MCP?

The Model Context Protocol (MCP) lets AI assistants connect to external tools and services — databases, APIs, code-execution environments, and more. An MCP server exposes tools that an AI agent can call during a session, extending it beyond reading and editing files.

- **MCP Spec**: [https://modelcontextprotocol.io](https://modelcontextprotocol.io)
- **Conventional config file**: `.mcp.json` at the project root (never commit secrets into it).

---

## Configured MCP Servers

| Server Name | Transport | Scope | Purpose | Auth |
|------------|-----------|-------|---------|------|
| `supabase` | HTTP (`https://mcp.supabase.com/mcp`) | project (`.mcp.json`) | Supabase's hosted MCP — inspect/work against a specific Supabase project | OAuth (interactive); no secret in `.mcp.json` |

### `supabase`

**Purpose**: Gives AI agents Supabase tooling against the hosted project `project_ref=jecgmiuypuathhvjuhea` — the enabled feature groups are `docs`, `account`, `database`, `debugging`, `development`, `functions`, `branching`, `storage`. Configured at **project scope** in [`.mcp.json`](../../.mcp.json) (committed & shared with the team; it holds only a `project_ref`, no secret).

**Transport / URL**: `http` → `https://mcp.supabase.com/mcp?project_ref=<ref>&features=docs,account,database,debugging,development,functions,branching,storage`. The `features` query param determines which tool groups are exposed — trim it to the minimum a task needs (least privilege).

**Auth (interactive — must be done by a human in a real terminal, once per developer):**

```bash
# NOT in the IDE extension — a normal terminal:
claude /mcp
# → select the "supabase" server → Authenticate → complete the browser OAuth flow
```

Until you authenticate, the server's tools appear but calls fail. Tokens are stored by the Claude CLI outside the repo — never in `.mcp.json`.

> **Architectural note (updated 2026-07-16):** Supabase adoption is now decided — [`../decisions.md`](../decisions.md) **ADR-009** supersedes ADR-002, and this MCP **was used to apply the Phase 1 migrations** (schema, RLS, Storage buckets) to project `jecgmiuypuathhvjuhea`. Tooling access still does **not** mean the app consumes Supabase: application code (Flutter, paax-api) has **no Supabase integration yet** — user state remains client-side Hive ([`../database.md`](../database.md)) until ADR-009's Phases 2–3.
>
> **Migration discipline (non-negotiable):** every schema change applied through this MCP (`apply_migration`) must be **mirrored 1:1 in `supabase/migrations/`** in the same change. **No Dashboard-only or MCP-only schema changes** — the repo files are the reviewable record ([`../backend/database-schema.md`](../backend/database-schema.md)).

### Optional: Supabase Agent Skills

Supabase publishes agent skills (ready-made instructions and scripts for working with Supabase more accurately). Install locally (outside the repo, into your Claude skills directory):

```bash
npx skills add supabase/agent-skills
```

---

## How MCP *Would* Integrate With Paax

If MCP is adopted later, these are the natural fits given the architecture ([`../architecture.md`](../architecture.md)). This section is **forward-looking design guidance**, not a description of anything currently wired.

| Candidate server | Why it would help Paax | Notes / risk |
|------------------|------------------------|--------------|
| `filesystem` | Scoped file access for agents in constrained runners | Low risk (local); largely redundant with built-in file tools |
| `github` | Issues, PRs, release automation for `release-manager` | Needs a `GITHUB_TOKEN`; keep scopes minimal |
| `railway` / HTTP fetch | Inspect deploy status / logs of the three Railway Python services (`paax-api`, `paax-stream`, `backend`) | Read-only credentials only |
| `redis` | Inspect the `paax-api` cache and `paax-stream` IPv6 session store | Read-only; never expose write access to prod cache |
| `supabase` (**configured & used** — see [Configured MCP Servers](#configured-mcp-servers)) | Applied the Phase 1 migrations; ongoing schema/advisor/storage tooling for the ADR-009 rollout | Adoption is decided (ADR-009 supersedes ADR-002); app code integration is Phases 2–3. Always mirror changes into `supabase/migrations/` |

> Historical note: an earlier version of this doc advised skipping a Supabase MCP because Paax had no Supabase project. That changed on 2026-07-16 — the hosted Supabase MCP was configured and used to deploy the ADR-009 Phase 1 foundation. It authenticates via **OAuth, not a `SUPABASE_SERVICE_ROLE_KEY`**; keep the service-role key out of `.mcp.json` and out of git ([`../environment.md`](../environment.md)). The app code still does not consume Supabase — see [`../decisions.md`](../decisions.md) ADR-009.

---

## How To Add an MCP Server (When the Time Comes)

1. Research the server package and verify it is trustworthy (supply-chain risk is real).
2. Create `.mcp.json` at the repo root and add the server there (see template below).
3. Document any required environment variables in [`docs/environment.md`](../environment.md) — never hardcode credentials.
4. Add the server to the **Configured MCP Servers** table above and write a full spec (below).
5. Test every exposed tool before committing.
6. This file is the mandatory doc update for the change (trigger map).

### Full server spec template

Fill one of these out per configured server once any exist:

```
### <server-name>
**Purpose**: <what it enables>
**Package / Binary**: <e.g., @modelcontextprotocol/server-github>
**Auth**: <env var reference, never an inline secret>

| Tool | Description | When to Use |
|------|-------------|-------------|
| <tool_name> | <what it does> | <when to call it> |

Rate limits / constraints: <...>
```

### `.mcp.json` config template

```json
{
  "mcpServers": {
    "server-name": {
      "command": "npx",
      "args": ["-y", "@package/mcp-server"],
      "env": {
        "API_TOKEN": "${API_TOKEN}"
      }
    }
  }
}
```

---

## MCP Security Rules

MCP tool calls carry the **same** security weight as direct API calls — treat them under [`.claude/rules/security.md`](../../.claude/rules/security.md) and [`docs/security.md`](../security.md):

- **Never** put secrets directly in `.mcp.json`; reference environment variables (`${VAR}`) documented in [`docs/environment.md`](../environment.md).
- Prefer **read-only** credentials. Any server touching prod (Railway, Redis, GitHub) should be read-only unless a write is genuinely required and reviewed.
- Do not grant an MCP server broader scope than the task needs (least privilege). For `supabase`, that means trimming the `features` query param to what's actually required.
- **Secrets** must never be committed. A **project-scoped `.mcp.json` with no inline secrets is committed on purpose** (it is shared team config): the `supabase` server is safe to commit because it stores only a `project_ref` and authenticates via OAuth. If a server ever needs a secret, reference `${VAR}` from [`docs/environment.md`](../environment.md) — never inline it.
- The configured `supabase` MCP is a **live external tool surface** with broad features (`database`, `functions`, `storage`, `branching`, …). Treat its write-capable tools with the same caution as production access, and have a `security-reviewer` pass cover it.

---

*Last updated: 2026-07-16*
