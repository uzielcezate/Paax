# Spacing

> **Purpose**: Documents the spacing system — margins, padding, gaps, and layout dimensions. Consistent spacing creates visual rhythm.
> **Update when**: A spacing scale is adopted, the base unit changes, or naming conventions change.

---

## Rules

- **Honest current state:** Paax has **no formal spacing scale and no spacing token file.** Spacing is a mix of (a) ad-hoc numeric literals inlined per screen/widget and (b) width/height-derived values from the `Responsive` helper. Treat the values below as *observed conventions*, not enforced tokens.
- When a value should adapt to screen size, use `Responsive` (`frontend/lib/core/utils/responsive.dart`) rather than a raw literal.
- Reserve the correct amount of bottom space for the floating mini-player + nav dock using `Responsive.bottomPadding(context)` / `bottom_content_padding.dart` — do not hardcode it.

See also: [responsive.md](responsive.md), [components.md](components.md), [design-system.md](design-system.md).

---

## Base Unit

**There is no declared base unit.** In practice most literals cluster on a loose **4px grid** (values like 4, 6, 8, 12, 14, 16, 20, 24 recur), but 6 and 14 (e.g. `BeatyGlassTokens.hPadding = 14`, chip padding `horizontal: 14, vertical: 6`) break a strict 4px/8px cadence.

> **Recommendation (target state):** adopt a canonical 4px base scale (`4, 8, 12, 16, 24, 32, 48, 64`) in a new `AppSpacing` constants file and migrate the recurring literals to it. This is the single biggest maturity gap in the design system (see [design-system.md](design-system.md#design-review-process)).

---

## Spacing Scale

**No formal scale exists.** The table below documents the recommended *target* scale to adopt, annotated with the literals currently found in code that would map to each step. Until adopted, these are aspirational.

| Proposed token | Value | Currently seen as (literals) |
|-------|-------|------------------------------|
| `space.1` | 4px | `SizedBox(height: 3/4)`, dot indicators, tight gaps |
| `space.2` | 8px | `BeatyGlassTokens.vPadding = 8`, chip vertical padding (6), common `SizedBox` gaps |
| `space.3` | 12px | nav dock side insets (`left/right: 12`), `BeatyGlassTokens` inner gaps |
| `space.4` | 16px | default screen horizontal padding floor (`Responsive.horizontalPadding` min 16) |
| `space.5` | 20px | section separators; also the `radiusPill`/chip corner value |
| `space.6` | 24px | `Responsive.horizontalPadding` max; section padding |
| `space.8` | 32px | large section gaps (`Responsive.iconSize` max is also 32) |
| `space.10`–`space.16` | 40–64px | hero blocks, header heights (ad-hoc) |

Non-conforming literals to note: `14` (glass hPadding, pill title font), `6` (chip vPadding), `33` (nav icon box), `40` (glass circle button / floating pill height), `160` (bottom padding constant).

---

## Semantic Spacing Aliases

There are no named aliases in code today. The closest things that exist are `Responsive` methods — treat *those* as the de facto semantic spacing API:

| De facto alias | Implementation | Value |
|----------------|----------------|-------|
| Screen horizontal padding | `Responsive.horizontalPadding(context)` | `width * 6%`, clamped **16–24px** |
| Screen padding (symmetric) | `Responsive.screenPadding(context)` | symmetric `Responsive.spacing` |
| Generic responsive gap | `Responsive.spacing(context)` | `width * 2%`, clamped **8–24px** |
| Vertical gap | `Responsive.verticalSpacing(context)` | `height * 1.2%`, clamped **8–14px** |
| Bottom dock reserve | `Responsive.bottomPadding(context)` | **160px + `MediaQuery.padding.bottom`** (nav 80 + mini-player 80 + safe area) |
| Player artwork size | `Responsive.artworkSize(context)` | `width * 75%`, clamped **280–400px** |
| Min touch target | *(not enforced)* | Some icon hit boxes are **40px**, below the 48px guideline |

---

## Implementation

```dart
// Adaptive spacing — use Responsive instead of raw literals
import 'package:beaty/core/utils/responsive.dart';

Padding(
  padding: EdgeInsets.symmetric(horizontal: Responsive.horizontalPadding(context)),
  child: Column(children: [
    const _Section(),
    SizedBox(height: Responsive.verticalSpacing(context)),
    const _Section(),
  ]),
);

// Reserve room for the floating mini-player + nav dock at the bottom of scroll views
ListView(
  padding: EdgeInsets.only(bottom: Responsive.bottomPadding(context)),
  children: [...],
);
```

The current anti-pattern (widespread, being paid down):

```dart
// ❌ Common today — inlined magic numbers
const SizedBox(height: 24);
const EdgeInsets.symmetric(horizontal: 14, vertical: 6);
Positioned(left: 12, right: 12, top: topPadding + 4);
```

---

## Layout Grid

There is **no column grid system**. Grids are computed dynamically by item width:

| Property | Value / mechanism |
|----------|-------------------|
| Columns | Dynamic — `Responsive.gridCount(context, minItemWidth: 160, maxColumns: 6)` → `floor(width / minItemWidth)`, clamped **2–6** |
| Gutter | Ad-hoc per grid (typically `Responsive.spacing`, 8–24px) |
| Margin | `Responsive.horizontalPadding` (16–24px) |

So grids are **content-width driven** (min item ≈160px, at least 2 columns) rather than a fixed 4/8/12-column layout. See [responsive.md](responsive.md#adaptive-components).

---

*Last updated: 2026-07-16*
