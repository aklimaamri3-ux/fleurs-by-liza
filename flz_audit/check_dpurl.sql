select id, delivery_proof_url from public.orders where delivery_proof_url is not null limit 3;
