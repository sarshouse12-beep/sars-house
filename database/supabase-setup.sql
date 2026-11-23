-- =====================================================================
--  SAR'S HOUSE — Supabase setup (run once in: Supabase Dashboard → SQL Editor)
--  Safe to re-run: uses IF NOT EXISTS / DROP ... IF EXISTS / CREATE OR REPLACE.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. TABLES
-- ---------------------------------------------------------------------

create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  email       text,
  full_name   text not null default '',
  phone       text not null default '',
  address     text not null default '',
  role        text not null default 'customer'
              check (role in ('customer', 'admin', 'super_admin')),
  permissions text[] not null default '{}'
              check (permissions <@ array['products','orders','design','ads']::text[]),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- key = 'design' (theme, texts, banners, delivery, contact) | 'ads' (promo banner)
create table if not exists public.store_settings (
  key        text primary key,
  value      jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

create table if not exists public.products (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (char_length(name) between 1 and 200),
  category    text not null default 'মধু',
  description text not null default '',
  name_en        text not null default '',
  description_en text not null default '',
  price       numeric(12,2) not null check (price >= 0),
  old_price   numeric(12,2) check (old_price is null or old_price >= 0),
  weight      text not null default '',
  tag         text not null default '',
  image_url   text,
  in_stock    boolean not null default true,
  sort_order  integer not null default 0,
  created_at  timestamptz not null default now()
);

create table if not exists public.orders (
  id              uuid primary key default gen_random_uuid(),
  order_no        text not null,
  user_id         uuid references auth.users(id) on delete set null,
  customer_name   text not null check (char_length(customer_name) between 1 and 120),
  phone           text not null check (char_length(phone) between 6 and 20),
  address         text not null check (char_length(address) between 1 and 500),
  area            text not null default 'dhaka' check (area in ('dhaka', 'outside')),
  items           jsonb not null,
  subtotal        numeric(12,2) not null check (subtotal >= 0),
  delivery_charge numeric(12,2) not null default 0 check (delivery_charge >= 0),
  total           numeric(12,2) not null check (total >= 0),
  status          text not null default 'pending'
                  check (status in ('pending', 'confirmed', 'delivered', 'cancelled')),
  note            text not null default '',
  created_at      timestamptz not null default now()
);

alter table public.products add column if not exists name_en        text not null default '';
alter table public.products add column if not exists description_en text not null default '';

create index if not exists orders_user_id_idx    on public.orders (user_id);
create index if not exists orders_created_at_idx on public.orders (created_at desc);
create index if not exists products_category_idx on public.products (category);

-- ---------------------------------------------------------------------
-- 2. SECURITY DEFINER HELPERS (avoid RLS recursion on profiles)
-- ---------------------------------------------------------------------

create or replace function public.get_my_role()
returns text
language sql stable security definer
set search_path = public
as $$
  select coalesce((select role from public.profiles where id = auth.uid()), 'customer');
$$;

create or replace function public.is_super_admin()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select public.get_my_role() = 'super_admin';
$$;

create or replace function public.is_staff()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select public.get_my_role() in ('admin', 'super_admin');
$$;

-- super_admin => always true; admin => only if permission was granted
create or replace function public.has_permission(perm text)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and (p.role = 'super_admin'
           or (p.role = 'admin' and perm = any (p.permissions)))
  );
$$;

grant execute on function public.get_my_role()          to anon, authenticated;
grant execute on function public.is_super_admin()       to anon, authenticated;
grant execute on function public.is_staff()             to anon, authenticated;
grant execute on function public.has_permission(text)   to anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. TRIGGERS
-- ---------------------------------------------------------------------

-- 3a. Create a profile (always role = customer) for every new signup
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email, full_name, phone)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data ->> 'full_name', ''),
    coalesce(new.raw_user_meta_data ->> 'phone', '')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- 3b. Customers / admins can never change role, permissions or email.
--     (auth.uid() is NULL in the SQL Editor, so you can still promote the first super admin there.)
create or replace function public.protect_profile_fields()
returns trigger
language plpgsql security definer
set search_path = public
as $$
begin
  if auth.uid() is not null and not public.is_super_admin() then
    new.id          := old.id;
    new.email       := old.email;
    new.role        := old.role;
    new.permissions := old.permissions;
  end if;
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists protect_profile_fields on public.profiles;
create trigger protect_profile_fields
  before update on public.profiles
  for each row execute function public.protect_profile_fields();

