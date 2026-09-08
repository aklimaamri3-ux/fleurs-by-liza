-- Public settings key for the new structured payment-methods config,
-- and lock delivery_prices reads down to active areas only.

DROP POLICY IF EXISTS settings_public_read ON public.settings;
CREATE POLICY settings_public_read ON public.settings
  FOR SELECT TO anon
  USING (key = ANY (ARRAY[
    'pay_methods','announcement','social','reviews','promo_bar',
    'promos','prod_promos','currency','seo','pickup_deposit','payment_methods_v2'
  ]));

CREATE OR REPLACE FUNCTION public.get_public_setting(k text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if k not in (
    'announcement','social','reviews',
    'pay_methods','promos','currency','promo_bar','prod_promos','seo',
    'pickup_deposit','payment_methods_v2'
  ) then
    return null;
  end if;
  return (select value from public.settings where key = k limit 1);
end;
$function$;

-- Disabled wilayas should never even be visible to the public, not just
-- unselectable client-side.
DROP POLICY IF EXISTS delivery_anon_read ON public.delivery_prices;
CREATE POLICY delivery_anon_read ON public.delivery_prices
  FOR SELECT TO anon
  USING (active = true);
