-- ============================================================================
-- Migration: catalog_views
-- Phase 1 — Supabase foundation (ADR-009).
-- Read-simplification views over the public catalog. All use
-- security_invoker = true, so the caller's RLS applies (catalog is publicly
-- readable, so anon works too).
--
-- Rollback strategy:
--   drop view if exists public.artist_latest_release,
--     public.artist_discography, public.album_track_details;
-- ============================================================================

-- Tracks of an album in play order, with ALL contributors ordered by position
-- (supports multi-artist credits, e.g. Young Miko primary + Feid featured).
create view public.album_track_details
with (security_invoker = true)
as
select
  t.album_id,
  t.id as track_id,
  t.title,
  t.title_short,
  t.disc_number,
  t.track_number,
  t.duration_seconds,
  t.explicit,
  t.preferred_youtube_video_id,
  t.youtube_match_status,
  t.image_cached_url,
  t.image_original_url,
  coalesce(
    (
      select jsonb_agg(
               jsonb_build_object(
                 'artist_id', ta.artist_id,
                 'name', coalesce(ta.display_name, a.name),
                 'role', ta.role,
                 'position', ta.position
               )
               order by ta.position, ta.role
             )
      from public.track_artists ta
      join public.artists a on a.id = ta.artist_id
      where ta.track_id = t.id
    ),
    '[]'::jsonb
  ) as artists
from public.tracks t
where t.album_id is not null;

grant select on public.album_track_details to anon, authenticated;

-- Full discography of an artist, newest first, with release type.
create view public.artist_discography
with (security_invoker = true)
as
select
  aa.artist_id,
  al.id as album_id,
  al.title,
  al.album_type,
  al.release_date,
  al.release_year,
  al.cover_cached_url,
  al.cover_original_url,
  al.total_tracks,
  al.explicit,
  aa.role as artist_role
from public.album_artists aa
join public.albums al on al.id = aa.album_id
order by al.release_date desc nulls last, al.created_at desc;

grant select on public.artist_discography to anon, authenticated;

-- The truly latest dated release per artist (primary credits only).
create view public.artist_latest_release
with (security_invoker = true)
as
select distinct on (aa.artist_id)
  aa.artist_id,
  al.id as album_id,
  al.title,
  al.album_type,
  al.release_date,
  al.cover_cached_url,
  al.cover_original_url
from public.album_artists aa
join public.albums al on al.id = aa.album_id
where aa.role = 'primary'
  and al.release_date is not null
order by aa.artist_id, al.release_date desc;

grant select on public.artist_latest_release to anon, authenticated;
