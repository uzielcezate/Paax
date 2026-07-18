# Feature: Profile

> **Purpose**: Documents the user profile feature — public profile display, editing, and social context.
> **Update when**: Profile fields, avatar logic, or public visibility rules change.

---

## Overview

The profile is a **single-user, non-social** screen (`presentation/screens/profile_screen.dart`). It shows who is signed in (from the real Supabase `profiles` row), live library stats, a recently-played rail, and account/data actions. There is **no social layer** in Paax — no other users, no followers, no public profiles, no profile URLs — because there are no other users to relate to yet; social surfaces remain future work.

> **Real profile rendering (Phase 3.2A, 2026-07-17)**: `profile_screen` renders the real Supabase **`public.profiles`** row via `AuthController.profile` (1:1 with `auth.users`, auto-created by the `on_auth_user_created` trigger; see [authentication](authentication.md)) — display name, `@username`, email (from `auth.currentUser`), city/state/country, the **real `subscription_tier`** (the hardcoded PRO pill is gone), and joined date (`auth.currentUser.createdAt`). It also shows **live stats from `LibraryController`** (liked / playlists / followed artists / saved albums). While `profile == null` it shows a **skeleton** (no "Unknown User" placeholder). New in 3.2A: `EditProfileScreen`, `ProfileController`, and `AvatarService` (real avatar upload). See [`../frontend/state-management.md`](../frontend/state-management.md), [`../backend/database-schema.md`](../backend/database-schema.md).

Profile is the fourth tab in the [main shell](../frontend/navigation.md).

---

## Profile Data Model

The authoritative identity is now the server-side **`public.profiles`** row (RLS-protected, 1:1 with `auth.users`; see [authentication](authentication.md)), mirrored client-side by the `Profile` entity and surfaced via `ProfileController`/`AuthController`. A residual Hive `UserProfile` type still backs on-device stats (`typeId: 3`, box `user_profile`, single record at key `0`; persists `name`, `email`, `minutesListened`). The rest of the screen is either derived at render time or does not exist.

| Field | Editable by User | Visible to Others | Description |
|-------|-----------------|-------------------|-------------|
| Display Name | Yes (Edit Profile) | N/A (no "others") | `display_name` on the `profiles` row; writable columns are whitelisted client-side. |
| Username / Handle | Yes (Edit Profile, debounced availability) | — | `username` on the `profiles` row (unique, validated); no public profile URLs yet. |
| Avatar / Profile Photo | Yes (upload) | N/A | Real upload via `AvatarService` to the `user-avatars` Storage bucket; initials fallback when none (see [Avatar Management](#avatar-management)). Persisted as `avatar_url` on the `profiles` row. |
| Bio | — | — | Not implemented. |
| Email | No (from Supabase Auth) | Private | The authenticated email from `auth.currentUser`. |
| Follower / Following Count | — | — | Not implemented (no social graph). |
| Joined Date | No | — | Derived from `auth.currentUser.createdAt`; surfaced in the header. |
| Subscription tier | No (server-managed) | — | The **real** `subscription_tier` from the `profiles` row is displayed. The old hardcoded "PRO" pill is **removed**. |

### Stats (live from the library)

The profile header shows summary stats computed at render time from `LibraryController` (the offline-first Hive cache):

- **Liked count** — number of tracks in the `liked_tracks` box.
- **Playlists count** — number of `Playlist` objects in the `playlists` box.
- **Followed artists** — number in the `followed_artists` box.
- **Saved albums** — number in the `saved_albums` box.

A residual Hive `UserProfile.minutesListened` accumulator still exists (typeId 3) but the header stats are the four library counts above.

---

## Profile Screens

### Own Profile Screen

`profile_screen.dart` shows:

- Avatar (real upload or initials fallback) + display name + `@username` + email + city/state/country + subscription tier + joined date.
- The four live library stats (liked / playlists / followed artists / saved albums).
- A **recently played** horizontal rail sourced from the `recently_played` Hive box (most-recent-first). Tapping an item plays it / opens its context.
- An **Edit Profile** entry → `EditProfileScreen`.
- Account/data actions: **Clear data** and **Logout**.
- A **Settings** menu entry that is currently a **no-op** (see [settings](settings.md)).

While `profile == null` the screen renders a **skeleton** (never a "Unknown User" fallback).

### Other User's Profile Screen

**Not applicable — not implemented.** There are no other users to view. Follow/unfollow, shared activity, and public playlists do not exist. (Following *artists* is a separate feature and lives in the [library](library.md) Artists tab, not on a user profile.)

---

## Edit Profile Flow

`EditProfileScreen` (Phase 3.2A) edits **only whitelisted, non-privileged fields** via `ProfileRepository.updateOwn`:

`first_name`, `last_name`, `display_name`, `username`, `birth_date`, `gender_identity`, `country_code`, `state_region`, `city`, `avatar_url`.

**Excluded** (never writable by the client): `app_role`, `subscription_*`, `onboarding_completed`, and the trigger-maintained counters. Username edits run a **debounced availability** check. A new **`ProfileController`** orchestrates the update plus avatar handling (provided inline via Provider; no `main.dart` change was required).

---

## Avatar Management

`AvatarService` (`frontend/lib/core/media/avatar_service.dart`) implements the full upload path:

1. **Pick** — `image_picker` (gallery/camera).
2. **Validate** — MIME allow-list (`jpg`/`png`/`webp`) + size ≤ 8 MB.
3. **Process** — decode + resize to a **512px square**, JPEG **q85** (`package:image`).
4. **Upload** — to the Storage bucket **`user-avatars`** at path `{auth.uid()}/avatar_{ts}.jpg` (matches the per-user Storage RLS policy).
5. **Persist** — set `profiles.avatar_url`.
6. **Cleanup** — best-effort delete of the user's old avatars.

- **Default avatar**: An initials fallback rendered from the display name when no avatar is set.

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

- Screens: `frontend/lib/presentation/screens/profile_screen.dart`, `frontend/lib/presentation/screens/edit_profile_screen.dart`
- Auth/profile controllers: `frontend/lib/presentation/state/auth_controller.dart` (+ `ProfileController`)
- Profile repository/entity: `frontend/lib/data/repositories/profile_repository.dart` (`updateOwn`), `frontend/lib/domain/entities/profile.dart`
- Avatar: `frontend/lib/core/media/avatar_service.dart` → Storage bucket `user-avatars`
- Library stats source: `frontend/lib/presentation/state/library_controller.dart`
- Home greeting uses `profile.firstName` (fallback `greetingName`, never empty) — see [home](home.md)
- Residual `UserProfile` (on-device stats): Hive `typeId: 3` (see `frontend/lib/data/local/hive_storage.dart`)

**See also:** [authentication](authentication.md) · [onboarding](onboarding.md) · [settings](settings.md) · [library](library.md) · [playlist](playlist.md) · [database](../database.md)

---

*Last updated: 2026-07-17*
