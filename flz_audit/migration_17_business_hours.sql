-- Business hours: a new public-readable settings key. Informational only —
-- does not block checkout server-side, per explicit instruction not to
-- break ordering unless the business rules already required it.

begin;

drop policy if exists settings_public_read on public.settings;
create policy settings_public_read on public.settings for select to anon
using (key = any (array[
  'pay_methods','announcement','social','reviews','promo_bar','promos',
  'prod_promos','currency','seo','pickup_deposit','payment_methods_v2',
  'business_hours'
]));

insert into public.settings (key, value, updated_at)
values ('business_hours', '{"enabled":false,"hours":{"sun":{"open":"09:00","close":"20:00","closed":false},"mon":{"open":"09:00","close":"20:00","closed":false},"tue":{"open":"09:00","close":"20:00","closed":false},"wed":{"open":"09:00","close":"20:00","closed":false},"thu":{"open":"09:00","close":"20:00","closed":false},"fri":{"open":"09:00","close":"20:00","closed":false},"sat":{"open":"09:00","close":"20:00","closed":false}}}'::jsonb, now())
on conflict (key) do nothing;

commit;
