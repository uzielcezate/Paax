-- ============================================================================
-- Migration: catalog_phase2_2_ingestion_upserts
-- Phase 2.2 (ADR-009 Phase 2). Atomic Deezer -> Supabase graph upserts.
--
-- Adds transactional, idempotent upsert RPCs used by the ingestion layer:
--   public.catalog_upsert_artist_graph(jsonb) returns uuid
--   public.catalog_upsert_album_graph(jsonb)  returns uuid
--   public.catalog_upsert_track_graph(jsonb)  returns uuid
-- plus private helpers (never exposed by PostgREST).
--
-- Invariants enforced here (reconciliation policy):
--   * A track upsert NEVER touches youtube_* columns or image_cached_* columns,
--     so an existing valid YouTube match / cached artwork is preserved.
--   * An album upsert NEVER touches cover_cached_url / image_cache_status /
--     cover_cached_at (cached artwork preserved).
--   * metadata_status is never downgraded from 'full' to a weaker state.
--   * metadata_updated_at is bumped ONLY on a 'full' (authoritative) upsert, so
--     partial (search-sourced) rows stay eligible for a later full ingestion.
--   * Junction rows (artists/genres) are pruned ONLY when the caller marks the
--     payload 'complete' (an authoritative full response), never for partials.
--
-- Each function is a single statement-block => one implicit transaction. No
-- half-ingested graph is left behind.
--
-- Rollback strategy:
--   drop function if exists public.catalog_upsert_artist_graph(jsonb);
--   drop function if exists public.catalog_upsert_album_graph(jsonb);
--   drop function if exists public.catalog_upsert_track_graph(jsonb);
--   drop function if exists private.catalog_upsert_artist(jsonb);
--   drop function if exists private.catalog_upsert_album_row(jsonb);
--   drop function if exists private.catalog_upsert_track_row(jsonb, uuid, boolean);
--   drop function if exists private.catalog_upsert_genre(jsonb);
-- ============================================================================

