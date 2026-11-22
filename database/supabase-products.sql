-- =====================================================================
--  SAR'S HOUSE — load the real product list + new categories
--  Run ONCE in: Supabase Dashboard → SQL Editor → New query → Run
--
--  What it does
--    1) deletes the 7 demo products (only those exact demo names)
--    2) adds your 17 products, grouped into 4 categories (price = 0 for now)
--    3) sets the 4 category names (this REPLACES your current category list)
--  Prices are 0 on purpose: the site shows "দাম জানতে মেসেজ করুন" until you set
--  each price in  কন্ট্রোল প্যানেল → পণ্য.
--  Safe to re-run: products that already exist (same name) are not added twice.
-- =====================================================================

-- 1) demo products out
delete from public.products where name in ('খাঁটি সরিষা ফুলের মধু', 'সুন্দরবনের খলিসা ফুলের মধু', 'গাওয়া ঘি', 'ঘানি ভাঙা সরিষার তেল', 'আজওয়া খেজুর', 'কাজুবাদাম', 'কালোজিরা');

-- 2) real products in
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
where not exists (select 1 from public.products p where p.name = v.name);

-- 3) categories (editable later in the Admin panel → ডিজাইন ও থিম → ক্যাটেগরি ব্যবস্থাপনা)
insert into public.store_settings (key, value)
values ('design', jsonb_build_object('categories', '[{"id": "c1", "name": "মধু", "name_en": "Honey", "icon": "fa-droplet", "image": ""}, {"id": "c2", "name": "ঘি ও তেল", "name_en": "Ghee & Oil", "icon": "fa-bottle-droplet", "image": ""}, {"id": "c3", "name": "দই ও দুগ্ধজাত", "name_en": "Yogurt & Dairy", "icon": "fa-bowl-food", "image": ""}, {"id": "c4", "name": "ড্রাই ফ্রুটস ও বাদাম", "name_en": "Dry Fruits & Nuts", "icon": "fa-seedling", "image": ""}]'::jsonb))
on conflict (key) do update
  set value = (public.store_settings.value - 'cat_images')
              || jsonb_build_object('categories', excluded.value -> 'categories'),
      updated_at = now();
