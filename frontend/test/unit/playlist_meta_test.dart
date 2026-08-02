// test/unit/playlist_meta_test.dart
//
// Phase 3.3.6 — playlist metadata formatter + domain projection.

import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:beaty/core/utils/playlist_meta.dart';
import 'package:beaty/domain/entities/playlist.dart';
import 'package:beaty/domain/entities/playlist_contributors.dart';
import 'package:beaty/domain/entities/track.dart';

Track _t(String id, {int duration = 180}) => Track(
      id: id,
      title: 't$id',
      artistName: 'a',
      albumId: '',
      albumTitle: '',
      artworkUrl: '',
      duration: duration,
    );

Playlist _playlist({
  List<Track>? tracks,
  String? ownerId,
  String? ownerUsername,
  String? visibility,
  bool? isCollaborative,
  List<Map<String, dynamic>>? collaborators,
}) =>
    Playlist(
      id: 'p1',
      name: 'Bad Bunny',
      tracks: tracks ?? [],
      createdAt: DateTime(2026, 1, 1),
      ownerId: ownerId,
      ownerUsername: ownerUsername,
      visibility: visibility,
      isCollaborative: isCollaborative,
      collaboratorsJson: collaborators == null ? null : jsonEncode(collaborators),
    );

void main() {
  group('song count', () {
    test('singular/plural', () {
      expect(PlaylistMeta.songCount(0), '0 songs');
      expect(PlaylistMeta.songCount(1), '1 song');
      expect(PlaylistMeta.songCount(2), '2 songs');
      expect(PlaylistMeta.songCount(24), '24 songs');
    });
  });

  group('duration', () {
    test('< 60 min → "N min"', () {
      expect(PlaylistMeta.duration(22 * 60), '22 min');
      expect(PlaylistMeta.duration(3 * 60), '3 min');
    });
    test('>= 60 min → "H hr M min"', () {
      expect(PlaylistMeta.duration(62 * 60), '1 hr 2 min');
      expect(PlaylistMeta.duration(78 * 60), '1 hr 18 min');
    });
    test('zero/negative → null (segment omitted)', () {
      expect(PlaylistMeta.duration(0), isNull);
      expect(PlaylistMeta.duration(-5), isNull);
    });
  });

  group('visibility label — independent of collaboration', () {
    test('public/private', () {
      expect(PlaylistMeta.visibilityLabel('public'), 'Public');
      expect(PlaylistMeta.visibilityLabel('private'), 'Private');
      expect(PlaylistMeta.visibilityLabel(null), 'Private');
    });
  });

  group('detail line (Line 3)', () {
    test('exact format with duration', () {
      expect(
        PlaylistMeta.detailLine(
            visibility: 'private', trackCount: 6, totalDurationSeconds: 22 * 60),
        'Private · 6 songs · 22 min',
      );
      expect(
        PlaylistMeta.detailLine(
            visibility: 'public', trackCount: 1, totalDurationSeconds: 3 * 60),
        'Public · 1 song · 3 min',
      );
      expect(
        PlaylistMeta.detailLine(
            visibility: 'private', trackCount: 24, totalDurationSeconds: 78 * 60),
        'Private · 24 songs · 1 hr 18 min',
      );
    });
    test('omits duration segment when zero', () {
      expect(
        PlaylistMeta.detailLine(
            visibility: 'private', trackCount: 0, totalDurationSeconds: 0),
        'Private · 0 songs',
      );
    });
    test('NEVER contains a "Collaborative" label', () {
      final line = PlaylistMeta.detailLine(
          visibility: 'private', trackCount: 6, totalDurationSeconds: 1320);
      expect(line.toLowerCase().contains('collab'), isFalse);
    });
  });

  group('contributor line (Line 2)', () {
    test('owner only (non-collaborative)', () {
      final p = _playlist(ownerId: 'u1', ownerUsername: 'iamleizu');
      expect(PlaylistMeta.contributorLine(p), 'iamleizu');
    });

    test('owner + accepted collaborators, comma+space', () {
      final p = _playlist(
        ownerId: 'u1',
        ownerUsername: 'iamleizu',
        isCollaborative: true,
        collaborators: [
          {'userId': 'u2', 'username': 'bren_arteaga', 'status': 'accepted', 'position': 0},
          {'userId': 'u3', 'username': 'another_user', 'status': 'accepted', 'position': 1},
        ],
      );
      expect(PlaylistMeta.contributorLine(p), 'iamleizu, bren_arteaga, another_user');
    });

    test('pending/rejected collaborators are NOT shown', () {
      final p = _playlist(
        ownerId: 'u1',
        ownerUsername: 'iamleizu',
        isCollaborative: true,
        collaborators: [
          {'userId': 'u2', 'username': 'pending_user', 'status': 'pending', 'position': 0},
          {'userId': 'u3', 'username': 'bren_arteaga', 'status': 'accepted', 'position': 1},
          {'userId': 'u4', 'username': 'rejected_user', 'status': 'rejected', 'position': 2},
        ],
      );
      expect(PlaylistMeta.contributorLine(p), 'iamleizu, bren_arteaga');
    });

    test('owner never duplicated even if present in collaborators (by id)', () {
      final p = _playlist(
        ownerId: 'u1',
        ownerUsername: 'iamleizu',
        isCollaborative: true,
        collaborators: [
          {'userId': 'u1', 'username': 'iamleizu', 'status': 'accepted', 'position': 0},
          {'userId': 'u2', 'username': 'bren_arteaga', 'status': 'accepted', 'position': 1},
        ],
      );
      expect(PlaylistMeta.contributorLine(p), 'iamleizu, bren_arteaga');
    });

    test('dedupe by canonical user id', () {
      final p = _playlist(
        ownerId: 'u1',
        ownerUsername: 'iamleizu',
        collaborators: [
          {'userId': 'u2', 'username': 'bren_arteaga', 'status': 'accepted', 'position': 0},
          {'userId': 'u2', 'username': 'bren_dupe', 'status': 'accepted', 'position': 1},
        ],
      );
      expect(PlaylistMeta.contributorLine(p), 'iamleizu, bren_arteaga');
    });

    test('preserves order: owner first, collaborators by stored position', () {
      final p = _playlist(
        ownerId: 'u1',
        ownerUsername: 'iamleizu',
        collaborators: [
          {'userId': 'u3', 'username': 'third', 'status': 'accepted', 'position': 2},
          {'userId': 'u2', 'username': 'second', 'status': 'accepted', 'position': 1},
        ],
      );
      expect(PlaylistMeta.contributorLine(p), 'iamleizu, second, third');
    });

    test('missing owner username → fallback username', () {
      final p = _playlist(ownerId: 'u1'); // no stored username
      expect(PlaylistMeta.contributorLine(p, fallbackUsername: 'live_user'),
          'live_user');
    });

    test('no owner name available → empty (caller hides blank line)', () {
      final p = _playlist();
      expect(PlaylistMeta.contributorLine(p), '');
    });

    test('empty-id collaborator cannot duplicate the owner (name fallback)', () {
      // Phase 3.4 seam: a collaborator with a missing canonical id must still be
      // deduped against the owner by name, never rendered twice.
      final p = _playlist(
        ownerId: '',
        ownerUsername: 'iamleizu',
        isCollaborative: true,
        collaborators: [
          {'userId': '', 'username': 'iamleizu', 'status': 'accepted', 'position': 0},
          {'userId': '', 'username': 'bren_arteaga', 'status': 'accepted', 'position': 1},
        ],
      );
      expect(PlaylistMeta.contributorLine(p), 'iamleizu, bren_arteaga');
    });

    test('collaborative with no accepted collaborators → owner only, no label',
        () {
      final p = _playlist(
        ownerId: 'u1',
        ownerUsername: 'iamleizu',
        isCollaborative: true,
        collaborators: [
          {'userId': 'u2', 'username': 'invited', 'status': 'pending', 'position': 0},
        ],
      );
      expect(PlaylistMeta.contributorLine(p), 'iamleizu');
      expect(p.isCollaborativeOrDefault, isTrue); // flag stays explicit
    });
  });

  group('Phase 3.4.1 followers + stats line + last modified', () {
    test('followers singular/plural', () {
      expect(PlaylistMeta.followers(0), '0 followers');
      expect(PlaylistMeta.followers(1), '1 follower');
      expect(PlaylistMeta.followers(37), '37 followers');
    });

    test('stats line with followers', () {
      expect(
        PlaylistMeta.statsLine(
            visibility: 'public', trackCount: 21, totalDurationSeconds: 74 * 60, followerCount: 37),
        'Public · 21 songs · 1 hr 14 min · 37 followers',
      );
      expect(
        PlaylistMeta.statsLine(
            visibility: 'private', trackCount: 6, totalDurationSeconds: 22 * 60, followerCount: 0),
        'Private · 6 songs · 22 min · 0 followers',
      );
    });

    test('stats line omits followers when unknown, duration when zero', () {
      expect(
        PlaylistMeta.statsLine(visibility: 'private', trackCount: 1, totalDurationSeconds: 0),
        'Private · 1 song',
      );
    });

    test('last modified text', () {
      final now = DateTime(2026, 6, 1, 12);
      expect(PlaylistMeta.lastModifiedText(now.subtract(const Duration(hours: 2)), now),
          'Last modified 2 hours ago');
      expect(PlaylistMeta.lastModifiedText(null, now), isNull);
    });

    test('contributors · last modified (line 1)', () {
      final now = DateTime(2026, 6, 1, 12);
      final p = _playlist(ownerId: 'u1', ownerUsername: 'iamleizu');
      expect(
        PlaylistMeta.contributorsWithModified(p,
            lastModifiedAt: now.subtract(const Duration(minutes: 12)), now: now),
        'iamleizu · Last modified 12 minutes ago',
      );
      // contributors only when modified unknown
      expect(PlaylistMeta.contributorsWithModified(p, now: now), 'iamleizu');
    });
  });

  group('visibility × collaboration are independent', () {
    test('private + collaborative keeps "Private"', () {
      final p = _playlist(
          ownerId: 'u1',
          ownerUsername: 'iamleizu',
          visibility: 'private',
          isCollaborative: true);
      final line = PlaylistMeta.detailLine(
        visibility: p.visibility,
        trackCount: 6,
        totalDurationSeconds: 1320,
      );
      expect(line, 'Private · 6 songs · 22 min');
    });
  });
}
