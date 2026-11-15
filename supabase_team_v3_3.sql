-- TaskFlow 3.3: Per-task meeting minutes / work journal + follow-up schedule.
-- Apply AFTER 3.0 / 3.1 / 3.2 to the SAME Supabase project.
-- Does NOT drop/replace any existing project, task, profile or team records.
begin;

create table if not exists public.taskflow_activity_logs (
 id uuid primary key default gen_random_uuid(),
 project_id text not null references public.taskflow_projects(id) on delete cascade,
 node_id text not null references public.taskflow_nodes(id) on delete cascade,
 record_date date not null,
 record_time time,
 kind text not null default 'meeting' check (kind in ('meeting','internal','external','phone','message','site','memo','issue')),
 title text not null check (char_length(title) between 1 and 250),
 place text not null default '' check (char_length(place)<=200),
 attendees text not null default '' check (char_length(attendees)<=1500),
 content text not null default '' check (char_length(content)<=40000),
 decision text not null default '' check (char_length(decision)<=15000),
 followup text not null default '' check (char_length(followup)<=15000),
 followup_owner text not null default '' check (char_length(followup_owner)<=200),
 followup_due date,
 followup_status text not null default 'none' check (followup_status in ('none','pending','done')),
 needs_review boolean not null default false,
 created_by uuid not null references auth.users(id),
 updated_by uuid not null references auth.users(id),
 revision bigint not null default 1,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
-- Safe addition when upgrading a database where 3.3 was partially applied.
alter table public.taskflow_activity_logs
 add column if not exists followup_owner text not null default '';

create index if not exists tf_activity_project_date_idx
 on public.taskflow_activity_logs(project_id,record_date desc,created_at desc);
create index if not exists tf_activity_node_idx
 on public.taskflow_activity_logs(node_id,record_date desc);
create index if not exists tf_activity_followup_idx
 on public.taskflow_activity_logs(followup_due)
 where followup_status='pending';

create or replace function public.tf_can_edit_activity(p_node text)
returns boolean language sql stable security definer set search_path = ''
as $$
 select coalesce((
  select public.tf_can_edit_node(n.project_id,n.depth,n.category_id)
  from public.taskflow_nodes n where n.id=p_node
 ),false);
$$;
revoke all on function public.tf_can_edit_activity(text) from public;
grant execute on function public.tf_can_edit_activity(text) to authenticated;

create or replace function public.tf_activity_validate()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare v_node public.taskflow_nodes%rowtype;v_me uuid:=(select auth.uid());
begin
 if v_me is null then raise exception 'Authentication required'; end if;
 select * into v_node from public.taskflow_nodes where id=new.node_id;
 if not found or v_node.project_id<>new.project_id then
  raise exception 'Invalid task/project link';
 end if;
 if tg_op='UPDATE' then
  if new.id<>old.id or new.project_id<>old.project_id or
     new.node_id<>old.node_id or new.created_by<>old.created_by or
     new.created_at<>old.created_at then
   raise exception 'Task link and authorship cannot be changed';
  end if;
  new.revision=old.revision+1;
 else
  new.created_by=v_me;
  new.created_at=now();
  new.revision=1;
 end if;
 new.updated_by=v_me;
 new.updated_at=now();
 return new;
end $$;
drop trigger if exists tf_activity_validate_trg on public.taskflow_activity_logs;
create trigger tf_activity_validate_trg before insert or update
 on public.taskflow_activity_logs for each row
 execute function public.tf_activity_validate();

alter table public.taskflow_activity_logs enable row level security;
revoke all on public.taskflow_activity_logs from anon;
grant select,insert,update,delete on public.taskflow_activity_logs to authenticated;

drop policy if exists tf_activity_read on public.taskflow_activity_logs;
create policy tf_activity_read on public.taskflow_activity_logs for select to authenticated
 using(public.tf_can_view_project(project_id));
drop policy if exists tf_activity_add on public.taskflow_activity_logs;
create policy tf_activity_add on public.taskflow_activity_logs for insert to authenticated
 with check (
  public.tf_can_edit_activity(node_id)
  and exists(select 1 from public.taskflow_nodes
       where id=node_id and project_id=taskflow_activity_logs.project_id)
 );
drop policy if exists tf_activity_edit on public.taskflow_activity_logs;
create policy tf_activity_edit on public.taskflow_activity_logs for update to authenticated
 using(public.tf_can_edit_activity(node_id))
 with check(public.tf_can_edit_activity(node_id));
drop policy if exists tf_activity_delete on public.taskflow_activity_logs;
create policy tf_activity_delete on public.taskflow_activity_logs for delete to authenticated
 using(public.tf_can_edit_activity(node_id));

commit;
notify pgrst, 'reload schema';
