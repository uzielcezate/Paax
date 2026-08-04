// test/unit/playlist_activity_presentation_test.dart — Phase 3.4.1.2 §E.
//
// The centralized activity presentation mapper: distinct icon + user-readable
// copy + destructive flag + bounded track summary for each activity type.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:beaty/domain/entities/playlist_activity.dart';
import 'package:beaty/presentation/util/playlist_activity_presentation.dart';

PlaylistActivity _a(String type,
        {Map<String, dynamic> meta = const {}, String actor = 'uziel'}) =>
    PlaylistActivity(
      id: 'x',
      playlistId: 'p',
      eventType: type,
      actorUsername: actor,
      createdAt: DateTime(2026, 8, 4),
      metadata: meta,
    );

void main() {
  test('tracks added → add icon + copy', () {
    final p = PlaylistActivityPresentation.of(_a('tracks_added', meta: {'count': 3}));
    expect(p.icon, Icons.add_rounded);
    expect(p.title, 'uziel added 3 songs');
    expect(p.destructive, isFalse);
  });

  test('tracks removed → remove icon + destructive', () {
    final p = PlaylistActivityPresentation.of(
        _a('tracks_removed', meta: {'count': 2}, actor: 'bren_arteaga'));
    expect(p.icon, Icons.remove_rounded);
    expect(p.title, 'bren_arteaga removed 2 songs');
    expect(p.destructive, isTrue);
  });

  test('renamed → edit icon + copy', () {
    final p = PlaylistActivityPresentation.of(
        _a('playlist_renamed', meta: {'to': 'Bad Bunny'}));
    expect(p.icon, Icons.edit_rounded);
    expect(p.title, 'uziel renamed the playlist to "Bad Bunny"');
  });

  test('made public → globe icon + copy', () {
    final p = PlaylistActivityPresentation.of(
        _a('visibility_changed', meta: {'from': 'private', 'to': 'public'}));
    expect(p.icon, Icons.public_rounded);
    expect(p.title, 'uziel made this playlist public');
  });

  test('made private → lock icon + copy', () {
    final p = PlaylistActivityPresentation.of(
        _a('visibility_changed', meta: {'from': 'public', 'to': 'private'}));
    expect(p.icon, Icons.lock_outline_rounded);
    expect(p.title, 'uziel made this playlist private');
  });

  test('collaborator joined → group-add icon + copy', () {
    final p = PlaylistActivityPresentation.of(
        _a('collaborator_joined', actor: 'bren_arteaga'));
    expect(p.icon, Icons.group_add_rounded);
    expect(p.title, 'bren_arteaga joined as a collaborator');
  });

  test('ownership transferred → premium icon, no UUID leak', () {
    final p = PlaylistActivityPresentation.of(_a('ownership_transferred',
        meta: {'from': 'uuid-a', 'to': 'uuid-b'}));
    expect(p.icon, Icons.workspace_premium_rounded);
    expect(p.title, 'Ownership was transferred');
    expect(p.title.contains('uuid'), isFalse);
  });

  test('created → distinct icon', () {
    final p = PlaylistActivityPresentation.of(_a('playlist_created'));
    expect(p.icon, Icons.library_music_rounded);
    expect(p.title, 'uziel created the playlist');
  });

  test('deleted / collaborator removed are destructive', () {
    expect(PlaylistActivityPresentation.of(_a('playlist_deleted')).destructive, isTrue);
    expect(PlaylistActivityPresentation.of(_a('collaborator_removed')).destructive, isTrue);
  });

  test('every mapped type has a non-empty semantic label', () {
    for (final t in [
      'tracks_added', 'tracks_removed', 'tracks_reordered', 'playlist_renamed',
      'description_changed', 'visibility_changed', 'cover_changed',
      'playlist_created', 'playlist_imported', 'playlist_cloned',
      'collaborator_invited', 'collaborator_joined', 'collaborator_removed',
      'collaborator_left', 'ownership_transferred', 'playlist_deleted',
      'tracks_added_from_source', 'unknown_future_type',
    ]) {
      final p = PlaylistActivityPresentation.of(_a(t));
      expect(p.semanticLabel.trim(), isNotEmpty, reason: t);
    }
  });

  group('bounded track summary', () {
    test('under limit lists all titles, no "and N more"', () {
      final p = PlaylistActivityPresentation.of(_a('tracks_added', meta: {
        'count': 2,
        'tracks': [
          {'title': 'Duro'},
          {'title': 'offline'},
        ],
      }));
      expect(p.subtitle, 'Duro, offline');
    });

    test('over limit bounds to 3 + "and N more"', () {
      final p = PlaylistActivityPresentation.of(_a('tracks_added', meta: {
        'count': 6,
        'tracks': [
          {'title': 'Duro'},
          {'title': 'offline'},
          {'title': 'WASSUP'},
          {'title': 'Four'},
          {'title': 'Five'},
          {'title': 'Six'},
        ],
      }));
      expect(p.subtitle, 'Duro, offline, WASSUP and 3 more');
    });

    test('non-track event has no track subtitle', () {
      expect(PlaylistActivityPresentation.of(_a('playlist_renamed')).subtitle, isNull);
    });
  });
}
