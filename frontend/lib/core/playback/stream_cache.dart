import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'media_resolver.dart';

// ---------------------------------------------------------------------------
// StreamCache — two-tier cache for resolved stream metadata
// ---------------------------------------------------------------------------
class StreamCache {
  StreamCache._();
  static final StreamCache instance = StreamCache._();

  static const Duration kTtl           = Duration(minutes: 4);
  static const int      kMaxHiveEntries = 50;
  static const String   kBoxName        = 'stream_candidates';

  final _mem = <String, ResolvedStream>{};

  Future<ResolvedStream?> get(String videoId) async {
    final mem = _mem[videoId];
    if (mem != null && !_isExpired(mem)) return mem;
    if (mem != null) _mem.remove(videoId);

    if (!Hive.isBoxOpen(kBoxName)) return null;
    final box = Hive.box(kBoxName);
    final raw = box.get(videoId) as Map?;
    if (raw == null) return null;

    final resolved = _deserialize(raw);
    if (_isExpired(resolved)) { await box.delete(videoId); return null; }
    _mem[videoId] = resolved;
    return resolved;
  }

  Future<void> put(String videoId, ResolvedStream resolved) async {
    _mem[videoId] = resolved;
    if (!Hive.isBoxOpen(kBoxName)) return;
    final box = Hive.box(kBoxName);
    await box.put(videoId, _serialize(resolved));
    if (box.length > kMaxHiveEntries) await box.delete(box.keys.first);
  }

  Future<void> invalidate(String videoId) async {
    _mem.remove(videoId);
    if (Hive.isBoxOpen(kBoxName)) await Hive.box(kBoxName).delete(videoId);
    debugPrint('[MEDIA CACHE] Invalidated $videoId');
  }

  Future<void> clear() async {
    _mem.clear();
    if (Hive.isBoxOpen(kBoxName)) await Hive.box(kBoxName).clear();
  }

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
    'candidates': r.candidates.map((c) => c.toJson()).toList(),
  };

  ResolvedStream _deserialize(Map raw) {
    final clientUsed = (raw['clientUsed'] as String?) ?? '?';
    final rawCandidates = (raw['candidates'] as List?)
        ?.map((c) => StreamCandidate.fromJson(Map<String, dynamic>.from(c as Map), clientUsed))
        .toList() ?? <StreamCandidate>[];

    return ResolvedStream(
      url:        raw['url']        as String,
      mimeType:   (raw['mimeType']  as String?) ?? 'audio/mp4',
      sourceType: raw['sourceType'] as String,
      resolvedAt: DateTime.parse(raw['resolvedAt'] as String),
      expiresAt:  (raw['expiresAt'] as int?)     ?? 0,
      clientUsed: clientUsed,
      itag:       (raw['itag']       as int?)     ?? 0,
      candidates: rawCandidates,
    );
  }
}
