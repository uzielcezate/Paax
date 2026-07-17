# Widgets

> **Purpose**: Documents shared/reusable widgets in the frontend — their purpose, public API, variants, and usage conventions. Complements `docs/design/components.md` (which covers design specs).
> **Update when**: A new shared widget is created, its props change, or a widget is deprecated.

---

## At a glance

- Widgets live flat under `lib/presentation/widgets/`, grouped by role (glass, images, player, cards, sheets, misc) — **not** in `lib/shared/widgets/`.
- **"Glass" is not glass**: runtime blur is disabled everywhere except `player_screen.dart` — every "glass" widget renders a solid `AppColors.surface` (`#111`) fill (see [Glass system](#glassblur-system-blur-disabled)).
- **`AppImage` is the canonical network image**; `NetworkImageWithFallback` / `SmartNetworkImage` / `QueuedNetworkImage` are legacy. The throttling stack exists to survive artwork **HTTP 429s**.
- Dormant/deprecated by design: `DynamicBackground`, `thumbnail_prefetcher`, `PlaybackDebugOverlay` — see [Deprecations](#deprecations--dormant-widgets-call-out-honestly).

---

## Widget Categories

> **Correction to the template**: widgets are **not** split into `lib/shared/widgets/buttons|inputs|...`. They live flat under `lib/presentation/widgets/`, grouped by role. The table maps the template's generic categories onto Paax's real groups.

| Category | Location | Description |
|----------|----------|-------------|
| Glass / surfaces | `lib/presentation/widgets/` | "Glass" chrome — **blur disabled**, renders solid dark surfaces |
| Images | `lib/presentation/widgets/` + `lib/core/image/`, `lib/core/network/` | Throttled, cached network image stack |
| Player UI | `lib/presentation/widgets/` | Mini player, queue sheet, progress bar, lyrics, marquee, WebView host |
| Cards / lists | `lib/presentation/widgets/` | Track tiles, music cards, genre cards, playlist covers, headers |
| Sheets / menus | `lib/presentation/widgets/` | Add-to-playlist, overflow menu, sort sheet |
| Misc | `lib/presentation/widgets/` | Explicit badge, error state, padding helpers |

Related: [design/components](../design/components.md) · [theming](theming.md) · [screens](screens.md).

---

## Widget Inventory

| Widget | File | Category | Description |
|--------|------|----------|-------------|
| `GlassSurface` | `glass_surface.dart` | Glass | Solid "cinematic black" surface (no `BackdropFilter`) |
| `BlackGlassBlurSurface` | `black_glass_blur_surface.dart` | Glass | Solid dark surface variant |
| `PaaxGlassContainer` | `paax_glass_container.dart` | Glass | Solid glass container (pill/rounded) |
| `DynamicEdgeFade` | (glass group) | Glass | Gradient edge fades (`.black` / `.dynamic` / `.dynamicBottom`) |
| `DynamicBackground` | `dynamic_background.dart` | Glass | **Dormant** — extracts color, pushes to `ThemeState`; not mounted |
| `AppImage` | `app_image.dart` | Images | Canonical throttled/cached network image |
| `Thumbnail` | `thumbnail.dart` | Images | Thin delegate to `AppImage` |
| `NetworkImageWithFallback` | `network_image_with_fallback.dart` | Images | Legacy image variant |
| `SmartNetworkImage` | `smart_network_image.dart` | Images | Legacy image variant |
| `QueuedNetworkImage` | `queued_network_image.dart` | Images | Legacy image variant |
| `MiniPlayer` | `mini_player.dart` | Player | 67px persistent bar; opens Full Player |
| `QueueBottomSheet` | `queue_bottom_sheet.dart` | Player | Draggable, reorderable queue |
| `SmoothAudioProgressBar` | `smooth_audio_progress_bar.dart` | Player | 60fps interpolated scrubber |
| `SyncedLyricsView` | `synced_lyrics_view.dart` | Player | Auto-advancing synced lyrics |
| `MarqueeText` | `marquee_text.dart` | Player | Scrolling overflow text |
| `HiddenVideoPlayer` | `hidden_video_player.dart` | Player | Off-screen WebView audio host |
| `PlaybackDebugOverlay` | `playback_debug_overlay.dart` | Player | Dev-only diagnostics overlay |
| `MusicCard` | `music_card.dart` | Cards | Album/artist/track card |
| `TrackListTile` | `track_list_tile.dart` | Cards | Track row with swipe actions |
| `GenreCard` | `genre_card.dart` | Cards | Genre browse tile |
| `PlaylistCover` | `playlist_cover.dart` | Cards | 2×2 collage cover |
| `SectionHeader` | `section_header.dart` | Layout | Section title + "see all" |
| `LibraryChipTabs` / `SearchSortHeader` | `library_headers.dart` | Layout | Library tab chips + search/sort header |
| `AddToPlaylistSheet` | `add_to_playlist_sheet.dart` | Sheets | Add track(s) to playlist |
| `OverflowMenu` | `overflow_menu.dart` | Menus | Context menu (track/album/artist/playlist) |
| `SortBottomSheet` | `sort_bottom_sheet.dart` | Sheets | Sort options |
| `ExplicitBadge` | `explicit_badge.dart` | Misc | "E" explicit indicator |
| `ErrorStateWidget` | `error_state_widget.dart` | Feedback | Classified error + retry |
| `BottomContentPadding` | `bottom_content_padding.dart` | Layout | Reserves space for the bottom dock |

---

## Glass/Blur System (blur DISABLED)

**This is the most important thing to understand about Paax's chrome: the "glass" is not glass.** The header of `glass_surface.dart` marks it *"Phase 1 (Cinematic Black) — no `BackdropFilter`"*. Concretely:

- `BlurCapability.canBlur()` **always returns `false`** and `forceSolidGlass = true`.
- Every "glass" widget (`GlassSurface`, `BlackGlassBlurSurface`, `PaaxGlassContainer`) renders a **solid** `AppColors.surface` (`#111`) fill + a white @ 0.08 opacity, 0.5px border + a soft shadow. No backdrop sampling happens.
- `BeatyGlassTokens`: radius 16 (pill 24), `borderOpacity` 0.08, `borderWidth` 0.5, `tintOpacity` 0.32.
- The **only live `BackdropFilter` in the entire app** is inside `player_screen.dart` (blur 55 over a blurred artwork layer + a 55% scrim). Nothing else blurs.
- The "liquid glass" look is therefore *simulated*: static **pre-blurred artwork headers** (an `Image` blurred once, not a runtime backdrop) + solid dark chrome + `DynamicEdgeFade` gradient fades.

> **Why is blur disabled?** Runtime `BackdropFilter` is the single most expensive Flutter effect, and it is catastrophic on **Flutter Web** (the primary PWA target) where it forces layer readbacks and tanks scroll performance. It is also unreliable across OEM Android GPUs. The team chose a "cinematic black" solid-surface system that looks like glass over dark artwork but costs nothing per frame. See the git history's "liquid glass" polish commits and [theming](theming.md).

`DynamicEdgeFade` supplies the gradient falloffs that sell the depth illusion at container edges (top/bottom), in `.black`, `.dynamic`, and `.dynamicBottom` variants.

`DynamicBackground` is **implemented but dormant** — it is a `RouteAware` widget that extracts a `CinematicColor` from artwork and pushes it into `ThemeState`, but **no screen currently mounts it**. Contrast still flows through screens that pass `foregroundColor` explicitly. See [state-management](state-management.md#themestate) and [theming](theming.md).

---

## Images

Network artwork is the app's biggest performance liability, so images go through a purpose-built throttling stack rather than a raw `Image.network`. **`AppImage` (`app_image.dart`) is canonical**; the others are legacy.

- **`AppImage`**: `VisibilityDetector`-gated (only loads when on/near screen), fed by an `ImageRequestQueue` with priority tiers (onScreen / nearScreen / offScreen) and a 429 cooldown. On **web** it uses `Image.network`; on **mobile** it uses `CachedNetworkImage` + `ImagePipeline`. `Lh3UrlBuilder` rewrites YouTube `lh3` URLs with strict `=w-h` sizing and shards the host `lh3→lh3/4/5/6` by `url.hashCode % 4`. Falls back to a music-note placeholder.
- **`Thumbnail`**: thin delegate to `AppImage`.
- **`NetworkImageWithFallback`, `SmartNetworkImage`, `QueuedNetworkImage`**: **legacy** variants that predate `AppImage`. Prefer `AppImage` in new code.

> **Why all this machinery?** YouTube artwork (`lh3-lh6.googleusercontent.com`) and Deezer covers aggressively return **HTTP 429** under bursty parallel loads — worst on Flutter Web, where the browser fires every request at once. The queue caps concurrency (web `maxConcurrent = 1`, mobile 4), `HostThrottleState` applies per-host exponential backoff (2s→60s + jitter), and domain sharding spreads load across the `lh3–lh6` mirrors. Off-screen prefetch (`thumbnail_prefetcher`) was **deprecated** because it *caused* 429 storms. Full rationale in [architecture](../architecture.md) and [performance](../performance.md).

---

## Player UI

- **`MiniPlayer`** — 67px bar shown only when a track exists; watches `PlaybackController`; tap opens the Full Player overlay via `shellKey.openPlayer()`.
- **`QueueBottomSheet`** — `DraggableScrollableSheet` with reorderable queue, wired to `PlaybackController`.
- **`SmoothAudioProgressBar`** — interpolates between `positionNotifier` ticks with a 60fps `Ticker` so the scrubber moves smoothly despite ~250ms position updates.
- **`SyncedLyricsView`** — auto-advancing synced lyrics with active-line glow and center-scroll; data from `/lyrics` via `LyricsService`.
- **`MarqueeText`** — scrolls overflowing titles; uses a shared `MarqueeController` to sync multiple instances.
- **`HiddenVideoPlayer`** — hosts the off-screen `InAppWebView` that actually plays audio (300×300, lives in the root stack). See [player feature](../features/player.md).
- **`PlaybackDebugOverlay`** — dev-only; reads `PlaybackDiagnosticsNotifier` (reflects an older resolve-based architecture).

---

## Cards / Lists

- **`MusicCard`** — generic album/artist/track card for horizontal rails.
- **`TrackListTile`** — track row with swipe actions (add-to-playlist / add-to-queue; remove when inside a playlist). Current track = bold + border; hidden track = dimmed.
- **`GenreCard`** — colored browse tile (used for Search's 19 empty-state genres).
- **`PlaylistCover`** — 2×2 collage generated from a playlist's tracks.
- **`SectionHeader`** — section title with optional "see all".
- **`LibraryChipTabs` / `SearchSortHeader`** (`library_headers.dart`) — the Library tab chips and the per-tab search + sort header.

Per [ui](../../.claude/rules/ui.md), all interactive tiles must meet the 48×48 touch target and provide press feedback.

---

## Sheets / Menus

- **`AddToPlaylistSheet`** — pick a playlist (or create one) for a track; mutates `LibraryController`.
- **`OverflowMenu`** — context menu keyed by `MenuType` (track / album / artist / playlist); share via `share_plus`.
- **`SortBottomSheet`** — sort options for library/detail lists.

---

## Misc / Feedback

- **`ExplicitBadge`** — the "E" indicator for explicit tracks (`Track.isExplicit`).
- **`ErrorStateWidget`** — the standardized error state. Classifies error strings into an icon + message + retry action; this is the app's answer to the [ui](../../.claude/rules/ui.md) error-state requirement. There is no dedicated *offline* widget — offline surfaces as a generic error (a known gap noted in [screens](screens.md#state-handling-note)).
- **`BottomContentPadding`** — reserves scroll space so content clears the mini-player + nav dock.

---

## Widget Conventions

```dart
class MyWidget extends StatelessWidget {
  const MyWidget({super.key, required this.requiredProp, this.optionalProp});

  /// What requiredProp does.
  final String requiredProp;
  /// What optionalProp does. Defaults to null.
  final VoidCallback? optionalProp;

  @override
  Widget build(BuildContext context) { /* ... */ }
}
```

### Rules

- Use `const` constructors wherever possible.
- Read theme via context — never hardcode colors/sizes outside `AppColors`/`BeatyGlassTokens` (see [theming](theming.md), [ui rules](../../.claude/rules/ui.md)).
- Keep business logic out of widgets — consume controllers via `provider` (see [state-management](state-management.md)).
- Prefer `AppImage` for all network artwork; do not add new `Image.network` call sites.
- Extract sub-widgets past ~80 lines per the Flutter rules.

---

## Deprecations & dormant widgets (call out honestly)

| Widget | Status | Why |
|--------|--------|-----|
| `DynamicBackground` | Dormant | Implemented but mounted by no screen |
| `NetworkImageWithFallback`, `SmartNetworkImage`, `QueuedNetworkImage` | Legacy | Superseded by `AppImage` |
| `thumbnail_prefetcher` (core) | Deprecated | Off-screen prefetch caused 429s |
| `PlaybackDebugOverlay` | Dev-only | Reflects an older resolve-based playback design |
| Backdrop blur (all "glass") | Disabled by design | Perf on web/OEM Android — see [Glass system](#glassblur-system-blur-disabled) |

---

*Last updated: 2026-07-16*
