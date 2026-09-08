CREATE OR REPLACE FUNCTION public.get_public_setting(k text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if k not in (
    'announcement','social','reviews',
    'pay_methods','promos','currency','promo_bar','prod_promos','seo'
  ) then
    return null;
  end if;
  return (select value from public.settings where key = k limit 1);
end;
$function$;
