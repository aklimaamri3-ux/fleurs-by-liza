select id, receipt_token from public.orders where payment_status='paid' order by created_at desc limit 1;
