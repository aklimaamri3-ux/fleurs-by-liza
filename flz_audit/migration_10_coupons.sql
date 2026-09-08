-- ============================================================
-- Real, server-validated coupons. Admin already writes codes into
-- settings.promos (code/type/value/max_use/used/active) — this
-- migration makes checkout actually apply and enforce them,
-- instead of that data being decorative.
-- ============================================================

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS coupon_code text,
  ADD COLUMN IF NOT EXISTS discount_amount integer NOT NULL DEFAULT 0;

-- Public: check a coupon code against the trusted order total (does NOT
-- consume/increment usage — that only happens on a real order insert).
CREATE OR REPLACE FUNCTION public.validate_coupon(p_code text, p_subtotal integer)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  promos jsonb;
  c jsonb;
  discount integer;
BEGIN
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
  IF (c->>'max_use') IS NOT NULL AND (c->>'max_use') <> ''
     AND COALESCE((c->>'used')::int, 0) >= (c->>'max_use')::int THEN
    RETURN jsonb_build_object('valid', false, 'error', 'exhausted');
  END IF;
  discount := CASE WHEN (c->>'type') = 'percent'
    THEN ROUND(p_subtotal * (c->>'value')::numeric / 100)
    ELSE (c->>'value')::int
  END;
  discount := LEAST(discount, p_subtotal);
  RETURN jsonb_build_object('valid', true, 'discount', discount, 'type', c->>'type', 'value', c->>'value');
END;
$$;

-- Applies the coupon server-side during order creation and atomically
-- increments its usage counter — never trusts a client-sent discount.
CREATE OR REPLACE FUNCTION public.apply_coupon_to_order(p_code text, p_subtotal integer)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  promos jsonb;
  idx integer;
  c jsonb;
  discount integer := 0;
  new_promos jsonb;
BEGIN
  IF p_code IS NULL OR trim(p_code) = '' THEN RETURN 0; END IF;
  SELECT value INTO promos FROM public.settings WHERE key = 'promos';
  IF promos IS NULL THEN RETURN 0; END IF;

  SELECT ord.idx - 1 INTO idx
  FROM jsonb_array_elements(promos) WITH ORDINALITY AS ord(val, idx)
  WHERE upper(ord.val->>'code') = upper(trim(p_code)) LIMIT 1;
  IF idx IS NULL THEN RETURN 0; END IF;

  c := promos->idx;
  IF (c->>'active') = 'false' THEN RETURN 0; END IF;
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
