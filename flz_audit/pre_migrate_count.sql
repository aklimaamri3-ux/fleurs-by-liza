select count(*) as wilayas_with_string_communes from public.delivery_prices dp where exists (select 1 from jsonb_array_elements(coalesce(dp.communes,'[]'::jsonb)) e where jsonb_typeof(e)='string');
