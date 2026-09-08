select o.id,o.total,o.payment_status,(select count(*) from order_events e where e.order_id=o.id) as event_count from public.orders o where o.name='Final Regression COD';
