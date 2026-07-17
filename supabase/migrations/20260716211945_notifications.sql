-- ============================================================================
-- Migration: notifications
-- Phase 1 — Supabase foundation (ADR-009).
-- Minimal notifications foundation: registered devices (push tokens are
-- PRIVATE data — own-row RLS only) and a notifications inbox that only the
-- backend/service-role can create; users read + mark-read their own.
--
-- Rollback strategy:
--   drop table if exists public.notifications, public.user_devices cascade;
--   drop function if exists private.protect_notification_content() cascade;
-- ============================================================================

create table public.user_devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  device_id text not null,
  platform text not null,
  push_token text,
  is_active boolean not null default true,
  last_seen_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique (user_id, device_id),
  constraint user_devices_platform_valid
    check (platform in ('android','ios','web','other'))
);

create index idx_user_devices_user_id on public.user_devices (user_id);
-- Push fan-out: only active devices with a token.
create index idx_user_devices_active on public.user_devices (user_id)
  where is_active and push_token is not null;

create trigger set_user_devices_updated_at
  before update on public.user_devices
  for each row execute function public.set_updated_at();

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  type text not null,
  title text not null,
  body text,
  data jsonb,
  read_at timestamptz,
  created_at timestamptz not null default now(),

  constraint notifications_type_format check (type ~ '^[a-z0-9_.]+$'),
  constraint notifications_title_not_empty check (length(trim(title)) > 0)
);

create index idx_notifications_user_created
  on public.notifications (user_id, created_at desc);
create index idx_notifications_unread on public.notifications (user_id)
  where read_at is null;

-- Users may only mark-read/unread — never rewrite notification content.
create or replace function private.protect_notification_content()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if current_user in ('anon', 'authenticated') and (
       new.id is distinct from old.id
       or new.user_id is distinct from old.user_id
       or new.type is distinct from old.type
       or new.title is distinct from old.title
       or new.body is distinct from old.body
       or new.data is distinct from old.data
       or new.created_at is distinct from old.created_at
     ) then
    raise exception 'notification content cannot be modified by clients'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger protect_notification_content
  before update on public.notifications
  for each row execute function private.protect_notification_content();

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.user_devices enable row level security;
alter table public.notifications enable row level security;

-- Devices: full own-row management (push tokens never visible to others).
create policy "Users read their own devices" on public.user_devices
  for select to authenticated using ((select auth.uid()) = user_id);
create policy "Users register their own devices" on public.user_devices
  for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "Users update their own devices" on public.user_devices
  for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);
create policy "Users remove their own devices" on public.user_devices
  for delete to authenticated using ((select auth.uid()) = user_id);

-- Notifications: creation is backend/service-role only (no INSERT policy).
create policy "Users read their own notifications" on public.notifications
  for select to authenticated using ((select auth.uid()) = user_id);
create policy "Users mark their own notifications read" on public.notifications
  for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);
create policy "Users delete their own notifications" on public.notifications
  for delete to authenticated using ((select auth.uid()) = user_id);
