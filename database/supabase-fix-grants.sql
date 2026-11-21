-- =====================================================================
--  SAR'S HOUSE — FIX for "401" errors on products / store_settings
--  Run ONCE in: Supabase Dashboard → SQL Editor → New query → Run
--  Safe to re-run. (RLS policies still decide who can do what.)
-- =====================================================================

grant usage on schema public to anon, authenticated;

-- visitors (not logged in) can only READ products & settings, and PLACE orders
grant select         on public.products       to anon, authenticated;
grant select         on public.store_settings to anon, authenticated;
grant insert         on public.orders         to anon, authenticated;

-- logged-in users (RLS limits each role to what it is allowed to do)
grant select, insert, update, delete on public.products       to authenticated;
grant select, insert, update, delete on public.store_settings to authenticated;
grant select, update, delete         on public.orders         to authenticated;
grant select, update, delete         on public.profiles       to authenticated;

grant execute on function public.get_my_role()        to anon, authenticated;
grant execute on function public.is_super_admin()     to anon, authenticated;
grant execute on function public.is_staff()           to anon, authenticated;
grant execute on function public.has_permission(text) to anon, authenticated;

-- make Supabase's API pick up the changes immediately
notify pgrst, 'reload schema';
