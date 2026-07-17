-- ============================================================================
-- Migration: playlists
-- Phase 1 — Supabase foundation (ADR-009).
-- Playlists with visibility, collaboration, reorderable tracks (separate row
-- id), follows/downloads, and trigger-maintained count/duration counters.
--
-- Visibility semantics (documented in docs/features/playlist.md):
--   private   -> owner + collaborators only
--   followers -> owner + collaborators + accepted friends of the owner
--   unlisted  -> readable by anyone who has the id (not surfaced in discovery)
--   public    -> readable by everyone (incl. anonymous)
--
-- Rollback strategy (reverse order):
--   drop view if exists public.playlist_summary;
--   drop table if exists public.user_downloaded_playlists,
--     public.user_followed_playlists, public.playlist_collaborators,
--     public.playlist_tracks, public.playlists cascade;
--   drop function if exists private.can_view_playlist(uuid, uuid),
--     private.can_edit_playlist(uuid, uuid),
--     private.bump_playlist_followers(), private.refresh_playlist_totals() cascade;
-- ============================================================================

create table public.playlists (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  name text not null,
  description text,
  cover_url text,
  visibility text not null default 'private',
  collaborative boolean not null default false,
  -- Denormalized; derived from user_followed_playlists via private trigger only.
  platform_followers_count bigint not null default 0,
  -- Denormalized; derived from playlist_tracks via private trigger only.
  total_tracks integer not null default 0,
  total_duration_seconds integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint playlists_name_not_empty check (length(trim(name)) > 0),
  constraint playlists_visibility_valid
    check (visibility in ('private','followers','unlisted','public')),
  constraint playlists_followers_nonnegative check (platform_followers_count >= 0),
  constraint playlists_total_tracks_nonnegative check (total_tracks >= 0),
  constraint playlists_total_duration_nonnegative check (total_duration_seconds >= 0)
);

create index idx_playlists_owner_id on public.playlists (owner_id);
create index idx_playlists_public on public.playlists (created_at desc)
  where visibility = 'public';

create trigger set_playlists_updated_at
  before update on public.playlists
  for each row execute function public.set_updated_at();

-- Separate row id so tracks can be reordered and (if the product later
-- permits) repeated within a playlist.
create table public.playlist_tracks (
  id uuid primary key default gen_random_uuid(),
  playlist_id uuid not null references public.playlists(id) on delete cascade,
  track_id uuid not null references public.tracks(id) on delete cascade,
  added_by uuid references public.profiles(id) on delete set null,
  position integer not null default 1,
  added_at timestamptz not null default now(),

  constraint playlist_tracks_position_positive check (position >= 1)
);

create index idx_playlist_tracks_playlist_position
  on public.playlist_tracks (playlist_id, position);
create index idx_playlist_tracks_track_id on public.playlist_tracks (track_id);
create index idx_playlist_tracks_added_by on public.playlist_tracks (added_by);

