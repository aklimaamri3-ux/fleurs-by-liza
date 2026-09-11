update public.orders
set receipt_url='https://lgpllhbabctsdplqapzi.supabase.co/storage/v1/object/public/receipts/purge_test_receipt.png',
    receipt_at=now() - interval '31 days'
where id='FBLPURGETEST1'
returning id, receipt_url, receipt_at;
