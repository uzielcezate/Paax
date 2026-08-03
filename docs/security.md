# Security

> **Purpose**: Documents security requirements, practices, known vulnerabilities, and threat mitigations. The security rules here are **non-negotiable**. Agents must review this file before any work touching auth, data access, or external inputs.
> **Update when**: A new vulnerability is discovered, a security measure is added, or the threat model changes.

---

## Security Principles

1. **Defense in depth.** Multiple layers of security, not a single barrier.
2. **Least privilege.** Every component gets only the permissions it needs.
3. **Zero trust.** Never assume a request is safe because it came from inside the system.
4. **Fail securely.** On error, deny access rather than grant it.
5. **Validate all input.** Every piece of user input is potentially malicious.

> **Reality check:** Paax is an early-stage, single-maintainer project with a deliberately small attack surface (no server DB, no user accounts, no payments). Several of the principles above are **aspirational** — this document states honestly where the code meets them and where it does not. See [KNOWN_ISSUES.md](KNOWN_ISSUES.md) and [TECH_DEBT.md](TECH_DEBT.md).

---

## Threat Model (what actually matters here)

Because there is **no per-user account, no PII on any server, and no payment data**, the classic account-takeover / data-breach threats are largely out of scope *today*. The real risks are:

1. **Abuse of open proxy/resolver endpoints** (paax-stream `/stream`, the Worker) as a general-purpose proxy.
2. **Upstream abuse / rate-limit bans** (Deezer, YouTube) taking the app down.
3. **Shared-account misuse**: the single `YTMUSIC_OAUTH_JSON` account backing paax-api's write endpoints.
4. **Transport integrity** (the Deezer client disables TLS verification).
5. **Information leakage** via `str(e)` in 500 responses.

---

## Authentication & Authorization

- **Client "auth" is a demo stub, not real authentication.** `AuthController.login` accepts hardcoded `user@gmail.com` / `12345`; `signup` always succeeds; the profile is stored locally in Hive. There are **no tokens, no sessions, no server verification**. See [features/authentication.md](features/authentication.md), [backend/auth.md](backend/auth.md).
- **Server "auth" is a single shared account.** paax-api's `/library/*`, `/rate`, `/playlists*` endpoints act on **one** YouTube Music account (`YTMUSIC_OAUTH_JSON`) and have **no authorization gate** — any caller can invoke them. The live app does not use these; treat them as admin/experimental and do not expose them publicly without adding auth.
- **Token Expiry / Refresh**: N/A (no user tokens). The YouTube OAuth is refreshed by `ytmusicapi` internally.
- **Authorization Model**: None. There is nothing to authorize because there is no user-owned server data.

### Roles & Permissions

| Role | Description | Permissions |
|------|-------------|-------------|
| `anonymous client` | Any app/browser hitting paax-api | Read metadata/search/lyrics; (currently also the unguarded write endpoints) |
| `local user` | Person using the app | Full control of their **on-device** Hive data only |
| `operator` | Maintainer with Railway/Cloudflare access | Deploy, set secrets, view logs |

There is no `admin` API role — operator power is infra-level, not application-level.

---

## Secrets Management

- **Never** commit secrets. `oauth.json` / `*oauth*.json` and `.env` are gitignored (root `.gitignore`).
- Server secrets (`YTMUSIC_OAUTH_JSON`, `REDIS_URL`) are set as **Railway variables**. `YTMUSIC_OAUTH_JSON` is materialized to a temp file at startup and unlinked on shutdown.
- The Cloudflare Worker holds **no secrets** (Innertube is called unauthenticated).
- No secrets are logged by any service.

```python
# ✅ pattern used
oauth = os.environ.get("YTMUSIC_OAUTH_JSON")
```

---

## Input Validation

