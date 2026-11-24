-- =====================================================================
--  SAR'S HOUSE — নতুন ফিচারের SQL  (কুপন, ওজন অনুযায়ী দাম, একাধিক ছবি,
--  স্টক সংখ্যা, কম্বো, রিভিউ, "স্টকে এলে জানান", নিরাপদ অর্ডার ফাংশন)
--
--  কীভাবে চালাবেন: Supabase → SQL Editor → New query → এই পুরো লেখা পেস্ট → Run
--  বারবার চালালেও কোনো ক্ষতি নেই (idempotent)।
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. products / orders — নতুন কলাম
-- ---------------------------------------------------------------------
alter table public.products add column if not exists images   jsonb   not null default '[]'::jsonb;
alter table public.products add column if not exists variants jsonb   not null default '[]'::jsonb;
alter table public.products add column if not exists stock_qty integer;
alter table public.products add column if not exists is_combo boolean not null default false;
alter table public.products add column if not exists is_best  boolean not null default false;
alter table public.products drop constraint if exists products_stock_qty_check;
alter table public.products add constraint products_stock_qty_check check (stock_qty is null or stock_qty >= 0);

alter table public.orders add column if not exists coupon_code text not null default '';
alter table public.orders add column if not exists discount    numeric(12,2) not null default 0;
alter table public.orders add column if not exists tracking    text not null default '';

-- delivery area may now be any configured zone; status gains "shipped"
alter table public.orders drop constraint if exists orders_area_check;
alter table public.orders add  constraint orders_area_check check (char_length(area) between 1 and 40);
alter table public.orders drop constraint if exists orders_status_check;
alter table public.orders add  constraint orders_status_check
  check (status in ('pending', 'confirmed', 'shipped', 'delivered', 'cancelled'));

-- ---------------------------------------------------------------------
-- 2. COUPONS (only staff can read them; customers go through check_coupon)
-- ---------------------------------------------------------------------
create table if not exists public.coupons (
  id           uuid primary key default gen_random_uuid(),
  code         text not null unique check (code = upper(code) and char_length(code) between 2 and 30),
  kind         text not null check (kind in ('percent', 'fixed', 'free_delivery')),
  value        numeric(12,2) not null default 0 check (value >= 0),
  max_discount numeric(12,2) check (max_discount is null or max_discount >= 0),
  min_order    numeric(12,2) not null default 0 check (min_order >= 0),
  max_uses     integer check (max_uses is null or max_uses >= 1),
  used_count   integer not null default 0,
  expires_at   timestamptz,
  active       boolean not null default true,
  note         text not null default '',
  created_at   timestamptz not null default now()
);
alter table public.coupons enable row level security;
drop policy if exists "coupons_staff_all" on public.coupons;
create policy "coupons_staff_all" on public.coupons for all to authenticated
  using (public.has_permission('products')) with check (public.has_permission('products'));

-- ---------------------------------------------------------------------
-- 3. REVIEWS (only buyers of a delivered order can review; you approve)
-- ---------------------------------------------------------------------
create table if not exists public.reviews (
  id         uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  user_id    uuid references auth.users(id) on delete set null,
  name       text not null check (char_length(name) between 1 and 80),
  rating     integer not null check (rating between 1 and 5),
  body       text not null default '' check (char_length(body) <= 600),
  approved   boolean not null default false,
  created_at timestamptz not null default now(),
  unique (product_id, user_id)
);
alter table public.reviews enable row level security;
drop policy if exists "reviews_select" on public.reviews;
drop policy if exists "reviews_update" on public.reviews;
drop policy if exists "reviews_delete" on public.reviews;
create policy "reviews_select" on public.reviews for select
  using (approved = true or user_id = auth.uid() or public.has_permission('products'));
create policy "reviews_update" on public.reviews for update to authenticated
  using (public.has_permission('products')) with check (public.has_permission('products'));
create policy "reviews_delete" on public.reviews for delete to authenticated
  using (public.has_permission('products'));

-- ---------------------------------------------------------------------
-- 4. "স্টকে এলে জানান" requests
-- ---------------------------------------------------------------------
create table if not exists public.stock_requests (
  id         uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  phone      text not null check (char_length(phone) between 6 and 20),
  created_at timestamptz not null default now(),
  unique (product_id, phone)
);
alter table public.stock_requests enable row level security;
drop policy if exists "stock_requests_insert" on public.stock_requests;
drop policy if exists "stock_requests_select" on public.stock_requests;
drop policy if exists "stock_requests_delete" on public.stock_requests;
create policy "stock_requests_insert" on public.stock_requests for insert to anon, authenticated with check (true);
create policy "stock_requests_select" on public.stock_requests for select to authenticated
  using (public.has_permission('products'));
create policy "stock_requests_delete" on public.stock_requests for delete to authenticated
  using (public.has_permission('products'));