-- ---------------------------------------------------------------------------
-- private.catalog_upsert_genre(jsonb) -> uuid
-- Resolves an existing genre by deezer_id, then slug, then name; inserts if new.
-- Avoids tripping the name/slug/deezer_id unique constraints.
-- ---------------------------------------------------------------------------
create or replace function private.catalog_upsert_genre(p jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id     uuid;
  v_deezer bigint := nullif(p->>'deezer_id', '')::bigint;
  v_name   text   := nullif(p->>'name', '');
  v_slug   text   := nullif(p->>'slug', '');
begin
  if v_name is null then
    return null;
  end if;
  if v_slug is null then
    v_slug := trim(both '-' from regexp_replace(lower(v_name), '[^a-z0-9]+', '-', 'g'));
  end if;
  if v_slug is null or length(v_slug) = 0 then
    return null;
  end if;

  if v_deezer is not null then
    select id into v_id from public.genres where deezer_id = v_deezer limit 1;
  end if;
  if v_id is null then
    select id into v_id from public.genres where slug = v_slug limit 1;
  end if;
  if v_id is null then
    select id into v_id from public.genres where name = v_name limit 1;
  end if;

  if v_id is null then
    insert into public.genres (deezer_id, name, slug)
    values (v_deezer, v_name, v_slug)
    returning id into v_id;
  elsif v_deezer is not null then
    update public.genres set deezer_id = coalesce(deezer_id, v_deezer) where id = v_id;
  end if;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- private.catalog_upsert_artist(jsonb) -> uuid
-- Upserts an artist (minimal or full). Preserves cached image + does not
-- downgrade 'full' metadata. Optionally links + prunes artist_genres.
-- ---------------------------------------------------------------------------
create or replace function private.catalog_upsert_artist(p jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id       uuid;
  v_deezer   bigint  := nullif(p->>'deezer_id', '')::bigint;
  v_name     text    := nullif(p->>'name', '');
  v_status   text    := coalesce(nullif(p->>'metadata_status', ''), 'partial');
  v_complete boolean := coalesce((p->>'complete')::boolean, false);
  v_country  text    := nullif(p->>'country_code', '');
  v_full_ts  timestamptz := case when v_status = 'full' then now() else null end;
  g          jsonb;
  v_genre_id uuid;
  v_keep     uuid[] := '{}';
begin
  if v_name is null then
    return null;
  end if;
  if v_country is not null then
    v_country := upper(v_country);
    if v_country !~ '^[A-Z]{2}$' then
      v_country := null;
    end if;
  end if;

  insert into public.artists (
    deezer_id, name, normalized_name, image_original_url, deezer_fans_count,
    biography, country_code, is_verified, metadata_source, metadata_status, metadata_updated_at
  ) values (
    v_deezer, v_name, public.catalog_normalize(v_name), nullif(p->>'image_original_url',''),
    nullif(p->>'deezer_fans_count','')::bigint, nullif(p->>'biography',''), v_country,
    coalesce((p->>'is_verified')::boolean, false), 'deezer', v_status, v_full_ts
  )
  on conflict (deezer_id) do update set
    name                = excluded.name,
    normalized_name     = excluded.normalized_name,
    image_original_url  = coalesce(excluded.image_original_url, public.artists.image_original_url),
    deezer_fans_count   = coalesce(excluded.deezer_fans_count, public.artists.deezer_fans_count),
    biography           = coalesce(excluded.biography, public.artists.biography),
    country_code        = coalesce(excluded.country_code, public.artists.country_code),
    is_verified         = excluded.is_verified or public.artists.is_verified,
    metadata_status     = case when public.artists.metadata_status = 'full' and excluded.metadata_status <> 'full'
                               then 'full' else excluded.metadata_status end,
    metadata_updated_at = case when excluded.metadata_status = 'full' then now()
                               else public.artists.metadata_updated_at end
  returning id into v_id;

  if v_id is null and v_deezer is null then
    -- No deezer_id to conflict on and no row returned: insert unconditionally.
    insert into public.artists (deezer_id, name, normalized_name, metadata_source, metadata_status)
    values (null, v_name, public.catalog_normalize(v_name), 'deezer', v_status)
    returning id into v_id;
  end if;

  if p ? 'genres' then
    for g in select * from jsonb_array_elements(p->'genres') loop
      v_genre_id := private.catalog_upsert_genre(g);
      if v_genre_id is not null then
        insert into public.artist_genres (artist_id, genre_id, relevance_score, source)
        values (v_id, v_genre_id, nullif(g->>'relevance_score','')::numeric, coalesce(nullif(g->>'source',''),'deezer'))
        on conflict (artist_id, genre_id) do update set
          relevance_score = coalesce(excluded.relevance_score, public.artist_genres.relevance_score),
          source = excluded.source;
        v_keep := array_append(v_keep, v_genre_id);
      end if;
    end loop;
    if v_complete then
      delete from public.artist_genres ag
      where ag.artist_id = v_id and ag.genre_id <> all(v_keep);
    end if;
  end if;

  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- private.catalog_upsert_album_row(jsonb) -> uuid
-- Album row only (no tracks/junctions). Preserves cached cover artwork.
-- ---------------------------------------------------------------------------
create or replace function private.catalog_upsert_album_row(p jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id      uuid;
  v_deezer  bigint := nullif(p->>'deezer_id','')::bigint;
  v_title   text   := nullif(p->>'title','');
  v_status  text   := coalesce(nullif(p->>'metadata_status',''), 'partial');
  v_full_ts timestamptz := case when v_status = 'full' then now() else null end;
  v_type    text   := coalesce(nullif(p->>'album_type',''), 'album');
begin
  if v_title is null then
    return null;
  end if;
  if v_type not in ('album','single','ep','compilation','live','soundtrack','other') then
    v_type := 'other';
  end if;

  insert into public.albums (
    deezer_id, title, normalized_title, album_type, release_date, release_year,
    label, upc, cover_original_url, total_tracks, total_duration_seconds, explicit,
    metadata_source, metadata_status, metadata_updated_at
  ) values (
    v_deezer, v_title, public.catalog_normalize(v_title), v_type,
    nullif(p->>'release_date','')::date, nullif(p->>'release_year','')::smallint,
    nullif(p->>'label',''), nullif(p->>'upc',''), nullif(p->>'cover_original_url',''),
    coalesce((p->>'total_tracks')::int, 0), coalesce((p->>'total_duration_seconds')::int, 0),
    coalesce((p->>'explicit')::boolean, false), 'deezer', v_status, v_full_ts
  )
  on conflict (deezer_id) do update set
    title                  = excluded.title,
    normalized_title       = excluded.normalized_title,
    album_type             = excluded.album_type,
    release_date           = coalesce(excluded.release_date, public.albums.release_date),
    release_year           = coalesce(excluded.release_year, public.albums.release_year),
    label                  = coalesce(excluded.label, public.albums.label),
    upc                    = coalesce(excluded.upc, public.albums.upc),
    cover_original_url     = coalesce(excluded.cover_original_url, public.albums.cover_original_url),
    total_tracks           = greatest(excluded.total_tracks, public.albums.total_tracks),
    total_duration_seconds = greatest(excluded.total_duration_seconds, public.albums.total_duration_seconds),
    explicit               = excluded.explicit,
    metadata_status        = case when public.albums.metadata_status = 'full' and excluded.metadata_status <> 'full'
                                  then 'full' else excluded.metadata_status end,
    metadata_updated_at    = case when excluded.metadata_status = 'full' then now()
                                  else public.albums.metadata_updated_at end
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- private.catalog_upsert_track_row(jsonb, uuid, boolean) -> uuid
-- Upserts a track + its own credited artists + genres. PRESERVES youtube_* and
-- image_cached_* columns. Prunes credits/genres only when p_complete.
-- ---------------------------------------------------------------------------
create or replace function private.catalog_upsert_track_row(p jsonb, p_album_id uuid, p_complete boolean)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id       uuid;
  v_deezer   bigint := nullif(p->>'deezer_id','')::bigint;
  v_title    text   := nullif(p->>'title','');
  v_status   text   := coalesce(nullif(p->>'metadata_status',''), 'partial');
  v_full_ts  timestamptz := case when v_status = 'full' then now() else null end;
  a          jsonb;
  g          jsonb;
  v_artist_id uuid;
  v_genre_id  uuid;
  v_role      text;
  v_keep_art  text[] := '{}';   -- artist_id::text || ':' || role
  v_keep_gen  uuid[] := '{}';
begin
  if v_title is null then
    return null;
  end if;

  insert into public.tracks (
    deezer_id, album_id, title, title_short, normalized_title, track_number,
    disc_number, duration_seconds, explicit, isrc, image_original_url,
    metadata_source, metadata_status, metadata_updated_at
  ) values (
    v_deezer, p_album_id, v_title, nullif(p->>'title_short',''), public.catalog_normalize(v_title),
    nullif(p->>'track_number','')::int, coalesce((p->>'disc_number')::int, 1),
    coalesce((p->>'duration_seconds')::int, 0), coalesce((p->>'explicit')::boolean, false),
    nullif(p->>'isrc',''), nullif(p->>'image_original_url',''), 'deezer', v_status, v_full_ts
  )
  on conflict (deezer_id) do update set
    album_id            = coalesce(excluded.album_id, public.tracks.album_id),
    title               = excluded.title,
    title_short         = coalesce(excluded.title_short, public.tracks.title_short),
    normalized_title    = excluded.normalized_title,
    track_number        = coalesce(excluded.track_number, public.tracks.track_number),
    disc_number         = excluded.disc_number,
    duration_seconds    = excluded.duration_seconds,
    explicit            = excluded.explicit,
    isrc                = coalesce(excluded.isrc, public.tracks.isrc),
    image_original_url  = coalesce(excluded.image_original_url, public.tracks.image_original_url),
    metadata_status     = case when public.tracks.metadata_status = 'full' and excluded.metadata_status <> 'full'
                               then 'full' else excluded.metadata_status end,
    metadata_updated_at = case when excluded.metadata_status = 'full' then now()
                               else public.tracks.metadata_updated_at end
    -- youtube_* and image_cached_* columns intentionally NOT updated (preserved).
  returning id into v_id;

  -- Track credits (its OWN collaborators, never the album header's).
  if p ? 'artists' then
    for a in select * from jsonb_array_elements(p->'artists') loop
      v_artist_id := private.catalog_upsert_artist(a);
      if v_artist_id is not null then
        v_role := coalesce(nullif(a->>'role',''), 'primary');
        if v_role not in ('primary','featured','producer','composer','remixer','performer','vocalist','other') then
          v_role := 'other';
        end if;
        insert into public.track_artists (track_id, artist_id, role, position, display_name)
        values (v_id, v_artist_id, v_role, coalesce((a->>'position')::int, 1), nullif(a->>'display_name',''))
        on conflict (track_id, artist_id, role) do update set
          position = excluded.position,
          display_name = coalesce(excluded.display_name, public.track_artists.display_name);
        v_keep_art := array_append(v_keep_art, v_artist_id::text || ':' || v_role);
      end if;
    end loop;
    if p_complete then
      delete from public.track_artists ta
      where ta.track_id = v_id and (ta.artist_id::text || ':' || ta.role) <> all(v_keep_art);
    end if;
  end if;

  -- Track genres
  if p ? 'genres' then
    for g in select * from jsonb_array_elements(p->'genres') loop
      v_genre_id := private.catalog_upsert_genre(g);
      if v_genre_id is not null then
        insert into public.track_genres (track_id, genre_id, relevance_score, source)
        values (v_id, v_genre_id, nullif(g->>'relevance_score','')::numeric, coalesce(nullif(g->>'source',''),'deezer'))
        on conflict (track_id, genre_id) do update set
          relevance_score = coalesce(excluded.relevance_score, public.track_genres.relevance_score),
          source = excluded.source;
        v_keep_gen := array_append(v_keep_gen, v_genre_id);
      end if;
    end loop;
    if p_complete then
      delete from public.track_genres tg
      where tg.track_id = v_id and tg.genre_id <> all(v_keep_gen);
    end if;
  end if;

  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- public.catalog_upsert_artist_graph(jsonb) -> uuid
-- Payload: { "artist": {..., "genres":[...]}, "complete": bool } or a bare
-- artist object. Backend-only.
-- ---------------------------------------------------------------------------
create or replace function public.catalog_upsert_artist_graph(p jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_artist jsonb := coalesce(p->'artist', p);
begin
  if p ? 'complete' and not (v_artist ? 'complete') then
    v_artist := v_artist || jsonb_build_object('complete', p->'complete');
  end if;
  return private.catalog_upsert_artist(v_artist);
end;
$$;

-- ---------------------------------------------------------------------------
-- public.catalog_upsert_album_graph(jsonb) -> uuid
-- Payload:
--   { "album": {...}, "album_artists":[...], "album_genres":[...],
--     "tracks":[ {track w/ artists,genres} ], "complete": bool }
-- Full graph: artists, album, album_artists, album_genres, tracks,
-- track_artists, track_genres, genres. Backend-only.
-- ---------------------------------------------------------------------------
create or replace function public.catalog_upsert_album_graph(p jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_album_id  uuid;
  v_complete  boolean := coalesce((p->>'complete')::boolean, false);
  r           jsonb;
  v_artist_id uuid;
  v_genre_id  uuid;
  v_role      text;
  v_keep_art  text[] := '{}';
  v_keep_gen  uuid[] := '{}';
begin
  v_album_id := private.catalog_upsert_album_row(p->'album');
  if v_album_id is null then
    raise exception 'catalog_upsert_album_graph: album payload missing/invalid';
  end if;

  -- album_artists
  for r in select * from jsonb_array_elements(coalesce(p->'album_artists', '[]'::jsonb)) loop
    v_artist_id := private.catalog_upsert_artist(r);
    if v_artist_id is not null then
      v_role := coalesce(nullif(r->>'role',''), 'primary');
      if v_role not in ('primary','featured','producer','composer','remixer','performer','other') then
        v_role := 'other';
      end if;
      insert into public.album_artists (album_id, artist_id, role, position)
      values (v_album_id, v_artist_id, v_role, coalesce((r->>'position')::int, 1))
      on conflict (album_id, artist_id, role) do update set position = excluded.position;
      v_keep_art := array_append(v_keep_art, v_artist_id::text || ':' || v_role);
    end if;
  end loop;
  if v_complete then
    delete from public.album_artists aa
    where aa.album_id = v_album_id and (aa.artist_id::text || ':' || aa.role) <> all(v_keep_art);
  end if;

  -- album_genres
  for r in select * from jsonb_array_elements(coalesce(p->'album_genres', '[]'::jsonb)) loop
    v_genre_id := private.catalog_upsert_genre(r);
    if v_genre_id is not null then
      insert into public.album_genres (album_id, genre_id, relevance_score, source)
      values (v_album_id, v_genre_id, nullif(r->>'relevance_score','')::numeric, coalesce(nullif(r->>'source',''),'deezer'))
      on conflict (album_id, genre_id) do update set
        relevance_score = coalesce(excluded.relevance_score, public.album_genres.relevance_score),
        source = excluded.source;
      v_keep_gen := array_append(v_keep_gen, v_genre_id);
    end if;
  end loop;
  if v_complete then
    delete from public.album_genres ag
    where ag.album_id = v_album_id and ag.genre_id <> all(v_keep_gen);
  end if;

  -- tracks (each with its own credits/genres)
  for r in select * from jsonb_array_elements(coalesce(p->'tracks', '[]'::jsonb)) loop
    perform private.catalog_upsert_track_row(r, v_album_id, v_complete);
  end loop;

  return v_album_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- public.catalog_upsert_track_graph(jsonb) -> uuid
-- Payload: { "track": {...w/ artists,genres}, "album": {minimal album}?,
--            "complete": bool }. Backend-only.
-- ---------------------------------------------------------------------------
create or replace function public.catalog_upsert_track_graph(p jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_track    jsonb := coalesce(p->'track', p);
  v_album_id uuid  := null;
  v_complete boolean := coalesce((p->>'complete')::boolean, coalesce((v_track->>'complete')::boolean, false));
begin
  if p ? 'album' and jsonb_typeof(p->'album') = 'object' then
    v_album_id := private.catalog_upsert_album_row(p->'album');
  end if;
  return private.catalog_upsert_track_row(v_track, v_album_id, v_complete);
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants: backend-only (service_role). Never callable by anon/authenticated.
-- ---------------------------------------------------------------------------
revoke all on function public.catalog_upsert_artist_graph(jsonb) from public, anon, authenticated;
revoke all on function public.catalog_upsert_album_graph(jsonb)  from public, anon, authenticated;
revoke all on function public.catalog_upsert_track_graph(jsonb)  from public, anon, authenticated;
grant execute on function public.catalog_upsert_artist_graph(jsonb) to service_role;
grant execute on function public.catalog_upsert_album_graph(jsonb)  to service_role;
grant execute on function public.catalog_upsert_track_graph(jsonb)  to service_role;
