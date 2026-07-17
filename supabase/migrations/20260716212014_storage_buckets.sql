-- ============================================================================
-- Migration: storage_buckets
-- Phase 1 — Supabase foundation (ADR-009).
-- Buckets + explicit Storage RLS policies.
--
--   music-images  (PUBLIC read)  — cached catalog artwork. Paths:
--       artists/{artist_id}/profile.webp
--       albums/{album_id}/cover.webp
--       genres/{genre_id}/cover.webp
--       playlists/{playlist_id}/cover.webp
--     Writes: backend/service-role ONLY (no client write policies) — clients
--     can never overwrite canonical artwork.
--
--   user-avatars  (PUBLIC read)  — {user_id}/avatar.webp
--     Public read is deliberate: avatars render on public profiles and in
--     social surfaces; the path contains no sensitive data.
--     Users manage ONLY their own {user_id}/ folder.
--
--   story-media   (PRIVATE)     — {user_id}/{story_id}/{filename}
--     Private is deliberate: stories are ephemeral, may be friends-only, and
--     Storage policies cannot evaluate per-story visibility cheaply on a CDN
--     path. Access for other users is via short-lived SIGNED URLs issued by
--     the backend after a can_view_story check. Owners manage their own
--     folder directly.
--
-- Rollback strategy:
--   delete from storage.objects where bucket_id in
--     ('music-images','user-avatars','story-media');
--   delete from storage.buckets where id in
--     ('music-images','user-avatars','story-media');
--   drop policy if exists ... (each policy below) on storage.objects;
-- ============================================================================

insert into storage.buckets (id, name, public)
values
  ('music-images', 'music-images', true),
  ('user-avatars', 'user-avatars', true),
  ('story-media',  'story-media',  false)
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- music-images: public read; no client writes.
-- ---------------------------------------------------------------------------
create policy "Catalog artwork is publicly readable"
  on storage.objects for select
  to anon, authenticated
  using (bucket_id = 'music-images');

-- ---------------------------------------------------------------------------
-- user-avatars: public read; users write only inside their own {user_id}/.
-- Upsert requires INSERT + SELECT + UPDATE — all granted for the own folder.
-- ---------------------------------------------------------------------------
create policy "Avatars are publicly readable"
  on storage.objects for select
  to anon, authenticated
  using (bucket_id = 'user-avatars');

create policy "Users upload their own avatar"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'user-avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "Users replace their own avatar"
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'user-avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  )
  with check (
    bucket_id = 'user-avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "Users delete their own avatar"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'user-avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

-- ---------------------------------------------------------------------------
-- story-media: private. Owners manage their own {user_id}/... folder; other
-- viewers get short-lived signed URLs from the backend (no direct policy).
-- ---------------------------------------------------------------------------
create policy "Users read their own story media"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'story-media'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "Users upload their own story media"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'story-media'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "Users update their own story media"
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'story-media'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  )
  with check (
    bucket_id = 'story-media'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "Users delete their own story media"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'story-media'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );
