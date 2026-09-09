-- Fix: orders_receipt_select / orders_receipt_update only checked that
-- receipt_token was non-null on the row, never that the caller actually
-- supplied the matching token. Any anonymous request with no filter
-- returned every order (name, phone, address, total, receipt_token).
-- Leaked tokens then also allowed updating any order via
-- orders_receipt_update. Replacing direct table access with
-- token-scoped SECURITY DEFINER RPCs closes both holes while keeping
-- the guest receipt-tracking/upload flow working exactly as before
-- (the frontend already always sent id+token together).

begin;

drop policy if exists orders_receipt_select on public.orders;
drop policy if exists orders_receipt_update on public.orders;

create or replace function public.get_order_by_token(p_id text, p_token text)
returns setof public.orders
language sql
security definer
stable
set search_path to 'public'
as $$
  select * from public.orders
  where id = p_id
    and receipt_token is not null
    and receipt_token = p_token
  limit 1;
$$;

revoke all on function public.get_order_by_token(text, text) from public;
grant execute on function public.get_order_by_token(text, text) to anon, authenticated;

create or replace function public.submit_order_receipt(p_id text, p_token text, p_receipt_url text)
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  updated_count int;
begin
  update public.orders
  set receipt_url = p_receipt_url,
      payment_status = 'waiting_review',
      receipt_at = now()
  where id = p_id
    and receipt_token is not null
    and receipt_token = p_token
    and payment_status = any(array['waiting_review','pending']);
  get diagnostics updated_count = row_count;
  return updated_count > 0;
end;
$$;

revoke all on function public.submit_order_receipt(text, text, text) from public;
grant execute on function public.submit_order_receipt(text, text, text) to anon, authenticated;

commit;
