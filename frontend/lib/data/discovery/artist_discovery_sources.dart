// lib/data/discovery/artist_discovery_sources.dart
//
// Phase 3.3 §9 — concrete ArtistDiscoveryRepository implementations plus the
// factory that selects one from AppConfig.artistDiscoveryMode.
//
// Behavior is intentionally identical to the previous inline OnboardingController
// logic when the default `hybrid` mode is active: a Supabase "popular" grid,
// paax-api `/v2/find` search, and `/v2/artists/deezer/{id}` resolve-on-select.
// The Deezer/Supabase variants exist so the source can be swapped without
// touching the onboarding UI or controller.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/config/api_config.dart';
import '../../core/config/app_config.dart';
import '../../core/utils/artwork_resolver.dart';
import '../../domain/entities/onboarding_artist.dart';
import '../../domain/repositories/artist_discovery_repository.dart';

/// Parses the discovery mode string into the enum (defaults to hybrid).
ArtistDiscoveryMode artistDiscoveryModeFromConfig() {
  switch (AppConfig.artistDiscoveryMode.trim().toLowerCase()) {
    case 'supabase':
      return ArtistDiscoveryMode.supabase;
    case 'deezer':
      return ArtistDiscoveryMode.deezer;
    case 'hybrid':
    default:
      return ArtistDiscoveryMode.hybrid;
  }
}

/// Builds the configured discovery repository. Shared HTTP client + Supabase
/// client are injectable for tests.
ArtistDiscoveryRepository artistDiscoveryRepository({
  ArtistDiscoveryMode? mode,
  http.Client? httpClient,
  SupabaseClient? supabase,
}) {
  final api = PaaxCatalogDiscoveryApi(httpClient: httpClient);
  // Resolve the Supabase client lazily — the deezer source never needs it, so
  // it must not require an initialized Supabase instance (also aids testing).
  SupabaseClient sb() => supabase ?? Supabase.instance.client;
  switch (mode ?? artistDiscoveryModeFromConfig()) {
    case ArtistDiscoveryMode.supabase:
      return SupabaseArtistDiscoverySource(api: api, supabase: sb());
    case ArtistDiscoveryMode.deezer:
      return DeezerArtistDiscoverySource(api: api);
    case ArtistDiscoveryMode.hybrid:
      return HybridArtistDiscoverySource(api: api, supabase: sb());
  }
}

int? _asInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

/// Thin paax-api catalog client shared by the discovery sources: normalized
/// `/v2/find` search and `/v2/artists/deezer/{id}` resolve. Both go through
/// paax-api (Supabase-first, Deezer discovery + ingestion behind it).
class PaaxCatalogDiscoveryApi {
  final http.Client _http;
  PaaxCatalogDiscoveryApi({http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  Future<List<OnboardingArtist>> findArtists(String query, {int limit = 20}) async {
    final uri = Uri.parse('${ApiConfig.baseUrl}/v2/find').replace(
      queryParameters: {'type': 'artists', 'q': query, 'limit': '$limit'},
    );
    final res = await _http.get(uri).timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) {
      throw http.ClientException('find failed: ${res.statusCode}', uri);
    }
    return _parseArtists(json.decode(utf8.decode(res.bodyBytes)));
  }

  /// Ingest-on-miss resolve. The top-level `id` is the Supabase UUID.
  Future<OnboardingArtist?> resolveByDeezerId(int deezerId,
      {OnboardingArtist? fallback}) async {
    final uri = Uri.parse('${ApiConfig.baseUrl}/v2/artists/deezer/$deezerId');
    final res = await _http.get(uri).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) return null;
    final decoded = json.decode(utf8.decode(res.bodyBytes));
    Map<String, dynamic>? map;
    if (decoded is Map<String, dynamic>) {
      final inner = decoded['data'];
      map = inner is Map<String, dynamic> ? inner : decoded;
    }
    if (map == null) return null;
    final rawId = map['id'];
    final id = (rawId is String && rawId.trim().isNotEmpty) ? rawId.trim() : null;
    if (id == null) return null;
    final name = (map['name'] as String?)?.trim();
    final image = ArtworkResolver.artist(map);
    return OnboardingArtist(
      id: id,
      deezerId: deezerId,
      name: (name == null || name.isEmpty) ? (fallback?.name ?? 'Unknown artist') : name,
      imageUrl: image.isNotEmpty ? image : fallback?.imageUrl,
    );
  }

