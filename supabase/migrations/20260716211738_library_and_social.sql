-- ============================================================================
-- Migration: library_and_social
-- Phase 1 — Supabase foundation (ADR-009).
-- User library relations (likes / saves / follows), listening history,
-- download sync-state, friendships, backend-only play qualification, and the
-- security-definer counter triggers that keep denormalized counters honest.
--
-- Counter strategy (documented in docs/database.md):
--   * artists.platform_followers_count  <- user_followed_artists (trigger)
--   * genres.platform_followers_count   <- user_followed_genres (trigger)
--   * tracks.platform_likes_count       <- user_liked_tracks (trigger)
--   * albums.platform_likes_count       <- user_saved_albums (trigger)
--   * tracks/albums platform_play_count <- private.record_qualified_play
--     (backend/service-role ONLY; clients can never self-qualify a play)
--
-- Rollback strategy (reverse order):
--   drop function if exists private.record_qualified_play(uuid);
--   drop table if exists public.user_friendships,
--     public.user_downloaded_albums, public.user_downloaded_tracks,
--     public.user_listening_history, public.user_followed_genres,
--     public.user_followed_artists, public.user_saved_albums,
--     public.user_liked_tracks cascade;
--   drop function if exists private.bump_artist_followers(),
--     private.bump_genre_followers(), private.bump_track_likes(),
--     private.bump_album_likes() cascade;
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Likes / saves / follows
-- ---------------------------------------------------------------------------
create table public.user_liked_tracks (
  user_id uuid not null references public.profiles(id) on delete cascade,
  track_id uuid not null references public.tracks(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, track_id)
);
create index idx_user_liked_tracks_track_id on public.user_liked_tracks (track_id);

create table public.user_saved_albums (
  user_id uuid not null references public.profiles(id) on delete cascade,
  album_id uuid not null references public.albums(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, album_id)
);
create index idx_user_saved_albums_album_id on public.user_saved_albums (album_id);

create table public.user_followed_artists (
  user_id uuid not null references public.profiles(id) on delete cascade,
  artist_id uuid not null references public.artists(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, artist_id)
);
create index idx_user_followed_artists_artist_id
  on public.user_followed_artists (artist_id);

create table public.user_followed_genres (
  user_id uuid not null references public.profiles(id) on delete cascade,
  genre_id uuid not null references public.genres(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, genre_id)
);
create index idx_user_followed_genres_genre_id
  on public.user_followed_genres (genre_id);

-- ---------------------------------------------------------------------------
-- Listening history (event table).
-- Clients may insert their own events but qualified_as_play is FORCED false
-- at the policy level; only private.record_qualified_play (backend) can
-- qualify an event and bump global play counters.
-- ---------------------------------------------------------------------------
create table public.user_listening_history (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  track_id uuid not null references public.tracks(id) on delete cascade,
  played_at timestamptz not null default now(),
  started_at timestamptz,
  ended_at timestamptz,
  listened_seconds integer,
  completion_percentage numeric,
  playback_source text,
  session_id uuid,
  device_id text,
  qualified_as_play boolean not null default false,
  created_at timestamptz not null default now(),

  constraint ulh_listened_seconds_nonnegative
    check (listened_seconds is null or listened_seconds >= 0),
  constraint ulh_completion_range
    check (completion_percentage is null
           or (completion_percentage >= 0 and completion_percentage <= 100)),
  constraint ulh_playback_source_valid
    check (playback_source is null or playback_source in
      ('search','album','playlist','artist','library','chart','radio','history','story','other'))
);

create index idx_ulh_user_played_at
  on public.user_listening_history (user_id, played_at desc);
create index idx_ulh_track_id on public.user_listening_history (track_id);
create index idx_ulh_qualified
  on public.user_listening_history (track_id) where qualified_as_play;

-- ---------------------------------------------------------------------------
-- Download sync-state (metadata only — NEVER audio bytes).
-- ---------------------------------------------------------------------------
create table public.user_downloaded_tracks (
  user_id uuid not null references public.profiles(id) on delete cascade,
  track_id uuid not null references public.tracks(id) on delete cascade,
  downloaded_at timestamptz not null default now(),
  local_status text not null default 'pending',
  device_id text not null default '',
  last_synced_at timestamptz,
  primary key (user_id, track_id, device_id),
  constraint udt_local_status_valid
    check (local_status in ('pending','downloading','downloaded','failed','removed'))
);
create index idx_udt_track_id on public.user_downloaded_tracks (track_id);

create table public.user_downloaded_albums (
  user_id uuid not null references public.profiles(id) on delete cascade,
  album_id uuid not null references public.albums(id) on delete cascade,
  downloaded_at timestamptz not null default now(),
  local_status text not null default 'pending',
  device_id text not null default '',
  last_synced_at timestamptz,
  primary key (user_id, album_id, device_id),
  constraint uda_local_status_valid
    check (local_status in ('pending','downloading','downloaded','failed','removed'))
);
create index idx_uda_album_id on public.user_downloaded_albums (album_id);

