// lib/presentation/state/playlist_activity_timeline_controller.dart
//
// Phase 3.4.1.2A — state for the paginated, realtime activity timeline shown
// from "Last modified…". Loads newest-first pages (keyset by created_at),
// appends realtime events into the head (deduped by id), and exposes the
// presentation-grouped rows. The DB is authoritative and already logs every
// event; this never writes. Subscription is torn down on dispose / account
// switch (the shared PlaylistRealtimeService handles account teardown).

import 'package:flutter/foundation.dart';

import '../../data/remote/playlist_realtime_service.dart';
import '../../domain/entities/playlist_activity.dart';
import '../../domain/entities/playlist_activity_grouping.dart';

/// Fetch one newest-first page of activity, optionally older than [before].
typedef ActivityPageFetcher = Future<List<PlaylistActivity>> Function(
    {int limit, DateTime? before});

class PlaylistActivityTimelineController extends ChangeNotifier {
  final ActivityPageFetcher _fetchPage;
  final PlaylistRealtimeService _realtime;
  final String playlistId;
  final int pageSize;

  PlaylistActivityTimelineController({
    required ActivityPageFetcher fetchPage,
    required PlaylistRealtimeService realtime,
    required this.playlistId,
    this.pageSize = 30,
  })  : _fetchPage = fetchPage,
        _realtime = realtime;

  final List<PlaylistActivity> _raw = []; // newest-first, deduped by id
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = true;
  bool _error = false;
  bool _subscribed = false;

  bool get isLoading => _loading;
  bool get isLoadingMore => _loadingMore;
  bool get hasMore => _hasMore;
  bool get hasError => _error;
  bool get isEmpty => _raw.isEmpty;

  /// Presentation rows: deduped by id, then 5-minute same-actor/type grouped.
  List<PlaylistActivity> get rows =>
      ActivityGrouper.group(ActivityGrouper.dedupeById(_raw));

  Future<void> load() async {
    _loading = true;
    _error = false;
    notifyListeners();
    try {
      final page = await _fetchPage(limit: pageSize);
      _raw
        ..clear()
        ..addAll(page);
      _hasMore = page.length >= pageSize;
    } catch (e, st) {
      // Non-release: surface the real Supabase/PostgREST/RPC error (message,
      // code) instead of swallowing it behind the generic UI failure state.
      if (kDebugMode) {
        debugPrint('[PlaylistActivity] load($playlistId) failed: $e');
        debugPrintStack(stackTrace: st, label: '[PlaylistActivity]');
      }
      _error = _raw.isEmpty; // release: safe user-facing "Couldn't load activity"
    }
    _loading = false;
    notifyListeners();
    _ensureSubscribed();
  }

  Future<void> loadMore() async {
    if (_loadingMore || !_hasMore || _raw.isEmpty) return;
    _loadingMore = true;
    notifyListeners();
    try {
      final oldest = _raw.last.createdAt;
      final page = await _fetchPage(limit: pageSize, before: oldest);
      final seen = _raw.map((e) => e.id).toSet();
      _raw.addAll(page.where((e) => !seen.contains(e.id)));
      _hasMore = page.length >= pageSize;
    } catch (e) {
      if (kDebugMode) debugPrint('[PlaylistActivity] loadMore($playlistId) failed: $e');
      /* keep what we have */
    }
    _loadingMore = false;
    notifyListeners();
  }

  Future<void> refresh() => load();

  void _ensureSubscribed() {
    if (_subscribed) return;
    _subscribed = true;
    _realtime.addListener(playlistId, _onRealtime);
    // ignore: discarded_futures
    _realtime.subscribe(playlistId);
  }

  void _onRealtime(PlaylistRealtimeEvent e) {
    if (e.kind != 'activity' || e.record == null) return;
    // Fetch the newest page to pick up the just-committed event with its actor
    // join, then merge into the head (dedupe by id keeps ordering stable).
    // ignore: discarded_futures
    _mergeNewest();
  }

  Future<void> _mergeNewest() async {
    try {
      final page = await _fetchPage(limit: pageSize);
      final seen = _raw.map((e) => e.id).toSet();
      final fresh = page.where((e) => !seen.contains(e.id)).toList();
      if (fresh.isEmpty) return;
      _raw.insertAll(0, fresh);
      _raw.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      notifyListeners();
    } catch (e) {
      if (kDebugMode) debugPrint('[PlaylistActivity] realtime merge($playlistId) failed: $e');
    }
  }

  @override
  void dispose() {
    if (_subscribed) {
      _realtime.removeListener(playlistId, _onRealtime);
      // ignore: discarded_futures
      _realtime.unsubscribe(playlistId);
    }
    super.dispose();
  }
}