- **paax-api** does **not** use a schema-validation library on its own endpoints (contrary to `.claude/rules/api.md`); params are read directly. Deezer/track ids are coerced with `int.parse`. This is a gap for a future rate-limited/public API.
- **paax-stream `/stream`** enforces a **host allowlist** (`*.googlevideo.com` / `.youtube.com` / `.ytimg.com` / `.ggpht.com`) to prevent open-proxy (SSRF) abuse, and validates the `Range` header.
- **Cloudflare Worker** validates the videoId with `^[a-zA-Z0-9_-]{11}$`.
- **Client**: search input is free-text passed to the metadata API; no injection surface (no SQL, no shell). Deezer/YouTube handle the query.

---

## OWASP Top 10 Mitigations

| Risk | Status | Notes |
|------|--------|-------|
| A01: Broken Access Control | ⚠️ | paax-api write endpoints (`/rate`, `/playlists*`) are **unauthenticated** — mitigated only by not advertising them; add auth before public exposure |
| A02: Cryptographic Failures | ⚠️ | HTTPS everywhere for client↔service, **but** the Deezer httpx client uses `verify=False` (TLS cert validation disabled) — MITM-exposed on metadata. Fix planned |
| A03: Injection | ✅ | No SQL/ORM/shell with user input anywhere; parameterized HTTP calls only |
| A04: Insecure Design | ⚠️ | Multiple streaming generations + shared account are design debt; documented in [decisions.md](decisions.md)/[architecture.md](architecture.md) |
| A05: Security Misconfiguration | ⚠️ | Android `usesCleartextTraffic=true`, release signed with debug keys, permissive CORS (`allow_credentials=True` + LAN regex) |
| A06: Vulnerable Components | ⚠️ | No automated dependency scanning (no Dependabot / `pip-audit` / `flutter pub audit` in CI) |
| A07: Identity/Auth Failures | N/A→⚠️ | No real auth exists yet; will apply once user auth is added |
| A08: Data Integrity Failures | ✅ | No signed webhooks/tokens to forge; no deserialization of untrusted server data |
| A09: Logging/Monitoring Failures | ⚠️ | Plain-text logs, no request IDs, no central log aggregation or alerting |
| A10: SSRF | ✅ (proxy) | paax-stream host allowlist mitigates; Worker validates videoId |

---

## Supabase security model (deployed; auth + profile + library consumed since Phase 3.1/3.2A)

Deployed 2026-07-16 ([decisions.md](decisions.md) ADR-009; full reference: [backend/database-schema.md](backend/database-schema.md)). **The app now consumes it directly** for auth/profile (Phase 3.1) and library sync + onboarding (Phase 3.2A) — paax-api still does not (unchanged). RLS is the enforcement boundary. The following controls are in force on the Supabase project (`jecgmiuypuathhvjuhea`):

- **RLS on all 34 tables** — no exceptions. User data uses own-row policies; catalog is public-read.
- **Service-role-only writes** for catalog, billing, notification creation, counters, and play qualification — clients cannot write any of these.
- **Clients can never self-promote**: `profiles.app_role` and subscription tier/status columns are trigger-guarded (`protect_profiles_privileged_columns`); the signup trigger never reads role/tier from client metadata.
- **`security definer` functions live in the non-exposed `private` schema** with pinned `search_path = ''` and input validation.
- **Deliberate, documented exceptions**: `public_profiles` is a definer view exposing only safe columns (id, username, display_name, avatar_url, is_private, created_at) — the Supabase advisor lint on definer views is acknowledged for this view; `billing_events` has RLS enabled with **zero policies** = service-role only by construction.
- **Storage own-folder policies**: `user-avatars` and `story-media` writes are constrained to the caller's `{user_id}/` prefix; `story-media` is private (backend-signed URLs only); public buckets serve by URL without listing. See [backend/storage.md](backend/storage.md).
- **No plaintext credentials anywhere**: the owner bootstrap (`scripts/bootstrap-owner.mjs`) is env-driven; nothing secret is committed.
- **`service_role` key is server/scripts-only** — it must never ship in Flutter or any client bundle.
- **⚠️ Manual Dashboard step required** (MCP cannot set it): Authentication → Sign In / Providers → Email → minimum password length **8**, required characters **"lowercase, uppercase, digits and symbols"** — matching the app-side regex `^(?=.*[a-z])(?=.*[A-Z])(?=.*\d)(?=.*[^A-Za-z0-9]).{8,}$`. See [backend/auth.md](backend/auth.md).

