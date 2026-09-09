SET LOCAL request.jwt.claims = '{"role":"service_role"}';
delete from public.orders where name in ('Stock Test Over','Stock Test OK','Stock Test Zero','Regress NoTrack','Cart Stock Test');
delete from public.products where id='TESTSTOCKPROD';
