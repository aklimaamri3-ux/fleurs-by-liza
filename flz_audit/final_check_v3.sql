select (select count(*) from public.delivery_prices) as wilayas, (select value from public.settings where key='currency') as currency;