-- ---------------------------------------------------------------------
-- 5. SERVER-SIDE PRICING: coupon check + place_order
--    The browser can no longer choose its own prices or totals.
-- ---------------------------------------------------------------------
create or replace function public._coupon_eval(p_code text, p_subtotal numeric, p_delivery numeric)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c public.coupons; d numeric := 0; dd numeric := 0;
begin
  select * into c from public.coupons where code = upper(btrim(p_code));
  if not found or not c.active then return jsonb_build_object('ok', false, 'code', 'coupon_invalid'); end if;
  if c.expires_at is not null and c.expires_at < now() then return jsonb_build_object('ok', false, 'code', 'coupon_expired'); end if;
  if c.max_uses is not null and c.used_count >= c.max_uses then return jsonb_build_object('ok', false, 'code', 'coupon_used_up'); end if;
  if p_subtotal < c.min_order then return jsonb_build_object('ok', false, 'code', 'coupon_min', 'amount', c.min_order); end if;
  if c.kind = 'percent' then
    d := round(p_subtotal * least(c.value, 100) / 100);
    if c.max_discount is not null then d := least(d, c.max_discount); end if;
  elsif c.kind = 'fixed' then
    d := least(c.value, p_subtotal);
  else
    dd := p_delivery;
  end if;
  return jsonb_build_object('ok', true, 'code', c.code, 'kind', c.kind, 'discount', d, 'delivery_discount', dd);
end $$;

create or replace function public.check_coupon(p_code text, p_subtotal numeric, p_delivery numeric)
returns jsonb language sql stable security definer set search_path = public as $$
  select public._coupon_eval(p_code, coalesce(p_subtotal, 0), coalesce(p_delivery, 0));
$$;

