-- CRITICAL SECURITY FIX found during final security audit:
-- customers_auth_all was the ONLY policy in the entire schema scoped
-- to the generic 'authenticated' role with qual=true instead of the
-- is_admin() check every other admin-writable table uses. This was
-- not just theoretical: confirmed live via GET /auth/v1/settings that
-- this Supabase project has public signup ENABLED (disable_signup:
-- false, email signup on). Any person could self-register a
-- Supabase Auth account, confirm their own email, and — purely by
-- being "authenticated", with no admin role at all — get full
-- SELECT/INSERT/UPDATE/DELETE on the customers table: real customer
-- names, phone numbers, and purchase history.
--
-- The "Staff" feature in admin.html (page-staff) does NOT create real
-- Supabase Auth accounts — it's just a JSON list in settings.staff
-- for payroll record-keeping — so there is no legitimate lower-
-- privilege authenticated tier that this policy needed to serve.
-- This was a plain gap, not a deliberate broader grant.

begin;

drop policy if exists customers_auth_all on public.customers;

create policy customers_admin_all
  on public.customers
  for all
  to authenticated
  using (is_admin())
  with check (is_admin());

commit;
