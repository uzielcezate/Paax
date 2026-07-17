# Feature: Settings

> **Purpose**: Documents the settings feature — all configurable preferences available to users.
> **Update when**: A new setting is added, a setting is removed, or the settings UI is restructured.

---

## Overview

There is **no real settings screen**. The "Settings" menu item on the [profile](profile.md) screen is currently a **no-op** — it does not navigate anywhere or open a preferences UI. The only user-configurable state that actually exists is a small set of implicit flags stored in the untyped Hive `settings` box, none of which is exposed through a dedicated settings UI. Everything else in the template below (audio quality, crossfade, equalizer, downloads, notification toggles, theme picker, language) is **not implemented**.

This is consistent with the app's scope: no server, no account preferences to sync, dark-only theming, and no downloads. Below, each template category is annotated with reality.

---

## What Actually Exists

The real "settings" are three keys in the untyped `settings` Hive box (see [database](../database.md) and [storage](../backend/storage.md)):

| Key | Type | Set by | Purpose |
|-----|------|--------|---------|
| `onboarding_completed` | bool | Onboarding flow (3-page intro) | Gates whether the intro `PageView` is shown on launch (checked above the shell in `main.dart`). |
| `hidden_track_ids` | `List<String>` | Track overflow → "Hide" | Track IDs the user has hidden; hidden tracks render dimmed / filtered in lists (see `track_list_tile`). |
| `pinned_playlist_map` | `Map<playlistId, epochMillis>` (max 5) | Playlist pin action | Ordering for pinned-first playlists in the Library (see [playlist](playlist.md)). |

None of these has a settings *screen*. They are side effects of onboarding and of contextual actions elsewhere in the app.

---

## Settings Categories

### Account

**Mostly not implemented.** The only account-related actions live on the [profile](profile.md) screen, not in a settings screen.

| Setting | Type | Description |
|---------|------|-------------|
| Edit Profile | — | Not implemented (no edit form; see [profile](profile.md)). |
| Change Password | — | Not implemented (auth is a local demo stub, no password store; see [authentication](authentication.md)). |
| Email Address | Display | Shown on the profile header (persisted `UserProfile.email`); not editable. |
| Logout / Clear data | Destructive action | On the profile screen. `logout` runs `HiveStorage.clearAll()`. |

### Playback

**Not applicable — not implemented.** Audio is delegated to the YouTube IFrame (see [player](player.md)); there is no audio-quality, crossfade, equalizer, or volume-normalization control.

| Setting | Status |
|---------|--------|
| Audio Quality / Crossfade / Equalizer / Normalize Volume | None exist. |

### Downloads

**Not applicable — not implemented.** There are no downloads at all (see [downloads](downloads.md) and [offline](offline.md)), so there is nothing to configure.

### Notifications

**Not applicable — no notification preferences.** The only notification surface is the Android media-playback notification, which is a byproduct of active playback and has no user-facing toggle (see [notifications](notifications.md)). There are no push notifications and therefore no per-type preference toggles.

### Appearance

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| Theme | — | Dark | The app is **dark-only**. `ThemeState` is *not* a light/dark toggle — it holds an ambient background/foreground color derived from album art (via `DominantColorService`) for contrast, not a user theme choice. There is no light theme to switch to. See [theming](../frontend/theming.md). |
| Language | — | Device | Not implemented — strings are hardcoded (no localization system is wired, despite the [ui rules](../../.claude/rules/ui.md) prescribing one). |

### Privacy

**Not applicable — not implemented.** No listening-history toggle and no private-session mode. Recently-played is always recorded locally; there is no server to send it to (see [security](../security.md)).

### About

**Not surfaced in-app.** There is no About screen. App version lives in `pubspec.yaml` (`beaty` v1.0.0+1) and the Android build (versionCode/Name from `local.properties`). Terms/Privacy/Licenses links are not implemented.

---

## Settings Persistence

- **Storage**: Local device only — the untyped Hive `settings` box (`data/local/hive_storage.dart`). No `SharedPreferences`; Hive is the app's single persistence layer (see [database](../database.md)).
- **Sync**: Local only. Nothing syncs to a server (there is no user account server; see [architecture](../architecture.md)).

---

## Gaps / Missing

To reach parity with the template, these would all be new work: a real settings screen wired to the profile menu item, a theme toggle (requires building a light theme), localization, and any playback/download/notification/privacy preferences (each of which depends on the corresponding feature existing first).

---

## Related Files

- Profile screen (hosts the no-op "Settings" item and account actions): `frontend/lib/presentation/screens/profile_screen.dart`
- Onboarding (sets `onboarding_completed`): `frontend/lib/presentation/screens/onboarding_screen.dart`
- Theme/ambient state: `frontend/lib/presentation/state/theme_state.dart`, `frontend/lib/core/theme/`
- Settings persistence: `frontend/lib/data/local/hive_storage.dart` (untyped `settings` box)

**See also:** [profile](profile.md) · [theming](../frontend/theming.md) · [notifications](notifications.md) · [downloads](downloads.md) · [database](../database.md)

---

*Last updated: 2026-07-16*
