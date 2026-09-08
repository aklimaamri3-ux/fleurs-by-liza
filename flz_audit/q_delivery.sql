select wilaya_id, wilaya_name, home_price, office_price, jsonb_array_length(communes) as n_communes from public.delivery_prices order by wilaya_id limit 5;