  /// Defensive parse: a bare list or wrapped under data/artists/results/items.
  /// Each item: `id` (uuid|null), `deezerId` (int), `name`, image (any key).
  /// Deduped by deezerId (always present), falling back to uuid.
  List<OnboardingArtist> _parseArtists(dynamic decoded) {
    List<dynamic>? items;
    if (decoded is List) {
      items = decoded;
    } else if (decoded is Map<String, dynamic>) {
      for (final key in const ['items', 'data', 'artists', 'results']) {
        final v = decoded[key];
        if (v is List) {
          items = v;
          break;
        }
      }
    }
    if (items == null) return const [];

    final out = <OnboardingArtist>[];
    final seen = <String>{};
    for (final item in items) {
      if (item is! Map) continue;
      final map = item.cast<String, dynamic>();
      final rawId = map['id'];
      final id = (rawId is String && rawId.trim().isNotEmpty) ? rawId.trim() : null;
      final deezerId = _asInt(map['deezerId'] ?? map['deezer_id']);
      if (id == null && deezerId == null) continue;
      final dedupKey = deezerId != null ? 'd:$deezerId' : 'u:$id';
      if (!seen.add(dedupKey)) continue;
      final name = (map['name'] as String?)?.trim();
      final image = ArtworkResolver.artist(map);
      out.add(OnboardingArtist(
        id: id,
        deezerId: deezerId,
        name: (name == null || name.isEmpty) ? 'Unknown artist' : name,
        imageUrl: image.isNotEmpty ? image : null,
      ));
    }
    return out;
  }

  void close() => _http.close();
}

/// Reads the "popular" grid straight from the public Supabase `artists` table,
/// ordered by platform follower count. Search/resolve go through paax-api.
class SupabaseArtistDiscoverySource implements ArtistDiscoveryRepository {
  final PaaxCatalogDiscoveryApi api;
  final SupabaseClient supabase;
  SupabaseArtistDiscoverySource({required this.api, required this.supabase});

  @override
  Future<List<OnboardingArtist>> popular({int limit = 30}) async {
    final rows = await supabase
        .from('artists')
        .select('id,name,image_cached_url,image_original_url,platform_followers_count')
        .order('platform_followers_count', ascending: false)
        .limit(limit);
    final list = <OnboardingArtist>[];
    for (final row in (rows as List)) {
      final map = row as Map<String, dynamic>;
      final id = (map['id'] as String?)?.trim();
      if (id == null || id.isEmpty) continue;
      final name = (map['name'] as String?)?.trim();
      final image = ArtworkResolver.artist(map);
      list.add(OnboardingArtist(
        id: id,
        name: (name == null || name.isEmpty) ? 'Unknown artist' : name,
        imageUrl: image.isNotEmpty ? image : null,
      ));
    }
    return list;
  }

  @override
  Future<List<OnboardingArtist>> search(String query, {int limit = 20}) =>
      api.findArtists(query, limit: limit);

  @override
  Future<OnboardingArtist?> resolveByDeezerId(int deezerId,
          {OnboardingArtist? fallback}) =>
      api.resolveByDeezerId(deezerId, fallback: fallback);
}

/// Deezer-first discovery: "popular" candidates come from a broad paax-api
/// search (Deezer-backed) rather than the still-sparse Supabase table.
class DeezerArtistDiscoverySource implements ArtistDiscoveryRepository {
  final PaaxCatalogDiscoveryApi api;
  DeezerArtistDiscoverySource({required this.api});

  @override
  Future<List<OnboardingArtist>> popular({int limit = 30}) =>
      // A broad seed query surfaces well-known artists via Deezer discovery.
      api.findArtists('top', limit: limit);

  @override
  Future<List<OnboardingArtist>> search(String query, {int limit = 20}) =>
      api.findArtists(query, limit: limit);

  @override
  Future<OnboardingArtist?> resolveByDeezerId(int deezerId,
          {OnboardingArtist? fallback}) =>
      api.resolveByDeezerId(deezerId, fallback: fallback);
}

/// CURRENT PRODUCTION default: Supabase "popular" grid with a Deezer fallback
/// when the catalog is empty; paax-api search + resolve. Identical to the
/// previous inline onboarding behavior.
class HybridArtistDiscoverySource implements ArtistDiscoveryRepository {
  final PaaxCatalogDiscoveryApi api;
  final SupabaseClient supabase;
  late final SupabaseArtistDiscoverySource _supabaseSource =
      SupabaseArtistDiscoverySource(api: api, supabase: supabase);
  late final DeezerArtistDiscoverySource _deezerSource =
      DeezerArtistDiscoverySource(api: api);

  HybridArtistDiscoverySource({required this.api, required this.supabase});

  @override
  Future<List<OnboardingArtist>> popular({int limit = 30}) async {
    final local = await _supabaseSource.popular(limit: limit);
    if (local.isNotEmpty) return local;
    // Catalog still sparse — fall back to Deezer discovery so the grid isn't
    // empty for a brand-new deployment.
    try {
      return await _deezerSource.popular(limit: limit);
    } catch (_) {
      return local; // empty, but the UI shows its empty state gracefully
    }
  }

  @override
  Future<List<OnboardingArtist>> search(String query, {int limit = 20}) =>
      api.findArtists(query, limit: limit);

  @override
  Future<OnboardingArtist?> resolveByDeezerId(int deezerId,
          {OnboardingArtist? fallback}) =>
      api.resolveByDeezerId(deezerId, fallback: fallback);
}
