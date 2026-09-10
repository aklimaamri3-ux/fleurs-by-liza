update public.settings set value = '["ccp","iban","binance","redotpay","pickup"]'::jsonb where key='pay_methods';
select value from public.settings where key='pay_methods';
