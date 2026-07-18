// lib/presentation/state/home_controller.dart
//
// Phase 3.2.5 — Personalized Home state.
//
// Owns ONLY the catalog-derived sections (4–8): New / Popular from your
// artists, Recommended (genres), Trending, Recently Added. The local sections
// (Continue Listening, Your Artists, Your Genres) are read straight from
// LibraryController / HiveStorage by the widget and are NOT this controller's
// concern.
//
// Design contract:
//   • Reads Supabase INDEPENDENTLY — it does NOT need LibraryController
//     injected. It resolves the followed artist/genre UUIDs once per load via a
//     LibraryRemoteDataSource, then runs sections 4–8 IN PARALLEL.
//   • A monotonically increasing request token cancels stale load()/refresh()
//     results (a newer call wins; older results are ignored).
//   • Last successful section results are cached in-memory (survive rebuilds)
//     AND best-effort to SharedPreferences for offline display.
//   • refresh() is debounced (ignored if a refresh ran < 1s ago) and cancels
//     any in-flight request via the token.
//   • On network failure: show cached sections + an offline flag; if no cache,
//     an error state with retry.
//   • No duplicated requests: album ids for artists are resolved ONCE and shared
//     by the "new" and "popular" fetches.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/remote/library_remote_data_source.dart';
import '../../data/repositories/home_repository.dart';

/// Catalog section identifiers (sections 4–8).
enum HomeSectionKey {
  newFromArtists,
  popularFromArtists,
  recommended,
  trending,
  recentlyAdded,
}

class HomeController extends ChangeNotifier {
  final HomeRepository _repo;
  final LibraryRemoteDataSource _remote;
  final Future<SharedPreferences> _prefs;

  HomeController({
    HomeRepository? repository,
    LibraryRemoteDataSource? remoteDataSource,
    Future<SharedPreferences>? prefs,
  })  : _repo = repository ?? HomeRepository(),
        _remote = remoteDataSource ?? LibraryRemoteDataSource(),
        _prefs = prefs ?? SharedPreferences.getInstance();

  static const String _cacheKey = 'paax_home_sections_v1';
  static const int _cacheSchemaVersion = 1;

  // ── Section data (in-memory cache; survives rebuilds) ─────────────
  final Map<HomeSectionKey, List<HomeAlbum>> _sections = {
    for (final k in HomeSectionKey.values) k: const <HomeAlbum>[],
  };

  bool _isLoading = false;
  bool _isRefreshing = false;
  bool _isOffline = false;
  bool _hasLoadedOnce = false;
  bool _cacheHydrated = false;
  String? _error;

  int _requestToken = 0;
  DateTime? _lastRefreshAt;

  // ── Public read API ───────────────────────────────────────────────

  /// True during the very first load when there is nothing to show yet.
  bool get isLoading => _isLoading && !_hasContent;

  /// True while a pull-to-refresh runs on top of existing content.
  bool get isRefreshing => _isRefreshing;

  /// True when the last attempt failed but cached content is being shown.
  bool get isOffline => _isOffline;

  /// A hard error string when a failure occurred AND there is no cache to show.
  String? get error => _hasContent ? null : _error;

  bool get hasLoadedOnce => _hasLoadedOnce;

  List<HomeAlbum> section(HomeSectionKey key) =>
      _sections[key] ?? const <HomeAlbum>[];

  List<HomeAlbum> get newFromArtists => section(HomeSectionKey.newFromArtists);
  List<HomeAlbum> get popularFromArtists =>
      section(HomeSectionKey.popularFromArtists);
  List<HomeAlbum> get recommended => section(HomeSectionKey.recommended);
  List<HomeAlbum> get trending => section(HomeSectionKey.trending);
  List<HomeAlbum> get recentlyAdded => section(HomeSectionKey.recentlyAdded);

  bool get _hasContent =>
      _sections.values.any((list) => list.isNotEmpty);

  // ── Load / refresh / retry ────────────────────────────────────────

