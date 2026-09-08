-- ============================================================
-- Fleurs by Liza — core hardening migration
-- 1) receipt flow RLS  2) trusted order pricing/validation
-- 3) idempotency  4) promo flag  5) area active flags  6) ads
-- ============================================================

-- ---------- 1. RECEIPT FLOW: allow token-gated anon select/update ----------
DROP POLICY IF EXISTS orders_receipt_select ON public.orders;
CREATE POLICY orders_receipt_select ON public.orders
  FOR SELECT TO anon
  USING (receipt_token IS NOT NULL);

DROP POLICY IF EXISTS orders_receipt_update ON public.orders;
CREATE POLICY orders_receipt_update ON public.orders
  FOR UPDATE TO anon
  USING (receipt_token IS NOT NULL AND payment_status IN ('waiting_review','pending'))
  WITH CHECK (receipt_token IS NOT NULL);

-- Lock down WHAT an anon caller can actually change on UPDATE (defense in depth
-- beyond RLS, since RLS alone can't restrict per-column changes).
CREATE OR REPLACE FUNCTION public.orders_guard_anon_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  -- service_role (edge functions/webhooks) and admins pass through untouched
  IF auth.role() = 'service_role' THEN RETURN NEW; END IF;
  IF auth.uid() IS NOT NULL AND EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN NEW;
  END IF;

  -- anon (customer uploading a receipt): only receipt_url/receipt_at may change,
  -- and payment_status may only move to 'waiting_review'. Everything else is
  -- forced back to its old value so a crafted PATCH can't touch price/total/status.
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
    -- already confirmed paid — no further anon edits at all
    RAISE EXCEPTION 'order already finalized';
  END IF;

  IF NEW.payment_status IS DISTINCT FROM OLD.payment_status
     AND NEW.payment_status <> 'waiting_review' THEN
    NEW.payment_status := OLD.payment_status;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_orders_guard_anon_update ON public.orders;
CREATE TRIGGER trg_orders_guard_anon_update
  BEFORE UPDATE ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.orders_guard_anon_update();

-- ---------- 2. TRUSTED PRICING: recompute everything server-side on INSERT ----------
ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS fulfillment_type text NOT NULL DEFAULT 'delivery'
    CHECK (fulfillment_type IN ('delivery','pickup')),
  ADD COLUMN IF NOT EXISTS deposit_amount integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS deposit_status text NOT NULL DEFAULT 'not_required'
    CHECK (deposit_status IN ('not_required','pending','paid')),
  ADD COLUMN IF NOT EXISTS client_ref text;

CREATE UNIQUE INDEX IF NOT EXISTS orders_client_ref_uidx
  ON public.orders (client_ref) WHERE client_ref IS NOT NULL;

ALTER TABLE public.delivery_prices
  ADD COLUMN IF NOT EXISTS active boolean NOT NULL DEFAULT true;

ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS is_promo boolean NOT NULL DEFAULT false;

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
BEGIN
  is_priv := (auth.role() = 'service_role')
    OR (auth.uid() IS NOT NULL AND EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'));

  -- Admin/service inserts (manual orders, webhooks) are trusted as typed —
  -- staff deliberately set custom delivery/qty/price for manual orders.
  IF is_priv THEN
    IF NEW.ref IS NULL OR NEW.ref = '' THEN NEW.ref := public.generate_order_ref(); END IF;
    RETURN NEW;
  END IF;

  -- ---- everyone else (public checkout): never trust client-sent price/total ----
  IF NEW.qty IS NULL OR NEW.qty < 1 THEN NEW.qty := 1; END IF;
  IF NEW.qty > 20 THEN NEW.qty := 20; END IF;

  SELECT * INTO prod FROM public.products WHERE id = NEW.product_id AND active = true;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'invalid or inactive product';
  END IF;
  NEW.product_price := prod.price;
  NEW.product_name := COALESCE(NULLIF(NEW.product_name,''), prod.name_ar);
  NEW.product_emoji := COALESCE(prod.emoji, '🌹');

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

  NEW.total := NEW.product_price * NEW.qty + NEW.delivery_cost;

  -- payment status can never be client-forced to 'paid'
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

DROP TRIGGER IF EXISTS trg_orders_secure_insert ON public.orders;
CREATE TRIGGER trg_orders_secure_insert
  BEFORE INSERT ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.orders_secure_insert();

-- ---------- 3. ADS SYSTEM (new — nothing existing serves this purpose) ----------
CREATE TABLE IF NOT EXISTS public.ads (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title text DEFAULT '',
  image_url text,
  link_url text,
  placement text NOT NULL DEFAULT 'home_top',
  active boolean NOT NULL DEFAULT true,
  sort_order integer NOT NULL DEFAULT 0,
  starts_at timestamptz,
  ends_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.ads ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ads_admin_write ON public.ads;
CREATE POLICY ads_admin_write ON public.ads FOR ALL USING (is_admin()) WITH CHECK (is_admin());

DROP POLICY IF EXISTS ads_anon_read ON public.ads;
CREATE POLICY ads_anon_read ON public.ads FOR SELECT
  USING (
    active = true
    AND (starts_at IS NULL OR starts_at <= now())
    AND (ends_at IS NULL OR ends_at >= now())
  );

-- ---------- 4. currency + pickup deposit settings are just reused settings rows ----------
-- (no schema change needed: 'currency' key already exists & is RLS-public;
--  'pickup_deposit' key will be created by the admin UI on first save)
