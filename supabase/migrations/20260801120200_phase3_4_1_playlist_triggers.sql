-- Phase 3.4.1 — trigger-maintained counters + append-only activity helper.
-- track_count / total_duration_seconds / follower count are NEVER trusted from
-- the client; they are maintained here. version + updated_at for metadata edits
-- are owned by the RPCs (one bump per grouped operation). Follow/unfollow must
-- NOT touch last_modified_at or updated_at (only the follower counter).

-- Track membership/order change → recompute counts + stamp modification time.
create or replace function private.tg_playlist_tracks_counters()
returns trigger language plpgsql security definer set search_path to '' as $$
declare v_pid uuid;
begin
  v_pid := coalesce(new.playlist_id, old.playlist_id);
  update public.playlists p set
    total_tracks = (select count(*) from public.playlist_tracks t where t.playlist_id = v_pid),
    total_duration_seconds = coalesce((
      select sum(coalesce(tr.duration_seconds, 0))
      from public.playlist_tracks t
      join public.tracks tr on tr.id = t.track_id
      where t.playlist_id = v_pid), 0),
    updated_at = now(),
    last_modified_at = now(),
    last_modified_by = coalesce((select auth.uid()), p.last_modified_by)
  where p.id = v_pid;
  return null;
end;
$$;

drop trigger if exists trg_playlist_tracks_counters on public.playlist_tracks;
create trigger trg_playlist_tracks_counters
  after insert or delete or update on public.playlist_tracks
  for each row execute function private.tg_playlist_tracks_counters();

-- Follower count (mirrors the artists pattern). Does NOT touch modification time.
create or replace function private.tg_playlist_followers_count()
returns trigger language plpgsql security definer set search_path to '' as $$
begin
  if tg_op = 'INSERT' then
    update public.playlists
      set platform_followers_count = platform_followers_count + 1
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

drop trigger if exists trg_playlist_followers_count on public.user_followed_playlists;
create trigger trg_playlist_followers_count
  after insert or delete on public.user_followed_playlists
  for each row execute function private.tg_playlist_followers_count();

-- Append-only activity logger (called only by trusted RPCs).
create or replace function private.log_playlist_activity(
  p_playlist_id uuid, p_actor uuid, p_event text,
  p_metadata jsonb default '{}'::jsonb, p_grouped uuid default null)
returns void language plpgsql security definer set search_path to '' as $$
declare v_version bigint;
begin
  select version into v_version from public.playlists where id = p_playlist_id;
  insert into public.playlist_activity(
    playlist_id, actor_id, event_type, playlist_version, metadata, grouped_change_id)
  values (p_playlist_id, p_actor, p_event, v_version, coalesce(p_metadata, '{}'::jsonb), p_grouped);
end;
$$;
revoke all on function private.log_playlist_activity(uuid, uuid, text, jsonb, uuid)
  from public, anon, authenticated;