> Integration has begun: server-side PII (emails, profile fields) is now live under RLS. The "no PII on servers" statements in the older Threat Model / Data Privacy sections below are being superseded — treat the Supabase controls here and the Phase 3.2A section as authoritative.

### Phase 3.2A controls (onboarding, hidden tracks, library sync, avatars)

- **Onboarding RPC is a hardened boundary** — `public.complete_artist_onboarding(p_artist_ids uuid[])` is **SECURITY DEFINER** with `set search_path=''`, `EXECUTE` granted to `authenticated` only (revoked from `anon`/`public`). It requires `auth.uid()` (else `42501`), validates ≥5 unique **existing** artists (`<5` → `22023`; non-existent → `23503`), inserts idempotent follows, and is the **only** path allowed to flip `profiles.onboarding_completed` (excluded from the client `updateOwn` whitelist).
- **`user_hidden_tracks` own-row RLS** — `SELECT`/`INSERT`/`DELETE` scoped to `auth.uid()`; hiding excludes a track from automatic playback + future recommendation inputs without deleting the catalog track.
- **Multi-account local isolation** — on a real account switch the client clears the local library boxes + pending sync journal (`clear-on-switch`); a pre-existing library with no recorded owner is kept **local-only and never bulk-uploaded** (`unowned-not-uploaded`), preventing one account's data from leaking into another's cloud rows.
- **Avatar Storage is per-user** — `AvatarService` uploads only to `user-avatars/{auth.uid()}/…`, matching the own-folder Storage RLS policy; MIME + size validated client-side before upload.
- **Counters never client-written** — library sync writes only relation rows (`user_liked_tracks`/`user_saved_albums`/`user_followed_artists`/`user_hidden_tracks`); `platform_likes_count`/`platform_followers_count` are maintained solely by the `bump_*` triggers.
- **Idempotent, RLS-scoped CRUD** — inserts ignore Postgres `23505`; all writes are scoped to `auth.uid()`. paax-api was not modified, so no new server attack surface.

### Phase 3.2B controls (followed genres, personalized Home)

- **`user_followed_genres` own-row RLS** — `SELECT`/`INSERT`/`DELETE` scoped to `auth.uid()`, PK `(user_id, genre_id)`; the client **never writes** the `platform`-style counter — `private.bump_genre_followers` maintains it (same counters-are-trigger-only rule as artists). Genre follows ride the existing offline-first pipeline (idempotent inserts ignoring `23505`). **No migration** was needed (the genres tables pre-existed) and **paax-api was not modified**, so no new server attack surface.
- **Home reads only public catalog + the user's own relation rows** — `HomeRepository` queries the publicly-readable catalog tables (`genres`/`albums`/`artists`/`album_genres`), and the personalization inputs are the caller's own `user_followed_artists`/`user_followed_genres` rows under RLS. Nothing on Home reads another user's data.
- **Per-user Home cache prevents cross-account content bleed** — `HomeController`'s offline `SharedPreferences` cache is keyed per user, and `onUserSession(uid)` resets in-memory sections on account switch, so a persistent Home tab never shows a previous user's personalized content.

---

## Data Privacy

- **PII stored on servers**: **None.** No accounts, no emails on the backend. The only "profile" (`name`, `email`) is stored **locally on-device** in Hive and never transmitted.
- **Data retention**: On-device only; destroyed on uninstall or `logout()` (`HiveStorage.clearAll()`).
- **Encryption at rest**: Hive boxes are **not** encrypted (Hive supports encryption but it is not enabled). Low risk given no server-side PII, but worth enabling if sensitive data is ever stored.
- **GDPR/CCPA**: Largely N/A today (no server data). A user can erase all their data by clearing app storage.
- **Never log PII** — currently honored (no PII exists server-side to log).

---

