-- Real, server-enforced feature flags — not just CSS hiding. A single
-- settings.feature_flags JSONB, public-readable (so the customer UI
-- knows what to show), admin-writable only. is_feature_enabled() is
-- called from inside the actual RPCs/trigger paths that cost money or
-- touch third-party services, so disabling a feature here blocks it
-- even via a direct API call, not just in the UI. Safe defaults: a
-- missing/malformed flag always defaults to enabled, so the site never
-- breaks if this setting is absent or a new flag hasn't been added yet.
--
-- Payment methods (COD/CIB/bank transfer/pickup) already have a real
-- enable/disable via settings.pay_methods + the admin payToggles UI —
-- not duplicated here. Business hours already has its own enabled flag
-- (migration_17) — not duplicated here. Currency display already has
-- settings.currency.show_eur — not duplicated here. Stock/inventory is
-- intentionally absent — the shop doesn't use it and it must not be
-- reintroduced under any name, including as a feature flag.

begin;

insert into public.settings (key, value, updated_at)
values ('feature_flags', jsonb_build_object(
  'cart', true, 'wishlist', true, 'promotions', true, 'ads', true,
  'reviews', true, 'occasions', true, 'telegram_notifications', true,
  'email_notifications', true, 'whatsapp_actions', true, 'yalidine', true,
  'delivery_proof', true, 'tracking', true, 'invoice', true, 'search', true
), now())
on conflict (key) do nothing;

drop policy if exists settings_public_read on public.settings;
create policy settings_public_read on public.settings for select to anon
using (key = any (array[
  'pay_methods','announcement','social','reviews','promo_bar','promos',
  'prod_promos','currency','seo','pickup_deposit','payment_methods_v2',
  'business_hours','feature_flags'
]));

create or replace function public.is_feature_enabled(p_key text)
returns boolean
language plpgsql
stable
security definer
set search_path to 'public'
as $$
DECLARE
  flags jsonb;
BEGIN
  SELECT value INTO flags FROM public.settings WHERE key = 'feature_flags';
  IF flags IS NULL OR NOT (flags ? p_key) THEN RETURN true; END IF;
  RETURN COALESCE((flags->>p_key)::boolean, true);
END;
$$;
revoke all on function public.is_feature_enabled(text) from public;
grant execute on function public.is_feature_enabled(text) to anon, authenticated;

commit;
