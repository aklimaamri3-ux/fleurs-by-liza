-- Wire feature flags into the RPCs that actually do work server-side —
-- not just hiding a button. Each check fails closed with a clear
-- message the client can show, before any DB mutation happens.

begin;

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
  IF NOT public.is_feature_enabled('cart') THEN
    RAISE EXCEPTION 'cart is currently disabled';
  END IF;

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

create or replace function public.validate_coupon(p_code text, p_subtotal integer)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
DECLARE
  promos jsonb;
  c jsonb;
  discount integer;
BEGIN
  IF NOT public.is_feature_enabled('promotions') THEN
    RETURN jsonb_build_object('valid', false, 'error', 'disabled');
  END IF;
  IF p_code IS NULL OR trim(p_code) = '' THEN
    RETURN jsonb_build_object('valid', false, 'error', 'no_code');
  END IF;
  SELECT value INTO promos FROM public.settings WHERE key = 'promos';
  IF promos IS NULL THEN
    RETURN jsonb_build_object('valid', false, 'error', 'not_found');
  END IF;
  SELECT p INTO c FROM jsonb_array_elements(promos) p
    WHERE upper(p->>'code') = upper(trim(p_code)) LIMIT 1;
  IF c IS NULL THEN
    RETURN jsonb_build_object('valid', false, 'error', 'not_found');
  END IF;
  IF (c->>'active') = 'false' THEN
    RETURN jsonb_build_object('valid', false, 'error', 'inactive');
  END IF;
  IF (c->>'start_date') IS NOT NULL AND (c->>'start_date') <> ''
     AND now()::date < (c->>'start_date')::date THEN
    RETURN jsonb_build_object('valid', false, 'error', 'not_started');
  END IF;
  IF (c->>'end_date') IS NOT NULL AND (c->>'end_date') <> ''
     AND now()::date > (c->>'end_date')::date THEN
    RETURN jsonb_build_object('valid', false, 'error', 'expired');
  END IF;
  IF (c->>'min_order') IS NOT NULL AND (c->>'min_order') <> ''
     AND p_subtotal < (c->>'min_order')::integer THEN
    RETURN jsonb_build_object('valid', false, 'error', 'below_minimum', 'min_order', (c->>'min_order')::integer);
  END IF;
  IF (c->>'max_use') IS NOT NULL AND (c->>'max_use') <> ''
     AND COALESCE((c->>'used')::int, 0) >= (c->>'max_use')::int THEN
    RETURN jsonb_build_object('valid', false, 'error', 'exhausted');
  END IF;
  discount := CASE WHEN (c->>'type') = 'percent'
    THEN ROUND(p_subtotal * (c->>'value')::numeric / 100)
    ELSE (c->>'value')::int
  END;
  discount := LEAST(GREATEST(discount, 0), p_subtotal);
  RETURN jsonb_build_object('valid', true, 'discount', discount, 'type', c->>'type', 'value', c->>'value');
END;
$$;

create or replace function public.apply_coupon_to_order(p_code text, p_subtotal integer)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
DECLARE
  promos jsonb;
  idx integer;
  c jsonb;
  discount integer := 0;
  new_promos jsonb;
BEGIN
  IF NOT public.is_feature_enabled('promotions') THEN RETURN 0; END IF;
  IF p_code IS NULL OR trim(p_code) = '' THEN RETURN 0; END IF;
  SELECT value INTO promos FROM public.settings WHERE key = 'promos';
  IF promos IS NULL THEN RETURN 0; END IF;

  SELECT ord.idx - 1 INTO idx
  FROM jsonb_array_elements(promos) WITH ORDINALITY AS ord(val, idx)
  WHERE upper(ord.val->>'code') = upper(trim(p_code)) LIMIT 1;
  IF idx IS NULL THEN RETURN 0; END IF;

  c := promos->idx;
  IF (c->>'active') = 'false' THEN RETURN 0; END IF;
  IF (c->>'start_date') IS NOT NULL AND (c->>'start_date') <> ''
     AND now()::date < (c->>'start_date')::date THEN RETURN 0; END IF;
  IF (c->>'end_date') IS NOT NULL AND (c->>'end_date') <> ''
     AND now()::date > (c->>'end_date')::date THEN RETURN 0; END IF;
  IF (c->>'min_order') IS NOT NULL AND (c->>'min_order') <> ''
     AND p_subtotal < (c->>'min_order')::integer THEN RETURN 0; END IF;
  IF (c->>'max_use') IS NOT NULL AND (c->>'max_use') <> ''
     AND COALESCE((c->>'used')::int, 0) >= (c->>'max_use')::int THEN RETURN 0; END IF;

  discount := CASE WHEN (c->>'type') = 'percent'
    THEN ROUND(p_subtotal * (c->>'value')::numeric / 100)
    ELSE (c->>'value')::int
  END;
  discount := LEAST(GREATEST(discount, 0), p_subtotal);

  new_promos := jsonb_set(promos, ARRAY[idx::text, 'used'], to_jsonb(COALESCE((c->>'used')::int, 0) + 1));
  UPDATE public.settings SET value = new_promos, updated_at = now() WHERE key = 'promos';

  RETURN discount;
END;
$$;

create or replace function public.submit_review(
  p_order_id text, p_token text, p_rating integer, p_text text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
DECLARE
  ord RECORD;
BEGIN
  IF NOT public.is_feature_enabled('reviews') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'disabled');
  END IF;

  SELECT id, status, receipt_token, product_id, name INTO ord
  FROM public.orders WHERE id = p_order_id;

  IF ord.id IS NULL OR ord.receipt_token IS NULL OR ord.receipt_token <> p_token THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;
  IF ord.status <> 'delivered' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_delivered');
  END IF;
  IF EXISTS (SELECT 1 FROM public.reviews WHERE order_id = p_order_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_reviewed');
  END IF;
  IF p_rating IS NULL OR p_rating < 1 OR p_rating > 5 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_rating');
  END IF;

  INSERT INTO public.reviews (order_id, product_id, customer_name, rating, review_text, approved)
  VALUES (p_order_id, ord.product_id, ord.name, p_rating, NULLIF(trim(COALESCE(p_text,'')),''), false);

  RETURN jsonb_build_object('ok', true);
END;
$$;

commit;
