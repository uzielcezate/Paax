-- Phase 3.4.1.2B — admin-only hard purge of SOFT-DELETED playlists.
--
-- The USER delete contract stays soft-delete (playlist_delete sets deleted_at).
-- This function is a separate, admin-only maintenance tool for permanently
-- removing already-soft-deleted test/junk data. It is NOT callable by clients
-- (EXECUTE revoked from public/anon/authenticated; lives in the private schema,
-- which PostgREST does not expose) — only service_role / direct SQL can run it.
--
-- Safety: it REFUSES to purge a live (deleted_at IS NULL) playlist, so it can
-- never be used to bypass soft-delete. FK cascades remove playlist_tracks,
-- playlist_collaborators, playlist_activity, user_followed_playlists and
-- user_downloaded_playlists; notification references (no FK) and clone
-- source_playlist_id back-references are cleaned explicitly.

create or replace function private.purge_soft_deleted_playlist(p_playlist_id uuid)
returns boolean language plpgsql security definer set search_path to '' as $$
declare v_deleted timestamptz;
begin
  select deleted_at into v_deleted from public.playlists where id = p_playlist_id;
  if not found then return false; end if;
  if v_deleted is null then
    raise exception 'REFUSE_PURGE_LIVE_PLAYLIST: %', p_playlist_id;
  end if;
  -- No FK on these — clean explicitly.
  delete from public.notifications where entity_type = 'playlist' and entity_id = p_playlist_id;
  update public.playlists set source_playlist_id = null where source_playlist_id = p_playlist_id;
  -- Cascades handle playlist_tracks / collaborators / activity / followers / downloads.
  delete from public.playlists where id = p_playlist_id;
  return true;
end; $$;
revoke all on function private.purge_soft_deleted_playlist(uuid) from public, anon, authenticated;
