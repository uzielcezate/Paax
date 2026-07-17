# Feature: Albums

> **Purpose**: Documents the album feature — browsing, viewing, and interacting with albums.
> **Update when**: Album display, metadata fields, or interaction model changes.

---

## Overview

An album in Paax is a **Deezer catalog album**, surfaced through paax-api's `/v2/album/{id}` endpoint (`getAlbumV2`). Album cards appear across Home, Search, and Artist pages; tapping one opens `album_detail_screen.dart`. Albums carry catalog metadata only — unlike tracks, album/artist cards are **not** given a YouTube match at the card level (there is nothing to play until you tap an individual track). Playback resolution happens lazily when a track is played. See [the v2 pipeline in architecture](../architecture.md) and [api](../api.md).

Users can **save** an album to their library. Saved albums persist locally in Hive as `SavedAlbum` objects — there is no server-side "saved" state (see [library](library.md) and [database](../database.md)).

---

## Album Data Model

Fields come from Deezer via `deezer_mapper` (album type normalized to album/single/ep). The runtime album detail carries the full track list; the persisted `SavedAlbum` deliberately keeps only a lightweight subset.

| Field | Source | Display |
|-------|--------|---------|
| Title | Deezer `/v2/album/{id}` | Large heading in the header |
| Artist(s) | Deezer (`artist`, `artists[]`) | Sub-heading under title; tappable → [artist](artists.md) |
| Cover Art | Deezer `cover_xl`→`cover_big`→… | Blurred, scaled backdrop **and** sharp foreground artwork |
| Release date / year | Deezer | Metadata row (runtime only — not persisted on `SavedAlbum`) |
| Track Count | Deezer `nb_tracks` | Metadata row |
| Duration | Sum of track durations | Metadata row |
| Release type | Deezer `record_type` / `nb_tracks` (1=single, ≤6=ep, else album) | Label/badge |
| Label | Deezer | Metadata (runtime only) |

### `SavedAlbum` entity — persisted vs runtime

`SavedAlbum` (Hive typeId 2, box `saved_albums`, keyed by `albumId`) is intentionally slim so the library stays cheap to store and render:

- **Persisted**: `albumId`, `title`, `artistName`, `artworkUrl`, `artistId?`.
- **NOT persisted** (runtime-only, re-fetched on open): `releaseDate`, `label`, `duration`, `trackCount`, `tracks`, `releaseType`, `artists`.

So a saved album in the library shows just enough to render a card; opening it re-fetches the full detail from `/v2/album/{id}`. This is a conscious trade-off — persisting full track lists for every saved album would bloat Hive for data that is cheap to re-fetch and cache server-side (album responses are cached 24h — see [cache](../backend/cache.md)).

> Note: `SingleTrackAlbumDetail` is a separate plain (non-Hive) helper class used when a track has no real album context; its `fromTrack` hardcodes `releaseYear 2024`.

---

## Screens

### Album Detail Screen

`frontend/lib/presentation/screens/album_detail_screen.dart`.

**Layout / sections**:
1. **Blurred-artwork header** — the cover art is rendered blurred and scaled as a backdrop with a dark scrim, with the sharp cover, title, artist, and metadata over it. This is the app's "liquid glass" look, which is actually a static blurred image plus solid dark chrome, **not** a live `BackdropFilter` (blur is globally disabled — see [theming](../frontend/theming.md)).
2. **Track list** — `track_list_tile`s. The currently-playing track is bolded/bordered; swipe actions add to playlist/queue.
3. Action row (play/shuffle/save).

**Enrich-from-playback**: The album's tracks are Deezer metadata. Their YouTube `videoId` (the actual playback key, `Track.id`) is resolved on demand — when a track is played, the repository enriches it from the playback match rather than eagerly matching every track on the album (which would be slow and rate-limited). This keeps album open latency low.

**Actions available**:
- [x] Play album
- [x] Shuffle
- [x] Save to library (`toggleSaveAlbum`)
- [x] Add to playlist (per-track, via overflow/swipe)
- [x] Share (`share_plus` via `overflow_menu`)
- [ ] Download — a download button is present in the UI but is **non-functional**; see [downloads](downloads.md) / [offline](offline.md)

### Save / Unsave

`LibraryController.toggleSaveAlbum` flips membership in the `saved_albums` Hive box (writes a slim `SavedAlbum`, or removes it), then notifies listeners. The save button reflects state reactively. Saved albums appear in the Library → Albums tab.

---

## Navigation

- **From**: Home rails, Search results, [Artist](artists.md) discography/latest, and the Library → Albums tab.
- **To**: [Artist](artists.md) page (tap artist), [Player](player.md) (tap/play a track), Add-to-playlist sheet.

---

## States

See the [UI states rule](../../.claude/rules/ui.md).

| State | Description | UI |
|-------|-------------|-----|
| Loading | Fetching `/v2/album/{id}` | Skeleton header + shimmer track rows |
| Loaded | Album data available | Full detail view |
| Empty | N/A — a valid album id always has tracks | (Not applicable) |
| Error | Fetch failed (network/API/404) | `ErrorStateWidget` with retry |
| Offline | No connectivity | Presents as Error; a *saved* album can still render its slim cached fields, but the track list requires the network |

---

## Related Files

- Screen: `frontend/lib/presentation/screens/album_detail_screen.dart`
- Entity: `SavedAlbum` in `frontend/lib/data/local/hive_storage.dart` (and `frontend/lib/domain/entities/`)
- Repository: `frontend/lib/data/repositories/music_repository_impl.dart` → `getAlbumV2` in `youtube_music_data_source.dart`
- Controller: `frontend/lib/presentation/state/library_controller.dart` (`toggleSaveAlbum`) — see [state-management](../frontend/state-management.md)
- API: `GET /v2/album/{id}` — see [api](../api.md)
- Related features: [artists](artists.md), [library](library.md), [player](player.md), [playlist](playlist.md), [downloads](downloads.md)

---

*Last updated: 2026-07-16*
