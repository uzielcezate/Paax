/// Deterministic search Top-Result relevance ranking (Phase 3.3.3 issue 1).
///
/// The Top Result must be relevance-based, not just the first artist whose NAME
/// matches the query. An obscure artist whose name matches must not outrank a
/// major artist who is the PRIMARY artist of several exact-matching tracks or
/// releases. This composes candidate artists from the name-matching artist
/// results PLUS the primary artists of exact-matching tracks/albums, and scores
/// them generically (no hardcoded names).
///
/// Example: query "Dai Dai" — Shakira (primary artist of the strongest exact
/// track/album matches) outranks "DAIDAI" (name-only match, no catalog context).
library;

class ScoredArtist {
  final String name;
  final double score;
  /// True when this candidate came from the artist search results (so it is
  /// already a navigable Artist); false when derived only from track/album
  /// primary artists (the caller must resolve it to a navigable entity).
  final bool inArtistResults;
  final int followers;
  const ScoredArtist(this.name, this.score, this.inArtistResults, {this.followers = 0});
}

class SearchRelevance {
  SearchRelevance._();

  static String norm(String s) =>
      s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  /// Rank candidate Top-Result artists by relevance to [query].
  /// [tracks]/[albums] are (title, primaryArtistName); [artists] are
  /// (name, followers). Returns candidates sorted by descending score.
  static List<ScoredArtist> rankArtists({
    required String query,
    required List<({String title, String artist})> tracks,
    required List<({String title, String artist})> albums,
    required List<({String name, int followers})> artists,
  }) {
    final q = norm(query);
    if (q.isEmpty) return const [];
    final qTokens = q.split(' ').where((t) => t.isNotEmpty).toSet();

    final cand = <String, _Sig>{};
    _Sig sig(String name) => cand.putIfAbsent(norm(name), () => _Sig(name));

    // Context: primary artist of EXACT-title-matching tracks (very high signal).
    for (final t in tracks) {
      if (t.artist.trim().isEmpty) continue;
      if (norm(t.title) == q) sig(t.artist).exactTracks++;
    }
    // Context: primary artist of EXACT-title-matching albums/singles.
    for (final a in albums) {
      if (a.artist.trim().isEmpty) continue;
      if (norm(a.title) == q) sig(a.artist).exactAlbums++;
    }
    // Name-match artist candidates (carry followers for the tie-breaker).
    for (final ar in artists) {
      if (ar.name.trim().isEmpty) continue;
      final s = sig(ar.name);
      s.inArtistResults = true;
      if (ar.followers > s.followers) s.followers = ar.followers;
    }

    final out = <ScoredArtist>[];
    for (final s in cand.values) {
      final n = norm(s.displayName);
      final exactName = n == q;
      final prefix = !exactName && n.startsWith(q);
      final tokenCoverage = !exactName && !prefix &&
          qTokens.isNotEmpty && qTokens.every((tok) => n.contains(tok));

      var score = 0.0;
      // Primary artist of exact-matching tracks/releases → high (capped).
      score += _capped(s.exactTracks, 3) * 50.0;
      score += _capped(s.exactAlbums, 3) * 45.0;
      // Name match: an EXACT artist-name match is a strong identity signal (60)
      // — enough that a single incidental same-titled song (one exact track = 50)
      // does not override an artist literally named the query, while a major
      // artist who is the primary of SEVERAL exact-matching tracks/releases
      // (≥2 → ≥100) still wins (review M2). Prefix/token are weaker.
      if (exactName) {
        score += 60;
      } else if (prefix) {
        score += 15;
      } else if (tokenCoverage) {
        score += 8;
      }

      if (score > 0) {
        out.add(ScoredArtist(s.displayName, score, s.inArtistResults,
            followers: s.followers));
      }
    }
    // Score is primary; popularity is ONLY a tie-breaker for equal relevance.
    out.sort((x, y) {
      final byScore = y.score.compareTo(x.score);
      if (byScore != 0) return byScore;
      return y.followers.compareTo(x.followers);
    });
    return out;
  }

  static int _capped(int v, int max) => v > max ? max : v;
}

class _Sig {
  final String displayName;
  int exactTracks = 0;
  int exactAlbums = 0;
  int followers = 0;
  bool inArtistResults = false;
  _Sig(this.displayName);
}
