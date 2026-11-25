-- =====================================================================
-- SAR'S HOUSE — security pack (run once in Supabase → SQL Editor)
--   1. Two-step login enforcement for admins (only for users who have
--      enrolled an authenticator — nobody is locked out before that)
--   2. Order / stock-request spam brakes
--   3. Admin activity log + "restore deleted product"
-- Safe to run more than once.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. TWO-STEP LOGIN (TOTP) — server-side enforcement
-- ---------------------------------------------------------------------
create or replace function public.mfa_ok()
returns boolean language sql stable security definer set search_path = public, auth as $$
  select coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2'
      or not exists (select 1 from auth.mfa_factors f
                     where f.user_id = auth.uid() and f.status = 'verified');
$$;
grant execute on function public.mfa_ok() to anon, authenticated;

create or replace function public.is_super_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'super_admin')
         and public.mfa_ok();
$$;
create or replace function public.is_staff()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles p where p.id = auth.uid() and p.role in ('admin', 'super_admin'))
         and public.mfa_ok();
$$;
create or replace function public.has_permission(perm text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and (p.role = 'super_admin' or (p.role = 'admin' and perm = any (p.permissions)))
  ) and public.mfa_ok();
$$;

-- ---------------------------------------------------------------------
-- 2. SPAM BRAKES
-- ---------------------------------------------------------------------
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
  return public._place_order_core(p_name, p_phone, p_address, p_area, p_items, p_coupon, p_note);
end $$;
grant execute on function public.place_order(text,text,text,text,jsonb,text,text) to anon, authenticated;

create or replace function public.stock_requests_brake() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from public.stock_requests where created_at > now() - interval '10 minutes') >= 40 then
    raise exception 'rate_limit'; end if;
  return new;
end $$;
drop trigger if exists stock_requests_brake on public.stock_requests;
create trigger stock_requests_brake before insert on public.stock_requests
  for each row execute function public.stock_requests_brake();

-- ---------------------------------------------------------------------
-- 3. ADMIN ACTIVITY LOG
-- ---------------------------------------------------------------------
create table if not exists public.admin_log (
  id         bigserial primary key,
  at         timestamptz not null default now(),
  actor      uuid,
  actor_email text,
  tbl        text not null,
  action     text not null,
  row_id     text,
  label      text,
  old_data   jsonb,
  new_data   jsonb
);
create index if not exists admin_log_at_idx on public.admin_log (at desc);
alter table public.admin_log enable row level security;
drop policy if exists "admin_log_select" on public.admin_log;
create policy "admin_log_select" on public.admin_log for select to authenticated using (public.is_super_admin());
revoke all on public.admin_log from anon, authenticated;
grant select on public.admin_log to authenticated;

create or replace function public.log_change() returns trigger
language plpgsql security definer set search_path = public as $$
declare o jsonb := case when tg_op = 'INSERT' then null else to_jsonb(old) end;
        n jsonb := case when tg_op = 'DELETE' then null else to_jsonb(new) end;
        j jsonb; em text;
begin
  if not public.is_staff() then return coalesce(new, old); end if;   -- customers / system: not logged
  j := coalesce(n, o);
  if tg_table_name = 'profiles' and tg_op = 'UPDATE'
     and (o->>'role') is not distinct from (n->>'role')
     and (o->'permissions') is not distinct from (n->'permissions') then return new; end if;
  select email into em from public.profiles where id = auth.uid();
  insert into public.admin_log (actor, actor_email, tbl, action, row_id, label, old_data, new_data)
  values (auth.uid(), em, tg_table_name, lower(tg_op), coalesce(j->>'id', j->>'key'),
          left(coalesce(j->>'name', j->>'order_no', j->>'code', j->>'key', j->>'email', ''), 120), o, n);
  if random() < 0.02 then delete from public.admin_log where at < now() - interval '180 days'; end if;
  return coalesce(new, old);
end $$;

do $$
declare t text;
begin
  foreach t in array array['products', 'orders', 'coupons', 'store_settings', 'profiles', 'reviews'] loop
    if to_regclass('public.' || t) is not null then
      execute format('drop trigger if exists log_change on public.%I', t);
      execute format('create trigger log_change after insert or update or delete on public.%I for each row execute function public.log_change()', t);
    end if;
  end loop;
end $$;

-- put a product back the way it was (deleted → re-created, edited → old values)
create or replace function public.restore_product(p_log bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l public.admin_log; cols text;
begin
  if not public.is_super_admin() then raise exception 'forbidden'; end if;
  select * into l from public.admin_log where id = p_log and tbl = 'products';
  if not found or l.old_data is null then raise exception 'nothing_to_restore'; end if;
  if l.action = 'delete' then
    insert into public.products select * from jsonb_populate_record(null::public.products, l.old_data)
    on conflict (id) do nothing;
  else
    select string_agg(quote_ident(column_name), ',') into cols from information_schema.columns
     where table_schema = 'public' and table_name = 'products' and column_name <> 'id';
    execute format('update public.products set (%s) = (select %s from jsonb_populate_record(null::public.products, $1)) where id = $2', cols, cols)
      using l.old_data, (l.old_data->>'id')::uuid;
  end if;
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.restore_product(bigint) to authenticated;

notify pgrst, 'reload schema';
