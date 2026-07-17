# Typography

> **Purpose**: Documents the typographic system — font family, the Material 3 text theme, and the weight scale. Defines how type is set across the app.
> **Update when**: The font is changed, a text style is added or removed, or type scale values change.

---

## Rules

- Reference theme text styles (`Theme.of(context).textTheme.*`) rather than constructing `TextStyle` from scratch where a matching style exists.
- The app uses **one font family, globally locked** — do not introduce a second family without updating this doc.
- Text should respond to the system font-scaling setting (no global `textScaleFactor` override exists — keep it that way).
- Truncate long strings with `TextOverflow.ellipsis` (used throughout for track/artist names, alongside `marquee_text` for scrolling titles in the player).

See also: [design-system.md](design-system.md), [colors.md](colors.md), [frontend/theming.md](../frontend/theming.md).

---

## Font Families

Source: `AppTheme` (`frontend/lib/core/theme/app_theme.dart`).

| Role | Family | Weights Used | Source |
|------|--------|-------------|--------|
| Everything (body, UI, display) | **Roboto** | 400–900 (heaviest for display/headline) | `google_fonts` (`GoogleFonts.roboto()` / `GoogleFonts.robotoTextTheme`) |

- There is **one** family for the entire app. It is set two ways for belt-and-suspenders coverage: `ThemeData.fontFamily = GoogleFonts.roboto().fontFamily` **and** `textTheme = GoogleFonts.robotoTextTheme(...)`.
- **Why locked:** the family is resolved once and cached (`AppTheme.appFontFamily`) specifically to **defeat OEM system-font overrides** on Android — some manufacturers substitute their own UI font, which would break the intended look.
- **No custom font files are bundled.** `pubspec.yaml` declares no `fonts:` section; Roboto is delivered by the `google_fonts` package (fetched/cached at runtime; on most Android devices Roboto is already the platform font).

> ⚠️ **Discrepancy to be aware of:** Two code comments say **"Manrope"** (`/// Manrope — locked globally` and `// Lock Manrope globally`), but the code calls `GoogleFonts.roboto()` / `GoogleFonts.robotoTextTheme()`. **The real font is Roboto.** The comments are stale from an earlier design phase. Fix the comments when you next touch `app_theme.dart`.

---

## Type Scale

Paax uses the **Material 3 default type scale** (sizes/line-heights/letter-spacing come from `ThemeData.dark().textTheme` via `GoogleFonts.robotoTextTheme`). `AppTheme` only **overrides color and weight** on a subset of styles. The table below lists the overridden styles (the ones that carry intent); un-listed styles (`titleMedium`, `titleSmall`, `bodySmall`, `labelLarge`, `labelSmall`) fall through to Material 3 defaults in Roboto.

| Style Name | Size (M3 default) | Weight (Paax override) | Color (override) | Usage |
|-----------|-------------------|------------------------|------------------|-------|
| `displayLarge` | 57 | **w900** | `textPrimary` #FFF | Hero numerals / biggest display moments |
| `displayMedium` | 45 | **w800** | `textPrimary` #FFF | Large display |
| `displaySmall` | 36 | **w800** | `textPrimary` #FFF | Display |
| `headlineLarge` | 32 | **w800** | `textPrimary` #FFF | Screen / section hero titles |
| `headlineMedium` | 28 | **w700** | `textPrimary` #FFF | Section headers |
| `titleLarge` | 22 | **w700** | `textPrimary` #FFF | Card / list section titles |
| `bodyLarge` | 16 | **w500** | `textPrimary` #FFF | Primary body text |
| `bodyMedium` | 14 | **w500** | **`textSecondary` white70** | Secondary body / metadata (default `Text` style) |
| `titleMedium` / `titleSmall` / `bodySmall` / `labelLarge` / `labelSmall` | M3 defaults | M3 default weights | M3 default (white-ish) | Not overridden |

> **Design intent:** hierarchy is driven by **weight** (w700–w900 for anything display/headline) far more than by size. The heavy weights are the reason the UI reads as bold/cinematic. `bodyMedium` is deliberately the muted `white70` so default body text recedes.

Ad-hoc `TextStyle`s also appear inline in widgets (e.g. `GlassChip` uses `fontSize: 12.5, fontWeight: w700`; `ScrolledTopPill` title uses `fontSize: 15, fontWeight: w800`). These are **not** part of the theme scale — see the recommendation below.

---

## Usage Examples

```dart
// Preferred: reference the themed style
Text('Your Library', style: Theme.of(context).textTheme.headlineLarge)   // w800, white
Text('12 songs',     style: Theme.of(context).textTheme.bodyMedium)      // w500, white70

// Local override on top of a themed style (fine)
Text(
  'Now Playing',
  style: Theme.of(context).textTheme.titleLarge?.copyWith(color: fg),
)
```

---

## Typography Rules

- Use `titleLarge`+ only for genuine headings, not decoration.
- Body text should be `bodyLarge` (primary) or `bodyMedium` (secondary). `bodyMedium` is intentionally muted (`white70`).
- Heavy weights (w800/w900) are **intentional and in-scale** here — unlike the generic template rule, w900 *is* part of Paax's display scale.
- Always `ellipsis`-truncate names; use `marquee_text` for the player's scrolling title/artist.

---

## Font Loading

No bundled font files — Roboto comes from `google_fonts`:

```dart
// frontend/lib/core/theme/app_theme.dart
static String get appFontFamily {
  _fontFamily ??= GoogleFonts.roboto().fontFamily!;   // resolved once, cached
  return _fontFamily!;
}

// applied globally
ThemeData(
  fontFamily: appFontFamily,
  textTheme: GoogleFonts.robotoTextTheme(ThemeData.dark().textTheme).copyWith(/* weight/color overrides */),
);
```

`pubspec.yaml` has **no** `flutter: fonts:` section. Dependency: `google_fonts ^8.0.2`.

> **Recommendation (target state):** (1) Fix the stale "Manrope" comments. (2) If offline-first / deterministic rendering matters, bundle the Roboto weights as assets instead of runtime-fetching. (3) Promote the recurring inline `TextStyle`s (chips, pills, badges) into named theme styles so the scale is the single source of truth.

---

*Last updated: 2026-07-16*
