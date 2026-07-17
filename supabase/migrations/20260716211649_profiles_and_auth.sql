-- ============================================================================
-- Migration: profiles_and_auth
-- Phase 1 — Supabase foundation (ADR-009).
-- 1:1 profile per auth.users row, auto-created on signup, with strict
-- protection of privileged columns (role / subscription fields).
--
-- Supabase Auth remains the single authority for identity + credentials.
-- No plaintext credentials exist anywhere in this migration.
--
-- Rollback strategy:
--   drop trigger if exists on_auth_user_created on auth.users;
--   drop function if exists private.handle_new_user();
--   drop function if exists private.protect_profile_privileged_columns();
--   drop view if exists public.public_profiles;
--   drop table if exists public.profiles cascade;
-- ============================================================================

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique,
  display_name text,
  avatar_original_url text,
  avatar_url text,
  -- PRIVATE fields: never exposed through public_profiles.
  birth_date date,
  gender_identity text,
  country_code text,
  state_region text,
  city text,
  latitude_approx numeric,
  longitude_approx numeric,
  -- Privileged fields: protected by trigger; backend/service-role writes only.
  app_role text not null default 'user',
  -- Cached convenience value ONLY. Authoritative state = user_subscriptions.
  subscription_tier text not null default 'free',
  subscription_status text not null default 'inactive',
  subscription_expires_at timestamptz,
  is_private boolean not null default false,
  onboarding_completed boolean not null default false,
  last_seen_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint profiles_username_format check (username ~ '^[a-z0-9_.]{3,30}$'),
  constraint profiles_app_role_valid
    check (app_role in ('user','moderator','admin','owner')),
  constraint profiles_subscription_tier_valid
    check (subscription_tier in ('free','premium','family','student')),
  constraint profiles_subscription_status_valid
    check (subscription_status in
      ('inactive','trialing','active','past_due','canceled','unpaid','paused','expired')),
  constraint profiles_country_code_format
    check (country_code is null or country_code ~ '^[A-Z]{2}$'),
  constraint profiles_latitude_range
    check (latitude_approx is null or (latitude_approx >= -90 and latitude_approx <= 90)),
  constraint profiles_longitude_range
    check (longitude_approx is null or (longitude_approx >= -180 and longitude_approx <= 180)),
  constraint profiles_gender_identity_length
    check (gender_identity is null or length(gender_identity) <= 60)
);

create trigger set_profiles_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Auto-create a profile on Auth signup.
--  * Uses metadata username only when valid AND free; otherwise derives a
--    safe temporary username from the user id.
--  * Never blocks signup: any unexpected error falls back to the derived name.
--  * NEVER reads role/tier from user metadata (privilege-escalation safe):
--    new users are always user / free / inactive via column defaults.
-- ---------------------------------------------------------------------------
create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_username text;
  v_fallback text;
begin
  v_fallback := 'user_' || replace(left(new.id::text, 13), '-', '');
  v_username := lower(trim(coalesce(new.raw_user_meta_data->>'username', '')));

  if v_username !~ '^[a-z0-9_.]{3,30}$'
     or exists (select 1 from public.profiles p where p.username = v_username) then
    v_username := v_fallback;
  end if;

  begin
    insert into public.profiles (id, username, display_name)
    values (
      new.id,
      v_username,
      nullif(left(trim(coalesce(new.raw_user_meta_data->>'display_name', '')), 60), '')
    )
    on conflict (id) do nothing;
  exception when others then
    -- Optional fields must never fail signup; retry with the safe minimum.
    insert into public.profiles (id, username)
    values (new.id, v_fallback)
    on conflict (id) do nothing;
  end;

  return new;
end;
$$;

revoke execute on function private.handle_new_user() from public, anon, authenticated;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_user();

-- ---------------------------------------------------------------------------
-- Privileged-column protection: clients (anon/authenticated) can update their
-- own profile but can NEVER change role, subscription fields, id or created_at.
-- service_role / postgres (backend, billing jobs) are unaffected.
-- ---------------------------------------------------------------------------
create or replace function private.protect_profile_privileged_columns()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if current_user in ('anon', 'authenticated') and (
       new.id is distinct from old.id
       or new.app_role is distinct from old.app_role
       or new.subscription_tier is distinct from old.subscription_tier
       or new.subscription_status is distinct from old.subscription_status
       or new.subscription_expires_at is distinct from old.subscription_expires_at
       or new.created_at is distinct from old.created_at
     ) then
    raise exception 'privileged profile columns cannot be modified by clients'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger protect_profiles_privileged_columns
  before update on public.profiles
  for each row execute function private.protect_profile_privileged_columns();

-- ---------------------------------------------------------------------------
-- RLS: users read/update ONLY their own full row. Public exposure happens
-- exclusively through the safe-column public_profiles view below.
-- ---------------------------------------------------------------------------
alter table public.profiles enable row level security;

create policy "Users can read their own profile"
  on public.profiles for select
  to authenticated
  using ((select auth.uid()) = id);

create policy "Users can insert their own profile"
  on public.profiles for insert
  to authenticated
  with check (
    (select auth.uid()) = id
    and app_role = 'user'
    and subscription_tier = 'free'
    and subscription_status = 'inactive'
  );

create policy "Users can update their own profile"
  on public.profiles for update
  to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);

-- ---------------------------------------------------------------------------
-- public_profiles — safe public projection.
-- DELIBERATE PATTERN (documented in docs/security.md): this view is owned by
-- `postgres` and does NOT use security_invoker, because the base table's RLS
-- is intentionally own-row-only. The view exposes ONLY safe columns and only
-- non-private profiles (plus the caller's own). Never add private columns
-- (birth_date, coordinates, subscription, location) to this view.
-- ---------------------------------------------------------------------------
create view public.public_profiles
with (security_barrier = true)
as
select
  id,
  username,
  display_name,
  avatar_url,
  is_private,
  created_at
from public.profiles
where is_private = false
   or id = (select auth.uid());

grant select on public.public_profiles to anon, authenticated;
