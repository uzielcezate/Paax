-- ============================================================================
-- Migration: catalog
-- Phase 1 — Supabase foundation (ADR-009).
-- Canonical music catalog: genres, artists, albums, tracks, contributor
-- junctions, and genre junctions. Metadata source of truth is Deezer;
-- YouTube provides playback video IDs only (matched later, Phase 2+).
--
-- Security model: catalog is publicly readable (anon + authenticated).
-- Writes are backend/service-role ONLY — no client write policies exist.
--
-- Rollback strategy (reverse dependency order):
--   drop table if exists public.track_genres, public.album_genres,
--     public.artist_genres, public.track_artists, public.album_artists,
--     public.tracks, public.albums, public.artists, public.genres cascade;
-- ============================================================================

-- ---------------------------------------------------------------------------
-- genres
-- ---------------------------------------------------------------------------
create table public.genres (
  id uuid primary key default gen_random_uuid(),
  deezer_id bigint unique,
  name text not null unique,
  slug text not null unique,
  description text,
  image_original_url text,
  image_cached_url text,
  image_cached_at timestamptz,
  image_cache_status text not null default 'pending',
  -- Denormalized; derived from user_followed_genres via private trigger only.
  platform_followers_count bigint not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint genres_name_not_empty check (length(trim(name)) > 0),
  constraint genres_slug_format check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  constraint genres_image_cache_status_valid
    check (image_cache_status in ('pending','processing','cached','failed','skipped')),
  constraint genres_followers_nonnegative check (platform_followers_count >= 0)
);

create trigger set_genres_updated_at
  before update on public.genres
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- artists
-- ---------------------------------------------------------------------------
create table public.artists (
  id uuid primary key default gen_random_uuid(),
  deezer_id bigint unique,
  name text not null,
  normalized_name text not null,
  image_original_url text,
  image_cached_url text,
  image_cached_at timestamptz,
  image_cache_status text not null default 'pending',
  dominant_genre_id uuid references public.genres(id) on delete set null,
  -- Denormalized; derived from user_followed_artists via private trigger only.
  platform_followers_count bigint not null default 0,
  deezer_fans_count bigint,
  biography text,
  country_code text,
  is_verified boolean not null default false,
  metadata_source text not null default 'deezer',
  metadata_status text not null default 'partial',
  metadata_updated_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint artists_name_not_empty check (length(trim(name)) > 0),
  constraint artists_normalized_name_not_empty check (length(trim(normalized_name)) > 0),
  constraint artists_followers_nonnegative check (platform_followers_count >= 0),
  constraint artists_deezer_fans_nonnegative
    check (deezer_fans_count is null or deezer_fans_count >= 0),
  constraint artists_country_code_format
    check (country_code is null or country_code ~ '^[A-Z]{2}$'),
  constraint artists_image_cache_status_valid
    check (image_cache_status in ('pending','processing','cached','failed','skipped')),
  constraint artists_metadata_status_valid
    check (metadata_status in ('partial','full','stale','failed'))
);

create index idx_artists_normalized_name on public.artists (normalized_name);
create index idx_artists_normalized_name_trgm
  on public.artists using gin (normalized_name extensions.gin_trgm_ops);
create index idx_artists_metadata_updated_at on public.artists (metadata_updated_at);
create index idx_artists_dominant_genre_id on public.artists (dominant_genre_id);

create trigger set_artists_updated_at
  before update on public.artists
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- albums
-- ---------------------------------------------------------------------------
create table public.albums (
  id uuid primary key default gen_random_uuid(),
  deezer_id bigint unique,
  title text not null,
  normalized_title text not null,
  album_type text not null default 'album',
  release_date date,
  release_year smallint,
  label text,
  upc text,
  cover_original_url text,
  cover_cached_url text,
  cover_cached_at timestamptz,
  image_cache_status text not null default 'pending',
  total_tracks integer not null default 0,
  total_duration_seconds integer not null default 0,
  explicit boolean not null default false,
  primary_genre_id uuid references public.genres(id) on delete set null,
  -- Denormalized; derived from user_saved_albums via private trigger only.
  platform_likes_count bigint not null default 0,
  -- Denormalized; incremented ONLY by private.record_qualified_play (backend).
  platform_play_count bigint not null default 0,
  metadata_source text not null default 'deezer',
  metadata_status text not null default 'partial',
  metadata_updated_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint albums_title_not_empty check (length(trim(title)) > 0),
  constraint albums_album_type_valid
    check (album_type in ('album','single','ep','compilation','live','soundtrack','other')),
  constraint albums_release_year_valid
    check (release_year is null or release_year between 1000 and 2100),
  constraint albums_total_tracks_nonnegative check (total_tracks >= 0),
  constraint albums_total_duration_nonnegative check (total_duration_seconds >= 0),
  constraint albums_likes_nonnegative check (platform_likes_count >= 0),
  constraint albums_plays_nonnegative check (platform_play_count >= 0),
  constraint albums_image_cache_status_valid
    check (image_cache_status in ('pending','processing','cached','failed','skipped')),
  constraint albums_metadata_status_valid
    check (metadata_status in ('partial','full','stale','failed'))
);

