-- =====================================================================
--  SAR'S HOUSE — "বেশি বিক্রিত" (Best Selling) switch for products
--  Run ONCE in: Supabase Dashboard → SQL Editor → New query → Run
--  Safe to re-run.
-- =====================================================================
alter table public.products add column if not exists is_best boolean not null default false;
notify pgrst, 'reload schema';
