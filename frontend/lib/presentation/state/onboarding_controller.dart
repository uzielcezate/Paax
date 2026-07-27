// lib/presentation/state/onboarding_controller.dart
//
// State for the Phase 3.2 "real" artist-onboarding flow.
//
// Sources (both ultimately yield Supabase catalog UUIDs — never Deezer ids get
// sent to the RPC):
//   • POPULAR grid → one batched read of the public `artists` table (real UUIDs).
//   • SEARCH       → paax-api normalized search `GET /v2/find?type=artists`.
//       Each hit has { id: <uuid|null>, deezerId: <int>, name, imageUrl }.
//       `id` is null for freshly-discovered artists (ingested in the background),
//       so selecting one lazily resolves its UUID via
//       `GET /v2/artists/deezer/{deezerId}` before it enters the selection.
//
// Completion is atomic via `complete_artist_onboarding(p_artist_ids uuid[])`,
// which requires >= 5 unique existing artist UUIDs and flips
// `profiles.onboarding_completed`. Every id sent is guaranteed non-null.
//
// This controller never touches routing — the screen re-resolves AuthController
// after a successful complete().

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/discovery/artist_discovery_sources.dart';
import '../../data/local/onboarding_selection_store.dart';
import '../../domain/entities/onboarding_artist.dart';
import '../../domain/repositories/artist_discovery_repository.dart';

class OnboardingController extends ChangeNotifier {
  /// Minimum artists the user must select to complete onboarding.
  static const int minSelection = 5;

  static const Duration _debounce = Duration(milliseconds: 350);

  final SupabaseClient _supabase;
  final OnboardingSelectionStore _store;

  /// Where onboarding candidates come from (Phase 3.3 §9). Defaults to the
  /// AppConfig-selected source (hybrid) so the UI stays source-agnostic.
  final ArtistDiscoveryRepository _discovery;

  OnboardingController({
    SupabaseClient? supabase,
    http.Client? httpClient,
    OnboardingSelectionStore? store,
    ArtistDiscoveryRepository? discovery,
    bool autoStart = true,
  })  : _supabase = supabase ?? Supabase.instance.client,
        _store = store ?? OnboardingSelectionStore(),
        _discovery = discovery ??
            artistDiscoveryRepository(httpClient: httpClient, supabase: supabase) {
    if (autoStart) {
      // ignore: discarded_futures
      _init();
    }
  }

  // ── state ──────────────────────────────────────────────────────────────────

  List<OnboardingArtist> _popular = const [];
  List<OnboardingArtist> _searchResults = const [];

  /// Selected artists — invariant: every entry has a non-null catalog UUID.
  final Set<OnboardingArtist> _selected = <OnboardingArtist>{};

  /// Deezer ids currently being resolved to a UUID (for per-card spinners).
  final Set<int> _resolving = <int>{};

  String _query = '';

  bool _loadingPopular = false;
  bool _searching = false;
  bool _submitting = false;
  bool _disposed = false;

  String? _error; // popular/init error
  String? _searchError;
  String? _submitError;

  Timer? _debounceTimer;
  int _searchToken = 0; // stale-request cancellation

  // ── getters ────────────────────────────────────────────────────────────────

  List<OnboardingArtist> get popular => _popular;
  List<OnboardingArtist> get searchResults => _searchResults;
  List<OnboardingArtist> get selected => List.unmodifiable(_selected);
  int get selectedCount => _selected.length;
  String get query => _query;

  bool get isLoadingPopular => _loadingPopular;
  bool get isSearching => _searching;
  bool get isSubmitting => _submitting;

  String? get error => _error;
  String? get searchError => _searchError;
  String? get submitError => _submitError;

  bool get isSearchMode => _query.trim().isNotEmpty;
  bool get canComplete => _selected.length >= minSelection;
  int get remaining => (minSelection - _selected.length).clamp(0, minSelection);

  /// Selection state, matching by UUID when known else by Deezer id — so a
  /// resolved-and-selected artist still shows selected on its search card.
  bool isSelected(OnboardingArtist a) {
    if (a.hasCatalogId && _selected.any((s) => s.id == a.id)) return true;
    if (a.deezerId != null &&
        _selected.any((s) => s.deezerId != null && s.deezerId == a.deezerId)) {
      return true;
    }
    return false;
  }

  /// Whether a search card is mid-resolve (waiting on its UUID).
  bool isResolving(OnboardingArtist a) =>
      a.deezerId != null && _resolving.contains(a.deezerId);

  /// The artists to show right now: search results when a query is active,
  /// otherwise the popular grid.
  List<OnboardingArtist> get visibleArtists =>
      isSearchMode ? _searchResults : _popular;

  // ── lifecycle ────────────────────────────────────────────────────────────────

  Future<void> _init() async {
    // Restore any in-progress selection first so it survives a mid-flow restart.
    try {
      final restored = await _store.load();
      _selected.addAll(restored);
      if (restored.isNotEmpty) _safeNotify();
    } catch (_) {/* corrupt-safe: ignore */}
    await loadPopular();
  }

  // ── popular grid (single batched query) ──────────────────────────────────────

  Future<void> loadPopular() async {
    _loadingPopular = true;
    _error = null;
    _safeNotify();
    try {
      _popular = await _discovery.popular();
      _error = null;
    } catch (e) {
      _error = _friendlyLoadError(e);
    } finally {
      _loadingPopular = false;
      _safeNotify();
    }
  }

