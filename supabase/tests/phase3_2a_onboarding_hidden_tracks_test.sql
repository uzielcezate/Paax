-- ============================================================================
-- Manual / CI SQL tests for the Phase 3.2A migration
-- (20260717160000_phase3_2a_onboarding_and_hidden_tracks.sql)
--
-- These were executed live against the project (ref jecgmiuypuathhvjuhea) via
-- the Supabase MCP on 2026-07-17 using two disposable auth.users, each test in
-- a rolled-back transaction, then the disposable users were deleted.
--
-- They assert the security contract of `complete_artist_onboarding` and the
-- RLS of `user_hidden_tracks`. To re-run, create two disposable confirmed users
-- and substitute their ids for :u1 / :u2 and five real public.artists ids.
--
-- Expected results (verified 2026-07-17):
--   T1 happy path            -> {onboarding_completed:true, followed_count:5}; 5 follows; profiles.onboarding_completed=true
--   T2 fewer than 5          -> ERROR 22023 "onboarding requires at least 5 unique artists (got 4)"
--   T3 non-existent artist   -> ERROR 23503 "one or more selected artists do not exist"
--   T4 duplicates collapse   -> ERROR 22023 (5 elements, 4 distinct -> got 4)
--   T5 no auth.uid()         -> ERROR 42501 "authentication required"
--   T6 hidden_tracks RLS     -> owner sees own row (idempotent insert); another user sees 0
-- ============================================================================

-- T1 — happy path
begin;
  select set_config('request.jwt.claims', '{"sub":":u1","role":"authenticated"}', true);
  set local role authenticated;
  select public.complete_artist_onboarding(array[:a1,:a2,:a3,:a4,:a5]::uuid[]);
  reset role;
  select
    (select count(*) from public.user_followed_artists where user_id = ':u1') as follows,       -- expect 5
    (select onboarding_completed from public.profiles where id = ':u1') as onboarded;            -- expect true
rollback;

-- T2 — fewer than 5 -> 22023
begin;
  select set_config('request.jwt.claims', '{"sub":":u1","role":"authenticated"}', true);
  set local role authenticated;
  select public.complete_artist_onboarding(array[:a1,:a2,:a3,:a4]::uuid[]);   -- raises 22023
rollback;

-- T3 — non-existent artist -> 23503
begin;
  select set_config('request.jwt.claims', '{"sub":":u1","role":"authenticated"}', true);
  set local role authenticated;
  select public.complete_artist_onboarding(array[:a1,:a2,:a3,:a4,'00000000-0000-0000-0000-0000000000ff']::uuid[]); -- raises 23503
rollback;

-- T4 — duplicates collapse below 5 -> 22023
begin;
  select set_config('request.jwt.claims', '{"sub":":u1","role":"authenticated"}', true);
  set local role authenticated;
  select public.complete_artist_onboarding(array[:a1,:a1,:a2,:a3,:a4]::uuid[]);  -- raises 22023 (got 4)
rollback;

-- T5 — no authenticated identity -> 42501
begin;
  set local role authenticated;                       -- no sub claim => auth.uid() is null
  select public.complete_artist_onboarding(array[:a1,:a2,:a3,:a4,:a5]::uuid[]);  -- raises 42501
rollback;

-- T6 — hidden_tracks RLS isolation + idempotency
begin;
  select set_config('request.jwt.claims', '{"sub":":u1","role":"authenticated"}', true);
  set local role authenticated;
  insert into public.user_hidden_tracks (user_id, track_id) values (':u1', :track) on conflict do nothing;
  insert into public.user_hidden_tracks (user_id, track_id) values (':u1', :track) on conflict do nothing; -- idempotent, no error
  select count(*) as owner_sees from public.user_hidden_tracks;   -- expect 1
  reset role;
  select set_config('request.jwt.claims', '{"sub":":u2","role":"authenticated"}', true);
  set local role authenticated;
  select count(*) as other_sees from public.user_hidden_tracks;   -- expect 0 (RLS)
rollback;
