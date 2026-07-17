# Feature: Recommendations

> **Purpose**: Documents the recommendation system — how content is surfaced to users based on their preferences, history, and behavior.
> **Update when**: The recommendation algorithm, signals, or surfaces change.

---

## Overview

Be honest up front: **Paax has no personalized recommender.** There is no ML model, no collaborative filtering, no per-user embedding, and no server-side "made for you" pipeline — the backends are stateless metadata proxies with no user database (see [architecture](../architecture.md)). What the app calls "recommendations" is a mix of **editorial/chart data from the source APIs** and **catalog-relationship lookups** (an artist's top tracks, an artist's related artists). The only vaguely "personal" surface, "For You" on Home, is derived from the user's **recent search terms** — not from listening behavior.

Everything below documents what actually exists. Do not describe a signals-weighted algorithm; there isn't one.

---

## Recommendation Surfaces

| Surface | Location | Description |
|---------|----------|-------------|
| Charts / genre rows | Home screen | Editorial content: `getCharts` for ZZ (global) / US / MX plus genre rows. Not personalized — same for everyone in a region. See [home](home.md). |
| "For You" | Home screen | Built from the user's **recent search terms** (the `recent_searches` Hive box, max 10). It re-queries the API for those terms; it is search-history-derived, not behavior-modeled. |
| "Fans Also Like" (related artists) | Artist detail | `relatedArtists` from the Deezer-backed `/v2/artist/{id}` response. Catalog relationship, not user-specific. See [artists](artists.md). |
| Artist top tracks | Artist detail | `getArtistTopV2` (`/v2/artist/{id}/top`) — the artist's most popular tracks. Used both on the artist page and as the seed for the track-detail rail. |
| "Recommended for you" rail | Track detail | Despite the label, it is **not personalized**: it surfaces the current track's artist's top tracks (`getArtistTopV2`) and/or a search by that artist. Reachable from search only. See [Track-detail rail](#track-detail-rail). |
| Watch / radio playlist | API (not auto-chained in the player) | The v1 `/watch?videoId&playlistId` endpoint returns a YouTube-style radio queue. The data exists but is **not** automatically appended to the queue when playback ends (see [player](player.md) autoplay note). |
| Autoplay after queue ends | Player | **Not implemented** — playback stops at the end of the queue; no recommended continuation. |

---

## Recommendation Signals

**Not applicable — there is no signal-weighting engine.** The app does not compute weighted scores from listening history, skips, likes, or time of day. The closest thing to a "signal" is the raw list of recent search strings feeding "For You". The table below is retained to make the absence explicit:

| Signal | Description | Weight |
|--------|-------------|--------|
| Recent searches | Last ≤10 search terms (`recent_searches` box) seed the "For You" queries. | The only input, and it is not weighted. |
| Listening history | Recently-played is stored, but **not** used to generate recommendations. | Unused. |
| Explicit likes | Liked tracks are stored, but **not** fed into recommendations. | Unused. |
| Skip rate | Not tracked. | N/A. |
| Followed artists | Followed artists are stored, but **not** used to build a recommendation feed. | Unused. |
| Time of day | Not used. | N/A. |

---

## Algorithm

- **Type**: None (no personalization). It is best described as **editorial + catalog-relationship lookups**.
- **Engine**: Third-party catalog data via paax-api's v2 hybrid endpoints — Deezer metadata (charts, artist top, related artists) matched to YouTube `videoId`s for playback (see [api](../api.md) and the v2 pipeline in [architecture](../architecture.md)). No internal ML model exists.
- **Update frequency**: Whatever the upstream cache TTLs are — chart/artist data is cached ~6h server-side (see [cache](../backend/cache.md)). "For You" refreshes when the user's recent searches change.

### Track-detail rail

`track_detail_screen.dart` (reachable from search results) shows a "Recommended for you" rail. Under the hood it uses the track's artist to fetch **that artist's top tracks** (`getArtistTopV2`) and/or a search scoped to the artist name. It is content-adjacency (same artist / neighborhood), presented with a personalized-sounding label.

---

## Cold Start Problem

Because nothing is personalized, there is effectively **no cold-start problem** — a brand-new user sees exactly what an established user sees: regional charts and genre rows on Home. There is no onboarding step that captures genre/artist preferences (onboarding is a 3-page intro PageView; see [settings](settings.md)). "For You" is simply empty/absent until the user has searched for something.

- **Strategy**: Fall back to globally/regionally trending content (charts) for everyone.
- **Onboarding signals**: None captured.

---

## Feedback Loop

**Not applicable — not implemented.** User actions do not adjust any recommendation model, because there is no model. Liking, skipping, or adding to a playlist changes the local library only (see [library](library.md)); none of it flows back into what gets recommended.

| User Action | Effect |
|-------------|--------|
| Like a track | Saved to the local `liked_tracks` box. No effect on recommendations. |
| Skip a track | Not recorded. No effect. |
| Add to playlist | Saved locally. No effect on recommendations. |
| "Not interested" | Feature does not exist. |

---

## Privacy Considerations

Because there is no server-side recommender, **no behavioral data leaves the device for recommendation purposes.** Recent searches (which seed "For You") are stored locally in Hive and only used to re-issue normal metadata queries. There is nothing to "disable" and no ML retention policy. See [security](../security.md).

- User data used for recommendations: recent search strings (local only).
- User can disable: N/A (no tracking to disable); clearing app data wipes recent searches.
- Data retention for ML: N/A — no ML.

---

## Related Files

- Home ("For You" + charts): `frontend/lib/presentation/screens/home_screen.dart`
- Artist detail ("Fans Also Like", top tracks): `frontend/lib/presentation/screens/artist_detail_screen.dart`
- Track detail ("Recommended for you"): `frontend/lib/presentation/screens/track_detail_screen.dart`
- Data source (top tracks / related / search / watch): `frontend/lib/data/api/youtube_music_data_source.dart`
- Repository: `frontend/lib/data/repositories/music_repository_impl.dart`
- API: See [`docs/api.md`](../api.md)

**See also:** [home](home.md) · [artists](artists.md) · [search](search.md) · [player](player.md) · [architecture](../architecture.md)

---

*Last updated: 2026-07-16*
