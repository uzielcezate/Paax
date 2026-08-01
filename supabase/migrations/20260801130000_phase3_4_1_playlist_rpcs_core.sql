-- Phase 3.4.1 — core transactional playlist RPCs (content + follow).
-- All SECURITY DEFINER, search_path='', validate auth.uid() + centralized
-- permission helpers, version-aware where relevant, emit grouped activity,
-- execute granted to `authenticated` only. Positions are ONE-BASED.

-- ── create (idempotent via optional client-supplied id) ──
create or replace function public.playlist_create(
  p_name text,
  p_visibility text default 'private',
  p_track_ids uuid[] default '{}',
  p_id uuid default null,
  p_source_playlist_id uuid default null,
  p_imported boolean default false
) returns public.playlists
language plpgsql security definer set search_path to '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_pid uuid; v_row public.playlists; v_grouped uuid := gen_random_uuid();
  v_tid uuid; i int := 0;
begin
  if v_uid is null then raise exception 'AUTH_REQUIRED' using errcode = '28000'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'NAME_REQUIRED'; end if;
  if p_visibility not in ('private','unlisted','public','followers') then
    raise exception 'INVALID_VISIBILITY';
  end if;

  if p_id is not null then
    select * into v_row from public.playlists where id = p_id;
    if found then
      if v_row.owner_id <> v_uid then raise exception 'NOT_OWNER' using errcode = '42501'; end if;
      return v_row; -- idempotent: offline retry / migration re-run
    end if;
  end if;

  insert into public.playlists(id, owner_id, name, visibility, collaborative, cover_mode,
      version, last_modified_at, last_modified_by, source_playlist_id)
  values (coalesce(p_id, gen_random_uuid()), v_uid, trim(p_name), p_visibility, false, 'generated',
      1, now(), v_uid, p_source_playlist_id)
  returning id into v_pid;

  foreach v_tid in array coalesce(p_track_ids, '{}') loop
    if v_tid is null then continue; end if;
    if not exists (select 1 from public.tracks t where t.id = v_tid) then continue; end if;
    if exists (select 1 from public.playlist_tracks pt where pt.playlist_id = v_pid and pt.track_id = v_tid) then continue; end if;
    i := i + 1;
    insert into public.playlist_tracks(playlist_id, track_id, position, added_by)
    values (v_pid, v_tid, i, v_uid);
  end loop;

  perform private.log_playlist_activity(v_pid, v_uid,
    case when p_imported then 'playlist_imported' else 'playlist_created' end,
    jsonb_build_object('title', trim(p_name), 'track_count', i,
                       'source_playlist_id', p_source_playlist_id), v_grouped);

  select * into v_row from public.playlists where id = v_pid;
  return v_row;
end; $$;

-- ── save order (version-checked, atomic reorder) ──
create or replace function public.playlist_save_order(
  p_playlist_id uuid, p_ordered_track_ids uuid[], p_expected_version bigint default null)
returns public.playlists language plpgsql security definer set search_path to '' as $$
declare v_uid uuid := (select auth.uid()); v_ver bigint; v_row public.playlists;
  i int := 0; v_tid uuid; v_grouped uuid := gen_random_uuid(); v_before jsonb; v_after jsonb;
begin
  if v_uid is null then raise exception 'AUTH_REQUIRED' using errcode = '28000'; end if;
  if not private.can_edit_playlist(p_playlist_id, v_uid) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select version into v_ver from public.playlists where id = p_playlist_id and deleted_at is null;
  if not found then raise exception 'NOT_FOUND'; end if;
  if p_expected_version is not null and v_ver <> p_expected_version then
    raise exception 'PLAYLIST_VERSION_CONFLICT' using errcode = '40001';
  end if;
  if (select count(*) from public.playlist_tracks where playlist_id = p_playlist_id)
     <> coalesce(array_length(p_ordered_track_ids, 1), 0) then
    raise exception 'ORDER_SET_MISMATCH';
  end if;

  select jsonb_agg(track_id order by position) into v_before
    from public.playlist_tracks where playlist_id = p_playlist_id;

  foreach v_tid in array p_ordered_track_ids loop
    i := i + 1;
    update public.playlist_tracks set position = i, updated_at = now()
      where playlist_id = p_playlist_id and track_id = v_tid;
  end loop;

  update public.playlists set version = version + 1, last_modified_at = now(),
    last_modified_by = v_uid, updated_at = now()
    where id = p_playlist_id returning * into v_row;

  select jsonb_agg(track_id order by position) into v_after
    from public.playlist_tracks where playlist_id = p_playlist_id;
  perform private.log_playlist_activity(p_playlist_id, v_uid, 'tracks_reordered',
    jsonb_build_object('count', i, 'before', v_before, 'after', v_after), v_grouped);
  return v_row;