## Incident Response

1. Identify and isolate the affected service (pause the Railway deploy / disable the Worker route).
2. If the shared `YTMUSIC_OAUTH_JSON` account is implicated, **revoke and rotate** the OAuth credential immediately.
3. Rotate `REDIS_URL` credentials if Redis is implicated.
4. Assess impact — because there is no user PII on servers, blast radius is limited to service availability and the shared account.
5. Document in [KNOWN_ISSUES.md](KNOWN_ISSUES.md) and a post-mortem entry in [decisions.md](decisions.md) if design changes result.

---

## Known Vulnerabilities / Open Items

| Issue | Severity | Status | Notes |
|-------|----------|--------|-------|
| Deezer client `verify=False` (TLS off) | High | Open | `paax-api/services/deezer/deezer_client.py` |
| Unauthenticated write endpoints on shared account | High | Open | Add auth or remove from public routing |
| Release Android build signs with debug keys | High | Open | Blocks safe store release |
| `str(e)` leakage in 500 responses | Medium | Open | Wrap errors before returning |
| No rate limiting on paax-api | Medium | Open | Exposed to abuse/cost |
| `usesCleartextTraffic=true` in prod manifest | Medium | Open | Needed for dev; scope to debug |
| Hive not encrypted at rest | Low | Accepted (no server PII) | Enable if sensitive data added |
| No dependency scanning in CI | Medium | Open | Add `pub audit` / `pip-audit` |

Every item cross-references [TECH_DEBT.md](TECH_DEBT.md) and the backlog ([tasks/backlog.md](tasks/backlog.md)). Security rules the whole project follows live in [`.claude/rules/security.md`](../.claude/rules/security.md).

---

## Architecture Review Findings (2026-07-16)

The [Architecture Review](architecture-review.md) §7 catalogs the security posture with severities. Beyond the table above, it adds:

- **AR-SEC-06 — Permissive CORS with credentials** (`allow_credentials=True` + `*` methods/headers + broad LAN regex) — tighten and scope to dev.
- **AR-SEC-07 — Cleartext traffic in the production manifest** (`usesCleartextTraffic="true"`) — scope to debug.
- **AR-SEC-08 — Open stream resolvers** — the Cloudflare Worker returns `Access-Control-Allow-Origin: *` with no auth; `paax-stream` relies only on a host allowlist. Add token/referrer gating + rate limits.
- **AR-SEC-10 — No dependency/secret hygiene automation** — no `pub audit`/`pip-audit`/Dependabot, no rotation runbook.

