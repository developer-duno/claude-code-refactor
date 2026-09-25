# vibe-plugins — Vibe Consulting의 Claude Code 플러그인

## refactor — 운영 중인 서비스를 안전하게 리팩토링하는 플러그인

명령 하나(`/refactor:go`)로 **코드 지도 → 25항목 건강검진 → 정밀검사 → 반박 검증 → 기준선 테스트 → 계획서**까지 순서대로 진행합니다.

- 읽기만 하는 단계는 자동으로 이어 갑니다.
- 코드를 바꾸는 일은 **사장님이 승인한 단계만, 한 번에 하나씩** 합니다. 승인은 `/refactor:approve`가 남기는 기록(`APPROVALS.log`)으로만 인정합니다.
- `/refactor:go` 중의 테스트·빌드는 **안전 실행기**로 돌립니다. `.env`와 셸 환경에 있는 운영 DB 주소·키를 가짜 값으로 바꿔 실행해, 실수로 운영 데이터를 바꾸거나 알림톡을 보내는 일을 줄입니다. 다만 코드·설정 파일에 직접 적힌 키, `~/.aws` 같은 자격 증명 파일, Cloudflare·docker·Supabase 함수가 직접 읽는 설정 파일, 실제 네트워크 요청은 가려지지 않습니다(§6).
- **안전장치**가 비밀값 노출, 되돌릴 수 없는 명령, 승인 우회 같은 흔한 사고를 미리 막습니다. 사고를 줄이는 보조 장치이지 모든 우회를 막는 벽은 아니니, 중요한 변경은 사람이 한 번 더 확인하세요(§6 한계).
- 진행 상황은 프로젝트의 `docs/refactor/` 폴더에 저장되므로 대화를 닫았다 열어도 이어서 할 수 있고, 커밋·푸시해 두면 다른 PC에서도 이어서 할 수 있습니다.

---

## 1. 흐름 한눈에

```
/refactor:go
  준비(질문 6개) → 코드 지도 → 건강검진 25항목 → 정밀검사 → 반박 검증 → 기준선 계획
                                                                ⏸ /refactor:approve baseline
/refactor:go
  기준선 작성(지금 동작을 테스트로 사진 찍기)          ⏸ 사람이 커밋
/refactor:go
  계획서(무엇을·왜·어떤 순서로·얼마나 위험하게)       ⏸ /refactor:approve P0-1 P1-1 …
/refactor:go
  승인된 단계 하나 실행 → 독립 검사 → 보고           ⏸ 확인하고 커밋 → 다음 /refactor:go
  …
  남은 단계가 없거나 /refactor:go 마무리(완료 보고) → /refactor:approve 마무리 → 완료
```

⏸ 표시에서 멈춥니다. 그 사이의 읽기 단계는 알아서 이어 갑니다.

## 2. 명령 4개

| 명령 | 하는 일 | 누가 |
|---|---|---|
| `/refactor:go` | 다음 단계 진행. 뒤에 `하나씩`(한 단계만), `다시 CHECKUP`(그 단계부터 다시), `마무리`(완료 보고 — 끝내기는 `/refactor:approve 마무리`)를 붙일 수 있음 | 사장님 |
| `/refactor:approve` | 승인·취소·마무리. 예: `baseline` / `P0-1 P1-2` / `P1`(묶음 전체) / `보류 P1-2`(보류는 맨 앞에) / `마무리`(리팩토링 끝내기) / `확인`(승인 기록을 직접 고친 뒤 다시 봉인). 인자 없이 치면 승인 현황 | **사장님만** — Claude가 부르는 것은 안전장치가 막고, 계획서의 체크 표시를 고쳐도 승인으로 치지 않습니다 |
| `/refactor:status` | 이 프로젝트가 어디까지 왔는지, 다음에 뭘 치면 되는지 | 사장님·Claude |
| `/refactor:board` | 여러 프로젝트를 급한 순서로 한 표에. 예: `/refactor:board ~/projects` | 사장님·Claude |

---

## 3. 설치

### 준비물
- **Claude Code** 최신 버전 (`claude --version`)
- **git** — 리팩토링할 프로젝트는 git 저장소여야 합니다(되돌리기의 바탕).
- **Windows**: **Git for Windows(Git Bash)** 가 설치돼 있어야 안전장치가 돕니다.

### 3-1. 이 폴더를 GitHub 비공개 저장소에 올리기 (처음 한 번)

