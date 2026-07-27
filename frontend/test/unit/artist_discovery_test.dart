// test/unit/artist_discovery_test.dart
//
// Phase 3.3 §9 — the onboarding discovery source is a replaceable abstraction.
// These cover the paax-api catalog client parsing/resolve and that the factory
// selects the right source per mode (so a future Supabase-first swap needs no
// UI change).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:beaty/data/discovery/artist_discovery_sources.dart';
import 'package:beaty/domain/repositories/artist_discovery_repository.dart';

http.Client _mock(Map<String, Object> routes) {
  return MockClient((req) async {
    final path = req.url.path;
    for (final entry in routes.entries) {
      if (path.contains(entry.key)) {
        return http.Response(json.encode(entry.value), 200,
            headers: {'content-type': 'application/json'});
      }
    }
    return http.Response('not found', 404);
  });
}

void main() {
  group('PaaxCatalogDiscoveryApi.findArtists', () {
    test('parses normalized /v2/find items with deezerId + imageUrl', () async {
      final api = PaaxCatalogDiscoveryApi(
        httpClient: _mock({
          '/v2/find': {
            'type': 'artists',
            'items': [
              {'id': 'uuid-1', 'deezerId': 111, 'name': 'Young Miko', 'imageUrl': 'http://a'},
              {'id': null, 'deezerId': 222, 'name': 'Feid', 'imageUrl': 'http://b'},
            ],
          },
        }),
      );
      final res = await api.findArtists('mi');
      expect(res.length, 2);
      expect(res[0].id, 'uuid-1');
      expect(res[0].deezerId, 111);
      expect(res[0].imageUrl, 'http://a');
      expect(res[1].id, isNull); // fresh discovery, UUID resolved on select
      expect(res[1].deezerId, 222);
    });

    test('dedupes by deezerId', () async {
      final api = PaaxCatalogDiscoveryApi(
        httpClient: _mock({
          '/v2/find': {
            'items': [
              {'id': 'u1', 'deezerId': 5, 'name': 'A', 'imageUrl': 'x'},
              {'id': 'u2', 'deezerId': 5, 'name': 'A dup', 'imageUrl': 'y'},
            ],
          },
        }),
      );
      final res = await api.findArtists('a');
      expect(res.length, 1);
    });
  });

  group('PaaxCatalogDiscoveryApi.resolveByDeezerId', () {
    test('returns the canonical UUID from /v2/artists/deezer/{id}', () async {
      final api = PaaxCatalogDiscoveryApi(
        httpClient: _mock({
          '/v2/artists/deezer/111': {
            'id': 'uuid-canonical',
            'deezerId': 111,
            'name': 'Young Miko',
            'imageUrl': 'http://img',
          },
        }),
      );
      final r = await api.resolveByDeezerId(111);
      expect(r, isNotNull);
      expect(r!.id, 'uuid-canonical');
      expect(r.hasCatalogId, isTrue);
      expect(r.deezerId, 111);
    });

    test('returns null on 404 (not resolvable)', () async {
      final api = PaaxCatalogDiscoveryApi(httpClient: _mock({}));
      expect(await api.resolveByDeezerId(999), isNull);
    });
  });

  group('factory selects the configured source', () {
    test('mode → concrete type', () {
      expect(
        artistDiscoveryRepository(mode: ArtistDiscoveryMode.deezer, httpClient: _mock({})),
        isA<DeezerArtistDiscoverySource>(),
      );
      // supabase/hybrid need a SupabaseClient; just assert deezer here to avoid
      // constructing Supabase in a unit test. Mode parsing is covered below.
    });

    test('mode string parsing defaults to hybrid', () {
      // Default compile-time value is "hybrid".
      expect(artistDiscoveryModeFromConfig(), ArtistDiscoveryMode.hybrid);
    });
  });

  group('DeezerArtistDiscoverySource', () {
    test('popular + search both go through /v2/find', () async {
      final src = DeezerArtistDiscoverySource(
        api: PaaxCatalogDiscoveryApi(
          httpClient: _mock({
            '/v2/find': {
              'items': [
                {'id': 'u', 'deezerId': 1, 'name': 'X', 'imageUrl': 'i'},
              ],
            },
          }),
        ),
      );
      expect((await src.popular()).length, 1);
      expect((await src.search('x')).length, 1);
    });
  });
}
