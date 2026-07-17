-- ============================================================================
-- Migration: catalog_phase2_1_match_types_and_search
-- Phase 2.1 (ADR-009 Phase 2). Backend catalog ingestion foundation.
--
-- Adds:
--   * tracks.youtube_audio_match_type / youtube_music_video_match_type
--     (mandatory playback-selection rule: classify the stored YouTube mappings)
--   * public.catalog_normalize(text)  — deterministic text normalization used
--     for pg_trgm search + normalized_* columns at ingestion time.
--   * public.catalog_search(type, query, limit, offset) — trigram-ranked
--     catalog search. Backend-only (EXECUTE granted to service_role only).
--
-- Idempotent + additive. No data is dropped.
--
-- Rollback strategy:
--   drop function if exists public.catalog_search(text,text,int,int);
--   drop function if exists public.catalog_normalize(text);
--   alter table public.tracks
--     drop column if exists youtube_audio_match_type,
--     drop column if exists youtube_music_video_match_type;
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. YouTube candidate classification columns
-- ---------------------------------------------------------------------------
alter table public.tracks
  add column if not exists youtube_audio_match_type text,
  add column if not exists youtube_music_video_match_type text;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'tracks_youtube_audio_match_type_valid'
  ) then
    alter table public.tracks add constraint tracks_youtube_audio_match_type_valid
      check (youtube_audio_match_type is null or youtube_audio_match_type in
        ('audio_only','official_music_video','live','lyric_video','remix','cover','other'));
  end if;
  if not exists (
    select 1 from pg_constraint where conname = 'tracks_youtube_music_video_match_type_valid'
  ) then
    alter table public.tracks add constraint tracks_youtube_music_video_match_type_valid
      check (youtube_music_video_match_type is null or youtube_music_video_match_type in
        ('audio_only','official_music_video','live','lyric_video','remix','cover','other'));
  end if;
end $$;

comment on column public.tracks.youtube_audio_match_type is
  'Classification of youtube_audio_video_id (audio_only|official_music_video|live|lyric_video|remix|cover|other).';
comment on column public.tracks.youtube_music_video_match_type is
  'Classification of youtube_music_video_id.';

-- ---------------------------------------------------------------------------
-- 2. Deterministic normalization helper (lower/trim/collapse-whitespace).
--    Immutable so it may back a functional index later. search_path pinned.
-- ---------------------------------------------------------------------------
create or replace function public.catalog_normalize(p text)
returns text
language sql
immutable
set search_path = ''
as $$
  select trim(regexp_replace(lower(coalesce(p, '')), '\s+', ' ', 'g'));
$$;

comment on function public.catalog_normalize(text) is
  'Deterministic catalog text normalization (lower, trim, collapse whitespace). '
  'Must match the value stored in artists.normalized_name / albums.normalized_title / tracks.normalized_title.';

-- ---------------------------------------------------------------------------
-- 3. Trigram-ranked catalog search. Backend-only.
--    Returns a jsonb array of matched rows with a similarity score.
-- ---------------------------------------------------------------------------
create or replace function public.catalog_search(
  p_type  text,
  p_query text,
  p_limit int default 20,
  p_offset int default 0
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = public, extensions
as $$
declare
  q       text := public.catalog_normalize(p_query);
  lim     int  := least(greatest(coalesce(p_limit, 20), 1), 100);
  off     int  := greatest(coalesce(p_offset, 0), 0);
  result  jsonb;
begin
  if q is null or length(q) = 0 then
    return '[]'::jsonb;
  end if;

  if p_type = 'artists' then
    select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) into result from (
      select a.id, a.deezer_id, a.name,
             a.image_cached_url, a.image_original_url,
             a.platform_followers_count, a.deezer_fans_count,
             a.metadata_status,
             round(similarity(a.normalized_name, q)::numeric, 4) as score
      from artists a
      where a.normalized_name % q
      order by score desc, a.deezer_fans_count desc nulls last
      limit lim offset off
    ) x;

  elsif p_type = 'albums' then
    select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) into result from (
      select al.id, al.deezer_id, al.title, al.album_type, al.release_date,
             al.cover_cached_url, al.cover_original_url,
             al.total_tracks, al.explicit, al.metadata_status,
             (
               select coalesce(ar.name, '')
               from album_artists aa
               join artists ar on ar.id = aa.artist_id
               where aa.album_id = al.id and aa.role = 'primary'
               order by aa.position limit 1
             ) as primary_artist_name,
             round(similarity(al.normalized_title, q)::numeric, 4) as score
      from albums al
      where al.normalized_title % q
      order by score desc, al.release_date desc nulls last
      limit lim offset off
    ) x;

  elsif p_type = 'tracks' then
    select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) into result from (
      select t.id, t.deezer_id, t.title, t.title_short, t.duration_seconds,
             t.explicit, t.album_id, t.preferred_youtube_video_id,
             t.youtube_match_status, t.image_cached_url, t.image_original_url,
             t.metadata_status,
             (
               select coalesce(ta.display_name, ar.name, '')
               from track_artists ta
               join artists ar on ar.id = ta.artist_id
               where ta.track_id = t.id and ta.role = 'primary'
               order by ta.position limit 1
             ) as primary_artist_name,
             round(similarity(t.normalized_title, q)::numeric, 4) as score
      from tracks t
      where t.normalized_title % q
      order by score desc, t.platform_play_count desc nulls last
      limit lim offset off
    ) x;

  else
    raise exception 'catalog_search: invalid type %', p_type
      using errcode = 'invalid_parameter_value';
  end if;

  return result;
end;
$$;

comment on function public.catalog_search(text,text,int,int) is
  'Backend-only trigram-ranked catalog search over artists/albums/tracks.';

-- Backend-only: never callable by anon/authenticated via PostgREST.
revoke all on function public.catalog_normalize(text) from public;
revoke all on function public.catalog_search(text,text,int,int) from public, anon, authenticated;
grant execute on function public.catalog_normalize(text) to service_role;
grant execute on function public.catalog_search(text,text,int,int) to service_role;
