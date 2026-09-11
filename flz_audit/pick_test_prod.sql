select id, name_ar, active from public.products where deleted_at is null order by created_at desc limit 1;
