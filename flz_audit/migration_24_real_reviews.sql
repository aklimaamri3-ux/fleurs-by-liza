-- Real customer reviews. The existing admin.html "Reviews" page only
-- lets the admin type in a fabricated name/rating/text with zero link
-- to any actual order — kept as-is (an admin may legitimately transcribe
-- a review sent via WhatsApp), but a genuine pipeline never existed:
-- customers can only review their own delivered order, once, and every
-- submission needs admin approval before it's shown publicly.

begin;

create table if not exists public.reviews (
  id uuid primary key default gen_random_uuid(),
  order_id text not null references public.orders(id) on delete cascade,
  product_id text,
  customer_name text not null,
  rating integer not null check (rating between 1 and 5),
  review_text text,
  approved boolean not null default false,
  created_at timestamptz not null default now(),
  deleted_at timestamptz,
  unique (order_id)
);

alter table public.reviews enable row level security;
drop policy if exists reviews_anon_read on public.reviews;
create policy reviews_anon_read on public.reviews for select to public
using (approved = true and deleted_at is null);
drop policy if exists reviews_admin_all on public.reviews;
create policy reviews_admin_all on public.reviews for all to public
using (is_admin()) with check (is_admin());
-- ✅ no anon INSERT policy at all — only submit_review() (SECURITY
-- DEFINER, validates delivery + token + one-per-order) can ever create one.

create or replace function public.submit_review(
  p_order_id text, p_token text, p_rating integer, p_text text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
DECLARE
  ord RECORD;
BEGIN
  SELECT id, status, receipt_token, product_id, name INTO ord
  FROM public.orders WHERE id = p_order_id;

  IF ord.id IS NULL OR ord.receipt_token IS NULL OR ord.receipt_token <> p_token THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;
  IF ord.status <> 'delivered' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_delivered');
  END IF;
  IF EXISTS (SELECT 1 FROM public.reviews WHERE order_id = p_order_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_reviewed');
  END IF;
  IF p_rating IS NULL OR p_rating < 1 OR p_rating > 5 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_rating');
  END IF;

  INSERT INTO public.reviews (order_id, product_id, customer_name, rating, review_text, approved)
  VALUES (p_order_id, ord.product_id, ord.name, p_rating, NULLIF(trim(COALESCE(p_text,'')),''), false);

  RETURN jsonb_build_object('ok', true);
END;
$$;

revoke all on function public.submit_review(text, text, integer, text) from public;
grant execute on function public.submit_review(text, text, integer, text) to anon, authenticated;

-- ✅ can the customer see whether they already reviewed this order?
-- (used to hide the form after submission, even on a later visit)
create or replace function public.get_review_status(p_order_id text, p_token text)
returns jsonb
language plpgsql
security definer
stable
set search_path to 'public'
as $$
DECLARE
  ord RECORD;
BEGIN
  SELECT id, status, receipt_token INTO ord FROM public.orders WHERE id = p_order_id;
  IF ord.id IS NULL OR ord.receipt_token IS NULL OR ord.receipt_token <> p_token OR ord.status <> 'delivered' THEN
    RETURN jsonb_build_object('eligible', false);
  END IF;
  IF EXISTS (SELECT 1 FROM public.reviews WHERE order_id = p_order_id) THEN
    RETURN jsonb_build_object('eligible', true, 'already_reviewed', true);
  END IF;
  RETURN jsonb_build_object('eligible', true, 'already_reviewed', false);
END;
$$;
revoke all on function public.get_review_status(text, text) from public;
grant execute on function public.get_review_status(text, text) to anon, authenticated;

commit;
