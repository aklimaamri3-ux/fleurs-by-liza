SET LOCAL request.jwt.claims = '{"role":"service_role"}';
update public.orders set payment_status='paid', status='shipping' where id='FBLREFTRACKTEST1';
