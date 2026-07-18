# Feature: Search

> **Purpose**: Documents the search feature — how users discover content, the search flow, filtering, and edge cases.
> **Update when**: Search scope, algorithm, or UI changes.

---

## Overview

`SearchScreen` (`frontend/lib/presentation/screens/search_screen.dart`), driven by `SearchController` (`frontend/lib/presentation/state/search_controller.dart`), is the Search tab of the app shell. Users type a query and get grouped results across tracks, albums, and artists. There is **no in-house search index** — the query is forwarded to paax-api's `/v2/search`, which searches the **Deezer public catalog** and (for tracks only) attaches a YouTube playback match. See [the v2 pipeline in architecture](../architecture.md) and [api](../api.md).

Before the user types anything, the screen is a browse surface: a grid of **19 hard-coded `GenreCard`s** that route into genre result pages. This gives the empty state a purpose (per the [UX empty-state rule](../../.claude/rules/ux.md)) instead of a blank screen.

---

## Search Scope

Searchable via paax-api `/v2/search?type=...`:

- [x] Tracks / Songs — `type=tracks` (these get a YouTube `videoId` match for playback)
- [x] Albums — `type=albums`
- [x] Artists — `type=artists`
- [ ] Playlists — not searchable (playlists are local Hive objects only; see [library](library.md)/[playlist](playlist.md))
- [ ] Podcasts — not supported (music-only product)
- [ ] Users — not applicable (no server-side user accounts; see [authentication](authentication.md))
- [x] Genres — via the 19 static `GenreCard`s in the empty state, not free-text genre search

---

## Search Behavior

- **Trigger**: Debounced live search. `SearchController` waits **220 ms** after the last keystroke before issuing requests (tuned down from 400 ms for responsiveness).
- **Minimum characters**: Searches start at **≥ 2 characters**. A single character does nothing; an empty query short-circuits to the browse (genre grid) state.
- **Parallel + partial fan-out**: The controller runs `searchTracks`/`searchAlbums`/`searchArtists` concurrently against `MusicRepositoryImpl` and paints **each group the moment it returns** (no wait-for-all); a single group failing doesn't fail the others.
- **Cancellation (newest-wins)**: a monotonic generation token is bumped on every query change, so a slower older response can never overwrite a newer query's results.
- **In-memory LRU cache (40 entries)**: a repeated query paints **instantly** and then silently revalidates in the background (stale-while-revalidate); identical in-flight queries are coalesced.
- **Connection reuse**: one persistent keep-alive HTTP client per data source, **prewarmed** (HEAD) on `SearchController` init; large search payloads are JSON-decoded in a **background isolate** (`compute`) to keep scrolling at 60 FPS.
- **Results limit**: `limit=25` per type (paax-api default for `/v2/search`).

> **/v2-migration compatible**: the pipeline talks only to the `MusicRepository` interface — a future move to the normalized `/v2` endpoints is a drop-in repository swap, and the debounce/cancellation/cache/partial logic is unaffected. See [architecture](../architecture.md). The search perf work is **logic-only** — the Search screen, cards, spacing, animations and layout are unchanged. Covered by `frontend/test/unit/search_controller_test.dart` (min-length gate, newest-wins cancellation, instant cache, coalesced-query resolution, prewarm).

---

## Filters & Facets

A chip/tab row (`LibraryChipTabs`-style header) lets the user narrow the already-fetched results client-side. Filtering does **not** refetch — all three groups are fetched every search and the filter just selects which to display.

| Filter | Type | Options |
|--------|------|---------|
| Content type | Segmented tabs (single-select) | **All**, **Tracks**, **Albums**, **Artists** |

- **All**: shows every group (tracks, albums, artists) in labeled sections.
- **Tracks / Albums / Artists**: shows only that group's results.

---

## Search States

| State | Trigger | UI |
|-------|---------|-----|
| Empty (before search) | No query entered | Browse grid of **19 static `GenreCard`s**; recent searches shown above it if any exist |
| Loading | Query submitted, requests in flight | Skeleton / shimmer placeholders |
| Results | Query returned results | Grouped list — tracks, albums, artists — filtered by the active chip |
| No Results | All three groups returned 0 rows | "No results" messaging with the query echoed back; user can edit the query |
| Error | Network/API failure | `ErrorStateWidget` (classifies the error string) with a retry that re-runs the last query |
| Offline | No connectivity | Presents as the Error state — there is no offline search cache (see [offline](offline.md)) |

Tapping a track opens the [player](player.md) (and can reach `track_detail_screen`, which is only reachable from search); tapping an album/artist routes to [album](albums.md)/[artist](artists.md) detail.

---

## Recent & Trending

- **Show recent searches**: **Yes.** Submitted queries are persisted to the Hive `recent_searches` box (`Box<String>`), **capped at 10** (oldest evicted). They render above the genre grid in the empty state and can be tapped to re-run. These same recent searches also seed the Home "For You" rail (see [home](home.md)).
- **Show trending searches**: **No.** There is no analytics backend, so there is no "trending" data source. The 19 genre cards serve as the curated browse alternative.

---

## Backend Implementation

- **Search Engine**: None of our own. paax-api proxies **Deezer's public search API** (`https://api.deezer.com`, no key). For `type=tracks`, each result is additionally run through the YouTube matcher (`yt-dlp ytsearch`, scored 0–100 on duration/title/artist/trust signals) to attach a playback `videoId`. See [architecture](../architecture.md) and [services](../backend/services.md).
- **API Endpoint**: `GET /v2/search?q=<query>&type=tracks|albums|artists&limit=25`. Response is normalized by `deezer_mapper` (track/album/artist shapes with a `playback` block on tracks). See [api](../api.md).
- **Indexing**: Not applicable — Deezer is the live index. Note `/v2/search` is **not** endpoint-cached (results are query-specific), but individual YouTube matches use paax-api's 7-day match cache, so repeated searches for popular tracks resolve fast. See [cache](../backend/cache.md).

---

## Related Files

- Screen: `frontend/lib/presentation/screens/search_screen.dart`
- Genre result page: `frontend/lib/presentation/screens/genre_results_screen.dart`
- Track detail (search-only): `frontend/lib/presentation/screens/track_detail_screen.dart`
- Controller: `frontend/lib/presentation/state/search_controller.dart` — see [state-management](../frontend/state-management.md)
- Repository: `frontend/lib/data/repositories/music_repository_impl.dart` → `searchV2` in `youtube_music_data_source.dart`
- Local store: `frontend/lib/data/local/hive_storage.dart` (`recent_searches` box) — see [database](../database.md)
- API: See [api](../api.md)
- Related features: [home](home.md), [library](library.md), [albums](albums.md), [artists](artists.md)

---

*Last updated: 2026-07-17*