압축을 푼 `vibe-plugins` 폴더에서:

```bash
cd vibe-plugins
git init
git add -A
git commit -m "vibe-plugins 0.2.0"
gh repo create vibe-plugins --private --source . --push
```

`gh` 명령이 없으면 GitHub 웹에서 **비공개(Private)** 저장소 `vibe-plugins`를 만들고, 화면에 나오는 안내대로 `git remote add origin …` → `git push -u origin main`을 하면 됩니다.

### 3-2. 프로젝트마다 설치 (프로젝트 폴더에서 두 줄)

```bash
claude plugin marketplace add <GitHub아이디>/vibe-plugins --scope local
claude plugin install refactor@vibe-consulting --scope local
```

- 두 줄 모두 **그 프로젝트의 `.claude/settings.local.json`에만** 적힙니다. 전역 설정(`~/.claude/settings.json`)은 바뀌지 않고, git에도 올라가지 않습니다.
- 비공개 저장소라서 그 PC의 git이 GitHub에 로그인돼 있어야 합니다(`gh auth login` 한 번).
- 설치 뒤 Claude Code를 다시 열면 적용됩니다.

### 3-3. 잘 깔렸는지 확인

1. Claude Code에서 `/refactor:status` → "아직 시작하지 않았어요"가 나오면 명령 OK.
2. `/hooks`를 열어 refactor의 훅(PreToolUse·PostToolUse·UserPromptSubmit·SessionStart)이 보이면 안전장치 OK.
3. 첫 `/refactor:go`의 준비 단계에서 안전장치가 실제로 막는지 스스로 시험합니다(항상 켜진 규칙, 리팩토링 중 규칙, `/refactor:go` 중 규칙 각각 한 번). 막히지 않으면 보고해 줍니다.

> 설치 없이 이번 대화에서만 시험해 보기: `claude --plugin-dir ~/vibe-plugins/plugins/refactor`

---

## 4. 쓰는 법

1. **시작** — `/refactor:go` → 준비 질문 6개에 답하기(서비스 종류, 결제·수집 여부, 운영/개발 DB 분리, 멈추면 안 되는 기능, 목표, 작업 브랜치). 그다음 진단 단계는 자동으로 진행하다가 **기준선 계획**에서 멈춥니다.
2. **기준선** — `docs/refactor/BASELINE.md`를 훑어보고 `/refactor:approve baseline` → `/refactor:go`. 기준선 테스트를 만든 뒤 커밋을 부탁합니다. 알려 준 한 줄(`! git add -A && git commit -m "…"`)을 입력하고 다시 `/refactor:go`.
3. **계획서** — `docs/refactor/REFACTOR_PLAN.md`를 보고 할 단계만 승인: `/refactor:approve P0-1 P1-1`. 승인하면 "👤 사람이 직접 할 일"(예: 결제사 테스트 키 발급)을 먼저 알려 줍니다. 승인은 그 순간의 카드 내용에 묶입니다 — 승인한 뒤 카드 내용이 바뀌면 그 단계는 실행하지 않고 다시 승인을 받습니다.
4. **실행** — `/refactor:go` 한 번에 **한 단계만** 고치고, 기준선으로 확인하고, 다른 AI가 독립 검사를 한 뒤 보고하고 멈춥니다. 테스트·빌드는 안전 실행기(운영 키 대신 가짜 값)로 돌립니다. 화면 확인은 **개발용 DB·테스트 키로 켠 개발 서버**에서 하세요(운영 DB가 하나뿐이면 보기만 하고 저장·결제·발송 버튼은 누르지 않기). 알려 준 커밋 한 줄을 입력한 뒤 다음 `/refactor:go`.
5. **끝** — 승인한 단계가 다 끝나면 완료 보고를 합니다. `/refactor:approve 마무리`를 입력해야 끝납니다(그래야 리팩토링 중 안전장치가 꺼집니다). 남은 단계를 안 할 거면 먼저 `/refactor:approve 보류 <ID>`. 한두 달 뒤 `/refactor:go 다시 CHECKUP`으로 재점검.

**팁**
- 처음에는 `/refactor:go 하나씩`으로 한 단계씩 보면서 진행하면 이해하기 쉽습니다.
- 대화가 길어지면 `/clear` 후 `/refactor:go` — 진행 상황은 파일에 있으니 그대로 이어집니다.
- 입력창에서 `!`로 시작하는 줄은 **사장님이 직접 실행하는 명령**입니다(커밋·허용 파일 만들기 등). 안전장치를 거치지 않습니다.

