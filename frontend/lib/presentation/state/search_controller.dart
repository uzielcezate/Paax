import 'dart:async';
import 'dart:collection';
import 'package:flutter/material.dart';
import '../../data/repositories/music_repository_impl.dart';
import '../../domain/repositories/music_repository.dart';
import '../../domain/entities/track.dart';
import '../../domain/entities/saved_album.dart';
import '../../domain/entities/artist.dart';

/// Immutable bundle of one query's results, stored in the LRU cache.
class _SearchResults {
  final List<Track> tracks;
  final List<SavedAlbum> albums;
  final List<Artist> artists;
  const _SearchResults(this.tracks, this.albums, this.artists);
}

/// Search state + a fast, cancellable, cache-backed search pipeline.
///
/// Performance model (UI is unchanged — same public getters):
///   * 220 ms debounce; searches start at >= 2 characters (1 char does nothing).
///   * A monotonic generation token is bumped on every query change, so a slow
///     older response can NEVER overwrite a newer query's results.
///   * An in-memory LRU cache makes a repeated query near-instant, and is served
///     immediately while the network silently revalidates (stale-while-
///     revalidate).
///   * Track / album / artist searches run in parallel and paint PARTIALLY —
///     each category updates the UI the moment it arrives, tolerating a single
///     category failing.
///   * Identical in-flight queries are coalesced (no duplicate requests).
///   * The HTTP connection is prewarmed (keep-alive) so the first search is fast.
///
/// The pipeline talks only to the [MusicRepository] interface, so a future
/// migration to the normalized /v2 endpoints is a drop-in repository swap.
class SearchController extends ChangeNotifier {
  final MusicRepository _repository;

  // ── Tunables ──────────────────────────────────────────────────────────────
  static const Duration _debounce = Duration(milliseconds: 220);
  static const int _minQueryLength = 2;
  static const int _maxCacheEntries = 40;

  String _query = '';
  List<Track> _trackResults = [];
  List<SavedAlbum> _albumResults = [];
  List<Artist> _artistResults = [];
  bool _isLoading = false;
  String? _error;

  Timer? _debounceTimer;

  /// Bumped on every query change. Responses from an older generation are
  /// discarded so the newest query always wins.
  int _gen = 0;

  /// Normalized queries with a network request currently in flight — used to
  /// coalesce duplicate identical requests.
  final Set<String> _inFlight = <String>{};

  /// Recent-results LRU (insertion-ordered; most-recent last).
  final LinkedHashMap<String, _SearchResults> _cache =
      LinkedHashMap<String, _SearchResults>();

  // ── Public API (unchanged) ────────────────────────────────────────────────
  List<Track> get trackResults => _trackResults;
  List<SavedAlbum> get albumResults => _albumResults;
  List<Artist> get artistResults => _artistResults;
  bool get isLoading => _isLoading;
  String? get error => _error;
  String get query => _query;

  /// [repository] is injectable for tests; production uses the real Deezer-backed
  /// [MusicRepositoryImpl].
  SearchController({MusicRepository? repository})
      : _repository = repository ?? MusicRepositoryImpl() {
    // Prewarm DNS/TLS/keep-alive so the first real search reuses an open socket.
    // ignore: discarded_futures
    _repository.prewarm();
  }

  String _normalize(String q) => q.trim().toLowerCase();

  void onQueryChanged(String newQuery) {
    if (_query == newQuery) return;
    _query = newQuery;
    _debounceTimer?.cancel();

    // Invalidate any in-flight/pending search immediately — their responses are
    // discarded the moment the query changes (proper request cancellation).
    _gen++;

    final normalized = _normalize(newQuery);

    // 0 or 1 character: do not search. Clear the results area (no stale results
    // under a shorter query); the existing UI shows its browse/empty state.
    if (normalized.length < _minQueryLength) {
      _clearResults();
      return;
    }

    // Cache hit → paint instantly (< 50 ms), then silently revalidate.
    final cached = _cache[normalized];
    if (cached != null) {
      _touch(normalized);
      _trackResults = cached.tracks;
      _albumResults = cached.albums;
      _artistResults = cached.artists;
      _isLoading = false;
      _error = null;
      _notify();
      final gen = _gen;
      _debounceTimer =
          Timer(_debounce, () => _fetch(newQuery, normalized, gen, revalidate: true));
      return;
    }

    // Cache miss → drop the previous query's results (they don't match the new
    // query) so the UI shows its loading state instead of stale results under
    // the new text (Phase 3.3.1 §5), then fetch after the debounce.
    _trackResults = [];
    _albumResults = [];
    _artistResults = [];
    _isLoading = true;
    _error = null;
    _notify();
    final gen = _gen;
    _debounceTimer =
        Timer(_debounce, () => _fetch(newQuery, normalized, gen, revalidate: false));
  }

