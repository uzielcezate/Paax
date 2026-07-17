-- ============================================================================
-- Migration: billing
-- Phase 1 — Supabase foundation (ADR-009).
-- Provider-agnostic subscription & billing readiness. NO live payment
-- processing, NO Stripe credentials, NO sensitive payment instruments are
-- stored (no card numbers, CVVs, bank details — only opaque provider IDs).
--
-- Authoritative subscription state lives HERE (user_subscriptions);
-- profiles.subscription_tier/status are cached convenience values only,
-- synced by trigger from this table.
--
-- Seeded prices are PROVISIONAL placeholders (documented in docs/decisions.md
-- ADR-009): premium_monthly = 9900 minor units, premium_yearly = 99900 minor
-- units, currency 'mxn'. Final production pricing is a Phase 2+ decision.
--
-- Rollback strategy (reverse order):
--   drop function if exists public.current_user_entitlements();
--   drop function if exists private.sync_profile_subscription_cache() cascade;
--   drop table if exists public.billing_events, public.user_subscriptions,
--     public.billing_customers, public.plan_features,
--     public.subscription_plans cascade;
-- ============================================================================

create table public.subscription_plans (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  name text not null,
  description text,
  billing_interval text,
  currency text,
  price_minor_units integer,
  trial_days integer not null default 0,
  is_active boolean not null default true,
  provider text,
  provider_product_id text,
  provider_price_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint plans_code_format check (code ~ '^[a-z0-9_]+$'),
  constraint plans_interval_valid
    check (billing_interval is null or billing_interval in ('month','year','week','day')),
  constraint plans_currency_format
    check (currency is null or currency ~ '^[a-z]{3}$'),
  constraint plans_price_nonnegative
    check (price_minor_units is null or price_minor_units >= 0),
  constraint plans_trial_nonnegative check (trial_days >= 0)
);

create trigger set_subscription_plans_updated_at
  before update on public.subscription_plans
  for each row execute function public.set_updated_at();

create table public.plan_features (
  id uuid primary key default gen_random_uuid(),
  plan_id uuid not null references public.subscription_plans(id) on delete cascade,
  feature_key text not null,
  enabled boolean not null default true,
  limit_value bigint,
  config jsonb,
  created_at timestamptz not null default now(),

  unique (plan_id, feature_key),
  constraint plan_features_key_format check (feature_key ~ '^[a-z0-9_]+$'),
  constraint plan_features_limit_nonnegative
    check (limit_value is null or limit_value >= 0)
);
create index idx_plan_features_plan_id on public.plan_features (plan_id);

create table public.billing_customers (
  id uuid primary key default gen_random_uuid(),
  user_id uuid unique not null references public.profiles(id) on delete cascade,
  provider text,
  provider_customer_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique (provider, provider_customer_id)
);

create trigger set_billing_customers_updated_at
  before update on public.billing_customers
  for each row execute function public.set_updated_at();

create table public.user_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  plan_id uuid not null references public.subscription_plans(id) on delete restrict,
  provider text,
  provider_subscription_id text,
  status text not null,
  current_period_start timestamptz,
  current_period_end timestamptz,
  cancel_at_period_end boolean not null default false,
  canceled_at timestamptz,
  trial_start timestamptz,
  trial_end timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint subscriptions_status_valid
    check (status in
      ('inactive','trialing','active','past_due','canceled','unpaid','paused','expired'))
);

create index idx_user_subscriptions_user_id on public.user_subscriptions (user_id);
create index idx_user_subscriptions_plan_id on public.user_subscriptions (plan_id);
create index idx_user_subscriptions_status_period_end
  on public.user_subscriptions (status, current_period_end);
-- At most one live subscription per user.
create unique index idx_user_subscriptions_one_active
  on public.user_subscriptions (user_id)
  where status in ('active','trialing');

create trigger set_user_subscriptions_updated_at
  before update on public.user_subscriptions
  for each row execute function public.set_updated_at();

-- Keep the profiles convenience cache in sync with authoritative state.
-- Runs as definer (backend/webhooks mutate this table; clients cannot).
create or replace function private.sync_profile_subscription_cache()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_tier text;
  v_status text;
  v_expires timestamptz;
begin
  v_user_id := coalesce(new.user_id, old.user_id);

  select
    case
      when p.code like 'premium%' then 'premium'
      when p.code like 'family%' then 'family'
      when p.code like 'student%' then 'student'
      else 'free'
    end,
    s.status,
    s.current_period_end
  into v_tier, v_status, v_expires
  from public.user_subscriptions s
  join public.subscription_plans p on p.id = s.plan_id
  where s.user_id = v_user_id
    and s.status in ('active','trialing')
  order by s.created_at desc
  limit 1;

  update public.profiles
  set subscription_tier = coalesce(v_tier, 'free'),
      subscription_status = coalesce(v_status, 'inactive'),
      subscription_expires_at = v_expires
  where id = v_user_id;

  return coalesce(new, old);
end;
$$;

revoke execute on function private.sync_profile_subscription_cache()
  from public, anon, authenticated;

