// PLACEHOLDER — NOT DEPLOYED. See supabase/functions/README.md.
// Future: verify Stripe signature (STRIPE_WEBHOOK_SIGNING_SECRET), insert an
// idempotent row into public.billing_events, then update user_subscriptions.
// No secrets belong in this file — configuration comes from Supabase secrets.

Deno.serve(() =>
  new Response(
    JSON.stringify({ error: { code: 'NOT_IMPLEMENTED', message: 'Stripe webhook is not enabled in this phase.' } }),
    { status: 501, headers: { 'Content-Type': 'application/json' } },
  ));