  void _clearResults() {
    _trackResults = [];
    _albumResults = [];
    _artistResults = [];
    _isLoading = false;
    _error = null;
    _notify();
  }

  /// Runs the three category searches in parallel. Each category paints as soon
  /// as it lands (partial results); a single category failing does not fail the
  /// whole search. Results are cached and only applied while [gen] is current.
  void _fetch(String query, String normalized, int gen,
      {required bool revalidate}) {
    if (_inFlight.contains(normalized)) return; // coalesce duplicates
    _inFlight.add(normalized);

    List<Track>? tracks;
    List<SavedAlbum>? albums;
    List<Artist>? artists;
    int pending = 3;
    bool loadingCleared = revalidate; // revalidate already shows cached content

    void clearLoadingOnFirst() {
      if (!loadingCleared && gen == _gen) {
        loadingCleared = true;
        _isLoading = false;
      }
    }

    void onSettled() {
      if (--pending > 0) return;
      final res = _SearchResults(
          tracks ?? const [], albums ?? const [], artists ?? const []);
      final anySuccess = tracks != null || albums != null || artists != null;
      // Only cache a COMPLETE result set — never cache a partial/empty result
      // caused by one category failing (it would later paint that category empty
      // with no way to retry). Partial failures are still shown live, just not
      // cached, so the next visit re-fetches.
      final allSuccess = tracks != null && albums != null && artists != null;
      if (allSuccess) _put(normalized, res);
      _inFlight.remove(normalized);

      if (gen == _gen) {
        // Current generation: per-category updates already painted the results.
        _isLoading = false;
        if (!revalidate && !anySuccess) {
          _error = "Couldn't load results";
        }
        _notify();
      } else if (anySuccess &&
          _normalize(_query) == normalized &&
          !_inFlight.contains(normalized)) {
        // Stale by generation, but it matches the CURRENT query and no fresher
        // fetch is running for it (it was coalesced) — apply it so the UI is
        // never stuck loading (covers a coalesced miss whose owner was a
        // background revalidate).
        _trackResults = res.tracks;
        _albumResults = res.albums;
        _artistResults = res.artists;
        _isLoading = false;
        _error = null;
        _notify();
      }
    }

    // Each category runs independently: it paints the moment it lands and a
    // single failure leaves that category null without failing the others.
    () async {
      try {
        final r = await _repository.searchTracks(query);
        tracks = r;
        if (gen == _gen) {
          _trackResults = r;
          clearLoadingOnFirst();
          _notify();
        }
      } catch (_) {/* category failed — stays null */} finally {
        onSettled();
      }
    }();

    () async {
      try {
        final r = await _repository.searchAlbums(query);
        albums = r;
        if (gen == _gen) {
          _albumResults = r;
          clearLoadingOnFirst();
          _notify();
        }
      } catch (_) {} finally {
        onSettled();
      }
    }();

    () async {
      try {
        final r = await _repository.searchArtists(query);
        artists = r;
        if (gen == _gen) {
          _artistResults = r;
          clearLoadingOnFirst();
          _notify();
        }
      } catch (_) {} finally {
        onSettled();
      }
    }();
  }

  // ── LRU cache helpers ───────────────────────────────────────────────────
  void _touch(String key) {
    final v = _cache.remove(key);
    if (v != null) _cache[key] = v; // move to most-recent
  }

  void _put(String key, _SearchResults value) {
    _cache.remove(key);
    _cache[key] = value;
    while (_cache.length > _maxCacheEntries) {
      _cache.remove(_cache.keys.first); // evict least-recently-used
    }
  }

  /// Force a fresh fetch of the current query (bypasses the cache-hit fast path).
  void retry() {
    final normalized = _normalize(_query);
    if (normalized.length < _minQueryLength) return;
    _debounceTimer?.cancel(); // drop any pending stale-generation fetch
    _gen++;
    _isLoading = true;
    _error = null;
    _notify();
    _fetch(_query, normalized, _gen, revalidate: false);
  }

  /// Guarded notify: in-flight category futures can resolve after the controller
  /// is disposed (e.g. the user leaves Search mid-search); never notify then.
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _debounceTimer?.cancel();
    super.dispose();
  }
}
