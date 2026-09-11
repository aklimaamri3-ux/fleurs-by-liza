SET LOCAL request.jwt.claims = '{"role":"service_role"}';
update public.orders set payment_status='paid', status='shipping', yalidine_tracking='TEST-TRACK-98765' where id='FBLTRACKTEST1';
select id, payment_status, status, yalidine_tracking from public.orders where id='FBLTRACKTEST1';
