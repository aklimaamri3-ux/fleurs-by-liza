-- Add yalidine_tracking to track_order's return set — not sensitive (it's
-- meant to be given to the customer anyway), satisfies "show shipment
-- number in customer tracking". Everything else about this RPC (rate
-- limiting, phone matching, no PII) is preserved unchanged.

begin;

drop function if exists public.track_order(text);

create or replace function public.track_order(p_phone text)
returns table(ref text, product text, status text, created_at timestamptz, yalidine_tracking text)
language plpgsql
security definer
set search_path to 'public'
as $$
DECLARE
  clean text;
  rec   record;
BEGIN
  clean := regexp_replace(COALESCE(p_phone,''), '[^0-9]', '', 'g');

  IF length(clean) < 9 OR length(clean) > 15 THEN
    RETURN;
  END IF;

  SELECT * INTO rec FROM public.track_attempts WHERE phone = clean;

  IF FOUND THEN
    IF rec.window_start > now() - interval '1 hour' THEN
      IF rec.attempts >= 5 THEN
        RETURN;
      END IF;
      UPDATE public.track_attempts
         SET attempts = attempts + 1
       WHERE phone = clean;
    ELSE
      UPDATE public.track_attempts
         SET attempts = 1, window_start = now()
       WHERE phone = clean;
    END IF;
  ELSE
    INSERT INTO public.track_attempts (phone) VALUES (clean);
  END IF;

  IF random() < 0.05 THEN
    DELETE FROM public.track_attempts
     WHERE window_start < now() - interval '2 hours';
  END IF;

  RETURN QUERY
  SELECT
    o.ref,
    COALESCE(o.product_name, '') AS product,
    o.status,
    o.created_at,
    o.yalidine_tracking
  FROM public.orders o
  WHERE regexp_replace(COALESCE(o.phone,''), '[^0-9]', '', 'g') = clean
     OR regexp_replace(COALESCE(o.phone,''), '[^0-9]', '', 'g')
        = '213' || substring(clean from 2)
     OR '213' || substring(regexp_replace(COALESCE(o.phone,''), '[^0-9]', '', 'g') from 2)
        = clean
  ORDER BY o.created_at DESC
  LIMIT 5;
END;
$$;

commit;
