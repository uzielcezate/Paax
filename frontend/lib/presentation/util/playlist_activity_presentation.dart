// lib/presentation/util/playlist_activity_presentation.dart
//
// Phase 3.4.1.2 §E — the SINGLE source of truth for how a playlist activity
// event is presented: icon, title, subtitle, accessibility label, and whether
// it is destructive. Both the activity sheet and any notification/activity
// surface render through this mapper, so the icon/copy mapping is never
// duplicated across widgets. Icons use the app's existing Material icon set (no
// emoji); every icon carries a semantic label so meaning is not color-only.

import 'package:flutter/material.dart';
import '../../domain/entities/playlist_activity.dart';

class PlaylistActivityPresentation {
  final IconData icon;
  final String title;
  final String? subtitle;
  final String semanticLabel;
  final bool destructive;

  const PlaylistActivityPresentation({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.semanticLabel,
    required this.destructive,
  });

  /// Build the presentation for one activity event. [actorFallback] is used when
  /// the actor username is unknown (never a UUID).
  factory PlaylistActivityPresentation.of(PlaylistActivity a,
      {String actorFallback = 'Someone'}) {
    final title = ActivitySummary.headline(a, actorFallback: actorFallback);
    final _Icon spec = _iconFor(a);
    final subtitle = _subtitleFor(a);
    return PlaylistActivityPresentation(
      icon: spec.icon,
      title: title,
      subtitle: subtitle,
      semanticLabel: title,
      destructive: spec.destructive,
    );
  }

  static String? _subtitleFor(PlaylistActivity a) {
    final inline = ActivitySummary.inlineTrackSummary(a);
    return inline.isEmpty ? null : inline;
  }

  static _Icon _iconFor(PlaylistActivity a) {
    switch (a.eventType) {
      case 'tracks_added':
        return const _Icon(Icons.add_rounded);
      case 'tracks_added_from_source':
        return const _Icon(Icons.library_add_rounded);
      case 'tracks_removed':
        return const _Icon(Icons.remove_rounded, destructive: true);
      case 'tracks_reordered':
        return const _Icon(Icons.swap_vert_rounded);
      case 'playlist_renamed':
        return const _Icon(Icons.edit_rounded);
      case 'description_changed':
        return const _Icon(Icons.notes_rounded);
      case 'visibility_changed':
        final to = a.metadata['to']?.toString();
        if (to == 'public') return const _Icon(Icons.public_rounded);
        if (to == 'private') return const _Icon(Icons.lock_outline_rounded);
        return const _Icon(Icons.visibility_rounded);
      case 'cover_changed':
        return const _Icon(Icons.image_rounded);
      case 'playlist_created':
        return const _Icon(Icons.library_music_rounded);
      case 'playlist_imported':
        return const _Icon(Icons.download_rounded);
      case 'playlist_cloned':
        return const _Icon(Icons.content_copy_rounded);
      case 'collaborator_invited':
        return const _Icon(Icons.person_add_alt_1_rounded);
      case 'collaborator_joined':
        return const _Icon(Icons.group_add_rounded);
      case 'collaborator_removed':
        return const _Icon(Icons.person_remove_rounded, destructive: true);
      case 'collaborator_left':
        return const _Icon(Icons.logout_rounded);
      case 'ownership_transferred':
        return const _Icon(Icons.workspace_premium_rounded);
      case 'playlist_deleted':
        return const _Icon(Icons.delete_outline_rounded, destructive: true);
      default:
        return const _Icon(Icons.history_rounded);
    }
  }
}

class _Icon {
  final IconData icon;
  final bool destructive;
  const _Icon(this.icon, {this.destructive = false});
}
