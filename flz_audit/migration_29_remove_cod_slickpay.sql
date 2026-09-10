-- Owner instruction: remove COD ("الدفع عند الاستلام") and the SlickPay
-- card methods (CIB, Dahabia) completely. Removing them from the
-- frontend alone would be cosmetic only — orders_secure_insert always
-- bypassed the enabled_methods allow-list for 'cod' ("COD is always
-- available"), so a raw API call could still create a COD order even
-- with no COD button anywhere in the UI. This migration makes the
-- removal real, server-side:
--
--   1. Drop the special-case COD bypass in orders_secure_insert (both
--      the single-item and multi-item/cart branches) so 'cod' is now
--      subject to the same enabled_methods allow-list as every other
--      method.
--   2. Remove 'cib' and 'dahabia' from settings.pay_methods (the
--      allow-list) so they're rejected the same way. 'cod' was never
--      in this list to begin with (it didn't need to be, since it
--      bypassed the check) — removing the bypass alone is enough to
--      block it too, since it's still absent from the list.
--
-- Existing historical orders with payment_method IN ('cod','cib',
-- 'dahabia') are untouched — this only blocks NEW orders from being
-- created with these methods. The SlickPay Edge Function actions
-- (slickpay_create/check/webhook) are left in place but become
-- unreachable for new orders, since orders_secure_insert now rejects
-- cib/dahabia before any SlickPay call could ever be made.

begin;

create or replace function public.orders_secure_insert()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
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
       AND NOT (enabled_methods ? NEW.payment_method) THEN
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
     AND NOT (enabled_methods ? NEW.payment_method) THEN
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
$function$;

-- Remove the now-disallowed methods from the live allow-list. 'cod'
-- was never in this list (it didn't need to be), so nothing to remove
-- there — the bypass removal above is what blocks it.
update public.settings
set value = (
  select coalesce(jsonb_agg(v), '[]'::jsonb)
  from jsonb_array_elements_text(value) as v
  where v not in ('cib', 'dahabia', 'cod')
)
where key = 'pay_methods';

commit;
