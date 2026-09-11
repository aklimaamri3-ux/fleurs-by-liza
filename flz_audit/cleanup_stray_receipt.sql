SET LOCAL request.jwt.claims = '{"role":"service_role"}';
delete from storage.objects where bucket_id='receipts' and name='1789168578218_c3ggnbbgd45.jpg';
select count(*) from storage.objects where bucket_id='receipts' and name='1789168578218_c3ggnbbgd45.jpg';
