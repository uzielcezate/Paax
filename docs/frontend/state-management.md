# State Management

> **Purpose**: Documents the state management architecture — which library is used, how state is organized, which state belongs where, and patterns for common scenarios.
> **Update when**: The state management library changes, a new state layer is introduced, or conventions change.

---

## At a glance

- **`provider` + `ChangeNotifier`**, plain mutable state — **no** Riverpod, Bloc, or freezed.
- **Five global controllers** registered once in a root `MultiProvider`: `AuthController`, `LibraryController`, `PlaybackController`, `SearchController`, `ThemeState`.
- Durable state lives in [Hive](../database.md); there is **no server database** — controllers are the session source of truth.
- High-frequency playback position/duration uses `ValueNotifier` (not `notifyListeners()`) so only the progress bar rebuilds.
- Widgets consume via `context.watch`/`Selector`/`Consumer` and dispatch via `context.read`; no business logic in widgets.

---

## State Management Solution

> **Correction to the template**: earlier boilerplate assumed **Riverpod + freezed** (immutable state, `StateNotifierProvider`, `@freezed` unions). Paax uses **none of that**. The real stack is **`provider` + `ChangeNotifier`** with **plain mutable state**. Treat every Riverpod/freezed snippet elsewhere as aspirational, not implemented.

- **Library**: `provider` `^6.1.5` (see [tech-stack](../tech-stack.md))
- **Primitive**: `ChangeNotifier` (Flutter SDK) — one long-lived controller per concern
- **Pattern**: MVVM-ish — controllers are the view-models; screens/widgets subscribe and call intent methods. Unidirectional in spirit (UI → method → mutate fields → `notifyListeners()` → rebuild), but state objects are **mutable**, not immutable snapshots.
- **Persistence**: [Hive](../database.md) (local, on-device). There is **no server database** — the controllers *are* the source of truth for session state, and Hive is the durable store behind them.

Related: [architecture](../architecture.md) · [screens](screens.md) · [navigation](navigation.md) · [Library feature](../features/library.md) · [Player feature](../features/player.md)

---

## State Layers

| Layer | Description | Where it lives | Examples |
|-------|-------------|----------------|----------|
| **Global / App State** | One instance for the whole app lifetime, provided at the root `MultiProvider` in `main.dart` | `presentation/state/*.dart` (5 controllers) | Auth session, library, playback queue, search, ambient theme color |
| **Durable State** | Survives app restarts | Hive boxes (`data/local/hive_storage.dart`) | Liked tracks, playlists, saved albums, followed artists, profile, settings |
| **Screen State** | Local to a single screen | `StatefulWidget` `State` fields | Selected tab index, scroll controllers, in-progress form text, local sort choice |
| **Ephemeral State** | Transient, high-frequency, non-persisted | `ValueNotifier` inside `PlaybackController` | Playback `position`/`duration` (updated ~4×/sec) |

---

## State Organization