-- ---------------------------------------------------------------------------
-- Friendships. Uniqueness strategy: one logical relationship per pair,
-- regardless of direction, enforced by a unique index on the ordered pair.
-- ---------------------------------------------------------------------------
create table public.user_friendships (
  requester_id uuid not null references public.profiles(id) on delete cascade,
  addressee_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'pending',
  created_at timestamptz not null default now(),
  accepted_at timestamptz,
  updated_at timestamptz not null default now(),

  primary key (requester_id, addressee_id),
  constraint friendships_no_self check (requester_id <> addressee_id),
  constraint friendships_status_valid
    check (status in ('pending','accepted','declined','blocked','removed'))
);

-- Prevents A->B and B->A coexisting.
create unique index idx_friendships_unique_pair
  on public.user_friendships (least(requester_id, addressee_id),
                              greatest(requester_id, addressee_id));
create index idx_friendships_addressee on public.user_friendships (addressee_id);

create trigger set_user_friendships_updated_at
  before update on public.user_friendships
  for each row execute function public.set_updated_at();

-- Participants may update status, but never re-point the relationship.
create or replace function private.protect_friendship_parties()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.requester_id is distinct from old.requester_id
     or new.addressee_id is distinct from old.addressee_id then
    raise exception 'friendship participants cannot be changed'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger protect_friendship_parties
  before update on public.user_friendships
  for each row execute function private.protect_friendship_parties();

-- Helper used by playlist/story visibility rules ("followers" == accepted friends).
create or replace function private.is_accepted_friend(a uuid, b uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.user_friendships f
    where f.status = 'accepted'
      and least(f.requester_id, f.addressee_id) = least(a, b)
      and greatest(f.requester_id, f.addressee_id) = greatest(a, b)
  );
$$;

