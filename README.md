# claude-code-refactor

운영 중인 서비스를 AI로 **안전하게** 리팩토링하는 Claude Code 플러그인입니다.
누구나 쓸 수 있는 공개 플러그인(MIT)이고, 화면 문구와 문서는 모두 한국어입니다(**한국어 전용 플러그인**).

![version](https://img.shields.io/badge/version-0.2.3-blue) ![license](https://img.shields.io/badge/license-MIT-green) ![Claude Code plugin](https://img.shields.io/badge/Claude%20Code-plugin-orange)

> **English summary**
> - **What it is:** A Korean-only Claude Code plugin that refactors a live service in a fixed order — code map, 25-item health check, deep audit, rebuttal review, baseline tests, plan — and then changes code only for steps a human approved, one step at a time.
> - **What it blocks:** Hooks stop common accidents before they run: secret exposure (`.env`, environment dumps, tokens in git remotes), irreversible commands (force push, `reset --hard`, dropping databases) and common approval-bypass tricks; tests and builds run with production URLs and keys swapped for dummy values.
> - **Install:** `claude plugin marketplace add developer-duno/claude-code-refactor` then `claude plugin install refactor@vibe-consulting`.

바로 가기: [설치](#3-설치) · [명령](#4-명령-5개) · [사용 순서](#5-사용-순서) · [안전장치](#6-안전장치) · [한계](#6-4-한계) · [문제 신고](#11-피드백기여라이선스)

---

## 1. 무슨 문제를 풀어 주나

코딩을 잘 모르는 운영자가 AI에게 "코드 좀 정리해 줘"라고 맡기면 이런 사고가 자주 납니다.

1. **운영 DB·운영 키로 테스트가 돈다** — `.env`에 운영 주소가 들어 있으면 테스트 한 번에 실제 주문 데이터가 바뀌거나 고객에게 알림톡이 나갑니다.
2. **승인 없이 코드가 바뀐다** — "살펴봐 줘"라고 했는데 여러 파일을 한꺼번에 고쳐, 무엇이 왜 바뀌었는지 모르게 됩니다.
3. **비밀값이 화면에 찍힌다** — `.env`·환경변수·git 기록 속 옛 키가 대화 기록에 그대로 남습니다.

이 플러그인의 답은 세 가지입니다.

- **순서 강제** — 읽기만 하는 진단을 먼저 끝내고, 지금 동작을 테스트로 찍어 둔(기준선) 뒤, 사람이 승인한 단계만 한 번에 하나씩 고칩니다.
- **안전장치** — Claude가 명령을 실행하거나 파일을 고치기 **직전에** 훅이 검사해서, 위 사고로 이어지는 흔한 명령을 막습니다.
- **안전 실행기** — `/refactor:go` 중의 테스트·빌드는 운영 주소·키를 가짜 값으로 바꿔서 돌립니다.

## 2. 30초 요약

```
/refactor:go
  준비(질문 6개) → 코드 지도 → 건강검진 25항목 → 정밀검사 → 반박 검증 → 기준선 계획
                                                        ⏸ /refactor:approve baseline
/refactor:go
  기준선 작성 (지금 동작을 테스트로 사진 찍어 두기)          ⏸ 사람이 커밋
/refactor:go
  계획서 (무엇을·왜·어떤 순서로·얼마나 위험하게)             ⏸ /refactor:approve P0-1 P1-1 …
/refactor:go
  승인된 단계 하나 실행 → 기준선으로 확인 → 독립 검사 → 보고 ⏸ 확인하고 커밋
  … 승인된 단계가 남아 있으면 /refactor:go 를 반복
  완료 보고                                                 ⏸ /refactor:approve 마무리 → 끝
```

⏸ 표시는 **사람이 확인하고 명령을 쳐야 넘어가는 곳**입니다. 그 사이의 읽기 단계는 알아서 이어 갑니다.
진행 상황은 프로젝트의 `docs/refactor/` 폴더에 저장되므로, 대화를 닫았다 열어도 이어서 할 수 있습니다.

---

## 3. 설치

### 3-1. 준비물

- **Claude Code** 최신 버전 (`claude --version`으로 확인)
- **git** — 리팩토링할 프로젝트는 git 저장소여야 합니다(되돌리기의 바탕).
- **Windows**: **Git for Windows(Git Bash)**. Windows에서 훅 명령은 Git Bash가 있으면 Git Bash로, 없으면 PowerShell로 실행됩니다(공식 문서). 이 플러그인의 훅은 `bash`로 돌기 때문에 Git Bash가 없으면 안전장치가 작동하지 않습니다.
- macOS·Linux: 기본 bash(3.2 이상)면 됩니다. 훅·스크립트는 bash 3.2 문법만 씁니다 — `GUARD_BASH` 환경변수로 bash 3.2 경로를 지정하면 시험을 그 bash로 돌려 볼 수 있습니다.

### 3-2. 범위 고르기 — 여러 프로젝트에 쓸까, 한 프로젝트에서만 쓸까

Claude Code는 플러그인을 **어느 설정 파일에 적느냐(범위, `--scope`)** 로 어디서 켜질지 정합니다. `claude plugin install`의 기본값은 `user`입니다(공식 문서).

| 범위 | 적히는 설정 파일 | 켜지는 곳 |
|---|---|---|
| `user` (기본값) | `~/.claude/settings.json` | 이 PC의 모든 프로젝트 |
| `local` | 프로젝트의 `.claude/settings.local.json` (git에 안 올라감) | 이 PC의 이 프로젝트만 |
| `project` | 프로젝트의 `.claude/settings.json` (git으로 공유) | 이 저장소를 받는 팀원 모두 |

> 알아 둘 것: 안전장치의 **항상 켜진 규칙**(비밀값 노출·되돌릴 수 없는 명령 막기, [§6](#6-안전장치))은 플러그인이 켜진 **모든 대화**에 적용됩니다. 리팩토링 중 규칙은 `docs/refactor/STATE.md`가 있는(리팩토링을 시작한) 프로젝트에서만 켜집니다.

**여러 프로젝트에 쓰는 경우** — 아무 폴더에서 두 줄:

```bash
claude plugin marketplace add developer-duno/claude-code-refactor
claude plugin install refactor@vibe-consulting
```

**한 프로젝트에서만 쓰는 경우** — 그 프로젝트 폴더에서 두 줄:

```bash
claude plugin marketplace add developer-duno/claude-code-refactor --scope local
claude plugin install refactor@vibe-consulting --scope local
```

- 팀원과 함께 쓰려면 `--scope local` 대신 `--scope project`를 쓰고 `.claude/settings.json`을 커밋합니다. 커밋만으로는 팀원 PC에 내려받아지지 않으므로, 팀원도 각자 한 번 `claude plugin install refactor@vibe-consulting --scope project`를 실행합니다(공식 문서).
- 어느 범위든 내려받은 플러그인 파일은 이 PC 공용 폴더(`~/.claude/plugins/`)에 저장됩니다.
- 공개 저장소라서 GitHub 로그인 없이도 설치됩니다.
- 설치한 뒤 **Claude Code를 다시 열거나**, 열려 있는 대화에서 `/reload-plugins`를 입력하세요.

### 3-3. 잘 깔렸는지 확인 (3단계)

1. Claude Code에서 `/refactor:status` → "아직 시작하지 않았어요"가 나오면 명령 OK.
2. `/hooks`를 열어 refactor의 훅(PreToolUse·PostToolUse·UserPromptSubmit·SessionStart)이 보이면 안전장치 OK.
3. 첫 `/refactor:go`의 준비 단계에서 Claude가 안전장치를 스스로 시험합니다(항상 켜진 규칙·리팩토링 중 규칙·`/refactor:go` 중 규칙 각각 한 번). 막히지 않으면 그 사실을 보고합니다.

### 3-4. 설치 없이 시험해 보기

저장소를 받아서 그 대화에서만 불러올 수 있습니다(설정 파일에 아무것도 적지 않음).

```bash
git clone https://github.com/developer-duno/claude-code-refactor.git
claude --plugin-dir ./claude-code-refactor/plugins/refactor
```

---

## 4. 명령 5개

| 명령 | 하는 일 | 누가 |
|---|---|---|
| `/refactor:go` | 다음 단계 진행. 뒤에 `하나씩`(한 단계만), `다시 CHECKUP`(그 단계부터 다시), `마무리`(완료 보고)를 붙일 수 있음 | 사람만 |
| `/refactor:approve` | 승인·취소·마무리. 예: `baseline` / `P0-1 P1-2` / `P1`(묶음 전체) / `보류 P1-2` / `마무리` / `확인`(승인 기록을 손으로 고친 뒤 다시 봉인). 인자 없이 치면 현황만 | **사람만** — 입력창에 직접 칠 때 **입력 훅**이 승인을 처리합니다 |
| `/refactor:status` | 이 프로젝트가 어디까지 왔는지, 다음에 뭘 치면 되는지 | 사람·Claude |
| `/refactor:board` | 여러 프로젝트를 급한 순서로 한 표에. 예: `/refactor:board ~/projects` | 사람·Claude |
| `/refactor:report` | 문제 신고 묶음을 만들어 **먼저 보여 주고**, 동의하면 GitHub 이슈로 보냄([§11](#11-피드백기여라이선스)) | 사람만 |

- **승인은 사람만 할 수 있습니다.** `/refactor:approve`를 입력창에 치면 입력 훅(UserPromptSubmit)이 승인 스크립트를 실행하고, 결과를 `[Vibe Refactor 승인 처리 결과 — 입력 훅]` 블록으로 Claude에게 전합니다. Claude가 승인 스크립트나 훅을 직접 부르는 것은 안전장치가 막고, 스크립트도 훅 밖에서는 아무것도 바꾸지 않습니다(현황만 보여 줌). 따옴표나 역슬래시로 이름을 쪼개기(`app''rove`), 새 Claude 세션에 승인 명령 넘기기(`claude -p "/refactor:approve …"`), 한 줄 파이썬·노드 코드 안에서 부르기처럼 **알려진 우회 모양**도 막습니다. 다만 글자를 조립하거나 파일에 적어 두었다가 넘기는 우회까지 모두 막지는 못합니다([§6-4](#6-4-한계)).
- 계획서의 체크 표시를 손으로 고쳐도 승인으로 치지 않습니다. 승인의 근거는 `docs/refactor/APPROVALS.log` 한 곳입니다.
- `/refactor:board`는 지금 프로젝트에 `docs/refactor/STATE.md`가 있으면 그 상위 폴더를, 없으면 지금 폴더 아래를 훑습니다. 상태는 🔴 급한 구멍 · 🙋 사장님 차례(화면 문구 그대로 — 승인·답변만 하면 진행) · 🙋 마무리 확인 필요(STATE는 DONE인데 `/refactor:approve 마무리`로 아직 확인 안 함) · ▶ 다음 단계 가능 · ⏳ 진행 중 · ✅ 완료 · ⏰ 14일 넘게 멈춤 · ⚠허용파일(허용 파일이 남아 있음)로 표시됩니다.

---

## 5. 사용 순서

1. **준비** — 프로젝트 폴더에서 Claude Code를 열고 `/refactor:go`. 준비 질문 6개(서비스 종류, 결제 여부, 외부 데이터 수집, 운영/개발 DB 분리, 멈추면 안 되는 기능, 목표와 작업 브랜치)에 답합니다.
2. **건강검진** — 이어서 코드 지도 → 건강검진 25항목 → 정밀검사 → 반박 검증까지 자동으로 진행하고, **기준선 계획**에서 멈춥니다. 결과는 `docs/refactor/AUDIT_REPORT.md` 등에 남습니다.
3. **기준선** — `docs/refactor/BASELINE.md`를 훑어보고 아래 두 명령을 차례로 입력합니다.
   ```
   /refactor:approve baseline
   /refactor:go
   ```
   기준선 테스트를 만든 뒤 커밋을 부탁합니다. 알려 준 한 줄(`! git add -A && git commit -m "…"`)을 입력하고 다시 `/refactor:go`.
4. **계획서** — `docs/refactor/REFACTOR_PLAN.md`를 보고 할 단계만 승인합니다.
   ```
   /refactor:approve P0-1 P1-1
   ```
   승인하면 "👤 사람이 직접 할 일"(예: 결제사 테스트 키 발급)을 먼저 알려 줍니다. 승인은 그 순간의 **카드 내용**에 묶입니다 — 승인한 뒤 카드가 바뀌면 그 단계는 실행하지 않고 다시 승인을 받습니다.
5. **승인 실행** — `/refactor:go` 한 번에 **한 단계만** 고치고, 기준선으로 확인하고, 다른 AI가 독립 검사를 한 뒤 보고하고 멈춥니다. 알려 준 커밋 한 줄을 입력한 뒤 다음 `/refactor:go`. 화면 확인은 **개발용 DB·테스트 키로 켠 개발 서버**에서 하세요(운영 DB가 하나뿐이면 보기만 하고 저장·결제·발송 버튼은 누르지 않기).
6. **마무리** — 승인한 단계가 다 끝나면 완료 보고를 합니다. `/refactor:approve 마무리`를 입력해야 끝나고, 그래야 리팩토링 중 안전장치가 꺼집니다. 남은 단계를 안 할 거면 먼저 `/refactor:approve 보류 <ID>`. 한두 달 뒤 `/refactor:go 다시 CHECKUP`으로 재점검할 수 있습니다.

**팁**

- 처음에는 `/refactor:go 하나씩`으로 한 단계씩 보면서 진행하면 이해하기 쉽습니다.
- 대화가 길어지면 `/clear` 후 `/refactor:go` — 진행 상황은 파일에 있으니 그대로 이어집니다.
- 입력창에서 `!`로 시작하는 줄은 **사람이 직접 실행하는 명령**입니다(커밋·허용 파일 만들기 등). 안전장치를 거치지 않습니다.
- 비용: 건강검진·정밀검사는 보조 AI(감사관)를 여러 명 동시에 써서 토큰을 꽤 씁니다. 감사관은 Sonnet 모델을 씁니다(`plugins/refactor/agents/auditor.md`의 `model:` 줄). 처음 진단(준비~기준선 계획)이 가장 크고, 그 뒤로는 승인한 단계만큼만 씁니다.

---

## 6. 안전장치

Claude가 도구를 쓰기 **직전에**(PreToolUse 훅) 검사해서 위험하면 막습니다. 막으면 `[refactor 안전장치] …` 메시지와 함께 대신 할 방법(→)을 알려 주고, Claude는 우회하지 않고 사용자에게 보고하게 되어 있습니다. 셸 명령(Bash·PowerShell·Monitor), 파일 도구, Grep 도구, MCP 도구, 하위 에이전트에게 보내는 지시를 모두 봅니다.

### 6-1. 막는 것

| 언제 | 막는 것 |
|---|---|
| **항상** (플러그인이 켜진 모든 대화) | `.env`·키 파일(`.git/config`·`.npmrc` 포함)을 읽기·출력·복사·전송·수정하는 명령과 도구, 환경변수 전체 출력, 토큰이 든 원격 주소 출력, git 기록 속 옛 비밀값 검색, git이 무시하지 않는 `.env`가 든 범위의 내용 검색 · 강제 push, `reset --hard`, `clean -f`, `checkout .`, `branch -D`, 원격 가지·저장소 삭제(`gh api -X DELETE`·`gh repo delete` 포함), 기록 다시 쓰기, `rm -rf ~`·프로젝트 통째 삭제 같은 대량 삭제, DB 삭제·초기화 · 승인 스크립트와 플러그인 훅을 직접 부르기, 승인 기록(`APPROVALS.log`)·허용 파일(`.allow-*`)·`.turn*`을 만들기·복사·이동·개명·압축 해제로 바꾸기, 계획서 승인 칸 체크, 플러그인 폴더 수정 · MCP 도구나 하위 에이전트 지시로 위 금지를 우회하기 |
| **리팩토링 진행 중** (`docs/refactor/STATE.md`가 있고 마무리 전) | push·배포·원격 서버 명령, DB 구조 적용(마이그레이션), 원격 DB 접속, MCP로 운영 DB 조회·배포·메시지 발송, 플러그인 끄기, Claude 설정 수정, `git stash`, 파일을 지정하지 않은 `git log -p`, 프로젝트 전체 포맷터 · 커밋된 기준선 테스트와 마이그레이션 파일 수정(스냅숏 갱신 옵션 포함) |
| **`/refactor:go` 실행 중** | 대표 실행 명령(npm·pnpm·yarn·bun·npx, python·node·deno, pytest, uv·poetry·pipenv run, make, turbo·nx, docker compose 등)은 안전 실행기로만 · 읽기 전용 단계, 그리고 승인된 실행 대기 단계가 없을 때는 `docs/refactor/` 밖 수정 금지 |
| **너무 긴 입력** | 셸 명령 16KB(MCP 도구의 명령 칸 포함) · Grep 입력·Edit의 바꿀 부분·파일 경로 32KB · 하위 에이전트(Agent) 지시문 32KB(바이트 기준이라 한글만 쓰면 약 1만 글자) 또는 2,000줄을 넘거나, Grep 검색 범위가 너무 넓으면(폴더 200개 또는 5초 이상) 판정하지 않고 막습니다 — 파일로 저장해 실행하거나 범위를 좁히세요. **Write 본문과 MCP 도구(노션·DB·메일 등) 입력은 크기로 막지 않습니다** — 큰 파일 쓰기·긴 문서·큰 SQL은 정상 작업이기 때문입니다. 대신 그 안의 경로·명령 규칙은 크기와 상관없이 적용되고, SQL은 256KB까지 문장마다 판정하며 그보다 크면 위험한 낱말(DROP·DELETE 등)이 하나라도 있을 때 막습니다 |

명령이 끝난 뒤에도(PostToolUse 훅) 한 번 더 확인해서, **이번 턴에** 커밋된 기준선·마이그레이션 파일이나 승인 기록이 바뀌었으면 그 턴의 Claude에게 바로 알립니다. 승인 기록은 `/refactor:approve`가 쓸 때마다 봉인되므로, 그 밖에서 바뀐 기록은 사람이 `/refactor:approve 확인`을 입력하기 전까지 인정되지 않습니다.

### 6-2. 막지 않는 것 (일부러 허용)

- 비밀이 아닌 환경변수 이름만 지정해 보는 명령: `printenv PATH`, `printenv HOME`, `env | grep PATH`, `echo $HOME` 등. **이름만 보는** `env | cut -d= -f1`, `printenv | cut -d= -f1`도 허용됩니다(값이 안 나오므로). 막히는 것은 `env`·`printenv`·`set`처럼 **값이 함께** 나오는 덤프입니다 — 어떤 이름이 있는지는 안전 실행기 `--check`로 보세요.
- `.env`가 **아직 없을 때만** 하는 `cp .env.example .env`(이미 있으면 덮어쓰기라 막음). `.env.local`처럼 없는 파일로 복사하는 것도 허용.
- `git config --list`, `.envrc`(direnv) 읽기.
- 원격 주소를 **개수만** 세는 확인(`git config --get-regexp 'remote\..*\.url' | grep -c x-access-token`)과 원격이 아닌 항목만 보는 `git config --get-regexp '^(user|credential)\.'`. 원격 주소 원문이 필요하면 가려서 보세요: `git remote -v | sed -E 's#//[^/@]*@#//****@#'`.
- 문서·메모를 heredoc(`cat >> 메모.md <<'EOF'`, `tee -a 메모.md <<'EOF'`)으로 쓸 때 본문에 `.env`·`credentials.json` 같은 **이름이 나오기만** 하는 것. 따옴표 없는 `<<EOF`는 본문이 셸에서 풀리므로 `$(…)`로 비밀 파일을 여는 줄은 계속 막고, 쓴 파일을 같은 명령에서 실행하면(`| bash`, `bash x.md` 등) 본문 전체를 봅니다. `python -`·`node -`처럼 **코드를 실행하는** heredoc은 본문 전체를 보므로, 코드 안 글에 이런 이름이 나오면 막힙니다 — 그럴 때는 편집 도구로 쓰세요.
- `bash -c '…'` 안에서 `.md` 파일을 이어 붙이는 것(`cat a.md >> b.md`). `.md`를 **실행**하는 것(`bash x.md`, `source x.md`)만 막습니다.
- `test -f .env`·`[ -f .env ]`처럼 있는지만 보는 확인.
- `node_modules`·`.next`·`dist`·`build` 같은 폴더 지우기.

> 훅은 도구를 쓸 때마다 실행되므로 조금 느려집니다. 이 PC 실측으로 호출마다 0.15~0.4초 정도이고, 컴퓨터가 매우 바쁠 때는 몇 초까지 늘 수 있습니다.

### 6-3. 일부러 풀어야 할 때 (사람만 가능)

동작을 일부러 바꾸는 단계에서 기준선 테스트를 새 동작으로 고쳐야 하면, Claude가 멈추고 아래처럼 부탁합니다. 입력창에 그대로 붙여 넣으세요.

```
! touch "<프로젝트 폴더>/docs/refactor/.allow-baseline-edit"
```

마이그레이션 파일은 `.allow-migration-edit`입니다. **작업을 커밋한 다음에는 꼭 지우세요**(`! rm "<같은 경로>"`). 허용 파일은 git에 올라가지 않습니다.

### 6-4. 한계

- 안전장치는 **흔한 위험 명령을 모양으로 알아보고 막는 보조 장치**입니다. 스크립트를 거친 수정, 일부러 꼬아 쓴 명령 등 모든 우회를 막지는 못합니다. 사고(실수)를 줄이는 장치이지, 악의적인 공격을 막는 장치가 아닙니다. **보조 안전망이지 벽이 아닙니다.**
- 이름을 쪼개거나 조립하는 우회는 **알려진 모양만** 막습니다. 따옴표·역슬래시·빈 변수·`$'…'`·중괄호·글로브로 쪼갠 이름은 승인·훅 진입점·되돌릴 수 없는 git 명령·원격 가지 삭제·대량 삭제·DB 초기화 규칙(리팩토링 중에는 배포·마이그레이션·원격 DB 규칙까지)에서 막고, 새 Claude 세션에 넘긴 승인 명령과 한 줄 인터프리터 코드 안의 승인 스크립트도 막습니다. 하지만 `printf`·`eval`로 글자를 이어 붙이거나, 명령을 파일에 적어 두었다가 다음 도구 호출에서 실행하거나, 새 Claude 세션에 파일로 넘기는 것(`claude -p < 파일`)은 명령 글자만 보고는 알아볼 수 없습니다.
- 커밋 메시지처럼 따옴표 안 문장에 `;`와 위험한 명령이 함께 있으면(`git commit -m "x; rm -rf docs/refactor"`) 막힐 수 있습니다. 명령을 `;`·`&&` 조각으로 나눠 보기 때문입니다 — 메시지를 파일로 쓰고 `git commit -F <파일>`을 쓰세요.
- 안전장치 스크립트가 고장 나거나 실행되지 못하면(Windows에서 Git Bash를 못 찾을 때 등) **막지 않고 통과**시킵니다. 모든 작업이 멈추는 것을 막기 위해서이고, 그래서 준비 단계에서 작동 시험을 합니다.
- 판정이 **25초 안에 끝나지 않으면 통과시키지 않고 막습니다**("판정이 너무 오래 걸려 막았습니다"). Claude Code는 제한 시간을 넘긴 훅을 "막지 않음"으로 처리하므로, 판정이 느린 입력이 검사 없이 지나가지 않게 실행기가 먼저 끊습니다. 명령 줄이 수천 개인 지시문이나 구분자(`;`·`&&`)가 수천 개인 명령처럼 아주 긴 입력은 컴퓨터가 느리거나 바쁠 때 이 제한에 걸립니다 — 안내대로 내용을 파일로 저장해 경로를 넘기거나 명령을 나누면 됩니다.
- 플러그인 스크립트를 통째로 복사해 훅과 같은 입력을 흉내 내는 것, 승인 기록과 봉인을 함께 다시 쓰는 스크립트까지는 막지 못합니다. 커밋 전에 `git diff`로 계획서·승인 기록의 변화를 한 번 보는 습관이 가장 확실합니다.
- 코드·설정 파일에 직접 적힌 키는 안전 실행기도 가리지 못합니다([§7](#7-안전-실행기)).
- 안전 실행기 강제는 `/refactor:go`로 시작한 대화(그 뒤 질문에 답하거나 단계 보고를 받은 뒤 이어지는 대화 포함)에만 적용됩니다. 평소 개발 대화에서는 막지 않습니다.
- 입력 훅(`/refactor:go`·`/refactor:approve` 처리)은 컴퓨터가 매우 바쁠 때 3~10초 걸릴 수 있고, 30초를 넘기면 그 턴의 결과 안내가 생략됩니다 — 그때는 같은 명령을 한 번 더 치세요(승인은 두 번 기록되지 않습니다).
- `/refactor:report`의 전송은 스킬이 "보낼까요?"라고 물은 뒤 예일 때만 실행하도록 되어 있고, 안전장치가 전송 자체를 강제로 막지는 않습니다.

---

## 7. 안전 실행기

`/refactor:go` 중 Claude는 테스트·빌드를 이렇게 돌립니다(대표 실행 명령은 안전장치가 강제하고, 그 밖의 실행 명령에도 Claude가 붙이도록 되어 있습니다).

```
bash "<플러그인 폴더>/hooks/run.sh" refactor-safe-run -- npm test
```

- **Bash 도구(Git Bash)로만 실행합니다.** PowerShell 도구에서 `bash`를 치면 Windows에 딸린 WSL bash가 먼저 잡혀 실패합니다.
- `.env`(세 단계 아래 폴더까지)와 셸 환경에서 운영일 수 있는 값(DB 주소, API 키, 결제 키, 서버 주소 등)을 **이름과 값의 모양으로** 찾아 가짜 값(`127.0.0.1:9` 등, 접속하면 바로 실패하는 주소)으로 바꿔 실행합니다. 테스트 키(`test_…`, `sk_test_…`)·로컬 주소·숫자·짧은 설정값·파일 경로는 그대로 둡니다.
- 같은 이름이 여러 곳(`.env` 여러 파일·셸)에 있으면 **하나라도 운영 모양이면 가짜 값**으로 바꿉니다(`.env`=로컬 + `.env.local`=운영이면 가짜 값).
- `refactor-safe-run --check`는 무엇이 바뀌는지 **이름만** 보여 줍니다. 값은 어떤 경우에도 출력하지 않습니다.

**개발용 DB를 그대로 쓰고 싶을 때 — `.allow-env`**

가장 안전한 것은 개발용 DB와 테스트 키를 따로 두는 것입니다. 개발용 DB가 원격(예: 개발용 Supabase 프로젝트)이라 가짜 값으로 바뀌면 곤란할 때는, 개발용인지 확인한 뒤 **사람이** 그 이름을 허용 목록에 적습니다.

```
! printf 'DATABASE_URL=db.<개발용 프로젝트>.supabase.co\n' >> "<프로젝트 폴더>/docs/refactor/.allow-env"
```

`이름=호스트`로 적으면 그 값이 나중에 다른(운영) 주소로 바뀌었을 때 자동으로 다시 가립니다. `--check`가 허용한 이름의 지금 호스트를 보여 주니 확인한 뒤 적으세요(운영 주소는 절대 적지 않기). 한 줄에 하나, git에 올라가지 않습니다. 운영 DB가 하나뿐이면 DB를 쓰는 테스트는 돌리지 않고, DB 없이 확인할 수 있는 계산·문구 기준선만 만듭니다.

**가려지지 않는 것**

- 코드·설정 파일에 직접 적힌 키·주소, `~/.aws`·gcloud 같은 자격 증명 파일
- 코드가 `.env`를 직접 열어 읽거나(`dotenv_values`, `readFileSync('.env')`) 덮어쓰기 옵션(`override: true`)을 쓰는 경우
- Cloudflare(wrangler)가 직접 읽는 `.dev.vars`·`.env`, docker compose의 `env_file`, Supabase 함수의 `supabase/functions/.env`
- 코드가 하는 실제 네트워크 요청(수집 대상 사이트 등)

`--check`가 세 단계 아래 폴더까지 이런 흔적을 찾아 알려 주지만, 코드 속에 직접 적힌 값은 찾지 못합니다. 안전 실행기로 만든 빌드 결과(`.next`, `dist`)에는 가짜 값이 들어 있으니 **배포에 쓰지 말고** 배포 전에는 평소 방법으로 다시 빌드하세요.

---

## 8. 만들어지는 파일

프로젝트의 `docs/refactor/` 아래:

| 파일 | 내용 |
|---|---|
| `STATE.md` | 진행 상황(현황표가 읽음) |
| `PROFILE.md` | 서비스 정보와 준비 질문 답변 |
| `PROJECT_MAP.md` | 코드 지도 |
| `AUDIT_REPORT.md`, `audit/*.md`, `AUDIT_VERIFY.md` | 건강검진·정밀검사·반박 검증 |
| `BASELINE.md` | 기준선 계획과 결과 |
| `REFACTOR_PLAN.md` | 공사 계획서(단계 카드와 승인 칸 — 승인 칸은 기록을 보기 좋게 옮겨 적은 것) |
| `EXECUTION_LOG.md` | 실행 기록 |
| `APPROVALS.log` | **승인의 유일한 근거.** 언제·무엇을·어떤 카드 내용(지문)으로 승인했는지. `/refactor:approve`와 `/refactor:go 다시`(그 앞 승인을 무효로 하는 재설정 줄) 두 경우에만 씀 |
| `approved/<ID>.md` | 승인할 때의 카드 내용(카드가 바뀌면 무엇이 바뀌었는지 보여 줄 때 씀) |
| `.turn.<세션ID>`, `.turn-dirty.<세션ID>`, `.allow-*`(`.allow-env` 포함) | 플러그인·사람용 표시 파일. 세션별로 나뉘어 같은 프로젝트를 여러 대화창에서 열어도 섞이지 않음(git에 안 올라감) |

`docs/refactor/`는 **git에 커밋해 두세요** — 다른 PC에서 이어서 하려면 필요합니다. 승인 기록의 봉인은 줄바꿈(CRLF)과 무관하게 계산되고, `docs/refactor/.gitattributes`가 없으면 자동으로 만들어집니다.

플러그인 데이터 폴더 `${CLAUDE_PLUGIN_DATA}`(마켓플레이스로 설치했다면 보통 `~/.claude/plugins/data/refactor-vibe-consulting/`) 아래:

- `problems.log` — 문제 기록. 규칙 이름과 시각만 적히고, 명령·값·파일 이름·경로는 적히지 않습니다(플러그인 스크립트가 비정상으로 끝난 기록도 이름과 종료 코드만). 200KB를 넘으면 최근 절반만 남깁니다. `/refactor:report`가 마지막 30줄을 묶음에 넣어 **먼저 보여 주고**, "보낼까요?"에 **예**라고 답할 때만 보냅니다([§11](#11-피드백기여라이선스) 참고).
- `report-<날짜-시각>.md` — `/refactor:report`가 만든 신고 묶음.

---

## 9. 업데이트·끄기·지우기

```bash
claude plugin marketplace update vibe-consulting
claude plugin update refactor@vibe-consulting        # 그다음 Claude Code 다시 열기(또는 /reload-plugins)
claude plugin disable refactor@vibe-consulting       # 잠시 끄기 — 범위를 안 주면 local → project → user 순으로 찾음
claude plugin uninstall refactor@vibe-consulting     # 지우기 — 기본 범위가 user. local로 설치했으면 뒤에 --scope local
```

- 이 마켓플레이스는 공식 마켓플레이스가 아니라서 자동 업데이트가 기본으로 꺼져 있습니다(공식 문서). 새 버전은 위 두 줄로 받으세요.
- 마지막 범위에서 지우면 플러그인 데이터 폴더(`problems.log`·신고 묶음)도 함께 지워집니다. 남기려면 `--keep-data`를 붙입니다.
- 0.2.0에서 승인한 기록은 그대로 이어집니다. `/refactor:approve 확인`은 화면에 "봉인이 다르다"고 나올 때만 치세요 — 습관적으로 치면 손댄 기록까지 봉인될 수 있습니다. STATE가 DONE인데 사용자가 아직 `/refactor:approve 마무리`로 확인하지 않은 프로젝트는 리팩토링 중 안전장치가 계속 켜져 있으니, 끝내려면 `/refactor:approve 마무리`가 필요합니다.
- 리팩토링 진행 중에는 Claude가 플러그인을 끄는 명령이 막혀 있습니다. 끄기·지우기는 사람이 터미널에서 합니다.

## 10. 문제가 생기면

| 증상 | 할 일 |
|---|---|
| 안전장치가 아무것도 안 막음 | Windows면 Git for Windows 설치 확인 → Claude Code 다시 열기 → `/hooks`에서 refactor 훅 확인 |
| 승인이 안 먹힘 / `[Vibe Refactor 승인 처리 결과 — 입력 훅]` 블록이 안 보임 | 입력 훅이 꺼졌거나 시간 안에 끝나지 못한 것입니다. `/refactor:approve`(인자 없이)로 현황을 다시 보고, `/hooks`에서 refactor 훅이 보이는지 확인하세요 |
| `WSL … execvpe(/bin/bash) failed` | 안전 실행기를 PowerShell 도구로 실행했습니다. Bash 도구(Git Bash)로 다시 실행하세요([§7](#7-안전-실행기)) |
| `[refactor 안전장치]`로 멈춤 | 정상입니다. → 줄의 안내를 따르거나, 정말 필요하면 사람이 `!`로 직접 실행 |
| "명령이 너무 깁니다(16KB 초과)" | 명령을 파일로 저장하고, 무엇을 하는지 확인한 뒤 실행 |
| "판정이 너무 오래 걸려 막았습니다(N초 초과)" | 판정이 제한 시간 안에 끝나지 않은 것입니다. 긴 지시문·SQL은 파일로 저장해 경로를 넘기고, 긴 명령은 나누거나 스크립트 파일로 만들어 무엇을 하는지 확인한 뒤 실행합니다. N이 25가 아니면 환경 변수 `REFACTOR_GUARD_LIMIT`이 설정돼 있는 것입니다(지우면 25초) |
| "이번 턴에 보호된 파일(…)이 바뀌었습니다" | `git diff <파일>`로 무엇이 바뀌었는지 보고 결정. 사람이 일부러 바꾼 것이면 그대로 둠 |
| "승인 뒤 카드 내용이 바뀜" | `/refactor:status`가 보여 주는 바뀐 줄(− 승인 때 / + 지금)을 읽어 보고 괜찮으면 `/refactor:approve <ID>`로 다시 승인 |
| "이번 턴에 승인 기록(…)이 바뀌었습니다" / "승인 기록(APPROVALS.log)이 /refactor:approve 밖에서 바뀌었습니다" | `git diff docs/refactor/APPROVALS.log`로 보고, 모르는 줄이면 지운 뒤 `/refactor:approve 확인` |
| "STATE는 DONE이지만 사용자의 마무리 확인(…)이 없어 …" | 정말 끝났으면 `/refactor:approve 마무리` |
| "체크 표시만 있고 승인 기록이 없음" | 누군가 계획서를 손으로 체크한 흔적입니다. 실행하려면 `/refactor:approve <ID>` |
| 테스트가 `127.0.0.1:9` 연결 실패로 끝남 | 정상입니다 — 안전 실행기가 운영 DB 대신 가짜 주소를 넣었습니다. 개발용 DB를 만든 뒤 `.allow-env`에 적고 돌립니다([§7](#7-안전-실행기)) |
| 진행이 꼬임 | `/refactor:status`로 확인 → `/refactor:go 다시 <단계>` |

그래도 안 풀리면 `/refactor:report`로 신고해 주세요.

---

## 11. 피드백·기여·라이선스

- **`/refactor:report [문제 설명]`** — 플러그인 버전·설치 위치·OS·Claude Code·bash·git·python 버전, 리팩토링 단계, `problems.log` 마지막 30줄, 여러분의 설명을 모아 **진단 묶음**을 만들고 화면에 그대로 보여 줍니다. 비밀값 모양(KEY=값·토큰·주소 속 비밀번호)과 홈 폴더 경로는 가려져 있고, **이 단계에서는 아무 데도 보내지 않습니다.** "보낼까요?"에 **예**라고 답할 때만 여러분의 `gh` 로그인으로 이 저장소에 **공개 이슈**를 만듭니다. `gh`가 없거나 로그인돼 있지 않으면 제목이 채워진 이슈 작성 링크와 묶음 파일 경로를 알려 줍니다(묶음 내용을 본문에 붙여 넣으면 됩니다). 이 저장소에 쓰기 권한이 없는 분이 보내면 GitHub가 `bug` 라벨만 오류 없이 빼고 이슈를 만듭니다(라벨은 관리자가 붙입니다).
- **이슈 양식**: [버그 신고](https://github.com/developer-duno/claude-code-refactor/issues/new?template=bug.yml) · [기능 제안](https://github.com/developer-duno/claude-code-refactor/issues/new?template=feature.yml)
- **취약점(안전장치 우회 방법)**: 공개 이슈에 적지 말고 [`SECURITY.md`](SECURITY.md)의 비공개 취약점 신고로 보내 주세요.
- **기여**: [`CONTRIBUTING.md`](CONTRIBUTING.md) — 막는 규칙을 고칠 때는 차단 케이스와 통과 대조군 시험을 함께 추가합니다.
- **라이선스**: MIT — [`LICENSE`](LICENSE)

---

## 12. 개발자용

### 시험 돌리기

Git Bash·macOS·Linux:

```bash
python tests/test_guard.py && python tests/test_scripts.py   # 안전장치·스크립트 시험
GUARD_BASH=/bin/bash python3 tests/test_guard.py             # macOS 기본 bash 3.2로 시험(macOS는 python3)
claude plugin validate --strict plugins/refactor && claude plugin validate --strict .
```

Windows PowerShell(`&&` 대신 `;`, `VAR=값 명령` 대신 `$env:VAR`):

```powershell
python tests/test_guard.py; python tests/test_scripts.py
$env:GUARD_BASH = "C:/Program Files/Git/bin/bash.exe"; python tests/test_guard.py
claude plugin validate --strict plugins/refactor; claude plugin validate --strict .
```

- Windows에서는 시험이 Git Bash를 자동으로 찾습니다(PATH의 WSL bash 대신). 못 찾으면 `GUARD_BASH`에 Git Bash 절대경로를 지정하세요. `python3`은 Windows 스토어 안내 프로그램일 수 있으니 `python`을 쓰세요.
- 0.2.3 기준 결과(GitHub Actions): 안전장치 시험 1424/1424(Ubuntu·Windows Git Bash·macOS 기본 bash 3.2 모두), 스크립트 시험 152/152(Ubuntu·macOS)·153/153(Windows Git Bash, Windows 전용 1개 포함) 통과. 안전장치 시험은 시간이 오래 걸리니 동시에 여러 개를 돌리지 마세요.
- 배포할 때는 `plugins/refactor/.claude-plugin/plugin.json`과 `.claude-plugin/marketplace.json`의 `version`을 함께 올립니다.

### 폴더 구조

```
claude-code-refactor/
├─ .claude-plugin/marketplace.json   마켓플레이스(플러그인 목록, 이름 vibe-consulting)
├─ .github/                          이슈 양식(bug·feature·config), PR 양식
├─ .gitattributes                    스크립트 줄바꿈을 LF로 고정
├─ LICENSE · SECURITY.md · CONTRIBUTING.md · README.md
├─ tests/test_guard.py               안전장치 시험
├─ tests/test_scripts.py             승인·현황·안전 실행기·신고 시험
└─ plugins/refactor/
   ├─ .claude-plugin/plugin.json
   ├─ skills/go/        지휘자: SKILL.md, phases/0~7, checklists/(건강검진·정밀 12종), templates/
   ├─ skills/approve/   승인(사람만) — 실제 처리는 입력 훅
   ├─ skills/status/    현황 — scripts/refactor-status.sh
   ├─ skills/board/     여러 프로젝트 현황표 — scripts/refactor-board.sh
   ├─ skills/report/    문제 신고(사람만) — scripts/refactor-report.sh
   ├─ agents/           auditor(감사관) · verifier(반박 검증) · reviewer(실행 후 검사)
   ├─ hooks/            hooks.json, run.sh(실행기), guard.sh, post-check.sh, turn.sh, session-start.sh
   └─ scripts/          refactor-approve.sh · refactor-status.sh · refactor-board.sh · refactor-report.sh
                        refactor-lib.sh(승인 기록·카드 읽기 공용) · refactor-safe-run.sh(안전 실행기)
```

---

## 13. 변경점

### 0.2.3 (2026-10-02)

- **판정이 느리면 통과되던 구멍 막기** — Claude Code는 제한 시간을 넘긴 훅을 "막지 않음"으로 처리합니다. 그래서 판정이 30초를 넘기는 입력은 위험한 명령이어도 검사 없이 실행될 수 있었습니다(macOS 기본 bash 3.2에서 20KB 지시문, Linux·Windows에서 따옴표 짝이 안 맞는 명령 줄 2,000개짜리 지시문). 이제 실행기(`run.sh`)가 안전장치를 지켜보다 **25초 안에 판정이 안 끝나면 막습니다**("판정이 너무 오래 걸려 막았습니다" — [§6-4](#6-4-한계)·[§10](#10-문제가-생기면)). 훅 제한 시간은 60초로 올려 실행기가 먼저 끊을 여유를 두었습니다.
- **macOS 기본 bash(3.2)에서 빨라짐** — bash 3.2는 긴 글에서 `${변수//찾을말/바꿀말}`이 길이의 제곱~세제곱으로 느려집니다. 지시문 줄 세기·줄 나누기, SQL 풀기, 따옴표 짝 세기를 1KB가 넘으면 awk 한 번으로 처리합니다(macOS CI 기준 20KB 지시문 판정 52초 → 0.2초, 250KB SQL은 90초 초과 → 2초). awk가 없거나 실패하면 옛 방식으로 계산하므로 판정을 건너뛰지 않습니다.
- **문제 신고** — macOS 기본 bash에서 `bad substitution` 오류로 진단 묶음을 만들지 못하던 것을 고쳤습니다.
- **시험** — GitHub Actions가 Ubuntu·Windows(Git Bash)·macOS(기본 bash 3.2) 세 곳에서 두 시험을 돌리고, 셋 다 통과해야 합쳐집니다. 훅을 부르는 시험은 30초를 넘기면 실패로 셉니다(예전에는 90초까지 기다려 느린 판정이 가려졌습니다). 옛 계산과 새 계산이 글자 하나까지 같은지 대조하는 시험, 실행기 감시 시험, awk가 실패했을 때의 시험을 넣었습니다.

### 0.2.2 (2026-09-27)

- **쪼갠 이름 막기 확대** — 따옴표·역슬래시·빈 변수·`$'…'`·중괄호·글로브로 이름을 쪼개도, 승인·git 규칙과 똑같이 **대량 삭제·DB 초기화·(리팩토링 중) 배포·마이그레이션·원격 DB** 규칙이 알아봅니다(예: `eval "rm -rf doc"'s/refactor'`, `bash -c "supa"'base db reset'`).
- **원격 가지·저장소 삭제 우회 차단** — `gh api -X DELETE …/git/refs/…`, `gh api -X DELETE repos/<소유자>/<저장소>`, `gh repo delete`.
- **옛 판부터 있던 구멍 막기**(0.2.2 검사관이 찾음) — 따옴표·주석 안의 `<<'EOF'` 글자 뒤 줄을 판정에서 빼던 것, `tee`·`>`로 여러 파일에 쓸 때 첫 파일만 보던 것, `bash -e`처럼 코드 옵션이 아닌 옵션 뒤의 스크립트 실행.
- **괜히 막히던 것 풀기**(전역 설치 첫날 실제로 막힌 명령 원문으로 확인) — 원격 주소를 개수만 세는 확인(`$( … | grep -c …)`처럼 명령 치환 안에 있어도), `git config --get-regexp '^(user|credential)\.'`, 문서·메모를 heredoc(`cat`·`tee`)으로 쓸 때 본문에 이름만 나오는 경우, 쓴 문서를 같은 명령에서 `wc`·`tail`로 보기만 하는 경우, `2~4단`·`15:00~19:00`처럼 물결표가 든 글을 Windows 짧은 파일 이름(`ENV~1`)으로 오해하던 것, `bash -c` 안의 `.md` 이어 붙이기, `test -f`·`[ -f ]` 존재 확인, 따옴표 안에 `\"`가 든 검색어. 막힐 때 안내도 보강했습니다(`cd X && rm …`로 잇기, 스쿼시 머지된 가지는 사용자에게 `git branch -D`를 부탁하기).
- **문제 신고** — 파이썬 버전을 `python`부터 찾습니다(Windows 스토어 안내 프로그램 지연 방지). 쓰기 권한이 없는 사람이 보내면 `bug` 라벨은 빠지고 이슈만 만들어진다는 점을 [§11](#11-피드백기여라이선스)에 적었습니다.
- **시험 도구** — 리눅스·맥에서 `gh`와 `bash`가 같은 폴더에 있으면 신고 시험이 멈추던 문제, Windows에서 스크립트 안의 `bash`가 WSL로 가던 문제를 고쳤고, 시험 중 진짜 GitHub 호출이 나가지 않게 했습니다.

### 0.2.1

- **승인을 입력 훅이 처리** — 스킬의 `!` 명령이 입력 훅보다 먼저 돌아 승인이 사라지던 문제를 고쳤습니다. `refactor-approve.sh`는 입력 훅이 붙이는 `--from-hook` 없이는 아무것도 바꾸지 않고, Claude가 훅 진입점(`run.sh turn|guard|post-check|session-start`)을 직접 부르는 것은 안전장치가 막습니다. 따옴표·역슬래시로 이름을 쪼개기, 새 Claude 세션에 넘기기, 한 줄 인터프리터 코드 안에서 부르기 같은 알려진 우회 모양도 막습니다(글자 조립·파일 경유 우회의 한계는 [§6-4](#6-4-한계)).
- **문제 신고 `/refactor:report`(동의형)와 문제 기록 `problems.log`** 추가([§11](#11-피드백기여라이선스)).
- **안전장치 보강** — 목적지 기준 판정·경로 정규화, 너무 긴 입력·너무 넓은 검색 범위 차단, 승인 기록·허용 파일을 복사·이동·개명·압축 해제·우회 도구로 건드리는 것 차단. 과잉 차단 완화: 안전한 환경변수 이름 조회, `.env`가 없을 때의 `.env.example` 복사, `git config --list`, `.envrc` 읽기.
- **표시 파일 세션별 분리** — `.turn.<세션ID>`, `.turn-dirty.<세션ID>`.
- **안전 실행기** — 여러 출처를 함께 보고 하나라도 운영 모양이면 가짜 값, `--check`는 값을 출력하지 않음(`.allow-env`는 호스트만). `run.sh`의 역슬래시 경로 처리 보강.
- **승인 봉인** — 줄바꿈(CRLF)과 무관하게 계산, `docs/refactor/.gitattributes` 자동 생성.
- **Windows** — 시험 하네스가 Git Bash를 자동으로 찾아 그대로 돌아감.
- **공개 저장소 준비** — MIT `LICENSE`, `SECURITY.md`, `CONTRIBUTING.md`, 이슈·PR 양식.
