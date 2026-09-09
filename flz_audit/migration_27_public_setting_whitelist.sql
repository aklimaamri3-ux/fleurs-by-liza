-- get_public_setting() (used by receipt.html/checkout.html/product.html
-- via the RPC path) never had feature_flags or business_hours added to
-- its whitelist, even though the direct-table RLS policy already
-- allows both — pages using the RPC path silently got null for these
-- keys.

begin;

create or replace function public.get_public_setting(k text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
begin
  if k not in (
    'announcement','social','reviews',
    'pay_methods','promos','currency','promo_bar','prod_promos','seo',
    'pickup_deposit','payment_methods_v2','business_hours','feature_flags'
  ) then
    return null;
  end if;
  return (select value from public.settings where key = k limit 1);
end;
$$;

commit;