-- Back-fill profiles for any users that signed up before this script ran
insert into public.profiles (id, email, full_name, phone)
select u.id, u.email,
       coalesce(u.raw_user_meta_data ->> 'full_name', ''),
       coalesce(u.raw_user_meta_data ->> 'phone', '')
from auth.users u
on conflict (id) do nothing;

-- ---------------------------------------------------------------------
-- 4. ROW LEVEL SECURITY
-- ---------------------------------------------------------------------

alter table public.profiles       enable row level security;
alter table public.store_settings enable row level security;
alter table public.products       enable row level security;
alter table public.orders         enable row level security;

-- ---- profiles ----
drop policy if exists "profiles_select" on public.profiles;
drop policy if exists "profiles_update" on public.profiles;
drop policy if exists "profiles_delete" on public.profiles;

create policy "profiles_select" on public.profiles for select to authenticated
  using (auth.uid() = id or public.is_super_admin());

create policy "profiles_update" on public.profiles for update to authenticated
  using      (auth.uid() = id or public.is_super_admin())
  with check (auth.uid() = id or public.is_super_admin());

create policy "profiles_delete" on public.profiles for delete to authenticated
  using (public.is_super_admin());

-- ---- store_settings (public read; write by super_admin or the matching permission) ----
drop policy if exists "settings_select" on public.store_settings;
drop policy if exists "settings_insert" on public.store_settings;
drop policy if exists "settings_update" on public.store_settings;
drop policy if exists "settings_delete" on public.store_settings;

create policy "settings_select" on public.store_settings for select
  using (true);

create policy "settings_insert" on public.store_settings for insert to authenticated
  with check (
    public.is_super_admin()
    or (key = 'design' and public.has_permission('design'))
    or (key = 'ads'    and public.has_permission('ads'))
  );

create policy "settings_update" on public.store_settings for update to authenticated
  using (
    public.is_super_admin()
    or (key = 'design' and public.has_permission('design'))
    or (key = 'ads'    and public.has_permission('ads'))
  )
  with check (
    public.is_super_admin()
    or (key = 'design' and public.has_permission('design'))
    or (key = 'ads'    and public.has_permission('ads'))
  );

create policy "settings_delete" on public.store_settings for delete to authenticated
  using (public.is_super_admin());

-- ---- products (public read; write needs 'products' permission) ----
drop policy if exists "products_select" on public.products;
drop policy if exists "products_insert" on public.products;
drop policy if exists "products_update" on public.products;
drop policy if exists "products_delete" on public.products;

create policy "products_select" on public.products for select
  using (true);
create policy "products_insert" on public.products for insert to authenticated
  with check (public.has_permission('products'));
create policy "products_update" on public.products for update to authenticated
  using (public.has_permission('products')) with check (public.has_permission('products'));
create policy "products_delete" on public.products for delete to authenticated
  using (public.has_permission('products'));

-- ---- orders ----
drop policy if exists "orders_insert" on public.orders;
drop policy if exists "orders_select" on public.orders;
drop policy if exists "orders_update" on public.orders;
drop policy if exists "orders_delete" on public.orders;

-- anyone (guest or logged-in) may place an order, but only as 'pending' and only as themselves
create policy "orders_insert" on public.orders for insert to anon, authenticated
  with check (
    status = 'pending'
    and jsonb_typeof(items) = 'array'
    and (user_id is null or user_id = auth.uid())
  );

-- customers see only their own orders; staff with 'orders' permission see all
create policy "orders_select" on public.orders for select to authenticated
  using (user_id = auth.uid() or public.has_permission('orders'));

create policy "orders_update" on public.orders for update to authenticated
  using (public.has_permission('orders')) with check (public.has_permission('orders'));

create policy "orders_delete" on public.orders for delete to authenticated
  using (public.has_permission('orders'));

-- ---------------------------------------------------------------------
-- 5. STORAGE — public bucket "shop-images"
-- ---------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('shop-images', 'shop-images', true, 5242880,
        array['image/jpeg', 'image/png', 'image/webp', 'image/gif'])
on conflict (id) do update
  set public = true,
      file_size_limit = 5242880,
      allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp', 'image/gif'];

drop policy if exists "shop_images_public_read"   on storage.objects;
drop policy if exists "shop_images_staff_insert"  on storage.objects;
drop policy if exists "shop_images_staff_update"  on storage.objects;
drop policy if exists "shop_images_staff_delete"  on storage.objects;

create policy "shop_images_public_read" on storage.objects for select
  using (bucket_id = 'shop-images');

