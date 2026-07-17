# Feature: Authentication

> **Purpose**: Documents the design, flows, and implementation of the authentication feature.
> **Update when**: Auth flows change, real auth is introduced, or security requirements evolve.

---

## Overview

> **Read this first: Paax has no real authentication.** What ships today is a **local demo/stub**, not a production auth system. There is no identity provider, no server-side account, no password verification, no token, and no session in any security sense. The "login" gate exists to make the app feel complete and to hold a locally-stored display name — nothing more.

Because Paax stores **all** user state on-device in Hive and its backends are stateless metadata/stream proxies (see [architecture](../architecture.md)), there is simply no server to authenticate *against* for the end user *in the live app*. This is a deliberate current-state limitation, documented honestly per [`docs/security.md`](../security.md) and [backend auth](../backend/auth.md). As of 2026-07-16 a **server-side identity foundation exists** (Supabase Auth, ADR-009 — see [the section below](#supabase-auth-foundation-deployed-not-integrated)), but the app is **not connected to it** — the demo stub remains the live behavior until Phase 3.

`AuthController` (`frontend/lib/presentation/state/auth_controller.dart` — a `ChangeNotifier`) owns the whole flow: `UserProfile? currentUser`, `isAuthenticated`, and `onboardingCompleted`. The onboarding + auth gate lives **above** the app shell in `main.dart` via `Consumer<AuthController>`.

---

## Supported Auth Methods

- [x] Email + Password — **stubbed.** `login` accepts exactly one hard-coded credential pair; `signup` always succeeds without validation.
- [ ] Magic Link / Passwordless — not supported
- [ ] Google OAuth — not supported
- [ ] Apple Sign-In — not supported
- [ ] Phone / SMS OTP — not supported
- [ ] Guest / Anonymous — no explicit guest mode; the demo login effectively is one

> Separately, the **server** has a single shared YouTube Music OAuth account (`YTMUSIC_OAUTH_JSON`) used only by paax-api's v1 authenticated ytmusicapi library/playlist endpoints. It is **not** per-user and is unrelated to app login. See [backend auth](../backend/auth.md) and [environment](../environment.md).

---

## User Flows

### Onboarding gate

On first launch, `main.dart` shows a 3-page onboarding `PageView` (`onboarding_screen.dart`). Completing it sets `onboarding_completed` in the Hive `settings` box. The gate order is: **onboarding → auth → app shell**.

### Registration Flow (stub)

1. User opens the signup form (`auth_screen.dart`).
2. User enters any name/email/password.
3. `AuthController.signup` **always succeeds** — no validation, no uniqueness check, no server call.
4. A `UserProfile` is written to the Hive `user_profile` box and `isAuthenticated` flips true; the app shell mounts.

### Login Flow (stub)

1. User enters credentials on the login form.
2. `AuthController.login` checks them against the **hard-coded demo pair** `user@gmail.com` / `12345`.
3. On match: a `UserProfile(name: "Uziel")` is saved to Hive and `isAuthenticated` becomes true.
4. On mismatch: an invalid-credentials error is shown; no lockout, no rate limit (there is no server to protect).

### Password Reset Flow

**Not implemented.** There is no password store and no email delivery. A forgotten password is meaningless here — any user can log in with the demo pair or sign up fresh.

### Token Refresh Flow

**Not applicable.** No tokens are issued, so there is nothing to refresh. Authentication "persists" only because the `UserProfile` remains in Hive across restarts.

---

## Session Management

| Aspect | Reality |
|--------|---------|
| Access Token Lifetime | None — no tokens exist |
| Refresh Token Lifetime | None |
| Refresh Rotation | Not applicable |
| Session persistence | The `UserProfile` in the Hive `user_profile` box (single object at key 0: `name`, `email`, `minutesListened`). Presence of a profile = "logged in". |
| **Logout Behavior** | `logout` calls `HiveStorage.clearAll()` — a **full local wipe**. This clears not just the profile but the entire library (liked/playlists/albums/artists), recently played, recent searches, and settings. There is no server session to revoke. |

> The logout-wipes-everything behavior is worth flagging as a UX sharp edge: on this stub there is no cloud backup, so logging out is effectively "reset the app". See [profile](profile.md), which also exposes a "clear data" action.

---

## Screen Inventory

Navigation is manual (`Navigator`) — there are no named routes/deep links for auth (see [routing](../frontend/routing.md)).

| Screen | Route | Description |
|--------|-------|-------------|
| Onboarding | (gate in `main.dart`) | 3-page intro `PageView`; sets `onboarding_completed` |
| Login / Signup | (gate in `main.dart`) | Combined auth form (`auth_screen.dart`); demo creds pre-implied |
| Forgot Password | — | Not implemented |

---

## Edge Cases & Error States

| Error | User Message | Behavior |
|-------|-------------|----------|
| Invalid credentials | "Email or password incorrect" (login) | Form error; user retries. No lockout / no rate limit (no server). |
| Account not verified | — | Not applicable — there is no verification step |
| Session expired | — | Cannot happen — the local profile never expires |
| Signup "failure" | — | Cannot happen — `signup` always succeeds |

---

## Supabase Auth foundation (deployed, not integrated)

> **Status**: server-side foundation **deployed 2026-07-16** (ADR-009, Phase 1). The Flutter app does **not** use any of this yet — everything above this section remains the live behavior. Flutter integration is **Phase 3** (see [`../tasks/backlog.md`](../tasks/backlog.md) TASK-B20).

- **Real accounts are now possible server-side**: Supabase Auth is deployed as the single identity authority, with a `profiles` table 1:1 with `auth.users` (see [`../backend/database-schema.md`](../backend/database-schema.md)).
- **Profiles auto-create on signup**: a `security definer` trigger (`private.handle_new_user()`) creates the profile row — using the metadata username only if valid and free, otherwise deriving a safe `user_<id>`; it never fails signup and never reads role/tier from metadata.
- **Password policy** (min 8 chars, upper + lower + digit + special; regex `^(?=.*[a-z])(?=.*[A-Z])(?=.*\d)(?=.*[^A-Za-z0-9]).{8,}$`) must be enforced in **both** places: the Flutter auth forms (Phase 3) **and** the Supabase Dashboard (a **manual step** — not migration-configurable; tracked as backlog TASK-B19).
- **Roles**: `app_role` ∈ `user`/`moderator`/`admin`/`owner` on `profiles`. Roles and subscription tier are **privileged, trigger-guarded columns** — clients can never self-promote or self-assign paid tiers.
- **Not in scope yet**: no Flutter sign-in, no token flow in the app, no Hive migration — the demo stub stays live until Phase 3.

---

## Security Notes (must-read)

- This is a **stub, not security**. Do not treat the login screen as an access control boundary. Anyone with the device (or the demo credentials) is "authenticated".
- Real auth is a prerequisite for any per-user server state. The server identity store **now exists** (Supabase Auth foundation, ADR-009 — see the section above), but it is **not wired into the app**; per-request token validation and client integration are Phase 3. See [`.claude/rules/security.md`](../../.claude/rules/security.md) and [`.claude/rules/supabase.md`](../../.claude/rules/supabase.md).
- Related backend caveat: paax-api's v1 write endpoints (`/rate`, `/playlists*`) have **no per-user auth** and mutate the single shared server account — another reason those endpoints are not exposed as user features. See [api](../api.md) and [security](../security.md).

---

## Related Files

- Controller: `frontend/lib/presentation/state/auth_controller.dart` — see [state-management](../frontend/state-management.md)
- Screens: `frontend/lib/presentation/screens/onboarding_screen.dart`, `frontend/lib/presentation/screens/auth_screen.dart`
- Gate: `frontend/lib/main.dart` (`Consumer<AuthController>`)
- Local store: `frontend/lib/data/local/hive_storage.dart` (`user_profile` box, `clearAll`) — see [database](../database.md)
- Cross-references: [security](../security.md), [backend auth](../backend/auth.md), [profile](profile.md)

---

*Last updated: 2026-07-16*
