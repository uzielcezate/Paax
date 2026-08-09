-- Phase 3.4.3 (INCIDENT FIX) — stop the server-side retry loop on version conflicts.
--
-- APPLIED TO PRODUCTION 2026-08-09 as `fix_playlist_version_conflict_sqlstate`
-- (supabase_migrations.schema_migrations version 20260809000925).
--
-- ROOT CAUSE
-- ----------
-- playlist_save_order and playlist_update_metadata signalled an application-level
-- optimistic-concurrency conflict with:
--     raise exception 'PLAYLIST_VERSION_CONFLICT' using errcode = '40001';
--
-- SQLSTATE 40001 is serialization_failure — the standard code meaning "this
-- transaction lost a race, retrying will probably succeed". PostgREST maps class
-- 40* to HTTP 500 and the request is retried. But this conflict is DETERMINISTIC
-- business logic: the stale p_expected_version never changes, so every retry
-- failed identically, forever.
--
-- MEASURED IN PRODUCTION (2026-08-08). A controlled probe, self-limited to 20
-- executions, recorded per SINGLE HTTP request:
--     errcode 40001  -> HTTP 500, 21+ executions (still looping at the guard)
--     errcode P0001  -> HTTP 400,  1 execution
--     sqlstate PGRST -> HTTP 409,  1 execution                      <-- chosen
-- Sustained effect before the fix: ~2,565 executions/sec, 872M transactions,
-- 99.92% rollbacks, Postgres CPU ~92%, with ZERO corresponding API Gateway
-- requests in a 16-hour window (the multiplication was entirely server-side).
--
-- THE FIX
-- -------
-- Raise with the PostgREST `PGRST` SQLSTATE, which sets an explicit HTTP status
-- and returns a JSON body. 409 Conflict is the correct semantic for optimistic
-- concurrency, and the `code` field preserves the PLAYLIST_VERSION_CONFLICT
-- identifier so clients branch on a stable code rather than message text.
--
-- Authorization, version checking and all other behaviour are UNCHANGED. This
-- migration only changes how the conflict is CLASSIFIED on the wire.

create or replace function private.raise_playlist_version_conflict(
  p_expected bigint,
  p_actual   bigint
) returns void
language plpgsql
as $$
begin
  raise sqlstate 'PGRST' using
    message = json_build_object(
      'code',    'PLAYLIST_VERSION_CONFLICT',
      'message', 'PLAYLIST_VERSION_CONFLICT',
      'details', json_build_object(
                   'expected_version', p_expected,
                   'actual_version',   p_actual
                 )::text,
      'hint',    'Refetch the playlist and reapply against the current version.'
    )::text,
    detail  = '{"status":409,"headers":{}}';
end $$;

revoke all on function private.raise_playlist_version_conflict(bigint, bigint)
  from public, anon, authenticated;

-- ── playlist_save_order: only the raise changes ──────────────────────────────
CREATE OR REPLACE FUNCTION public.playlist_save_order(p_playlist_id uuid, p_ordered_track_ids uuid[], p_expected_version bigint DEFAULT NULL::bigint)
 RETURNS playlists
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_uid uuid := (select auth.uid()); v_ver bigint; v_row public.playlists;
  i int := 0; v_tid uuid; v_grouped uuid := gen_random_uuid(); v_before jsonb; v_after jsonb;
begin
  if v_uid is null then raise exception 'AUTH_REQUIRED' using errcode = '28000'; end if;
  if not private.can_edit_playlist(p_playlist_id, v_uid) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select version into v_ver from public.playlists where id = p_playlist_id and deleted_at is null;
  if not found then raise exception 'NOT_FOUND'; end if;
  if p_expected_version is not null and v_ver <> p_expected_version then
    perform private.raise_playlist_version_conflict(p_expected_version, v_ver);
  end if;
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
end; $function$;

-- ── playlist_update_metadata: only the raise changes ─────────────────────────
CREATE OR REPLACE FUNCTION public.playlist_update_metadata(p_playlist_id uuid, p_name text DEFAULT NULL::text, p_description text DEFAULT NULL::text, p_visibility text DEFAULT NULL::text, p_collaborative boolean DEFAULT NULL::boolean, p_expected_version bigint DEFAULT NULL::bigint)
 RETURNS playlists
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_uid uuid := (select auth.uid()); v_old public.playlists; v_new public.playlists; v_g uuid := gen_random_uuid();
begin
  if v_uid is null then raise exception 'AUTH_REQUIRED' using errcode = '28000'; end if;
  if not private.is_playlist_owner(p_playlist_id, v_uid) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into v_old from public.playlists where id = p_playlist_id and deleted_at is null;
  if not found then raise exception 'NOT_FOUND'; end if;
  if p_expected_version is not null and v_old.version <> p_expected_version then
    perform private.raise_playlist_version_conflict(p_expected_version, v_old.version);
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
end; $function$;
