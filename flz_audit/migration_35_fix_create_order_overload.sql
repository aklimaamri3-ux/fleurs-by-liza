-- CRITICAL FIX: migration_33's CREATE OR REPLACE FUNCTION with an
-- expanded parameter list did NOT replace create_order/
-- create_cart_order — Postgres only replaces a function when the
-- full parameter signature matches exactly, so adding new (even
-- defaulted) parameters silently created a SECOND overload instead,
-- leaving both the old 16/14-param and new 19/17-param versions live
-- side by side. PostgREST then refuses any RPC call whose JSON body
-- doesn't uniquely match exactly one overload — confirmed live: a
-- call sending only the original parameters (no gift fields) failed
-- with PGRST203 "Could not choose the best candidate function".
--
-- checkout.html always sends all gift-related params (even when
-- false/null) so real customer checkout was not exposed to this, but
-- any other caller using the original parameter set — including a
-- direct RPC call, as confirmed by this session's own test — was
-- broken. Fixed by dropping the old-shape overloads outright; the
-- surviving 19/17-param versions have DEFAULT values for the new
-- params, so a call with just the original arguments still resolves
-- correctly and unambiguously once the old overload is gone.

begin;

drop function if exists public.create_order(
  text, text, text, integer, text, text, text, text, integer, text, text, text, text, text, text, text
);

drop function if exists public.create_cart_order(
  text, jsonb, text, text, integer, text, text, text, text, text, text, text, text, text
);

commit;