create trigger sync_profile_subscription_cache
  after insert or update or delete on public.user_subscriptions
  for each row execute function private.sync_profile_subscription_cache();

-- Idempotent provider webhook/event ledger. Backend/service-role ONLY.
create table public.billing_events (
  id uuid primary key default gen_random_uuid(),
  provider text not null,
  provider_event_id text not null,
  event_type text not null,
  payload jsonb,
  processing_status text not null default 'received',
  received_at timestamptz not null default now(),
  processed_at timestamptz,
  error_message text,

  unique (provider, provider_event_id),
  constraint billing_events_processing_status_valid
    check (processing_status in ('received','processing','processed','failed','skipped'))
);
create index idx_billing_events_status
  on public.billing_events (processing_status, received_at);

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.subscription_plans enable row level security;
alter table public.plan_features enable row level security;
alter table public.billing_customers enable row level security;
alter table public.user_subscriptions enable row level security;
alter table public.billing_events enable row level security;

-- Plans & features are public marketing/entitlement data.
create policy "Active plans are publicly readable" on public.subscription_plans
  for select to anon, authenticated using (is_active = true);
create policy "Plan features are publicly readable" on public.plan_features
  for select to anon, authenticated using (true);

-- Users may see (not modify) their own billing linkage & subscriptions.
-- All writes are backend/service-role only (no client write policies).
create policy "Users read their own billing customer" on public.billing_customers
  for select to authenticated using ((select auth.uid()) = user_id);
create policy "Users read their own subscriptions" on public.user_subscriptions
  for select to authenticated using ((select auth.uid()) = user_id);

-- billing_events: RLS enabled with NO policies — service-role only by design.

-- ---------------------------------------------------------------------------
-- current_user_entitlements — effective features from the caller's active
-- subscription plan, falling back to the free plan. security invoker: relies
-- on the caller's own RLS access to user_subscriptions.
-- ---------------------------------------------------------------------------
create or replace function public.current_user_entitlements()
returns table (feature_key text, enabled boolean, limit_value bigint, config jsonb)
language sql
stable
security invoker
set search_path = ''
as $$
  select pf.feature_key, pf.enabled, pf.limit_value, pf.config
  from public.plan_features pf
  where pf.plan_id = coalesce(
    (
      select s.plan_id
      from public.user_subscriptions s
      where s.user_id = (select auth.uid())
        and s.status in ('active','trialing')
      order by s.created_at desc
      limit 1
    ),
    (select p.id from public.subscription_plans p where p.code = 'free')
  );
$$;

revoke execute on function public.current_user_entitlements() from public, anon;
grant execute on function public.current_user_entitlements() to authenticated;

-- ---------------------------------------------------------------------------
-- Seed data — structural only (no credentials, no catalog content).
-- Idempotent: safe to re-run.
-- ---------------------------------------------------------------------------
insert into public.subscription_plans
  (code, name, description, billing_interval, currency, price_minor_units, trial_days, is_active)
values
  ('free', 'Paax Free', 'Free tier with ads and core listening features.',
   null, null, 0, 0, true),
  -- PROVISIONAL placeholder pricing (see ADR-009); not production pricing.
  ('premium_monthly', 'Paax Premium (Monthly)',
   'Premium tier, billed monthly. Placeholder price pending final pricing decision.',
   'month', 'mxn', 9900, 0, true),
  ('premium_yearly', 'Paax Premium (Yearly)',
   'Premium tier, billed yearly. Placeholder price pending final pricing decision.',
   'year', 'mxn', 99900, 0, true)
on conflict (code) do nothing;

-- Free plan: limited features.
insert into public.plan_features (plan_id, feature_key, enabled, limit_value)
select p.id, f.feature_key, f.enabled, f.limit_value
from public.subscription_plans p
cross join (values
  ('ad_free',                  false, null::bigint),
  ('unlimited_skips',          false, 6),
  ('high_quality_option',      false, null),
  ('offline_downloads',        false, 0),
  ('unlimited_library',        true,  null),
  ('social_features',          true,  null),
  ('family_members',           false, 0),
  ('story_creation',           true,  null),
  ('advanced_recommendations', false, null)
) as f(feature_key, enabled, limit_value)
where p.code = 'free'
on conflict (plan_id, feature_key) do nothing;

-- Premium plans (monthly + yearly share the same entitlements).
insert into public.plan_features (plan_id, feature_key, enabled, limit_value)
select p.id, f.feature_key, f.enabled, f.limit_value
from public.subscription_plans p
cross join (values
  ('ad_free',                  true,  null::bigint),
  ('unlimited_skips',          true,  null),
  ('high_quality_option',      true,  null),
  ('offline_downloads',        true,  null),
  ('unlimited_library',        true,  null),
  ('social_features',          true,  null),
  ('family_members',           false, 0),
  ('story_creation',           true,  null),
  ('advanced_recommendations', true,  null)
) as f(feature_key, enabled, limit_value)
where p.code in ('premium_monthly', 'premium_yearly')
on conflict (plan_id, feature_key) do nothing;
