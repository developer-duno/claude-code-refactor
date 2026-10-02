---
name: status
description: 이 프로젝트의 리팩토링 진행 현황(지금 단계, 승인 대기, 실행 대기, 사람이 할 일, 다음 명령)을 보여 준다. 파일은 고치지 않는다. 사용자가 "리팩토링 어디까지 했어?", "다음에 뭐 하면 돼?"라고 물을 때도 쓴다.
allowed-tools: Bash(bash *run.sh*refactor-status*)
---

# 리팩토링 현황

```!
bash "${CLAUDE_SKILL_DIR}/../../hooks/run.sh" refactor-status "${CLAUDE_PROJECT_DIR}"
```

## 너의 할 일 (읽기만)

위 내용을 비개발자에게 아래 형식으로 짧게 전한다. 긴 표를 다시 붙이지 않는다.

```
📍 지금: <단계 이름을 쉬운 말로> (<phase>)
✅ 끝난 것: <최근 단계 기록 1~2줄 요약>
🙋 사장님 차례: <승인 대기·질문이 있으면 무엇을 입력하면 되는지 — 없으면 생략>
▶ 다음 명령: <예: /refactor:go 또는 /refactor:approve P1-2>
⚠️ 주의: <허용 파일이 남아 있음, 14일 넘게 멈춤, 커밋 안 된 변경이 많음 등 — 없으면 생략>
```

- 단계 이름 쉬운 말: SETUP 준비 · MAP 코드 지도 · CHECKUP 건강검진 · DEEP 정밀검사 · VERIFY 반박 검증 · BASELINE_PLAN 기준선 계획(승인 대기) · BASELINE 기준선 작성 · PLAN 계획서(승인 대기) · EXECUTE 단계 실행 · DONE 완료
- 결과가 `NO_STATE`로 시작하면: "아직 시작하지 않았어요. `/refactor:go`로 시작하면 준비 질문부터 합니다. 안전장치는 `/refactor:go` 로 리팩토링을 시작하면 켜집니다." 두 문장만.
- 커밋 안 된 변경이 있으면 "다음 단계 전에 커밋해 두면 되돌리기 쉬워요"를 덧붙인다(커밋은 사람이).
- 파일을 고치거나 다른 명령을 실행하지 않는다.
