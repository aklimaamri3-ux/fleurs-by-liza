-- Receipts auto-expiry: delete the actual uploaded receipt image from
-- the private 'receipts' bucket 30 days after upload, via the new
-- cron_purge_receipts Edge Function action (same CRON_SECRET pattern,
-- same Vault secret, as the daily report). Only the storage object
-- and orders.receipt_url are touched — the order row itself is never
-- deleted or otherwise modified.

begin;

create or replace function public.purge_expired_receipts_job()
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
DECLARE
  secret text;
BEGIN
  SELECT decrypted_secret INTO secret FROM vault.decrypted_secrets WHERE name = 'cron_secret' LIMIT 1;
  IF secret IS NULL THEN
    RAISE EXCEPTION 'cron_secret not found in vault';
  END IF;
  PERFORM net.http_post(
    url := 'https://lgpllhbabctsdplqapzi.supabase.co/functions/v1/hyper-action',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'X-Cron-Secret', secret
    ),
    body := jsonb_build_object('action', 'cron_purge_receipts')
  );
END;
$$;

select cron.schedule(
  'purge-expired-receipts',
  '30 3 * * *', -- 03:30 UTC daily, right after the existing trash purge at 03:00
  $$select public.purge_expired_receipts_job();$$
);

commit;
