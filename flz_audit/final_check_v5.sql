select count(*) as stray_test_data from public.orders where name ilike '%test%' or name ilike '%regress%' or name ilike '%dup%' or name ilike '%debug%';
