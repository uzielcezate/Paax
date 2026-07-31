-- Phase 3.3.5 — Real-Time Global Artist Follower Counts
--
-- Adds public.artists to the `supabase_realtime` publication so clients can
-- subscribe to UPDATE events on a single artist row and receive the
-- authoritative `platform_followers_count` live (maintained by the existing
-- `bump_artist_followers` trigger on user_followed_artists).
--
-- Why the artists row (and NOT user_followed_artists):
--   * artists has a public SELECT policy (`qual = true`), so every authenticated
--     client can receive its changes and see ONLY the aggregate count — no user
--     identity or follow-row is ever exposed.
--   * user_followed_artists SELECT is restricted to `auth.uid() = user_id`, so a
--     realtime subscription there would deliver ONLY the current user's own rows
--     and could never reflect another user's follow/unfollow. It is therefore
--     unusable as a global-count source and would leak nothing useful.
--
-- Replica identity: artists uses the default (primary key `id`), which is
-- sufficient for a filtered UPDATE subscription (`id = eq.<uuid>`); the new-row
-- image always carries `platform_followers_count`. No REPLICA IDENTITY FULL is
-- required.
--
-- Idempotent: safe to re-run.

do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'artists'
  ) then
    alter publication supabase_realtime add table public.artists;
  end if;
end
$$;
