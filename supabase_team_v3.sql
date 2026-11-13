-- TaskFlow 3.0 company collaboration schema
-- Supabase Dashboard > SQL Editor > New query > paste all > Run
-- SAFE: does NOT drop or modify the old public.taskflow_store (legacy user JSON).
-- Backup your projects in TaskFlow before opting into team workspace import.
begin;

create table if not exists public.taskflow_workspaces (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 150),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);
create table if not exists public.taskflow_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default '',
  email text not null default '',
  updated_at timestamptz not null default now()
);
create table if not exists public.taskflow_workspace_members (
  workspace_id uuid not null references public.taskflow_workspaces(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('admin','lead','member')),
  joined_at timestamptz not null default now(),
  primary key (workspace_id,user_id)
);
create table if not exists public.taskflow_invites (
  token uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.taskflow_workspaces(id) on delete cascade,
  role text not null default 'member' check(role in ('lead','member')),
  created_by uuid not null references auth.users(id),
  expires_at timestamptz not null default (now()+interval '14 days'),
  uses integer not null default 0 check (uses >= 0),
  max_uses integer not null default 1 check (max_uses between 1 and 50),
  created_at timestamptz not null default now()
);
create table if not exists public.taskflow_projects (
  id text primary key check (char_length(id) between 2 and 100),
  workspace_id uuid not null references public.taskflow_workspaces(id) on delete cascade,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);
