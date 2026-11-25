# TaskFlow ↔ ChatGPT 직접 등록 운영 가이드

## 연결 확인 (2026-11-25)
- Supabase 연결 계정 별명: Supabase (별도 연결)
- 실제 TaskFlow 프로젝트: `obqzskfcuubfpgpcfiey` (kiesi10041-jpg's Project)
- 작업공간: `78fc5c2e-ba57-4f5c-8a33-b9d14c401c7b` (한국온라인창업컨설팅)
- ChatGPT가 Supabase 도구로 실제 DB를 조회할 수 있음
- 기존 사업 10개, 노드 191개, 업무기록 2개 확인
- 기존 테이블/RLS 정책과 GitHub Pages의 화면·저장 로직은 변경하지 않음

## 구현 상태
Supabase 마이그레이션 `taskflow_ai_private_blueprint_import` 적용됨.
비공개 스키마 `taskflow_ai_private`에 추가된 함수:
- `taskflow_ai_private.apply_blueprint(uuid,jsonb,text,text,boolean)`
- `taskflow_ai_private.add_children(text,text,jsonb)` (내부 재귀 병합)

스키마와 함수 모두 `anon`, `authenticated`, `service_role` 접근 불가 확인. 관리용 연결의 `postgres` 역할로만 사용.
기존 TaskFlow DB 트리거를 그대로 이용해 노드 깊이/카테고리/변경 시각을 계산함.
동일 부모 아래 같은 제목의 노드는 변경하지 않고 그 아래 신규 하위 항목만 재귀 추가.
실제 등록 시 기존 관리자 계정 UID가 created_by/updated_by로 기록됨. **전용 AI 직원 계정이 생성된 것은 아님.**

## 사용 예시
1. 사용자가 공고문과 기업 자료를 ChatGPT에 전달
2. ChatGPT가 근거를 분석해 `project` JSON을 생성하고 제출서류·기한을 교차 검토
3. 먼저 `p_dry_run=true`로 미리보기/검증만 실행
4. 사용자의 프로젝트 등록 요청을 확인한 경우 `p_dry_run=false` 실행
5. 반환 project_id와 삽입 항목 수를 확인하고 DB에서 다시 조회
6. 기존 사업 추가는 `p_mode='extend'`, 대상 `p_target_project`를 정확히 지정

### 신규 프로젝트 예시 (미리보기)
```sql
select taskflow_ai_private.apply_blueprint(
 '78fc5c2e-ba57-4f5c-8a33-b9d14c401c7b'::uuid,
 '{"project":{"title":"사업명","client":"신청기업","children":[{"title":"사업신청","children":[{"title":"공고문 확인"},{"title":"사업계획서 작성"}]}]}}'::jsonb,
 'new',null,true
);
```

### 기존 프로젝트 확장 예시 (미리보기)
```sql
select taskflow_ai_private.apply_blueprint(
 '78fc5c2e-ba57-4f5c-8a33-b9d14c401c7b'::uuid,
 '{"children":[{"title":"사업수행","children":[{"title":"사업계획서에 명시된 실제 수행과업"}]}]}'::jsonb,
 'extend','정확한_기존_프로젝트_ID',true
);
```

실제 저장은 마지막 인자 `true`를 `false`로 변경한다. **테스트 용도로 실제 DB를 오염시키지 말 것.**

## 지원 JSON 속성
- 최상위: `project.title`, `client`, `businessYear`, `deadline`, `contractDate`, `note`, `projectManager`, `businessContact`, `businessPhone`, `children`.
- 과업: `title`, `note`, `due` (검증된 YYYY-MM-DD), `children`.
- 상태 `todo`, 담당자 미배정으로 생성.
- 한 번에 과업 140개, 최대 깊이 15단계, JSON 350KB. 동명 신규 프로젝트 방지.
- 기존 프로젝트, 완료 상태, 과업 기록, 구성원 접근권한 등은 초기화·삭제·덮어쓰지 않음.

## 검증 결과
- `p_dry_run=true` 미리보기 성공: 3개 과업 산출
- 신규 사업 생성 `BEGIN ... ROLLBACK` 테스트 성공: 5개 과업 추가 후 롤백
- 기존 사업 확장 `BEGIN ... ROLLBACK` 테스트 성공: 2개 과업 추가 후 롤백
- 최종 검증: 프로젝트 10개·과업 191개·테스트 잔여 항목 0개
- 운영용 실데이터는 사용자 지시 전 등록하지 않음.

## 주의
- 이 경로는 ChatGPT에 연결된 Supabase 관리 도구를 통해 SQL 함수 호출하는 방식. **일반 직원용 공개 REST API 또는 범용 ChatGPT 외부 플러그인은 아님.**
- 문서 분석 및 과업 구체화는 ChatGPT에서 수행. 공고문/협약서에 없는 제출 서류와 기한은 사실처럼 만들지 않는다.
- 다른 연결 계정(`cozy-repair-demo`)을 실수로 선택하지 말 것.
- 중요: RLS를 우회하거나 관리자 비밀번호/API 비밀키를 클라이언트 또는 GitHub에 기록하지 않는다.


## 신청·수행 프로젝트 분리 및 링크 (2026-11-25 추가)

### 구조 규칙
- **지원사업 신청**: `projectKind = "application"`. 공고문 분석, 신청자격, 기업정보 및 제출서류, 사업계획서, 접수·선정 여부까지 관리.
- **선정사업 수행**: `projectKind = "execution"`. 협약·수행계획서와 실제 확정 과업, 산출물, 중간보고, 최종보고, 정산을 **별도 프로젝트**에서 관리.
- **일반 사업/용역**: `projectKind = "other"`.
- 기존에 `projectKind` 필드가 없는 프로젝트는 **미분류**로 표시하고 자동으로 분류하지 않는다.
- 수행 프로젝트의 루트 `payload.sourceApplicationId`에 원 신청 프로젝트의 ID를 지정한다. 원 신청 프로젝트는 **연결된 수행 프로젝트를 역방향 조회**하여 표시한다.
- 중간보고·최종보고 등 신청/수행 업무를 하나의 구조도에 섞지 않는다. 각 프로젝트의 완료율·회의록·기한·담당자·과업은 독립.
- 신청사업에서 **선정 후 수행사업 생성**을 누르면 제목·기업명·사업연도를 미리 채운 빈 수행 프로젝트 등록창이 열린다. 신청 항목은 자동 복제하지 않는다.
- 수행 프로젝트 이름과 기업명이 신청 프로젝트와 같아도 **서로 다른 유형**으로 등록 가능하다. 동일 유형·동일 이름·동일 기업명의 중복은 별도로 확인한다.
- 연결된 수행사업이 있으면 원 신청사업을 삭제하거나 다른 종류로 변경하기 전에 수행사업의 원 신청사업 연결을 해제해야 한다.

### ChatGPT가 Supabase에 직접 등록할 때

새 프로젝트는 **구형** `taskflow_ai_private.apply_blueprint` 대신
`taskflow_ai_private.apply_blueprint_linked(uuid,jsonb,text,text,text,text,boolean)`
을 사용한다. 기존 함수는 변경하지 않았으므로 등록 중인 다른 AI 작업과 충돌하지 않는다.

1. TaskFlow 실사용 Supabase 프로젝트 `obqzskfcuubfpgpcfiey`와 작업공간 `78fc5c2e-ba57-4f5c-8a33-b9d14c401c7b` 확인.
2. 지원사업의 원문 공고문과 기업 신청자료에서만 신청 과업 생성.
3. `p_kind='application'`, `p_mode='new'`, `p_dry_run=true`로 미리보기 실행.
4. 사용자의 등록 지시가 있고 사업명·기업·서류·일정이 확인되면 `p_dry_run=false`로 실제 저장.
5. 선정 확정 후 수행계획서를 근거로 새로운 JSON 생성. `p_kind='execution'`, `p_source_application='<정확한 신청 프로젝트 ID>'`로 별도 수행사업 등록.
6. 기존 신청 또는 수행 프로젝트의 **같은 단계 안**에 새 하위 업무를 추가할 때만 `p_mode='extend'`, `p_target_project='<정확한 해당 사업 ID>'` 사용.
7. 반환된 프로젝트 ID와 실제 루트 `payload.projectKind`, `payload.sourceApplicationId`를 재조회해 검증.

### 예시: 수행 프로젝트를 신청 프로젝트와 연결 (먼저 미리보기)

```sql
select taskflow_ai_private.apply_blueprint_linked(
 '78fc5c2e-ba57-4f5c-8a33-b9d14c401c7b'::uuid,
 '{"project":{"title":"지원사업명","client":"A기업",
 "children":[{"title":"실제 수행과업","children":[{"title":"협약서 기준 업무"}]}]}}'::jsonb,
 'new',null,'execution','이미_확인된_신청_프로젝트_ID',true
);
```

`true`는 미리보기이며 기존 데이터를 변경하지 않는다. 실제 저장은 동일 정보를 검토한 다음 마지막 값을 `false`로 바꿔 실행한다.

### 등록이 이미 진행되거나 끝난 프로젝트의 유형 분류

기존 프로젝트를 일괄 분류하지 않는다. 사업이 확정된 후 정확한 프로젝트 ID를 조회하고 사용자 지시에 따라 단건으로:

`taskflow_ai_private.set_project_kind(uuid,text,text,text)`

함수를 호출해 `application` 또는 `execution`을 등록한다. 마지막 인자는 수행사업에 연결할 원 신청 프로젝트 ID이며, 신청 또는 일반 사업은 `null`이다. 이 작업은 **프로젝트 루트의 유형/링크 필드만** 수정하며 하위 과업·회의록·담당자·상태는 수정하지 않는다.

### 검증 및 안전성

- 기존 저장 함수는 수정하지 않고 **새 private 함수** 추가.
- `postgres` 관리 연결만 실행 가능; `anon`, `authenticated`, `service_role` 함수 실행 권한 차단.
- 같은 제목·기업명으로 신청 1개와 수행 1개를 만들고 링크하는 SQL 테스트 통과; **BEGIN/ROLLBACK**으로 취소.
- 미분류 프로젝트를 기존 ID로 신청 유형 지정하는 SQL 테스트 통과; **BEGIN/ROLLBACK**으로 취소.
- 신규 레이아웃은 GitHub Pages 코드에 추가했으며 실제 사용자별 브라우저 동작 테스트는 별도 확인이 필요하다.
- 다른 AI가 프로젝트를 등록하는 동안 **기존 DB 사업 데이터는 일괄 수정하거나 자동 분류하지 않는다.**
