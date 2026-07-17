# Feature: Library

> **Purpose**: Documents the user library — the collection of saved/liked content a user builds over time.
> **Update when**: Library sections, sorting, or persistence behavior changes.

---

## Overview

`LibraryScreen` (`frontend/lib/presentation/screens/library_screen.dart`), backed by `LibraryController` (`frontend/lib/presentation/state/library_controller.dart`), is the third tab of the app shell. It is the user's personal collection: liked tracks, created playlists, saved albums, and followed artists.

The defining architectural fact: **the library lives entirely on-device in Hive.** There is no server database, no account, and no sync — Hive *is* the "database" for Paax (see [architecture](../architecture.md) and [database](../database.md)). Every CRUD action in `LibraryController` writes to a Hive box and then calls `notifyListeners()` so the `Consumer`/`Selector` widgets rebuild. This is why the library survives app restarts but does not follow the user across devices.

---

## Library Sections

The screen is organized as **4 tabs** (`LibraryChipTabs`). Each tab reads a dedicated Hive box via `LibraryController`.

| Section | Description | User Action to Add | Hive box (typeId) |
|---------|-------------|--------------------|-------------------|
| Liked | Individual tracks the user hearted | Tap the heart on a track (tile, player, or overflow menu) | `liked_tracks` — `Box<Track>` (typeId 0) |
| Playlists | User-created playlists (there are no server/imported playlists) | **Create** FAB, or "Add to playlist" from a track's overflow menu | `playlists` — `Box<Playlist>` (typeId 1) |
| Albums | Albums saved to the library | Tap save/unsave on an album page (`toggleSaveAlbum`) | `saved_albums` — `Box<SavedAlbum>` (typeId 2) |
| Artists | Followed artists | Tap follow on an artist page (`toggleFollowArtist`) | `followed_artists` — `Box<Artist>` (typeId 4) |

Related per-item detail screens: [playlist](playlist.md), [albums](albums.md), [artists](artists.md).

### Pinned playlists

The Playlists tab supports **pinning**, capped at **5** pinned playlists. Pins are stored in the untyped `settings` box under `pinned_playlist_map` (`Map<playlistId, millisTimestamp>`). Pinned playlists sort to the top of the list (most-recently-pinned ordering); attempting to pin a 6th is rejected by the controller. This is the library's lightweight "favorites within favorites" affordance.

---

## Sorting & Filtering

Each tab has its **own** search field and sort control (`SearchSortHeader`) — filtering/sorting is scoped to the active tab and applied client-side over the in-memory Hive collection (fast, no network).

| Option | Applies To | Values |
|--------|-----------|--------|
| In-tab search | All 4 tabs | Free-text filter over the tab's items (e.g. track title, playlist name, album/artist name) |
| Sort | All 4 tabs | Recent / A–Z (and creator/date variants where meaningful) via `SortBottomSheet` |
| Pinned-first | Playlists tab | Pinned playlists (cap 5) always float above unpinned, independent of the chosen sort |

---

## Persistence Behavior

The template's "Sync Behavior" heading does not map to reality — there is nothing to sync to. This section documents persistence instead.

- **Real-time sync**: **Not applicable** — no server, no Supabase Realtime, no WebSocket. All state is local.
- **Persistence**: Every mutation persists synchronously to Hive and then notifies listeners. Playlists are full Hive objects (`Box<Playlist>`) storing their `List<Track>` inline.
- **Cross-device**: **None.** Because state is device-local, uninstalling the app or calling `HiveStorage.clearAll()` (which is what **logout** does — see [authentication](authentication.md)) wipes the library.
- **Conflict resolution**: **Not applicable** — single writer (the device), so there are no conflicts.
- **Migrations**: `HiveStorage.init()` runs one-time dedup migrations on the `liked_tracks` and `recently_played` boxes (keep the richest `artists` list, re-key by track id). See [database](../database.md).

### Cloud future (prepared, not connected)

As of 2026-07-16 the server-side counterparts to this library **exist but are unused** (Supabase Phase 1, ADR-009): `user_liked_tracks`, `user_saved_albums`, `user_followed_artists`, `user_followed_genres`, and `user_listening_history` are deployed with own-row RLS and trigger-derived public counters (see [`../backend/database-schema.md`](../backend/database-schema.md)). **Hive remains the live store** — nothing in the app reads or writes these tables until the Phase-3 migration ([`../tasks/backlog.md`](../tasks/backlog.md) TASK-B21).

---

## States

See the [UI states rule](../../.claude/rules/ui.md). Because data is local, "loading" and "error" are effectively instantaneous/absent for the collection itself.

| State | Description | UI |
|-------|-------------|-----|
| Empty | A tab has no saved items | Empty-state message + CTA (e.g. "Liked songs will appear here" / a create prompt on Playlists) |
| Loaded | Items available | Filtered, sorted list; Playlists shows pinned-first |
| Loading | Initial Hive read | Effectively instant (local box read); no spinner needed in practice |
| Error | N/A for local data | Only artwork can fail (image 429/offline) — handled per-tile by `AppImage`'s placeholder, not a screen-level error |

---

## Related Files

- Screen: `frontend/lib/presentation/screens/library_screen.dart`
- Playlist detail: `frontend/lib/presentation/screens/playlist_detail_screen.dart`
- Controller: `frontend/lib/presentation/state/library_controller.dart` — see [state-management](../frontend/state-management.md)
- Local store: `frontend/lib/data/local/hive_storage.dart` — see [database](../database.md), [storage](../backend/storage.md)
- Headers/widgets: `library_headers.dart` (`LibraryChipTabs`, `SearchSortHeader`), `add_to_playlist_sheet.dart`, `sort_bottom_sheet.dart` — see [widgets](../frontend/widgets.md)
- Related features: [playlist](playlist.md), [albums](albums.md), [artists](artists.md), [profile](profile.md)

---

*Last updated: 2026-07-16*
