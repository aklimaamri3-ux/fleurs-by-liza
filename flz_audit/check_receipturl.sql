select id, receipt_url from public.orders where receipt_url is not null and receipt_url <> '' order by created_at desc limit 5;
