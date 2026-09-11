-- Gift order support: checkout.html gets a "هذا الطلب هدية 🎁"
-- checkbox; when checked, sender phone becomes required and an
-- optional gift message can be added. Both create_order (single-item)
-- and create_cart_order (cart) get the same three new optional
-- parameters, each defaulted so existing callers that omit them are
-- unaffected. Server-side validates sender phone is present whenever
-- is_gift is true — defense in depth, not just a client-side check.

begin;

alter table public.orders
  add column if not exists is_gift boolean not null default false,
  add column if not exists gift_sender_phone text,
  add column if not exists gift_message text;

create or replace function public.create_order(
  p_id text, p_name text, p_phone text, p_wilaya_id integer, p_commune text, p_address text,
  p_product_id text, p_color text, p_qty integer, p_payment_method text, p_fulfillment_type text,
  p_note text, p_lang text, p_email text, p_coupon_code text, p_client_ref text,
  p_is_gift boolean default false, p_gift_sender_phone text default null, p_gift_message text default null
)
returns table(id text, ref text, receipt_token text, total integer, delivery_cost integer, deposit_amount integer, payment_status text, status text, fulfillment_type text, wilaya text)
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if p_is_gift and (p_gift_sender_phone is null or trim(p_gift_sender_phone) = '') then
    raise exception 'sender phone is required for gift orders';
  end if;
  return query
  insert into public.orders (
    id, name, phone, wilaya_id, commune, address,
    product_id, color, qty, payment_method, fulfillment_type,
    note, lang, email, coupon_code, client_ref,
    is_gift, gift_sender_phone, gift_message, created_at
  ) values (
    p_id, p_name, p_phone, p_wilaya_id, nullif(p_commune,''), nullif(p_address,''),
    p_product_id, p_color, p_qty, p_payment_method, p_fulfillment_type,
    nullif(p_note,''), p_lang, nullif(p_email,''), nullif(p_coupon_code,''), p_client_ref,
    coalesce(p_is_gift,false), nullif(p_gift_sender_phone,''), nullif(p_gift_message,''), now()
  )
  returning
    orders.id, orders.ref, orders.receipt_token, orders.total, orders.delivery_cost,
    orders.deposit_amount, orders.payment_status, orders.status, orders.fulfillment_type, orders.wilaya;
end;
$function$;

create or replace function public.create_cart_order(
  p_id text, p_items jsonb, p_name text, p_phone text, p_wilaya_id integer, p_commune text, p_address text,
  p_payment_method text, p_fulfillment_type text, p_note text, p_lang text, p_email text,
  p_coupon_code text, p_client_ref text,
  p_is_gift boolean default false, p_gift_sender_phone text default null, p_gift_message text default null
)
returns table(id text, ref text, receipt_token text, total integer, delivery_cost integer, deposit_amount integer, payment_status text, status text, fulfillment_type text, wilaya text, item_count integer)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  item jsonb;
  prod record;
  qty integer;
  n_items integer := 0;
begin
  if not public.is_feature_enabled('cart') then
    raise exception 'cart is currently disabled';
  end if;

  if p_is_gift and (p_gift_sender_phone is null or trim(p_gift_sender_phone) = '') then
    raise exception 'sender phone is required for gift orders';
  end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'cart is empty';
  end if;
  if jsonb_array_length(p_items) > 30 then
    raise exception 'too many distinct items';
  end if;

  for item in select * from jsonb_array_elements(p_items) loop
    select * into prod from public.products as pr
      where pr.id = (item->>'product_id') and pr.active = true and pr.deleted_at is null;
    if not found then continue; end if;

    qty := coalesce((item->>'qty')::integer, 1);
    if qty < 1 then qty := 1; end if;
    if qty > 20 then qty := 20; end if;

    insert into public.order_items (order_id, product_id, product_name, product_sku, product_price, qty, subtotal)
    values (p_id, prod.id, prod.name_ar, prod.sku, prod.price, qty, prod.price * qty);
    n_items := n_items + 1;
  end loop;

  if n_items = 0 then
    raise exception 'no valid products in cart';
  end if;

  insert into public.orders (
    id, name, phone, wilaya_id, commune, address, payment_method, fulfillment_type,
    note, lang, email, coupon_code, client_ref, is_multi_item,
    is_gift, gift_sender_phone, gift_message, created_at
  ) values (
    p_id, p_name, p_phone, p_wilaya_id, nullif(p_commune,''), nullif(p_address,''),
    p_payment_method, p_fulfillment_type, nullif(p_note,''), p_lang, nullif(p_email,''),
    nullif(p_coupon_code,''), p_client_ref, true,
    coalesce(p_is_gift,false), nullif(p_gift_sender_phone,''), nullif(p_gift_message,''), now()
  );

  return query
  select o.id, o.ref, o.receipt_token, o.total, o.delivery_cost, o.deposit_amount,
         o.payment_status, o.status, o.fulfillment_type, o.wilaya, n_items
  from public.orders o where o.id = p_id;
end;
$function$;

commit;