## 5. 여러 프로젝트 관리

아무 프로젝트에서나 `/refactor:board` — 그 프로젝트의 상위 폴더에 있는 프로젝트들을 모아 급한 순서로 보여 주고, 이번 주에 먼저 할 일 3개를 골라 줍니다. 프로젝트들이 한 폴더에 모여 있지 않으면 `/refactor:board ~/projects`처럼 폴더를 알려 주세요.

| 상태 | 뜻 |
|---|---|
| 🔴 급한 구멍 | 아직 안 막은 위험(🔴)이 있음 |
| 🙋 사장님 차례 | 승인이나 답변만 하면 진행됨 |
| ▶ 다음 단계 가능 | 승인된 단계가 실행을 기다림 |
| ⏳ 진행 중 | 진단 중 |
| ⏰ N일 멈춤 | 14일 넘게 진행이 없음 |
| ⚠허용파일 | 기준선·마이그레이션 수정 허용 파일이 남아 있음 |

---

## 6. 안전장치가 하는 일

Claude가 명령을 실행하거나 파일을 고치기 **직전에** 검사해서 위험하면 막습니다. 막으면 `[refactor 안전장치] …` 메시지와 함께 무엇을 대신하면 되는지(→) 알려 주고, Claude는 우회하지 않고 사장님께 보고합니다.

| 언제 | 막는 것 |
|---|---|
| **항상** (이 플러그인을 켠 프로젝트) | `.env`·키 파일(`.git/config`·`.npmrc` 포함)을 읽기/출력/복사/전송/수정하는 명령(파이프·`$( )`·와일드카드로 나눈 것 포함), 환경변수 출력, 토큰이 든 원격 주소 출력, git 기록 속 옛 비밀값 검색(`git log -p … \| grep` 등), git이 무시하지 않는 `.env`가 든 범위의 내용 검색(Grep 도구 포함) · 강제 push, `reset --hard`, `clean -f`, `checkout .`, `rm -rf ~` 같은 대량 삭제, DB 테이블 삭제·초기화 · 승인 스크립트, 승인 기록·허용 파일 만들기, 플러그인 폴더 수정 |
| **리팩토링 진행 중** (완료 전) | push·배포·운영 DB 적용·원격 DB 접속, 배포/DB용 npm 스크립트, 플러그인 끄기, Claude 설정 수정, `git stash`, 파일을 지정하지 않은 `git log -p`, 프로젝트 전체 포맷터 · 커밋된 기준선 테스트와 마이그레이션 파일 수정(스냅숏 갱신 옵션 포함) |
| **`/refactor:go` 실행 중** | 대표 실행 명령(npm·pnpm·yarn·bun·npx, python·node·deno, pytest, uv·poetry·pipenv run, make, turbo·nx, docker compose 등)은 안전 실행기로만 · 읽기 전용 단계, 그리고 실행 대기(승인됨) 단계가 없는 단계 실행 중에는 `docs/refactor/` 밖의 코드 수정 금지 |

셸 명령(Bash·PowerShell·Monitor 도구)과 파일 도구, Grep 도구, MCP 도구를 모두 봅니다. 명령이 끝난 뒤에도(백그라운드·Monitor 명령은 시작 직후에) 한 번 더 확인해서, **이번 턴에** 커밋된 기준선·마이그레이션 파일이나 승인 기록(`APPROVALS.log`)이 바뀌었으면 그 턴의 Claude에게 바로 알립니다(사장님이 원래 고치던 파일은 알리지 않습니다). 승인 기록은 `/refactor:approve`가 쓸 때마다 봉인되므로, 그 밖에서 바뀐 기록은 사장님이 `/refactor:approve 확인`을 입력하기 전까지 다음 대화에서도 인정되지 않습니다(`/refactor:status`가 봉인 뒤 달라진 줄을 보여 줍니다). 다만 승인 기록과 봉인을 함께 다시 쓰는 스크립트까지는 막지 못합니다(아래 한계).

### 안전 실행기 (운영 키 대신 가짜 값)

`/refactor:go` 중 Claude는 테스트·빌드를 이렇게 돌립니다(대표 실행 명령은 안전장치가 강제하고, 그 밖의 실행 명령에도 Claude가 직접 붙이도록 되어 있습니다):

