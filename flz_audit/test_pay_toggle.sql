SET LOCAL request.jwt.claims = '{"role":"service_role"}';
update public.settings set value = '["ccp","iban","binance","redotpay"]'::jsonb where key='pay_methods';
select value from public.settings where key='pay_methods';
