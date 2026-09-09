-- Occasions: a real, independent taxonomy (Valentine's Day, birthdays,
-- weddings, etc.) — many-to-many with products, since one bouquet can
-- suit several occasions, unlike the single-category_id model. Mirrors
-- the categories table's exact shape and RLS pattern for consistency.

begin;

create table if not exists public.occasions (
  id text primary key default ('occ' || extract(epoch from now())::bigint::text || substr(md5(random()::text),1,4)),
  name_ar text not null,
  name_fr text,
  icon text default '🎉',
  sort_order integer default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);

alter table public.occasions enable row level security;
drop policy if exists occasions_anon_read on public.occasions;
create policy occasions_anon_read on public.occasions for select to public
using (deleted_at is null);
drop policy if exists occasions_admin_write on public.occasions;
create policy occasions_admin_write on public.occasions for all to public
using (is_admin()) with check (is_admin());

create table if not exists public.product_occasions (
  product_id text not null references public.products(id) on delete cascade,
  occasion_id text not null references public.occasions(id) on delete cascade,
  primary key (product_id, occasion_id)
);
create index if not exists product_occasions_occasion_idx on public.product_occasions(occasion_id);

alter table public.product_occasions enable row level security;
drop policy if exists product_occasions_anon_read on public.product_occasions;
create policy product_occasions_anon_read on public.product_occasions for select to public
using (true);
drop policy if exists product_occasions_admin_write on public.product_occasions;
create policy product_occasions_admin_write on public.product_occasions for all to public
using (is_admin()) with check (is_admin());

commit;
