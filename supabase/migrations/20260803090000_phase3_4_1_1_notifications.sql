-- Phase 3.4.1.1 — collaboration notifications. Additive: extend the existing
-- `notifications` table, add a trusted emit helper, wire it into the collab
-- RPCs (same transaction), and enable realtime. RLS stays own-rows; there is no
-- client INSERT policy, so notifications can only be created by trusted RPCs.

alter table public.notifications
  add column if not exists actor_user_id uuid,
  add column if not exists entity_type text,
  add column if not exists entity_id uuid,
  add column if not exists acted_at timestamptz,
  add column if not exists dedupe_key text,
  add column if not exists deleted_at timestamptz;

-- Dedupe active (undeleted) notifications by (recipient, dedupe_key) so a
-- re-invite refreshes one row instead of stacking duplicates.
create unique index if not exists notifications_dedupe_uidx
  on public.notifications(user_id, dedupe_key)
  where dedupe_key is not null and deleted_at is null;

create index if not exists idx_notifications_user_created
  on public.notifications(user_id, created_at desc);

-- Realtime for the bell/list (RLS still governs delivery — own rows only).
do $$ begin
  if not exists (select 1 from pg_publication_tables
      where pubname='supabase_realtime' and schemaname='public' and tablename='notifications') then
    alter publication supabase_realtime add table public.notifications;
  end if;
end $$;

-- Trusted emitter: builds a bounded, display-safe payload (playlist title/cover
-- + actor username — the minimum needed for an invite; never raw private track
-- data). Called only from SECURITY DEFINER RPCs.
create or replace function private.emit_playlist_notification(
  p_recipient uuid, p_actor uuid, p_type text, p_playlist_id uuid, p_dedupe text default null)
returns void language plpgsql security definer set search_path to '' as $$
declare v_title text; v_cover text; v_actor text; v_body text;
begin
  if p_recipient is null then return; end if;
  select name, cover_url into v_title, v_cover from public.playlists where id = p_playlist_id;
  select coalesce(username, display_name) into v_actor from public.profiles where id = p_actor;
  v_body := case p_type
    when 'playlist_collaboration_invited'  then coalesce(v_actor,'A user')||' invited you to collaborate'
    when 'playlist_collaboration_accepted' then coalesce(v_actor,'A user')||' accepted your invitation'
    when 'playlist_collaboration_declined' then coalesce(v_actor,'A user')||' declined your invitation'
    when 'playlist_collaborator_removed'   then 'You were removed from a playlist'
    when 'playlist_collaborator_left'      then coalesce(v_actor,'A user')||' left your playlist'
    when 'playlist_ownership_transferred'  then 'You are now the owner of a playlist'
    else 'Playlist update' end;
  insert into public.notifications(
    user_id, actor_user_id, type, title, body, data, entity_type, entity_id, dedupe_key)
  values (p_recipient, p_actor, p_type, coalesce(v_title,'Playlist'), v_body,
    jsonb_build_object('playlist_id', p_playlist_id, 'playlist_title', v_title,
      'playlist_cover', v_cover, 'actor_id', p_actor, 'actor_username', v_actor),
    'playlist', p_playlist_id, p_dedupe)
  on conflict (user_id, dedupe_key) where dedupe_key is not null and deleted_at is null
  do update set actor_user_id = excluded.actor_user_id, body = excluded.body,
    data = excluded.data, read_at = null, acted_at = null, created_at = now();
end; $$;
revoke all on function private.emit_playlist_notification(uuid,uuid,text,uuid,text) from public, anon, authenticated;

-- Mark a recipient's active invite notification non-actionable (revoked).
create or replace function private.revoke_invite_notification(p_recipient uuid, p_playlist_id uuid)
returns void language plpgsql security definer set search_path to '' as $$
begin
  update public.notifications set acted_at = now()
  where user_id = p_recipient
    and dedupe_key = 'pl_invite:'||p_playlist_id::text||':'||p_recipient::text
    and acted_at is null and deleted_at is null;
