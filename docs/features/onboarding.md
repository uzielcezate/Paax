# Feature: Artist Onboarding

> **Purpose**: Documents the post-signup artist-selection onboarding (Phase 3.2A) — the step a newly verified user completes before reaching Home.
> **Update when**: The onboarding flow, minimum-selection rule, RPC contract, or its data sources change.

---

## Overview

Artist onboarding is the mandatory step between a completed profile and the Home shell. As of **Phase 3.2A (2026-07-17, branch `feat/phase-3.2a-onboarding-profile-library`)** it is a **real feature** — the previous placeholder (`onboarding_placeholder_screen.dart`) has been **deleted** and replaced by `ArtistOnboardingScreen` (`frontend/lib/presentation/screens/onboarding/`).

The user picks a **minimum of 5 artists** to follow. On completion, those follows are written to the Supabase catalog via an RPC and `profiles.onboarding_completed` is flipped, advancing routing to Home.

Routing: `AuthController` resolves `AppAuthState.onboarding` for a verified user with a complete profile who has **not** yet onboarded; `AuthGate` maps that state to `ArtistOnboardingScreen`, wrapped in a `ChangeNotifierProvider<OnboardingController>`. See [authentication](authentication.md) for the full state machine.

---

## Data Sources

The screen combines two catalog sources, both reading real Supabase catalog UUIDs:

| Source | Origin | Notes |
|--------|--------|-------|
| **Popular artists** | The readable Supabase `artists` table — **top 30 by `platform_followers_count`** | Real catalog UUIDs; shown as the default grid before the user searches. |
| **Search** | paax-api `GET /v2/find?type=artists` (Supabase-first, Deezer-ingest on miss) | Debounced **350 ms** with stale-request cancellation + de-duplication. |

### Lazy UUID resolution (search hits)

A freshly-discovered artist returned by search (Deezer-ingested, not yet in the catalog with a stable id) has a **null Supabase id**. On selection it is **lazily resolved** via `GET /v2/artists/deezer/{deezerId}`, so only **real catalog UUIDs** are ever submitted to the completion RPC. An artist that cannot be resolved to a catalog UUID cannot be submitted.

---

## Selection & Persistence

- **Minimum 5 selections** required to complete. The complete action is disabled until the threshold is met.
- The in-progress selection is **persisted locally** in `SharedPreferences` under key `paax_onboarding_selection_v1`, so an app restart mid-onboarding **restores** the pending selection.
- The persisted selection is **cleared on logout**.

---

## Completion

1. The controller calls the Supabase RPC **`complete_artist_onboarding(p_artist_ids uuid[])`** with the resolved catalog UUIDs.
2. On success, `AuthController.bootstrap()` re-resolves the auth/profile state; `AuthGate` advances to **Home**.

### RPC contract — `complete_artist_onboarding(p_artist_ids uuid[])`

`SECURITY DEFINER`, `set search_path = ''`. See [backend/database-schema.md](../backend/database-schema.md) and [backend/auth.md](../backend/auth.md).

| Condition | Result |
|-----------|--------|
| No `auth.uid()` (unauthenticated) | Raises `42501` |
| Fewer than 5 **unique existing** artists (input is de-duplicated first) | Raises `22023` |
| Any id not present in `artists` | Raises `23503` |
| Valid | Idempotent follows (`ON CONFLICT DO NOTHING` on `user_followed_artists`), flips `profiles.onboarding_completed` **atomically**, returns `jsonb { onboarding_completed, followed_count }` |

`EXECUTE` is granted to `authenticated` only (revoked from `anon`/`public`). Follows written here bump `artists.platform_followers_count` via the existing `bump_*` triggers — the RPC never writes the counter directly. The onboarding follows are ordinary `user_followed_artists` rows, so onboarded artists appear in the [Library](library.md) → Artists tab.

---

## Bypass Prevention

- The screen uses `PopScope(canPop: false)` to block accidental back-navigation out of onboarding.
- **Log out still works** from the onboarding screen (the only sanctioned exit); logout clears the pending selection.

---

## States

| State | UI |
|-------|-----|
| Loading | Popular artists loading from the `artists` table |
| Loaded | Popular grid / search results; selection chips |
| Searching | Debounced query in flight (stale results cancelled) |
| Below minimum | Complete disabled until 5 selected |
| Submitting | RPC in flight |
| Error | Search/RPC failure surfaced with retry; validation rejections mapped to a friendly message |

---

## Related Files

- Screen/controller: `frontend/lib/presentation/screens/onboarding/` (`ArtistOnboardingScreen`, `OnboardingController`)
- Gate: `frontend/lib/presentation/screens/auth/auth_gate.dart` (maps `AppAuthState.onboarding`)
- Auth: `frontend/lib/presentation/state/auth_controller.dart` (`bootstrap()`)
- API: `GET /v2/find?type=artists`, `GET /v2/artists/deezer/{deezerId}` — see [api](../api.md)
- RPC: `complete_artist_onboarding` — see [backend/database-schema.md](../backend/database-schema.md)
- Migration: `supabase/migrations/20260717160000_phase3_2a_onboarding_and_hidden_tracks.sql`
- Related features: [authentication](authentication.md), [artists](artists.md), [library](library.md), [profile](profile.md)

---

*Last updated: 2026-07-17*
