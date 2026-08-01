-- Phase 3.4.1 — collaboration, ownership transfer, clone, add-from-source, and
-- account-deletion ownership succession RPCs. SECURITY DEFINER, search_path='',
-- permission-checked, activity-emitting.

-- ── invite collaborator (owner only) ──
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

  -- ensure the playlist is flagged collaborative
  update public.playlists set collaborative = true, updated_at = now()
    where id = p_playlist_id and collaborative = false;

  perform private.log_playlist_activity(p_playlist_id, v_uid, 'collaborator_invited',
    jsonb_build_object('user_id', p_user_id, 'role', p_role));
end; $$;

-- ── accept / decline own invitation ──
create or replace function public.playlist_respond_invitation(p_playlist_id uuid, p_accept boolean)
returns void language plpgsql security definer set search_path to '' as $$
declare v_uid uuid := (select auth.uid()); v_status text;
begin
  if v_uid is null then raise exception 'AUTH_REQUIRED' using errcode = '28000'; end if;
  select status into v_status from public.playlist_collaborators
    where playlist_id = p_playlist_id and user_id = v_uid;
  if not found or v_status <> 'pending' then raise exception 'NO_PENDING_INVITATION'; end if;
  if p_accept then
    update public.playlist_collaborators
      set status = 'accepted', accepted_at = now(), joined_at = now(), updated_at = now()
      where playlist_id = p_playlist_id and user_id = v_uid;
    perform private.log_playlist_activity(p_playlist_id, v_uid, 'collaborator_joined',
      jsonb_build_object('user_id', v_uid));
  else
    update public.playlist_collaborators set status = 'declined', updated_at = now()
      where playlist_id = p_playlist_id and user_id = v_uid;
  end if;
end; $$;

-- ── leave (accepted collaborator) ──
create or replace function public.playlist_leave(p_playlist_id uuid)
returns void language plpgsql security definer set search_path to '' as $$
declare v_uid uuid := (select auth.uid());
begin
  if v_uid is null then raise exception 'AUTH_REQUIRED' using errcode = '28000'; end if;
  update public.playlist_collaborators set status = 'left', updated_at = now()
    where playlist_id = p_playlist_id and user_id = v_uid and status = 'accepted';
  if not found then raise exception 'NOT_A_COLLABORATOR'; end if;
  perform private.log_playlist_activity(p_playlist_id, v_uid, 'collaborator_left',
    jsonb_build_object('user_id', v_uid));
end; $$;

-- ── remove collaborator (owner only; reason e.g. blocked) ──
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
end; $$;

-- ── transfer ownership (owner only; target must be accepted collaborator) ──
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

  -- prior owner becomes an accepted collaborator (editor); new owner's collab row removed
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
  return v_row;
end; $$;

-- ── clone (independent copy owned by caller) ──
create or replace function public.playlist_clone(
  p_playlist_id uuid, p_new_id uuid default null, p_new_title text default null)
returns public.playlists language plpgsql security definer set search_path to '' as $$
declare v_uid uuid := (select auth.uid()); v_src public.playlists; v_new_id uuid; v_row public.playlists;
  v_title text; v_grouped uuid := gen_random_uuid();
begin
  if v_uid is null then raise exception 'AUTH_REQUIRED' using errcode = '28000'; end if;
  if not private.can_view_playlist(p_playlist_id, v_uid) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into v_src from public.playlists where id = p_playlist_id and deleted_at is null;
  if not found then raise exception 'NOT_FOUND'; end if;

  if p_new_id is not null and exists (select 1 from public.playlists where id = p_new_id) then
    select * into v_row from public.playlists where id = p_new_id;
    if v_row.owner_id <> v_uid then raise exception 'NOT_OWNER' using errcode = '42501'; end if;
    return v_row; -- idempotent
  end if;

  v_title := coalesce(nullif(trim(p_new_title), ''), v_src.name);
  if exists (select 1 from public.playlists where owner_id = v_uid and name = v_title and deleted_at is null) then
    v_title := v_title || ' (Copy)';
  end if;

  insert into public.playlists(id, owner_id, name, visibility, collaborative, cover_mode,
      version, last_modified_at, last_modified_by, source_playlist_id)
  values (coalesce(p_new_id, gen_random_uuid()), v_uid, v_title, 'private', false, 'generated',
      1, now(), v_uid, p_playlist_id)
  returning id into v_new_id;

  insert into public.playlist_tracks(playlist_id, track_id, position, added_by)
  select v_new_id, pt.track_id, pt.position, v_uid
  from public.playlist_tracks pt where pt.playlist_id = p_playlist_id
  order by pt.position;

  perform private.log_playlist_activity(v_new_id, v_uid, 'playlist_cloned',
    jsonb_build_object('source_playlist_id', p_playlist_id, 'title', v_title), v_grouped);

  select * into v_row from public.playlists where id = v_new_id;
  return v_row;
