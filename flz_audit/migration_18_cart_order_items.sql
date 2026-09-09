-- Real multi-product shopping cart. Design constraint: orders_anon_insert
-- has with_check=true (fully open at the RLS layer) — all pricing trust
-- has always lived in the orders_secure_insert trigger, which fires on
-- every INSERT regardless of which function performs it. For a multi-item
-- order, the trigger cannot validate a single product_id/qty the way it
-- does for the existing (unchanged) single-item path — so instead:
--
--   1. order_items has RLS enabled with ZERO policies for anon at all
--      (default-deny). It can only ever be written by a SECURITY DEFINER
--      function (create_cart_order), which independently re-looks-up
--      each product's real price server-side — never trusts a client
--      price — before inserting.
--   2. orders_secure_insert, for a row flagged is_multi_item, computes the
--      order's total by reading the SUM of order_items.subtotal back from
--      the database — not from anything the client put on the orders row
--      itself. Since order_items can only be written by that one trusted
--      function, this is exactly as safe as the existing single-item path.
--   3. Delivery fee is computed by the trigger from wilaya/commune using
--      the exact same trusted lookup as the single-item branch — never
--      client-supplied.

begin;

create table if not exists public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id text not null references public.orders(id) on delete cascade deferrable initially deferred,
  product_id text,
  product_name text,
  product_sku text,
  product_price integer not null,
  qty integer not null,
  subtotal integer not null,
  created_at timestamptz not null default now()
);
create index if not exists order_items_order_id_idx on public.order_items(order_id);

alter table public.order_items enable row level security;
-- ✅ intentionally no anon policy of any kind — default-deny for anon on
-- every operation. Only admin can read directly; writes only ever happen
-- via the SECURITY DEFINER function below.
drop policy if exists order_items_admin_all on public.order_items;
create policy order_items_admin_all on public.order_items for all to authenticated
using (is_admin()) with check (is_admin());

alter table public.orders add column if not exists is_multi_item boolean not null default false;

-- ✅ shared delivery-fee resolver so both the legacy single-item trigger
-- branch and the new multi-item branch use identical, trusted logic
create or replace function public.resolve_delivery(p_wilaya_id integer, p_commune text, out wilaya_name text, out delivery_cost integer)
language plpgsql
security definer
set search_path to 'public'
as $$
DECLARE
  dp RECORD;
  commune_row jsonb;
  commune_price integer;
BEGIN
  IF p_wilaya_id IS NULL THEN
    RAISE EXCEPTION 'wilaya is required for delivery';
  END IF;
  SELECT * INTO dp FROM public.delivery_prices WHERE wilaya_id = p_wilaya_id AND active = true;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'invalid or disabled wilaya';
  END IF;
  wilaya_name := dp.wilaya_name;
  commune_price := NULL;
  IF p_commune IS NOT NULL AND p_commune <> '' THEN
    SELECT c INTO commune_row
    FROM jsonb_array_elements(COALESCE(dp.communes,'[]'::jsonb)) c
    WHERE (c->>'name') = p_commune
    LIMIT 1;
    IF commune_row IS NULL THEN
      RAISE EXCEPTION 'invalid commune for this wilaya';
    END IF;
    IF (commune_row->>'active') = 'false' THEN
      RAISE EXCEPTION 'this commune is currently disabled';
    END IF;
    IF (commune_row->>'home_price') IS NOT NULL THEN
      commune_price := (commune_row->>'home_price')::integer;
    END IF;
  END IF;
  delivery_cost := COALESCE(commune_price, dp.home_price, 0);
END;
$$;
revoke all on function public.resolve_delivery(integer, text) from public;

create or replace function public.orders_secure_insert()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
DECLARE
  prod RECORD;
  dres RECORD;
  is_priv boolean;
  enabled_methods jsonb;
  subtotal integer;
  discount integer;
  v_item_count integer;
  v_items_subtotal integer;
  v_items_qty integer;
