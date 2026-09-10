-- Order-confirmation reliability fix: if the customer's connection
-- drops (very common on Algerian mobile networks) right as
-- create_order/create_cart_order's response is coming back, the
-- order can be created successfully server-side while the customer's
-- browser sees a network error and shows nothing — no receipt_token,
-- no redirect to receipt.html, no confirmation at all, even though
-- the order genuinely exists. If checkout.html then retries the
-- exact same request (same p_id, same p_client_ref — a random UUID
-- generated once per page load), it gets a deterministic
-- "duplicate client_ref" error back, which today is shown to the
-- customer as an error and nothing else.
--
-- This RPC lets the client recover the *real* order (including its
-- receipt_token, needed for the confirmation page) using only the
-- client_ref it already generated itself — the same security model
-- already used for receipt_token: an unguessable, client-generated
-- random UUID (crypto.randomUUID(), ~122 bits of entropy) that is
-- never displayed or transmitted anywhere else. Scoped to orders
-- created in the last 30 minutes, since this exists purely to
-- recover from an immediate checkout-flow failure, not as a general
-- lookup endpoint.

begin;

create or replace function public.get_order_by_client_ref(p_client_ref text)
returns setof orders
language sql
stable
security definer
set search_path to 'public'
as $$
  select * from public.orders
  where client_ref is not null
    and client_ref = p_client_ref
    and created_at > now() - interval '30 minutes'
  limit 1;
$$;

commit;