State is layer-first, not feature-first (matching the repo's overall [architecture](../architecture.md)). All global controllers live together:

```
lib/presentation/state/
  auth_controller.dart       ← AuthController      (session + onboarding gate)
  library_controller.dart    ← LibraryController   (liked/playlists/albums/artists)
  playback_controller.dart   ← PlaybackController  (queue + engine + media session)
  search_controller.dart     ← SearchController    (debounced multi-search)
  theme_state.dart           ← ThemeState          (ambient color, dark-only)
```

They are all registered once, at the top of the tree:

```dart
// lib/main.dart
return MultiProvider(
  providers: [
    ChangeNotifierProvider(create: (_) => AuthController()),
    ChangeNotifierProvider(create: (_) => LibraryController()),
    ChangeNotifierProvider(create: (_) => app_search.SearchController()),
    ChangeNotifierProvider(create: (_) => PlaybackController()),
    ChangeNotifierProvider(create: (_) => ThemeState()),
  ],
  child: MaterialApp(
    home: Consumer<AuthController>(
      builder: (context, auth, _) {
        if (!auth.onboardingCompleted) return const OnboardingScreen();
        if (!auth.isAuthenticated)     return const AuthScreen();
        return MainWrapper(key: MainWrapper.shellKey);
      },
    ),
  ),
);
```

> **Why a single root `MultiProvider`?** Every controller is genuinely global — the mini-player must reflect playback from any tab, the library badge must update from any screen, and the auth gate wraps the whole shell. Scoping any of these lower would force lifting state back up. There is no per-feature provider scoping.

---

## Conventions

### State is mutable `ChangeNotifier`, NOT immutable

This project deliberately does **not** use `copyWith`/`freezed`. Controllers expose private mutable fields behind getters and call `notifyListeners()` after each mutation:

```dart
// ✅ How Paax actually does it (ThemeState)
class ThemeState extends ChangeNotifier {
  Color _backgroundColor = AppColors.background;
  Color _foregroundColor = Colors.white;

  Color get backgroundColor => _backgroundColor;
  Color get foregroundColor => _foregroundColor;

  void update(Color bg, Color fg) {
    if (_backgroundColor == bg && _foregroundColor == fg) return; // no-op guard
    _backgroundColor = bg;
    _foregroundColor = fg;
    notifyListeners();
  }
}
```

Trade-off accepted: mutability means no free `==`/diffing and no time-travel, but it keeps the code small and avoids codegen (`build_runner`) on the hot path. The guard-then-notify idiom (`if (unchanged) return;`) is how needless rebuilds are avoided instead.

### Async states are explicit boolean/error fields

There is no `AsyncValue`. Each controller carries its own `isLoading` / `error` fields and toggles them around awaits (see [SearchController](#searchcontroller)). Screens branch on those fields to render the loading / loaded / empty / error states required by [`.claude/rules/ui.md`](../../.claude/rules/ui.md).

### High-frequency state uses `ValueNotifier`, not `notifyListeners()`

Playback position/duration tick several times per second. Routing those through `notifyListeners()` would rebuild every `Consumer<PlaybackController>` in the tree (mini-player, full player, queue sheet) on every tick. Instead they are exposed as standalone `ValueNotifier`s so **only** the progress bar rebuilds:

```dart
final positionNotifier = ValueNotifier<Duration>(Duration.zero);
final durationNotifier = ValueNotifier<Duration>(Duration.zero);
```

Consumed with `ValueListenableBuilder` (or read directly by `SmoothAudioProgressBar`, which further interpolates at 60fps off a `Ticker`).

---

## Global Providers / State

The real five. All are `ChangeNotifierProvider`s created once in `main.dart`.

| Provider | Type | Scope | Persistence | Description |
|----------|------|-------|-------------|-------------|
| `AuthController` | `ChangeNotifierProvider<AuthController>` | Global | Hive `user_profile` + `settings` | Demo/local session + onboarding gate. Drives the root `Consumer` that chooses Onboarding → Auth → Shell. |
| `LibraryController` | `ChangeNotifierProvider<LibraryController>` | Global | Hive (5 boxes) | Liked tracks, playlists, saved albums, followed artists, hidden ids, pinned map. |
| `PlaybackController` | `ChangeNotifierProvider<PlaybackController>` | Global | none (session only) | Owns the `PlaybackEngine`, the queue, and the OS media session. |
| `SearchController` | `ChangeNotifierProvider<SearchController>` | Global | Hive `recent_searches` | Debounced parallel search over tracks/albums/artists. |
| `ThemeState` | `ChangeNotifierProvider<ThemeState>` | Global | none | Ambient background/foreground color + status-bar brightness. Dark-only (see [theming](theming.md)). |

---

## The Five Controllers in Detail

### `AuthController`

- **State**: `UserProfile? currentUser`, `bool isAuthenticated`, `bool onboardingCompleted`.
- **Key methods**: `login(email, password)`, `signup(...)`, `logout()`, `completeOnboarding()`.
- **Reality — demo auth, no server** (see [security](../security.md) / [auth feature](../features/authentication.md)):
  `login` only accepts the hardcoded pair `user@gmail.com` / `12345`, then persists a fixed `UserProfile(name: "Uziel")`. `signup` always succeeds. `logout` calls `HiveStorage.clearAll()`. There are **no tokens and no network auth** — the backends have no per-user accounts.
- **Consumption**: the root `Consumer<AuthController>` in `main.dart` is the app's auth gate; `ProfileScreen` reads it for the account/stats/logout UI.

### `LibraryController`

- **State**: liked tracks, playlists (Hive `Playlist` objects), saved albums, followed artists, `Set<String>` hidden track ids, and a pinned-playlist map (`id → millis`, **cap 5**).
- **Pattern**: every CRUD op mutates the in-memory collection, **persists to the matching Hive box**, then `notifyListeners()`. Hive is the durable mirror of the controller.
- **Key methods (representative)**: `toggleLike(track)`, `createPlaylist(name)`, `addTrackToPlaylist(...)`, `reorderPlaylist(...)`, `saveAlbum(...)`, `followArtist(...)`, `hideTrack(id)`, `pinPlaylist(id)` (enforces the 5-pin cap).
- **Consumption**: `LibraryScreen` (4 tabs), `add_to_playlist_sheet`, `track_list_tile` swipe actions, and like buttons across detail screens use `context.watch`/`Selector` to reflect membership live.

### `PlaybackController`

The largest controller. It owns a `PlaybackEngine` (platform factory — WebView on mobile, iframe on web; see [player feature](../features/player.md)) and mediates between the UI and the OS media session (`paax_audio_handler`).

- **State**: `List<Track> queue`, `int currentIndex`, `bool isPlaying`, `bool isShuffled`, `LoopMode loopMode` (`{ off, all, one }`), plus the two high-frequency `positionNotifier` / `durationNotifier` `ValueNotifier`s.
- **Key methods**: `playQueue(tracks, startIndex)`, `playTrack(track)`, `togglePlay()`, `playNext()`, `playPrevious()` (seeks to 0 if position > 3s, else previous track), `seek(pos)`, `toggleShuffle()`, `cycleLoop()` (off → all → one → off), queue `add`/`remove`/`reorder`.
- **Engine wiring**: subscribes to engine streams — completion → `playNext()` or replay (loop-one), position throttled to ~250ms into `positionNotifier`, `isPlaying` mirrored to the media session. Prefetches the next 1 track.
- **Consumption**: `MiniPlayer`, `PlayerScreen`, `queue_bottom_sheet`. The mini-player watches `isPlaying`/`currentTrack`; the progress bar listens to the notifiers.

### `SearchController`

- **State**: query string, per-type result lists (tracks/albums/artists), `isLoading`, `error`.
- **Behavior**: **400ms debounce** on input; on fire, runs `Future.wait([searchTracks, searchAlbums, searchArtists])` in parallel via `MusicRepositoryImpl`; sets loading/error around the await. Recent queries persist to Hive `recent_searches` (max 10).
- **Consumption**: `SearchScreen` (empty state renders hardcoded genre cards; results are filtered by an All/Tracks/Albums/Artists chip).

### `ThemeState`

- **Not a light/dark toggle** — Paax is **dark-only**. `ThemeState` instead holds an *ambient* color pair derived from album art.
- **State**: `Color backgroundColor`, `Color foregroundColor`; also sets the system status-bar icon brightness to keep contrast.
- **Pipeline**: `DominantColorService.extractCinematic(imageUrl)` → `CinematicColor{background, foreground}` → `ThemeState.update(bg, fg)`. See [theming](theming.md) for the full pipeline. **Note**: the live driver widget `DynamicBackground` is currently **not mounted by any screen** (dormant), so ThemeState is presently updated only where widgets pass `foregroundColor` explicitly.

---

## Rules

- **No business logic in widgets.** Widgets read controllers via `context.watch`/`Selector`/`Consumer` and call intent methods via `context.read`. Data fetching lives in repositories, orchestration in controllers.
- **Read vs. watch.** Use `context.read<T>()` for one-off actions in callbacks (no rebuild subscription); use `context.watch<T>()` / `Consumer` / `Selector` when the widget must rebuild on change.
- **Prefer `Selector` over `Consumer`** when a widget depends on one field of a fat controller (e.g. only `isPlaying`) — it avoids rebuilding on unrelated notifications.
- **Guard before notify.** Return early when a mutation is a no-op to avoid spurious rebuilds.
- **Never store `BuildContext`** in a controller. Controllers are plain Dart objects; they do not import `presentation/`.
- **Persist then notify.** Any mutation that must survive restart writes to Hive *before* `notifyListeners()`.

---

## Common Patterns

### Consuming a single field efficiently

```dart
// Rebuilds only when isPlaying flips, not on every position tick.
Selector<PlaybackController, bool>(
  selector: (_, c) => c.isPlaying,
  builder: (_, isPlaying, __) => Icon(isPlaying ? Icons.pause : Icons.play_arrow),
);
```

### Dispatching an action without subscribing

```dart
onTap: () => context.read<PlaybackController>().playQueue(tracks, startIndex: i),
```

### Loading an async resource with explicit states

```dart
// Inside a controller
Future<void> search(String q) async {
  _isLoading = true; _error = null; notifyListeners();
  try {
    final results = await Future.wait([
      _repo.searchTracks(q), _repo.searchAlbums(q), _repo.searchArtists(q),
    ]);
    _tracks = results[0]; _albums = results[1]; _artists = results[2];
  } catch (e) {
    _error = e.toString();
  } finally {
    _isLoading = false; notifyListeners();
  }
}
```

### High-frequency updates without full rebuilds

```dart
ValueListenableBuilder<Duration>(
  valueListenable: context.read<PlaybackController>().positionNotifier,
  builder: (_, pos, __) => Text(_format(pos)),
);
```

---

## Recommended Improvements (Architecture Review, 2026-07-16)

The [Architecture Review](../architecture-review.md) §10 (Flutter) targets the client's structural gaps:

- **Dependency injection** — `MusicRepositoryImpl()` is constructed directly in `SearchController` and 7 screens, so nothing is mockable and each holds a separate album cache. Inject a single `MusicRepository` (`AR-FL-01`, `AR-MA-01`).
- **Immutable state + explicit async states** instead of mutable fields and ad-hoc booleans (`AR-FL-02`).
- **Extract business logic into use-cases** so controllers stay thin and testable (`AR-FL-03`, `AR-MA-05`).
- **A typed `Result`/`Failure` model** at the repository boundary, replacing try/catch-and-skip + string-parsed errors (`AR-MA-02`).
- **Tests + CI** — none exist today; start with mappers, matcher scoring, and `PlaybackController` queue logic (`AR-FL-06`, [testing.md](../testing.md)).
- **Localization & accessibility** — strings are hardcoded English; icon buttons lack semantic labels; Reduce Motion is unhandled (`AR-FL-07`, `AR-FL-08`).

Full detail: [architecture-review.md](../architecture-review.md#10-flutter-improvements).

---

*Last updated: 2026-07-16*