BEGIN
  is_priv := (auth.role() = 'service_role')
    OR (auth.uid() IS NOT NULL AND EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'));

  IF is_priv THEN
    IF NEW.ref IS NULL OR NEW.ref = '' THEN NEW.ref := public.generate_order_ref(); END IF;
    IF NEW.product_sku IS NULL AND NEW.product_id IS NOT NULL THEN
      SELECT sku INTO NEW.product_sku FROM public.products WHERE id = NEW.product_id;
    END IF;
    RETURN NEW;
  END IF;

  -- ✅ multi-item cart order: total is read back from order_items, which
  -- only create_cart_order (SECURITY DEFINER, independently re-validates
  -- every product/price) can ever write.
  IF NEW.is_multi_item THEN
    SELECT count(*), COALESCE(sum(oi.subtotal),0), COALESCE(sum(oi.qty),0)
      INTO v_item_count, v_items_subtotal, v_items_qty
      FROM public.order_items AS oi WHERE oi.order_id = NEW.id;
    IF v_item_count = 0 THEN
      RAISE EXCEPTION 'cart order has no valid items';
    END IF;

    NEW.product_id := NULL;
    NEW.product_sku := NULL;
    NEW.product_price := NULL;
    NEW.product_emoji := '🛍️';
    NEW.product_name := v_item_count || ' produits';
    NEW.qty := v_items_qty;

    SELECT value INTO enabled_methods FROM public.settings WHERE key = 'pay_methods';
    IF enabled_methods IS NOT NULL AND NEW.payment_method IS NOT NULL
       AND NOT (enabled_methods ? NEW.payment_method) AND NEW.payment_method <> 'cod' THEN
      RAISE EXCEPTION 'this payment method is not currently available';
    END IF;

    IF NEW.payment_method = 'pickup' THEN NEW.fulfillment_type := 'pickup'; END IF;

    IF NEW.fulfillment_type = 'pickup' THEN
      NEW.delivery_cost := 0;
    ELSE
      NEW.fulfillment_type := 'delivery';
      SELECT * INTO dres FROM public.resolve_delivery(NEW.wilaya_id, NEW.commune);
      NEW.wilaya := dres.wilaya_name;
      NEW.delivery_cost := dres.delivery_cost;
    END IF;

    subtotal := v_items_subtotal + NEW.delivery_cost;
    discount := 0;
    IF NEW.coupon_code IS NOT NULL AND trim(NEW.coupon_code) <> '' THEN
      discount := public.apply_coupon_to_order(NEW.coupon_code, subtotal);
    END IF;
    NEW.discount_amount := discount;
    NEW.total := subtotal - discount;

    IF NEW.fulfillment_type = 'pickup' THEN
      NEW.deposit_amount := ROUND(NEW.total * 0.5);
      NEW.deposit_status := 'pending';
      NEW.payment_status := 'waiting_review';
    ELSIF NEW.payment_method = 'cod' THEN
      NEW.payment_status := 'pending';
    ELSIF NEW.payment_method IN ('cib', 'dahabia') THEN
      NEW.payment_status := 'pending';
    ELSE
      NEW.payment_status := 'waiting_review';
    END IF;
    NEW.status := 'new';
    IF NEW.ref IS NULL OR NEW.ref = '' THEN NEW.ref := public.generate_order_ref(); END IF;
    RETURN NEW;
  END IF;

  -- ── existing single-item path, unchanged ──
  IF NEW.qty IS NULL OR NEW.qty < 1 THEN NEW.qty := 1; END IF;
  IF NEW.qty > 20 THEN NEW.qty := 20; END IF;

  IF NEW.payment_method = 'pickup' THEN
    NEW.fulfillment_type := 'pickup';
  END IF;

  SELECT * INTO prod FROM public.products WHERE id = NEW.product_id AND active = true AND deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'invalid or inactive product';
  END IF;
  NEW.product_price := prod.price;
  NEW.product_name := COALESCE(NULLIF(NEW.product_name,''), prod.name_ar);
  NEW.product_emoji := COALESCE(prod.emoji, '🌹');
  NEW.product_sku := prod.sku;

  SELECT value INTO enabled_methods FROM public.settings WHERE key = 'pay_methods';
  IF enabled_methods IS NOT NULL AND NEW.payment_method IS NOT NULL
     AND NOT (enabled_methods ? NEW.payment_method) AND NEW.payment_method <> 'cod' THEN
    RAISE EXCEPTION 'this payment method is not currently available';
  END IF;

  IF NEW.fulfillment_type = 'pickup' THEN
    NEW.delivery_cost := 0;
  ELSE
    NEW.fulfillment_type := 'delivery';
    SELECT * INTO dres FROM public.resolve_delivery(NEW.wilaya_id, NEW.commune);
    NEW.wilaya := dres.wilaya_name;
    NEW.delivery_cost := dres.delivery_cost;
  END IF;

  subtotal := NEW.product_price * NEW.qty + NEW.delivery_cost;

  discount := 0;
  IF NEW.coupon_code IS NOT NULL AND trim(NEW.coupon_code) <> '' THEN
    discount := public.apply_coupon_to_order(NEW.coupon_code, subtotal);
  END IF;
  NEW.discount_amount := discount;
  NEW.total := subtotal - discount;

  IF NEW.fulfillment_type = 'pickup' THEN
    NEW.deposit_amount := ROUND(NEW.total * 0.5);
    NEW.deposit_status := 'pending';
    NEW.payment_status := 'waiting_review';
  ELSIF NEW.payment_method = 'cod' THEN
    NEW.payment_status := 'pending';
  ELSIF NEW.payment_method IN ('cib', 'dahabia') THEN
    NEW.payment_status := 'pending';
  ELSE
    NEW.payment_status := 'waiting_review';
  END IF;
  NEW.status := 'new';

  IF NEW.ref IS NULL OR NEW.ref = '' THEN NEW.ref := public.generate_order_ref(); END IF;

  RETURN NEW;
END;
$$;

-- ✅ create_cart_order: validates every item's product server-side
-- (active, not deleted, real price — never a client-submitted price),
-- writes order_items, then inserts the orders header row which the
-- trigger above finalizes using the trusted order_items sum.
create or replace function public.create_cart_order(
  p_id text,
  p_items jsonb,
  p_name text,
  p_phone text,
  p_wilaya_id integer,
  p_commune text,
  p_address text,
  p_payment_method text,
  p_fulfillment_type text,
  p_note text,
  p_lang text,
  p_email text,
  p_coupon_code text,
  p_client_ref text
)
returns table (
  id text, ref text, receipt_token text, total integer, delivery_cost integer,
  deposit_amount integer, payment_status text, status text, fulfillment_type text,
  wilaya text, item_count integer
)
language plpgsql
security definer
set search_path to 'public'
as $$
DECLARE
  item jsonb;
  prod RECORD;
  qty integer;
  n_items integer := 0;
BEGIN
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'cart is empty';
  END IF;
  IF jsonb_array_length(p_items) > 30 THEN
    RAISE EXCEPTION 'too many distinct items';
  END IF;

  FOR item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    SELECT * INTO prod FROM public.products AS pr
      WHERE pr.id = (item->>'product_id') AND pr.active = true AND pr.deleted_at IS NULL;
    IF NOT FOUND THEN CONTINUE; END IF;

    qty := COALESCE((item->>'qty')::integer, 1);
    IF qty < 1 THEN qty := 1; END IF;
    IF qty > 20 THEN qty := 20; END IF;

    INSERT INTO public.order_items (order_id, product_id, product_name, product_sku, product_price, qty, subtotal)
    VALUES (p_id, prod.id, prod.name_ar, prod.sku, prod.price, qty, prod.price * qty);
    n_items := n_items + 1;
  END LOOP;

  IF n_items = 0 THEN
    RAISE EXCEPTION 'no valid products in cart';
  END IF;

  INSERT INTO public.orders (
    id, name, phone, wilaya_id, commune, address, payment_method, fulfillment_type,
    note, lang, email, coupon_code, client_ref, is_multi_item, created_at
  ) VALUES (
    p_id, p_name, p_phone, p_wilaya_id, NULLIF(p_commune,''), NULLIF(p_address,''),
    p_payment_method, p_fulfillment_type, NULLIF(p_note,''), p_lang, NULLIF(p_email,''),
    NULLIF(p_coupon_code,''), p_client_ref, true, now()
  );

  RETURN QUERY
  SELECT o.id, o.ref, o.receipt_token, o.total, o.delivery_cost, o.deposit_amount,
         o.payment_status, o.status, o.fulfillment_type, o.wilaya, n_items
  FROM public.orders o WHERE o.id = p_id;
END;
$$;

revoke all on function public.create_cart_order(
  text, jsonb, text, text, integer, text, text, text, text, text, text, text, text, text
) from public;
grant execute on function public.create_cart_order(
  text, jsonb, text, text, integer, text, text, text, text, text, text, text, text, text
) to anon, authenticated;

-- ✅ token-gated read of a multi-item order's line items, mirroring
-- get_order_by_token's trust model exactly
create or replace function public.get_order_items_by_token(p_id text, p_token text)
returns setof public.order_items
language sql
security definer
stable
set search_path to 'public'
as $$
  select oi.* from public.order_items oi
  join public.orders o on o.id = oi.order_id
  where oi.order_id = p_id
    and o.receipt_token is not null
    and o.receipt_token = p_token
  order by oi.created_at;
$$;

revoke all on function public.get_order_items_by_token(text, text) from public;
grant execute on function public.get_order_items_by_token(text, text) to anon, authenticated;

create or replace function public.orders_guard_anon_update()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
BEGIN
  IF auth.role() = 'service_role' THEN RETURN NEW; END IF;
  IF auth.uid() IS NOT NULL AND EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN NEW;
  END IF;

  NEW.name := OLD.name;
  NEW.phone := OLD.phone;
  NEW.wilaya := OLD.wilaya;
  NEW.wilaya_id := OLD.wilaya_id;
  NEW.commune := OLD.commune;
  NEW.address := OLD.address;
  NEW.delivery_cost := OLD.delivery_cost;
  NEW.product_id := OLD.product_id;
  NEW.product_name := OLD.product_name;
  NEW.product_price := OLD.product_price;
  NEW.product_sku := OLD.product_sku;
  NEW.is_multi_item := OLD.is_multi_item;
  NEW.qty := OLD.qty;
  NEW.total := OLD.total;
  NEW.payment_method := OLD.payment_method;
  NEW.fulfillment_type := OLD.fulfillment_type;
  NEW.deposit_amount := OLD.deposit_amount;
  NEW.deposit_status := OLD.deposit_status;
  NEW.status := OLD.status;
  NEW.ref := OLD.ref;
  NEW.receipt_token := OLD.receipt_token;

  IF OLD.payment_status = 'paid' THEN
    RAISE EXCEPTION 'order already finalized';
  END IF;

  IF NEW.payment_status IS DISTINCT FROM OLD.payment_status
     AND NEW.payment_status NOT IN ('waiting_review','waiting_slickpay') THEN
    NEW.payment_status := OLD.payment_status;
  END IF;

  RETURN NEW;
END;
$$;

commit;
