# Feature: Notifications

> **Purpose**: Documents the notification system — push notifications, in-app notifications, and user preferences.
> **Update when**: Notification types, delivery mechanism, or preference options change.

---

## Overview

"Notifications" in Paax means three different things:

1. **The OS media notification** — the now-playing card with transport controls that Android shows while audio is playing. This **is implemented** (Android), and it is a core part of the playback experience rather than a "messaging" feature.
2. **In-app notification inbox** — a **bell in the Home header + a Notifications screen** that surface **collaboration events** (invites, accepts/declines, removals/leaves, ownership transfers). **Implemented in Phase 3.4.1.1** on top of the existing `notifications` table — see [In-App Inbox](#in-app-inbox-implemented-phase-3411). This is **in-app realtime**, not device push: there is still no FCM/APNs and no device-token delivery pipeline.
3. **Push notifications** (device-delivered when the app is closed) — **still not implemented**. No FCM/APNs integration, no `user_devices` token delivery. See [below](#planned--if-push-is-added).

The rest of this doc keeps these senses separate so nobody assumes Paax can push messages to devices. It cannot yet — the inbox is delivered in-app via Supabase Realtime while the app is open.

---

## In-App Inbox (implemented, Phase 3.4.1.1)

The inbox is the client for playlist-collaboration events. It is **read-only from
the client's side**: rows are created **only** by trusted SECURITY DEFINER
collaboration RPCs (via `private.emit_playlist_notification`, revoked from all
client roles), inside the same transaction as the mutation. Clients can only
read/mark their own rows (RLS: `auth.uid() = user_id`; **no INSERT policy**).

- **Types**: `playlist_collaboration_invited`, `playlist_collaboration_accepted`,
  `playlist_collaboration_declined`, `playlist_collaborator_removed`,
  `playlist_collaborator_left`, `playlist_ownership_transferred`,
  `playlist_followed` (Phase 3.4.1.2). `playlist_unfollowed` copy exists in the
  emitter but is **not** emitted — unfollow is intentionally silent to avoid
  follow/unfollow spam (product decision, §3.4.1.2 A).
- **Follow (Phase 3.4.1.2)**: following a viewable playlist emits exactly one
  `playlist_followed` to the owner from inside `playlist_set_follow`. It is
  `FOUND`-gated (an idempotent repeat follow inserts no row → no re-notify),
  never self-notifies, and is deduped per (owner, follower, playlist) via the
  `pl_follow:<pid>:<uid>` key. Following never touches the playlist's
  `updated_at`/`last_modified_*` (not a content edit).
- **Avatars (Phase 3.4.1.2)**: the payload carries `actor_avatar`
  (`coalesce(avatar_url, avatar_original_url)`); the inbox renders it via the one
  canonical `ActorAvatar` widget (circular center-crop, error/placeholder
  fallback, initials for a known name, neutral glyph + "Deleted user" for a
  missing actor). The body keeps the actor's username snapshot, so a row stays
  readable after the actor is deleted — never a raw UUID.
- **Deep navigation (Phase 3.4.1.2)**: tapping a playlist notification marks it
  read, resolves the canonical playlist UUID, and opens Playlist Detail (back
  returns to the inbox). In-library targets open instantly; others are fetched
  under RLS. Deleted / private-inaccessible / blocked targets show "This playlist
  is no longer available." — never a crash, infinite spinner, or leaked metadata.
- **Table** (extended, additive): `notifications` gains `actor_user_id`,
  `entity_type`, `entity_id`, `acted_at`, `dedupe_key`, `deleted_at`, a
  partial-unique dedupe index on `(user_id, dedupe_key)`, and membership in the
  `supabase_realtime` publication. See [database](../database.md).
- **Delivery**: `NotificationRealtimeService` opens one channel filtered
  `user_id=eq.<uid>`, rebound on account switch (no cross-account leak).
  `NotificationController` holds the caller's rows, drives the unread badge, and
  handles insert/update/delete + mark-read + inline Accept/Decline (delegated to
  `playlist_respond_invitation`, which also marks the invite `acted`).
- **UI**: a **bell** immediately left of the Home profile button (live red badge,
  hidden at 0, caps at "99+", never blocks the tap → `notification_bell.dart`);
  the **Notifications screen** (`notifications_screen.dart`) groups Today/Earlier,
  shows unread distinctly with relative timestamps, supports pull-to-refresh and
  realtime, marks a row read on open, "Mark all as read", inline Accept/Decline
  on live invites, and a quiet "no longer available" line for revoked/expired
  ones. Loading/empty/error(offline) states all handled.
- **Not** device push, **not** in the bottom nav, and does not deep-link into the
  playlist on tap (tap = mark read) in this phase.

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
| `playlist_update` (collaborative playlist) | No **device push**. Collaboration events **are** delivered to the **in-app inbox** (Phase 3.4.1.1) — see [In-App Inbox](#in-app-inbox-implemented-phase-3411). |
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