  // ── search (debounced + stale-request cancellation) ──────────────────────────

  void search(String raw) {
    final q = raw.trim();
    _query = raw;
    _searchError = null;

    _debounceTimer?.cancel();

    if (q.isEmpty) {
      // Leaving search mode — show the popular grid again.
      _searchResults = const [];
      _searching = false;
      _searchToken++; // invalidate any in-flight request
      _safeNotify();
      return;
    }

    // Show searching state immediately; run the request after the debounce.
    _searching = true;
    _safeNotify();

    _debounceTimer = Timer(_debounce, () {
      // ignore: discarded_futures
      _runSearch(q);
    });
  }

  Future<void> _runSearch(String q) async {
    final token = ++_searchToken;
    try {
      final parsed = await _discovery.search(q);

      // A newer query superseded this one — discard the result entirely.
      if (token != _searchToken || _disposed) return;
      _searchResults = parsed;
      _searchError = null;
      _searching = false;
      _safeNotify();
    } catch (e) {
      if (token != _searchToken || _disposed) return;
      _searchResults = const [];
      _searchError = _friendlyLoadError(e);
      _searching = false;
      _safeNotify();
    }
  }

  // ── selection ────────────────────────────────────────────────────────────────

  /// Toggles [artist] in the selection. Returns an error message if a fresh
  /// (null-UUID) artist could not be resolved, otherwise null.
  Future<String?> toggle(OnboardingArtist artist) async {
    _submitError = null;

    // Already selected → remove the matching entry (match by uuid or deezerId).
    if (isSelected(artist)) {
      _selected.removeWhere((s) =>
          (artist.hasCatalogId && s.id == artist.id) ||
          (artist.deezerId != null && s.deezerId == artist.deezerId));
      _safeNotify();
      _persist();
      return null;
    }

    // Selecting: already has a UUID → add directly.
    if (artist.hasCatalogId) {
      _selected.add(artist);
      _safeNotify();
      _persist();
      return null;
    }

    // Selecting a fresh artist → resolve its UUID first.
    final deezerId = artist.deezerId;
    if (deezerId == null) {
      return "Couldn't add that artist. Please try again.";
    }
    if (_resolving.contains(deezerId)) return null; // already resolving
    _resolving.add(deezerId);
    _safeNotify();
    try {
      final resolved =
          await _discovery.resolveByDeezerId(deezerId, fallback: artist);
      if (_disposed) return null;
      if (resolved == null || !resolved.hasCatalogId) {
        return "Couldn't add that artist. Please try again.";
      }
      // Guard against a double-tap having selected it while we awaited.
      if (!_selected.any((s) => s.id == resolved.id)) {
        _selected.add(resolved);
        _persist();
      }
      return null;
    } catch (e) {
      return _looksLikeNetwork(e)
          ? "Can't reach Paax right now. Check your connection."
          : "Couldn't add that artist. Please try again.";
    } finally {
      _resolving.remove(deezerId);
      _safeNotify();
    }
  }

  void _persist() {
    // Cheap, fire-and-forget; the store writer is corrupt-safe.
    // ignore: discarded_futures
    _store.save(_selected.toList());
  }

  // ── completion (atomic RPC) ──────────────────────────────────────────────────

  Future<bool> complete() async {
    if (_submitting) return false; // guard double submit
    // Only real catalog UUIDs (invariant already holds, but be defensive).
    final ids = _selected
        .map((a) => a.id)
        .whereType<String>()
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList();
    if (ids.length < minSelection) {
      _submitError = 'Pick at least $minSelection artists to continue.';
      _safeNotify();
      return false;
    }
    _submitting = true;
    _submitError = null;
    _safeNotify();
    try {
      await _supabase.rpc(
        'complete_artist_onboarding',
        params: {'p_artist_ids': ids},
      );
      // Success: onboarding_completed is now flipped server-side. Drop the
      // locally-persisted in-progress selection.
      try {
        await _store.clear();
      } catch (_) {/* best effort */}
      _submitting = false;
      _safeNotify();
      return true;
    } catch (e) {
      _submitError = _friendlySubmitError(e);
      _submitting = false;
      _safeNotify();
      return false;
    }
  }

  // ── error mapping ────────────────────────────────────────────────────────────

  String _friendlyLoadError(Object e) {
    if (_looksLikeNetwork(e)) {
      return "Can't reach Paax right now. Check your connection and try again.";
    }
    return 'Something went wrong. Please try again.';
  }

  String _friendlySubmitError(Object e) {
    if (_looksLikeNetwork(e)) {
      return "Can't reach Paax right now. Check your connection and try again.";
    }
    final msg = e.toString().toLowerCase();
    if (msg.contains('at least') || msg.contains('minimum')) {
      return 'Please pick at least $minSelection artists to continue.';
    }
    return "Couldn't save your picks. Please try again.";
  }

  bool _looksLikeNetwork(Object e) {
    if (e is TimeoutException || e is http.ClientException) return true;
    final msg = e.toString().toLowerCase();
    return msg.contains('socket') ||
        msg.contains('timeout') ||
        msg.contains('timed out') ||
        msg.contains('network') ||
        msg.contains('failed host lookup') ||
        msg.contains('connection');
  }

  // ── internals ────────────────────────────────────────────────────────────────

  void _safeNotify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _debounceTimer?.cancel();
    _searchToken++; // invalidate in-flight searches
    super.dispose();
  }
}
