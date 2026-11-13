-- TaskFlow 3.1: founder-only workspace bootstrap, private admin handover,
-- staff department/position, and server-side task audit metadata.
-- Apply AFTER supabase_team_v3.sql to the SAME existing Supabase project.
-- Safe rerun: preserves all existing users, projects and taskflow_store records.
begin;

alter table public.taskflow_profiles
  add column if not exists department text not null default '';
alter table public.taskflow_profiles
  add column if not exists job_title text not null default '';

-- Admin bootstrap is limited to the agreed founding account. SQL/RLS,
-- not hidden buttons, enforce this. A successor is made admin by handover RPC.
create or replace function public.tf_can_open_company()
returns boolean language sql stable security definer set search_path = ''
as $$
 select exists (
   select 1 from auth.users u
   where u.id = (select auth.uid())
     and lower(u.email) = 'zotozo12@naver.com'
     and u.email_confirmed_at is not null
 ) and not exists (
   select 1 from public.taskflow_workspaces w
   where w.created_by=(select auth.uid())
 );
$$;
revoke all on function public.tf_can_open_company() from public;
grant execute on function public.tf_can_open_company() to authenticated;
drop policy if exists tf_ws_create on public.taskflow_workspaces;
create policy tf_ws_create on public.taskflow_workspaces for insert to authenticated
with check (created_by=(select auth.uid()) and public.tf_can_open_company());

create table if not exists public.taskflow_admin_transfers (
 id uuid primary key default gen_random_uuid(),
 workspace_id uuid not null references public.taskflow_workspaces(id) on delete cascade,
 from_user uuid not null references auth.users(id),
 to_user uuid not null references auth.users(id),
 status text not null default 'pending'
   check (status in ('pending','accepted','cancelled','expired')),
 created_at timestamptz not null default now(),
 expires_at timestamptz not null default (now()+interval '7 days'),
 responded_at timestamptz,
 check(from_user<>to_user)
);
create index if not exists tf_admin_transfer_workspace_idx
 on public.taskflow_admin_transfers(workspace_id,status);
create unique index if not exists tf_admin_transfer_one_pending
 on public.taskflow_admin_transfers(workspace_id) where status='pending';
alter table public.taskflow_admin_transfers enable row level security;
revoke all on public.taskflow_admin_transfers from anon;
revoke all on public.taskflow_admin_transfers from authenticated;
grant select on public.taskflow_admin_transfers to authenticated;
drop policy if exists tf_transfer_private_read on public.taskflow_admin_transfers;
create policy tf_transfer_private_read on public.taskflow_admin_transfers
 for select to authenticated
 using((select auth.uid())=from_user or (select auth.uid())=to_user);

create or replace function public.tf_propose_admin_transfer(p_workspace uuid,p_to_user uuid)
returns uuid language plpgsql security definer set search_path=''
as $$
declare v_me uuid:=(select auth.uid());v_id uuid;
begin
 if v_me is null or public.tf_workspace_role(p_workspace)<>'admin' then
   raise exception 'Only the current administrator can initiate transfer';
 end if;
 if p_to_user=v_me then raise exception 'Choose another member'; end if;
 if not exists(select 1 from public.taskflow_workspace_members
    where workspace_id=p_workspace and user_id=p_to_user) then
   raise exception 'Successor must already be a member of the same workspace';
 end if;
 -- expire previous pending requests instead of leaving workspace permanently locked.
 update public.taskflow_admin_transfers
 set status='expired',responded_at=now()
 where workspace_id=p_workspace and status='pending' and expires_at<=now();
 if exists(select 1 from public.taskflow_admin_transfers
     where workspace_id=p_workspace and status='pending') then
   raise exception 'A transfer is already awaiting successor approval';
 end if;
 insert into public.taskflow_admin_transfers(workspace_id,from_user,to_user)
 values(p_workspace,v_me,p_to_user) returning id into v_id;
 return v_id;
end $$;

create or replace function public.tf_accept_admin_transfer(p_transfer uuid)
returns void language plpgsql security definer set search_path=''
as $$
declare tr public.taskflow_admin_transfers%rowtype;v_me uuid:=(select auth.uid());
begin
 if v_me is null then raise exception 'Log in first';end if;
 select * into tr from public.taskflow_admin_transfers where id=p_transfer for update;
 if not found or tr.to_user<>v_me then raise exception 'Not the nominated successor';end if;
 if tr.status<>'pending' or tr.expires_at<=now() then
   raise exception 'Transfer is not pending or has expired';
 end if;
 if not exists(select 1 from public.taskflow_workspace_members
    where workspace_id=tr.workspace_id and user_id=tr.from_user and role='admin') then
   raise exception 'Current administrator status changed';
 end if;
 if not exists(select 1 from public.taskflow_workspace_members
    where workspace_id=tr.workspace_id and user_id=tr.to_user) then
   raise exception 'Successor is no longer a company member';
 end if;
 -- The departing admin loses company-wide access; without explicit project
 -- membership they can no longer view projects. The successor gains all.
 update public.taskflow_workspace_members set role='admin'
   where workspace_id=tr.workspace_id and user_id=tr.to_user;
 update public.taskflow_workspace_members set role='member'
   where workspace_id=tr.workspace_id and user_id=tr.from_user;
 update public.taskflow_admin_transfers set status='accepted',responded_at=now()
   where id=p_transfer;
end $$;

create or replace function public.tf_cancel_admin_transfer(p_transfer uuid)
returns void language plpgsql security definer set search_path=''
as $$
declare tr public.taskflow_admin_transfers%rowtype;v_me uuid:=(select auth.uid());
begin
 select * into tr from public.taskflow_admin_transfers where id=p_transfer for update;
 if not found or tr.from_user<>v_me or tr.status<>'pending' then
   raise exception 'Only the initiating administrator can cancel a pending transfer';
 end if;
 update public.taskflow_admin_transfers set status='cancelled',responded_at=now()
 where id=p_transfer;
end $$;

revoke all on function public.tf_propose_admin_transfer(uuid,uuid) from public;
revoke all on function public.tf_accept_admin_transfer(uuid) from public;
revoke all on function public.tf_cancel_admin_transfer(uuid) from public;
grant execute on function public.tf_propose_admin_transfer(uuid,uuid),
 public.tf_accept_admin_transfer(uuid),public.tf_cancel_admin_transfer(uuid)
 to authenticated;

commit;
notify pgrst, 'reload schema';
