# Feature: Library

> **Purpose**: Documents the user library — the collection of saved/liked content a user builds over time.
> **Update when**: Library sections, sorting, or persistence behavior changes.

---

## Overview

`LibraryScreen` (`frontend/lib/presentation/screens/library_screen.dart`), backed by `LibraryController` (`frontend/lib/presentation/state/library_controller.dart`), is the third tab of the app shell. It is the user's personal collection: liked tracks, created playlists, saved albums, and followed artists.

The defining architectural fact (**Phase 3.2A, 2026-07-17**): the library is now **offline-first with cloud sync**. **Hive stays the fast, local cache** that every read renders from; **Supabase is the durable, cross-device authority** (see [architecture](../architecture.md), [database](../database.md), [decisions](../decisions.md) ADR-011). Every CRUD action in `LibraryController` still writes to a Hive box first (optimistic) and calls `notifyListeners()` so the `Consumer`/`Selector` widgets rebuild — and then fires a **best-effort push** of the post-toggle state to Supabase. The library both survives app restarts (Hive) **and** follows the user across devices (Supabase).

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

## Cloud Sync (Phase 3.2A) — offline-first

Hive is the fast local cache; **Supabase is the durable cross-device authority**. New files back this: `data/remote/catalog_resolver.dart`, `data/remote/library_remote_data_source.dart`, `data/repositories/library_repository.dart`, `data/local/library_sync_state.dart`. `LibraryController` takes an optional `LibraryRepository`; `main.dart` wires it via `ChangeNotifierProxyProvider<AuthController, LibraryController>` and drives `LibraryRepository.onUserSession(uid)` on auth changes (idempotent per identity). See [decisions](../decisions.md) ADR-011.

### Synced entities

| Cloud table | Local box | Notes |
|-------------|-----------|-------|
| `user_liked_tracks` | `liked_tracks` | Liked tracks |
| `user_saved_albums` | `saved_albums` | Saved albums |
| `user_followed_artists` | `followed_artists` | Followed artists (also written by onboarding — see [onboarding](onboarding.md)) |
| `user_hidden_tracks` | `settings` → `hidden_track_ids` | Hidden tracks (new table — see below) |

`LibraryRemoteDataSource` does RLS-safe CRUD scoped to `auth.uid()`, with **idempotent inserts** (ignores Postgres `23505`). It **never writes the trigger-maintained counters** (`bump_*` triggers maintain `platform_likes_count`/`platform_followers_count`).

### Deezer-id → catalog-UUID resolution

Local entities carry Deezer ids; cloud rows need Supabase catalog UUIDs. `CatalogResolver` maps them by querying the publicly-readable catalog tables (`artists.deezer_id`, `albums.deezer_id`, `tracks.deezer_id`), cached in memory + `SharedPreferences`. To let tracks resolve, `Track` gained a nullable **`deezerTrackId` (HiveField 11, backwards-compatible)** sourced from the v2 payload's top-level id in `_mapTrackV2`.

### Sync & conflict model

- **Optimistic local write**: Hive first, then a best-effort `pushX` does only the cloud side.
- **Journaling**: on an unresolved Deezer id or a network failure, the op is journaled in `LibrarySyncState` pending-ops (deduped by `kind + deezerId`, **last-write-wins**). `flushPending` replays the journal.
- **`hydrateFromCloud` is ADD-ONLY** and **skips any cloud item that has a pending `remove` op** — so an unlike/unfollow is never resurrected from the cloud.
- **`migrateLocalToCloud`** runs **once per user** (guarded) to push the resolvable pre-existing local library. **Unresolvable legacy items stay LOCAL-ONLY** (never dropped).

### Multi-account isolation

`onUserSession(uid)`:
- On a **real account switch** (recorded `lastUserId` != new `uid`): clears the local library boxes via `HiveStorage.clearLibraryBoxes` (`liked_tracks`/`saved_albums`/`followed_artists`/`recently_played` + the `hidden_track_ids` setting; **playlists and `user_profile` are preserved**) **and** clears the pending journal; the controller also drops the previous account's in-memory lists immediately.
- On **first sync with no recorded owner** (`lastUserId == null`, the pre-3.2A upgrade path): a pre-existing local library is **kept LOCAL-ONLY and NOT bulk-uploaded**, preventing a cross-account cloud write.

### Hidden tracks

New table `public.user_hidden_tracks(user_id, track_id, reason?, created_at)`, PK `(user_id, track_id)`, own-row RLS (`SELECT`/`INSERT`/`DELETE`), FK index. **Hidden = excluded from automatic playback + future recommendation inputs; the catalog track is NOT deleted.** The local hidden set stores `videoId`s; cloud sync recovers the Deezer id **best-effort** from a locally-known `Track` (liked / recently-played), so a hidden track with no locally-known `Track` stays local-only.

### Migrations

`HiveStorage.init()` still runs its one-time dedup migrations on `liked_tracks` and `recently_played` (keep the richest `artists` list, re-key by track id). See [database](../database.md).

### Deferred (still on-device / not yet synced)

- **Playlists cloud migration** — playlists remain Hive-only for now.
- **Followed genres** — no client feature exists.
- **Listening history** (qualified-play) — needs backend `private.record_qualified_play` + playback event hooks.
- **Offline audio downloads / local-device music scanning** — deferred. The YouTube IFrame playback engine is unchanged.

---

## States

See the [UI states rule](../../.claude/rules/ui.md). Reads render from the local Hive cache, so "loading"/"error" are effectively instantaneous/absent for the collection itself; cloud sync happens in the background (best-effort, journaled on failure).

| State | Description | UI |
|-------|-------------|-----|
| Empty | A tab has no saved items | Empty-state message + CTA (e.g. "Liked songs will appear here" / a create prompt on Playlists) |
| Loaded | Items available | Filtered, sorted list; Playlists shows pinned-first |
| Loading | Initial Hive read | Effectively instant (local box read); no spinner needed in practice |
| Error | N/A for local data | Only artwork can fail (image 429/offline) — handled per-tile by `AppImage`'s placeholder, not a screen-level error. Cloud-push failures are silent + journaled (retried later), never blocking the UI |

---

## Related Files

- Screen: `frontend/lib/presentation/screens/library_screen.dart`
- Playlist detail: `frontend/lib/presentation/screens/playlist_detail_screen.dart`
- Controller: `frontend/lib/presentation/state/library_controller.dart` — see [state-management](../frontend/state-management.md)
- Cloud sync: `frontend/lib/data/repositories/library_repository.dart`, `frontend/lib/data/remote/library_remote_data_source.dart`, `frontend/lib/data/remote/catalog_resolver.dart`, `frontend/lib/data/local/library_sync_state.dart`
- Local store: `frontend/lib/data/local/hive_storage.dart` (`clearLibraryBoxes`) — see [database](../database.md), [storage](../backend/storage.md)
- Headers/widgets: `library_headers.dart` (`LibraryChipTabs`, `SearchSortHeader`), `add_to_playlist_sheet.dart`, `sort_bottom_sheet.dart` — see [widgets](../frontend/widgets.md)
- Related features: [onboarding](onboarding.md), [playlist](playlist.md), [albums](albums.md), [artists](artists.md), [profile](profile.md)

---

*Last updated: 2026-07-17*
