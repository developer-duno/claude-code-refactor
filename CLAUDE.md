# claude-code-refactor — Claude 작업 메모

이 레포는 Claude Code 플러그인 `refactor@vibe-consulting`(마켓 `vibe-consulting`)의 저장소다. 설치·사용법은 README. 여기에는 이 레포에서 Claude 가 작업할 때 지킬 레포별 절차만 적는다.

## 머지 뒤 라이브 확인 (전역 CLAUDE.md §0-8)

서버 배포가 **없다**(Railway·Vercel·NSSM 없음). main 에 합친 뒤 "라이브" = ① 그 커밋의 CI ② 판을 올린 합치기면 GitHub 릴리스 ③ 설치본 판. 셋 다 **합친 커밋 해시로** 골라 확인하고 숫자로 보고한다. 로그인 화면은 없다(화면 없는 CLI 플러그인 — live-verify 스킬 해당 없음).

1. **그 커밋의 CI**(`.github/workflows/test.yml` · 잡 4개: ubuntu-latest · windows-latest · macos-latest · ubuntu-26.04 미리보기)
   ```bash
   H=$(git rev-parse origin/main)   # 합친 뒤 fetch 한 상태에서
   gh run list --commit "$H" --event push --json databaseId,conclusion,headSha --jq '.[]|"\(.databaseId) \(.conclusion) \(.headSha[0:7])"'
   ```
   기대 = `<run id> success <해시>` 1줄. 아직 돌고 있으면 `timeout 3000 gh run watch <run id> --exit-status -i 30`. 맨 위 run 이 아니라 **해시로 고른 run** 만 본다.
2. **릴리스**(판 번호를 올린 합치기만 — 문서만 바꾼 합치기는 해당 없음)
   ```bash
   gh release view --json tagName,targetCommitish --jq '"\(.tagName) \(.targetCommitish[0:7])"'
   ```
   기대 = 새 판 태그가 합친 해시를 가리킨다. 판 번호는 네 곳이 같아야 CI 가 지나간다(`plugins/refactor/.claude-plugin/plugin.json` · `.claude-plugin/marketplace.json` · README 배지 · `.github/ISSUE_TEMPLATE/bug.yml` placeholder — `tests/test_scripts.py` 25번 「판 번호 일치」).
3. **설치본**(릴리스 뒤, 설치된 범위마다 `claude plugin update refactor@vibe-consulting --scope <user|local>`)
   ```bash
   claude plugin list | grep -A1 'refactor@vibe-consulting'   # Version: <새 판> — 범위(user·local)마다 한 항목
   ```
   다른 OS(Windows ↔ WSL)의 설치본은 그 OS 에서 같은 명령. 기준(2026-11-08): 0.4.8 · 우분투 user+local · Windows user.

보고 꼴: `CI <run id> success · 릴리스 vX.Y.Z = <해시> · 설치본 N곳 X.Y.Z`. 문서만 바꾼 합치기는 `CI <run id> success · 릴리스 해당 없음 · 설치본 변경 없음`.
