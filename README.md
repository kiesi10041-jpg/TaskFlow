# TaskFlow 2.0 — 다중 사업 과업관리

사업명 → 지원항목 → 세부과업 → 실행단계를 선으로 연결하는 웹 관리 도구입니다.

## 1. 사이트 공개 (GitHub Pages)
저장소 **Settings → Pages**로 이동한 후 **Build and deployment → Source: Deploy from a branch → Branch: main → /(root) → Save**를 선택합니다.
공개 주소: https://kiesi10041-jpg.github.io/TaskFlow/

> GitHub Pages 설정은 사용자가 GitHub에서 한 번 활성화해야 합니다. `index.html` 파일은 이미 저장소에 있습니다.

## 2. Supabase 데이터베이스 준비
[Supabase 대시보드](https://supabase.com/dashboard)에서 이 TaskFlow에 사용할 프로젝트를 연 뒤 왼쪽 **SQL Editor → New query**로 이동합니다.
저장소의 [supabase_setup.sql](./supabase_setup.sql) 파일 전체 내용을 붙여 넣고 **Run**을 실행합니다.
**Table Editor**에서 `public.taskflow_store` 테이블이 생성됐는지 확인합니다.

## 3. API 연결
Supabase **Project Settings → API Keys**에서 **publishable key**(`sb_publishable_...`)를 확인합니다. 프로젝트 URL은 Overview 또는 Connect에서 확인합니다.
TaskFlow 사이트 왼쪽 아래 **☁ 클라우드 저장 연동**을 열고 아래 항목을 입력합니다.
- 프로젝트 URL: `https://프로젝트참조.supabase.co`
- Publishable key (`sb_publishable_...`)
- 사용할 이메일 및 비밀번호

처음 사용하는 계정이면 **계정 등록**을 누릅니다. 이메일 인증을 요구하는 경우 메일 인증 후 **로그인**을 누릅니다. 이미 Auth에 계정이 있으면 **로그인**만 하세요.

**secret key(`sb_secret_...`), service_role 키를 입력하거나 저장소에 게시하지 마세요.**

## 4. 첫 동기화 및 다른 기기
1. 웹사이트에서 **JSON 백업**으로 파일을 하나 저장합니다.
2. Supabase 계정으로 로그인하고 **현재 데이터를 클라우드에 처음 저장할까요?** 확인창에서 동의합니다.
3. 사업 하나를 수정하고 왼쪽 아래 저장 상태가 **기기 + 클라우드 저장됨**인지 확인합니다.
4. 다른 기기에서 동일 URL과 publishable key로 같은 이메일에 로그인합니다. 클라우드의 기존 사업을 **불러오기**로 승인합니다.
5. 다른 기기에 기존 자료가 있다면 불러오기 전에 각각 JSON으로 백업합니다.

## 운영상 주의
- 이 시제품은 사용자별 하나의 JSON 문서로 사업 전체를 저장합니다. **한 번에 한 기기에서 수정**하세요. 여러 기기 동시 편집은 마지막 저장 내용으로 덮일 수 있습니다.
- 브라우저 저장은 보조 저장입니다. 수시로 JSON 백업을 내려받으세요.
- 저장이 실패하면 화면에서 **클라우드 오류**를 확인하고 Supabase **Table Editor**에서 해당 계정 행의 갱신시간을 확인하세요.
- GitHub Pages는 정적 웹사이트를 공개합니다. 로그인한 사용자의 사업 데이터는 Supabase의 RLS 정책으로 구분됩니다.
