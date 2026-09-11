insert into public.ads (title, image_url, link_url, placement, product_id, active, sort_order)
values ('Test Ad Regress', 'https://lgpllhbabctsdplqapzi.supabase.co/storage/v1/object/public/products/1788723987592_xomhdfq9tw8.jpg', null, 'product_page', 'p1788723027266', true, 0)
returning id, title, product_id;
