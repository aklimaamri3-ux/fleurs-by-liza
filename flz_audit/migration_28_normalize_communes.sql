-- CRITICAL FIX: real delivery_prices.communes data is stored as plain
-- string arrays (e.g. ["أدرار","رقان",...]) for essentially every
-- wilaya, but resolve_delivery() (and the admin communes CRUD UI)
-- expect objects: {"name":..,"home_price":..,"active":..}.
--
-- Effect of the bug: calling resolve_delivery(wilaya_id, commune) for
-- ANY real commune currently raises "invalid commune for this wilaya"
-- (c->>'name' on a jsonb string scalar returns NULL, never matches),
-- meaning checkout fails for any customer who selects a commune.
--
-- Fix: normalize every plain-string commune entry into an object with
-- home_price = null (NOT 0) and active = true. NULL home_price makes
-- resolve_delivery() fall back to the wilaya's existing home_price —
-- i.e. exactly today's real, intended flat-rate behavior — while
-- unblocking checkout and enabling per-commune overrides going
-- forward via the admin UI. No commune name, wilaya price, or order
-- data is changed or removed.

begin;

update public.delivery_prices
set communes = norm.new_communes
from (
  select
    dp.wilaya_id,
    jsonb_agg(
      case
        when jsonb_typeof(elem) = 'string'
          then jsonb_build_object('name', elem #>> '{}', 'home_price', null, 'active', true)
        else elem
      end
      order by ord
    ) as new_communes
  from public.delivery_prices dp,
       jsonb_array_elements(coalesce(dp.communes, '[]'::jsonb)) with ordinality as t(elem, ord)
  where dp.communes is not null and jsonb_array_length(dp.communes) > 0
  group by dp.wilaya_id
) norm
where delivery_prices.wilaya_id = norm.wilaya_id;

-- Defense in depth: make resolve_delivery() also tolerate a plain
-- string commune element (treated as a valid commune with no price
-- override), so a future bulk import in the old format can't
-- reintroduce this class of bug.
create or replace function public.resolve_delivery(p_wilaya_id integer, p_commune text, OUT wilaya_name text, OUT delivery_cost integer)
returns record
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
    WHERE (jsonb_typeof(c) = 'object' AND (c->>'name') = p_commune)
       OR (jsonb_typeof(c) = 'string' AND (c #>> '{}') = p_commune)
    LIMIT 1;
    IF commune_row IS NULL THEN
      RAISE EXCEPTION 'invalid commune for this wilaya';
    END IF;
    IF jsonb_typeof(commune_row) = 'object' THEN
      IF (commune_row->>'active') = 'false' THEN
        RAISE EXCEPTION 'this commune is currently disabled';
      END IF;
      IF (commune_row->>'home_price') IS NOT NULL THEN
        commune_price := (commune_row->>'home_price')::integer;
      END IF;
    END IF;
  END IF;
  delivery_cost := COALESCE(commune_price, dp.home_price, 0);
END;
$$;

commit;
