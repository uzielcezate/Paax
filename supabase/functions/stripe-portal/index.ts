// PLACEHOLDER — NOT DEPLOYED. See supabase/functions/README.md.
// Future: authenticated endpoint that opens a Stripe Customer Portal session
// for the caller's billing_customers.provider_customer_id.

Deno.serve(() =>
  new Response(
    JSON.stringify({ error: { code: 'NOT_IMPLEMENTED', message: 'Customer portal is not enabled in this phase.' } }),
    { status: 501, headers: { 'Content-Type': 'application/json' } },
  ));
