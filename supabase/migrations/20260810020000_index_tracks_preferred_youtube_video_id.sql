-- Phase 3.4.7 — index the second track-identity path.
--
-- APPLIED TO PRODUCTION 2026-08-10 as
-- `index_tracks_preferred_youtube_video_id`.
--
-- Playlist membership must not require a Deezer id. `Track.id` in the client IS
-- the YouTube videoId, and `tracks.preferred_youtube_video_id` stores it, so a
-- track with no numeric deezer_id can still resolve to its canonical Paax UUID
-- this way. Without this index that lookup is a sequential scan on every
-- add-to-playlist.
--
-- Partial (NOT NULL) because ~2.4% of rows have no videoId and are never looked
-- up by it. Additive and reversible; no RLS, policy or behaviour change.
create index if not exists idx_tracks_preferred_youtube_video_id
  on public.tracks (preferred_youtube_video_id)
  where preferred_youtube_video_id is not null;