```
bash "<플러그인 폴더>/hooks/run.sh" refactor-safe-run -- npm test
```

`.env`(세 단계 아래 폴더까지)와 셸 환경에서 운영일 수 있는 값(DB 주소, API 키, 결제 키, 서버 주소 등)을 **이름과 값의 모양으로** 찾아(값은 출력하지 않음) 가짜 값(`127.0.0.1:9` 등, 접속하면 바로 실패하는 주소)으로 바꿔 실행합니다. 테스트 키(`test_…`, `sk_test_…`)·로컬 주소·숫자·짧은 설정값(버킷 이름, 템플릿 코드 등)·파일 경로는 그대로 둡니다. `refactor-safe-run --check`로 무엇이 바뀌는지 이름만 볼 수 있습니다.

- 가장 안전한 것은 **개발용 DB와 테스트 키를 따로 두는 것**입니다. 개발용 DB가 원격(예: 개발용 Supabase 프로젝트)이라 가짜 값으로 바뀌면 곤란할 때는, 개발용인지 확인한 뒤 사장님이 그 이름을 허용 목록에 적습니다: `! printf 'DATABASE_URL=db.<개발용 프로젝트>.supabase.co\n' >> "<프로젝트 폴더>/docs/refactor/.allow-env"` — `이름=호스트`로 적으면 그 값이 나중에 다른(운영) 주소로 바뀌었을 때 자동으로 다시 가립니다. `--check`가 허용한 이름의 지금 호스트를 보여 주니, 개발용 프로젝트 주소가 맞는지 확인한 뒤 적으세요(RLS가 약하면 공개 키로도 쓰기가 되니 운영 주소는 절대 적지 않기). 한 줄에 하나, git에 올라가지 않음. 운영 DB가 하나뿐이면 DB를 쓰는 테스트는 돌리지 않고, DB 없이 확인할 수 있는 계산·문구 기준선만 만듭니다.
- 코드가 `.env`를 직접 열어 읽거나(`dotenv_values`, `readFileSync('.env')`) 덮어쓰기 옵션(`override: true`)을 쓰면 가짜 값이 무시될 수 있습니다. `--check`가 그런 파일을 찾아 알려 줍니다.
- 가려지지 않는 것: 코드·설정 파일에 직접 적힌 키·주소, `~/.aws`·gcloud 같은 자격 증명 파일, Cloudflare(wrangler)가 직접 읽는 `.dev.vars`·`.env`, docker compose의 `env_file`, Supabase 함수의 `supabase/functions/.env`, 그리고 코드가 하는 실제 네트워크 요청(수집 대상 사이트 등). `--check`가 세 단계 아래 폴더까지 이런 파일의 흔적을 찾아 알려 주지만, 코드 속에 직접 적힌 값은 찾지 못합니다.
- 안전 실행기로 만든 빌드 결과(`.next`, `dist`)에는 가짜 값이 들어 있습니다. **배포에 쓰지 말고** 배포 전에는 평소 방법으로 다시 빌드하세요.

### 한계 — 꼭 알아 두세요

- 안전장치는 **흔한 위험 명령을 모양으로 알아보고** 막는 보조 장치입니다. 스크립트를 거친 수정, 일부러 꼬아 쓴 명령 등 모든 우회를 막지는 못합니다. 사고(실수)를 줄이는 장치이지, 악의적인 공격을 막는 장치가 아닙니다.
- 안전장치 스크립트가 고장 나거나 실행되지 못하면 **막지 않고 통과**시킵니다(모든 작업이 멈추는 것을 막기 위해). 그래서 준비 단계에서 작동 시험을 합니다.
- 승인의 근거는 `APPROVALS.log` 한 곳입니다. 이 파일을 흔한 방법으로 고치는 명령은 막고, `/refactor:approve` 밖에서 바뀌면 봉인이 깨져 사장님이 확인하기 전까지 어떤 단계도 실행하지 않습니다(기록과 봉인을 함께 다시 쓰는 스크립트까지는 못 막음). 그래도 커밋 전에 `git diff`로 계획서·승인 기록의 변화를 한 번 보는 습관이 가장 확실합니다.
- AI가 진행 상황 파일(STATE.md)의 단계를 바꿔도 안전장치가 풀리지 않게 했습니다: 기준선 작성은 승인 기록으로, 끝(DONE)은 `/refactor:approve 마무리` 기록으로만 인정하고, `/refactor:go` 중에는 "승인된 실행 대기 단계가 있는 단계 실행"과 "승인된 기준선 작성" 때만 코드 수정을 허락합니다. 이상하면 `/refactor:status`로 확인하세요.
- 이전 버전에서 시작한 프로젝트는 한 번 `/refactor:approve 확인`(승인 기록 봉인)과, 이미 끝난 프로젝트는 `/refactor:approve 마무리`가 필요합니다.
- 안전 실행기 강제는 `/refactor:go`로 시작한 대화(그 뒤 질문에 답하거나 단계 보고를 받은 뒤 이어지는 대화 포함)에만 적용됩니다. 평소 개발 대화에서는 막지 않습니다.

