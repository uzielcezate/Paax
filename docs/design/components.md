# Components

> **Purpose**: Catalogs the reusable UI components (custom Flutter widgets) — their anatomy, variants, states, and specs. The reference for building and reviewing UI.
> **Update when**: A new shared widget is added, a variant is introduced, or behavior changes.

---

## How components work in Paax

There is no third-party component kit and no Figma. Components are **custom Flutter widgets** under `frontend/lib/presentation/widgets/`, built on Material 3. The visual backbone is the **surface system** in `glass_surface.dart` (solid dark fills + `white@0.08`, 0.5px borders + soft shadows — blur is disabled; see [design-system.md](design-system.md#theme-system)). Most other components compose those surfaces.

Shared surface tokens (`BeatyGlassTokens`, `frontend/lib/presentation/widgets/glass_surface.dart`):

| Token | Value | Meaning |
|-------|-------|---------|
| `radius` | 16.0 | Default surface corner radius |
| `radiusPill` | 24.0 | Pill / chip corner radius |
| `heightCompact` / `heightRegular` | 38 / 44 | Standard control heights |
| `tintOpacity` / `tintOpacityLight` | 0.32 / 0.18 | Fill tint (nominal — fills render solid `#111`) |
| `borderOpacity` / `borderWidth` | 0.08 / 0.5 | The signature glass rim |
| `shadowOpacity` | 0.18 | Soft drop-shadow strength |
| `hPadding` / `vPadding` | 14 / 8 | Default inner padding |
| `highlightOpacity` | 0.06 | Inner-highlight gradient strength |

See the engineering-oriented widget inventory in [frontend/widgets.md](../frontend/widgets.md). This doc is the **design spec** view.

---

## Component Catalog

| Component | File | Variants | Status |
|-----------|------|----------|--------|
| `BeatyGlassSurface` / `GlassSurface` | `presentation/widgets/glass_surface.dart` | border on/off, shadow on/off, custom fill | ✅ Core |
| `GlassPill` | `presentation/widgets/glass_surface.dart` | any height (radius = h/2) | ✅ |
| `GlassChip` | `presentation/widgets/glass_surface.dart` | Selected (white fill), Unselected (dark + rim) | ✅ |
| `GlassCircleButton` / `GlassMenuButton` | `presentation/widgets/glass_surface.dart` | icon / arbitrary child | ✅ |
| `ScrolledTopPill` / `FloatingTopControls` | `presentation/widgets/glass_surface.dart` | default ↔ scrolled (cross-fade) | ✅ |
| `DynamicEdgeFade` | `presentation/widgets/glass_surface.dart` | `.black`, `.dynamic`, `.dynamicBottom` | ✅ Core |
| `black_glass_blur_surface` / `paax_glass_container` | `presentation/widgets/` | solid variants of the glass surface | ✅ |
| `MusicCard` | `presentation/widgets/music_card.dart` | album / artist / playlist tile | ✅ |
| `TrackListTile` | `presentation/widgets/track_list_tile.dart` | default, current (bold+border), hidden (dimmed); swipe actions | ✅ |
| `GenreCard` | `presentation/widgets/genre_card.dart` | colored genre entry (search empty state) | ✅ |
| `PlaylistCover` | `presentation/widgets/playlist_cover.dart` | 1-up / 2×2 collage | ✅ |
| `SectionHeader` | `presentation/widgets/section_header.dart` | title + optional action | ✅ |
| `LibraryChipTabs` / `SearchSortHeader` | `presentation/widgets/library_headers.dart` | chip tab bar / sort+search header | ✅ |
| `AppImage` (+ `Thumbnail`) | `presentation/widgets/app_image.dart`, `thumbnail.dart` | mobile (`CachedNetworkImage`) / web (`Image.network`); music-note placeholder | ✅ Core |
| `MiniPlayer` | `presentation/widgets/mini_player.dart` | shown when a track exists (~67px) | ✅ |
| `QueueBottomSheet` | `presentation/widgets/queue_bottom_sheet.dart` | draggable, reorderable | ✅ |
| `SmoothAudioProgressBar` | `presentation/widgets/smooth_audio_progress_bar.dart` | 60fps interpolated | ✅ |
| `SyncedLyricsView` | `presentation/widgets/synced_lyrics_view.dart` | auto-advance, glow, center-scroll | ✅ |
| `MarqueeText` | `presentation/widgets/marquee_text.dart` | scroll-if-overflow | ✅ |
| `AddToPlaylistSheet` / `OverflowMenu` / `SortBottomSheet` | `presentation/widgets/` | bottom-sheet actions; menu types track/album/artist/playlist | ✅ |
| `ExplicitBadge` | `presentation/widgets/explicit_badge.dart` | "E" marker | ✅ |
| `ErrorStateWidget` | `presentation/widgets/error_state_widget.dart` | classifies error string → icon + retry | ✅ |
| `HiddenVideoPlayer` | `presentation/widgets/hidden_video_player.dart` | 300×300 offscreen WebView host | ✅ (infra) |

> Several image widgets (`network_image_with_fallback`, `smart_network_image`, `queued_network_image`) are **legacy variants** superseded by `AppImage` — prefer `AppImage`/`Thumbnail` in new code. `thumbnail_prefetcher` is **deprecated** (off-screen prefetch caused HTTP 429s).

---

## Component Specs

### `BeatyGlassSurface` (and `GlassSurface`)

**Description**: The base "glass" container. A solid dark rounded rectangle with a hairline rim and soft shadow. Nearly every panel/pill/button composes it. `GlassSurface` is an API-compatible thin wrapper.
**File**: `frontend/lib/presentation/widgets/glass_surface.dart`

#### Anatomy
```
┌───────────────────────────────┐  ← white@0.08, 0.5px rim
│  (child)                       │  ← fill: AppColors.surface (#111)
└───────────────────────────────┘  ← soft shadow: black@0.10, blur 10, y+1
```

#### Props
| Prop | Type | Default | Description |
|------|------|---------|-------------|
| `child` | `Widget` | — | Content |
| `width` / `height` | `double?` | `null` | Optional fixed size |
| `borderRadius` | `BorderRadius` | `radius 16` | Corner radius |
| `showBorder` | `bool` | `true` | White@0.08, 0.5px rim |
| `showShadow` | `bool` | `true` | Soft drop shadow |
| `enableBlur` | `bool` | `true` | **Ignored** — always solid (`forceSolidGlass`) |
| `overrideFill` | `Color?` | `null` | Fill override (else `#111`) |

#### States
| State | Visual |
|-------|--------|
| Default | `#111` fill, `white@0.08` 0.5px rim, soft shadow |
| No border / no shadow | Flat panel (set `showBorder`/`showShadow` false) |
| Blur | **Never** — `enableBlur` is a no-op; see [design-system.md](design-system.md#theme-system) |

---

### `GlassChip`

**Description**: Selectable filter chip. Used for library tabs and search filters.
**File**: `glass_surface.dart`

| State | Visual |
|-------|--------|
| Selected | Fill `white@0.88`, **black** text, `w700`, `fontSize 12.5`, radius 20, padding `H14/V6` |
| Unselected | Fill `AppColors.elevatedSurface` (#111), text `white@0.8`, `white@0.08` 0.5px rim |

> Colors are overridable (`selectedColor`/`unselectedColor`/`textColor`) — used when a screen tints chips with the ambient artwork color.

---

### `GlassPill` / `ScrolledTopPill` / `FloatingTopControls`

**Description**: The floating top-bar system on detail screens. `GlassPill` is a full-radius (`h/2`) surface. `ScrolledTopPill` is a back-button + centered title pill. `FloatingTopControls` cross-fades between the "default" floating controls and the compact `ScrolledTopPill` as the user scrolls.
**File**: `glass_surface.dart`

- Cross-fade: `AnimatedCrossFade`, **60ms**, `Curves.linear` (see [animations.md](animations.md)).
- `ScrolledTopPill` height 40; title `w800`, `fontSize 15`; foreground driven by `foregroundColor` (ambient/adaptive).

---

### `GlassCircleButton` / `GlassMenuButton`

**Description**: Round icon buttons floating over artwork (back, overflow, etc.).
**File**: `glass_surface.dart`

| Prop | Default | Note |
|------|---------|------|
| `size` | 40 | ⚠️ Below the 48px min touch target |
| `iconSize` | 18 | — |
| Fill / rim / shadow | `#111` / `white@0.08` 0.5px / `black@0.10` blur 8 | — |

---

### `TrackListTile`

**Description**: The primary row for a track in lists (library, album, playlist, search).
**File**: `frontend/lib/presentation/widgets/track_list_tile.dart`

| State | Visual |
|-------|--------|
| Default | Thumbnail + title/artist, trailing overflow/action |
| Current (now playing) | **Bold** title + accent border |
| Hidden | Dimmed (reduced opacity) |
| Swipe | Reveals actions — add-to-playlist / add-to-queue (and remove-from-playlist in a playlist context) |

Pairs with `OverflowMenu` (`MenuType.track`) and `AddToPlaylistSheet`.

---

### `DynamicEdgeFade`

**Description**: The gradient overlay that makes content "dissolve" under floating chrome. Central to the cinematic aesthetic.
**File**: `glass_surface.dart`

| Variant | Color | Height | Max opacity | Direction |
|---------|-------|--------|-------------|-----------|
| `.black` | `#121212` (legacy literal) | 130 | 0.95 | top |
| `.dynamic` | caller-supplied (ambient) | 130 | 0.92 | top |
| `.dynamicBottom` | caller-supplied (ambient) | 240 | 0.98 | bottom |

Multi-stop `LinearGradient` (5–6 stops) fading opaque→transparent so scrolling content vanishes gradually beneath the top controls / above the mini-player. `TopFadeGradient` and `EdgeGradient` are **deprecated** wrappers — prefer `DynamicEdgeFade`.

---

## Don'ts

- Do not pass `enableBlur: true` expecting real blur — it is ignored everywhere except the full player's own `BackdropFilter`.
- Do not use `network_image_with_fallback` / `smart_network_image` / `queued_network_image` in new code — use `AppImage`/`Thumbnail` (they carry the 429-throttling pipeline). See [frontend/widgets.md](../frontend/widgets.md).
- Do not hardcode `white.withOpacity(0.08)` borders — reference `BeatyGlassTokens.borderOpacity`.
- Do not rely on `GlassCircleButton`'s default 40px size for a primary tap target on its own — pad the hit area toward 48px.

---

*Last updated: 2026-07-16*
