# Paax Edge Functions — Scaffolds (NOT deployed)

> **Status: placeholders only.** Nothing in this directory is deployed or
> operational. They document the intended Stripe integration surface for a
> later phase (see `docs/decisions.md` ADR-009). Do **not** deploy them until
> the billing phase is explicitly started.

| Function | Purpose (future) |
|----------|------------------|
| `stripe-checkout/` | Create a Stripe Checkout Session for a plan (`subscription_plans.provider_price_id`) |
| `stripe-portal/` | Create a Stripe Customer Portal session for self-service management |
| `stripe-webhook/` | Verify Stripe webhook signatures, write idempotent rows to `billing_events`, and update `user_subscriptions` |

## Required future environment variables (Supabase secrets — never commit)

| Variable | Used by |
|----------|---------|
| `STRIPE_SECRET_KEY` | checkout, portal, webhook |
| `STRIPE_WEBHOOK_SIGNING_SECRET` | webhook |
| `SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY` | provided automatically to Edge Functions |

Set with `supabase secrets set NAME=value` — **never** in code or migrations.

## Design constraints (already enforced by the schema)

- `billing_events (provider, provider_event_id)` is UNIQUE → webhook retries are idempotent.
- `user_subscriptions` allows only one `active`/`trialing` row per user (partial unique index).
- `profiles.subscription_tier/status` are cache columns synced by the
  `sync_profile_subscription_cache` trigger — the webhook only writes
  `user_subscriptions`, never `profiles`.
- All writes happen with the service role; clients have zero write policies on
  billing tables.
