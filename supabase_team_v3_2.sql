-- TaskFlow 3.2: Fix workspace creation RLS for the existing founder account.
-- Execute ONCE in the SAME Supabase project used by TaskFlow.
-- Safe: no business/project/task tables are deleted; no user accounts modified.
-- If you already ran the 3.0 and 3.1 scripts, run only THIS file.
begin;

-- The founding user's Supabase Auth ID must match the existing
-- zotozo12@naver.com account. Email confirmation is not a prerequisite
-- when this Supabase project allows an authenticated login without it.
create or replace function public.tf_can_open_company()
returns boolean
language sql stable security definer set search_path = ''
as $$
 select (select auth.uid()) is not null
    and exists (
      select 1 from auth.users u
      where u.id = (select auth.uid())
        and lower(btrim(u.email)) = 'zotozo12@naver.com'
    )
    and not exists (
      select 1 from public.taskflow_workspaces w
      where w.created_by = (select auth.uid())
    );
$$;

revoke all on function public.tf_can_open_company() from public;
grant execute on function public.tf_can_open_company() to authenticated;

drop policy if exists tf_ws_create on public.taskflow_workspaces;
create policy tf_ws_create on public.taskflow_workspaces
for insert to authenticated
with check (
  created_by = (select auth.uid())
  and public.tf_can_open_company()
);

commit;
notify pgrst, 'reload schema';

-- Diagnostic output (SQL Editor): does the founder login exist
-- in THIS Supabase project, and has a workspace already been opened?
select
 case when exists(
   select 1 from auth.users
   where lower(btrim(email))='zotozo12@naver.com'
 ) then '관리자 계정 확인됨' else '관리자 계정 없음: Supabase 프로젝트 확인 필요' end as "관리자 계정",
 (select count(*) from public.taskflow_workspaces w
  join auth.users u on u.id=w.created_by
  where lower(btrim(u.email))='zotozo12@naver.com') as "이미 생성한 회사 공간 수",
 '이 파일을 실행한 후 TaskFlow로 돌아가 새로고침하고 설치 상태 확인을 누르세요.' as "다음 단계";
