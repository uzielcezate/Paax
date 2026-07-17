# Feature: Profile

> **Purpose**: Documents the user profile feature — public profile display, editing, and social context.
> **Update when**: Profile fields, avatar logic, or public visibility rules change.

---

## Overview

The profile is a **local, single-user, non-social** screen (`presentation/screens/profile_screen.dart`). It shows who is "signed in" (a locally stored `UserProfile`), a few listening stats derived on the fly from Hive data, a recently-played rail, and account/data actions. There is **no social layer** in Paax — no other users, no followers, no public profiles, no profile URLs — because the live app has no connected server-side user system (auth is a local demo stub; see [authentication](authentication.md) and [architecture](../architecture.md)).

> **Prepared, not connected (2026-07-16)**: a server-side `profiles` table now exists (Supabase Phase 1, ADR-009) with username, avatar URL, a privacy flag, and a trigger-guarded role/subscription-tier cache, plus a safe `public_profiles` projection for future social surfaces (see [`../backend/database-schema.md`](../backend/database-schema.md)). **The live app still uses only the local Hive `UserProfile`** described below; nothing reads or writes the server table until Phase 3.

Profile is the fourth tab in the [main shell](../frontend/navigation.md).

---

## Profile Data Model

The stored entity is the Hive `UserProfile` type (`typeId: 3`, box `user_profile`, a single record at key `0`). Only **three fields are persisted**: `name`, `email`, and `minutesListened` (a `double`). Everything else on the screen is either derived at render time or does not exist.

| Field | Editable by User | Visible to Others | Description |
|-------|-----------------|-------------------|-------------|
| Display Name | Effectively no | N/A (no "others") | Persisted `name`. Set at login (demo login hardcodes `"Uziel"`); no in-app edit form today. |
| Username / Handle | — | — | Not implemented — there are no handles or profile URLs. |
| Avatar / Profile Photo | No | N/A | No uploaded photo; the UI renders an initials/placeholder avatar (see [Avatar Management](#avatar-management)). |
| Bio | — | — | Not implemented. |
| Email | No (set at login) | Private (local only) | Persisted `email`. |
| Follower / Following Count | — | — | Not implemented (no social graph). |
| Joined Date | — | — | Not persisted. |
| Premium / PRO | — | — | A **cosmetic** "PRO" pill only — see [Premium PRO pill](#premium-pro-pill). |

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

**Not implemented as a form.** The profile is populated at login and there is no in-app "Edit Profile" screen that writes back `name`/`email`. The template's edit flow is aspirational:

1. Intended: user opens an edit screen from their profile.
2. Intended: fields pre-filled from the current `UserProfile`.
3. Intended: validate and save back to the `user_profile` box.

Today, changing identity effectively means logging out and back in (demo login sets `name: "Uziel"` for the hardcoded credentials — see [authentication](authentication.md)).

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
| Logout | Calls `AuthController.logout()`, which runs `HiveStorage.clearAll()` — this wipes **all** local state (library, playlists, liked, recently played, settings), then returns the user to the auth gate. Because there is no server, logout and "clear everything" are essentially the same operation. |
| Clear data | Clears local Hive data. Given the ux [confirmation rules](../../.claude/rules/ux.md), this destructive/irreversible action should be confirmed before wiping. |

There is **no** account-deletion server call and **no** change-password flow, because there is no account on any server.

---

## Privacy Controls

**Not applicable — not implemented.** Profile/activity visibility settings assume other users can see you; nobody can. All profile data is local to the device and never transmitted. See [security](../security.md).

| Setting | Options | Default |
|---------|---------|---------|
| Profile Visibility | N/A (device-local only) | — |
| Activity Visibility | N/A | — |

---

## Related Files

- Screen: `frontend/lib/presentation/screens/profile_screen.dart`
- Auth/profile controller: `frontend/lib/presentation/state/auth_controller.dart`
- Library stats source: `frontend/lib/presentation/state/library_controller.dart`
- `UserProfile` entity: Hive `typeId: 3` (see `frontend/lib/data/local/hive_storage.dart`)

**See also:** [authentication](authentication.md) · [settings](settings.md) · [library](library.md) · [playlist](playlist.md) · [database](../database.md)

---

*Last updated: 2026-07-16*
