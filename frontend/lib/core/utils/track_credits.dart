/// One canonical per-track credit resolver (Phase 3.3.3 issue 4).
///
/// Album track rows must show the real performing artists for THAT track
/// (e.g. "Skrillex, Young Miko"), read from the normalized `track_artists`
/// graph — never collapsed to the album's primary artist. This turns a raw,
/// ordered artist list (from the normalized track's `artists` array, a legacy
/// track's `artists`, or Deezer `contributors`) into the deduped,
/// position-ordered `List<{'name','id'}>` used by `Track.artists`.
///
/// Rules:
///  * primary/main performers before featured;
///  * preserve `position` order within each group;
///  * dedupe by canonical UUID → Deezer id → normalized name;
///  * exclude non-performing roles (producer/composer/remixer/writer/…) so only
///    visible performing credits are shown;
///  * the nav `id` is the numeric Deezer id when available (the artist screen
///    navigates by Deezer id), else the raw id.
class TrackCredits {
  TrackCredits._();

  // Roles that are NOT visible performing credits and must be hidden. Use a
  // DENYLIST (not an allowlist) so an unexpected/new role from the backend
  // degrades to "show the artist" rather than silently hiding everyone
  // (review H2). The normalized track_artists vocabulary is
  // primary/featured/producer/composer/remixer/performer/vocalist/other.
  static const Set<String> _hiddenRoles = {
    'producer', 'composer', 'writer', 'songwriter', 'lyricist',
    'remixer', 'mixer', 'engineer', 'arranger', 'programmer',
  };

  static bool _isPerforming(String role) => !_hiddenRoles.contains(role);

  static bool _isFeatured(String role) =>
      role == 'featured' || role == 'feat';

  static int? _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  static String _norm(String s) => s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  /// Resolve an ordered, deduped visible-credit list from a raw artist list.
  static List<Map<String, String>> resolve(List<dynamic> rawArtists) {
    final entries = <_Credit>[];
    for (var i = 0; i < rawArtists.length; i++) {
      final a = rawArtists[i];
      if (a is! Map) continue;
      final m = a.cast<String, dynamic>();
      final name = (m['name']?.toString() ?? '').trim();
      if (name.isEmpty) continue;
      final role = (m['role']?.toString() ?? 'primary').toLowerCase().trim();
      if (!_isPerforming(role)) continue; // hide producers/composers/etc.
      final position = _asInt(m['position']) ?? (i + 1);
      final deezerId = _asInt(m['deezerId'] ?? m['deezer_id']);
      // A non-numeric `id` is a Supabase UUID; a numeric one is a Deezer id.
      final rawId = m['id']?.toString();
      final uuid = (m['uuid']?.toString()) ??
          ((rawId != null && _asInt(rawId) == null) ? rawId : null);
      final navId = deezerId?.toString() ?? rawId ?? '';
      entries.add(_Credit(
        name: name, role: role, position: position,
        deezerId: deezerId, uuid: uuid, navId: navId,
      ));
    }

    // Primary before featured; preserve position within each group.
    entries.sort((x, y) {
      final xf = _isFeatured(x.role) ? 1 : 0;
      final yf = _isFeatured(y.role) ? 1 : 0;
      if (xf != yf) return xf - yf;
      return x.position.compareTo(y.position);
    });

    // Dedupe by canonical UUID → Deezer id → normalized name. An entry is a
    // duplicate if it shares an identifier with a kept one; the name fallback
    // only applies to entries lacking BOTH ids, so two DISTINCT same-name
    // artists (each with its own id) are not wrongly merged.
    final seenUuid = <String>{};
    final seenDeezer = <int>{};
    final seenName = <String>{};
    final out = <Map<String, String>>[];
    for (final e in entries) {
      final hasUuid = e.uuid != null && e.uuid!.isNotEmpty;
      final nn = _norm(e.name);
      final dup = (hasUuid && seenUuid.contains(e.uuid)) ||
          (e.deezerId != null && seenDeezer.contains(e.deezerId)) ||
          (!hasUuid && e.deezerId == null && seenName.contains(nn));
      if (dup) continue;
      if (hasUuid) seenUuid.add(e.uuid!);
      if (e.deezerId != null) seenDeezer.add(e.deezerId!);
      seenName.add(nn);
      out.add({'name': e.name, 'id': e.navId});
    }
    return out;
  }
}

class _Credit {
  final String name;
  final String role;
  final int position;
  final int? deezerId;
  final String? uuid;
  final String navId;
  const _Credit({
    required this.name,
    required this.role,
    required this.position,
    required this.deezerId,
    required this.uuid,
    required this.navId,
  });
}
