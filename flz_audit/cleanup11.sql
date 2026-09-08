delete from public.orders where id in ('COUPONTEST1','COUPONTEST2');
update public.settings set value='[]'::jsonb where key='promos';
