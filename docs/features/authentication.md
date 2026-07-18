# Feature: Authentication

> **Purpose**: Documents the design, flows, and implementation of the authentication feature.
> **Update when**: Auth flows change, security requirements evolve, or a new provider is added.

---

## Overview

> **Paax now has real authentication.** As of **Phase 3.1** (branch `feat/paax-branding-auth`) the Flutter app is wired to **Supabase Auth** as the single identity authority. The previous local demo/stub (hard-coded `user@gmail.com` / `12345`) is **gone**. Real accounts, email verification, password recovery, and an RLS-protected `profiles` row are live.

The client uses **only the public anon key** (`lib/core/config/supabase_config.dart`). The `service_role` key never ships in the app — all privileged operations stay in `paax-api`, and every table is protected by Row Level Security. Auth uses the **PKCE** flow (`AuthFlowType.pkce`), initialized once in `main.dart`.

`AuthController` (`frontend/lib/presentation/state/auth_controller.dart`, a `ChangeNotifier`) is the single source of truth for routing. It exposes a deterministic `AppAuthState` that `AuthGate` maps to exactly one screen — no imperative `Navigator` juggling for the core flow.

---

## Architecture

| Layer | File | Responsibility |
|-------|------|----------------|
| Config | `core/config/supabase_config.dart` | Public URL + anon key (compile-time overridable via `--dart-define`); deep-link redirect constants |
| Repository | `data/repositories/auth_repository.dart` | Thin, injectable wrapper over Supabase Auth (sign up/in/out, resend, reset, update password, refresh) |
| Repository | `data/repositories/profile_repository.dart` | RLS-safe reads/writes of `public.profiles`; **whitelists** non-privileged columns; `username_available` RPC |
| Local store | `data/local/pending_registration.dart` | Versioned, **non-sensitive** pending-registration payload in `SharedPreferences` (7-day TTL) |
| Entity | `domain/entities/profile.dart` | Mirrors the `profiles` row; `isComplete`, `greetingName`, read-only privileged fields |
| Errors | `core/auth/auth_errors.dart` | `AuthFailure` + `AuthErrorMapper` — friendly messages, no raw payloads, no account enumeration |
| Validators | `core/auth/validators.dart` | Pure email/password/username/DOB/country validators mirroring the server policy |
| State | `presentation/state/auth_controller.dart` | Session restore, auth-event subscription, routing state machine, all actions |
| Router | `presentation/screens/auth/auth_gate.dart` | `Selector<AuthController, AppAuthState>` → one destination |
| Screens | `presentation/screens/auth/*.dart` (+ `screens/onboarding/`) | Welcome, Login, Register (3-step), Verify Email, Forgot/Reset Password, Complete Profile; artist onboarding is `ArtistOnboardingScreen` (see [onboarding](onboarding.md)) |

### Routing state machine

`AppAuthState` ∈ `initializing`, `unauthenticated`, `unverified`, `profileLoading`, `completeProfile`, `onboarding` (**real artist onboarding as of Phase 3.2A** — see [onboarding](onboarding.md)), `ready`, `recovery`.

```
initializing ──▶ unauthenticated ──▶ (register/login)
                     ▲                     │
                     │              unverified ──(email confirmed)──▶ profileLoading
                  (logout)                                                │
                                          completeProfile ◀──(incomplete/lost pending)──┤
                                                 │                                       │
                                              onboarding ◀──(profile complete, !onboarded)┤
                                                 │                                       │
                                                ready ◀──────────(complete + onboarded)──┘

recovery  ◀── AuthChangeEvent.passwordRecovery (paax://auth/reset-password deep link)
```

---

## Supported Auth Methods

- [x] Email + Password — **real** (Supabase Auth, PKCE, email confirmation required)
- [ ] Magic Link / Passwordless — not yet
- [ ] Google OAuth — not yet
- [ ] Apple Sign-In — not yet
- [ ] Phone / SMS OTP — not yet
- [ ] Guest / Anonymous — not offered

> Separately, the **server** has a single shared YouTube Music OAuth account (`YTMUSIC_OAUTH_JSON`) used only by paax-api's v1 ytmusicapi endpoints. It is unrelated to app login. See [backend auth](../backend/auth.md).

---

## User Flows

### Registration (3-step wizard)

`register_screen.dart` — **Account** (email, password + live strength checklist, confirm) → **Identity** (given/family name, username with debounced availability check, DOB, gender) → **Location** (country, state/region, optional city). The Supabase account is created **only** on the final step.

