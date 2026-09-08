insert into public.products (id,name_ar,price,active,deleted_at) values ('TRASH_OLD','Old trashed test',1000,true, now() - interval '21 days');
insert into public.products (id,name_ar,price,active,deleted_at) values ('TRASH_RECENT','Recent trashed test',1000,true, now() - interval '1 day');
select public.purge_expired_trash();
select id from public.products where id in ('TRASH_OLD','TRASH_RECENT');
