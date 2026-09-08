-- ============================================================
-- Trash / soft-delete for products, categories, ads.
-- Historical order data is untouched (orders store snapshots,
-- no FK to these tables), so this only affects catalog browsing.
-- ============================================================

ALTER TABLE public.products   ADD COLUMN IF NOT EXISTS deleted_at timestamptz;
ALTER TABLE public.categories ADD COLUMN IF NOT EXISTS deleted_at timestamptz;
ALTER TABLE public.ads        ADD COLUMN IF NOT EXISTS deleted_at timestamptz;

-- ✅ public reads must never see trashed rows, regardless of active/date filters
DROP POLICY IF EXISTS products_anon_read ON public.products;
CREATE POLICY products_anon_read ON public.products
  FOR SELECT USING (deleted_at IS NULL);

DROP POLICY IF EXISTS categories_anon_read ON public.categories;
CREATE POLICY categories_anon_read ON public.categories
  FOR SELECT USING (deleted_at IS NULL);

DROP POLICY IF EXISTS ads_anon_read ON public.ads;
CREATE POLICY ads_anon_read ON public.ads
  FOR SELECT
  USING (
    deleted_at IS NULL
    AND active = true
    AND (starts_at IS NULL OR starts_at <= now())
    AND (ends_at IS NULL OR ends_at >= now())
  );
-- (admin policies already grant is_admin() unrestricted access to every
--  row including trashed ones, via the existing *_admin_write policies)

-- ✅ purge anything trashed more than 20 days ago — admin-only via RLS,
-- but this function itself runs with elevated rights so pg_cron can call it.
CREATE OR REPLACE FUNCTION public.purge_expired_trash()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  DELETE FROM public.products   WHERE deleted_at IS NOT NULL AND deleted_at < now() - interval '20 days';
  DELETE FROM public.categories WHERE deleted_at IS NOT NULL AND deleted_at < now() - interval '20 days';
  DELETE FROM public.ads        WHERE deleted_at IS NOT NULL AND deleted_at < now() - interval '20 days';
END;
$$;

-- ✅ server-side daily schedule — does not depend on anyone opening the site
SELECT cron.unschedule('purge-trash-daily') WHERE EXISTS (
  SELECT 1 FROM cron.job WHERE jobname = 'purge-trash-daily'
);
SELECT cron.schedule('purge-trash-daily', '0 3 * * *', $$SELECT public.purge_expired_trash();$$);
