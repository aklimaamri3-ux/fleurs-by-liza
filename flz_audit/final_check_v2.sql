select count(*) as stray_test_orders from public.orders where name ilike '%test%' or name ilike '%regress%' or name ilike 'final flag%';
