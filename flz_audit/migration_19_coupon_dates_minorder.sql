-- Promotions hardening: coupons gain start_date/end_date/min_order,
-- enforced server-side in BOTH validate_coupon (live feedback) and
-- apply_coupon_to_order (the authoritative apply inside the order
-- trigger) — client-submitted discount amounts are never trusted,
-- and an expired/not-yet-started/below-minimum/disabled coupon can
-- never produce a discount regardless of what the client claims.

begin;

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

commit;
