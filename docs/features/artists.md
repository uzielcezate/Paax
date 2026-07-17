# Feature: Artists

> **Purpose**: Documents the artist feature — browsing artist profiles, discographies, and related content.
> **Update when**: Artist data model, profile layout, or related content logic changes.

---

## Overview

An artist in Paax is a **Deezer artist**, surfaced through paax-api's `/v2/artist/{id}` family of endpoints. The artist profile (`artist_detail_screen.dart`) is the richest catalog surface in the app: a hero header, popular tracks, split discography (albums / singles & EPs), and "fans also like" related artists. A separate `artist_discography_screen.dart` shows the full, filterable discography.

Users can **follow** an artist; followed artists persist locally in Hive as `Artist` objects (there is no server-side social graph — see [library](library.md) and [architecture](../architecture.md)).

A key backend convenience: the v2 artist endpoints return **pre-split** release buckets — `topTracks`, `albums`, `singles`, and `relatedArtists` come already categorized from paax-api (Deezer already carries release dates and `record_type`), so the client does no client-side classification. Consequently `MusicRepositoryImpl.enrichArtistReleases` is a **no-op in the v2 path** (it existed to backfill dates/types in the old v1 ytmusicapi world). See [repositories](../backend/repositories.md).

---

## Artist Data Model

`Artist` (Hive typeId 4, box `followed_artists`, keyed by `artist.id`).

| Field | Source | Display |
|-------|--------|---------|
| Name | Deezer `/v2/artist/{id}` | Hero title |
| Profile Image (`picture`) | Deezer | Circular/large hero image |
| Bio / Description | Not provided by Deezer | Not shown (no bio surface) |
| Follower count (`nbFans`) | Deezer | Stat under the name |
| Monthly listeners | Not provided | Not shown |
| Genres | Not surfaced in the v2 artist shape | Not shown |
| Verified status | Not provided | Not shown |
| `albums` / `singles` / `topTracks` / `relatedArtists` | paax-api (pre-split) | Discography + related rails |

**Persisted (0–7)**: `id`, `name`, `picture`, `nbFans`, `albums` (`List<dynamic>`), `singles`, `topTracks`, `relatedArtists` (`List<Artist>`).
**NOT persisted**: `albumsParams`, `singlesParams` (pagination tokens — only meaningful for a live session).

---

## Screens

### Artist Profile Screen (`artist_detail_screen.dart`)

Loads in **two phases** to make the screen appear fast:
1. **Basic** — render the header (name, image, follower count, follow button) from whatever minimal data the entry point already has (`/v2/artist/{id}`), so the hero paints immediately.
2. **Enrich** — fetch the heavier buckets (`/v2/artist/{id}/top`, `/v2/artist/{id}/albums`) and fill in the rails. Until enrichment lands, those rails show shimmer skeletons.

**Sections**:
1. Hero header (image, name, `nbFans`, follow button)
2. **Popular** (top tracks)
3. **Latest** (most recent release)
4. **Albums**
5. **Singles & EPs**
6. **Fans also like** (related artists)

**Actions available**:
- [x] Follow / Unfollow (`toggleFollowArtist`)
- [x] Play top tracks
- [x] View full discography → `artist_discography_screen.dart`
- [x] Share artist (`share_plus` via `overflow_menu`)

### Artist Discography Screen (`artist_discography_screen.dart`)

The full release list with filter chips: **All**, **Albums**, **Singles & EPs**. Releases are typed by Deezer's normalized `record_type` (**album / single / ep**), so the filters partition the already-fetched, pre-split buckets — no re-fetch, no client classification.

> `artist_items_screen.dart` is an **orphaned** paginated grid (superseded by the discography screen) — noted here for accuracy; it is not in the live navigation path.

---

## Following

- **Follow action**: `LibraryController.toggleFollowArtist` writes/removes the `Artist` in the `followed_artists` Hive box and notifies listeners. The follow button reflects state reactively.
- **Effect on home**: **None currently** — the Home feed does not aggregate followed artists' new releases (there is no notifications/new-release pipeline; see [home](home.md) and [notifications](notifications.md)).
- **Effect on library**: The artist appears in the [Library](library.md) → **Artists** tab.

---

## Related Content Logic

- **Source**: Deezer's "related artists", returned by paax-api inside the `/v2/artist/{id}` response as the pre-split `relatedArtists` bucket. Rendered as the "Fans also like" rail.
- **Max shown**: Whatever Deezer returns for that artist (no client-side cap beyond the rail's horizontal viewport). There is no in-house similarity engine — see [recommendations](recommendations.md).

---

## States

See the [UI states rule](../../.claude/rules/ui.md). The 2-phase load means the header and the rails can be in different states simultaneously.

| State | UI |
|-------|-----|
| Loading | Hero paints from basic phase; enrich rails show shimmer skeletons |
| Loaded | Full profile with all rails populated |
| Not Found | Error surface for an invalid/removed artist id (paax-api 404) |
| Error | `ErrorStateWidget` with retry that re-runs the failed phase |
| Offline | Presents as Error; a *followed* artist can render its persisted buckets, but live enrichment requires the network |

---

## Related Files

- Screens: `frontend/lib/presentation/screens/artist_detail_screen.dart`, `frontend/lib/presentation/screens/artist_discography_screen.dart` (orphaned: `artist_items_screen.dart`)
- Entity: `Artist` in `frontend/lib/domain/entities/` / `frontend/lib/data/local/hive_storage.dart`
- Repository: `frontend/lib/data/repositories/music_repository_impl.dart` → `getArtistV2`, `getArtistTopV2`, `getArtistAlbumsV2` in `youtube_music_data_source.dart`
- Controller: `frontend/lib/presentation/state/library_controller.dart` (`toggleFollowArtist`) — see [state-management](../frontend/state-management.md)
- API: `GET /v2/artist/{id}`, `/v2/artist/{id}/top`, `/v2/artist/{id}/albums` — see [api](../api.md)
- Related features: [albums](albums.md), [library](library.md), [player](player.md), [recommendations](recommendations.md)

---

*Last updated: 2026-07-16*