end; $$;
revoke all on function private.revoke_invite_notification(uuid,uuid) from public, anon, authenticated;

-- ── Wire emits into the collab RPCs (bodies preserved; emits appended) ──

create or replace function public.playlist_invite_collaborator(
  p_playlist_id uuid, p_user_id uuid, p_role text default 'editor')
returns void language plpgsql security definer set search_path to '' as $$
declare v_uid uuid := (select auth.uid()); v_owner uuid; v_status text;
begin
  if v_uid is null then raise exception 'AUTH_REQUIRED' using errcode = '28000'; end if;
  select owner_id into v_owner from public.playlists where id = p_playlist_id and deleted_at is null;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_owner <> v_uid then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_user_id = v_owner then raise exception 'CANNOT_INVITE_OWNER'; end if;
  if not exists (select 1 from public.profiles where id = p_user_id) then raise exception 'USER_NOT_FOUND'; end if;
  if private.is_blocked(v_owner, p_user_id) then raise exception 'USER_BLOCKED'; end if;
  if p_role not in ('editor','moderator','viewer') then raise exception 'INVALID_ROLE'; end if;
  select status into v_status from public.playlist_collaborators
    where playlist_id = p_playlist_id and user_id = p_user_id;
  if v_status in ('pending','accepted') then raise exception 'ALREADY_INVITED'; end if;
  insert into public.playlist_collaborators(playlist_id, user_id, role, status, invited_by, invited_at, updated_at)
  values (p_playlist_id, p_user_id, p_role, 'pending', v_uid, now(), now())
  on conflict (playlist_id, user_id) do update
    set role = excluded.role, status = 'pending', invited_by = v_uid,
        invited_at = now(), accepted_at = null, joined_at = null, updated_at = now();
  update public.playlists set collaborative = true, updated_at = now()
    where id = p_playlist_id and collaborative = false;
  perform private.log_playlist_activity(p_playlist_id, v_uid, 'collaborator_invited',
    jsonb_build_object('user_id', p_user_id, 'role', p_role));
  perform private.emit_playlist_notification(p_user_id, v_uid, 'playlist_collaboration_invited',
    p_playlist_id, 'pl_invite:'||p_playlist_id::text||':'||p_user_id::text);
end; $$;

create or replace function public.playlist_respond_invitation(p_playlist_id uuid, p_accept boolean)
returns void language plpgsql security definer set search_path to '' as $$
declare v_uid uuid := (select auth.uid()); v_status text; v_owner uuid;
begin
  if v_uid is null then raise exception 'AUTH_REQUIRED' using errcode = '28000'; end if;
  select status into v_status from public.playlist_collaborators
    where playlist_id = p_playlist_id and user_id = v_uid;
  if not found or v_status <> 'pending' then raise exception 'NO_PENDING_INVITATION'; end if;
  select owner_id into v_owner from public.playlists where id = p_playlist_id;
  if p_accept then
    update public.playlist_collaborators
      set status = 'accepted', accepted_at = now(), joined_at = now(), updated_at = now()
      where playlist_id = p_playlist_id and user_id = v_uid;
    perform private.log_playlist_activity(p_playlist_id, v_uid, 'collaborator_joined',
      jsonb_build_object('user_id', v_uid));
    perform private.emit_playlist_notification(v_owner, v_uid, 'playlist_collaboration_accepted', p_playlist_id, null);
  else
    update public.playlist_collaborators set status = 'declined', updated_at = now()
      where playlist_id = p_playlist_id and user_id = v_uid;
    perform private.emit_playlist_notification(v_owner, v_uid, 'playlist_collaboration_declined', p_playlist_id, null);
  end if;
  -- The invite is now resolved: mark this user's invite notification acted.
  update public.notifications set acted_at = now(), read_at = coalesce(read_at, now())
    where user_id = v_uid
      and dedupe_key = 'pl_invite:'||p_playlist_id::text||':'||v_uid::text
      and deleted_at is null;
end; $$;

create or replace function public.playlist_leave(p_playlist_id uuid)
returns void language plpgsql security definer set search_path to '' as $$
declare v_uid uuid := (select auth.uid()); v_owner uuid;
begin
  if v_uid is null then raise exception 'AUTH_REQUIRED' using errcode = '28000'; end if;
  update public.playlist_collaborators set status = 'left', updated_at = now()
    where playlist_id = p_playlist_id and user_id = v_uid and status = 'accepted';
  if not found then raise exception 'NOT_A_COLLABORATOR'; end if;
  select owner_id into v_owner from public.playlists where id = p_playlist_id;
  perform private.log_playlist_activity(p_playlist_id, v_uid, 'collaborator_left',
    jsonb_build_object('user_id', v_uid));
  perform private.emit_playlist_notification(v_owner, v_uid, 'playlist_collaborator_left', p_playlist_id, null);
end; $$;

create or replace function public.playlist_remove_collaborator(
  p_playlist_id uuid, p_user_id uuid, p_reason text default null)
returns void language plpgsql security definer set search_path to '' as $$
declare v_uid uuid := (select auth.uid()); v_owner uuid;
begin
  if v_uid is null then raise exception 'AUTH_REQUIRED' using errcode = '28000'; end if;
  select owner_id into v_owner from public.playlists where id = p_playlist_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_owner <> v_uid then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  update public.playlist_collaborators set status = 'removed', updated_at = now()
    where playlist_id = p_playlist_id and user_id = p_user_id;
  perform private.log_playlist_activity(p_playlist_id, v_uid, 'collaborator_removed',
    jsonb_build_object('user_id', p_user_id, 'reason', coalesce(p_reason, 'removed')));
  perform private.revoke_invite_notification(p_user_id, p_playlist_id);
  perform private.emit_playlist_notification(p_user_id, v_uid, 'playlist_collaborator_removed', p_playlist_id, null);
end; $$;

create or replace function public.playlist_transfer_ownership(p_playlist_id uuid, p_new_owner uuid)
returns public.playlists language plpgsql security definer set search_path to '' as $$
declare v_uid uuid := (select auth.uid()); v_owner uuid; v_row public.playlists;
begin
  if v_uid is null then raise exception 'AUTH_REQUIRED' using errcode = '28000'; end if;
  select owner_id into v_owner from public.playlists where id = p_playlist_id and deleted_at is null;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_owner <> v_uid then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_new_owner = v_owner then raise exception 'ALREADY_OWNER'; end if;
  if private.is_blocked(v_owner, p_new_owner) then raise exception 'USER_BLOCKED'; end if;
  if not exists (select 1 from public.playlist_collaborators
                 where playlist_id = p_playlist_id and user_id = p_new_owner and status = 'accepted') then
    raise exception 'TARGET_NOT_ACCEPTED_COLLABORATOR';
  end if;
  insert into public.playlist_collaborators(playlist_id, user_id, role, status, invited_by, invited_at, accepted_at, joined_at, updated_at)
  values (p_playlist_id, v_owner, 'editor', 'accepted', p_new_owner, now(), now(), now(), now())
  on conflict (playlist_id, user_id) do update
    set role = 'editor', status = 'accepted', joined_at = coalesce(public.playlist_collaborators.joined_at, now()), updated_at = now();
  delete from public.playlist_collaborators where playlist_id = p_playlist_id and user_id = p_new_owner;
  update public.playlists set owner_id = p_new_owner, collaborative = true,
    version = version + 1, last_modified_at = now(), last_modified_by = v_uid, updated_at = now()
    where id = p_playlist_id returning * into v_row;
  perform private.log_playlist_activity(p_playlist_id, v_uid, 'ownership_transferred',
    jsonb_build_object('from', v_owner, 'to', p_new_owner));
  perform private.emit_playlist_notification(p_new_owner, v_uid, 'playlist_ownership_transferred', p_playlist_id, null);
  return v_row;
end; $$;
