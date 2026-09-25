---
name: board
description: 여러 프로젝트의 리팩토링 현황표를 만든다. 프로젝트들이 모인 상위 폴더 아래의 docs/refactor/STATE.md를 모아 급한 순서로 보여 주고, 이번 주에 먼저 할 일 3개를 고른다. 파일은 고치지 않는다.
argument-hint: "[프로젝트들이 모인 폴더 — 비우면 이 프로젝트의 상위 폴더]"
allowed-tools: Bash(bash *run.sh*refactor-board*)
---

# 여러 프로젝트 리팩토링 현황표

```!
bash "${CLAUDE_SKILL_DIR}/../../hooks/run.sh" refactor-board "${CLAUDE_PROJECT_DIR}" <<'VIBE_REFACTOR_ARGS'
$ARGUMENTS
VIBE_REFACTOR_ARGS
```

## 너의 할 일 (읽기만)

1. 위 표를 그대로 보여 준다(표는 이미 급한 순서로 정렬돼 있다).
2. 표 아래에 **이번 주 먼저 할 일 3개**를 고른다. 순서: 🔴 급한 구멍이 있는 프로젝트 → 🙋 사장님 차례(승인·답변만 하면 진행되는 것 — 5분짜리 일) → ▶ 다음 단계 실행 가능 → ⏰ 오래 멈춘 것. 항목마다 "어느 프로젝트 폴더에서 무엇을 입력하면 되는지"를 한 줄로.
   - 예: `flower-shop` 폴더에서 Claude를 열고 `/refactor:status` → 🔴 내용 확인
3. "아직 시작 안 한 프로젝트"가 있으면, 돈·개인정보를 다루는 프로젝트부터 `/refactor:go`로 시작하길 권한다(어느 것이 그런지는 모르면 사용자에게 묻는다).
4. 표를 찾지 못했으면 프로젝트들이 모여 있는 폴더 경로를 알려 달라고 하고 예를 준다: `/refactor:board ~/projects`
5. 다른 프로젝트의 파일을 열거나 고치지 않는다. 이 표는 각 프로젝트의 STATE.md 요약칸만 읽은 것이다.
