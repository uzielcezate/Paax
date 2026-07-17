# Icons

> **Purpose**: Documents the icon system — the libraries used, sizing, coloring, custom SVGs, and usage rules.
> **Update when**: A new icon library or custom icon is added, sizes change, or naming conventions change.

---

## Icon Library

Paax uses **two** sources side by side:

- **Primary library**: **Material Icons** — Flutter's built-in `Icons` class (`cupertino_icons ^1.0.6` is also present for Cupertino glyphs). Used for the overwhelming majority of UI: playback controls, overflow menus, list actions, back arrows, etc.
- **Custom SVGs**: A small set of hand-made SVGs rendered at runtime via **`flutter_svg ^2.0.17`** (`SvgPicture.asset`), recolored with a `ColorFilter`. Used **only for the primary bottom-nav icons** (Home and Search) so they can have bespoke filled/outlined states.
- **Format**: Material = icon font (`IconData`); custom = SVG rendered at runtime and tinted via `ColorFilter.mode(color, BlendMode.srcIn)`.
- **Design source**: **None** — no Figma icon set. The SVGs are authored/edited directly as files under `frontend/assets/icons/`.

> Nav-bar inconsistency (intentional but worth noting): **Home** and **Search** use custom SVGs (with distinct outlined/filled variants); **Library** and **Profile** use Material `Icons`. See [frontend/navigation.md](../frontend/navigation.md).

---

## Icon Sizes

**No icon-size token file exists.** Sizes are either literals or computed via `Responsive.iconSize`. Observed values:

| Context | Size | Source |
|---------|------|--------|
| Bottom-nav SVG icons | **33×33** box | `main_wrapper.dart` (`SizedBox(width/height: 33)`) |
| `GlassCircleButton` icon | **18** (default) | `glass_surface.dart` |
| `ScrolledTopPill` back arrow | **18** | `glass_surface.dart` |
| Responsive/adaptive icons | base **24**, clamped **20–32** | `Responsive.iconSize(context, base: 24, min: 20, max: 32)` |
| Player transport controls | ad-hoc larger literals | `player_screen.dart` |

> **Recommendation (target state):** introduce an `AppIconSizes` scale (e.g. `sm 16 / md 20 / lg 24 / xl 32`) and route icon sizes through it or through `Responsive.iconSize`, replacing the loose literals (18, 33, …).

---

## Icon Color Rules

- Material icons default to **white** (`iconTheme: IconThemeData(color: Colors.white)` in `AppTheme`).
- Custom SVGs are tinted via `ColorFilter.mode(color, BlendMode.srcIn)`.
- Over artwork, chrome icons take the adaptive `foregroundColor` from `ThemeState` so they stay legible against any header. See [colors.md](colors.md#dynamic-album-color-pipeline).

| Context | Color |
|---------|-------|
| Default icon | White (`iconTheme`) |
| Selected nav icon | White + filled SVG variant + a 4px dot indicator below |
| Unselected nav icon | `white54` + outlined SVG variant |
| Icon over artwork chrome | `ThemeState.foregroundColor` (adaptive) |
| Accent / destructive | `AppColors.primaryEnd` (#FF0055) at call sites (no dedicated destructive token — see [colors.md](colors.md#semantic-colors)) |

Bottom-nav selection logic (`main_wrapper.dart`):

```dart
final color  = isSelected ? Colors.white : Colors.white54;
final asset  = isSelected ? filledAsset : outlinedAsset;   // e.g. home-filled.svg vs home.svg
SvgPicture.asset(asset, colorFilter: ColorFilter.mode(color, BlendMode.srcIn), fit: BoxFit.contain);
```

---

## Usage Rules

- Pair icons with text labels for primary navigation and important actions (nav uses icon-only + a selection dot; acceptable for a 4-tab dock).
- Do not encode meaning in color alone (color-blind users).

> ⚠️ **Accessibility gap:** Most `Icon` and `SvgPicture.asset` usages **omit `semanticLabel`**. Interactive icon buttons (back, overflow, nav) should carry semantic labels for TalkBack/VoiceOver. This is currently unmet across the app — flag/fix when touching icon widgets.

```dart
// Target usage — provide semantics on interactive icons
Icon(Icons.favorite, size: 24, color: AppColors.primaryEnd, semanticLabel: 'Like')

// Custom SVG nav icon (tinted); add a Semantics wrapper for the tappable region
SvgPicture.asset('assets/icons/home-filled.svg',
  colorFilter: ColorFilter.mode(Colors.white, BlendMode.srcIn));
```

---

## Custom Icons

All custom SVGs live in `frontend/assets/icons/` (declared under `flutter: assets:` in `pubspec.yaml`) and are used exclusively by the bottom nav:

| Name | Asset Path | Usage |
|------|------------|-------|
| Home (outlined) | `frontend/assets/icons/home.svg` | Bottom nav — Home tab, unselected |
| Home (filled) | `frontend/assets/icons/home-filled.svg` | Bottom nav — Home tab, selected |
| Search (outlined) | `frontend/assets/icons/magnifying-glass.svg` | Bottom nav — Search tab, unselected |
| Search (filled) | `frontend/assets/icons/magnifying-glass-filled.svg` | Bottom nav — Search tab, selected |

There are exactly **four** custom SVGs (two icons × outlined/filled). Everything else is a Material glyph.

---

## Adding a New Custom Icon

1. Author/optimize the SVG (24×24 base viewBox; keep it single-path where possible so `BlendMode.srcIn` tinting works cleanly — avoid baked-in fills you don't want recolored).
2. Place it in `frontend/assets/icons/`.
3. Ensure `frontend/assets/icons/` is covered by the `flutter: assets:` list in `pubspec.yaml` (it is).
4. Render with `SvgPicture.asset(path, colorFilter: ColorFilter.mode(color, BlendMode.srcIn))`.
5. If it has selected/unselected states, ship both `-filled` and outlined variants (mirroring the nav convention).
6. Add it to the Custom Icons table above.

> Prefer Material `Icons` for anything that doesn't need a bespoke shape — the custom-SVG path exists specifically for the nav's filled/outlined treatment.

See also: [components.md](components.md), [design-system.md](design-system.md), [frontend/widgets.md](../frontend/widgets.md).

---

*Last updated: 2026-07-16*
