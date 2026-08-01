# Feature: Playlist

> **Purpose**: Documents playlist creation, editing, collaboration, and playback.
> **Update when**: Playlist data model, creation flow, or collaboration features change.

---

## Overview

Playlists are **entirely local**. There is no server, no account-synced playlist storage, and no sharing back-end — every playlist a user creates lives only in the on-device Hive database (see [database](../database.md) and [storage](../backend/storage.md)). This is a direct consequence of Paax's architecture: the backends are stateless metadata/stream proxies with no user database (see [architecture](../architecture.md)). All CRUD is mediated by `LibraryController` (`presentation/state/library_controller.dart`), which mutates Hive and then calls `notifyListeners()`; the UI observes via Provider (see [state management](../frontend/state-management.md)).

Playlists appear as one of the four tabs in the [library](library.md) screen and are edited on `playlist_detail_screen.dart`.

---

## Playlist Data Model

The stored entity is the Hive `Playlist` type (`typeId: 1`, box `playlists`, keyed by `playlist.id`). **All five fields below are persisted** — there is no separate description, owner, visibility, or collaboration field, because those concepts do not exist in this app.

| Field | Description |
|-------|-------------|
| `id` | Unique identifier (generated locally on creation). Hive box key. |
| `name` | Playlist name (user-entered; editable via rename). |
| `tracks` | `List<Track>` — the full ordered track objects (not just references), so a playlist renders offline without any lookup. |
| `createdAt` | Creation timestamp. |
| `coverColor` | Optional `0xAARRGGBB` int used as the fallback cover tint when there is no artwork collage. |

