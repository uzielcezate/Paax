import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'media_resolver.dart';

// ---------------------------------------------------------------------------
// StreamCache
// ---------------------------------------------------------------------------

/// Two-tier cache for resolved stream URLs.
///
/// Tier 1 — in-memory HashMap: zero-latency lookup, lost on app restart.
/// Tier 2 — Hive box `stream_candidates`: survives restarts, bounded to 50
///           entries, with TTL validation on read.
///
/// TTL = 4 minutes. Additionally, any entry whose CDN URL has passed its
/// expiresAt timestamp is evicted proactively.
class StreamCache {
  StreamCache._();

  static final StreamCache instance = StreamCache._();

  static const Duration kTtl           = Duration(minutes: 4);
  static const int      kMaxHiveEntries = 50;
  static const String   kBoxName        = 'stream_candidates';

  // Tier 1: in-memory
  final _mem = <String, ResolvedStream>{};

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Returns a non-expired [ResolvedStream] for [videoId], or null.
  Future<ResolvedStream?> get(String videoId) async {
    // Tier 1: memory
    final mem = _mem[videoId];
    if (mem != null && !_isExpired(mem)) return mem;
    if (mem != null) _mem.remove(videoId); // expired — evict

    // Tier 2: Hive
    if (!Hive.isBoxOpen(kBoxName)) return null;
    final box = Hive.box(kBoxName);
    final raw = box.get(videoId) as Map?;
    if (raw == null) return null;

    final resolved = _deserialize(raw);
    if (_isExpired(resolved)) {
      await box.delete(videoId);
      return null;
    }
    // Promote to memory tier
    _mem[videoId] = resolved;
    return resolved;
  }

  /// Write [resolved] for [videoId] to both tiers.
  Future<void> put(String videoId, ResolvedStream resolved) async {
    _mem[videoId] = resolved;

    if (!Hive.isBoxOpen(kBoxName)) return;
    final box = Hive.box(kBoxName);
    await box.put(videoId, _serialize(resolved));

    // Evict oldest if over the cap
    if (box.length > kMaxHiveEntries) {
      final oldest = box.keys.first;
      await box.delete(oldest);
    }
  }

  /// Remove the cache entry for [videoId] from both tiers.
  Future<void> invalidate(String videoId) async {
    _mem.remove(videoId);
    if (Hive.isBoxOpen(kBoxName)) {
      await Hive.box(kBoxName).delete(videoId);
    }
    debugPrint('[MEDIA CACHE] Invalidated $videoId');
  }

  /// Wipe all entries. Useful for debug / settings clear.
  Future<void> clear() async {
    _mem.clear();
    if (Hive.isBoxOpen(kBoxName)) {
      await Hive.box(kBoxName).clear();
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  bool _isExpired(ResolvedStream r) =>
      DateTime.now().difference(r.resolvedAt) > kTtl || r.isExpired;

  Map<String, dynamic> _serialize(ResolvedStream r) => {
        'url':        r.url,
        'mimeType':   r.mimeType,
        'sourceType': r.sourceType,
        'resolvedAt': r.resolvedAt.toIso8601String(),
        'expiresAt':  r.expiresAt,
      };

  ResolvedStream _deserialize(Map raw) => ResolvedStream(
        url:        raw['url']        as String,
        mimeType:   (raw['mimeType']  as String?) ?? 'audio/mp4',
        sourceType: raw['sourceType'] as String,
        resolvedAt: DateTime.parse(raw['resolvedAt'] as String),
        expiresAt:  (raw['expiresAt'] as int?)    ?? 0,
      );
}