1. `AuthController.register` normalizes email/username, builds `display_name`, and calls `signUp(email, password, data: {username, display_name})` with `emailRedirectTo = paax://auth/confirm`.
2. A **`PendingRegistration`** (non-sensitive profile fields only — never the password or tokens) is saved locally so the full profile can be applied after verification.
3. State resolves to **`unverified`** → `VerifyEmailScreen`.

### Email verification

- Supabase sends a confirmation email with the `paax://auth/confirm` deep link. `supabase_flutter` captures the link and completes the PKCE exchange automatically.
- `VerifyEmailScreen` offers **Resend** (45-second cooldown) and **"I already verified"** (`refreshVerificationStatus` → refreshes the session and re-resolves).
- On the first **verified** session, `_maybeApplyPending` writes the stored `PendingRegistration` to the profile — **only if it matches the authenticated email** — then clears it (only after a confirmed DB write).

### Login

1. `signInWithPassword(email, password)`.
2. If Supabase reports **email not confirmed**, the controller routes to `unverified` (so the user can resend) and surfaces a friendly message.
3. Otherwise → `profileLoading` → `completeProfile` / `onboarding` / `ready` based on the profile.

### Password recovery

1. `ForgotPasswordScreen` → `sendPasswordReset(email)` → `resetPasswordForEmail(email, redirectTo: paax://auth/reset-password)`. The outcome is **neutral** — success is shown regardless of whether the address exists (no account enumeration); only rate-limit/network errors surface.
2. Opening the emailed link fires `AuthChangeEvent.passwordRecovery` → state `recovery` → `ResetPasswordScreen`.
3. `updatePassword(newPassword)` → `updateUser(password:)`. The recovery session persists, so the user is routed straight into the app.

### Complete profile (fallback)

If a verified user has no complete profile (pending payload lost/expired, or a prior write failed), `CompleteProfileScreen` collects the required fields and writes **RLS-safe columns only**. Required for completeness: `username`, `display_name`, `birth_date`, `country_code` (see `Profile.isComplete`).

### Logout

`AuthController.logout` calls `signOut()` and clears in-memory auth state. **It no longer wipes the local Hive library** (the old stub did a full `clearAll`). It clears the in-progress onboarding selection (`paax_onboarding_selection_v1`). The email-scoped `PendingRegistration` is intentionally retained so a genuine re-login with the same email can still finish onboarding; a different account can never receive it (email match enforced).

---

## Session Management

| Aspect | Reality |
|--------|---------|
| Provider | Supabase Auth (GoTrue), PKCE flow |
| Access token | Short-lived JWT; **refreshed automatically** by `supabase_flutter` |
| Refresh token | Managed + rotated by the SDK; persisted in the platform secure store |
| Session persistence | The SDK restores the session on launch; `AuthGate` shows a splash during `initializing`/`profileLoading` so the Login screen never flashes for a signed-in user |
| Logout | `signOut()` revokes the session server-side; local auth state cleared. Hive library is preserved |

---

## Profiles & Authorization (server)

- `public.profiles` is **1:1 with `auth.users`**. The `on_auth_user_created` trigger (`private.handle_new_user()`) creates the row on signup, deriving the username from signup metadata when it is valid and free, otherwise a safe `user_<id>`. It never fails signup and never reads role/tier from metadata.
- **RLS**: users may `SELECT`/`INSERT`/`UPDATE` only their own row (`auth.uid() = id`). The anon role sees nothing.
- **Privileged columns** (`id`, `app_role`, `subscription_tier`, `subscription_status`, `subscription_expires_at`, `created_at`) are guarded by the `protect_profiles_privileged_columns` BEFORE UPDATE trigger, which **raises `42501`** if a client (`anon`/`authenticated`) tries to change them. The client also whitelists writable columns (`ProfileRepository.writableFields`) as defense-in-depth.
- `onboarding_completed` is server-managed and never set by the Complete-Profile path or client `updateOwn` — it is flipped **only** by the `complete_artist_onboarding` RPC (Phase 3.2A; see [onboarding](onboarding.md)).

See [database](../database.md), [backend/database-schema.md](../backend/database-schema.md), and [`.claude/rules/supabase.md`](../../.claude/rules/supabase.md).

---

## Deep Links

