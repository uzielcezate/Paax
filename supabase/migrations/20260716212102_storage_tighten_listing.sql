-- ============================================================================
-- Migration: storage_tighten_listing
-- Phase 1 — Supabase foundation (ADR-009).
-- Advisor remediation (Supabase lint 0025 public_bucket_allows_listing):
-- public buckets serve objects via their public URL without any SELECT
-- policy on storage.objects; a broad SELECT policy only enables clients to
-- LIST every file in the bucket. Replace the broad policies:
--
--   * music-images: no client SELECT policy at all. Artwork is fetched by
--     public URL; ingestion/writes use the service role.
--   * user-avatars: SELECT restricted to the caller's own folder — required
--     because client-side avatar upsert needs INSERT + SELECT + UPDATE.
--
-- Rollback strategy:
--   drop policy if exists "Users list their own avatar folder" on storage.objects;
--   (recreate the two broad policies from 20260716090900_storage_buckets.sql
--    if broad listing is ever intentionally desired)
-- ============================================================================

drop policy if exists "Catalog artwork is publicly readable" on storage.objects;
drop policy if exists "Avatars are publicly readable" on storage.objects;

create policy "Users list their own avatar folder"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'user-avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );
