-- Manual order / order-detail: track the actual amount the customer
-- sent (separate from `total`, the computed order total, and
-- `deposit_amount`, the computed 50% pickup deposit — this is what
-- admin actually saw arrive, for reconciliation with any payment
-- method, not just pickup).

begin;

alter table public.orders
  add column if not exists amount_received integer;

commit;
