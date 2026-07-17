# Routing

> **Purpose**: Documents the technical implementation of the routing system — how routes are declared, how parameters are passed, how guards are implemented, and how navigation is triggered.
> **Update when**: A route is added or removed, navigation patterns change, or the router library is upgraded.

> **See also**: [`docs/frontend/navigation.md`](navigation.md) for the user-facing navigation structure and route map.

---

## Router Implementation

> **Correction to the template**: there is **no `go_router`**, no `GoRouter`, no `ShellRoute`, no `RouteNames`, no `redirect` guard, no `errorBuilder`. Every `go_router` snippet in the original skeleton is **not** how Paax works. Disregard `context.goNamed(...)`, `state.pathParameters`, and `state.extra` — none exist here.

Routing is **imperative** and built from Flutter SDK primitives:

- **Library**: Flutter `Navigator` (SDK). No routing package in `pubspec.yaml`.
- **Shell / handle**: `lib/presentation/screens/main_wrapper.dart` — exposes `MainWrapper.shellKey`, the static app-wide entry point for navigation.
- **Route names file**: none. Screens are constructed directly and passed to `MaterialPageRoute`.

---

## The Shell Routing Model

The authenticated app is one `MainWrapper` widget. It holds:

1. An `IndexedStack` of 4 tab root pages (Home, Search, Library, Profile).
2. **Four independent `GlobalKey<NavigatorState>`** — one nested `Navigator` per tab.
3. **Four `RouteObserver`s** — one per tab navigator (must not be shared; see below).
4. The Full Player as an animated **overlay** (`SlideTransition`), not a route.

```dart
// lib/presentation/screens/main_wrapper.dart  (shape, abridged)
class MainWrapper extends StatefulWidget {
  const MainWrapper({super.key});

  /// App-wide handle. Any code can drive the shell without a BuildContext:
  ///   MainWrapper.shellKey.currentState?.navigateTo(route);
  ///   MainWrapper.shellKey.currentState?.openPlayer();
  static final GlobalKey<MainWrapperState> shellKey =
      GlobalKey<MainWrapperState>();

  /// One RouteObserver per tab navigator (NOT shared — see note).
  static final List<RouteObserver<ModalRoute<dynamic>>> tabObservers = [
    RouteObserver<ModalRoute<dynamic>>(), // Home
    RouteObserver<ModalRoute<dynamic>>(), // Search
    RouteObserver<ModalRoute<dynamic>>(), // Library
    RouteObserver<ModalRoute<dynamic>>(), // Profile
  ];

  /// The observer for the currently active tab.
  static RouteObserver<ModalRoute<dynamic>> get activeObserver =>
      tabObservers[shellKey.currentState?._currentIndex ?? 0];
}
```

Each tab in the `IndexedStack` is a `Navigator` wired to its key and observer:

```dart
Navigator(
  key: _navigatorKeys[index],
  observers: [MainWrapper.tabObservers[index]],
  onGenerateRoute: (settings) => MaterialPageRoute(
    builder: (_) => _rootPages[index], // HomeScreen / SearchScreen / ...
  ),
);
```

> **Why one `RouteObserver` per `Navigator`?** A `RouteObserver` can be subscribed to exactly one `Navigator` at a time. Sharing a single observer across the four tab navigators trips an `observer.navigator == null` assertion in debug and silently breaks `didPopNext` callbacks in release. The comment in the source calls this out explicitly. `DynamicBackground` (dormant) relies on the *active* tab's observer to know when a pushed detail screen is popped.

---

## Route Declaration & Navigation

There is no route table. You navigate by pushing a `MaterialPageRoute` onto the **active tab's** navigator. Two equivalent entry points:

```dart
// A) From within a screen that has a BuildContext under the tab navigator:
Navigator.of(context).push(
  MaterialPageRoute(builder: (_) => AlbumDetailScreen(albumId: id)),
);

// B) From anywhere (no context needed) via the shell handle:
MainWrapper.shellKey.currentState?.navigateTo(
  MaterialPageRoute(builder: (_) => AlbumDetailScreen(albumId: id)),
);
```

`navigateTo` simply forwards to the current tab's navigator:

```dart
void navigateTo(Route route) {
  _navigatorKeys[_currentIndex].currentState?.push(route);
}
```

### Passing parameters

Parameters are ordinary **Dart constructor arguments** — there are no path params, query params, or `extra` maps. Callers pass whatever the destination needs, including a preloaded object to avoid a re-fetch:

```dart
Navigator.of(context).push(MaterialPageRoute(
  builder: (_) => AlbumDetailScreen(album: album, albumId: album.id),
));
```

### Switching tabs & the Full Player

```dart
// Tab switch (records history for back navigation)
MainWrapper.shellKey.currentState?.switchTab(2); // via _onTabTapped internally

// Full Player overlay — NOT a pushed route
MainWrapper.shellKey.currentState?.openPlayer();
MainWrapper.shellKey.currentState?.closePlayer();
```

Because the player is an overlay driven by an `AnimationController` (`SlideTransition`, ~120ms), it can appear above any tab, is dismissible by drag, and is the first thing intercepted by back handling — see [navigation](navigation.md#back-navigation-rules).

---

## Auth Guard

There is **no router-level guard**. The gate is a `Consumer<AuthController>` at the `MaterialApp.home` root that swaps the entire subtree:

```dart
home: Consumer<AuthController>(
  builder: (context, auth, _) {
    if (!auth.onboardingCompleted) return const OnboardingScreen();
    if (!auth.isAuthenticated)     return const AuthScreen();
    return MainWrapper(key: MainWrapper.shellKey);
  },
),
```

Onboarding/auth screens live **above** the shell, so they have no bottom dock and no tab navigators. See [state-management](state-management.md#authcontroller) and [auth feature](../features/authentication.md).

---

## Deep Linking Status

- **No in-app URL router.** The app cannot map an inbound URL (`paaxmusic.app/albums/123`) to a screen — it always boots at the shell root.
- **PWA / TWA**: the web build ships a service worker and manifest; the Android TWA is verified through Digital Asset Links (`assetlinks.json`) so the domain opens the installed app. This is *app launch* association only, not *screen-level* deep linking.
- Introducing deep links later means adding a URL parser (or a router package) that resolves a path to a `navigateTo(MaterialPageRoute(...))` on the correct tab. Tracked as a gap in [navigation](navigation.md#deep-linking).

---

## Error Handling

- There is no `errorBuilder` / 404 route (no declarative router to host one). An unknown screen is simply a code path that is never pushed.
- `onGenerateRoute` on each tab navigator only ever builds that tab's root page; detail screens are pushed explicitly with their own `MaterialPageRoute`, so a malformed route object cannot reach a fallback — the compiler enforces the widget exists.

---

*Last updated: 2026-07-16*
