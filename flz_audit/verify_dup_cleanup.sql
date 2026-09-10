select count(*) from public.orders where name ilike '%test%' or name ilike '%dup%' or name ilike '%debug%';
