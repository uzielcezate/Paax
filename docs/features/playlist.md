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

## Phase 3.4.1 — Cloud Playlists (2026-08-02)

Playlists are now **authoritative in Supabase**. Hive is the offline cache /
optimistic mirror / pending-op journal / last-known state / device-local pin
store — never the cloud source of truth. Every write goes through a
permission-/version-checked SECURITY DEFINER RPC.

**Concepts (kept strictly separate)**
- **Owner** — the single creator/administrator (`playlists.owner_id`, canonical
  user id). The authorization source for ownership. Changing it is an explicit
  operation (transfer / succession), never implicit.
- **Collaborators** — users with an **accepted** `playlist_collaborators` record
  and an editing role. The authorization source for shared editing. Pending /
  declined / removed / left / blocked users have no edit rights.
- **Displayed contributors** — a presentation projection (owner first, then
  accepted collaborators by `joined_at`, deduped by canonical id, owner never
  repeated, pending never shown). **Never** an authorization source.
- **Followers** — `user_followed_playlists`. Following ≠ ownership/editing: a
  followed playlist appears in the follower's Library, reflects owner/collaborator
  updates, and cannot be edited by the follower.

**Follow vs Clone / Add-to-playlist**
- **Follow** saves the *source* cloud playlist in the follower's Library (read-only,
  live updates). Unfollow removes it locally; the source is untouched.
- **Add to playlist** (non-member) either **creates a new independent playlist**
  from the source tracks (clone — new UUID, owner = current user, Private, no
  collaborators/followers/activity copied, `source_playlist_id` recorded; later
  edits are independent both ways) or **adds all source tracks to one of the
  user's editable playlists** (one grouped `tracks_added` on the target; source
  untouched).

**Cloud order vs device-local pin**
- Track content + order = **cloud-ready** (synced; one-based `position`,
  normalized, no dupes). Reorder stays staged-until-Save; Save submits one atomic
  `playlist_save_order` (version-checked), bumps `version` + `last_modified_at/by`,
  and emits one `tracks_reordered` activity.
- **Pinned status = device-local preference.** Never synced, never in any cloud
  payload, per-account scoped, and it must not change `updated_at`/
  `last_modified_at`/`version`/follower count or create activity.

**`last_modified_at` semantics** — updates for title/description/visibility/cover/
track add/remove/reorder (meaningful content or metadata edits). Follow/unfollow,
device-local pin, and open/play do NOT change it.

**Ownership succession (account deletion)** — server-side (`auth.users` AFTER
DELETE trigger → `private.handle_owner_account_deletion`, independent of the
deleting client): ownership transfers to the **oldest eligible accepted
collaborator** ordered by `joined_at` → `created_at` → `user_id`, **skipping
blocked / missing-profile** candidates. If none, the playlist is **soft-deleted**
(no arbitrary/system owner). Explicit transfer (owner-initiated) requires the
target to be an accepted collaborator, is transactional, and demotes the prior
owner to an accepted editor.

**Blocking** — a minimal `user_blocks` seam. `private.is_blocked` denies access in
BOTH directions: a blocked user cannot view/edit the blocker's private
collaborative playlists, is hidden from displayed contributors, and is **not
eligible to inherit ownership**. Historical activity remains attributed; prior
track additions are not deleted.

**Offline / conflict** — optimistic local write → RPC when online → journal
(per-user pending-op queue) when offline. Replay is ordered: success drops the op,
a **version conflict or lost permission drops the stale op and is surfaced**, a
network error keeps the op and stops (preserving order). Reorder/metadata use
optimistic concurrency (expected `version`); a stale device cannot overwrite a
newer title/collaborator/ownership/order.

**Realtime** — while Playlist Detail is open, one ref-counted channel per playlist
watches metadata/version, tracks, collaborators, activity, and deletion; a
monotonic version guard drops stale events; torn down on leave and on account
switch. RLS governs delivery (no private leakage).

### Future Supabase mapping (implemented)
`playlists(id, owner_id, name, description, visibility, collaborative,
cover_mode, custom_cover_url, source_playlist_id, version, deleted_at,
platform_followers_count, total_tracks, total_duration_seconds, created_at,
updated_at, last_modified_at, last_modified_by)` ·
`playlist_collaborators(playlist_id, user_id, role, status, invited_by,
invited_at, accepted_at, joined_at, created_at, updated_at)` ·
`playlist_tracks(id, playlist_id, track_id, position, added_by, added_at,
updated_at)` · `playlist_activity(id, playlist_id, actor_id, event_type,
created_at, playlist_version, metadata, grouped_change_id)` ·
`user_followed_playlists(user_id, playlist_id, created_at)` ·
`user_blocks(blocker_id, blocked_id, created_at)`.

**Known limitations (3.4.1):** hydrated (cross-device/followed/collaborating)
track rows carry no artist-name join, so their subtitle can be empty until edited
locally; a follow reflects in the Library on the next session hydration (not
instantly); LibraryController's best-effort mirror pushes for reorder use no
version check (the version-checked path is the Detail-screen Save); first sign-in
on a device holding another account's pre-3.4.1 local playlists migrates them to
the signed-in account (device-local single-user assumption).

### Role-dependent removal, privacy, activity (Phase 3.4.1.1)

The Playlist Detail overflow shows exactly one removal action per role, and each
routes to the authoritative RPC (UI visibility is convenience; RLS/RPC decides):

| Role | Action | Effect |
|------|--------|--------|
| Owner | **Delete playlist** | `playlist_delete` (soft delete). **RPC-first with rollback**: the RPC must succeed before any local change, so a failure never leaves a local-only deletion. On success clears Hive + device-local pin; realtime removes it on other devices; collaborators/followers lose it. |
| Collaborator (accepted) | **Leave collaborative playlist** | `playlist_leave` — removes it from the leaver's library only. |
| Follower | **Remove from library** | `playlist_set_follow(false)` — drops the follow + local pin. |
| Pending invitee | **Decline invitation** | `playlist_respond_invitation(false)`. |

- **"Last modified…" is always tappable** for every cloud playlist (owner,
  collaborative, followed, zero-track). It opens the activity detail sheet;
  `ensureLatestActivity()` fetches on demand and synthesizes a "created" event
  when the log is empty. The actor is shown by username, never a UUID.
- **Edit privacy (owner only):** overflow → Private/Public via version-checked
  `playlist_update_metadata`; emits a grouped `visibility_changed` activity;
  rolls back + reloads on a version conflict. Visibility is **orthogonal** to
  `collaborative` (never overloaded).
- **Collaboration notifications:** invite/accept/decline/remove/leave/transfer
  now notify the counterpart via the in-app inbox — see
  [notifications](notifications.md#in-app-inbox-implemented-phase-3411).

### Party (entry scaffold only, Phase 3.4.1.1)

The Library "+" opens an action sheet (**Create playlist** / **Start a Party**).
Create playlist is unchanged. **Start a Party is a scaffold behind
`AppConfig.partyEnabled` (default OFF)**: it opens an informational prep sheet and
**creates nothing** — there is no Party backend, table, or session. It exists as
the minimal nav seam for a future "temporary shared listening session".

---

*Last updated: 2026-08-03*
