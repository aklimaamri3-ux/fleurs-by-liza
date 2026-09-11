select id, name_ar from public.products where (media_items is null or jsonb_array_length(media_items)=0) and deleted_at is null limit 3;
