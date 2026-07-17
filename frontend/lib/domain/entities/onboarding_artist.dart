// lib/domain/entities/onboarding_artist.dart
//
// Immutable model for an artist shown during the Phase 3.2 onboarding flow.
//
// Two identifiers can be present:
//   • [id]       — Supabase catalog UUID (`artists.id`). Present for popular-grid
//                  artists and for search hits already in the catalog. NULL for
//                  freshly-discovered search hits (still being ingested).
//   • [deezerId] — always present on search hits; null on the popular grid.
//
// The onboarding RPC only accepts real catalog UUIDs, so a null-[id] search hit
// must be resolved to its UUID (via /v2/artists/deezer/{deezerId}) BEFORE it can
// be added to the selection. Every artist stored in the selection therefore has
// a non-null [id].
//
// Identity/equality uses [selectionKey]: the UUID when known, else the Deezer id.
// This lets the same underlying artist deduplicate across the popular grid and
// search results even before its UUID is resolved.

import 'package:flutter/foundation.dart';

@immutable
class OnboardingArtist {
  /// Supabase catalog UUID (`artists.id`). May be null for un-ingested search hits.
  final String? id;

  /// Deezer numeric id (always present on search hits; null on the popular grid).
  final int? deezerId;

  final String name;
  final String? imageUrl;

  const OnboardingArtist({
    required this.id,
    required this.name,
    this.deezerId,
    this.imageUrl,
  });

  /// True when this artist can go straight into the selection (has a real UUID).
  bool get hasCatalogId => id != null && id!.isNotEmpty;

  /// Stable identity: prefer the UUID, fall back to the Deezer id.
  String get selectionKey {
    if (hasCatalogId) return 'u:$id';
    if (deezerId != null) return 'd:$deezerId';
    return 'x:$name';
  }

  OnboardingArtist copyWith({String? id, int? deezerId, String? name, String? imageUrl}) =>
      OnboardingArtist(
        id: id ?? this.id,
        deezerId: deezerId ?? this.deezerId,
        name: name ?? this.name,
        imageUrl: imageUrl ?? this.imageUrl,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'deezerId': deezerId,
        'name': name,
        'imageUrl': imageUrl,
      };

  /// Parses a persisted SELECTION entry. Selection entries always carry a real
  /// UUID; returns null when [id] is missing so corrupt entries are skipped.
  static OnboardingArtist? fromJson(Map<String, dynamic> json) {
    final id = (json['id'] as String?)?.trim();
    if (id == null || id.isEmpty) return null;
    final name = (json['name'] as String?)?.trim();
    final deezer = json['deezerId'];
    return OnboardingArtist(
      id: id,
      deezerId: deezer is int ? deezer : int.tryParse('${deezer ?? ''}'),
      name: (name == null || name.isEmpty) ? 'Unknown artist' : name,
      imageUrl: (json['imageUrl'] as String?)?.trim(),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is OnboardingArtist && other.selectionKey == selectionKey);

  @override
  int get hashCode => selectionKey.hashCode;

  @override
  String toString() => 'OnboardingArtist(id:$id, deezer:$deezerId, $name)';
}
