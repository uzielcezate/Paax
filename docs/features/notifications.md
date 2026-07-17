# Feature: Notifications

> **Purpose**: Documents the notification system — push notifications, in-app notifications, and user preferences.
> **Update when**: Notification types, delivery mechanism, or preference options change.

---

## Overview

"Notifications" in Paax means two very different things, and only one of them exists:

1. **The OS media notification** — the now-playing card with transport controls that Android shows while audio is playing. This **is implemented** (Android), and it is a core part of the playback experience rather than a "messaging" feature.
2. **Push notifications** (new releases, recommendations, social pings, etc.) — **not implemented in the app**. There is no FCM/APNs integration, no device-token registration, and no notification inbox anywhere in the Flutter codebase. As of 2026-07-16 a **server foundation is deployed but unused** (Supabase Phase 1, ADR-009): `user_devices` (with protected push tokens) and a `notifications` inbox table exist server-side — see [below](#planned--if-push-is-added).

The rest of this doc keeps those two senses strictly separate so nobody assumes Paax can push messages to users. It cannot — the deployed tables have no delivery pipeline and no client.

---

## Notification Channels

| Channel | Platform | Description |
|---------|----------|-------------|
| Media notification | Android | Foreground-service media control card driven by `audio_service` / `PaaxAudioHandler`. **Implemented.** |
| Media session (web) | Web | Web Media Session hooks exist historically but `media_session_web.dart` is currently **commented out**. |
| Push (FCM) | Android | **Not implemented** — no Firebase, no FCM in the dependency set (see [tech stack](../tech-stack.md)). |
| Push (APNs) | iOS | **Not implemented** — there is no iOS build target in scope (Android + Web/PWA/TWA only; see [architecture](../architecture.md)). |
| In-App inbox | — | **Not implemented** — no notification bell/inbox. |
| Email | — | **Not implemented** — no email service. |

---

## Media Notification (implemented)

This is the real notification feature. It exists to serve playback, and its implementation is the same foreground-service mechanism that keeps background audio alive (see [player](player.md#background-playback)).

- **Mechanism**: `core/playback/paax_audio_handler.dart` — `PaaxAudioHandler extends BaseAudioHandler` (from the `audio_service` package). It runs an Android **foreground service** (`foregroundServiceType=mediaPlayback`) and publishes the **OS media session**: current title/artist/artwork, play/pause state, and position.
- **Important nuance**: The handler **does not play audio** — the YouTube IFrame in the hidden WebView does. The handler proxies: it shows the notification, and forwards notification/lock-screen button presses (play, pause, next, previous) **back to `PlaybackController`**, which drives the IFrame engine. The foreground service's second job is to stop Android from killing the process (and thus the WebView) while backgrounded.
- **Android manifest wiring**: permissions `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MEDIA_PLAYBACK`, `WAKE_LOCK`; declares `com.ryanheise.audioservice.AudioService` (with a `MediaBrowserService` intent filter) and `MediaButtonReceiver`. See [architecture](../architecture.md).
- **Controls shown**: play/pause, next, previous, and a seek/scrub position — mirroring the in-app transport.

There are **no** user preferences for this notification (it is not a "message" the user opts into — it simply reflects active playback). There is no way to disable it while a track is loaded, by design.

---

## Notification Types (push)

**Not applicable — no push system exists.** The template's catalog of push types is retained only to state clearly that none of them are sent:

| Type | Status |
|------|--------|
| `new_release` (followed artist releases) | Not implemented. |
| `playlist_update` (collaborative playlist) | Not implemented — playlists are local-only, non-collaborative (see [playlist](playlist.md)). |
| `new_follower` | Not implemented — there is no social graph (see [profile](profile.md)). |
| `recommendation` (weekly) | Not implemented — there is no recommender pipeline (see [recommendations](recommendations.md)). |
| `system` (announcements) | Not implemented. |

---

## Notification Payload

**Not applicable — no push payloads.** There is no FCM/APNs payload schema because nothing is sent. The media notification's "payload" is simply the current track's metadata (`MediaItem`) supplied to the media session by `PaaxAudioHandler`; it is not a network message.

---

## Deep Linking

The app does have deep-link handling for the **PWA/TWA** entry (service worker, `assetlinks.json`, viewport-fit — see [release notes](../release-notes.md)), and navigation is handled by the custom shell (`MainWrapper`, no `go_router`; see [navigation](../frontend/navigation.md)). But there is **no notification-tap deep linking**, because there are no tappable push notifications. Tapping the **media** notification simply brings the app to the foreground (and the player is already the active context).

| Notification Type | Deep Link Target |
|------------------|-----------------|
| Media notification tap | Foregrounds the app (player context). |
| `new_release` / `new_follower` / `recommendation` | N/A — not sent. |

---

## Permission Handling

- **Media notification**: On Android 13+ the app needs the runtime `POST_NOTIFICATIONS` permission for the foreground-service notification to be visible. The media notification itself is not something the user "subscribes" to; it appears with playback.
- **Push permission request timing**: N/A — no push system, so no push-permission prompt is ever shown. (This actually aligns with the [ux rule](../../.claude/rules/ux.md) to delay non-essential permission requests: Paax never asks for push at all.)

---

## User Preferences

**No notification preferences UI exists.** The [settings](settings.md) screen is a stub, and there are no per-type toggles because there are no push types. The media notification has no toggle by design (it reflects playback state).

- Managed in: nowhere (not implemented).
- Preferences stored: none.

---

## Planned / If Push Is Added

**Server foundation: deployed 2026-07-16, not connected** (Supabase Phase 1, ADR-009 — see [`../backend/database-schema.md`](../backend/database-schema.md)):

- `user_devices` — device registry with **push tokens kept private** (own-row RLS); ready to hold FCM tokens.
- `notifications` — an inbox table that is **backend-created only** (no client INSERT policy); users can read, mark-read, and delete their own rows (a trigger allows clients to change only `read_at`).
- User identity and *who follows which artist* are also now modeled server-side (`profiles`, `user_followed_artists`).

**Still missing (Phase 2/3+)**: any delivery pipeline (no FCM/APNs integration, nothing writes to these tables), token registration from the app, notification-tap handling, and a preferences UI in a real settings screen. Until those exist, Paax still cannot push anything to anyone.

---

## Related Files

- Media notification / foreground-service handler: `frontend/lib/core/playback/paax_audio_handler.dart`
- Playback controller (receives forwarded controls): `frontend/lib/presentation/state/playback_controller.dart`
- Android manifest (service + permissions): `frontend/android/app/src/main/AndroidManifest.xml`
- Web media session (commented out): `frontend/lib/core/playback/media_session_web.dart`
- Push service: None (not implemented).
- Notifications screen: None (not implemented).

**See also:** [player](player.md) · [settings](settings.md) · [recommendations](recommendations.md) · [profile](profile.md) · [architecture](../architecture.md)

---

*Last updated: 2026-07-16*
