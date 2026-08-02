// test/unit/playlist_activity_test.dart — Phase 3.4.1 activity summary + time.

import 'package:flutter_test/flutter_test.dart';
import 'package:beaty/domain/entities/playlist_activity.dart';

PlaylistActivity _a(String type, Map<String, dynamic> meta, {String? actor}) => PlaylistActivity(
      id: 'x', playlistId: 'p', eventType: type,
      createdAt: DateTime(2026, 1, 1), metadata: meta, actorUsername: actor);

void main() {
  group('headline', () {
    test('tracks added singular/plural', () {
      expect(ActivitySummary.headline(_a('tracks_added', {'count': 3}, actor: 'bren_arteaga')),
          'bren_arteaga added 3 songs');
      expect(ActivitySummary.headline(_a('tracks_added', {'count': 1}, actor: 'iamleizu')),
          'iamleizu added 1 song');
    });
    test('reorder', () {
      expect(ActivitySummary.headline(_a('tracks_reordered', {'count': 6}, actor: 'iamleizu')),
          'iamleizu reordered 6 songs');
    });
    test('visibility change', () {
      expect(
        ActivitySummary.headline(_a('visibility_changed', {'from': 'private', 'to': 'public'}, actor: 'iamleizu')),
        'iamleizu changed the playlist visibility from Private to Public',
      );
    });
    test('rename', () {
      expect(ActivitySummary.headline(_a('playlist_renamed', {'to': 'Summer'}, actor: 'iamleizu')),
          'iamleizu renamed the playlist to "Summer"');
    });
    test('fallback actor when username missing', () {
      expect(ActivitySummary.headline(_a('tracks_added', {'count': 2}), actorFallback: 'Someone'),
          'Someone added 2 songs');
    });
    test('never leaks raw ids for ownership transfer', () {
      final h = ActivitySummary.headline(_a('ownership_transferred', {'to': 'uuid-123'}));
      expect(h.contains('uuid-123'), isFalse);
      expect(h, 'Ownership was transferred');
    });
  });

  group('detail lines', () {
    test('shows track titles, bounded, with overflow count', () {
      final tracks = List.generate(10, (i) => {'id': 'i$i', 'title': 'Song $i'});
      final a = _a('tracks_added', {'count': 10, 'tracks': tracks});
      final lines = ActivitySummary.detailLines(a);
      expect(lines.length, ActivitySummary.maxDetailLines);
      expect(lines.first, 'Song 0');
      expect(ActivitySummary.overflowCount(a), 10 - ActivitySummary.maxDetailLines);
    });
    test('no detail lines for non-track events', () {
      expect(ActivitySummary.detailLines(_a('visibility_changed', {'from': 'a', 'to': 'b'})), isEmpty);
    });
  });

  group('relative time', () {
    final base = DateTime(2026, 6, 1, 12, 0, 0);
    test('just now / minutes / hours / days', () {
      expect(ActivitySummary.relativeTime(base, base), 'just now');
      expect(ActivitySummary.relativeTime(base.subtract(const Duration(minutes: 1)), base), '1 minute ago');
      expect(ActivitySummary.relativeTime(base.subtract(const Duration(minutes: 2)), base), '2 minutes ago');
      expect(ActivitySummary.relativeTime(base.subtract(const Duration(hours: 2)), base), '2 hours ago');
      expect(ActivitySummary.relativeTime(base.subtract(const Duration(days: 3)), base), '3 days ago');
    });
    test('future time clamps to just now', () {
      expect(ActivitySummary.relativeTime(base.add(const Duration(minutes: 5)), base), 'just now');
    });
  });
}
