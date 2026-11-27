-- =====================================================================
-- SAR'S HOUSE — backup restore helper (run once in Supabase → SQL Editor)
-- Lets the Super Admin re-add MISSING orders / reviews / stock requests
-- from a backup file. It never overwrites or deletes existing rows.
-- (Needs supabase-security.sql to have been run first.)
-- =====================================================================
create or replace function public.restore_missing(p_table text, p_rows jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer; fixed jsonb;
begin
  if not public.is_super_admin() then raise exception 'forbidden'; end if;
  if p_table not in ('orders', 'reviews', 'stock_requests') then raise exception 'bad_table'; end if;
  if jsonb_typeof(p_rows) <> 'array' then raise exception 'bad_rows'; end if;
  -- a customer account that no longer exists must not block the restore
  select coalesce(jsonb_agg(case when (e->>'user_id') is not null
                                  and not exists (select 1 from auth.users u where u.id::text = e->>'user_id')
                             then e || '{"user_id": null}'::jsonb else e end), '[]'::jsonb)
    into fixed from jsonb_array_elements(p_rows) e;
  execute format('insert into public.%I select * from jsonb_populate_recordset(null::public.%I, $1) on conflict do nothing', p_table, p_table)
    using fixed;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.restore_missing(text, jsonb) from public, anon;
grant execute on function public.restore_missing(text, jsonb) to authenticated;
notify pgrst, 'reload schema';
