select public.send_daily_report_job();
select net.http_get('https://example.com') is not null as pg_net_works;
