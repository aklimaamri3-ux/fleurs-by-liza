CREATE OR REPLACE FUNCTION public.orders_secure_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  prod RECORD;
  dp RECORD;
  commune_row jsonb;
  commune_price integer;
  is_priv boolean;
  enabled_methods jsonb;
  subtotal integer;
  discount integer;
BEGIN
  is_priv := (auth.role() = 'service_role')
    OR (auth.uid() IS NOT NULL AND EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'));

  IF is_priv THEN
    IF NEW.ref IS NULL OR NEW.ref = '' THEN NEW.ref := public.generate_order_ref(); END IF;
    RETURN NEW;
  END IF;

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

  SELECT value INTO enabled_methods FROM public.settings WHERE key = 'pay_methods';
  IF enabled_methods IS NOT NULL AND NEW.payment_method IS NOT NULL
     AND NOT (enabled_methods ? NEW.payment_method) AND NEW.payment_method <> 'cod' THEN
    RAISE EXCEPTION 'this payment method is not currently available';
  END IF;

  IF NEW.fulfillment_type = 'pickup' THEN
    NEW.delivery_cost := 0;
  ELSE
    NEW.fulfillment_type := 'delivery';
    IF NEW.wilaya_id IS NULL THEN
      RAISE EXCEPTION 'wilaya is required for delivery';
    END IF;
    SELECT * INTO dp FROM public.delivery_prices WHERE wilaya_id = NEW.wilaya_id AND active = true;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'invalid or disabled wilaya';
    END IF;
    NEW.wilaya := dp.wilaya_name;
    commune_price := NULL;
    IF NEW.commune IS NOT NULL AND NEW.commune <> '' THEN
      SELECT c INTO commune_row
      FROM jsonb_array_elements(COALESCE(dp.communes,'[]'::jsonb)) c
      WHERE (c->>'name') = NEW.commune
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
    NEW.delivery_cost := COALESCE(commune_price, dp.home_price, 0);
  END IF;

  subtotal := NEW.product_price * NEW.qty + NEW.delivery_cost;

  -- ✅ كوبون — يُتحقق ويُطبّق من السيرفر فقط، ويُستهلك (used++) هنا فقط
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
  ELSE
    NEW.payment_status := 'waiting_review';
  END IF;
  NEW.status := 'new';

  IF NEW.ref IS NULL OR NEW.ref = '' THEN NEW.ref := public.generate_order_ref(); END IF;

  RETURN NEW;
END;
$$;
