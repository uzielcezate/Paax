# Responsive Design

> **Purpose**: Documents breakpoints, adaptive sizing, and platform handling. Paax's responsiveness is centralized in one helper: `Responsive`.
> **Update when**: Breakpoints change, adaptive helpers change, or a new platform/form factor is supported.

---

## Target Platforms & Form Factors

Paax is a cross-platform Flutter client (package `beaty`, brand Paax). Primary target is **Android phones**; **Web/PWA/TWA** (`paaxmusic.app`) is a first-class secondary target with its own performance quirks.

| Platform | Form Factor | Notes |
|----------|------------|-------|
| Android | Phone (primary), tablet/large screens | Edge-to-edge; OEM system-nav quirks handled via safe insets |
| Web / PWA / TWA | Mobile browser (primary), tablet, desktop | Same layout; **stricter image concurrency** & different caching (see [Web vs Mobile](#web-vs-mobile-differences)) |
| iOS | Phone | Cupertino page transitions wired in `AppTheme`; not the primary distribution target |

The UI is **portrait-first**; there is no separate landscape/tablet layout beyond the width-driven adaptive values below.

---

## Breakpoints

Source: `Responsive` (`frontend/lib/core/utils/responsive.dart`).

| Name | Condition | Helper |
|------|-----------|--------|
| Mobile | `width < 600` | `Responsive.isMobile(context)` |
| Tablet | `600 ≤ width < 1200` | `Responsive.isTablet(context)` |
| Desktop | `width ≥ 1200` | `Responsive.isDesktop(context)` |

```dart
static const double mobileBreakpoint = 600;
static const double tabletBreakpoint = 1200;
```

Pick a value per breakpoint with `Responsive.value<T>(context, mobile: ..., tablet: ..., desktop: ...)` (falls back `desktop → tablet → mobile`).

---

## Adaptive Sizing Helpers

Rather than distinct per-breakpoint layouts, Paax mostly uses **continuous, clamped** functions of screen size. This is the real "responsive system":

| Helper | Formula | Clamp |
|--------|---------|-------|
| `spacing(context)` | `width * 2%` | 8–24px |
| `horizontalPadding(context)` | `width * 6%` | 16–24px |
| `verticalSpacing(context)` | `height * 1.2%` | 8–14px |
| `screenPadding(context)` | symmetric `spacing` | — |
| `fontSize(context, base, {min:12, max:30})` | `base * (width/400)`, scale capped at 1.5 | min–max |
| `iconSize(context, {base:24, min:20, max:32})` | `base * (width/400)`, scale capped at 1.5 | 20–32 |
| `artworkSize(context)` | `width * 75%` (player artwork) | 280–400px |
| `gridCount(context, {minItemWidth:160, maxColumns:6})` | `floor(width / minItemWidth)` | 2–6 columns |
| `bottomPadding(context)` | `160 + MediaQuery.padding.bottom` (nav 80 + mini-player 80 + safe area) | — |

> Note: `fontSize`/`iconSize` scale relative to a **400px baseline width** and cap growth at 1.5× so desktop doesn't produce oversized type. See [spacing.md](spacing.md) and [typography.md](typography.md).

---

## Layout Strategy Per Breakpoint

The **structure is the same at every breakpoint** — a 4-tab shell with a bottom nav dock and floating mini-player. Only *values* (padding, font/icon size, grid column count) scale. There is **no** navigation-rail or master-detail layout for tablet/desktop.

### Mobile (Phone, `< 600`)
- Navigation: bottom nav dock (4 tabs: Home / Search / Library / Profile) + floating `MiniPlayer` (~67px). See [frontend/navigation.md](../frontend/navigation.md).
- Content columns: grids use `gridCount` → **2 columns** typical.
- Horizontal padding: 16px (floor of `horizontalPadding`).
- Player: full-screen **overlay** (`SlideTransition`, not a route) + mini-player bar.

### Tablet (`600–1199`)
- Same shell. Grids widen via `gridCount` (e.g. 3–5 columns depending on `minItemWidth`).
- Horizontal padding: up to 24px; fonts/icons scale up (capped 1.5×).
- **No navigation rail** — the bottom dock persists.

### Desktop / Web-wide (`≥ 1200`)
- Same shell again. Grid columns clamp at **6 max**; padding maxes at 24px.
- **No** persistent drawer or master-detail. This is a known limitation — the app was designed phone-first and stretched, not re-laid-out, for wide screens.

> **Recommendation (target state):** for genuine large-screen support, introduce a `NavigationRail` (or drawer) above the tablet breakpoint (`600`) and a master-detail split for detail screens. Today wide screens just get wider grids.

---

## Responsive Implementation

```dart
import 'package:beaty/core/utils/responsive.dart';

// Per-breakpoint value
final columns = Responsive.gridCount(context, minItemWidth: 160); // 2..6

// Continuous, clamped sizing
final pad  = Responsive.horizontalPadding(context);   // 16..24
final size = Responsive.fontSize(context, 20);        // scales with width, capped
final art  = Responsive.artworkSize(context);         // 280..400 (player)

// Reserve room for the floating mini-player + nav dock
ListView(padding: EdgeInsets.only(bottom: Responsive.bottomPadding(context)));
```

---

## Adaptive Components

| Component | Mobile | Tablet | Desktop/Wide |
|-----------|--------|--------|--------------|
| Navigation | Bottom dock (4 tabs) | Bottom dock (same) | Bottom dock (same) — no rail |
| Content grid | ~2 cols (`gridCount`) | 3–5 cols | up to 6 cols |
| Player | Mini bar + fullscreen overlay | same | same (no side panel) |
| Search | In-tab screen (debounced) | same | same |
| Padding / type / icons | `Responsive.*` clamped low | mid | clamped high (1.5× cap) |

---

## Orientation Handling

- **Portrait**: primary; all layouts are designed portrait-first.
- **Landscape**: not specially handled — the width-driven helpers simply react to the wider viewport (bigger grids/padding). No landscape-specific player layout.
- **Orientation lock**: none in app code — follows the device setting.

---

## Safe Areas & Platform Quirks

Android edge-to-edge introduces the most nuance:

- The app renders **edge-to-edge**; screens use `SafeArea`/`MediaQuery.padding` and a **`SafeInsets`** approach to avoid content colliding with the status bar and system nav — this specifically works around **Android OEM gesture/nav-bar quirks** (inconsistent bottom insets across manufacturers).
- `bottomPadding(context)` always adds `MediaQuery.padding.bottom` on top of the 160px dock reserve, so the floating mini-player never overlaps the system nav.
- `usesCleartextTraffic=true` and `enableOnBackInvokedCallback=true` are set in the Android manifest (see [Android config](../environment.md) / project facts). Custom `PopScope` back handling routes the hardware back button: close player → pop tab nav → tab history → Home → exit.

---

## Web vs Mobile Differences

The same widget tree runs on web and mobile, but the **image loading pipeline differs** because browsers hammer image hosts and trigger HTTP 429s (see [frontend/theming.md](../frontend/theming.md) and the image-throttling system):

| Concern | Web | Mobile |
|---------|-----|--------|
| Image widget | `Image.network` | `CachedNetworkImage` + `ImagePipeline` |
| Concurrency | `ImageRequestQueue` **maxConcurrent = 1** | **4** |
| Cache | Memory-only (`flutter_cache_manager`) | Disk cache (~30 days) |
| Page transitions | n/a | Android **instant**, iOS Cupertino slide |

These differences are handled in the `core/image/` + `core/network/` layer (VisibilityDetector-gated loads, per-host exponential backoff, `Lh3UrlBuilder` domain sharding). Design-wise the takeaway is: **assume artwork loads lazily and may be briefly placeholdered on web**, and always use `AppImage`/`Thumbnail`. See [components.md](components.md).

---

*Last updated: 2026-07-16*