The Critical items (Deezer `verify=False`, unauthenticated write endpoints, debug-key signing) are `AR-SEC-01/02/03`. Full detail: [architecture-review.md](architecture-review.md#7-security-risks).

---

## Phase 2 backend security posture

- **AR-SEC-01 resolved** — Deezer client TLS verification enabled (`verify=True`,
  certifi); no client disables TLS.
- **Service-role isolation** — the `SUPABASE_SERVICE_ROLE_KEY` is backend-only,
  read from env, never logged or returned. All catalog-write RPCs
  (`catalog_upsert_*`, `catalog_search`, `catalog_normalize`) are `service_role`
  only (EXECUTE revoked from `anon`/`authenticated`); PostgREST never exposes the
  `private` schema helpers.
- **Artwork fetch hardening** — download host allowlist (Deezer CDN) prevents
  arbitrary-URL/SSRF fetches; size cap + timeout; MIME + real-image validation;
  destination paths derived from the internal entity id (clients never choose
  them); service-role Storage writes scoped to the entity's own object.
- **Rate limiting** — Redis fixed-window limits on expensive endpoints
  (`resolve-playback` 30/min, `report-playback-failure` 20/min, `find` 60/min);
  degrades open if Redis is down.
- **Input validation** — external ids are typed (`int`/UUID path params), search
  query + pagination are clamped, `report-playback-failure` takes no client
  metadata. Frontend-supplied metadata is never treated as canonical catalog data.
- **Correlation IDs** — every request/log line carries an `X-Request-ID`; secrets,
  tokens, cookies, and full auth headers are never logged.

---

## Phase 3.4.1 — Cloud Playlist RLS & RPC model (2026-08-02)

**All playlist mutations go through transactional RPCs** (`public.playlist_*`),
never raw table writes. Each is `SECURITY DEFINER`, `SET search_path = ''`,
validates `auth.uid()` and the correct permission (`private.can_edit_playlist` /
`is_playlist_owner` / `can_view_playlist`) **before any privileged write**, is
version-aware where relevant, emits activity via a trusted function, and is
`GRANT EXECUTE ... TO authenticated` only (revoked from `public`/`anon`).

- **Never client-trusted for authorization**: `owner_id`, `last_modified_by`,
  `added_by`, `actor_id`, `version`, `follower_count`, `track_count`,
  `total_duration_seconds` — all set server-side by RPCs/triggers.
- **Owner-only**: manage collaborators, change visibility, transfer ownership,
  delete, disable collaboration, replace custom cover.
- **Accepted collaborators**: add/remove/reorder tracks (via
  `can_edit_playlist`).
- **Followers**: insert/delete only their own `user_followed_playlists` row.
- **Account-deletion succession** runs in a trusted `auth.users` AFTER DELETE
  trigger (`private.handle_owner_account_deletion`, revoked from `authenticated`),
  not dependent on the deleting client.
- **Activity** is insertable only through `private.log_playlist_activity` (no
  direct INSERT policy), so `actor_id` cannot be spoofed.

**Security advisor note**: the linter flags each `public.playlist_*` RPC as
"Signed-In Users Can Execute SECURITY DEFINER Function" (WARN). This is the
**intended** permission-checked RPC pattern (same as the pre-existing
`complete_artist_onboarding`/`username_available`); each RPC validates auth +
role internally. No RLS bypass is exposed. No new ERROR-level advisor was
introduced by this phase.

---

## Phase 3.4.1.1 — Notification integrity (2026-08-03)

Collaboration notifications are **server-authored only**. The `notifications`
table has SELECT/UPDATE/DELETE own-rows policies (`auth.uid() = user_id`) and
**no INSERT policy** — so with RLS enabled a client cannot create a notification
at all. Rows are written exclusively by `private.emit_playlist_notification`
(SECURITY DEFINER, `EXECUTE` revoked from `public`/`anon`/`authenticated`),
called inside the collaboration RPCs.

**Threats considered & closed** (verified in production with disposable users in
rolled-back transactions):

- **Forgery — direct INSERT** of a notification into a victim's inbox: blocked by
  RLS (no INSERT policy). *Confirmed: attempt fails.*
- **Forgery — calling the emitter directly** as `authenticated`: blocked by the
  `EXECUTE` revoke. *Confirmed: attempt fails.*
- **Forgery via invite**: only the playlist owner can invite
  (`playlist_invite_collaborator` → non-owner is `FORBIDDEN`), so an attacker
  cannot emit an invite notification to an arbitrary user.
- **Private data leakage**: the emitter payload is limited to playlist
  title/cover + actor username — never private track contents; recipients are
  only the counterpart of the action (invitee/owner/removed user/new owner).
- **Revoked-invite race**: removing a collaborator marks their pending invite
  notification `acted` (`revoke_invite_notification`); `playlist_respond_invitation`
  independently re-checks `status='pending'`, so a forged `acted_at=null` on the
  client's own row still cannot accept a revoked invite.
- **Cross-account leak**: realtime is filtered `user_id=eq.<uid>` and rebound on
  account switch; the controller also drops rows whose `user_id` ≠ the active uid.
- **Duplicate spam**: partial-unique dedupe index + `on conflict … do update`, so
  a re-invite refreshes one row instead of stacking.

The client's UPDATE policy allows a user to modify only their **own** rows (used
for mark-read); this cannot affect another user's inbox and cannot bypass any RPC
permission check (all authoritative decisions are re-validated server-side).

---

*Last updated: 2026-08-03*