Fields the templates assume but that **do not exist**: `description`, `owner_id`, `is_public`, `is_collaborative`, `track_count` (derived from `tracks.length`), `duration` (derived), `updated_at`. Pinned state is **not** stored on the entity — it lives separately in the untyped `settings` box under `pinned_playlist_map` (see [Pinning](#pinning)).

### Cover collage

`playlist_cover.dart` renders a **2×2 collage** from the artwork of the first up-to-four tracks. With fewer than four distinct arts it degrades gracefully, and with none it falls back to the `coverColor` tint.

---

## User Flows

### Create Playlist

1. In the Library → Playlists tab, tap the **create FAB**.
2. Enter a name (required). No description/visibility prompts — there are none.
3. `LibraryController.createPlaylist(name)` builds a `Playlist` (empty `tracks`, `createdAt = now`), writes it to the `playlists` box, and notifies. The new playlist appears immediately in the tab.

### Add Track to Playlist

1. From a track's overflow menu or a swipe action on `track_list_tile`, choose **Add to Playlist**.
2. `add_to_playlist_sheet.dart` presents the user's playlists (with an inline "New playlist" affordance).
3. Selecting one calls `LibraryController.addTrackToPlaylist(playlistId, track)`, which appends the full `Track` and re-persists the playlist.

### Edit Playlist

Editing happens inside `playlist_detail_screen.dart`, which has a blurred-artwork header and an **edit mode**:

- **Rename**: edits `name` and re-persists.
- **Reorder tracks**: edit mode swaps the list for a `ReorderableListView`; drag-and-drop calls `reorderPlaylistTracks`, which rewrites the ordered `tracks` list.
- **Remove tracks**: swipe a `track_list_tile` (the tile exposes a remove-in-playlist swipe action) or use the overflow menu → `removeTrackFromPlaylist`.
- The detail screen also offers per-tab **search + sort** over the playlist's tracks.

### Delete Playlist

- From the playlist overflow menu → **Delete**. Per [UX rules](../../.claude/rules/ux.md), deleting a playlist is a high-impact, irreversible action, so it is guarded by a confirmation. `LibraryController.deletePlaylist(id)` removes it from the `playlists` box and clears any pin entry.

### Pinning

- Users can **pin up to 5 playlists** to the top of the Playlists tab. Pins are stored in the untyped `settings` box as `pinned_playlist_map` (`Map<playlistId, epochMillis>`, capped at 5). The controller enforces the cap and orders the tab pinned-first (by pin time).

---

## Collaborative Playlists

**Not applicable — not implemented.** Collaboration requires a shared server-side store and multi-user identity; Paax has neither (playlists are local-only Hive objects and auth is a local demo stub — see [authentication](authentication.md)).

- **Supported**: No.
- **Add collaborators**: N/A.
- **Collaborator permissions**: N/A.

If collaboration is ever built, it requires a real backend datastore and per-user auth — the server-side foundation for this **now exists but is unused** (see [Cloud future](#cloud-future-prepared-not-connected) and ADR-009 in [decisions](../decisions.md)).

---

## Playlist Privacy

**Not applicable — not implemented.** Because playlists never leave the device, there is no public/private/collaborative distinction. Every playlist is implicitly private to the single local user. The `share_plus` "Share" action (via `overflow_menu`) shares a link/text, not the playlist data itself.

| Setting | Description |
|---------|-------------|
| Private | Implicit and only state — playlists are device-local. |
| Public | Not implemented (no discovery/search of user playlists). |
| Collaborative | Not implemented. |

---

## Cloud future (prepared, not connected)

As of 2026-07-16 a full server-side playlist model is **deployed but unused by the app** (Supabase Phase 1, ADR-009 — see [`../backend/database-schema.md`](../backend/database-schema.md)): `playlists` + `playlist_tracks` (each entry has its **own uuid row id**, enabling reorder and repeated tracks), visibility `private`/`followers`/`unlisted`/`public`, `playlist_collaborators` (roles `viewer`/`editor`/`owner`), plus `user_followed_playlists` and `user_downloaded_playlists` sync tables. Everything above this section — local Hive playlists — remains the live behavior until the Phase-3 migration ([`../tasks/backlog.md`](../tasks/backlog.md) TASK-B21).

---

## States

Every user-facing surface must handle the five UI states (see [ui rules](../../.claude/rules/ui.md)). For playlists:

| State | UI |
|-------|-----|
| Empty playlist | Playlist detail with no tracks shows an empty state prompting the user to add songs. |
| Empty (no playlists) | Playlists tab shows an empty state with the create FAB as the call to action. |
| Loading | Playlists load synchronously from Hive (local), so there is effectively no network spinner; artwork within loads lazily via the throttled image pipeline. |
| Loaded | Track list with playback, edit-mode reorder, search/sort, and pin controls. |
| Error | Local reads rarely fail; artwork failures fall back to the music-note placeholder / `coverColor`. There is no network-error retry because there is no network fetch for playlist data. |

---

## Related Files

- Detail screen: `frontend/lib/presentation/screens/playlist_detail_screen.dart`
- Controller (CRUD, persistence, pinning): `frontend/lib/presentation/state/library_controller.dart`
- Add-to-playlist sheet: `frontend/lib/presentation/widgets/add_to_playlist_sheet.dart`
- Cover collage: `frontend/lib/presentation/widgets/playlist_cover.dart`
- Playlist entity: `frontend/lib/domain/entities/playlist.dart` (Hive `typeId: 1`)
- Local storage: `frontend/lib/data/local/hive_storage.dart`

**See also:** [library](library.md) · [player](player.md) · [profile](profile.md) · [database](../database.md) · [state management](../frontend/state-management.md)

---

## Phase 3.3.6 — cloud-ready model (2026-08-01)

The local `Playlist` entity was extended (additive, backward-compatible) to
prepare for Phase 3.4 Supabase sync **without another UI rewrite**. Nothing here
calls Supabase yet.

**Domain**
- `owner` (`PlaylistOwner{userId, username}`) — the single creator/administrator;
  the authorization source for ownership. Canonical **user id** keyed (usernames
  may change). Ownership never changes implicitly.
- `collaborators` (`PlaylistCollaborator{userId, username, role, status, position}`)
  — authorization source for shared editing. Only `status == accepted` grants
  edit rights or appears in the UI. Empty on all local playlists this phase.
- `visibility` (`private` | `public`) and `isCollaborative` (bool) are
  **independent** explicit fields. A playlist may be private+collaborative, etc.
  `isCollaborative` is NOT inferred from the contributor count.
- `displayedContributors` — a **presentation projection** (owner first, then
  accepted collaborators, deduped by user id, owner never repeated). Never an
  authorization source; safely recomputable from owner + accepted collaborators.
- **Explicit track positions** — zero-based, normalized (contiguous, no dupes) on
  every add/remove/commit. The committed `tracks` list order is the source of
  truth; `normalizedPositions()` yields the cloud payload `{trackId, position}`.

**Header UI** (unchanged look): Line 1 title · Line 2 `owner[, collaborators]` ·
Line 3 `Visibility · N songs · duration`. **No** Collaborative/Owner/Contributor
labels — collaboration is communicated by the participant line alone.

**Ordering**: reorder is staged in Edit Order mode and committed **only on Save**
(`LibraryController.commitPlaylistOrder`); cancel/back retains the committed
order; the order persists to Hive and survives restart. Repository seam:
`updatePlaylistTrackPositions(playlistId, [{trackId, position}])` (local-only).

**Field mapping → future Supabase (Phase 3.4):**

| Local (`Playlist`) | `playlists` | `playlist_collaborators` | `playlist_tracks` |
|---|---|---|---|
| `id` | `id` | — | — |
| `ownerId` | `owner_id` | — | — |
| `name` | `title` | — | — |
| `visibility` | `visibility` | — | — |
| `isCollaborative` | `is_collaborative` | — | — |
| `collaborators[]` | — | `playlist_id, user_id, role, status, position, created_at` | — |
| `tracks[]` + positions | — | — | `playlist_id, track_id, position, added_at, added_by` |
| `createdAt` | `created_at` | — | — |

**Device-local only (NEVER in the cloud payload):** pinned playlist ids —
stored in the settings box, namespaced **per account** so pins don't leak across
accounts on a device, and never synced across devices.

> **Cloud-ready vs device-local:** playlist content + order = cloud-ready;
> pinned status = device-local preference.

Not implemented this phase: collaborative editing permissions, invitations,
real-time playlist editing (Phase 3.4+).

---

*Last updated: 2026-08-01*
