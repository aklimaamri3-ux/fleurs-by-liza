delete from public.orders where name='UI Coupon Test';
update public.settings set value='[]'::jsonb where key='promos';
