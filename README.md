# sars-house
SAR'S HOUSE

## নতুন ফিচার (v2)
`database/supabase-features.sql` চালালে চালু হয়: কুপন, ওজন অনুযায়ী দাম, একাধিক ছবি, স্টক সংখ্যা, কম্বো প্যাক, রিভিউ, "স্টকে এলে জানান", নিরাপদ সার্ভার-সাইড অর্ডার ফাংশন (`place_order`)।
নতুন ইনস্টলে `supabase-setup.sql`-এ এগুলো আগে থেকেই আছে। এরপর `supabase/functions/chat/index.ts` আবার Deploy করুন।


## v3 — হোম সেকশন, ভাসমান কার্ট, চেকআউট
- ক্যাটেগরি অনুযায়ী হোম সেকশন + "বেশি বিক্রিত" (পণ্য সম্পাদনায় সুইচ; `database/supabase-best-selling.sql` একবার চালাতে হবে)
- ভাসমান কার্ট বাটন, কার্টে "এটাও কিনতে পারেন", লগইন হিন্ট, শর্তাবলীর টিক, পেমেন্ট পদ্ধতি (ক্যাশ অন ডেলিভারি / WhatsApp-এ কথা বলে বিকাশ-নগদ)
- চ্যাট টিজার বাবল (অ্যাডমিন → চ্যাট সেটিংস থেকে সম্পাদনযোগ্য)

## Security pack (v4)
Run `database/supabase-security.sql` once in Supabase → SQL Editor. It adds: server-side enforcement of two-step login for admins who enabled it, order/stock-request spam brakes (`rate_limit`), and an admin activity log with "restore product". In the admin panel: Settings → "২-ধাপ নিরাপত্তা" and "কাজের লগ".
If you lose your authenticator phone: Supabase Dashboard → Authentication → Users → your user → delete the factor.

## Panel entry lock (v5)
Settings → "২-ধাপ নিরাপত্তা" → "প্যানেলে ঢোকার তালা": set a 4–6 digit PIN, optionally enable fingerprint (WebAuthn platform authenticator). Stored per device in localStorage; locks on reload / idle. Client-side gate only — real protection stays Supabase login + 2-step.

## Hide products (v6)
Run `database/supabase-hide-products.sql` once (after `supabase-security.sql`), then redeploy the `chat` Edge Function. In Admin → Products, the eye button hides/shows a product; only hidden products show the permanent-delete button.
