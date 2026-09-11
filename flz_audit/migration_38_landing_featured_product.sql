-- Landing page featured-product setting: admin picks a product id in
-- Settings, landing.html's hero fetches and renders it. Stored as a
-- plain settings key (no new table/migration needed for the value
-- itself) but the public-read whitelist (both the RLS policy and the
-- get_public_setting() RPC) must be updated so anonymous visitors to
-- landing.html can read it.

begin;

drop policy if exists settings_public_read on public.settings;
create policy settings_public_read on public.settings for select to anon
using (key = any (array[
  'pay_methods','announcement','social','reviews','promo_bar','promos',
  'prod_promos','currency','seo','pickup_deposit','payment_methods_v2',
  'business_hours','feature_flags','landing_featured_product'
]));

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
    'pickup_deposit','payment_methods_v2','business_hours','feature_flags',
    'landing_featured_product'
  ) then
    return null;
  end if;
  return (select value from public.settings where key = k limit 1);
end;
$$;

commit;
