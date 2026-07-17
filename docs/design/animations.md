# Animations

> **Purpose**: Documents the motion system — the real durations, curves, and animation patterns in the app, plus known gaps.
> **Update when**: A new animation pattern is adopted, a duration changes, or reduce-motion support is added.

---

## Animation Philosophy

Motion in Paax is **sparse and functional**. There is no motion-token file; durations and curves are inlined at each call site. The observed conventions:

1. **Purpose over decoration.** Animation is used for the full-player overlay, play/pause feedback, marquee ticker, and progress interpolation — not ambient flourish.
2. **Fast, near-instant micro-interactions.** Most transitions are 50–120ms. Android page transitions are made **instant on purpose** (no slide/fade).
3. **60fps interpolation where perception matters.** The progress bar runs its own `Ticker` to look smooth despite low-frequency (250ms) position updates from the playback engine.
4. **Gap: Reduce Motion is not honored anywhere.** See [Accessibility](#accessibility--reduce-motion).

See also: [design-system.md](design-system.md), [components.md](components.md), [frontend/screens.md](../frontend/screens.md).

---

## Duration Tokens

**There are no duration tokens** — the values below are the actual literals found in code. The table proposes a naming that a future `AppDurations` file could adopt; the "Seen in code" column is the ground truth.

| Proposed token | Value | Seen in code |
|-------|-------|--------------|
| `instant` | 0ms | Android page transitions (`_FastPageTransitionBuilder` returns `child` unchanged) |
| `micro` | 50–70ms | `FloatingTopControls` cross-fade (60ms), nav pill inner `AnimatedContainer` (50ms), mini-player `AnimatedSize` (70ms) |
| `fast` | 100–120ms | Play/pause `AnimatedSwitcher` (~100ms), player overlay slide-in/out (120ms) |
| `normal` | 150ms | Player artwork-mode `AnimatedSwitcher` (150ms) |
| `loop.pause` | 2s | `MarqueeText` pause between loops |

> Everything is well under the generic "350ms page transition" convention — Paax is deliberately snappier, and Android navigation is instant.

---

## Easing Curves

Again, **no curve tokens** — literals in code:

| Curve used | Where |
|-------|-------|
| `Curves.linear` | `FloatingTopControls` cross-fade; marquee scroll loop |
| `Curves.easeOut` | Nav pill inner container (50ms), mini-player `AnimatedSize` (70ms), progress-mode transitions |
| `Curves.ease` | Player overlay `SlideTransition` |
| *(none / identity)* | Android page transition (instant) |

---

## Common Animation Patterns

### Full Player — slide-in overlay
The full player is **not a route** — it is an overlay toggled via `MainWrapper.shellKey.openPlayer()/closePlayer()`.

- **Mechanism**: `SlideTransition` driven by an `AnimationController`, **duration 120ms** in and 120ms reverse, `Curves.ease` (`main_wrapper.dart`).
- **Drag-to-dismiss**: the player screen tracks a vertical drag; releasing past a threshold animates the controller back to closed (drag maps to the same slide offset).
- **The one real blur**: inside the open player, a `BackdropFilter(ImageFilter.blur(sigmaX: 55, sigmaY: 55))` sits over the blurred artwork with a ~55% scrim (`player_screen.dart`). This is the **only** live `BackdropFilter` in the app — see [design-system.md](design-system.md#theme-system).

### Play / Pause icon swap
- `AnimatedSwitcher` (~**100ms**) with a scale transition — the icon scales as it swaps between play and pause glyphs (`player_screen.dart`). Gives tactile feedback without a ripple.

### Song ↔ Lyrics / artwork mode
- `AnimatedSwitcher` (**150ms**, `Curves.easeOut`) transitions between player content modes.

### Mini player show/hide
- `AnimatedSize` (**70ms**, `Curves.easeOut`) in the bottom dock collapses/expands the mini-player region when a track appears/disappears (`main_wrapper.dart`).

### Floating top controls cross-fade
- `AnimatedCrossFade` (**60ms**, `Curves.linear`) swaps the default floating controls for the compact `ScrolledTopPill` as the user scrolls (`glass_surface.dart`).

### Marquee ticker (scrolling titles)
- `MarqueeText` (`marquee_text.dart`): a `Ticker`-driven horizontal scroll that only engages when text overflows. Scrolls at a constant velocity (duration computed from text width), **pauses `2s`** at each end, loops. Multiple marquees can share a `MarqueeController` to stay in sync (title + artist scroll together).

### Smooth progress bar (60fps interpolation)
- `SmoothAudioProgressBar` (`smooth_audio_progress_bar.dart`): runs its own `Ticker` (`SingleTickerProviderStateMixin`). The playback engine only reports position every ~250ms (throttled), so the bar **interpolates** between updates each frame to render smooth 60fps movement, and pauses the ticker when playback is paused (`_updateTickerState`).

### Synced lyrics
- `SyncedLyricsView` (`synced_lyrics_view.dart`): auto-advances the active line, applies a glow to the current line, and auto-scrolls it to center.

### Page / screen transitions
- **Android: instant** — `_FastPageTransitionBuilder` returns the child with no animation (deliberate; avoids jank and matches the "content just appears" feel).
- **iOS**: `CupertinoPageTransitionsBuilder` (standard horizontal slide).
- Tab switching uses an `IndexedStack` (no transition — state preserved across tabs).

### Component enter/exit (summary)

| Component | Enter | Exit |
|-----------|-------|------|
| Full player | Slide up 120ms, `Curves.ease` | Slide down 120ms (or drag-to-dismiss) |
| Bottom sheets (queue, add-to-playlist, sort) | `DraggableScrollableSheet` / `showModalBottomSheet` default | Default dismiss |
| Play/pause icon | Scale-in ~100ms | Scale-out ~100ms |
| Mini player | `AnimatedSize` 70ms | `AnimatedSize` 70ms |
| Scrolled top pill | Cross-fade 60ms | Cross-fade 60ms |

---

## Accessibility — Reduce Motion

> ⚠️ **Not handled.** No widget in Paax checks `MediaQuery.of(context).disableAnimations` (or `accessibleNavigation`). The player slide, marquee, and switchers all run regardless of the system "Reduce Motion" setting.

Recommended target implementation:

```dart
final reduceMotion = MediaQuery.of(context).disableAnimations;
final playerSlide = reduceMotion ? Duration.zero : const Duration(milliseconds: 120);
// and: skip the marquee loop + progress-bar ticker easing when reduceMotion is true
```

Because most durations are already ≤150ms, the practical impact is modest — but the **marquee loop** and **player slide** are the two that should respect the setting first.

---

## Implementation Notes & Recommendation

- Durations/curves are inlined per widget — there is no `AppDurations`/`AppCurves` file.
- `Ticker`s are correctly bound to a `TickerProvider` (`SingleTickerProviderStateMixin`) and disposed, avoiding leaks (per the Flutter rule in the project standards).

> **Recommendation (target state):** (1) Extract an `AppDurations`/`AppCurves` constants file and replace the literals. (2) Add a single `reduceMotion` helper and gate the player slide + marquee loop through it.

---

*Last updated: 2026-07-16*