create table public.playlist_collaborators (
  playlist_id uuid not null references public.playlists(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role text not null default 'viewer',
  created_at timestamptz not null default now(),
  primary key (playlist_id, user_id),
  constraint playlist_collaborators_role_valid
    check (role in ('viewer','editor','owner'))
);
create index idx_playlist_collaborators_user_id
  on public.playlist_collaborators (user_id);

create table public.user_followed_playlists (
  user_id uuid not null references public.profiles(id) on delete cascade,
  playlist_id uuid not null references public.playlists(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, playlist_id)
);
create index idx_user_followed_playlists_playlist_id
  on public.user_followed_playlists (playlist_id);

create table public.user_downloaded_playlists (
  user_id uuid not null references public.profiles(id) on delete cascade,
  playlist_id uuid not null references public.playlists(id) on delete cascade,
  downloaded_at timestamptz not null default now(),
  local_status text not null default 'pending',
  device_id text not null default '',
  last_synced_at timestamptz,
  primary key (user_id, playlist_id, device_id),
  constraint udp_local_status_valid
    check (local_status in ('pending','downloading','downloaded','failed','removed'))
);
create index idx_udp_playlist_id on public.user_downloaded_playlists (playlist_id);

-- ---------------------------------------------------------------------------
-- Authorization helpers (security definer, non-exposed schema, fixed
-- search_path). These exist to avoid recursive RLS between playlists and
-- playlist_collaborators.
-- ---------------------------------------------------------------------------
create or replace function private.can_view_playlist(p_playlist_id uuid, p_user_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_owner uuid;
  v_visibility text;
begin
  select owner_id, visibility into v_owner, v_visibility
  from public.playlists where id = p_playlist_id;

  if not found then
    return false;
  end if;

  if v_visibility in ('public', 'unlisted') then
    return true;
  end if;

  if p_user_id is null then
    return false;
  end if;

  if v_owner = p_user_id then
    return true;
  end if;

  if exists (select 1 from public.playlist_collaborators c
             where c.playlist_id = p_playlist_id and c.user_id = p_user_id) then
    return true;
  end if;

  if v_visibility = 'followers' then
    return private.is_accepted_friend(v_owner, p_user_id);
  end if;

  return false;
end;
$$;

create or replace function private.can_edit_playlist(p_playlist_id uuid, p_user_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_owner uuid;
  v_collaborative boolean;
begin
  if p_user_id is null then
    return false;
  end if;

  select owner_id, collaborative into v_owner, v_collaborative
  from public.playlists where id = p_playlist_id;

  if not found then
    return false;
  end if;

  if v_owner = p_user_id then
    return true;
  end if;

  return v_collaborative and exists (
    select 1 from public.playlist_collaborators c
    where c.playlist_id = p_playlist_id
      and c.user_id = p_user_id
      and c.role in ('editor','owner')
  );
end;
$$;

-- Used inside RLS policies, which evaluate with the caller's privileges, so
-- anon/authenticated need EXECUTE. Not API-callable (private schema is not
-- exposed by PostgREST).
revoke execute on function private.can_view_playlist(uuid, uuid) from public;
revoke execute on function private.can_edit_playlist(uuid, uuid) from public;
grant execute on function private.can_view_playlist(uuid, uuid) to anon, authenticated;
grant execute on function private.can_edit_playlist(uuid, uuid) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Counter triggers
-- ---------------------------------------------------------------------------
create or replace function private.bump_playlist_followers()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    update public.playlists set platform_followers_count = platform_followers_count + 1
      where id = new.playlist_id;
    return new;
  elsif tg_op = 'DELETE' then
    update public.playlists
      set platform_followers_count = greatest(platform_followers_count - 1, 0)
      where id = old.playlist_id;
    return old;
  end if;
  return null;
end;
$$;

create or replace function private.refresh_playlist_totals()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_playlist_id uuid;
begin
  v_playlist_id := coalesce(new.playlist_id, old.playlist_id);
  update public.playlists p
  set total_tracks = agg.cnt,
      total_duration_seconds = agg.dur
  from (
    select count(*) as cnt, coalesce(sum(t.duration_seconds), 0) as dur
    from public.playlist_tracks pt
    join public.tracks t on t.id = pt.track_id
    where pt.playlist_id = v_playlist_id
  ) agg
  where p.id = v_playlist_id;
  return coalesce(new, old);
end;
$$;

revoke execute on function private.bump_playlist_followers() from public, anon, authenticated;
revoke execute on function private.refresh_playlist_totals() from public, anon, authenticated;

create trigger bump_playlist_followers
  after insert or delete on public.user_followed_playlists
  for each row execute function private.bump_playlist_followers();

create trigger refresh_playlist_totals
  after insert or update or delete on public.playlist_tracks
  for each row execute function private.refresh_playlist_totals();

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.playlists enable row level security;
alter table public.playlist_tracks enable row level security;
alter table public.playlist_collaborators enable row level security;
alter table public.user_followed_playlists enable row level security;
alter table public.user_downloaded_playlists enable row level security;

-- playlists
create policy "Playlists visible per visibility rules" on public.playlists
  for select to anon, authenticated
  using (private.can_view_playlist(id, (select auth.uid())));
create policy "Users create their own playlists" on public.playlists
  for insert to authenticated
  with check ((select auth.uid()) = owner_id);
create policy "Owners update their playlists" on public.playlists
  for update to authenticated
  using ((select auth.uid()) = owner_id)
  with check ((select auth.uid()) = owner_id);
create policy "Owners delete their playlists" on public.playlists
  for delete to authenticated
  using ((select auth.uid()) = owner_id);

-- playlist_tracks: view follows playlist visibility; edits require ownership
-- or an editor seat on a collaborative playlist.
create policy "Playlist tracks visible with the playlist" on public.playlist_tracks
  for select to anon, authenticated
  using (private.can_view_playlist(playlist_id, (select auth.uid())));
create policy "Editors add playlist tracks" on public.playlist_tracks
  for insert to authenticated
  with check (
    private.can_edit_playlist(playlist_id, (select auth.uid()))
    and added_by = (select auth.uid())
  );
create policy "Editors reorder playlist tracks" on public.playlist_tracks
  for update to authenticated
  using (private.can_edit_playlist(playlist_id, (select auth.uid())))
  with check (private.can_edit_playlist(playlist_id, (select auth.uid())));
create policy "Editors remove playlist tracks" on public.playlist_tracks
  for delete to authenticated
  using (private.can_edit_playlist(playlist_id, (select auth.uid())));

-- playlist_collaborators: only the playlist owner manages seats; collaborators
-- can see the seat list of playlists they can view.
create policy "Collaborator lists visible with the playlist"
  on public.playlist_collaborators
  for select to authenticated
  using (private.can_view_playlist(playlist_id, (select auth.uid())));
create policy "Owners add collaborators" on public.playlist_collaborators
  for insert to authenticated
  with check (exists (
    select 1 from public.playlists p
    where p.id = playlist_id and p.owner_id = (select auth.uid())
  ));
create policy "Owners change collaborator roles" on public.playlist_collaborators
  for update to authenticated
  using (exists (
    select 1 from public.playlists p
    where p.id = playlist_id and p.owner_id = (select auth.uid())
  ))
  with check (exists (
    select 1 from public.playlists p
    where p.id = playlist_id and p.owner_id = (select auth.uid())
  ));
create policy "Owners remove collaborators; collaborators may leave"
  on public.playlist_collaborators
  for delete to authenticated
  using (
    user_id = (select auth.uid())
    or exists (
      select 1 from public.playlists p
      where p.id = playlist_id and p.owner_id = (select auth.uid())
    )
  );

-- follows / downloads: own rows only (and only for viewable playlists).
create policy "Users read their own followed playlists" on public.user_followed_playlists
  for select to authenticated using ((select auth.uid()) = user_id);
create policy "Users follow viewable playlists" on public.user_followed_playlists
  for insert to authenticated
  with check (
    (select auth.uid()) = user_id
    and private.can_view_playlist(playlist_id, (select auth.uid()))
  );
create policy "Users unfollow their own playlists" on public.user_followed_playlists
  for delete to authenticated using ((select auth.uid()) = user_id);

create policy "Users read their own downloaded playlists" on public.user_downloaded_playlists
  for select to authenticated using ((select auth.uid()) = user_id);
create policy "Users record their own playlist downloads" on public.user_downloaded_playlists
  for insert to authenticated
  with check (
    (select auth.uid()) = user_id
    and private.can_view_playlist(playlist_id, (select auth.uid()))
  );
create policy "Users update their own playlist download state"
  on public.user_downloaded_playlists
  for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);
create policy "Users remove their own playlist downloads" on public.user_downloaded_playlists
  for delete to authenticated using ((select auth.uid()) = user_id);

-- ---------------------------------------------------------------------------
-- playlist_summary — live aggregation (honors RLS via security_invoker).
-- ---------------------------------------------------------------------------
create view public.playlist_summary
with (security_invoker = true)
as
select
  p.id as playlist_id,
  p.name,
  p.owner_id,
  p.visibility,
  count(pt.id) as track_count,
  coalesce(sum(t.duration_seconds), 0)::bigint as total_duration_seconds
from public.playlists p
left join public.playlist_tracks pt on pt.playlist_id = p.id
left join public.tracks t on t.id = pt.track_id
group by p.id, p.name, p.owner_id, p.visibility;

grant select on public.playlist_summary to anon, authenticated;
