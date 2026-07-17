// PLACEHOLDER — NOT DEPLOYED. See supabase/functions/README.md.
// Future: authenticated endpoint that creates a Stripe Checkout Session for a
// given subscription_plans.code, creating/reusing the billing_customers row.

Deno.serve(() =>
  new Response(
    JSON.stringify({ error: { code: 'NOT_IMPLEMENTED', message: 'Checkout is not enabled in this phase.' } }),
    { status: 501, headers: { 'Content-Type': 'application/json' } },
  ));
