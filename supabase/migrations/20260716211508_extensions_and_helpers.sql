-- ============================================================================
-- Migration: extensions_and_helpers
-- Phase 1 — Supabase foundation (ADR-009).
-- Creates shared extensions, the non-exposed `private` schema for privileged
-- helper functions, and the reusable updated_at trigger function.
--
-- Rollback strategy:
--   drop function if exists public.set_updated_at() cascade;
--   drop schema if exists private cascade;
--   -- pg_trgm is left installed (harmless, shared).
-- ============================================================================

-- Trigram similarity for normalized-name search (artists/albums/tracks).
create extension if not exists pg_trgm with schema extensions;

-- Non-exposed schema for privileged helpers (NOT served by PostgREST).
-- All security-definer functions live here so they are never callable as
-- anonymous API endpoints from the `public` schema.
create schema if not exists private;
revoke all on schema private from public;
revoke all on schema private from anon, authenticated;
-- USAGE (name resolution only) is granted because RLS policies evaluate
-- private.* helper functions with the caller's privileges. Each function in
-- this schema individually grants/revokes EXECUTE, and PostgREST never
-- exposes `private` as an API schema, so nothing here is client-callable.
grant usage on schema private to anon, authenticated;

-- Reusable, safe updated_at maintenance trigger.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

comment on function public.set_updated_at() is
  'Sets NEW.updated_at = now() on UPDATE. Attach as BEFORE UPDATE trigger to every mutable table.';