end; $$;

-- ── add all source tracks to an existing target (does not modify source) ──
create or replace function public.playlist_add_tracks_from_source(p_source uuid, p_target uuid)
returns public.playlists language plpgsql security definer set search_path to '' as $$
declare v_uid uuid := (select auth.uid()); v_ids uuid[];
begin
  if v_uid is null then raise exception 'AUTH_REQUIRED' using errcode = '28000'; end if;
  if not private.can_view_playlist(p_source, v_uid) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if not private.can_edit_playlist(p_target, v_uid) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select array_agg(track_id order by position) into v_ids from public.playlist_tracks where playlist_id = p_source;
  return public.playlist_add_tracks(p_target, coalesce(v_ids, '{}'));
end; $$;

-- ── account-deletion ownership succession (trusted; service_role only) ──
create or replace function private.handle_owner_account_deletion(p_owner uuid)
returns void language plpgsql security definer set search_path to '' as $$
declare r record; v_succ uuid;
begin
  for r in select id, visibility from public.playlists where owner_id = p_owner and deleted_at is null loop
    -- oldest eligible accepted collaborator: not blocked, account exists.
    select c.user_id into v_succ
    from public.playlist_collaborators c
    join public.profiles pr on pr.id = c.user_id
    where c.playlist_id = r.id and c.status = 'accepted'
      and not private.is_blocked(p_owner, c.user_id)
    order by c.joined_at asc nulls last, c.created_at asc, c.user_id asc
    limit 1;

    if v_succ is not null then
      delete from public.playlist_collaborators where playlist_id = r.id and user_id = v_succ;
      update public.playlists set owner_id = v_succ, version = version + 1,
        last_modified_at = now(), last_modified_by = v_succ, updated_at = now()
        where id = r.id;
      perform private.log_playlist_activity(r.id, null, 'ownership_transferred',
        jsonb_build_object('to', v_succ, 'reason', 'owner_account_deleted'));
    else
      -- No eligible successor: soft-delete (MVP rule; no arbitrary/system owner).
      update public.playlists set deleted_at = now(), version = version + 1, updated_at = now()
        where id = r.id;
      perform private.log_playlist_activity(r.id, null, 'playlist_deleted',
        jsonb_build_object('reason', 'owner_account_deleted'));
    end if;
  end loop;
end; $$;
revoke all on function private.handle_owner_account_deletion(uuid) from public, anon, authenticated;

-- Fire succession server-side when an auth user is deleted (independent of client).
create or replace function private.tg_on_auth_user_deleted()
returns trigger language plpgsql security definer set search_path to '' as $$
begin
  perform private.handle_owner_account_deletion(old.id);
  return old;
end; $$;

drop trigger if exists on_auth_user_deleted on auth.users;
create trigger on_auth_user_deleted
  after delete on auth.users
  for each row execute function private.tg_on_auth_user_deleted();

-- Grants: authenticated only.
do $$
declare f text;
begin
  foreach f in array array[
    'public.playlist_invite_collaborator(uuid,uuid,text)',
    'public.playlist_respond_invitation(uuid,boolean)',
    'public.playlist_leave(uuid)',
    'public.playlist_remove_collaborator(uuid,uuid,text)',
    'public.playlist_transfer_ownership(uuid,uuid)',
    'public.playlist_clone(uuid,uuid,text)',
    'public.playlist_add_tracks_from_source(uuid,uuid)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
