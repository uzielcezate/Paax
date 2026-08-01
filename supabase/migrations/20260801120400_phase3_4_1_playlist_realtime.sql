-- Phase 3.4.1 — enable Supabase Realtime for playlist tables so an open
-- Playlist Detail can watch metadata/version/follower-count (playlists UPDATE),
-- track membership/order (playlist_tracks), collaborator changes
-- (playlist_collaborators), and latest activity (playlist_activity). RLS still
-- governs delivery (private.can_view_playlist), so no unauthorized leakage.
-- Idempotent.

do $$
declare t text;
begin
  foreach t in array array['playlists','playlist_tracks','playlist_collaborators','playlist_activity']
  loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname='supabase_realtime' and schemaname='public' and tablename=t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
