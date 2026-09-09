-- Every product gets a stable, unique reference (FBL-BQ-0001 style),
-- generated server-side and never reassigned once set. Orders snapshot
-- the product's sku at order time (product_sku), mirroring the existing
-- product_name/product_price snapshot pattern, so invoices/admin show a
-- stable reference even if a product is later renamed or removed.

begin;

create sequence if not exists public.products_sku_seq start 1;

alter table public.products add column if not exists sku text;

-- backfill existing products in creation order
with numbered as (
  select id, row_number() over (order by created_at) as rn
  from public.products
  where sku is null
)
update public.products p
set sku = 'FBL-BQ-' || lpad(numbered.rn::text, 4, '0')
from numbered
where p.id = numbered.id;

-- keep the sequence ahead of whatever we just backfilled
select setval('public.products_sku_seq', greatest(1, (select count(*) from public.products)), true);

alter table public.products alter column sku set not null;
create unique index if not exists products_sku_uidx on public.products (sku);

create or replace function public.products_assign_sku()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if NEW.sku is null or NEW.sku = '' then
    NEW.sku := 'FBL-BQ-' || lpad(nextval('public.products_sku_seq')::text, 4, '0');
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_products_assign_sku on public.products;
create trigger trg_products_assign_sku
  before insert on public.products
  for each row execute function public.products_assign_sku();

-- orders snapshot the product's sku at order time, same pattern as
-- product_name/product_price
alter table public.orders add column if not exists product_sku text;

create or replace function public.orders_secure_insert()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
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
    IF NEW.product_sku IS NULL AND NEW.product_id IS NOT NULL THEN
      SELECT sku INTO NEW.product_sku FROM public.products WHERE id = NEW.product_id;
    END IF;
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
