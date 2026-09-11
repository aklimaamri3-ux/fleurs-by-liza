SET LOCAL request.jwt.claims = '{"role":"service_role"}';
update public.orders set amount_received=48000 where id='FBLAMTTEST1';
select id, amount_received from public.orders where id='FBLAMTTEST1';
