// lib/data/sync/playlist_op.dart
//
// Phase 3.4.1 — a single queued playlist mutation for offline-first replay.
// Serialized to JSON in the pending-op journal. Each op carries the expected
// playlist version (when relevant) so a stale device cannot silently overwrite
// newer cloud state on reconnect.

enum PlaylistOpType {
  create,
  addTracks,
  removeTracks,
  saveOrder,
  updateMetadata,
  delete,
  setFollow,
  clone,
  addFromSource,
  invite,
  respond,
  leave,
  removeCollaborator,
  transfer,
}

class PlaylistOp {
  final String opId;
  final String userId;
  final String playlistId;
  final PlaylistOpType type;
  final DateTime createdAt;
  final int? expectedVersion;
  final Map<String, dynamic> payload;
  int retryCount;

  PlaylistOp({
    required this.opId,
    required this.userId,
    required this.playlistId,
    required this.type,
    required this.createdAt,
    this.expectedVersion,
    this.payload = const {},
    this.retryCount = 0,
  });

  Map<String, dynamic> toJson() => {
        'opId': opId,
        'userId': userId,
        'playlistId': playlistId,
        'type': type.name,
        'createdAt': createdAt.toIso8601String(),
        'expectedVersion': expectedVersion,
        'payload': payload,
        'retryCount': retryCount,
      };

  factory PlaylistOp.fromJson(Map<String, dynamic> j) => PlaylistOp(
        opId: j['opId']?.toString() ?? '',
        userId: j['userId']?.toString() ?? '',
        playlistId: j['playlistId']?.toString() ?? '',
        type: PlaylistOpType.values.firstWhere(
          (t) => t.name == j['type'],
          orElse: () => PlaylistOpType.addTracks,
        ),
        createdAt: DateTime.tryParse(j['createdAt']?.toString() ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        expectedVersion: j['expectedVersion'] is int
            ? j['expectedVersion'] as int
            : int.tryParse('${j['expectedVersion'] ?? ''}'),
        payload: (j['payload'] is Map)
            ? (j['payload'] as Map).cast<String, dynamic>()
            : const {},
        retryCount: j['retryCount'] is int ? j['retryCount'] as int : 0,
      );
}
