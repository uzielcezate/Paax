-- Phase 3.4.1 — Cloud Playlists: additive schema for ownership, collaboration,
-- versioning, activity history, and blocking. Additive + idempotent; all
-- playlist tables are currently empty so there is zero data risk.

-- ── playlists: versioning, soft-delete, last-modified, cover mode, provenance ──
alter table public.playlists
  add column if not exists last_modified_at timestamptz not null default now(),
  add column if not exists last_modified_by uuid,
  add column if not exists version bigint not null default 1,
  add column if not exists deleted_at timestamptz,
  add column if not exists cover_mode text not null default 'generated',
  add column if not exists custom_cover_url text,
  add column if not exists source_playlist_id uuid;

-- ── playlist_tracks: updated_at + integrity constraints ──
alter table public.playlist_tracks
  add column if not exists updated_at timestamptz not null default now();

do $$ begin
  -- Deferrable so a reorder RPC can renumber positions inside one transaction
  -- without tripping the unique check mid-statement.
  if not exists (select 1 from pg_constraint where conname = 'playlist_tracks_playlist_position_key') then
    alter table public.playlist_tracks
      add constraint playlist_tracks_playlist_position_key
      unique (playlist_id, position) deferrable initially deferred;
  end if;
  -- Product policy: no duplicate track in the same playlist.
  if not exists (select 1 from pg_constraint where conname = 'playlist_tracks_playlist_track_key') then
    alter table public.playlist_tracks
      add constraint playlist_tracks_playlist_track_key unique (playlist_id, track_id);
  end if;
end $$;

-- ── playlist_collaborators: invitation lifecycle ──
alter table public.playlist_collaborators
  add column if not exists status text not null default 'pending',
  add column if not exists invited_by uuid,
  add column if not exists invited_at timestamptz not null default now(),
  add column if not exists accepted_at timestamptz,
  add column if not exists joined_at timestamptz,
  add column if not exists updated_at timestamptz not null default now();

-- ── playlist_activity: append-only audit/event log ──
create table if not exists public.playlist_activity (
  id uuid primary key default gen_random_uuid(),
  playlist_id uuid not null references public.playlists(id) on delete cascade,
  actor_id uuid,
  event_type text not null,
  created_at timestamptz not null default now(),
  playlist_version bigint,
  metadata jsonb not null default '{}'::jsonb,
  grouped_change_id uuid
);
create index if not exists idx_playlist_activity_playlist_created
  on public.playlist_activity(playlist_id, created_at desc);

alter table public.playlist_activity enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname='public'
      and tablename='playlist_activity' and policyname='Activity visible with the playlist') then
    create policy "Activity visible with the playlist" on public.playlist_activity
      for select using (private.can_view_playlist(playlist_id, (select auth.uid())));
  end if;
end $$;
-- No INSERT/UPDATE/DELETE policy: only SECURITY DEFINER RPCs write activity.

-- ── user_blocks: minimal reusable blocking seam (no full UI this phase) ──
create table if not exists public.user_blocks (
  blocker_id uuid not null,
  blocked_id uuid not null,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  constraint user_blocks_no_self check (blocker_id <> blocked_id)
);
alter table public.user_blocks enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname='public'
      and tablename='user_blocks' and policyname='Users read their own blocks') then
    create policy "Users read their own blocks" on public.user_blocks
      for select using (blocker_id = (select auth.uid()));
  end if;
  if not exists (select 1 from pg_policies where schemaname='public'
      and tablename='user_blocks' and policyname='Users create their own blocks') then
    create policy "Users create their own blocks" on public.user_blocks
      for insert with check (blocker_id = (select auth.uid()));
  end if;
  if not exists (select 1 from pg_policies where schemaname='public'
      and tablename='user_blocks' and policyname='Users delete their own blocks') then
    create policy "Users delete their own blocks" on public.user_blocks
      for delete using (blocker_id = (select auth.uid()));
  end if;
end $$;

-- is_blocked: true if EITHER user blocks the other (symmetric access denial).
create or replace function private.is_blocked(p_a uuid, p_b uuid)
returns boolean language sql stable security definer set search_path to '' as $$
  select exists (
    select 1 from public.user_blocks b
    where (b.blocker_id = p_a and b.blocked_id = p_b)
       or (b.blocker_id = p_b and b.blocked_id = p_a)
  );
$$;
revoke all on function private.is_blocked(uuid, uuid) from public, anon, authenticated;