create index idx_albums_release_date on public.albums (release_date desc nulls last);
create index idx_albums_album_type on public.albums (album_type);
create index idx_albums_normalized_title on public.albums (normalized_title);
create index idx_albums_normalized_title_trgm
  on public.albums using gin (normalized_title extensions.gin_trgm_ops);
create index idx_albums_primary_genre_id on public.albums (primary_genre_id);
create index idx_albums_metadata_updated_at on public.albums (metadata_updated_at);

create trigger set_albums_updated_at
  before update on public.albums
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- album_artists (M:N with roles; composite PK allows distinct roles per pair)
-- ---------------------------------------------------------------------------
create table public.album_artists (
  album_id uuid not null references public.albums(id) on delete cascade,
  artist_id uuid not null references public.artists(id) on delete cascade,
  role text not null default 'primary',
  position integer not null default 1,
  created_at timestamptz not null default now(),

  primary key (album_id, artist_id, role),
  constraint album_artists_role_valid
    check (role in ('primary','featured','producer','composer','remixer','performer','other')),
  constraint album_artists_position_positive check (position >= 1)
);

-- PK covers album->artists lookup; this covers artist->discography lookup.
create index idx_album_artists_artist_id on public.album_artists (artist_id);

-- ---------------------------------------------------------------------------
-- tracks
-- ---------------------------------------------------------------------------
create table public.tracks (
  id uuid primary key default gen_random_uuid(),
  deezer_id bigint unique,
  -- Deliberate: deleting an album orphans (not deletes) its tracks; catalog
  -- reconciliation jobs re-link or prune them.
  album_id uuid references public.albums(id) on delete set null,
  title text not null,
  title_short text,
  normalized_title text not null,
  track_number integer,
  disc_number integer not null default 1,
  duration_seconds integer not null default 0,
  bpm numeric,
  bpm_source text,
  bpm_confidence numeric,
  explicit boolean not null default false,
  isrc text,
  primary_genre_id uuid references public.genres(id) on delete set null,

  -- YouTube playback mapping (Phase 2 matcher fills these; Phase 1 = pending).
  youtube_audio_video_id text,
  youtube_music_video_id text,
  -- Normally references the audio/Topic/official-audio match.
  preferred_youtube_video_id text,
  youtube_match_status text not null default 'pending',
  youtube_match_confidence numeric,
  youtube_match_reason text,
  youtube_match_updated_at timestamptz,
  youtube_last_verified_at timestamptz,
  youtube_failure_count integer not null default 0,

  -- Artwork
  image_original_url text,
  image_cached_url text,
  image_cached_at timestamptz,
  image_cache_status text not null default 'pending',

  -- Platform counters (denormalized; trigger/backend-maintained only).
  platform_likes_count bigint not null default 0,
  platform_play_count bigint not null default 0,
  platform_download_count bigint not null default 0,

  metadata_source text not null default 'deezer',
  metadata_status text not null default 'partial',
  metadata_updated_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint tracks_title_not_empty check (length(trim(title)) > 0),
  constraint tracks_duration_nonnegative check (duration_seconds >= 0),
  constraint tracks_track_number_positive check (track_number is null or track_number >= 1),
  constraint tracks_disc_number_positive check (disc_number >= 1),
  constraint tracks_bpm_positive check (bpm is null or bpm > 0),
  constraint tracks_bpm_confidence_range
    check (bpm_confidence is null or (bpm_confidence >= 0 and bpm_confidence <= 1)),
  constraint tracks_youtube_match_status_valid
    check (youtube_match_status in
      ('pending','resolving','matched','failed','stale','needs_review','unavailable')),
  constraint tracks_youtube_confidence_range
    check (youtube_match_confidence is null
           or (youtube_match_confidence >= 0 and youtube_match_confidence <= 1)),
  constraint tracks_youtube_failures_nonnegative check (youtube_failure_count >= 0),
  constraint tracks_likes_nonnegative check (platform_likes_count >= 0),
  constraint tracks_plays_nonnegative check (platform_play_count >= 0),
  constraint tracks_downloads_nonnegative check (platform_download_count >= 0),
  constraint tracks_image_cache_status_valid
    check (image_cache_status in ('pending','processing','cached','failed','skipped')),
  constraint tracks_metadata_status_valid
    check (metadata_status in ('partial','full','stale','failed'))
);

