# Feature: Profile

> **Purpose**: Documents the user profile feature — public profile display, editing, and social context.
> **Update when**: Profile fields, avatar logic, or public visibility rules change.

---

## Overview

The profile is a **single-user, non-social** screen (`presentation/screens/profile_screen.dart`). It shows who is signed in, a few listening stats derived on the fly from Hive data, a recently-played rail, and account/data actions. There is **no social layer** in Paax — no other users, no followers, no public profiles, no profile URLs — because there are no other users to relate to yet; social surfaces remain future work.

> **Identity is now server-backed (Phase 3.1, 2026-07-17)**: as of the real Supabase auth landing (see [authentication](authentication.md)), the signed-in identity is the RLS-protected **`public.profiles` row** (1:1 with `auth.users`, auto-created by the `on_auth_user_created` trigger), surfaced in the app through `ProfileController` / `AuthController` (see [`../frontend/state-management.md`](../frontend/state-management.md)) rather than a local demo stub. The `profiles` row also carries username, avatar URL, a privacy flag, and a trigger-guarded role/subscription-tier cache, plus a safe `public_profiles` projection for future social surfaces (see [`../backend/database-schema.md`](../backend/database-schema.md)). The music **library** still lives on-device in Hive; cloud library sync is Phase 3.2+.

Profile is the fourth tab in the [main shell](../frontend/navigation.md).

---

## Profile Data Model

The authoritative identity is now the server-side **`public.profiles`** row (RLS-protected, 1:1 with `auth.users`; see [authentication](authentication.md)), mirrored client-side by the `Profile` entity and surfaced via `ProfileController`/`AuthController`. A residual Hive `UserProfile` type still backs on-device stats (`typeId: 3`, box `user_profile`, single record at key `0`; persists `name`, `email`, `minutesListened`). The rest of the screen is either derived at render time or does not exist.

| Field | Editable by User | Visible to Others | Description |
|-------|-----------------|-------------------|-------------|
| Display Name | Via account settings | N/A (no "others") | `display_name` on the `profiles` row (set during registration); writable columns are whitelisted client-side. |
| Username / Handle | On registration | — | `username` on the `profiles` row (unique, validated); no public profile URLs yet. |
| Avatar / Profile Photo | No | N/A | No uploaded photo; the UI renders an initials/placeholder avatar (see [Avatar Management](#avatar-management)). The `profiles` row has an `avatar_url` column, currently unused by upload. |
| Bio | — | — | Not implemented. |
| Email | No (from Supabase Auth) | Private | The authenticated email from `auth.users`. |
| Follower / Following Count | — | — | Not implemented (no social graph). |
| Joined Date | — | — | `created_at` on the `profiles` row (not surfaced in the UI). |
| Premium / PRO | — | — | A **cosmetic** "PRO" pill only — see [Premium PRO pill](#premium-pro-pill). The trigger-guarded `subscription_tier` cache is not wired to it. |

### Stats (derived, not stored)

The profile header shows summary stats computed at render time from Hive, not stored on `UserProfile`:

- **Liked count** — number of tracks in the `liked_tracks` box (via `LibraryController`).
- **Playlists count** — number of `Playlist` objects in the `playlists` box.
- **Minutes listened** — summed from the durations of tracks in the `recently_played` box. (The `UserProfile.minutesListened` field exists as a persisted accumulator, but the visible "minutes" stat is fundamentally driven by recently-played durations.)

---

## Profile Screens

### Own Profile Screen

`profile_screen.dart` shows:

- Avatar + display name + email.
- The three derived stats (liked / playlists / minutes).
- A **recently played** horizontal rail sourced from the `recently_played` Hive box (most-recent-first). Tapping an item plays it / opens its context.
- Account/data actions: **Clear data** and **Logout**.
- A **Settings** menu entry that is currently a **no-op** (see [settings](settings.md)).

### Other User's Profile Screen

**Not applicable — not implemented.** There are no other users to view. Follow/unfollow, shared activity, and public playlists do not exist. (Following *artists* is a separate feature and lives in the [library](library.md) Artists tab, not on a user profile.)

---

## Edit Profile Flow

**No general in-app "Edit Profile" form yet.** Identity fields (`username`, `display_name`, birth date, country) are collected during the registration wizard — or the Complete-Profile fallback — and written to the RLS-safe columns of the `profiles` row (see [authentication](authentication.md)). There is not yet a post-signup edit screen; the template's edit flow is still aspirational:

1. Intended: user opens an edit screen from their profile.
2. Intended: fields pre-filled from the current `Profile`.
3. Intended: validate and save the whitelisted columns back to `public.profiles` via `ProfileRepository`.

---

## Avatar Management

- **Upload**: Not supported — there is no gallery/camera picker.
- **Accepted formats / Max size / Processing**: N/A (no upload path, so nothing to validate or resize).
- **Default avatar**: An initials/placeholder avatar rendered from the display name. This is the only avatar state.

---

## Premium / PRO pill

The profile displays a **"PRO" pill**. It is **purely cosmetic** — there is no subscription system, no entitlement check, no paywalled feature, and no billing integration anywhere in the app. Do not treat it as a feature flag; it gates nothing.

---

## Account & Data Actions

| Action | Behavior |
|--------|----------|
| Logout | Calls `AuthController.logout()`, which signs out of Supabase (`signOut()`) and clears in-memory auth state, then returns the user to the auth gate. **It no longer wipes the local Hive library** — the on-device library, playlists, liked, and recently-played are preserved across a sign-out. See [authentication → Logout](authentication.md). |
| Clear data | The separate, explicitly destructive action that wipes local Hive data (and then signs out). Given the ux [confirmation rules](../../.claude/rules/ux.md), it should be confirmed before wiping. |

Password recovery is handled server-side via Supabase (see [authentication → Password recovery](authentication.md)). An in-app account-deletion flow is not yet implemented.

---

## Privacy Controls

**Not applicable — not implemented.** Profile/activity visibility settings assume other users can see you; nobody can yet. Identity lives in the RLS-protected `profiles` row (readable only by its owner); listening data (library, stats) stays on-device in Hive. See [security](../security.md).

| Setting | Options | Default |
|---------|---------|---------|
| Profile Visibility | N/A (device-local only) | — |
| Activity Visibility | N/A | — |

---

## Related Files

- Screen: `frontend/lib/presentation/screens/profile_screen.dart`
- Auth/profile controllers: `frontend/lib/presentation/state/auth_controller.dart` (+ `ProfileController`)
- Profile repository/entity: `frontend/lib/data/repositories/profile_repository.dart`, `frontend/lib/domain/entities/profile.dart`
- Library stats source: `frontend/lib/presentation/state/library_controller.dart`
- Residual `UserProfile` (on-device stats): Hive `typeId: 3` (see `frontend/lib/data/local/hive_storage.dart`)

**See also:** [authentication](authentication.md) · [settings](settings.md) · [library](library.md) · [playlist](playlist.md) · [database](../database.md)

---

*Last updated: 2026-07-17*
