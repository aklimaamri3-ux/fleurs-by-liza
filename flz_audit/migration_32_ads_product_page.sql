-- Ads on product.html: the feature never existed there at all (only
-- index.html has loadAds()/#adsTop) — "ads not showing on
-- product.html" was a missing feature, not a broken one. Adds:
--   1. An optional product_id link so an ad can be scoped to one
--      specific product's page instead of showing on every product
--      page (admin form gets an optional "ربط بمنتج" select).
--   2. product.html gets its own loadAds()/#adsTop wiring, filtered
--      to placement='product_top' and (product_id is null OR matches
--      the current product) — same active/date-range/deleted_at
--      gating as index.html, already enforced by the existing RLS
--      policy (unchanged, no placement/product_id restriction there).

begin;

alter table public.ads
  add column if not exists product_id text references public.products(id) on delete set null;

commit;
