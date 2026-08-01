-- Phase 3.4.1 — the totals (refresh_playlist_totals), follower count
-- (bump_playlist_followers), and updated_at (set_updated_at) triggers already
-- existed; the ones added in 120200 duplicated them (double follower count).
-- Drop the duplicates. Totals/followers/updated_at stay handled by the existing
-- triggers; version + last_modified_at/by are owned by the Phase 3.4.1 RPCs
-- (one bump per grouped operation). log_playlist_activity is kept.

drop trigger if exists trg_playlist_tracks_counters on public.playlist_tracks;
drop function if exists private.tg_playlist_tracks_counters();

drop trigger if exists trg_playlist_followers_count on public.user_followed_playlists;
drop function if exists private.tg_playlist_followers_count();