create or replace function public.place_order(
  p_name text, p_phone text, p_address text, p_area text,
  p_items jsonb, p_coupon text default '', p_note text default ''
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  d jsonb; it jsonb; prod public.products; v jsonb; vv jsonb;
  qty int; price numeric; sub numeric := 0; delivery numeric; free_min numeric;
  out_items jsonb := '[]'::jsonb; label text; wt text;
  zone jsonb; ok_area boolean := false; disc numeric := 0; ddisc numeric := 0;
  cv jsonb; ccode text := ''; ono text; res public.orders;
begin
  if coalesce(jsonb_typeof(p_items), '') <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'empty'; end if;
  if jsonb_array_length(p_items) > 40 then raise exception 'bad_input'; end if;
  p_name := btrim(coalesce(p_name, '')); p_phone := btrim(coalesce(p_phone, '')); p_address := btrim(coalesce(p_address, ''));
  if char_length(p_name) not between 1 and 120 or char_length(p_phone) not between 6 and 20
     or char_length(p_address) not between 1 and 500 then raise exception 'bad_input'; end if;

  select value into d from public.store_settings where key = 'design';
  d := coalesce(d, '{}'::jsonb);
  if (d->>'orders_paused') = 'true' then raise exception 'paused'; end if;

  if p_area = 'dhaka' then ok_area := true; delivery := coalesce(nullif(d->>'delivery_dhaka', '')::numeric, 60);
  elsif p_area = 'outside' then ok_area := true; delivery := coalesce(nullif(d->>'delivery_outside', '')::numeric, 120);
  elsif jsonb_typeof(d->'extra_zones') = 'array' then
    for zone in select * from jsonb_array_elements(d->'extra_zones') loop
      if zone->>'id' = p_area then ok_area := true; delivery := coalesce(nullif(zone->>'charge', '')::numeric, 0); end if;
    end loop;
  end if;
  if not ok_area then raise exception 'bad_area'; end if;

  for it in select * from jsonb_array_elements(p_items) loop
    begin
      qty := least(50, greatest(1, (it->>'qty')::int));
      select * into prod from public.products where id = (it->>'id')::uuid for update;
    exception when others then raise exception 'bad_input';
    end;
    if not found or not prod.in_stock then raise exception 'unavailable:%', coalesce(prod.name, ''); end if;
    label := ''; wt := prod.weight; price := prod.price;
    if jsonb_typeof(prod.variants) = 'array' and jsonb_array_length(prod.variants) > 0 then
      vv := null;
      for v in select * from jsonb_array_elements(prod.variants) loop
        if v->>'label' = it->>'v' then vv := v; end if;
      end loop;
      if vv is null then raise exception 'unavailable:%', prod.name; end if;
      price := coalesce(nullif(vv->>'price', '')::numeric, 0); label := vv->>'label'; wt := vv->>'label';
    end if;
    if price <= 0 then raise exception 'noprice:%', prod.name; end if;
    if prod.stock_qty is not null then
      if prod.stock_qty < qty then raise exception 'stock:%', prod.name; end if;
      update public.products set stock_qty = stock_qty - qty,
             in_stock = (stock_qty - qty) > 0 where id = prod.id;
    end if;
    sub := sub + price * qty;
    out_items := out_items || jsonb_build_array(jsonb_build_object(
      'id', prod.id, 'name', prod.name, 'name_en', prod.name_en, 'price', price,
      'qty', qty, 'weight', wt, 'variant', label));
  end loop;

  free_min := coalesce(nullif(d->>'free_delivery_min', '')::numeric, 0);
  if free_min > 0 and sub >= free_min then delivery := 0; end if;

  if btrim(coalesce(p_coupon, '')) <> '' then
    perform 1 from public.coupons c where c.code = upper(btrim(p_coupon)) for update;
    cv := public._coupon_eval(p_coupon, sub, delivery);
    if not (cv->>'ok')::boolean then
      raise exception '%', cv->>'code' || coalesce(':' || (cv->>'amount'), '');
    end if;
    disc := (cv->>'discount')::numeric; ddisc := (cv->>'delivery_discount')::numeric; ccode := cv->>'code';
    update public.coupons c set used_count = c.used_count + 1 where c.code = cv->>'code';
  end if;

  ono := 'SH' || to_char(now() at time zone 'Asia/Dhaka', 'YYMMDD') || '-' || lpad((floor(random() * 9000) + 1000)::int::text, 4, '0');
  insert into public.orders (order_no, user_id, customer_name, phone, address, area, items,
                             subtotal, delivery_charge, total, status, note, coupon_code, discount)
  values (ono, auth.uid(), p_name, p_phone, p_address, p_area, out_items,
          sub, delivery - ddisc, sub - disc + (delivery - ddisc), 'pending', left(coalesce(p_note, ''), 500), ccode, disc + ddisc)
  returning * into res;
  return to_jsonb(res);
end $$;

-- the only way to create an order is now place_order()
drop policy if exists "orders_insert" on public.orders;
revoke insert on public.orders from anon, authenticated;

-- ---------------------------------------------------------------------
-- 6. REVIEW SUBMISSION (verified buyers only)
-- ---------------------------------------------------------------------
create or replace function public.submit_review(p_product uuid, p_rating int, p_body text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); nm text;
begin
  if uid is null then raise exception 'login'; end if;
  if p_rating is null or p_rating not between 1 and 5 then raise exception 'bad_input'; end if;
  if not exists (select 1 from public.orders o where o.user_id = uid and o.status = 'delivered'
                 and o.items @> jsonb_build_array(jsonb_build_object('id', p_product::text))) then
    raise exception 'not_buyer'; end if;
  select coalesce(nullif(btrim(full_name), ''), split_part(email, '@', 1), 'গ্রাহক') into nm from public.profiles where id = uid;
  insert into public.reviews (product_id, user_id, name, rating, body, approved)
  values (p_product, uid, left(coalesce(nm, 'গ্রাহক'), 80), p_rating, left(coalesce(p_body, ''), 600), false)
  on conflict (product_id, user_id) do update
    set rating = excluded.rating, body = excluded.body, approved = false, created_at = now();
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- 7. cancelling an order puts the stock back (un-cancelling takes it again)
-- ---------------------------------------------------------------------
create or replace function public.orders_stock_sync() returns trigger
language plpgsql security definer set search_path = public as $$
declare it jsonb; sign int;
begin
  if new.status = old.status then return new; end if;
  if new.status = 'cancelled' then sign := 1;
  elsif old.status = 'cancelled' then sign := -1;
  else return new; end if;
  for it in select * from jsonb_array_elements(new.items) loop
    update public.products
       set stock_qty = greatest(0, stock_qty + sign * coalesce(nullif(it->>'qty', '')::int, 0)),
           in_stock = (greatest(0, stock_qty + sign * coalesce(nullif(it->>'qty', '')::int, 0)) > 0)
     where id::text = it->>'id' and stock_qty is not null;
  end loop;
  return new;
end $$;
drop trigger if exists orders_stock_sync on public.orders;
create trigger orders_stock_sync after update of status on public.orders
  for each row execute function public.orders_stock_sync();

-- ---------------------------------------------------------------------
-- 8. PRIVILEGES
-- ---------------------------------------------------------------------
grant select, insert, update, delete on public.coupons        to authenticated;
grant select                         on public.reviews        to anon, authenticated;
grant update, delete                 on public.reviews        to authenticated;
grant insert                         on public.stock_requests to anon, authenticated;
grant select, delete                 on public.stock_requests to authenticated;

grant execute on function public.check_coupon(text, numeric, numeric)       to anon, authenticated;
grant execute on function public.place_order(text, text, text, text, jsonb, text, text) to anon, authenticated;
grant execute on function public.submit_review(uuid, int, text)             to authenticated;
revoke execute on function public._coupon_eval(text, numeric, numeric)      from public, anon, authenticated;

notify pgrst, 'reload schema';