end; $$;

-- ── add tracks (append after max; grouped activity with titles) ──
create or replace function public.playlist_add_tracks(p_playlist_id uuid, p_track_ids uuid[])
returns public.playlists language plpgsql security definer set search_path to '' as $$
declare v_uid uuid := (select auth.uid()); v_row public.playlists; v_max int; v_tid uuid;
  v_added jsonb := '[]'::jsonb; v_count int := 0; v_grouped uuid := gen_random_uuid(); v_title text;
begin
  if v_uid is null then raise exception 'AUTH_REQUIRED' using errcode = '28000'; end if;
  if not private.can_edit_playlist(p_playlist_id, v_uid) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if not exists (select 1 from public.playlists where id = p_playlist_id and deleted_at is null) then raise exception 'NOT_FOUND'; end if;
  select coalesce(max(position), 0) into v_max from public.playlist_tracks where playlist_id = p_playlist_id;
  foreach v_tid in array coalesce(p_track_ids, '{}') loop
    if v_tid is null then continue; end if;
    if exists (select 1 from public.playlist_tracks where playlist_id = p_playlist_id and track_id = v_tid) then continue; end if;
    select title into v_title from public.tracks where id = v_tid;
    if not found then continue; end if;
    v_max := v_max + 1; v_count := v_count + 1;
    insert into public.playlist_tracks(playlist_id, track_id, position, added_by)
      values (p_playlist_id, v_tid, v_max, v_uid);
    v_added := v_added || jsonb_build_object('id', v_tid, 'title', v_title);
  end loop;
  if v_count > 0 then
    update public.playlists set version = version + 1, last_modified_at = now(),
      last_modified_by = v_uid, updated_at = now() where id = p_playlist_id;
    perform private.log_playlist_activity(p_playlist_id, v_uid, 'tracks_added',
      jsonb_build_object('count', v_count, 'tracks', v_added), v_grouped);
  end if;
  select * into v_row from public.playlists where id = p_playlist_id;
  return v_row;
end; $$;

-- ── remove tracks (renormalize positions; grouped activity) ──
create or replace function public.playlist_remove_tracks(p_playlist_id uuid, p_track_ids uuid[])
returns public.playlists language plpgsql security definer set search_path to '' as $$
declare v_uid uuid := (select auth.uid()); v_row public.playlists; v_tid uuid;
  v_removed jsonb := '[]'::jsonb; v_count int := 0; v_grouped uuid := gen_random_uuid(); v_title text;
begin
  if v_uid is null then raise exception 'AUTH_REQUIRED' using errcode = '28000'; end if;
  if not private.can_edit_playlist(p_playlist_id, v_uid) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if not exists (select 1 from public.playlists where id = p_playlist_id and deleted_at is null) then raise exception 'NOT_FOUND'; end if;
  foreach v_tid in array coalesce(p_track_ids, '{}') loop
    if v_tid is null then continue; end if;
    if not exists (select 1 from public.playlist_tracks where playlist_id = p_playlist_id and track_id = v_tid) then continue; end if;
    select title into v_title from public.tracks where id = v_tid;
    delete from public.playlist_tracks where playlist_id = p_playlist_id and track_id = v_tid;
    v_count := v_count + 1;
    v_removed := v_removed || jsonb_build_object('id', v_tid, 'title', coalesce(v_title, ''));
  end loop;
  if v_count > 0 then
    -- renormalize remaining to contiguous 1..n
    with ordered as (
      select track_id, row_number() over (order by position) as rn
      from public.playlist_tracks where playlist_id = p_playlist_id)
    update public.playlist_tracks pt set position = o.rn, updated_at = now()
      from ordered o where pt.playlist_id = p_playlist_id and pt.track_id = o.track_id;
    update public.playlists set version = version + 1, last_modified_at = now(),
      last_modified_by = v_uid, updated_at = now() where id = p_playlist_id;
    perform private.log_playlist_activity(p_playlist_id, v_uid, 'tracks_removed',
      jsonb_build_object('count', v_count, 'tracks', v_removed), v_grouped);
  end if;
  select * into v_row from public.playlists where id = p_playlist_id;
  return v_row;
