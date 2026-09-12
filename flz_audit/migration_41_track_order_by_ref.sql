-- "Suivre ma commande" on index.html only ever searched by phone number,
-- even though its own placeholder text ("رقم الهاتف أو رقم الطلب") already
-- promised order-ref lookup too — the RPC never supported it, and the
-- frontend stripped dashes from the input before sending it (which would
-- have mangled a ref like FBL2026-XXXXXX into FBL2026XXXXXX anyway).
--
-- track_order(text) keeps the same single-text-argument signature (no
-- overload risk — argument name doesn't matter for Postgres function
-- resolution, only types/arity), so CREATE OR REPLACE is safe here,
-- unlike the multi-arg create_order/create_cart_order cases.

begin;

drop function if exists public.track_order(text);

create or replace function public.track_order(p_query text)
returns table(ref text, product text, status text, created_at timestamptz, yalidine_tracking text)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  raw text := trim(coalesce(p_query,''));
  clean text;
  rec record;
begin
  if raw = '' then return; end if;

  -- ✅ رقم الطلب (ref مثل FBL2026-XXXXXX أو id مثل FBL1788...) — نتيجة
  -- واحدة فقط، بلا rate limiting بالهاتف لأنه لا يكشف كل طلبات شخص ما،
  -- فقط الطلب الذي تعرف مرجعه بالضبط
  if raw ~* '^FBL[A-Za-z0-9-]+$' then
    return query
    select o.ref, coalesce(o.product_name,'') as product, o.status, o.created_at, o.yalidine_tracking
    from public.orders o
    where o.ref = raw or o.id = raw
    limit 1;
    return;
  end if;

  -- ✅ رقم الهاتف — نفس منطق rate limiting السابق بلا تغيير
  clean := regexp_replace(raw, '[^0-9]', '', 'g');

  if length(clean) < 9 or length(clean) > 15 then
    return;
  end if;

  select * into rec from public.track_attempts where phone = clean;

  if found then
    if rec.window_start > now() - interval '1 hour' then
      if rec.attempts >= 5 then
        return;
      end if;
      update public.track_attempts
         set attempts = attempts + 1
       where phone = clean;
    else
      update public.track_attempts
         set attempts = 1, window_start = now()
       where phone = clean;
    end if;
  else
    insert into public.track_attempts (phone) values (clean);
  end if;

  if random() < 0.05 then
    delete from public.track_attempts
     where window_start < now() - interval '2 hours';
  end if;

  return query
  select
    o.ref,
    coalesce(o.product_name, '') as product,
    o.status,
    o.created_at,
    o.yalidine_tracking
  from public.orders o
  where regexp_replace(coalesce(o.phone,''), '[^0-9]', '', 'g') = clean
     or regexp_replace(coalesce(o.phone,''), '[^0-9]', '', 'g')
        = '213' || substring(clean from 2)
     or '213' || substring(regexp_replace(coalesce(o.phone,''), '[^0-9]', '', 'g') from 2)
        = clean
  order by o.created_at desc
  limit 5;
end;
$function$;

commit;
