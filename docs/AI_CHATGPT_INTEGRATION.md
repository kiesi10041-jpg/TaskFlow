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
