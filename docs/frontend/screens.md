# Screens

> **Purpose**: An inventory of all screens in the frontend application — their purpose, route, responsible widget file, and dependencies.
> **Update when**: A new screen is added, a screen is renamed or removed, or its core dependencies change.

---

## At a glance

- Screens live flat in `lib/presentation/screens/` and are pushed as `MaterialPageRoute`s onto per-tab navigators — **no named routes** (see [routing](routing.md)).
- Four tab roots (Home, Search, Library, Profile) plus detail screens; the Full Player is an **overlay**, not a route.
- Network-backed screens handle loading / loaded / error (via `error_state_widget`); **offline degrades to the error state** (no dedicated detector).
- Library/Profile/Playlist read from [Hive](../database.md) synchronously — effectively always "loaded".
- `ArtistItemsScreen` is **orphaned** (no live caller); `TrackDetailScreen` is reachable from **Search only**.

---

## Screen Inventory

> **Correction to the template**: there are **no named routes** (`/`, `/albums/:id`). Screens are pushed as `MaterialPageRoute`s onto per-tab navigators — see [routing](routing.md). "Reached via" replaces the route column. All in-shell screens require the user to have passed the onboarding + demo-auth gate (see [navigation](navigation.md#authentication-guard)); there is no per-screen auth.

| Screen | File (`lib/presentation/screens/`) | Reached via | Notes |
|--------|-----------------------------------|-------------|-------|
| `OnboardingScreen` | `onboarding_screen.dart` | root gate, `!onboardingCompleted` | 3-page PageView |
| `AuthScreen` | `auth_screen.dart` | root gate, `!isAuthenticated` | demo login/signup |
| `MainWrapper` | `main_wrapper.dart` | root gate, authenticated | shell (not a content screen) |
| `HomeScreen` | `home_screen.dart` | tab 0 | charts + genres + For You |
| `SearchScreen` | `search_screen.dart` | tab 1 | debounced search |
| `LibraryScreen` | `library_screen.dart` | tab 2 | 4 sub-tabs |
| `ProfileScreen` | `profile_screen.dart` | tab 3 | account + stats |
| `PlayerScreen` | `player_screen.dart` | **overlay** via `shellKey.openPlayer()` | full player |
| `AlbumDetailScreen` | `album_detail_screen.dart` | push (Home/Search/Library/Artist) | |
| `ArtistDetailScreen` | `artist_detail_screen.dart` | push (track/album/search) | 2-phase load |
| `ArtistDiscographyScreen` | `artist_discography_screen.dart` | push (Artist detail) | |
| `ArtistItemsScreen` | `artist_items_screen.dart` | **orphaned** — no live caller | paginated grid |
| `GenreResultsScreen` | `genre_results_screen.dart` | push (Search/Home) | search-driven |
| `PlaylistDetailScreen` | `playlist_detail_screen.dart` | push (Library) | edit-order |
| `TrackDetailScreen` | `track_detail_screen.dart` | push (**Search only**) | recommended rail |

Data flows through `MusicRepositoryImpl` → `YouTubeMusicDataSource` (paax-api `/v2/*`); see [architecture](../architecture.md) and [api](../api.md).

---

## State handling note

The [`ui`](../../.claude/rules/ui.md)/[`ux`](../../.claude/rules/ux.md) rules require every screen to handle loading / loaded / empty / error / offline. Reality: the **network-backed** screens (Home, Search, Album, Artist, Genre, Track) handle loading (shimmer/spinner), loaded, and error (`error_state_widget` with retry). **Empty** is handled where meaningful (Search empty → genre cards; Library tabs → empty prompts). **Offline** has no dedicated detector — a failed request surfaces as the generic error state, not a distinct offline banner. Library/Profile read from Hive and are effectively always "loaded" (no network fetch). Gaps are called out per screen below.

---

### `OnboardingScreen`

**File**: `onboarding_screen.dart` · **Gate**: shown when `!onboardingCompleted`
**Purpose**: One-time 3-page `PageView` intro. On completion calls `AuthController.completeOnboarding()` (persists `onboarding_completed` to Hive), which rebuilds the root gate to `AuthScreen`.
**States**: static content — no async states.

---

### `AuthScreen`

**File**: `auth_screen.dart` · **Gate**: shown when onboarding done but `!isAuthenticated`
**Purpose**: Login / signup form. **Demo auth only** — `login` accepts hardcoded `user@gmail.com` / `12345`; `signup` always succeeds. No tokens, no server. See [auth feature](../features/authentication.md) and [security](../security.md).
**State provider**: `AuthController`.
**States**: form validation inline; failed login shows an error message. No network → no loading/offline states.

---

### `MainWrapper` (shell)

**File**: `main_wrapper.dart`
**Purpose**: Not a content screen — the app shell. Hosts the 4-tab `IndexedStack`, per-tab navigators, bottom dock (`MiniPlayer` + nav icons), the `HiddenVideoPlayer`, and the Full Player overlay. Owns back-navigation logic and `shellKey`. See [navigation](navigation.md) / [routing](routing.md).

---

### `HomeScreen`

**File**: `home_screen.dart` · **Tab**: 0
**Purpose**: Landing feed — time-based greeting, chart rows (`getCharts` for regions ZZ/US/MX), genre rows, and a "For You" row derived from recent searches.
**State providers**: `MusicRepositoryImpl` (via local futures), `PlaybackController`, `LibraryController`, `ThemeState`.
**Data loaded**: charts (`/v2/chart` region variants), genre content, recent-search-derived recommendations.
**Interactions**: tap track → `playQueue`; tap album/artist → push detail; tap genre → push `GenreResultsScreen`.

| State | UI |
|-------|-----|
| Loading | Shimmer skeleton rows |
| Loaded | Vertical scroll of horizontal rails |
| Empty | Rare (charts almost always return) — falls through to error/empty rows |
| Error | `error_state_widget` with retry |
| Offline | Not distinct — shown as error |

---

### `SearchScreen`

**File**: `search_screen.dart` · **Tab**: 1
**Purpose**: Search across tracks/albums/artists with an All/Tracks/Albums/Artists filter.
**State provider**: `SearchController` (400ms debounce; parallel `Future.wait`).
**Data loaded**: `/v2/search?type=...`; recent searches from Hive.
**Interactions**: tap track → push `TrackDetailScreen` (the *only* entry to it) or play; tap album/artist → push detail; tap a genre card → push `GenreResultsScreen`.

| State | UI |
|-------|-----|
| Loading | Spinner / inline loading |
| Loaded | Filtered result list |
| Empty (no query) | **19 hardcoded `GenreCard`s** as browse entry |
| Empty (no results) | "No results" message |
| Error | `error_state_widget` with retry |

---

### `LibraryScreen`

**File**: `library_screen.dart` · **Tab**: 2
**Purpose**: The user's saved content in 4 sub-tabs — **Liked / Playlists / Albums / Artists** — each with its own in-tab search + sort. Playlists show pinned-first (cap 5). A FAB creates playlists.
**State provider**: `LibraryController` (Hive-backed; see [database](../database.md)).
**Data loaded**: entirely local (Hive) — no network fetch.
**Interactions**: tap → push relevant detail; swipe/long-press track for actions; create/pin/reorder playlists.

| State | UI |
|-------|-----|
| Loading | N/A — Hive reads are synchronous |
| Loaded | Tab content lists |
| Empty | Per-tab empty prompt (e.g. "No liked songs yet") |
| Error | N/A — no network |

---

### `ProfileScreen`

**File**: `profile_screen.dart` · **Tab**: 3
**Purpose**: Avatar, name, listening stats (`minutesListened`), recently played rail, and destructive actions (clear data / logout).
**State providers**: `AuthController`, `LibraryController`.
**Interactions**: logout (`HiveStorage.clearAll()` → back to auth); clear data; tap recently-played → play/push.
**States**: local data; logout/clear guarded per [ux](../../.claude/rules/ux.md) confirmation guidance.

---

### `PlayerScreen` (Full Player overlay)

**File**: `player_screen.dart` · **Reached via**: `shellKey.openPlayer()` (overlay, not a route)
**Purpose**: Full-screen player. Two modes — **Song** (large artwork) and **Lyrics** (`synced_lyrics_view`). Artwork swipe → next/prev; `SmoothAudioProgressBar`; shuffle / prev / play / next / loop controls; drag-to-dismiss.
**State provider**: `PlaybackController` (queue, `isPlaying`, loop/shuffle, `positionNotifier`/`durationNotifier`).
**Notable**: this is the **only** live `BackdropFilter` in the app (blur 55 over blurred artwork + 55% scrim) — see [widgets](widgets.md#glassblur-system-blur-disabled). Lyrics come from the paax-api `/lyrics` endpoint via `LyricsService`.
**States**: playing/paused; lyrics available vs. unavailable (falls back to Song mode messaging).

---

### `AlbumDetailScreen`

**File**: `album_detail_screen.dart` · **Reached via**: push
**Purpose**: Blurred-artwork header + track list; play-all; save album. Enriches tracks from their `playback` block on demand.
**Data loaded**: `/v2/album/{id}` via repository (in-memory album cache).
**Interactions**: play track/album; save (`LibraryController`); tap artist → push `ArtistDetailScreen`; overflow menu (share/add to playlist).

| State | UI |
|-------|-----|
| Loading | Header placeholder + shimmer list |
| Loaded | Header + track list |
| Empty | Rare — malformed album falls to error |
| Error | `error_state_widget` with retry |

---

### `ArtistDetailScreen`

**File**: `artist_detail_screen.dart` · **Reached via**: push
**Purpose**: Artist hub with sections — **Popular / Latest / Albums / Singles & EPs / Fans also like**.
**Load strategy**: **2-phase** — render basic info immediately, then enrich (top tracks, discography, related) so the screen paints fast and fills in.
**Data loaded**: `/v2/artist/{id}`, `/v2/artist/{id}/top`, `/v2/artist/{id}/albums`.
**Interactions**: follow (`LibraryController`); play top tracks; tap album → push album; "see all" → push `ArtistDiscographyScreen`.

| State | UI |
|-------|-----|
| Loading | Phase-1 header shown, sections shimmer while enriching |
| Loaded | Full sections |
| Error | `error_state_widget` with retry |

---

### `ArtistDiscographyScreen`

**File**: `artist_discography_screen.dart` · **Reached via**: push from Artist detail
**Purpose**: Full discography with **All / Albums / Singles & EPs** filter chips.
**Data loaded**: artist albums (`/v2/artist/{id}/albums`), release type from Deezer mapper.
**States**: loading shimmer → grid; error with retry.

---

### `ArtistItemsScreen` (orphaned)

**File**: `artist_items_screen.dart`
**Status**: **ORPHANED** — a paginated grid screen with no live caller in the current navigation graph. Retained in the tree but unreachable. Documented for completeness; candidate for removal or re-wiring.

---

### `GenreResultsScreen`

**File**: `genre_results_screen.dart` · **Reached via**: push from Search genre cards / Home rows
**Purpose**: A genre landing page. **Search-driven** — it runs a query for the genre term rather than hitting a dedicated genre endpoint.
**States**: loading → result list; error with retry; empty if the genre query returns nothing.

---

### `PlaylistDetailScreen`

**File**: `playlist_detail_screen.dart` · **Reached via**: push from Library
**Purpose**: A user playlist — blurred header, track list, in-place **edit order** (`ReorderableListView`), pin (cap 5), plus search + sort.
**State provider**: `LibraryController` (Hive `Playlist` object).
**Interactions**: play; reorder; add/remove tracks; pin/unpin; rename.
**States**: local — loaded/empty (empty playlist prompt). No network states.

---

### `TrackDetailScreen`

**File**: `track_detail_screen.dart` · **Reached via**: push from **Search only**
**Purpose**: A single track's page with a "recommended" rail.
**Data loaded**: track + related from repository.
**States**: loading → content; error with retry. Note the narrow entry point — this screen is not reachable from Home/Library/detail screens.

---

## Screen Standards

All screens should:
- [ ] Have a single root `StatefulWidget`/`StatelessWidget`, consuming controllers via `provider` (see [state-management](state-management.md)).
- [ ] Handle loading, loaded, empty, and error where a network fetch exists. **Offline** currently degrades to the error state (no dedicated detector) — a known gap.
- [ ] Be responsive via `Responsive` helpers (`core/utils`).
- [ ] Respect safe areas (`safe_insets.dart`) and keep the bottom dock clear via `bottom_content_padding`.
- [ ] Use `error_state_widget` for the error state and shimmer for loading, per [widgets](widgets.md).

Cross-references: [features/](../features/) · [widgets](widgets.md) · [theming](theming.md) · [navigation](navigation.md).

---

*Last updated: 2026-07-16*
