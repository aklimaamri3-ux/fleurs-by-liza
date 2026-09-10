select wilaya_id, wilaya_name, home_price, communes from public.delivery_prices where jsonb_array_length(coalesce(communes,'[]'::jsonb)) > 0 order by wilaya_id limit 5;
