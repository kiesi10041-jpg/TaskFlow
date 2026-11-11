-- TaskFlow 2 cloud storage (Supabase SQL Editor)
-- One record per authenticated user; the JSON holds that user's project hierarchy.
-- Run after creating your own Supabase project. Do NOT use service_role keys in browsers.

create table if not exists public.taskflow_store (
  user_id uuid primary key references auth.users(id) on delete cascade,
  data jsonb not null default '{"projects": []}'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.taskflow_store enable row level security;

revoke all on public.taskflow_store from anon;
revoke all on public.taskflow_store from authenticated;
grant select, insert, update on public.taskflow_store to authenticated;

create policy "taskflow_select_own" on public.taskflow_store
  for select to authenticated
  using ((select auth.uid()) = user_id);

create policy "taskflow_insert_own" on public.taskflow_store
  for insert to authenticated
  with check ((select auth.uid()) = user_id);

create policy "taskflow_update_own" on public.taskflow_store
  for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

-- user_id is the primary key and already has an index.
-- This starter schema isolates data by login account, not by team/project membership.