# Feature: Home

> **Purpose**: Documents the design and behavior of the Home screen — the first tab users land on inside the app shell.
> **Update when**: Home screen layout, content strategy, or data sources change.

---

## Overview

`HomeScreen` (`frontend/lib/presentation/screens/home_screen.dart`) is the first tab of the [`MainWrapper`](../frontend/navigation.md) `IndexedStack`. It is a discovery surface — there is no editorial CMS behind it. Everything on screen is assembled at runtime from the [paax-api v2 hybrid pipeline](../architecture.md) (Deezer metadata + YouTube playback matching) plus a little local personalization pulled from Hive.

The screen is built as a single lazy `CustomScrollView` / `SliverList` so that off-screen rows are not built or image-loaded until the user scrolls near them. This is deliberate: artwork comes from `lh3.googleusercontent.com` and Deezer CDNs which aggressively return HTTP 429 under bursty parallel loads, so we never build every row eagerly (see [performance notes](#performance-notes) and [widgets](../frontend/widgets.md)). The top and bottom of the scroll view are masked with `DynamicEdgeFade` gradient fades so content dissolves into the dark chrome rather than clipping hard against the app bar and the mini player dock.

Content is fetched through `MusicRepositoryImpl` (`frontend/lib/data/repositories/music_repository_impl.dart`), which wraps `YouTubeMusicDataSource`. See [repositories](../backend/repositories.md) and [the frontend data layer](../architecture.md).

---

## Content Sections

The layout is a vertical stack of sections. Horizontal rails (charts, genre rows) use `ListView.builder` with a horizontal scroll axis; each rail item is a `MusicCard`.

| Section | Description | Data Source | Order |
|---------|-------------|-------------|-------|
| Greeting header | Time-of-day greeting ("Good morning/afternoon/evening") + the signed-in display name (`UserProfile.name`, e.g. "Uziel"). Purely local. | `AuthController.currentUser` (Hive `user_profile`) | 1 |
| For You | A personalized rail seeded from the user's most recent search (the rail title becomes `Based on "<query>"`). A brand-new user with no search history falls back to a `Trending Now` rail sourced from a hard-coded `Top Hits` search. | Hive `recent_searches` (most recent entry) re-queried via `searchTracks`; else a `Top Hits` fallback query | 2 |
| Charts (ZZ / US / MX) | Top-track charts for a small set of regions: global (`ZZ`), United States (`US`), Mexico (`MX`). Rendered as separate labeled rails. | `MusicRepositoryImpl.getCharts(country)` → paax-api `/v2/chart` | 3 |
| Genre rows | Several horizontal rows of genre-based content, each a browsable slice of the catalog. | `getGenreContent(...)` → paax-api v2 search/chart-backed content | 4 |

> Region set and genre selection are defined in `home_screen.dart`. There is no server-driven "home feed" endpoint in the v2 path — the screen composes these calls client-side and lays out the results.

---

## Personalization

Personalization is intentionally shallow because there are **no server-side user accounts** (see [authentication](authentication.md) and [architecture](../architecture.md)). All signals are local Hive state:

- **Logged-in users see**: their name in the greeting, and a "For You" rail derived from their most recent search (`recent_searches` box, capped at 10 entries — the newest entry is re-queried; see [search](search.md)).
- **Guests**: there is no true guest mode; the app is gated behind the demo auth stub (`AuthController`), so the greeting always resolves to the locally-stored profile. If no searches have been performed (or the seed query returns nothing), the rail falls back to a `Trending Now` list built from a hard-coded `Top Hits` search rather than being omitted.
- **Personalization signals used**: the single most recent search query only. Play history (`recently_played` Hive box) and liked tracks are surfaced on the [Profile](profile.md) and [Library](library.md) tabs, **not** currently mixed into the Home feed. There is no recommendation engine or collaborative filtering — see [recommendations](recommendations.md) for the (limited) related-content story.

---

## States

Every rail resolves independently, so the screen can show a mix of loaded rails and still-loading rails. See the [UI states rule](../../.claude/rules/ui.md).

| State | Description | UI Behavior |
|-------|-------------|-------------|
| Loading | Charts/genre content in flight | Shimmer skeleton cards (`shimmer` package) occupy each rail's footprint so layout doesn't jump |
| Loaded | Data available | Rails render `MusicCard`s; tapping routes into [album](albums.md)/[artist](artists.md)/[player](player.md) |
| Empty | A section returned nothing (e.g. both the personalized seed and the `Top Hits` fallback returned no tracks → no "For You") | The section is omitted entirely rather than rendering an empty rail |
| Error | A fetch failed (network/API) | `ErrorStateWidget` classifies the error string and offers a retry that re-runs that section's fetch; other rails are unaffected |
| Offline | No connectivity | Surfaces as an Error state on each rail (the app has no offline cache of home content — see [offline](offline.md)); previously-loaded artwork may still show from the image cache |

---

## Performance Notes

Home is one of the heaviest screens because it fires several catalog requests and loads many images at once.

- **Lazy rendering**: The whole screen is a `SliverList`/`CustomScrollView`; rows are built on demand as they scroll into view, not eagerly.
- **Image throttling**: Artwork loads through `AppImage`, which is `VisibilityDetector`-gated and fed by `ImageRequestQueue` (web `maxConcurrent=1`, mobile `4`) with per-host exponential backoff on 429. This is the single biggest reason Home stays responsive on Web. See [widgets](../frontend/widgets.md) and [performance](../performance.md).
- **Server-side caching**: paax-api caches chart and genre responses for **6 hours** (`21600s`) in a two-tier Redis + in-memory LRU cache, so most Home loads are `X-Cache: HIT`. See [cache](../backend/cache.md) and [api](../api.md).
- **Edge fades**: `DynamicEdgeFade` (top + bottom) is a gradient shader mask, cheap and not a `BackdropFilter` — consistent with the app-wide "blur is disabled" [theming](../frontend/theming.md) decision.
- **Target**: above-the-fold (greeting + first rail) should paint from cache well under 1s on a warm start; cold catalog fetches are bounded by paax-api's per-track YouTube-match timeouts.

---

## Related Files

- Screen: `frontend/lib/presentation/screens/home_screen.dart`
- Shell/navigation host: `frontend/lib/presentation/screens/main_wrapper.dart` — see [navigation](../frontend/navigation.md), [screens](../frontend/screens.md)
- Data: `frontend/lib/data/repositories/music_repository_impl.dart`, `frontend/lib/data/api/youtube_music_data_source.dart`
- State: `AuthController`, `SearchController` (recent searches) — see [state-management](../frontend/state-management.md)
- API: `/v2/chart` and v2 search-backed genre content — see [api](../api.md)
- Related features: [search](search.md), [library](library.md), [profile](profile.md), [recommendations](recommendations.md)

---

*Last updated: 2026-07-16*
