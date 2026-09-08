insert into public.products (id,name_ar,price,active) values ('TRASHCYCLE','Trash Cycle Test',5000,true);
update public.products set deleted_at=now() where id='TRASHCYCLE';
