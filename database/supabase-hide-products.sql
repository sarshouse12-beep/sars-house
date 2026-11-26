-- =====================================================================
-- SAR'S HOUSE — "hide product" (run once in Supabase → SQL Editor)
-- Adds products.is_hidden. Hidden products disappear from the shop for
-- everyone except staff, and can no longer be ordered. Safe to re-run.
-- (Needs supabase-security.sql to have been run first.)
-- =====================================================================
alter table public.products add column if not exists is_hidden boolean not null default false;

drop policy if exists "products_select" on public.products;
create policy "products_select" on public.products for select
  using (not is_hidden or public.has_permission('products'));

-- order function: same spam brakes as supabase-security.sql, plus "hidden products can't be ordered"
do $$
declare sig regprocedure := 'public.place_order(text,text,text,text,jsonb,text,text)'::regprocedure;
begin
  if position('_place_order_core' in pg_get_functiondef(sig)) = 0 then
    drop function if exists public._place_order_core(text,text,text,text,jsonb,text,text);
    alter function public.place_order(text,text,text,text,jsonb,text,text) rename to _place_order_core;
  end if;
end $$;
revoke all on function public._place_order_core(text,text,text,text,jsonb,text,text) from public, anon, authenticated;

create or replace function public.place_order(
  p_name text, p_phone text, p_address text, p_area text,
  p_items jsonb, p_coupon text default '', p_note text default ''
) returns jsonb language plpgsql security definer set search_path = public as $$
declare ph text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
begin
  -- same phone: max 3 orders / 10 min
  if length(ph) >= 6 and (select count(*) from public.orders
        where created_at > now() - interval '10 minutes'
          and regexp_replace(phone, '\D', '', 'g') = ph) >= 3 then
    raise exception 'rate_limit'; end if;
  -- same logged-in user: max 5 orders / 10 min
  if auth.uid() is not null and (select count(*) from public.orders
        where created_at > now() - interval '10 minutes' and user_id = auth.uid()) >= 5 then
    raise exception 'rate_limit'; end if;
  -- whole shop flood brake: 60 orders / 10 min
  if (select count(*) from public.orders where created_at > now() - interval '10 minutes') >= 60 then
    raise exception 'rate_limit'; end if;
  -- hidden products can never be ordered (only checked once supabase-hide-products.sql added the column)
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'products' and column_name = 'is_hidden') then
    if exists (select 1 from public.products pr where pr.is_hidden
               and pr.id::text in (select e->>'id' from jsonb_array_elements(case when jsonb_typeof(p_items) = 'array' then p_items else '[]'::jsonb end) e)) then
      raise exception 'unavailable:'; end if;
  end if;
  return public._place_order_core(p_name, p_phone, p_address, p_area, p_items, p_coupon, p_note);
end $$;
grant execute on function public.place_order(text,text,text,text,jsonb,text,text) to anon, authenticated;


notify pgrst, 'reload schema';
