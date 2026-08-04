-- supabase/tests/playlist_delete_contract_test.sql
--
-- Phase 3.4.1.2B — automated acceptance test for the OWNER soft-delete contract.
-- Runs entirely inside one transaction and ABORTS at the end (RAISE) so it
-- leaves no data behind. Run via the Supabase MCP execute_sql, or:
--   psql "$DATABASE_URL" -f supabase/tests/playlist_delete_contract_test.sql
-- Every assertion is surfaced in the final RAISE message; all must be true/expected.
--
-- Proves (spec 3.4.1.2B delete regression points):
--   1. owner delete sets deleted_at and increments version
--   8. playlist_tracks (dependents) are RETAINED for audit
--   9. exactly one playlist_deleted activity event is recorded (idempotent)
--   4. a soft-deleted playlist is not viewable (can_view_playlist = false)
--   - a non-owner cannot delete (FORBIDDEN)
--   - a repeat delete is blocked (is_playlist_owner false once deleted)

do $$
declare
  owner uuid := gen_random_uuid();
  stranger uuid := gen_random_uuid();
  pl uuid := gen_random_uuid();
  t1 uuid; t2 uuid;
  v_deleted_at timestamptz; v_version_before int; v_version_after int;
  v_deleted_events int; v_tracks_retained int; v_can_view boolean;
  v_stranger_blocked boolean := false; v_repeat_blocked boolean := false;
begin
  select id into t1 from public.tracks limit 1;
  select id into t2 from public.tracks offset 1 limit 1;
  insert into auth.users(id,instance_id,aud,role,email,created_at,updated_at)
  select u,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','d_'||u||'@t.paax','now','now'
  from unnest(array[owner,stranger]) u;

  perform set_config('request.jwt.claims', json_build_object('sub',owner::text)::text, true);
  perform public.playlist_create('DeleteTest','private', array[]::uuid[], pl, null, false);
  perform public.playlist_add_tracks(pl, array[t1,t2]);
  select version into v_version_before from public.playlists where id=pl;

  perform set_config('request.jwt.claims', json_build_object('sub',stranger::text)::text, true);
  begin perform public.playlist_delete(pl); exception when others then v_stranger_blocked := true; end;

  perform set_config('request.jwt.claims', json_build_object('sub',owner::text)::text, true);
  perform public.playlist_delete(pl);
  select deleted_at, version into v_deleted_at, v_version_after from public.playlists where id=pl;
  select count(*) into v_deleted_events from public.playlist_activity where playlist_id=pl and event_type='playlist_deleted';
  select count(*) into v_tracks_retained from public.playlist_tracks where playlist_id=pl;
  v_can_view := private.can_view_playlist(pl, owner);

  begin perform public.playlist_delete(pl); exception when others then v_repeat_blocked := true; end;
  select count(*) into v_deleted_events from public.playlist_activity where playlist_id=pl and event_type='playlist_deleted';

  if not (v_deleted_at is not null) then raise exception 'FAIL deleted_at not set'; end if;
  if v_version_after <> v_version_before + 1 then raise exception 'FAIL version not incremented'; end if;
  if v_deleted_events <> 1 then raise exception 'FAIL playlist_deleted events = % (want 1)', v_deleted_events; end if;
  if v_tracks_retained <> 2 then raise exception 'FAIL tracks not retained = %', v_tracks_retained; end if;
  if v_can_view then raise exception 'FAIL deleted playlist still viewable'; end if;
  if not v_stranger_blocked then raise exception 'FAIL non-owner delete not blocked'; end if;
  if not v_repeat_blocked then raise exception 'FAIL repeat delete not blocked'; end if;

  raise exception 'PASS(rollback) deleted_at_set version=%->% deleted_events=% tracks_retained=% can_view=% stranger_blocked=% repeat_blocked=%',
    v_version_before, v_version_after, v_deleted_events, v_tracks_retained, v_can_view, v_stranger_blocked, v_repeat_blocked;
end $$;
