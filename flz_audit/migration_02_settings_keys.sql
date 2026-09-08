-- Allow the new 'pickup_deposit' settings key to be publicly readable,
-- consistent with the other public config keys (pay_methods, currency, ...).

DROP POLICY IF EXISTS settings_public_read ON public.settings;
CREATE POLICY settings_public_read ON public.settings
  FOR SELECT TO anon
  USING (key = ANY (ARRAY[
    'pay_methods','announcement','social','reviews','promo_bar',
    'promos','prod_promos','currency','seo','pickup_deposit'
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
    'pay_methods','promos','currency','promo_bar','prod_promos','seo','pickup_deposit'
  ) then
    return null;
  end if;
  return (select value from public.settings where key = k limit 1);
end;
$function$;
