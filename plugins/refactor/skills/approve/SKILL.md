---
name: approve
description: 리팩토링 계획서의 단계(또는 기준선 계획)를 사용자가 승인하거나 승인을 취소하고, 리팩토링을 마무리(DONE)하거나 손으로 고친 승인 기록을 다시 확인(봉인)한다. 사용자만 실행할 수 있다. 인자 없이 실행하면 승인 현황만 보여 준다.
disable-model-invocation: true
argument-hint: "[P0-1 P1-2 | P1 | baseline | 보류 P1-2 | 마무리 | 확인 | 비움=현황]"
allowed-tools: Bash(bash *run.sh*refactor-approve*)
disallowed-tools: Write, Edit, NotebookEdit
---

# 승인 처리 결과

**승인의 실제 결과는 같은 턴에 입력 훅이 넣은 `[Vibe Refactor 승인 처리 결과 — 입력 훅]` 블록이다.** 사용자가 입력창에 `/refactor:approve` 를 치면 입력 훅이 승인 스크립트를 실행해 `APPROVALS.log`에 단계 ID와 카드 지문(그 순간의 카드 내용)을 기록하고 계획서의 승인 칸·STATE를 바꾼다. 그 블록을 기준으로 사용자에게 3~6줄로 전한다. 승인 뒤 카드 내용이 바뀌면 그 승인은 풀린다는 것을 한 줄로 알려 준다.

아래 `!` 출력은 처리 전 현황일 수 있다(스킬의 명령은 입력 훅보다 먼저 돌고, 아무것도 바꾸지 않는다). **그 블록이 없으면 안전장치 훅이 꺼졌거나 시간 안에 끝나지 못한 것이다 — 승인됐다고도, 안 됐다고도 단정하지 말고, `/refactor:approve`(인자 없이)로 현황을 다시 확인하고 `/hooks` 에서 refactor 훅을 확인하라고 안내한다.**

```!
bash "${CLAUDE_SKILL_DIR}/../../hooks/run.sh" refactor-approve "${CLAUDE_PROJECT_DIR}" <<'VIBE_REFACTOR_ARGS'
$ARGUMENTS
VIBE_REFACTOR_ARGS
```

## 너의 할 일 (짧게)

1. 입력 훅 블록의 결과를 비개발자가 알아듣게 3~6줄로 전한다: 무엇이 승인·취소됐는지, 다음에 입력할 명령.
   - 마무리 결과를 전할 때 "안전장치가 모두 꺼집니다(비밀값·되돌릴 수 없는 명령 보호 포함)"는 줄이지 말고 그대로 전한다.
2. **👤 사람이 직접 할 일**이 "없음"이 아닌 단계가 있으면 맨 위에 굵게 적는다. 그중 단계 실행 **전에** 끝나야 하는 것(예: 결제사 테스트 키 발급, DB 백업 확인, 비공개 저장소 만들기)은 "이것부터 해 주세요"라고 먼저 말한다.
3. 다음 명령 안내:
   - 실행 대기(승인됨) 단계가 있으면 → `/refactor:go` (한 번에 한 단계씩 실행하고 멈춘다)
   - 기준선 계획을 승인했으면 → `/refactor:go` (기준선 테스트를 만든다)
   - 승인 대기만 남았으면 → 계획서 `docs/refactor/REFACTOR_PLAN.md`를 보고 `/refactor:approve <단계ID>`
4. 결과에 ❓가 있으면 무엇이 문제인지 쉽게 설명하고 올바른 입력 예를 하나 보여 준다.
5. **이번 답변에서는 아무 파일도 고치지 말고, 단계 실행도 시작하지 마라.** 실행은 사용자가 `/refactor:go`를 입력할 때 한다.
