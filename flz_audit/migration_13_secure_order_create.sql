-- Fix: migration_12 dropped orders_receipt_select (the RLS hole that let
-- anon read every order). But checkout.html's INSERT always used
-- `Prefer: return=representation`, and Postgres requires the newly
-- inserted row to satisfy a SELECT policy to be returned via RETURNING —
-- with no SELECT policy left for anon at all, every checkout now fails
-- with 42501 even though the INSERT (orders_anon_insert, with_check=true)
-- is itself unaffected and still correct.
--
-- Fix: move order creation behind a SECURITY DEFINER RPC. The function
-- owner bypasses RLS internally (same mechanism already used by
-- get_order_by_token/submit_order_receipt/apply_coupon_to_order), so it
-- can INSERT and RETURN the new row without any anon SELECT policy on
-- the table — meaning the table stays fully non-readable/non-updatable
-- for anon. auth.role()/auth.uid() inside orders_secure_insert are read
-- from the request's JWT claims, not the Postgres execution role, so
-- SECURITY DEFINER does NOT change the trigger's is_priv check — every
-- price/delivery/total/coupon/deposit field is still recomputed
-- server-side exactly as before, and this cannot be used to submit an
-- order "as admin".

begin;

drop function if exists public.create_order(
  text, text, text, integer, text, text, text, text, integer, text, text, text, text, text, text, text
);

create or replace function public.create_order(
  p_id text,
  p_name text,
  p_phone text,
  p_wilaya_id integer,
  p_commune text,
  p_address text,
  p_product_id text,
  p_color text,
  p_qty integer,
  p_payment_method text,
  p_fulfillment_type text,
  p_note text,
  p_lang text,
  p_email text,
  p_coupon_code text,
  p_client_ref text
)
returns table (
  id text,
  ref text,
  receipt_token text,
  total integer,
  delivery_cost integer,
  deposit_amount integer,
  payment_status text,
  status text,
  fulfillment_type text,
  wilaya text
)
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  return query
  insert into public.orders (
    id, name, phone, wilaya_id, commune, address,
    product_id, color, qty, payment_method, fulfillment_type,
    note, lang, email, coupon_code, client_ref, created_at
  ) values (
    p_id, p_name, p_phone, p_wilaya_id, nullif(p_commune,''), nullif(p_address,''),
    p_product_id, p_color, p_qty, p_payment_method, p_fulfillment_type,
    nullif(p_note,''), p_lang, nullif(p_email,''), nullif(p_coupon_code,''), p_client_ref, now()
  )
  returning
    orders.id, orders.ref, orders.receipt_token, orders.total, orders.delivery_cost,
    orders.deposit_amount, orders.payment_status, orders.status, orders.fulfillment_type, orders.wilaya;
end;
$$;

revoke all on function public.create_order(
  text, text, text, integer, text, text, text, text, integer, text, text, text, text, text, text, text
) from public;
grant execute on function public.create_order(
  text, text, text, integer, text, text, text, text, integer, text, text, text, text, text, text, text
) to anon, authenticated;

commit;