create index idx_tracks_album_id on public.tracks (album_id);
create index idx_tracks_isrc on public.tracks (isrc);
create index idx_tracks_normalized_title on public.tracks (normalized_title);
create index idx_tracks_normalized_title_trgm
  on public.tracks using gin (normalized_title extensions.gin_trgm_ops);
create index idx_tracks_primary_genre_id on public.tracks (primary_genre_id);
create index idx_tracks_youtube_match_status on public.tracks (youtube_match_status);
-- Matcher work queue: only rows that still need resolution.
create index idx_tracks_youtube_pending on public.tracks (youtube_match_updated_at)
  where youtube_match_status in ('pending','stale','failed');
create index idx_tracks_metadata_updated_at on public.tracks (metadata_updated_at);
create index idx_tracks_album_disc_track
  on public.tracks (album_id, disc_number, track_number);

create trigger set_tracks_updated_at
  before update on public.tracks
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- track_artists (M:N with roles + collaborator order; supports e.g.
-- "Young Miko — primary, Feid — featured")
-- ---------------------------------------------------------------------------
create table public.track_artists (
  track_id uuid not null references public.tracks(id) on delete cascade,
  artist_id uuid not null references public.artists(id) on delete cascade,
  role text not null default 'primary',
  position integer not null default 1,
  display_name text,
  created_at timestamptz not null default now(),

  primary key (track_id, artist_id, role),
  constraint track_artists_role_valid
    check (role in ('primary','featured','producer','composer','remixer','performer','vocalist','other')),
  constraint track_artists_position_positive check (position >= 1)
);

create index idx_track_artists_artist_id on public.track_artists (artist_id);

-- ---------------------------------------------------------------------------
-- Genre junctions
-- ---------------------------------------------------------------------------
create table public.artist_genres (
  artist_id uuid not null references public.artists(id) on delete cascade,
  genre_id uuid not null references public.genres(id) on delete cascade,
  relevance_score numeric,
  source text,
  created_at timestamptz not null default now(),
  primary key (artist_id, genre_id),
  constraint artist_genres_relevance_range
    check (relevance_score is null or (relevance_score >= 0 and relevance_score <= 1))
);
create index idx_artist_genres_genre_id on public.artist_genres (genre_id);

create table public.album_genres (
  album_id uuid not null references public.albums(id) on delete cascade,
  genre_id uuid not null references public.genres(id) on delete cascade,
  relevance_score numeric,
  source text,
  created_at timestamptz not null default now(),
  primary key (album_id, genre_id),
  constraint album_genres_relevance_range
    check (relevance_score is null or (relevance_score >= 0 and relevance_score <= 1))
);
create index idx_album_genres_genre_id on public.album_genres (genre_id);

create table public.track_genres (
  track_id uuid not null references public.tracks(id) on delete cascade,
  genre_id uuid not null references public.genres(id) on delete cascade,
  relevance_score numeric,
  source text,
  created_at timestamptz not null default now(),
  primary key (track_id, genre_id),
  constraint track_genres_relevance_range
    check (relevance_score is null or (relevance_score >= 0 and relevance_score <= 1))
);
create index idx_track_genres_genre_id on public.track_genres (genre_id);

-- ---------------------------------------------------------------------------
-- RLS: public catalog read, backend-only writes (no client write policies).
-- service_role bypasses RLS for ingestion.
-- ---------------------------------------------------------------------------
alter table public.genres enable row level security;
alter table public.artists enable row level security;
alter table public.albums enable row level security;
alter table public.album_artists enable row level security;
alter table public.tracks enable row level security;
alter table public.track_artists enable row level security;
alter table public.artist_genres enable row level security;
alter table public.album_genres enable row level security;
alter table public.track_genres enable row level security;

create policy "Catalog genres are publicly readable"
  on public.genres for select to anon, authenticated using (true);
create policy "Catalog artists are publicly readable"
  on public.artists for select to anon, authenticated using (true);
create policy "Catalog albums are publicly readable"
  on public.albums for select to anon, authenticated using (true);
create policy "Catalog album credits are publicly readable"
  on public.album_artists for select to anon, authenticated using (true);
create policy "Catalog tracks are publicly readable"
  on public.tracks for select to anon, authenticated using (true);
create policy "Catalog track credits are publicly readable"
  on public.track_artists for select to anon, authenticated using (true);
create policy "Catalog artist genres are publicly readable"
  on public.artist_genres for select to anon, authenticated using (true);
create policy "Catalog album genres are publicly readable"
  on public.album_genres for select to anon, authenticated using (true);
create policy "Catalog track genres are publicly readable"
  on public.track_genres for select to anon, authenticated using (true);
