# Feature: Downloads

> **Purpose**: Documents the offline download feature — its intended behavior and its current (unimplemented) status.
> **Update when**: A real download pipeline is built, or storage/DRM requirements change.

---

## Overview

> **Status: PLANNED / NOT IMPLEMENTED.** Downloads do not work today. A **download button appears in the album and playlist UI, but it is non-functional** — there is no download pipeline, no stream persistence, and no offline playback. This document describes the intended feature and what building it would require. Nothing here describes working behavior. See also [offline](offline.md).

The only download-related trace in the codebase is a Hive box named `stream_candidates`, **declared but unused** (it was reserved as a stream-URL cache and is not read or written by any live path — see [database](../database.md)). Tapping the download button does not enqueue anything, write any file, or change any state.

Why it doesn't exist yet is structural: Paax does not stream audio through a resolver in the live path at all — it plays a matched YouTube `videoId` **directly through a YouTube IFrame** (mobile: `flutter_inappwebview`; web: `youtube_player_iframe`). There is no local audio file, no `just_audio`, and no persistent stream URL to save. See [architecture](../architecture.md) and the [player](player.md) docs.

---

## Downloadable Content Types

None are downloadable today. The table below reflects the **intended** scope only.

- [ ] Individual Tracks — planned, not implemented
- [ ] Albums — download button present but non-functional
- [ ] Playlists — download button present but non-functional
- [ ] Podcasts / Episodes — out of scope (music-only product)

---

## Download Flow

**Not implemented.** The intended flow, if built, would be:

1. User taps the download button on an album or playlist.
2. App resolves a **durable audio stream URL** for each track's `videoId` (see requirements below), then fetches the audio bytes to a local file cache.
3. Progress is shown per item and in aggregate.
4. Downloaded tracks become playable offline via a **local-file playback engine** (which does not exist today — playback is IFrame-only).

Today, step 1 has no working implementation in the live app.

---

## Download States

**Aspirational only** — no state machine is wired. If implemented, the model would be:

| State | Description | Icon/UI |
|-------|-------------|---------|
| `not_downloaded` | Not on device | Download (down-arrow) icon — *this is the only state the current button visually implies, but it does nothing* |
| `queued` | Waiting to download | Clock/queued indicator |
| `downloading` | In progress | Progress ring with % |
| `downloaded` | Complete, available offline | Filled/checkmark icon |
| `error` | Download failed | Error icon + retry |
| `stale` | Underlying stream URL expired / content changed | Refresh icon |

---

## Storage Management

**Not applicable — nothing is stored.** A real implementation would need:

- A local file cache directory (via `path_provider`, already a dependency) for audio blobs.
- A persisted index (a real, read/written `stream_candidates`-style Hive box or a dedicated downloads box) mapping `videoId` → local file path + metadata + expiry.
- A "storage used" surface and per-item / bulk delete in [settings](settings.md).

---

## Download Restrictions

Not applicable while unimplemented. Design considerations for a future build:

- **Requires**: always-free would match the current no-subscription model.
- **DRM**: none applied today. Note the legal/licensing reality — Paax has no catalog license of its own and plays YouTube-matched content (see [architecture](../architecture.md)); persisting audio bytes raises licensing/ToS questions a real implementation must weigh.
- **Expiry**: YouTube CDN URLs are short-lived, so any cached stream URL would need re-resolution; persisted audio files would need their own retention policy.

---

## Background Download

**Not implemented.** A future build would reuse the existing Android foreground-service plumbing (`FOREGROUND_SERVICE` / `FOREGROUND_SERVICE_MEDIA_PLAYBACK`, already declared for playback — see [architecture](../architecture.md)) to run and notify background downloads.

---

## What building this would require

A realistic path to real downloads:

1. **Durable stream-URL resolution.** Reintroduce a resolver on the playback path — e.g. the deployed-but-unused `paax-stream` IPv6 byte-proxy (`resolver.paaxmusic.app`) or the Cloudflare Innertube Worker (`stream.paaxmusic.app`), both of which can produce a direct progressive audio CDN URL for a `videoId`. Today `ApiConfig.streamBaseUrl` and `MusicRepository.getStreamUrl` (`/stream/{videoId}`) are **defined but unused**. See [architecture](../architecture.md) and [api](../api.md).
2. **Local audio file cache.** Download bytes to app storage and index them (activate the dormant `stream_candidates` box or add a dedicated downloads box + Hive adapter — see [database](../database.md)).
3. **Offline-capable playback engine.** Add a local-file `PlaybackEngine` implementation (the current engine only drives a YouTube IFrame and cannot play local files), selected by the `playback_factory` when a track is available offline.
4. **UI/state.** A real download state machine in a controller, wired to the existing (currently inert) album/playlist download buttons, plus a Downloads surface.

---

## Related Files

- Screens (host the inert button): `frontend/lib/presentation/screens/album_detail_screen.dart`, `frontend/lib/presentation/screens/playlist_detail_screen.dart`
- Reserved store (unused): `stream_candidates` box in `frontend/lib/data/local/hive_storage.dart` — see [database](../database.md)
- Unused stream plumbing: `ApiConfig.streamBaseUrl`, `MusicRepository.getStreamUrl` — see [api](../api.md)
- Cross-references: [offline](offline.md), [player](player.md), [settings](settings.md), [architecture](../architecture.md)

---

*Last updated: 2026-07-16*
