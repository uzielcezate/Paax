-- ============================================================================
-- Migration: stories
-- Phase 1 — Supabase foundation (ADR-009).
-- 24-hour stories with at most one linked music entity, soft deletion,
-- comments (soft delete), deduplicated views, single reaction per user, and
-- an active_stories view that excludes expired/deleted rows.
--
-- Cleanup strategy (documented, NOT implemented in this phase): expired
-- stories are soft-hidden by queries; a future scheduled job (pg_cron or
-- backend worker) will hard-delete stories + their story-media Storage
-- objects N days after expiry. Do not hard-delete immediately on expiry.
--
-- Visibility rules: owner always sees own stories (even expired/deleted by
-- soft flag until purge). Others see active stories of non-private profiles,
-- or of friends when the profile is private.
--
-- Rollback strategy:
--   drop view if exists public.active_stories;
--   drop table if exists public.story_reactions, public.story_views,
--     public.story_comments, public.stories cascade;
--   drop function if exists private.can_view_story(uuid, uuid) cascade;
-- ============================================================================

create table public.stories (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  body text,
  media_url text,
  background_style jsonb,
  linked_track_id uuid references public.tracks(id) on delete set null,
  linked_album_id uuid references public.albums(id) on delete set null,
  linked_artist_id uuid references public.artists(id) on delete set null,
  linked_playlist_id uuid references public.playlists(id) on delete set null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '24 hours'),
  deleted_at timestamptz,

  constraint stories_single_linked_entity check (
    (case when linked_track_id    is not null then 1 else 0 end
   + case when linked_album_id    is not null then 1 else 0 end
   + case when linked_artist_id   is not null then 1 else 0 end
   + case when linked_playlist_id is not null then 1 else 0 end) <= 1
  ),
  constraint stories_expiry_after_creation check (expires_at > created_at),
  constraint stories_body_length check (body is null or length(body) <= 2000)
);

create index idx_stories_user_id on public.stories (user_id);
-- Active-story feed lookups.
create index idx_stories_active on public.stories (user_id, expires_at desc)
  where deleted_at is null;
create index idx_stories_expires_at on public.stories (expires_at);
create index idx_stories_linked_track_id on public.stories (linked_track_id);
create index idx_stories_linked_album_id on public.stories (linked_album_id);
create index idx_stories_linked_artist_id on public.stories (linked_artist_id);
create index idx_stories_linked_playlist_id on public.stories (linked_playlist_id);