create policy "shop_images_staff_insert" on storage.objects for insert to authenticated
  with check (
    bucket_id = 'shop-images'
    and (public.has_permission('products') or public.has_permission('design') or public.has_permission('ads'))
  );

create policy "shop_images_staff_update" on storage.objects for update to authenticated
  using (
    bucket_id = 'shop-images'
    and (public.has_permission('products') or public.has_permission('design') or public.has_permission('ads'))
  );

create policy "shop_images_staff_delete" on storage.objects for delete to authenticated
  using (
    bucket_id = 'shop-images'
    and (public.has_permission('products') or public.has_permission('design') or public.has_permission('ads'))
  );

-- ---------------------------------------------------------------------
-- 6. REALTIME (customers see order status changes live; admins see new orders)
-- ---------------------------------------------------------------------
do $$
begin
  alter publication supabase_realtime add table public.orders;
exception when duplicate_object then null;
end $$;

-- ---------------------------------------------------------------------
-- 7. DEFAULT SETTINGS ROWS (empty = the site uses its built-in defaults)
-- ---------------------------------------------------------------------
insert into public.store_settings (key, value)
  values ('design', jsonb_build_object('categories', '[{"id": "c1", "name": "মধু", "name_en": "Honey", "icon": "fa-droplet", "image": ""}, {"id": "c2", "name": "ঘি ও তেল", "name_en": "Ghee & Oil", "icon": "fa-bottle-droplet", "image": ""}, {"id": "c3", "name": "দই ও দুগ্ধজাত", "name_en": "Yogurt & Dairy", "icon": "fa-bowl-food", "image": ""}, {"id": "c4", "name": "ড্রাই ফ্রুটস ও বাদাম", "name_en": "Dry Fruits & Nuts", "icon": "fa-seedling", "image": ""}]'::jsonb))
  on conflict (key) do nothing;
insert into public.store_settings (key, value) values ('ads', '{}'::jsonb)
  on conflict (key) do nothing;

-- ---------------------------------------------------------------------
-- 8. YOUR PRODUCT LIST (price 0 = "ask on WhatsApp" until you set the price
--    in Admin panel → পণ্য). Only added when the products table is empty.
-- ---------------------------------------------------------------------
insert into public.products (name, name_en, category, description, description_en, price, old_price, weight, tag, in_stock, sort_order)
select v.* from (values
  ('সরমালাই দই', 'Sormalai Doi (Cream Yogurt)', 'দই ও দুগ্ধজাত', '', '', 0::numeric, null::numeric, '', '', true, 1),
  ('সরের রসমালাই', 'Cream Rasmalai', 'দই ও দুগ্ধজাত', '', '', 0::numeric, null::numeric, '', '', true, 2),
  ('সরযুক্ত সলপের মাঠা', 'Sholop Buttermilk (Mattha) with Cream', 'দই ও দুগ্ধজাত', '', '', 0::numeric, null::numeric, '', '', true, 3),
  ('সিরাজগঞ্জের খাঁটি গাওয়া ঘি', 'Pure Gawa Ghee of Sirajganj', 'ঘি ও তেল', '', '', 0::numeric, null::numeric, '', '', true, 4),
  ('তেঁতুল কাঠের ঘানির সরিষার তেল', 'Tamarind-Wood Ghani Mustard Oil', 'ঘি ও তেল', '', '', 0::numeric, null::numeric, '', '', true, 5),
  ('ড্রাই ফ্রুটস', 'Dry Fruits', 'ড্রাই ফ্রুটস ও বাদাম', '', '', 0::numeric, null::numeric, '', '', true, 6),
  ('মধুময় বাদাম / হানি নাটস', 'Honey Nuts', 'ড্রাই ফ্রুটস ও বাদাম', '', '', 0::numeric, null::numeric, '', '', true, 7),
  ('প্রাকৃতিক চাকের মধু', 'Natural Honeycomb Honey', 'মধু', '', '', 0::numeric, null::numeric, '', '', true, 8),
  ('সুন্দরবনের মধু', 'Sundarbans Honey', 'মধু', '', '', 0::numeric, null::numeric, '', '', true, 9),
  ('কালোজিরা ফুলের মধু', 'Black Cumin Flower Honey', 'মধু', '', '', 0::numeric, null::numeric, '', '', true, 10),
  ('লিচু ফুলের মধু', 'Litchi Flower Honey', 'মধু', '', '', 0::numeric, null::numeric, '', '', true, 11),
  ('বড়ই ফুলের মধু', 'Boroi (Jujube) Flower Honey', 'মধু', '', '', 0::numeric, null::numeric, '', '', true, 12),
  ('সরিষা ফুলের মধু', 'Mustard Flower Honey', 'মধু', '', '', 0::numeric, null::numeric, '', '', true, 13),
  ('দুধের ক্রীম', 'Milk Cream', 'দই ও দুগ্ধজাত', '', '', 0::numeric, null::numeric, '', '', true, 14),
  ('সরের ঘি', 'Cream Ghee (Shorer Ghee)', 'ঘি ও তেল', '', '', 0::numeric, null::numeric, '', '', true, 15),
  ('মাটির কাপদই', 'Clay Cup Doi', 'দই ও দুগ্ধজাত', '', '', 0::numeric, null::numeric, '', '', true, 16),
  ('প্লাস্টিকের কাপদই', 'Plastic Cup Doi', 'দই ও দুগ্ধজাত', '', '', 0::numeric, null::numeric, '', '', true, 17)
) as v(name, name_en, category, description, description_en, price, old_price, weight, tag, in_stock, sort_order)
where not exists (select 1 from public.products);

