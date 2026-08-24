// lib/data/sync/pending_track_ref.dart
//
// Phase 3.4.15 — the SOURCE IDENTITY of a track whose catalog UUID does not
// exist yet.
//
// WHY THIS TYPE EXISTS
// --------------------
// A queued playlist mutation used to be able to carry exactly one thing: a list
// of catalog UUIDs. That is fine for every track the catalog already knows, and
// impossible for the one case manual QA hit hardest — adding an Artist Top
// Track that has never been ingested, WHILE OFFLINE. Its UUID cannot be
// obtained (that needs the network) and must not be invented, so the intent
// could not be represented at all: the add failed locally with
// `UNRESOLVED_TRACK`, nothing was ever journaled, and reconnect had nothing to
// replay. The user saw "that song isn't available in Paax yet" and lost the row.
//
// So a queued op now carries INTENT, not just resolved ids: for each slot it
// could not resolve, the minimum stable source identity needed to ingest and
// resolve the track later.
//
// DELIBERATELY NOT A SECOND IDENTITY SYSTEM. These are exactly the fields the
// existing CatalogResolver path already consumes — `Track.id` (the YouTube
// playback id → `tracks.preferred_youtube_video_id`), `deezerTrackId` →
// `tracks.deezer_id`, and the Deezer ALBUM id, which is what actually triggers
// ingestion (`/v2/albums/deezer/{id}` upserts the whole album graph;
// `/v2/track/{id}` does not write at all). A ref round-trips to a [Track] so
// replay runs the SAME bounded resolve → ingest → re-resolve path an online add
// runs, rather than a parallel one.
//
// It is JSON-only (no Hive adapter, no in-memory handles) because it must
// survive the app being killed while offline.

import '../../domain/entities/track.dart';

class PendingTrackRef {
  /// Index of this track in the op's FULL intended id list, so an order-
  /// sensitive op (saveOrder) can splice resolved ids back into place.
  final int at;

  /// `Track.id` — the YouTube playback id when the app had one.
  final String playbackId;

  /// Deezer track id — the fast identity path.
  final String? deezerTrackId;

  /// Deezer ALBUM id — the only identity that can trigger ingestion.
  final String? albumDeezerId;

  /// Carried solely so a terminal failure can name the song.
  final String title;

  const PendingTrackRef({
    required this.at,
    required this.playbackId,
    this.deezerTrackId,
    this.albumDeezerId,
    this.title = '',
  });

  factory PendingTrackRef.fromTrack(Track t, int at) => PendingTrackRef(
        at: at,
        playbackId: t.id.trim(),
        deezerTrackId: _clean(t.deezerTrackId),
        albumDeezerId: _clean(t.albumId),
        title: t.title,
      );

  static String? _clean(String? v) {
    final s = (v ?? '').trim();
    return s.isEmpty ? null : s;
  }

  /// The [Track] shape the resolver already understands. Only identity matters
  /// here — metadata lives in the local cache, which is never overwritten by
  /// this path.
  Track toTrack() => Track(
        id: playbackId,
        title: title,
        artistName: '',
        albumId: albumDeezerId ?? '',
        albumTitle: '',
        artworkUrl: '',
        duration: 0,
        deezerTrackId: deezerTrackId,
      );

  /// True when replay has something it can actually act on.
  ///
  /// Ingestion needs a numeric Deezer ALBUM id; resolution alone needs a Deezer
  /// track id or a playback id. Anything with neither can never be completed by
  /// a later network call, so queuing it would be queuing a doomed op — it stays
  /// an immediate, honest failure exactly as before.
  bool get isIngestable =>
      int.tryParse(albumDeezerId ?? '') != null ||
      int.tryParse(deezerTrackId ?? '') != null ||
      playbackId.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'at': at,
        'playbackId': playbackId,
        if (deezerTrackId != null) 'deezerTrackId': deezerTrackId,
        if (albumDeezerId != null) 'albumDeezerId': albumDeezerId,
        'title': title,
      };

  factory PendingTrackRef.fromJson(Map<String, dynamic> j) => PendingTrackRef(
        at: j['at'] is int ? j['at'] as int : int.tryParse('${j['at']}') ?? 0,
        playbackId: j['playbackId']?.toString() ?? '',
        deezerTrackId: _clean(j['deezerTrackId']?.toString()),
        albumDeezerId: _clean(j['albumDeezerId']?.toString()),
        title: j['title']?.toString() ?? '',
      );

  /// Reads the `unresolved` payload slot of a queued op. Tolerant by design:
  /// a journal written by an older build simply has none.
  static List<PendingTrackRef> listFrom(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e is Map) PendingTrackRef.fromJson(e.cast<String, dynamic>())
    ]..sort((a, b) => a.at.compareTo(b.at));
  }

  static List<Map<String, dynamic>> listToJson(List<PendingTrackRef> refs) =>
      [for (final r in refs) r.toJson()];
}
