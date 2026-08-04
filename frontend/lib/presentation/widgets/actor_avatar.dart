// lib/presentation/widgets/actor_avatar.dart
//
// Phase 3.4.1.2 §B — the ONE canonical actor-avatar widget. Every surface that
// shows a user's avatar (notifications, activity) renders it through here so the
// resolver priority (cached → original → placeholder), circular center-crop,
// error fallback, and deleted-user handling live in a single place rather than
// duplicated per widget. The image URL is resolved server-side by the emitter
// (coalesce(avatar_url, avatar_original_url)); this widget resolves display +
// failure gracefully and never renders a raw UUID.

import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';

class ActorAvatar extends StatelessWidget {
  /// Already-resolved avatar URL (cached preferred, original fallback). May be null.
  final String? imageUrl;

  /// Human display name for the initials fallback. Never a UUID. When empty the
  /// actor is treated as unknown/deleted → neutral person glyph.
  final String? displayName;

  final double size;

  const ActorAvatar({
    super.key,
    required this.imageUrl,
    required this.displayName,
    this.size = 44,
  });

  String? get _initial {
    final n = (displayName ?? '').trim();
    if (n.isEmpty) return null;
    final ch = n.characters.first.toUpperCase();
    return RegExp(r'[A-Z0-9]').hasMatch(ch) ? ch : null;
  }

  Widget _fallback() {
    final initial = _initial;
    return Container(
      color: AppColors.surfaceLight,
      alignment: Alignment.center,
      child: initial != null
          ? Text(initial,
              style: TextStyle(
                  color: Colors.white70,
                  fontSize: size * 0.42,
                  fontWeight: FontWeight.w700))
          : Icon(Icons.person_rounded, color: Colors.white38, size: size * 0.55),
    );
  }

  @override
  Widget build(BuildContext context) {
    final url = (imageUrl ?? '').trim();
    return Semantics(
      label: (displayName ?? '').trim().isEmpty ? 'User' : displayName,
      image: true,
      child: SizedBox(
        width: size,
        height: size,
        child: ClipOval(
          child: url.isEmpty
              ? _fallback()
              : Image.network(
                  url,
                  fit: BoxFit.cover,
                  width: size,
                  height: size,
                  // Never let an avatar failure break the row.
                  errorBuilder: (_, __, ___) => _fallback(),
                  loadingBuilder: (context, child, progress) =>
                      progress == null ? child : _fallback(),
                ),
        ),
      ),
    );
  }
}
