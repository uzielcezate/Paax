-- Phase 3.4.1.2C — authorization-checked playlist activity reader RPC.
--
-- ROOT CAUSE this fixes: the Flutter client read activity with a PostgREST
-- embedded join `playlist_activity?select=*,profiles:actor_id(...)`. But
-- `playlist_activity.actor_id` has NO foreign key to `profiles`, so PostgREST
-- cannot resolve the relationship and returns 400 (PGRST200). The activity
-- sheet swallowed this into a generic "Couldn't load activity".
--
-- Even with an FK the embed would be wrong: `profiles` RLS is own-row-only, so
-- a non-owner viewing a shared playlist would see every actor resolve to null
-- ("Deleted user"). The correct, RLS-safe fix is a SECURITY DEFINER reader that
-- authorizes via private.can_view_playlist and returns actor display fields
-- directly (username/display_name/avatar) — consistent with how the
-- collaborators list already exposes participant usernames on a viewable
-- playlist. Actor UUIDs are never exposed to the UI (the client renders
-- username/avatar only).
--
-- Authorization: private.can_view_playlist already returns false for
-- soft-deleted playlists and for unauthorized users (blocked, private,
-- non-collaborator) → this RPC raises FORBIDDEN for exactly those cases.
--
-- Additive only: new function; no table/column/RLS/publication change. The base
-- table SELECT RLS ("Activity visible with the playlist") and the realtime
-- publication membership of playlist_activity are unchanged, so realtime append
-- keeps working. Grants: authenticated only.

create or replace function public.playlist_get_activity(
  p_playlist_id uuid,
  p_limit integer default 30,
  p_before timestamptz default null
)
returns table (
  id uuid,
  playlist_id uuid,
  actor_id uuid,
  event_type text,
  created_at timestamptz,
  playlist_version bigint,
  metadata jsonb,
  grouped_change_id uuid,
  actor_username text,
  actor_display_name text,
  actor_avatar_url text,
  actor_avatar_original_url text
)
language plpgsql stable security definer set search_path to '' as $$
declare
  v_uid uuid := (select auth.uid());
begin
  if v_uid is null then raise exception 'AUTH_REQUIRED' using errcode = '28000'; end if;
  if not private.can_view_playlist(p_playlist_id, v_uid) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  return query
    select a.id, a.playlist_id, a.actor_id, a.event_type, a.created_at,
           a.playlist_version, a.metadata, a.grouped_change_id,
           pr.username, pr.display_name, pr.avatar_url, pr.avatar_original_url
    from public.playlist_activity a
    left join public.profiles pr on pr.id = a.actor_id
    where a.playlist_id = p_playlist_id
      and (p_before is null or a.created_at < p_before)
    order by a.created_at desc
    limit greatest(1, least(coalesce(p_limit, 30), 100));
end; $$;

revoke all on function public.playlist_get_activity(uuid, integer, timestamptz) from public, anon;
grant execute on function public.playlist_get_activity(uuid, integer, timestamptz) to authenticated;