create table if not exists public.taskflow_project_members (
  project_id text not null references public.taskflow_projects(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  primary key (project_id,user_id)
);
create table if not exists public.taskflow_nodes (
  id text primary key check (char_length(id) between 2 and 100),
  project_id text not null references public.taskflow_projects(id) on delete cascade,
  parent_id text references public.taskflow_nodes(id) on delete cascade,
  depth integer not null default 0 check (depth between 0 and 25),
  category_id text,
  position integer not null default 0,
  payload jsonb not null default '{}'::jsonb check (jsonb_typeof(payload)='object'),
  revision bigint not null default 1,
  created_by uuid not null references auth.users(id),
  updated_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.taskflow_category_members (
  project_id text not null references public.taskflow_projects(id) on delete cascade,
  category_id text not null references public.taskflow_nodes(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  primary key(project_id,category_id,user_id)
);
create index if not exists taskflow_nodes_project_idx on public.taskflow_nodes(project_id,parent_id,position);
create index if not exists taskflow_project_members_user_idx on public.taskflow_project_members(user_id);
create index if not exists taskflow_category_members_user_idx on public.taskflow_category_members(user_id);
create index if not exists taskflow_project_workspace_idx on public.taskflow_projects(workspace_id);

-- Security-definer helpers prevent recursive RLS checks on membership tables.
create or replace function public.tf_workspace_role(p_workspace uuid)
returns text language sql stable security definer set search_path = ''
as $$ select role from public.taskflow_workspace_members where workspace_id = p_workspace and user_id = (select auth.uid()) limit 1 $$;

create or replace function public.tf_project_workspace(p_project text)
returns uuid language sql stable security definer set search_path = ''
as $$ select workspace_id from public.taskflow_projects where id=p_project limit 1 $$;

create or replace function public.tf_can_view_project(p_project text)
returns boolean language sql stable security definer set search_path = ''
as $$
select case
 when public.tf_workspace_role(public.tf_project_workspace(p_project)) in ('admin','lead') then true
 else exists(select 1 from public.taskflow_project_members where project_id=p_project and user_id=(select auth.uid()))
end
$$;

create or replace function public.tf_can_manage_project(p_project text)
returns boolean language sql stable security definer set search_path = ''
as $$ select coalesce(public.tf_workspace_role(public.tf_project_workspace(p_project)) in ('admin','lead'), false) $$;

create or replace function public.tf_can_edit_node(p_project text,p_depth integer,p_category text)
returns boolean language sql stable security definer set search_path = ''
as $$
select case
 when public.tf_can_manage_project(p_project) then true
 when p_depth < 2 or p_category is null then false
 else coalesce(public.tf_workspace_role(public.tf_project_workspace(p_project)) = 'member',false)
  and exists(select 1 from public.taskflow_project_members
             where project_id=p_project and user_id=(select auth.uid()))
  and exists(select 1 from public.taskflow_category_members
             where project_id=p_project and category_id=p_category and user_id=(select auth.uid()))
end
$$;

create or replace function public.tf_shared_workspace(p_other uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
select exists(select 1 from public.taskflow_workspace_members m1
 join public.taskflow_workspace_members m2 on m1.workspace_id=m2.workspace_id
 where m1.user_id=(select auth.uid()) and m2.user_id=p_other)
$$;

create or replace function public.tf_workspace_bootstrap()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
 insert into public.taskflow_workspace_members(workspace_id,user_id,role) values (new.id,new.created_by,'admin');
 return new;
end $$;
drop trigger if exists tf_workspace_bootstrap_trg on public.taskflow_workspaces;
create trigger tf_workspace_bootstrap_trg after insert on public.taskflow_workspaces
for each row execute function public.tf_workspace_bootstrap();

create or replace function public.tf_validate_node()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare par public.taskflow_nodes%rowtype;
begin
 if tg_op='UPDATE' then
  if new.id<>old.id or new.project_id<>old.project_id or new.created_by<>old.created_by then
   raise exception 'Cannot move a node between projects or change its ID';
  end if;
  new.created_at=old.created_at;
  new.revision=old.revision+1;
 else
  new.revision=1;
  new.created_by=(select auth.uid());
 end if;
 if new.parent_id is null then
  if new.id<>new.project_id then raise exception 'Project root node ID must equal project ID'; end if;
  new.depth=0;new.category_id=null;
 else
  select * into par from public.taskflow_nodes where id=new.parent_id;
  if not found or par.project_id<>new.project_id then raise exception 'Invalid parent or project'; end if;
  if par.id=new.id then raise exception 'Circular parent'; end if;
  new.depth=par.depth+1;
  if new.depth>25 then raise exception 'Maximum nesting depth exceeded'; end if;
  new.category_id=case when par.depth=0 then new.id else par.category_id end;
 end if;
 new.updated_by=(select auth.uid());
 new.updated_at=now();
 return new;
end $$;
drop trigger if exists tf_validate_node_trg on public.taskflow_nodes;
create trigger tf_validate_node_trg before insert or update on public.taskflow_nodes
for each row execute function public.tf_validate_node();

create or replace function public.tf_validate_category_assignment()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare p_workspace uuid;
begin
 if not exists (select 1 from public.taskflow_nodes
  where id=new.category_id and project_id=new.project_id and depth=1)
 then raise exception 'Only first-level project categories can be assigned'; end if;
 select workspace_id into p_workspace from public.taskflow_projects where id=new.project_id;
 if not exists(select 1 from public.taskflow_workspace_members
  where workspace_id=p_workspace and user_id=new.user_id)
 then raise exception 'User must belong to this workspace'; end if;
 insert into public.taskflow_project_members(project_id,user_id)
 values(new.project_id,new.user_id) on conflict do nothing;
 return new;
end $$;
drop trigger if exists tf_validate_category_assignment_trg on public.taskflow_category_members;
create trigger tf_validate_category_assignment_trg before insert on public.taskflow_category_members
for each row execute function public.tf_validate_category_assignment();

-- Accepting an invitation never requires giving the browser service_role credentials.
create or replace function public.tf_accept_invite(p_token uuid,p_name text default '')
returns uuid language plpgsql security definer set search_path = ''
as $$
declare inv public.taskflow_invites%rowtype; me uuid := (select auth.uid());
begin
 if me is null then raise exception 'Sign in first';end if;
 select * into inv from public.taskflow_invites where token=p_token for update;
 if not found or inv.expires_at<=now() or inv.uses>=inv.max_uses then
  raise exception 'Invitation is invalid, expired, or already used';
 end if;
 insert into public.taskflow_workspace_members(workspace_id,user_id,role)
 values(inv.workspace_id,me,inv.role)
 on conflict (workspace_id,user_id) do nothing;
 if not found then raise exception 'You already belong to this workspace';end if;
 update public.taskflow_invites set uses=uses+1 where token=p_token;
 insert into public.taskflow_profiles(user_id,display_name,email)
 values(me,left(trim(p_name),80),coalesce((select email from auth.users where id=me),''))
 on conflict(user_id) do update set display_name=case when excluded.display_name<>'' then excluded.display_name else public.taskflow_profiles.display_name end,updated_at=now();
 return inv.workspace_id;
end $$;

create or replace function public.tf_update_my_profile(p_name text)
returns void language plpgsql security definer set search_path = ''
as $$
declare me uuid := (select auth.uid());
begin
 if me is null then raise exception 'Sign in first';end if;
 insert into public.taskflow_profiles(user_id,display_name,email)
 values(me,left(trim(p_name),80),coalesce((select email from auth.users where id=me),''))
 on conflict(user_id) do update set display_name=excluded.display_name,email=excluded.email,updated_at=now();
end $$;

-- Enforce authentication, roles, and row access in the DATABASE (UI is not security).
alter table public.taskflow_workspaces enable row level security;
alter table public.taskflow_profiles enable row level security;
alter table public.taskflow_workspace_members enable row level security;
alter table public.taskflow_invites enable row level security;
alter table public.taskflow_projects enable row level security;
alter table public.taskflow_project_members enable row level security;
alter table public.taskflow_category_members enable row level security;
alter table public.taskflow_nodes enable row level security;

grant usage on schema public to authenticated;
grant select,insert,update on public.taskflow_workspaces to authenticated;
grant select,insert,update on public.taskflow_profiles to authenticated;
grant select on public.taskflow_workspace_members to authenticated;
grant select,insert,delete on public.taskflow_invites to authenticated;
grant select,insert,delete on public.taskflow_projects to authenticated;
grant select,insert,delete on public.taskflow_project_members to authenticated;
grant select,insert,delete on public.taskflow_category_members to authenticated;
grant select,insert,update,delete on public.taskflow_nodes to authenticated;

revoke all on public.taskflow_workspaces,public.taskflow_profiles,public.taskflow_workspace_members,
 public.taskflow_invites,public.taskflow_projects,public.taskflow_project_members,
 public.taskflow_category_members,public.taskflow_nodes from anon;

revoke all on function public.tf_accept_invite(uuid,text) from public;
revoke all on function public.tf_update_my_profile(text) from public;
revoke all on function public.tf_workspace_role(uuid) from public;
revoke all on function public.tf_project_workspace(text) from public;
revoke all on function public.tf_can_view_project(text) from public;
revoke all on function public.tf_can_manage_project(text) from public;
revoke all on function public.tf_can_edit_node(text,integer,text) from public;
revoke all on function public.tf_shared_workspace(uuid) from public;
grant execute on function public.tf_accept_invite(uuid,text),public.tf_update_my_profile(text),
 public.tf_workspace_role(uuid),public.tf_project_workspace(text),public.tf_can_view_project(text),
 public.tf_can_manage_project(text),public.tf_can_edit_node(text,integer,text),
 public.tf_shared_workspace(uuid) to authenticated;

drop policy if exists tf_ws_read on public.taskflow_workspaces;
create policy tf_ws_read on public.taskflow_workspaces for select to authenticated
using(public.tf_workspace_role(id) is not null);
drop policy if exists tf_ws_create on public.taskflow_workspaces;
create policy tf_ws_create on public.taskflow_workspaces for insert to authenticated
with check(created_by=(select auth.uid()));

drop policy if exists tf_profile_read on public.taskflow_profiles;
create policy tf_profile_read on public.taskflow_profiles for select to authenticated
using(user_id=(select auth.uid()) or public.tf_shared_workspace(user_id));
drop policy if exists tf_profile_self_insert on public.taskflow_profiles;
create policy tf_profile_self_insert on public.taskflow_profiles for insert to authenticated
with check(user_id=(select auth.uid()));
drop policy if exists tf_profile_self_edit on public.taskflow_profiles;
create policy tf_profile_self_edit on public.taskflow_profiles for update to authenticated
using(user_id=(select auth.uid())) with check(user_id=(select auth.uid()));

drop policy if exists tf_member_read on public.taskflow_workspace_members;
create policy tf_member_read on public.taskflow_workspace_members for select to authenticated
using(public.tf_workspace_role(workspace_id) is not null);

drop policy if exists tf_invite_read on public.taskflow_invites;
create policy tf_invite_read on public.taskflow_invites for select to authenticated
using(public.tf_workspace_role(workspace_id) in ('admin','lead'));
drop policy if exists tf_invite_insert on public.taskflow_invites;
create policy tf_invite_insert on public.taskflow_invites for insert to authenticated
with check(created_by=(select auth.uid()) and
 ((role='lead' and public.tf_workspace_role(workspace_id)='admin') or
  (role='member' and public.tf_workspace_role(workspace_id) in ('admin','lead'))));
drop policy if exists tf_invite_delete on public.taskflow_invites;
create policy tf_invite_delete on public.taskflow_invites for delete to authenticated
using(public.tf_workspace_role(workspace_id)='admin' or created_by=(select auth.uid()));

drop policy if exists tf_project_read on public.taskflow_projects;
create policy tf_project_read on public.taskflow_projects for select to authenticated
using(public.tf_can_view_project(id));
drop policy if exists tf_project_create on public.taskflow_projects;
create policy tf_project_create on public.taskflow_projects for insert to authenticated
with check(created_by=(select auth.uid()) and public.tf_workspace_role(workspace_id) in ('admin','lead'));
drop policy if exists tf_project_delete on public.taskflow_projects;
create policy tf_project_delete on public.taskflow_projects for delete to authenticated
using(public.tf_can_manage_project(id));

drop policy if exists tf_project_member_read on public.taskflow_project_members;
create policy tf_project_member_read on public.taskflow_project_members for select to authenticated
using(public.tf_can_view_project(project_id));
drop policy if exists tf_project_member_insert on public.taskflow_project_members;
create policy tf_project_member_insert on public.taskflow_project_members for insert to authenticated
with check(public.tf_can_manage_project(project_id) and
 exists(select 1 from public.taskflow_workspace_members
  where workspace_id=public.tf_project_workspace(project_id) and user_id=taskflow_project_members.user_id));
drop policy if exists tf_project_member_delete on public.taskflow_project_members;
create policy tf_project_member_delete on public.taskflow_project_members for delete to authenticated
using(public.tf_can_manage_project(project_id));

drop policy if exists tf_category_member_read on public.taskflow_category_members;
create policy tf_category_member_read on public.taskflow_category_members for select to authenticated
using(public.tf_can_view_project(project_id));
drop policy if exists tf_category_member_insert on public.taskflow_category_members;
create policy tf_category_member_insert on public.taskflow_category_members for insert to authenticated
with check(public.tf_can_manage_project(project_id));
drop policy if exists tf_category_member_delete on public.taskflow_category_members;
create policy tf_category_member_delete on public.taskflow_category_members for delete to authenticated
using(public.tf_can_manage_project(project_id));

drop policy if exists tf_node_read on public.taskflow_nodes;
create policy tf_node_read on public.taskflow_nodes for select to authenticated
using(public.tf_can_view_project(project_id));
drop policy if exists tf_node_insert on public.taskflow_nodes;
create policy tf_node_insert on public.taskflow_nodes for insert to authenticated
with check(public.tf_can_edit_node(project_id,depth,category_id));
drop policy if exists tf_node_update on public.taskflow_nodes;
create policy tf_node_update on public.taskflow_nodes for update to authenticated
using(public.tf_can_edit_node(project_id,depth,category_id))
with check(public.tf_can_edit_node(project_id,depth,category_id));
drop policy if exists tf_node_delete on public.taskflow_nodes;
create policy tf_node_delete on public.taskflow_nodes for delete to authenticated
using(public.tf_can_edit_node(project_id,depth,category_id));

commit;
