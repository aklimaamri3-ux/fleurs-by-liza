-- Real inventory: index.html has always checked p.in_stock === false to
-- disable ordering, but that column never existed — every product was
-- silently always orderable regardless of actual availability. Adding
-- real stock tracking, optional per product (NULL stock_qty = not
-- tracked / always available, matching current behavior for every
-- existing product so nothing breaks).

begin;

alter table public.products add column if not exists stock_qty integer;
alter table public.products add column if not exists low_stock_threshold integer default 5;
alter table public.products drop column if exists in_stock;
alter table public.products add column in_stock boolean
  generated always as (stock_qty is null or stock_qty > 0) stored;

-- ✅ server-authoritative, race-safe stock decrement. Row-level UPDATE
-- with a WHERE guard on remaining quantity serializes concurrent buyers
-- on the same product row — the second buyer's UPDATE simply matches
-- zero rows if the first already exhausted stock, and we raise instead
-- of silently overselling. Products not tracking stock (stock_qty IS
-- NULL) are untouched.
create or replace function public.decrement_stock(p_product_id text, p_qty integer)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
DECLARE
  updated_count integer;
BEGIN
  UPDATE public.products
  SET stock_qty = stock_qty - p_qty
  WHERE id = p_product_id AND stock_qty IS NOT NULL AND stock_qty >= p_qty;
  GET DIAGNOSTICS updated_count = ROW_COUNT;
  IF updated_count = 0 THEN
    -- either not tracked (fine) or genuinely insufficient stock
    IF EXISTS (SELECT 1 FROM public.products WHERE id = p_product_id AND stock_qty IS NOT NULL AND stock_qty < p_qty) THEN
      RAISE EXCEPTION 'insufficient stock for product %', p_product_id;
    END IF;
  END IF;
END;
$$;
revoke all on function public.decrement_stock(text, integer) from public;

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
  v_item RECORD;
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

  IF NEW.is_multi_item THEN
    SELECT count(*), COALESCE(sum(oi.subtotal),0), COALESCE(sum(oi.qty),0)
      INTO v_item_count, v_items_subtotal, v_items_qty
      FROM public.order_items AS oi WHERE oi.order_id = NEW.id;
    IF v_item_count = 0 THEN
      RAISE EXCEPTION 'cart order has no valid items';
    END IF;

    -- ✅ decrement stock for every line item — raises (aborting the whole
    -- order, including the already-inserted order_items, via rollback)
    -- if any item is genuinely out of stock
    FOR v_item IN SELECT product_id, qty FROM public.order_items WHERE order_id = NEW.id LOOP
      PERFORM public.decrement_stock(v_item.product_id, v_item.qty);
    END LOOP;

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

  -- ── existing single-item path ──
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

  -- ✅ raises if genuinely out of stock; no-op for untracked products
  PERFORM public.decrement_stock(NEW.product_id, NEW.qty);

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

commit;
