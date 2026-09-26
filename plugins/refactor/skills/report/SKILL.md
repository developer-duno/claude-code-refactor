---
name: report
description: 문제 신고 — 플러그인 버전·환경·최근 문제 기록(비밀값 가림)과 사용자 설명으로 진단 묶음을 만들어 먼저 보여 주고, 사용자가 동의하면 GitHub 이슈로 보낸다. 사용자만 실행할 수 있다.
disable-model-invocation: true
argument-hint: "[문제 설명 한 줄]"
allowed-tools: Bash(bash *run.sh*refactor-report*)
disallowed-tools: Write, Edit, NotebookEdit
---

# 문제 신고 묶음

아래는 진단 묶음이다. **아직 아무 데도 보내지 않았다.** 비밀값 모양(KEY=값·토큰·주소 속 비밀번호)과 홈 폴더 경로는 이미 가려져 있다.

```!
bash "${CLAUDE_SKILL_DIR}/../../hooks/run.sh" refactor-report --collect "${CLAUDE_PROJECT_DIR}" --data "${CLAUDE_PLUGIN_DATA}" <<'VIBE_REFACTOR_ARGS'
$ARGUMENTS
VIBE_REFACTOR_ARGS
```

## 너의 할 일 (순서대로, 짧게)

1. **위 묶음을 줄이거나 고치지 말고 그대로 보여 준다.** 그다음 한 줄로 "보내면 `보낼 곳:` 줄의 저장소에 **공개 이슈**로 위 내용이 그대로 올라갑니다"라고 말한 뒤 **"보낼까요?"라고 묻고 멈춘다.** 이번 답변에서는 아무것도 실행하지 않는다.
2. 사용자가 **다음 메시지에서 분명히 "예"(보내 줘·좋아요 등)라고 할 때만** 아래를 실행한다. 제목은 사용자 설명을 20자 안팎으로 요약한다(설명이 없으면 `--title` 을 빼도 된다).
   ```
   bash "${CLAUDE_SKILL_DIR}/../../hooks/run.sh" refactor-report --send --data "${CLAUDE_PLUGIN_DATA}" --title "<사용자 설명 요약>"
   ```
   - 결과가 `이슈를 만들었습니다: <주소>` 면 그 주소를 알려 준다.
   - 종료 코드 4(gh 가 없거나 로그인이 안 됨·만들기 실패)면 결과의 **이슈 작성 링크**와 **묶음 파일 경로**를 보여 주고 "링크를 열어 묶음 파일 내용을 본문에 붙여 넣어 주세요"라고 안내한다.
3. 사용자가 아니오라고 하거나 답이 분명하지 않으면 **아무것도 보내지 않고**, 묶음의 `저장한 파일:` 경로만 알려 준다(나중에 직접 이슈에 붙여 넣을 수 있다).
4. 문제가 **안전장치(guard)를 우회하는 방법**이면 공개 이슈로 보내지 말고, 비공개 취약점 신고 https://github.com/developer-duno/claude-code-refactor/security/advisories/new 로 보내 달라고 안내한다(SECURITY.md).
5. 묶음 파일이나 다른 파일을 고치지 않고, 사용자가 동의하기 전에는 `--send` 를 실행하지 않는다.