### 일부러 풀어야 할 때 (사람만 가능)

동작을 일부러 바꾸는 단계에서 기준선 테스트를 새 동작으로 고쳐야 하면, Claude가 멈추고 아래처럼 부탁합니다. 입력창에 그대로 붙여 넣으세요.

```
! touch "<프로젝트 폴더>/docs/refactor/.allow-baseline-edit"
```

마이그레이션 파일은 `.allow-migration-edit`. **작업을 커밋한 다음에는 꼭 지우세요**(`! rm "<같은 경로>"`). 허용 파일은 git에 올라가지 않게 되어 있습니다.

---

## 7. 만들어지는 파일 (`docs/refactor/`)

| 파일 | 내용 |
|---|---|
| `STATE.md` | 진행 상황(현황표가 읽음) |
| `PROFILE.md` | 서비스 정보와 답변 기록 |
| `PROJECT_MAP.md` | 코드 지도 |
| `AUDIT_REPORT.md`, `audit/*.md`, `AUDIT_VERIFY.md` | 건강검진·정밀검사·반박 검증 |
| `BASELINE.md` | 기준선 계획과 결과 |
| `REFACTOR_PLAN.md` | 공사 계획서(단계 카드와 승인 칸 — 승인 칸은 기록을 보기 좋게 옮겨 적은 것) |
| `EXECUTION_LOG.md` | 실행 기록 |
| `APPROVALS.log` | **승인의 유일한 근거.** 언제·무엇을·어떤 카드 내용(지문)으로 승인했는지. `/refactor:approve`만 쓰도록 되어 있습니다 |
| `approved/<ID>.md` | 승인할 때의 카드 내용(나중에 카드가 바뀌면 무엇이 바뀌었는지 보여 줄 때 씀) |
| `.turn`, `.turn-dirty`, `.allow-*`(`.allow-env` 포함) | 플러그인·사람용 표시 파일(git에 올라가지 않음) |

`docs/refactor/`는 **git에 커밋해 두세요.** 다른 PC에서 이어서 하려면 필요합니다.

## 8. 지금 쓰는 루틴과 함께

`/resume → /blueprint → /guard → /work → /review → /wrap` 루틴을 쓰고 있다면, 각 명령 파일에 한 줄씩 더하면 자연스럽게 이어집니다.

- `/resume`에: `docs/refactor/STATE.md가 있으면 /refactor:status 결과를 함께 보여 준다.`
- `/wrap`에: `리팩토링 진행 중(docs/refactor/STATE.md)이면 커밋 전에 /refactor:status로 멈춘 단계와 사람이 할 일을 요약한다.`

## 9. 비용·시간

- 건강검진·정밀검사는 보조 AI(감사관)를 여러 명 동시에 씁니다. 프로젝트가 크면 토큰을 꽤 씁니다.
- 감사관은 비용을 아끼려고 Sonnet 모델을 씁니다(`agents/auditor.md`의 `model:` 줄에서 바꿀 수 있음).
- 처음 한 번의 진단(준비~기준선 계획)이 가장 큽니다. 그 뒤로는 승인한 단계만큼만 씁니다.

## 10. 업데이트·끄기

```bash
claude plugin marketplace update vibe-consulting
claude plugin update refactor@vibe-consulting        # 그다음 Claude Code 다시 열기
claude plugin disable refactor@vibe-consulting       # 잠시 끄기
claude plugin uninstall refactor@vibe-consulting     # 지우기
```

플러그인을 고쳐 배포할 때는 `plugins/refactor/.claude-plugin/plugin.json`과 `.claude-plugin/marketplace.json`의 `version`을 함께 올리세요.

## 11. 문제가 생기면

