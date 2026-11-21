-- =====================================================================
--  SAR'S HOUSE — Bilingual update (Bengali + English)
--  Run ONCE in: Supabase Dashboard → SQL Editor → New query → Run
--  (Needed only if you already ran supabase-setup.sql before.)
-- =====================================================================

-- 1) English name & description columns for products
alter table public.products add column if not exists name_en        text not null default '';
alter table public.products add column if not exists description_en text not null default '';

-- 2) English text for the 7 sample products (only where still empty)
update public.products set name_en = 'Pure Mustard Flower Honey',
  description_en = '100% pure honey collected straight from the hive.'
  where name = 'খাঁটি সরিষা ফুলের মধু' and name_en = '';

update public.products set name_en = 'Sundarbans Khalisha Flower Honey',
  description_en = 'Natural, adulteration-free Khalisha flower honey.'
  where name = 'সুন্দরবনের খলিসা ফুলের মধু' and name_en = '';

update public.products set name_en = 'Gawa Ghee',
  description_en = 'Aromatic gawa ghee made from pure milk cream.'
  where name = 'গাওয়া ঘি' and name_en = '';

update public.products set name_en = 'Cold-Pressed Mustard Oil',
  description_en = 'Pure mustard oil pressed in a traditional wooden ghani.'
  where name = 'ঘানি ভাঙা সরিষার তেল' and name_en = '';

update public.products set name_en = 'Ajwa Dates',
  description_en = 'Soft and delicious premium-quality Ajwa dates.'
  where name = 'আজওয়া খেজুর' and name_en = '';

update public.products set name_en = 'Cashew Nuts',
  description_en = 'Hand-picked crispy cashew nuts.'
  where name = 'কাজুবাদাম' and name_en = '';

update public.products set name_en = 'Black Cumin (Kalojira)',
  description_en = 'Clean, hand-picked black cumin seeds.'
  where name = 'কালোজিরা' and name_en = '';
