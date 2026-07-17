# Feature: Offline Mode

> **Purpose**: Documents how the application behaves when there is no internet connection — what is available, what gracefully degrades, and what fails.
> **Update when**: Offline capabilities expand or change, or the offline strategy changes.

---

## Overview

**Offline mode is not implemented.** Paax has **no downloads, no offline playback, and no offline indicator.** Playback fundamentally requires a network connection because audio streams from YouTube through a WebView-hosted IFrame (see [player](player.md)) — there is no local audio file for any track.

What *does* survive without a network is **library metadata**, because all user state lives in the on-device Hive database rather than on a server (see [database](../database.md) and [architecture](../architecture.md)). So a user offline can still *see* their liked tracks, playlists, saved albums, and followed artists — they just cannot *play* anything. This is a meaningful but partial form of offline capability, and it is worth being precise about the boundary.

This doc is closely related to [downloads](downloads.md) (also not implemented).

---

## What Works Offline

| Feature | Available Offline | Notes |
|---------|------------------|-------|
| Play downloaded tracks | ❌ No | Nothing is ever downloaded; there is no local audio store. |
| Browse liked tracks / playlists / albums / artists | ✅ Yes (render only) | All persisted in Hive, so the [library](library.md) lists render from local data with no network. Playback still fails. |
| Recently played rail | ✅ Yes (render only) | Sourced from the `recently_played` Hive box. |
| Artwork | ⚠️ Partial | Only images already in the on-disk cache (mobile `CachedNetworkImage` / `flutter_cache_manager`, 30-day disk cache) show; uncached art falls back to the music-note placeholder. Web caches are memory-only, so web shows less offline. |
| Search | ❌ No | Search calls paax-api; offline it fails. There is no local search index. |
| Home feed | ❌ No | Charts/genres come from paax-api; no offline snapshot is persisted. |
| Like / Save / Create playlist | ✅ Yes | These are pure local Hive writes and work offline immediately — but there is nothing to "sync" later (see [Offline Queue](#offline-queue--pending-actions)). |

---

## Offline Detection

**Not implemented.** The app does not use `connectivity_plus` or any ping/reachability check (it is not in the dependency set — see [tech stack](../tech-stack.md)). There is:

- **Detection method**: None. The app does not know whether it is online.
- **Offline banner**: None. There is no "You're offline" indicator anywhere in the UI.
- **Reconnection behavior**: None — nothing is watching connectivity to react to it.

The practical consequence: offline, network-dependent screens surface generic error/empty states (via `error_state_widget`, which classifies error strings into an icon + retry) rather than a dedicated offline state.

---

## Offline Queue / Pending Actions

**Not applicable — not implemented.** There is no offline action queue because there is no server to sync to. Library mutations (like, add-to-playlist, create playlist, follow artist) are **local Hive writes that are immediately durable**; they are never "pending" and never uploaded. See [library](library.md) and [playlist](playlist.md).

| Action | Queued? | Sync Behavior |
|--------|---------|---------------|
| Like a track | No (not needed) | Written straight to Hive, offline or online. |
| Add to playlist | No | Written straight to Hive. |
| Create playlist | No | Written straight to Hive. |
| Follow artist | No | Written straight to Hive. |

---

## Cache Strategy

There is no *content* cache designed for offline use. The only durable local storage is Hive (user state) and the image disk cache; API responses are cached **server-side** (Redis + in-memory in paax-api, see [cache](../backend/cache.md)), which does not help an offline client.

| Content | Cache Duration | Cache Location |
|---------|---------------|----------------|
| Library / playlists / liked / recently-played | Until cleared by the user | Hive (device DB) — see [database](../database.md) |
| Album / artwork images | Mobile: 30 days on disk; Web: memory-only (session) | `flutter_cache_manager` via the image pipeline (`core/image`) |
| Home feed / search / API metadata | Not cached on the client for offline | Server-side Redis/in-memory only |
| Downloaded tracks | N/A | No download store exists |

---

## Error States While Offline

Because there is no offline detection, these are the *de facto* behaviors (driven by request failures), not designed offline states:

| Screen | Offline Behavior |
|--------|-----------------|
| Home | API calls fail → error/empty state with retry (`error_state_widget`); no cached feed. |
| Search | Query fails → error state; no local results. |
| Player | Track load fails (IFrame cannot reach YouTube); playback stalls. No downloaded fallback. |
| Library | ✅ Full local library renders from Hive; tapping to play fails at the player. |
| Profile | ✅ Renders (local data). |

Per the [ui state rules](../../.claude/rules/ui.md), a proper "Offline" state on network screens is currently a gap.

---

## Testing Offline

There is little to test today beyond confirming graceful failure and that Hive-backed screens still render:

```
# Android: Enable airplane mode (device or emulator extended controls).
#   Expect: Library/Profile/playlists still render from Hive; Home/Search/Player fail with error states.
# Web: DevTools → Network → Offline. Expect similar; artwork is memory-only so more placeholders.
# There is no connectivity mock to unit-test because no connectivity package is used.
```

---

## Planned Offline Architecture (not built)

If offline playback is pursued, it is a large piece of work because the current audio path (YouTube IFrame in a WebView) has no file to persist. A plausible shape:

1. Add a real download pipeline that resolves a track to a durable audio file (this needs one of the server-side stream resolvers — `paax-stream` or the Cloudflare Worker — to return a byte source; today those exist but are **not** on the live path; see [downloads](downloads.md) and [backend/workers](../backend/workers.md)).
2. Store downloaded audio in app storage with a Hive index (a `stream_candidates`/downloads box already exists as an unused placeholder).
3. Swap the engine to a local-file player (e.g. a real audio backend) when a downloaded copy exists, falling back to the IFrame when online-only.
4. Add `connectivity_plus`-based detection, an offline banner, and a "Downloads" library filter.

> **Prepared server-side (2026-07-16, not connected)**: download **sync-state** tables now exist in Supabase (Phase 1, ADR-009): `user_downloaded_tracks` / `user_downloaded_albums` / `user_downloaded_playlists`, holding metadata + per-device sync state only (`local_status`, `device_id`, `last_synced_at`) — **never audio bytes** (see [`../backend/database-schema.md`](../backend/database-schema.md)). They are groundwork for the future downloads feature; there is **no client implementation** and nothing writes to them yet.

Until then, treat Paax as **online-only for playback**.

---

## Related Files

- Connectivity service: None (not implemented).
- Offline queue: None (not implemented).
- Local (Hive) storage that enables offline rendering: `frontend/lib/data/local/hive_storage.dart`
- Image disk cache: `frontend/lib/core/image/` (`ImagePipeline`, `PlatformCacheManager`)
- Error state UI: `frontend/lib/presentation/widgets/error_state_widget.dart`

**See also:** [downloads](downloads.md) · [player](player.md) · [library](library.md) · [database](../database.md) · [backend/workers](../backend/workers.md)

---

*Last updated: 2026-07-16*
