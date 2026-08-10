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

  /// Phase 3.4.7 — the opId of a queued `create` this operation depends on.
  ///
  /// A playlist created offline holds a LOCAL client UUID that Supabase has
  /// never seen. Any add/remove/reorder/metadata op queued before the create
  /// commits therefore targets an id the server cannot resolve, and must not be
  /// sent. Setting this makes the dependency explicit rather than relying on
  /// FIFO ordering, which compaction and partial failures can break.
  final String? dependsOnOpId;

  /// Set once the create this op depended on has been adopted, rewriting
  /// [playlistId] from the local UUID to the authoritative cloud UUID.
  bool adopted;

  int retryCount;

  PlaylistOp({
    required this.opId,
    required this.userId,
    required this.playlistId,
    required this.type,
    required this.createdAt,
    this.expectedVersion,
    this.payload = const {},
    this.dependsOnOpId,
    this.adopted = false,
    this.retryCount = 0,
  });

  /// A copy re-targeted at the authoritative cloud playlist id.
  PlaylistOp adoptCloudId(String cloudPlaylistId) => PlaylistOp(
        opId: opId,
        userId: userId,
        playlistId: cloudPlaylistId,
        type: type,
        createdAt: createdAt,
        expectedVersion: null, // the queued version is stale after adoption
        payload: payload,
        dependsOnOpId: null, // dependency satisfied
        adopted: true,
        retryCount: retryCount,
      );

  Map<String, dynamic> toJson() => {
        'opId': opId,
        'userId': userId,
        'playlistId': playlistId,
        'type': type.name,
        'createdAt': createdAt.toIso8601String(),
        'expectedVersion': expectedVersion,
        'payload': payload,
        'dependsOnOpId': dependsOnOpId,
        'adopted': adopted,
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
        dependsOnOpId: j['dependsOnOpId']?.toString(),
        adopted: j['adopted'] == true,
        retryCount: j['retryCount'] is int ? j['retryCount'] as int : 0,
      );
}
