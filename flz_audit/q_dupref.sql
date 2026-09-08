select ref, count(*) from public.products where ref is not null group by ref having count(*)>1;