| 증상 | 할 일 |
|---|---|
| 안전장치가 아무것도 안 막음 | Windows면 Git for Windows 설치 확인 → Claude Code 다시 열기 → `/hooks`에서 refactor 훅 확인 |
| `[refactor 안전장치]`로 멈춤 | 정상입니다. → 줄의 안내를 따르거나, 정말 필요하면 사장님이 `!`로 직접 실행 |
| "이번 턴에 보호된 파일이 바뀌었습니다" | `git diff <파일>`로 무엇이 바뀌었는지 보고 결정하세요. 사장님이 일부러 바꾼 것이면 그대로 두면 됩니다 |
| 승인이 안 먹힘 | `/refactor:approve`(인자 없이)로 현황과 사용법 확인. 계획서의 체크 표시를 손으로 고치는 것은 승인으로 치지 않습니다 |
| "승인 뒤 카드 내용이 바뀜" | 승인한 뒤 그 단계 카드가 고쳐졌습니다. `/refactor:status`가 보여 주는 바뀐 줄(− 승인 때 / + 지금)을 읽어 보고 괜찮으면 `/refactor:approve <ID>`로 다시 승인 |
| "이번 턴에 승인 기록이 바뀌었습니다" / "승인 기록이 /refactor:approve 밖에서 바뀌었습니다" | `git diff docs/refactor/APPROVALS.log`로 보고, 모르는 줄이면 지운 뒤 `/refactor:approve 확인` |
| "DONE이지만 마무리 확인이 없어 안전장치가 켜져 있습니다" | 정말 끝났으면 `/refactor:approve 마무리` |
| "체크 표시만 있고 승인 기록이 없음" | 누군가 계획서를 손으로 체크한 흔적입니다. 실행하려면 `/refactor:approve <ID>` |
| 테스트가 `127.0.0.1:9` 연결 실패로 끝남 | 정상입니다 — 안전 실행기가 운영 DB 대신 가짜 주소를 넣었습니다. DB가 필요한 테스트는 개발용 DB를 만든 뒤, 그 이름을 `docs/refactor/.allow-env`에 적고 돌립니다 |
| 진행이 꼬임 | `/refactor:status`로 확인 → `/refactor:go 다시 <단계>` |

---

## 12. 폴더 구조와 검증 (고치는 사람용)

```
vibe-plugins/
├─ .claude-plugin/marketplace.json      마켓플레이스(플러그인 목록)
├─ .gitattributes                        스크립트 줄바꿈을 LF로 고정
├─ tests/test_guard.py                   안전장치 시험(522개)
├─ tests/test_scripts.py                 승인·현황·안전 실행기 시험(58개)
└─ plugins/refactor/
   ├─ .claude-plugin/plugin.json
   ├─ skills/go/        지휘자: SKILL.md, phases/0~7, checklists/(건강검진·정밀 12종), templates/
   ├─ skills/approve/   승인(사용자만) — scripts/refactor-approve.sh 실행
   ├─ skills/status/    현황 — scripts/refactor-status.sh
   ├─ skills/board/     여러 프로젝트 현황표 — scripts/refactor-board.sh
   ├─ agents/           auditor(감사관) · verifier(반박 검증) · reviewer(실행 후 검사)
   ├─ hooks/            hooks.json, run.sh(실행기), guard.sh, post-check.sh, turn.sh, session-start.sh
   └─ scripts/          refactor-approve.sh · refactor-status.sh · refactor-board.sh
                        refactor-lib.sh(승인 기록·카드 읽기 공용) · refactor-safe-run.sh(안전 실행기)
```

```bash
python3 tests/test_guard.py && python3 tests/test_scripts.py   # 안전장치·스크립트 시험
GUARD_BASH=/bin/bash python3 tests/test_guard.py              # macOS 기본 bash 3.2로 시험
claude plugin validate --strict plugins/refactor && claude plugin validate --strict .
```

## 13. 다음 계획

- **사이트 공개 전**: 실제 프로젝트 2~3개에서 끝까지 써 보기 → 문구 다듬기 → 라이선스 정하기(지금은 비공개 `UNLICENSED`).
- **vibe.2u.pe.kr 연결**: 사이트의 리팩토링 카드(N1~N8)와 이 플러그인의 단계를 짝지어 안내.
- **(선택) 관제 에이전트**: 여러 프로젝트의 재점검(`다시 CHECKUP`)을 정해진 날 자동으로 돌려 현황표를 갱신 — 필요해지면 예약 작업이나 GitHub Actions로 확장.
