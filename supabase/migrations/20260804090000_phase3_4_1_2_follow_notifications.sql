-- Phase 3.4.1.2 — follow notifications + actor avatar in the notification payload.
-- Additive: no schema change. (1) The trusted emitter now also carries the actor
-- avatar and knows the follow/unfollow copy. (2) playlist_set_follow emits a
-- single owner notification on a NEW follow (never self, never on an idempotent
-- repeat), deduped per (owner, follower, playlist). Unfollow is intentionally
-- silent (product decision: avoid follow/unfollow inbox spam). Following does NOT
-- touch playlists.updated_at / last_modified_at / last_modified_by — the follower
-- counter is maintained by the pre-existing bump_playlist_followers trigger, which
-- only writes platform_followers_count. Clients still cannot create notifications
-- (RLS has no INSERT policy; the emitter's EXECUTE is revoked from all roles).

create or replace function private.emit_playlist_notification(
  p_recipient uuid, p_actor uuid, p_type text, p_playlist_id uuid, p_dedupe text default null)
returns void language plpgsql security definer set search_path to '' as $$
declare v_title text; v_cover text; v_actor text; v_avatar text; v_body text;
begin
  if p_recipient is null then return; end if;
  select name, cover_url into v_title, v_cover from public.playlists where id = p_playlist_id;
  select coalesce(username, display_name), coalesce(avatar_url, avatar_original_url)
    into v_actor, v_avatar from public.profiles where id = p_actor;
  v_body := case p_type
    when 'playlist_collaboration_invited'  then coalesce(v_actor,'A user')||' invited you to collaborate'
    when 'playlist_collaboration_accepted' then coalesce(v_actor,'A user')||' accepted your invitation'
    when 'playlist_collaboration_declined' then coalesce(v_actor,'A user')||' declined your invitation'
    when 'playlist_collaborator_removed'   then 'You were removed from a playlist'
    when 'playlist_collaborator_left'      then coalesce(v_actor,'A user')||' left your playlist'
    when 'playlist_ownership_transferred'  then 'You are now the owner of a playlist'
    when 'playlist_followed'               then coalesce(v_actor,'A user')||' followed your playlist'
    when 'playlist_unfollowed'             then coalesce(v_actor,'A user')||' unfollowed your playlist'
    else 'Playlist update' end;
  insert into public.notifications(
    user_id, actor_user_id, type, title, body, data, entity_type, entity_id, dedupe_key)
  values (p_recipient, p_actor, p_type, coalesce(v_title,'Playlist'), v_body,
    jsonb_build_object('playlist_id', p_playlist_id, 'playlist_title', v_title,
      'playlist_cover', v_cover, 'actor_id', p_actor, 'actor_username', v_actor,
      'actor_avatar', v_avatar),
    'playlist', p_playlist_id, p_dedupe)
  on conflict (user_id, dedupe_key) where dedupe_key is not null and deleted_at is null
  do update set actor_user_id = excluded.actor_user_id, body = excluded.body,
    data = excluded.data, read_at = null, acted_at = null, created_at = now();
end; $$;
revoke all on function private.emit_playlist_notification(uuid,uuid,text,uuid,text) from public, anon, authenticated;

create or replace function public.playlist_set_follow(p_playlist_id uuid, p_follow boolean)
returns bigint language plpgsql security definer set search_path to '' as $$
declare v_uid uuid := (select auth.uid()); v_count bigint; v_owner uuid;
begin
  if v_uid is null then raise exception 'AUTH_REQUIRED' using errcode = '28000'; end if;
  if not private.can_view_playlist(p_playlist_id, v_uid) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_follow then
    insert into public.user_followed_playlists(user_id, playlist_id)
      values (v_uid, p_playlist_id) on conflict do nothing;
    -- FOUND is true only when a row was actually inserted (a NEW follow) — an
    -- idempotent repeat conflicts → no row → no duplicate notification.
    if found then
      select owner_id into v_owner from public.playlists where id = p_playlist_id and deleted_at is null;
      if v_owner is not null and v_owner <> v_uid then
        perform private.emit_playlist_notification(v_owner, v_uid, 'playlist_followed',
          p_playlist_id, 'pl_follow:'||p_playlist_id::text||':'||v_uid::text);
      end if;
    end if;
  else
    delete from public.user_followed_playlists where user_id = v_uid and playlist_id = p_playlist_id;
    -- Product decision: unfollow does NOT create an inbox notification (avoids
    -- follow/unfollow spam). A later re-follow refreshes the existing deduped row.
  end if;
  select platform_followers_count into v_count from public.playlists where id = p_playlist_id;
  return coalesce(v_count, 0);
end; $$;