end; $$;

-- ── update metadata (owner only; version-checked; per-change activity) ──
create or replace function public.playlist_update_metadata(
  p_playlist_id uuid, p_name text default null, p_description text default null,
  p_visibility text default null, p_collaborative boolean default null,
  p_expected_version bigint default null)
returns public.playlists language plpgsql security definer set search_path to '' as $$
declare v_uid uuid := (select auth.uid()); v_old public.playlists; v_new public.playlists; v_g uuid := gen_random_uuid();
begin
  if v_uid is null then raise exception 'AUTH_REQUIRED' using errcode = '28000'; end if;
  if not private.is_playlist_owner(p_playlist_id, v_uid) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into v_old from public.playlists where id = p_playlist_id and deleted_at is null;
  if not found then raise exception 'NOT_FOUND'; end if;
  if p_expected_version is not null and v_old.version <> p_expected_version then
    raise exception 'PLAYLIST_VERSION_CONFLICT' using errcode = '40001';
  end if;
  if p_visibility is not null and p_visibility not in ('private','unlisted','public','followers') then
    raise exception 'INVALID_VISIBILITY';
  end if;
  update public.playlists set
    name = coalesce(nullif(trim(p_name), ''), name),
    description = coalesce(p_description, description),
    visibility = coalesce(p_visibility, visibility),
    collaborative = coalesce(p_collaborative, collaborative),
    version = version + 1, last_modified_at = now(), last_modified_by = v_uid, updated_at = now()
    where id = p_playlist_id returning * into v_new;

  if p_name is not null and trim(p_name) <> '' and trim(p_name) <> v_old.name then
    perform private.log_playlist_activity(p_playlist_id, v_uid, 'playlist_renamed',
      jsonb_build_object('from', v_old.name, 'to', v_new.name), v_g);
  end if;
  if p_description is not null and coalesce(p_description, '') <> coalesce(v_old.description, '') then
    perform private.log_playlist_activity(p_playlist_id, v_uid, 'description_changed', '{}'::jsonb, v_g);
  end if;
  if p_visibility is not null and p_visibility <> v_old.visibility then
    perform private.log_playlist_activity(p_playlist_id, v_uid, 'visibility_changed',
      jsonb_build_object('from', v_old.visibility, 'to', v_new.visibility), v_g);
  end if;
  return v_new;
end; $$;

-- ── soft delete (owner only) ──
create or replace function public.playlist_delete(p_playlist_id uuid)
returns void language plpgsql security definer set search_path to '' as $$
declare v_uid uuid := (select auth.uid());
begin
  if v_uid is null then raise exception 'AUTH_REQUIRED' using errcode = '28000'; end if;
  if not private.is_playlist_owner(p_playlist_id, v_uid) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  update public.playlists set deleted_at = now(), version = version + 1, updated_at = now()
    where id = p_playlist_id and deleted_at is null;
  perform private.log_playlist_activity(p_playlist_id, v_uid, 'playlist_deleted', '{}'::jsonb);
end; $$;

-- ── follow / unfollow (idempotent; no version/activity/last_modified) ──
create or replace function public.playlist_set_follow(p_playlist_id uuid, p_follow boolean)
returns bigint language plpgsql security definer set search_path to '' as $$
declare v_uid uuid := (select auth.uid()); v_count bigint;
begin
  if v_uid is null then raise exception 'AUTH_REQUIRED' using errcode = '28000'; end if;
  if not private.can_view_playlist(p_playlist_id, v_uid) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_follow then
    insert into public.user_followed_playlists(user_id, playlist_id)
      values (v_uid, p_playlist_id) on conflict do nothing;
  else
    delete from public.user_followed_playlists where user_id = v_uid and playlist_id = p_playlist_id;
  end if;
  select platform_followers_count into v_count from public.playlists where id = p_playlist_id;
  return coalesce(v_count, 0);
end; $$;

-- Grants: authenticated only.
do $$
declare f text;
begin
  foreach f in array array[
    'public.playlist_create(text,text,uuid[],uuid,uuid,boolean)',
    'public.playlist_save_order(uuid,uuid[],bigint)',
    'public.playlist_add_tracks(uuid,uuid[])',
    'public.playlist_remove_tracks(uuid,uuid[])',
    'public.playlist_update_metadata(uuid,text,text,text,boolean,bigint)',
    'public.playlist_delete(uuid)',
    'public.playlist_set_follow(uuid,boolean)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
