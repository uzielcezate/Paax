-- Phase 3.4.1 — adversarial-review fixes (SQL).

-- H1: account-deletion succession was dead code. `playlists.owner_id → profiles
-- → auth.users` is ON DELETE CASCADE, and the RI cascade AFTER-triggers on
-- auth.users sort BEFORE the named AFTER trigger, so the owner's playlists were
-- already hard-deleted before succession ran. Run succession as a BEFORE DELETE
-- trigger so it reassigns owner_id (or soft-deletes) while the rows still exist;
-- reassigned playlists (owner_id = successor) then survive the cascade.
drop trigger if exists on_auth_user_deleted on auth.users;
create trigger on_auth_user_deleted
  before delete on auth.users
  for each row execute function private.tg_on_auth_user_deleted();

-- M4: enforce the RPC-only integrity model. `authenticated` held full table DML,
-- letting an owner PATCH playlists to forge version/follower_count/track_count,
-- or an editor write playlist_tracks directly (bypassing the version bump +
-- activity log), or force-insert an "accepted" collaborator. Revoke direct
-- INSERT/UPDATE/DELETE — the SECURITY DEFINER RPCs (owned by the admin role)
-- still write; clients keep RLS-governed SELECT only. Reads/activity unaffected.
revoke insert, update, delete on public.playlists from authenticated, anon;
revoke insert, update, delete on public.playlist_tracks from authenticated, anon;
revoke insert, update, delete on public.playlist_collaborators from authenticated, anon;

-- M5: playlist_save_order validated only the COUNT, so a same-length set that
-- swapped a real track id for a foreign/duplicate id could leave a stale
-- position or surface a raw 23505. Also validate exact membership (every id is
-- in the playlist) and no duplicate ids.
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
  -- exact-set validation: same count, no duplicates, every id present.
  if (select count(*) from public.playlist_tracks where playlist_id = p_playlist_id)
       <> coalesce(array_length(p_ordered_track_ids, 1), 0)
     or (select count(distinct x) from unnest(p_ordered_track_ids) x)
       <> coalesce(array_length(p_ordered_track_ids, 1), 0)
     or exists (
       select 1 from unnest(p_ordered_track_ids) x
       where not exists (
         select 1 from public.playlist_tracks pt
         where pt.playlist_id = p_playlist_id and pt.track_id = x))
  then
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
revoke all on function public.playlist_save_order(uuid, uuid[], bigint) from public, anon;
grant execute on function public.playlist_save_order(uuid, uuid[], bigint) to authenticated;
