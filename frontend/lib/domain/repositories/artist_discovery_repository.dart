// lib/domain/repositories/artist_discovery_repository.dart
//
// Phase 3.3 §9 — replaceable artist-discovery source for onboarding.
//
// The onboarding UI/controller depends only on this interface, never on where
// the candidates come from. Today the Paax catalog is still sparse, so the
// default HybridArtistDiscoverySource surfaces a Supabase "popular" grid and
// resolves search/selection through paax-api (which is Supabase-first, with
// Deezer discovery + background ingestion behind it). When catalog coverage is
// sufficient, switch to SupabaseArtistDiscoverySource — no UI change required.
//
// HOW TO SWITCH PROVIDERS LATER
//   Set the compile-time flag: --dart-define=ARTIST_DISCOVERY_MODE=supabase
//   (values: hybrid | supabase | deezer; default: hybrid). See
//   ArtistDiscoveryMode + artistDiscoveryRepository() below and AppConfig.

import '../entities/onboarding_artist.dart';

/// Which discovery source backs onboarding candidate selection.
enum ArtistDiscoveryMode {
  /// Supabase "popular" grid + paax-api search/resolve (current production).
  hybrid,

  /// Supabase-first everywhere (use once the catalog is well populated).
  supabase,

  /// Deezer-first discovery (chart popular) + paax-api resolve.
  deezer,
}

/// Source of artist candidates for onboarding. Every returned/selected artist
/// must be resolvable to a canonical Supabase catalog UUID before it is sent to
/// `complete_artist_onboarding` — resolution is [resolveByDeezerId].
abstract class ArtistDiscoveryRepository {
  /// Initial "popular / recommended" candidates shown before the user searches.
  Future<List<OnboardingArtist>> popular({int limit = 30});

  /// Text search for artists. Results may carry a null UUID until ingested;
  /// callers resolve on selection via [resolveByDeezerId].
  Future<List<OnboardingArtist>> search(String query, {int limit = 20});

  /// Resolve a Deezer artist id to its canonical Supabase catalog entity
  /// (ingest-on-miss). Returns null when it cannot be resolved.
  Future<OnboardingArtist?> resolveByDeezerId(int deezerId,
      {OnboardingArtist? fallback});

  /// Release the underlying HTTP client. Call from the owner's dispose().
  void dispose();
}
