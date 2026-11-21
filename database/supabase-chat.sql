-- =====================================================================
--  SAR'S HOUSE — AI chat tables
--  Run ONCE in: Supabase Dashboard → SQL Editor → New query → Run
--  Safe to re-run.
-- =====================================================================

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
