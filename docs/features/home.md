# Feature: Home

> **Purpose**: Documents the design and behavior of the Home screen — the first tab users land on inside the app shell.
> **Update when**: Home screen layout, content strategy, or data sources change.

---

## Overview

`HomeScreen` (`frontend/lib/presentation/screens/home_screen.dart`) is the first tab of the [`MainWrapper`](../frontend/navigation.md) `IndexedStack`. It is a discovery surface — there is no editorial CMS behind it.

As of **Phase 3.2B (2026-07-17, branch `feat/phase-3.2b-genres-home`)** Home is **personalized from real Supabase catalog data**. The **existing layout is preserved** — header, top/bottom `DynamicEdgeFade` gradient fades, horizontal `MusicCard` rails, `SectionHeader`, and navigation are unchanged. What changed is the **data source**: the old generic / YouTube-derived chart + genre-text-search sections were replaced with deterministic sections built from the user's follows and the public catalog. This was a **connect-the-existing-UI-to-real-data** effort — no Home redesign, no new visual system, no new standalone screens.

The screen remains a single lazy `CustomScrollView` / `SliverList` so off-screen rows are not built or image-loaded until scrolled near (artwork comes from `lh3.googleusercontent.com` and Deezer CDNs, which aggressively return HTTP 429 under bursty parallel loads — see [performance notes](#performance-notes) and [widgets](../frontend/widgets.md)). The top and bottom are masked with `DynamicEdgeFade` gradient fades so content dissolves into the dark chrome.

Content is now fetched through a new **`HomeRepository`** (`frontend/lib/data/repositories/home_repository.dart`) — batched public-catalog Supabase queries returning a typed `HomeAlbum` — and driven by a new **`HomeController`** (`frontend/lib/presentation/state/home_controller.dart`). State stays **Provider + `ChangeNotifier`** (not Riverpod). `HomeController` is wired in `main.dart` via `ChangeNotifierProxyProvider<AuthController, HomeController>`, which calls `onUserSession(uid)` on auth changes so the persistent Home tab **drops the previous user's personalized sections on an account switch** (per-user cache + in-memory reset = no cross-account bleed). See [decisions](../decisions.md) ADR-012.

---

## Content Sections

The layout is a vertical stack of sections. Horizontal rails use `ListView.builder` with a horizontal scroll axis; each rail item is a `MusicCard`. **Every section is hidden when it resolves empty** — there is no fake data, and there is **no "Continue Listening" placeholder**. Album cards reuse the existing `SavedAlbum` → [`AlbumDetailScreen`](albums.md) path, so **albums without a Deezer id are hidden** (the detail screen is keyed by Deezer id).

| Section | Description | Data Source |
|---------|-------------|-------------|
| Greeting header | Time-of-day greeting + the signed-in display name. Purely local. | `AuthController` / profile |
| Your artists | The artists the user follows. | Followed-artist UUIDs → catalog |
| Your genres | The genres the user follows; tapping a genre opens the existing [`GenreResultsScreen`](library.md). | Followed-genre UUIDs → catalog |
| New from your artists | Recent releases from followed artists. | Followed-artist UUIDs → catalog albums |
| Popular from your artists | Popular albums from followed artists. | Followed-artist UUIDs → catalog albums |
| Recommended for you | Albums in the user's followed genres. | Followed-genre UUIDs → `album_genres` links |
| Trending | Trending catalog albums. | Public catalog |
| Recently added | Most recently added catalog albums. | Public catalog |

> All sections are composed **client-side** in `HomeController` from batched Supabase catalog reads — there is still no server-driven "home feed" endpoint, and **paax-api was not changed** this phase. The followed **artist and genre UUIDs are resolved once** (via `LibraryRemoteDataSource`) and **shared** by the *new* and *popular* sections, avoiding an N+1. `HomeController` cancels stale requests via a **monotonic token** so a slow load never overwrites a newer one.

---

## Personalization

Personalization is now driven by the user's **real follows** (Phase 3.2A artists + Phase 3.2B genres), resolved against the Supabase catalog:

- **Followed artists** seed *Your artists*, *New from your artists*, and *Popular from your artists*.
- **Followed genres** seed *Your genres* and *Recommended for you* (albums whose `album_genres` links fall in the followed genres).
- **Trending** and **Recently added** provide catalog-wide discovery for users with few or no follows (those personalized sections simply hide when empty).
- **Per-user offline cache**: `HomeController` caches the resolved sections in `SharedPreferences` **keyed per user**, so a warm start paints instantly and an account switch never shows the previous user's content. **Pull-to-refresh** (debounced) re-fetches; loading/retry/error/offline states are handled.
- Home does **not** auto-refresh when follows change on another tab — it refreshes on next open or pull-to-refresh (see [KNOWN_ISSUES.md](../KNOWN_ISSUES.md)). There is still no play-history / collaborative-filtering engine; "Recommended for you" is genre-membership, not learned recommendations — see [recommendations](recommendations.md).

---

## States

`HomeController` loads the sections in parallel and exposes retry/error/offline states. See the [UI states rule](../../.claude/rules/ui.md).

| State | Description | UI Behavior |
|-------|-------------|-------------|
| Loading | Catalog sections in flight | Shimmer/skeleton occupies the rail footprint so layout doesn't jump; a warm start paints from the per-user cache immediately |
| Loaded | Data available | Rails render `MusicCard`s; album taps route via the existing `SavedAlbum` → [`AlbumDetailScreen`](albums.md); genre taps open [`GenreResultsScreen`](library.md) |
| Empty | A section resolved empty (e.g. no follows yet, or "Recommended for you" has no albums in followed genres) | The section is **omitted entirely** — no empty rail, no fake data |
| Error | A fetch failed (network/Supabase) | Error state with retry; pull-to-refresh re-runs the load |
| Offline | No connectivity | Serves the per-user `SharedPreferences` cache when present; otherwise an error/retry state (see [offline](offline.md)); previously-loaded artwork may still show from the image cache |

---

## Performance Notes

Home is one of the heaviest screens because it fires several catalog requests and loads many images at once.

- **Lazy rendering**: The whole screen is a `SliverList`/`CustomScrollView`; rows are built on demand as they scroll into view, not eagerly.
- **Image throttling**: Artwork loads through `AppImage`, which is `VisibilityDetector`-gated and fed by `ImageRequestQueue` (web `maxConcurrent=1`, mobile `4`) with per-host exponential backoff on 429. This is the single biggest reason Home stays responsive on Web. See [widgets](../frontend/widgets.md) and [performance](../performance.md).
- **Batched queries, no N+1**: `HomeRepository` uses batched public-catalog Supabase reads, and `HomeController` resolves the followed artist/genre UUIDs **once** to feed the *new*/*popular* sections; sections load in parallel.
- **Per-user offline cache**: resolved sections are cached in `SharedPreferences` keyed per user, so a warm start paints instantly and avoids re-hitting Supabase; a stale-request **monotonic token** drops out-of-order responses; pull-to-refresh is debounced.
- **Edge fades**: `DynamicEdgeFade` (top + bottom) is a gradient shader mask, cheap and not a `BackdropFilter` — consistent with the app-wide "blur is disabled" [theming](../frontend/theming.md) decision.
- **Target**: above-the-fold should paint from the per-user cache well under 1s on a warm start; cold loads are bounded by the Supabase catalog reads.

---

## Related Files

- Screen: `frontend/lib/presentation/screens/home_screen.dart`
- Shell/navigation host: `frontend/lib/presentation/screens/main_wrapper.dart` — see [navigation](../frontend/navigation.md), [screens](../frontend/screens.md)
- Data: `frontend/lib/data/repositories/home_repository.dart` (batched catalog reads → `HomeAlbum`), `frontend/lib/data/remote/library_remote_data_source.dart` (followed-UUID resolution)
- State: `frontend/lib/presentation/state/home_controller.dart` (`ChangeNotifierProxyProvider<AuthController, HomeController>`, per-user cache, `onUserSession`) — see [state-management](../frontend/state-management.md)
- Genre results screen (from *Your genres*): `frontend/lib/presentation/screens/genre_results_screen.dart`
- Related features: [library](library.md) (followed genres), [search](search.md), [profile](profile.md), [recommendations](recommendations.md), [decisions.md](../decisions.md) ADR-012

---

*Last updated: 2026-07-17*
