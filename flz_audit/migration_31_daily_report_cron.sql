-- Automated daily Telegram report at 8:00 AM Algeria time (UTC+1, no
-- DST), via pg_cron + pg_net calling the Edge Function's
-- cron_daily_report action. That action is gated by a dedicated
-- CRON_SECRET (a Supabase Edge Function secret, set separately via
-- `supabase secrets set`) — never the service-role key or an admin
-- JWT, so a leak of this one value can only ever trigger a report
-- send, nothing else.
--
-- The scheduled job needs to present that same secret back to the
-- Edge Function. Managed Postgres does not allow ALTER DATABASE ...
-- SET for custom app.* settings (superuser-only), so the value is
-- stored in Supabase Vault instead — encrypted at rest, readable only
-- through vault.decrypted_secrets by a role with the right grants
-- (postgres/service-role), never exposed to anon/authenticated or the
-- frontend.

begin;

-- ⚠️ REDACTED — do not commit the real secret. The value used live must
-- match, byte-for-byte, the CRON_SECRET set via `supabase secrets set`.
-- Generate a fresh one with e.g. `node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"`,
-- set it as the Edge Function secret first, then run this with the
-- same value substituted in before applying against the real project.
select vault.create_secret(
  '<CRON_SECRET_VALUE_HERE>',
  'cron_secret',
  'Shared secret for pg_cron -> hyper-action cron_daily_report calls'
);

create or replace function public.send_daily_report_job()
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
    body := jsonb_build_object('action', 'cron_daily_report')
  );
END;
$$;

select cron.schedule(
  'daily-telegram-report',
  '0 7 * * *', -- 07:00 UTC = 08:00 Algeria time (UTC+1, no DST)
  $$select public.send_daily_report_job();$$
);

commit;
