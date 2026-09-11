select column_name from information_schema.columns where table_schema='public' and table_name='orders' and column_name ilike '%gift%';