-- ---------------------------------------------------------------------
-- 9. TABLE PRIVILEGES (new Supabase projects don't auto-grant API access)
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- 10. AI CHAT TABLES
-- ---------------------------------------------------------------------
create table if not exists public.chat_sessions (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid references auth.users(id) on delete set null,
  lang       text not null default 'bn',
  created_at timestamptz not null default now(),
  last_at    timestamptz not null default now()
);

create table if not exists public.chat_messages (
  id         bigint generated always as identity primary key,
  session_id uuid not null references public.chat_sessions(id) on delete cascade,
  role       text not null check (role in ('user', 'assistant')),
  content    text not null,
  created_at timestamptz not null default now()
);

create index if not exists chat_messages_session_idx on public.chat_messages (session_id, id);
create index if not exists chat_messages_created_idx on public.chat_messages (created_at desc);
create index if not exists chat_sessions_last_idx    on public.chat_sessions (last_at desc);

alter table public.chat_sessions enable row level security;
alter table public.chat_messages enable row level security;

-- Visitors can NEVER read or write chats directly. Only the Edge Function
-- (service role) writes them. Staff with the 'orders' permission can read/delete.
drop policy if exists "chat_sessions_select" on public.chat_sessions;
drop policy if exists "chat_sessions_delete" on public.chat_sessions;
drop policy if exists "chat_messages_select" on public.chat_messages;
drop policy if exists "chat_messages_delete" on public.chat_messages;

create policy "chat_sessions_select" on public.chat_sessions for select to authenticated
  using (public.has_permission('orders'));
create policy "chat_sessions_delete" on public.chat_sessions for delete to authenticated
  using (public.has_permission('orders'));
create policy "chat_messages_select" on public.chat_messages for select to authenticated
  using (public.has_permission('orders'));
create policy "chat_messages_delete" on public.chat_messages for delete to authenticated
  using (public.has_permission('orders'));

grant select, delete on public.chat_sessions to authenticated;
grant select, delete on public.chat_messages to authenticated;

-- the Edge Function runs as service_role
grant all on public.chat_sessions  to service_role;
grant all on public.chat_messages  to service_role;
grant select on public.products, public.store_settings to service_role;
grant usage, select on all sequences in schema public to service_role;

notify pgrst, 'reload schema';

-- =====================================================================
--  FIRST SUPER ADMIN
--  1) Open your website and Sign Up with the owner's email.
--  2) Run this in the SQL Editor (replace the email if needed):
--
--  update public.profiles
--     set role = 'super_admin'
--   where email = 'farukahmedsujon112@gmail.com';
--
--  3) Sign out and sign in again, then open  https://YOUR-SITE/#admin
-- =====================================================================

-- =====================================================================
-- 11. NEW FEATURES (coupons, variants, reviews, stock, safe order function)
--     (same as supabase-features.sql — safe to run twice)
-- =====================================================================
-- ---------------------------------------------------------------------
-- 1. products / orders — নতুন কলাম
-- ---------------------------------------------------------------------
alter table public.products add column if not exists images   jsonb   not null default '[]'::jsonb;
alter table public.products add column if not exists variants jsonb   not null default '[]'::jsonb;
alter table public.products add column if not exists stock_qty integer;
alter table public.products add column if not exists is_combo boolean not null default false;
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