revoke execute on function private.is_accepted_friend(uuid, uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Denormalized counter triggers (security definer, private schema — the ONLY
-- write path from user actions into catalog counters).
-- ---------------------------------------------------------------------------
create or replace function private.bump_artist_followers()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    update public.artists set platform_followers_count = platform_followers_count + 1
      where id = new.artist_id;
    return new;
  elsif tg_op = 'DELETE' then
    update public.artists
      set platform_followers_count = greatest(platform_followers_count - 1, 0)
      where id = old.artist_id;
    return old;
  end if;
  return null;
end;
$$;

create or replace function private.bump_genre_followers()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    update public.genres set platform_followers_count = platform_followers_count + 1
      where id = new.genre_id;
    return new;
  elsif tg_op = 'DELETE' then
    update public.genres
      set platform_followers_count = greatest(platform_followers_count - 1, 0)
      where id = old.genre_id;
    return old;
  end if;
  return null;
end;
$$;

create or replace function private.bump_track_likes()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    update public.tracks set platform_likes_count = platform_likes_count + 1
      where id = new.track_id;
    return new;
  elsif tg_op = 'DELETE' then
    update public.tracks
      set platform_likes_count = greatest(platform_likes_count - 1, 0)
      where id = old.track_id;
    return old;
  end if;
  return null;
end;
$$;

create or replace function private.bump_album_likes()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    update public.albums set platform_likes_count = platform_likes_count + 1
      where id = new.album_id;
    return new;
  elsif tg_op = 'DELETE' then
    update public.albums
      set platform_likes_count = greatest(platform_likes_count - 1, 0)
      where id = old.album_id;
    return old;
  end if;
  return null;
end;
$$;

revoke execute on function private.bump_artist_followers() from public, anon, authenticated;
revoke execute on function private.bump_genre_followers() from public, anon, authenticated;
revoke execute on function private.bump_track_likes() from public, anon, authenticated;
revoke execute on function private.bump_album_likes() from public, anon, authenticated;

create trigger bump_artist_followers
  after insert or delete on public.user_followed_artists
  for each row execute function private.bump_artist_followers();
create trigger bump_genre_followers
  after insert or delete on public.user_followed_genres
  for each row execute function private.bump_genre_followers();
create trigger bump_track_likes
  after insert or delete on public.user_liked_tracks
  for each row execute function private.bump_track_likes();
create trigger bump_album_likes
  after insert or delete on public.user_saved_albums
  for each row execute function private.bump_album_likes();

-- ---------------------------------------------------------------------------
-- Backend-only play qualification. NOT exposed to clients: it lives in the
-- non-exposed `private` schema and EXECUTE is revoked from anon/authenticated.
-- Qualification rule (provisional, documented): >= 30 listened seconds or
-- >= 50% completion. Idempotent: a qualified event never re-qualifies.
-- ---------------------------------------------------------------------------
create or replace function private.record_qualified_play(p_history_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event public.user_listening_history%rowtype;
begin
  select * into v_event
  from public.user_listening_history
  where id = p_history_id
  for update;

  if not found or v_event.qualified_as_play then
    return false;
  end if;

  if coalesce(v_event.listened_seconds, 0) < 30
     and coalesce(v_event.completion_percentage, 0) < 50 then
    return false;
  end if;

  update public.user_listening_history
    set qualified_as_play = true
    where id = p_history_id;

  update public.tracks
    set platform_play_count = platform_play_count + 1
    where id = v_event.track_id;

  update public.albums a
    set platform_play_count = a.platform_play_count + 1
    from public.tracks t
    where t.id = v_event.track_id and a.id = t.album_id;

  return true;
end;
$$;

revoke execute on function private.record_qualified_play(uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- RLS — strict own-data policies.
-- ---------------------------------------------------------------------------
alter table public.user_liked_tracks enable row level security;
alter table public.user_saved_albums enable row level security;
alter table public.user_followed_artists enable row level security;
alter table public.user_followed_genres enable row level security;
alter table public.user_listening_history enable row level security;
alter table public.user_downloaded_tracks enable row level security;
alter table public.user_downloaded_albums enable row level security;
alter table public.user_friendships enable row level security;

-- Likes
create policy "Users read their own likes" on public.user_liked_tracks
  for select to authenticated using ((select auth.uid()) = user_id);
create policy "Users add their own likes" on public.user_liked_tracks
  for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "Users remove their own likes" on public.user_liked_tracks
  for delete to authenticated using ((select auth.uid()) = user_id);

-- Saved albums
create policy "Users read their own saved albums" on public.user_saved_albums
  for select to authenticated using ((select auth.uid()) = user_id);
create policy "Users save albums for themselves" on public.user_saved_albums
  for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "Users unsave their own albums" on public.user_saved_albums
  for delete to authenticated using ((select auth.uid()) = user_id);

-- Followed artists
create policy "Users read their own followed artists" on public.user_followed_artists
  for select to authenticated using ((select auth.uid()) = user_id);
create policy "Users follow artists for themselves" on public.user_followed_artists
  for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "Users unfollow their own artists" on public.user_followed_artists
  for delete to authenticated using ((select auth.uid()) = user_id);

-- Followed genres
create policy "Users read their own followed genres" on public.user_followed_genres
  for select to authenticated using ((select auth.uid()) = user_id);
create policy "Users follow genres for themselves" on public.user_followed_genres
  for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "Users unfollow their own genres" on public.user_followed_genres
  for delete to authenticated using ((select auth.uid()) = user_id);

-- Listening history: insert own, NEVER pre-qualified; read/delete own.
-- No UPDATE policy: events are immutable for clients.
create policy "Users read their own listening history" on public.user_listening_history
  for select to authenticated using ((select auth.uid()) = user_id);
create policy "Users insert their own unqualified listening events"
  on public.user_listening_history
  for insert to authenticated
  with check ((select auth.uid()) = user_id and qualified_as_play = false);
create policy "Users delete their own listening history" on public.user_listening_history
  for delete to authenticated using ((select auth.uid()) = user_id);

-- Downloads (tracks)
create policy "Users read their own downloaded tracks" on public.user_downloaded_tracks
  for select to authenticated using ((select auth.uid()) = user_id);
create policy "Users record their own track downloads" on public.user_downloaded_tracks
  for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "Users update their own track download state" on public.user_downloaded_tracks
  for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);
create policy "Users remove their own track downloads" on public.user_downloaded_tracks
  for delete to authenticated using ((select auth.uid()) = user_id);

-- Downloads (albums)
create policy "Users read their own downloaded albums" on public.user_downloaded_albums
  for select to authenticated using ((select auth.uid()) = user_id);
create policy "Users record their own album downloads" on public.user_downloaded_albums
  for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "Users update their own album download state" on public.user_downloaded_albums
  for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);
create policy "Users remove their own album downloads" on public.user_downloaded_albums
  for delete to authenticated using ((select auth.uid()) = user_id);

-- Friendships: either participant may read/update; only the requester creates
-- (always as 'pending'); either participant may delete their side.
create policy "Participants read their friendships" on public.user_friendships
  for select to authenticated
  using ((select auth.uid()) in (requester_id, addressee_id));
create policy "Users send friend requests" on public.user_friendships
  for insert to authenticated
  with check ((select auth.uid()) = requester_id and status = 'pending');
create policy "Participants update their friendships" on public.user_friendships
  for update to authenticated
  using ((select auth.uid()) in (requester_id, addressee_id))
  with check ((select auth.uid()) in (requester_id, addressee_id));
create policy "Participants remove their friendships" on public.user_friendships
  for delete to authenticated
  using ((select auth.uid()) in (requester_id, addressee_id));
