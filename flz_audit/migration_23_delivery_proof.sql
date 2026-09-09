-- Delivery proof photos: admin-uploaded (not customer), private bucket,
-- admin-only storage access — customers see their own proof only via a
-- token-gated Edge Function signed URL (server-side, service-role key),
-- never direct bucket access. Deleting a proof only clears the pointer
-- column / removes the storage object — never touches the order row.

begin;

insert into storage.buckets (id, name, public)
values ('delivery_proofs', 'delivery_proofs', false)
on conflict (id) do nothing;

drop policy if exists delivery_proofs_admin_all on storage.objects;
create policy delivery_proofs_admin_all on storage.objects for all to authenticated
using (bucket_id = 'delivery_proofs' and is_admin())
with check (bucket_id = 'delivery_proofs' and is_admin());

alter table public.orders add column if not exists delivery_proof_url text;
alter table public.orders add column if not exists delivery_proof_uploaded_at timestamptz;

create or replace function public.orders_guard_anon_update()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
BEGIN
  IF auth.role() = 'service_role' THEN RETURN NEW; END IF;
  IF auth.uid() IS NOT NULL AND EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN NEW;
  END IF;

  NEW.name := OLD.name;
  NEW.phone := OLD.phone;
  NEW.wilaya := OLD.wilaya;
  NEW.wilaya_id := OLD.wilaya_id;
  NEW.commune := OLD.commune;
  NEW.address := OLD.address;
  NEW.delivery_cost := OLD.delivery_cost;
  NEW.product_id := OLD.product_id;
  NEW.product_name := OLD.product_name;
  NEW.product_price := OLD.product_price;
  NEW.product_sku := OLD.product_sku;
  NEW.is_multi_item := OLD.is_multi_item;
  NEW.qty := OLD.qty;
  NEW.total := OLD.total;
  NEW.payment_method := OLD.payment_method;
  NEW.fulfillment_type := OLD.fulfillment_type;
  NEW.deposit_amount := OLD.deposit_amount;
  NEW.deposit_status := OLD.deposit_status;
  NEW.status := OLD.status;
  NEW.ref := OLD.ref;
  NEW.receipt_token := OLD.receipt_token;
  NEW.delivery_proof_url := OLD.delivery_proof_url;
  NEW.delivery_proof_uploaded_at := OLD.delivery_proof_uploaded_at;

  IF OLD.payment_status = 'paid' THEN
    RAISE EXCEPTION 'order already finalized';
  END IF;

  IF NEW.payment_status IS DISTINCT FROM OLD.payment_status
     AND NEW.payment_status NOT IN ('waiting_review','waiting_slickpay') THEN
    NEW.payment_status := OLD.payment_status;
  END IF;

  RETURN NEW;
END;
$$;

commit;
