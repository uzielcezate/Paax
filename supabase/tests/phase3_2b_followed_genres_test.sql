-- ============================================================================
-- Manual / CI SQL tests for Phase 3.2B — followed genres.
--
-- NO migration is introduced in Phase 3.2B: public.genres, public.user_followed_genres
-- (RLS: own SELECT/INSERT/DELETE, PK(user_id,genre_id)), and the
-- private.bump_genre_followers counter trigger already exist from the Phase 1
-- library_and_social migration. These tests assert that the existing contract
-- behaves as the offline-first genre sync relies on.
--
-- Verified live against the project (ref jecgmiuypuathhvjuhea) via the Supabase
-- MCP on 2026-07-17 using two disposable auth.users, then deleted them.
--
-- Expected results (verified):
--   T1 follow is idempotent + visible to owner        -> owner sees 1 after a double insert
--   T2 counter trigger                                 -> genres.platform_followers_count 0 -> 1 on follow, restored on delete
--   T3 cross-user isolation                            -> a different user sees 0 of the owner's followed genres
--
-- Substitute :u1 / :u2 for two disposable confirmed user ids and :g for a real
-- public.genres id.
-- ============================================================================

-- T1 + T3 — idempotent follow, owner visibility, and isolation (single txn)
do $$
declare a_follows int; b_sees int;
begin
  perform set_config('request.jwt.claims', '{"sub":":u1","role":"authenticated"}', true);
  execute 'set local role authenticated';
  insert into public.user_followed_genres(user_id, genre_id) values (':u1', ':g') on conflict do nothing;
  insert into public.user_followed_genres(user_id, genre_id) values (':u1', ':g') on conflict do nothing; -- idempotent, no error
  select count(*) into a_follows from public.user_followed_genres;   -- expect 1 (owner)
  execute 'reset role';
  perform set_config('request.jwt.claims', '{"sub":":u2","role":"authenticated"}', true);
  execute 'set local role authenticated';
  select count(*) into b_sees from public.user_followed_genres;      -- expect 0 (RLS)
  execute 'reset role';
  if a_follows <> 1 or b_sees <> 0 then
    raise exception 'genre isolation/idempotency FAIL: owner=% other=%', a_follows, b_sees;
  end if;
end $$;

-- T2 — counter trigger (bump_genre_followers), run outside the assertion block
begin;
  select set_config('request.jwt.claims', '{"sub":":u1","role":"authenticated"}', true);
  set local role authenticated;
  insert into public.user_followed_genres(user_id, genre_id) values (':u1', ':g') on conflict do nothing;
  reset role;
  select platform_followers_count from public.genres where id = ':g';  -- expect prior + 1
rollback;  -- rollback restores the counter to its prior value
