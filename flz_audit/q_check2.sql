select id,name,total,fulfillment_type,deposit_amount,payment_status,receipt_url from public.orders where name in ('Test Customer','Pickup Tester') order by created_at desc;