| Platform | Config | Value |
|----------|--------|-------|
| Android | `AndroidManifest.xml` intent-filter | `scheme="paax" host="auth"` (`paax://auth/*`) |
| iOS | `Info.plist` `CFBundleURLSchemes` | `paax` |
| Redirects | Supabase Dashboard → URL Configuration | `paax://auth/confirm`, `paax://auth/reset-password` (must be allow-listed) |

Both redirect URLs use the `auth` host, so the scoped Android intent-filter (not a broad catch-all) matches both. `supabase_flutter` + `app_links` handle the incoming links in Dart.

---

## Password & Username Policy

Enforced in **both** the client (`AuthValidators`) and Supabase:

- **Password**: ≥ 8 chars, with uppercase, lowercase, digit, and special character. The Supabase Dashboard policy must match (a manual step; configured for this project).
- **Username**: `^[a-z0-9_.]{3,30}$`, cannot start/end with `.`/`_`, no repeated separators; case-insensitive uniqueness via the `username_available` RPC + a DB uniqueness constraint (Postgrest `23505` → "That username is taken").

---

## Edge Cases & Error States

| Error | Kind | User Message |
|-------|------|--------------|
| Wrong email/password | `invalidCredentials` | "Incorrect email or password" |
| Unverified email at login | `emailNotConfirmed` | "Please verify your email to continue" (+ routes to Verify screen) |
| Email already registered | `emailAlreadyRegistered` | "This email is already registered" |
| Reused current password (`same_password` / "should be different from the old password") | `samePassword` | "Your new password must be different from your current password." — matched **before** the generic weak-password branch (Phase 3.1 fix, 2026-07-17; regression test added) |
| Weak password (server) | `weakPassword` | "Password must be 8+ chars with upper, lower, number and symbol" |
| Username taken (`23505`) | `usernameTaken` | "That username is taken" |
| Too many attempts (`429`) | `rateLimited` | "Too many attempts. Please try again in a moment" |
| Expired/used link | `expiredLink` | "This link has expired or was already used" |
| No connection | `network` | "No internet connection" |
| Server 5xx | `unavailable` | "Service temporarily unavailable. Try again later" |

Raw provider payloads are never surfaced. Password reset is neutral (no enumeration).

---

## Verification (Phase 3.1)

Auth was verified live against the Supabase project (ref `jecgmiuypuathhvjuhea`).

- **Committed live integration test** — `frontend/test/live/auth_live_test.dart` (run: `flutter test test/live/auth_live_test.dart`). Uses the public anon key only, sends **no email** (so it is repeatable and never trips the email rate limit), and asserts the anon-facing contract: `username_available` RPC reachable, anon cannot read `profiles` (RLS), weak password rejected before account creation, unknown credentials fail closed. **4/4 pass.**
- **Account-lifecycle verification** — against a disposable account (no email side effects): the `on_auth_user_created` trigger creates a `profiles` row with the derived username and `user`/`free`/`inactive` defaults; `username_available` flips to `false` for the taken handle; as the `authenticated` role a user can read/update only their own row; and a privilege-escalation UPDATE (`app_role='owner'`) is **rejected with `42501`**. Disposable artifacts were deleted afterward (0 leftover).
- **`flutter analyze`** — no errors; the auth files are lint-clean.
- **Email link click-through** and **live SMTP delivery** are covered by manual QA (they require a real inbox and cannot run headless).

---

## Security Notes

- The client holds **only** the anon key; RLS is the enforcement boundary. Never embed the `service_role` key.
- Clients cannot self-promote role or self-assign a paid tier (trigger-guarded + client whitelist).
- Password reset and (where possible) login errors avoid account enumeration.
- Related backend caveat: paax-api's v1 write endpoints (`/rate`, `/playlists*`) still have **no per-user auth** and mutate the shared server account — they are not exposed as user features. See [api](../api.md), [security](../security.md).

---

## Related Files

- Controller: `frontend/lib/presentation/state/auth_controller.dart`
- Repositories: `frontend/lib/data/repositories/{auth,profile}_repository.dart`
- Config: `frontend/lib/core/config/supabase_config.dart`
- Screens: `frontend/lib/presentation/screens/auth/*.dart`
- Gate: `frontend/lib/presentation/screens/auth/auth_gate.dart` (mounted from `main.dart`)
- Local store: `frontend/lib/data/local/pending_registration.dart`
- Live test: `frontend/test/live/auth_live_test.dart`
- Cross-references: [security](../security.md), [backend auth](../backend/auth.md), [profile](profile.md), [decisions.md](../decisions.md) (ADR-009)

---

*Last updated: 2026-07-17*
