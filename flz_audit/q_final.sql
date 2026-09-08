select id,name,payment_method,fulfillment_type,delivery_cost,total,deposit_amount,deposit_status,payment_status from public.orders where name in ('COD Test','Pickup Test2') order by created_at desc;