  /// Initial load. Safe to call more than once — the token cancels overlaps.
  /// Hydrates the offline cache first (so cached content paints immediately),
  /// then fetches fresh data.
  Future<void> load({bool fromRefresh = false}) async {
    final token = ++_requestToken;

    if (!_cacheHydrated) {
      await _hydrateFromCache();
      // A newer load()/refresh() may have started while awaiting the cache.
      if (token != _requestToken) return;
    }

    if (fromRefresh) {
      _isRefreshing = true;
    } else if (!_hasContent) {
      _isLoading = true;
    }
    _error = null;
    notifyListeners();

    try {
      // 1) Resolve followed relation UUIDs once.
      final artistIds = (await _remote.fetchFollowedArtistIds()).toList();
      if (token != _requestToken) return;
      final genreIds = (await _remote.fetchFollowedGenreIds()).toList();
      if (token != _requestToken) return;

      // 2) Resolve album ids for artists ONCE (shared by new + popular).
      final artistAlbumIds =
          artistIds.isEmpty ? <String>[] : await _repo.albumIdsForArtists(artistIds);
      if (token != _requestToken) return;

      // 3) Run sections 4–8 IN PARALLEL. Each is issued exactly once.
      final results = await Future.wait<List<HomeAlbum>>([
        artistAlbumIds.isEmpty
            ? Future.value(const <HomeAlbum>[])
            : _repo.newestAlbumsByIds(artistAlbumIds),
        artistAlbumIds.isEmpty
            ? Future.value(const <HomeAlbum>[])
            : _repo.popularAlbumsByIds(artistAlbumIds),
        genreIds.isEmpty
            ? Future.value(const <HomeAlbum>[])
            : _repo.recommendedFromGenres(genreIds),
        _repo.trending(),
        _repo.recentlyAdded(),
      ]);
      if (token != _requestToken) return;

      _sections[HomeSectionKey.newFromArtists] = results[0];
      _sections[HomeSectionKey.popularFromArtists] = results[1];
      _sections[HomeSectionKey.recommended] = results[2];
      _sections[HomeSectionKey.trending] = results[3];
      _sections[HomeSectionKey.recentlyAdded] = results[4];

      _isOffline = false;
      _error = null;
      _hasLoadedOnce = true;
      // Best-effort persist for offline display; failure is non-fatal.
      // ignore: discarded_futures
      _persist();
    } catch (e) {
      if (token != _requestToken) return;
      // Degrade gracefully: keep any cached/in-memory content and flag offline.
      if (_hasContent) {
        _isOffline = true;
      } else {
        _error = e.toString();
      }
    } finally {
      if (token == _requestToken) {
        _isLoading = false;
        _isRefreshing = false;
        notifyListeners();
      }
    }
  }

  /// Debounced pull-to-refresh. Ignored if a refresh ran < 1s ago. Cancels any
  /// in-flight request via the token and re-runs load().
  Future<void> refresh() async {
    final now = DateTime.now();
    if (_lastRefreshAt != null &&
        now.difference(_lastRefreshAt!) < const Duration(seconds: 1)) {
      return; // debounce
    }
    _lastRefreshAt = now;
    await load(fromRefresh: true);
  }

  /// Retry after a hard failure.
  Future<void> retry() => load();

  // ── Offline cache (SharedPreferences, JSON) ───────────────────────

  Future<void> _hydrateFromCache() async {
    _cacheHydrated = true;
    try {
      final p = await _prefs;
      final raw = p.getString(_cacheKey);
      if (raw == null) return;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      if ((map['schema_version'] as num?)?.toInt() != _cacheSchemaVersion) {
        return;
      }
      final sections = (map['sections'] as Map?) ?? const {};
      for (final key in HomeSectionKey.values) {
        final list = sections[key.name];
        if (list is List) {
          _sections[key] = list
              .whereType<Map>()
              .map((e) => HomeAlbum.fromJson(e.cast<String, dynamic>()))
              .toList();
        }
      }
    } catch (_) {
      // Corrupt cache — ignore and fall back to a network load.
    }
  }

  Future<void> _persist() async {
    try {
      final p = await _prefs;
      final payload = jsonEncode({
        'schema_version': _cacheSchemaVersion,
        'sections': {
          for (final entry in _sections.entries)
            entry.key.name: entry.value.map((a) => a.toJson()).toList(),
        },
      });
      await p.setString(_cacheKey, payload);
    } catch (_) {
      // Best-effort — persistence failure never breaks the UI.
    }
  }
}
