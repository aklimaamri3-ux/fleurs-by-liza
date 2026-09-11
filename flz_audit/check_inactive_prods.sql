select id, name_ar, active from public.products where active=false and deleted_at is null limit 3;
