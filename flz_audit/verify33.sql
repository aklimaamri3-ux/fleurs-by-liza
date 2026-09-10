select (select count(*) from public.products where id='p1788965123177') as prod_left, (select count(*) from public.ads where id='aa43d410-639f-4ede-9674-15245dfa5d01') as ad_left;
