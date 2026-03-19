import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'media_resolver.dart';

// ---------------------------------------------------------------------------
// StreamCache — two-tier cache for resolved stream metadata
// ---------------------------------------------------------------------------
//
// Tier 1: in-memory HashMap  — zero-latency lookup, lost on app restart.
// Tier 2: Hive box            — survives restarts, bounded to 50 entries.
//
// TTL = 4 minutes.
// Also evicts entries whose CDN expiresAt has passed.
// Stores clientUsed + itag so repeat plays can pin the last-working client.
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

  Future<ResolvedStream?> get(String videoId) async {
    // Tier 1
    final mem = _mem[videoId];
    if (mem != null && !_isExpired(mem)) return mem;
    if (mem != null) _mem.remove(videoId);

    // Tier 2
    if (!Hive.isBoxOpen(kBoxName)) return null;
    final box = Hive.box(kBoxName);
    final raw = box.get(videoId) as Map?;
    if (raw == null) return null;

    final resolved = _deserialize(raw);
    if (_isExpired(resolved)) {
      await box.delete(videoId);
      return null;
    }
    _mem[videoId] = resolved;
    return resolved;
  }

  Future<void> put(String videoId, ResolvedStream resolved) async {
    _mem[videoId] = resolved;
    if (!Hive.isBoxOpen(kBoxName)) return;
    final box = Hive.box(kBoxName);
    await box.put(videoId, _serialize(resolved));
    if (box.length > kMaxHiveEntries) {
      await box.delete(box.keys.first);
    }
  }

  Future<void> invalidate(String videoId) async {
    _mem.remove(videoId);
    if (Hive.isBoxOpen(kBoxName)) {
      await Hive.box(kBoxName).delete(videoId);
    }
    debugPrint('[MEDIA CACHE] Invalidated $videoId');
  }

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
    'clientUsed': r.clientUsed,
    'itag':       r.itag,
  };

  ResolvedStream _deserialize(Map raw) => ResolvedStream(
    url:        raw['url']        as String,
    mimeType:   (raw['mimeType']  as String?) ?? 'audio/mp4',
    sourceType: raw['sourceType'] as String,
    resolvedAt: DateTime.parse(raw['resolvedAt'] as String),
    expiresAt:  (raw['expiresAt'] as int?)    ?? 0,
    clientUsed: (raw['clientUsed'] as String?) ?? '?',
    itag:       (raw['itag']       as int?)    ?? 0,
  );
}