create table public.story_comments (
  id uuid primary key default gen_random_uuid(),
  story_id uuid not null references public.stories(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  body text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,

  constraint story_comments_body_not_empty check (length(trim(body)) > 0),
  constraint story_comments_body_length check (length(body) <= 1000)
);
create index idx_story_comments_story_id
  on public.story_comments (story_id, created_at);
create index idx_story_comments_user_id on public.story_comments (user_id);

create trigger set_story_comments_updated_at
  before update on public.story_comments
  for each row execute function public.set_updated_at();

-- One view row per (story, viewer): duplicate views are intentionally impossible.
create table public.story_views (
  story_id uuid not null references public.stories(id) on delete cascade,
  viewer_id uuid not null references public.profiles(id) on delete cascade,
  viewed_at timestamptz not null default now(),
  primary key (story_id, viewer_id)
);
create index idx_story_views_viewer_id on public.story_views (viewer_id);

-- One reaction per (story, user); changing reaction = update emoji.
create table public.story_reactions (
  story_id uuid not null references public.stories(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  emoji text not null,
  created_at timestamptz not null default now(),
  primary key (story_id, user_id),
  constraint story_reactions_emoji_length check (length(emoji) between 1 and 16)
);
create index idx_story_reactions_user_id on public.story_reactions (user_id);

-- ---------------------------------------------------------------------------
-- Visibility helper
-- ---------------------------------------------------------------------------
create or replace function private.can_view_story(p_story_id uuid, p_user_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_owner uuid;
  v_expired boolean;
  v_deleted boolean;
  v_owner_private boolean;
begin
  select s.user_id, s.expires_at <= now(), s.deleted_at is not null
    into v_owner, v_expired, v_deleted
  from public.stories s where s.id = p_story_id;

  if not found then
    return false;
  end if;

  -- Owner always sees their own stories.
  if p_user_id is not null and v_owner = p_user_id then
    return true;
  end if;

  if v_expired or v_deleted then
    return false;
  end if;

  select p.is_private into v_owner_private
  from public.profiles p where p.id = v_owner;

  if coalesce(v_owner_private, true) = false then
    return true;
  end if;

  return p_user_id is not null and private.is_accepted_friend(v_owner, p_user_id);
end;
$$;

-- Used inside RLS policies (caller-evaluated): anon/authenticated need
-- EXECUTE. Not API-callable (private schema is not exposed by PostgREST).
revoke execute on function private.can_view_story(uuid, uuid) from public;
grant execute on function private.can_view_story(uuid, uuid) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.stories enable row level security;
alter table public.story_comments enable row level security;
alter table public.story_views enable row level security;
alter table public.story_reactions enable row level security;

-- stories
create policy "Stories visible per visibility rules" on public.stories
  for select to anon, authenticated
  using (private.can_view_story(id, (select auth.uid())));
create policy "Users create their own stories" on public.stories
  for insert to authenticated
  with check (
    (select auth.uid()) = user_id
    and expires_at <= now() + interval '24 hours'
  );
-- Owner update = soft delete / edit; expiry cannot be extended past 24h.
create policy "Owners update their own stories" on public.stories
  for update to authenticated
  using ((select auth.uid()) = user_id)
  with check (
    (select auth.uid()) = user_id
    and expires_at <= created_at + interval '24 hours'
  );
create policy "Owners delete their own stories" on public.stories
  for delete to authenticated
  using ((select auth.uid()) = user_id);

-- comments: visible on viewable stories (excluding soft-deleted comments for
-- everyone but their author); authors manage their own comments.
create policy "Comments visible on viewable stories" on public.story_comments
  for select to authenticated
  using (
    private.can_view_story(story_id, (select auth.uid()))
    and (deleted_at is null or user_id = (select auth.uid()))
  );
create policy "Users comment on viewable stories" on public.story_comments
  for insert to authenticated
  with check (
    (select auth.uid()) = user_id
    and private.can_view_story(story_id, (select auth.uid()))
  );
create policy "Authors update their own comments" on public.story_comments
  for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);
create policy "Authors delete their own comments" on public.story_comments
  for delete to authenticated
  using ((select auth.uid()) = user_id);

-- views: story owner sees who viewed; viewers see their own view rows.
create policy "Story owners and viewers read view receipts" on public.story_views
  for select to authenticated
  using (
    viewer_id = (select auth.uid())
    or exists (select 1 from public.stories s
               where s.id = story_id and s.user_id = (select auth.uid()))
  );
create policy "Users record their own story views" on public.story_views
  for insert to authenticated
  with check (
    (select auth.uid()) = viewer_id
    and private.can_view_story(story_id, (select auth.uid()))
  );

-- reactions
create policy "Reactions visible on viewable stories" on public.story_reactions
  for select to authenticated
  using (private.can_view_story(story_id, (select auth.uid())));
create policy "Users react to viewable stories" on public.story_reactions
  for insert to authenticated
  with check (
    (select auth.uid()) = user_id
    and private.can_view_story(story_id, (select auth.uid()))
  );
create policy "Users change their own reactions" on public.story_reactions
  for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);
create policy "Users remove their own reactions" on public.story_reactions
  for delete to authenticated
  using ((select auth.uid()) = user_id);

-- ---------------------------------------------------------------------------
-- active_stories — the supported feed query. security_invoker: RLS on
-- public.stories applies to the caller, so this never leaks private stories.
-- ---------------------------------------------------------------------------
create view public.active_stories
with (security_invoker = true)
as
select
  s.id,
  s.user_id,
  s.body,
  s.media_url,
  s.background_style,
  s.linked_track_id,
  s.linked_album_id,
  s.linked_artist_id,
  s.linked_playlist_id,
  s.created_at,
  s.expires_at
from public.stories s
where s.deleted_at is null
  and s.expires_at > now();

grant select on public.active_stories to anon, authenticated;
