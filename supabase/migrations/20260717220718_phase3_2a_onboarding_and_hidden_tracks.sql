-- ============================================================================
-- Migration: phase3_2a_onboarding_and_hidden_tracks
-- Phase 3.2A — real artist onboarding + cross-device hidden tracks.
--
-- Additive and backwards-compatible. Adds:
--   1. public.user_hidden_tracks         — per-user hidden/disliked catalog tracks
--   2. public.complete_artist_onboarding — atomic onboarding completion RPC
--
-- No existing object is altered. Counters remain trigger-maintained; this
-- migration never writes a denormalized counter directly. onboarding_completed
-- is flipped ONLY through the RPC below (atomic with the artist follows).
--
-- Rollback strategy (reverse order):
--   revoke execute on function public.complete_artist_onboarding(uuid[]) from authenticated;
--   drop function if exists public.complete_artist_onboarding(uuid[]);
--   drop table if exists public.user_hidden_tracks cascade;
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Hidden / disliked tracks (cross-device).
--    Hiding does NOT delete the catalog track; it excludes it from automatic
--    playback and future recommendation inputs (see docs/features/library.md).
-- ---------------------------------------------------------------------------
create table if not exists public.user_hidden_tracks (
  user_id uuid not null references public.profiles(id) on delete cascade,
  track_id uuid not null references public.tracks(id) on delete cascade,
  reason text,
  created_at timestamptz not null default now(),
  primary key (user_id, track_id),
  constraint uht_reason_len check (reason is null or char_length(reason) <= 40)
);

create index if not exists idx_user_hidden_tracks_track_id
  on public.user_hidden_tracks (track_id);

alter table public.user_hidden_tracks enable row level security;

drop policy if exists "Users read their own hidden tracks" on public.user_hidden_tracks;
create policy "Users read their own hidden tracks"
  on public.user_hidden_tracks for select
  using ((select auth.uid()) = user_id);

drop policy if exists "Users hide their own tracks" on public.user_hidden_tracks;
create policy "Users hide their own tracks"
  on public.user_hidden_tracks for insert
  with check ((select auth.uid()) = user_id);

drop policy if exists "Users unhide their own tracks" on public.user_hidden_tracks;
create policy "Users unhide their own tracks"
  on public.user_hidden_tracks for delete
  using ((select auth.uid()) = user_id);

-- ---------------------------------------------------------------------------
-- 2. complete_artist_onboarding(selected artist UUIDs)
--    Atomic: validates >= 5 unique, existing artists, inserts the follows
--    (idempotent), then marks onboarding complete. Runs as one transaction.
--
--    SECURITY DEFINER so the follows + onboarding flip commit atomically and
--    the caller can never target another user (user_id is taken from
--    auth.uid(), never from a client-supplied value). search_path is pinned to
--    '' per project convention; all objects are schema-qualified. The
--    private.bump_artist_followers trigger still maintains follower counts —
--    this function never writes a counter directly.
-- ---------------------------------------------------------------------------
create or replace function public.complete_artist_onboarding(p_artist_ids uuid[])
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_ids uuid[];
  v_unique_count int;
  v_existing_count int;
begin
  if v_uid is null then
    raise exception 'authentication required'
      using errcode = '42501';
  end if;

  -- De-duplicate and drop nulls from the client input.
  select array_agg(distinct id) into v_ids
  from unnest(coalesce(p_artist_ids, array[]::uuid[])) as id
  where id is not null;

  v_unique_count := coalesce(array_length(v_ids, 1), 0);
  if v_unique_count < 5 then
    raise exception 'onboarding requires at least 5 unique artists (got %)', v_unique_count
      using errcode = '22023';  -- invalid_parameter_value
  end if;

  -- Every id must reference a real catalog artist.
  select count(*) into v_existing_count
  from public.artists a
  where a.id = any(v_ids);

  if v_existing_count <> v_unique_count then
    raise exception 'one or more selected artists do not exist'
      using errcode = '23503';  -- foreign_key_violation
  end if;

  -- Idempotent follows for the authenticated user only.
  insert into public.user_followed_artists (user_id, artist_id)
  select v_uid, id from unnest(v_ids) as id
  on conflict (user_id, artist_id) do nothing;

  -- Mark onboarding complete (atomic with the follows above).
  update public.profiles
  set onboarding_completed = true
  where id = v_uid;

  return jsonb_build_object(
    'onboarding_completed', true,
    'followed_count', (
      select count(*) from public.user_followed_artists where user_id = v_uid
    )
  );
end;
$$;

-- Only signed-in users may call it. Never anon / public.
revoke all on function public.complete_artist_onboarding(uuid[]) from public;
revoke all on function public.complete_artist_onboarding(uuid[]) from anon;
grant execute on function public.complete_artist_onboarding(uuid[]) to authenticated;
