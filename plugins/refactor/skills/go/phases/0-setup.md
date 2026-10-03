# 0단계: 준비 (SETUP)

목표: 안전망 상태를 확인하고, 프로젝트 프로필(`docs/refactor/PROFILE.md`)과 진행 상황 파일(`docs/refactor/STATE.md`)을 만든다. 이 단계에서만 사람에게 질문을 모아서 한 번에 한다.

## 1. 안전망 확인 (읽기만)
- `git rev-parse --is-inside-work-tree` — git 저장소가 아니면 **여기서 멈춘다.** "되돌릴 방법이 없어 위험해요. 사람이 `git init`과 첫 커밋을 먼저 해 주세요"라고 안내하고 `gate: ask-user`.
- 현재 브랜치, `git status --short`(미커밋 변경), 원격 백업 유무(`git remote`로 이름만 — 주소를 볼 때는 `git remote -v | sed -E 's#//[^/@]*@#//****@#'`처럼 토큰을 가린다).
- 폴더 안에 앱이 여럿(모노레포)이면 어느 앱을 볼지 질문 목록에 넣는다.
- **안전장치 작동 확인(1) 기본 규칙(비밀값)**: `cat .env.refactor-selftest`를 한 번 실행한다(없는 파일이라 무엇도 새지 않는다).
  - `[refactor 안전장치]` 메시지로 막히면 정상이다. 이 차단은 예상된 것이므로 보고만 하고 계속 진행한다.
  - 막히지 않고 "No such file" 같은 오류가 나오면 안전장치 훅이 동작하지 않는 것이다. 바로 아래에서 STATE.md를 만들 때 메모에 적고 사람에게 알린다: "안전장치가 꺼져 있어요. 입력 처리가 늦었을 수 있으니 먼저 `/refactor:go`를 한 번 더 입력해 보세요. 그래도 막히지 않으면 Windows면 Git for Windows(Git Bash)가 설치돼 있는지, `/hooks`에 refactor 훅이 보이는지 확인해 주세요." 사람이 그래도 진행하자고 하면 진행하되, 모든 보고 맨 위에 "⚠️ 안전장치 꺼짐"을 붙인다.
- **진행 상황 파일 만들기(자체 시험 (1) 바로 뒤, 자동 감지 전)**: `docs/refactor/STATE.md`를 `${CLAUDE_SKILL_DIR}/templates/STATE.md` 템플릿대로 만들고 `phase: SETUP`, `gate: none`, next: "준비: 자동 감지 중"으로 둔다. 첫 `/refactor:go` 직후에는 안전장치가 이 대화의 go 표시 하나로만 켜져 있어, 사람이 평범한 문장을 보내면 표시가 지워져 꺼진다 — STATE.md가 있으면 계속 켜져 있다. (git 저장소가 아니어서 위에서 멈춘 경우에는 만들지 않는다.)
- **안전장치 작동 확인(2) 리팩토링 중·/refactor:go 중 규칙**: 위에서 STATE.md를 만들었으니(리팩토링 중 규칙이 켜진 상태) 두 명령을 각각 한 번 실행한다. 둘 다 `[refactor 안전장치]`로 막혀야 정상이다(막히면 보고만 하고 계속).
  - `node -e 0` — /refactor:go 중에는 안전 실행기 없이 코드를 실행하지 못해야 한다(막히지 않으면 "go 턴 규칙이 꺼져 있음"을 STATE 메모와 보고 맨 위에 적는다).
  - `git push --dry-run __selftest__ HEAD` — 리팩토링 중에는 push가 막혀야 한다(막히지 않으면 "리팩토링 중 규칙이 꺼져 있음"을 적는다).
- **운영 설정 점검(값은 보지 않음)**: `bash "${CLAUDE_SKILL_DIR}/../../hooks/run.sh" refactor-safe-run --check`
  - 운영일 수 있는 설정 이름의 개수, "코드가 .env를 직접 읽는 흔적" 파일, `.dev.vars`·docker 경고를 PROFILE에 적는다(이름만).
  - 이후 모든 테스트·빌드는 `… refactor-safe-run -- <명령>`으로만 돌린다는 것을 보고에 한 줄로 알린다(운영 DB 대신 가짜 주소, 운영 키 대신 가짜 값).

## 2. 자동 감지 (읽기만 — 아무것도 실행하지 않는다)
- 언어·프레임워크, 패키지 관리자·lock 파일.
- 테스트·빌드·타입 검사·린트 명령의 **정의**(package.json scripts, pyproject.toml, Makefile 등). 실행하지 않는다.
- DB 종류·호스팅·배포 흔적(vercel.json, supabase/, Dockerfile, .github/workflows 등).
- 결제 흔적 검색어 예: `toss|portone|iamport|nicepay|inicis|kcp|stripe|webhook|payment`
- 수집 흔적 검색어 예: `playwright|puppeteer|selenium|cheerio|beautifulsoup|bs4|scrapy|requests.get|axios|crawl|scrap|cron|schedule`
- 로그인·관리자 흔적: `auth|login|session|admin|role|rls|policy`
- 받는 개인정보: 입력 폼 필드·DB 컬럼 이름(phone, address, name, email, birth 등). **값은 보지 않는다.**

## 3. 사람에게 질문 (한 번에, 최대 6개 — 이 대화가 WSL 안이면 7개, 감지 결과를 보기로 제시)
AskUserQuestion 도구가 있으면 쓰고, 없으면 번호 목록으로 묻는다.
- 묻기 **전에** STATE의 `gate`를 `ask-user`로, next를 "준비 질문에 답하기"로 **바꾼다**(STATE.md는 1에서 이미 만들었다). 질문 목록은 "대기 중인 결정·질문"에 적는다(여러 프로젝트 현황표에 "사장님 차례"로 보이게).
- 사용자가 명령 없이 대화로 답해도 그 답으로 이어서 진행한다.
1. 이 서비스는 무엇이고 실제 사용자·주문이 있나요? (감지 결과 제시)
2. 결제가 있나요? 결제사는? (감지: …)
3. 다른 사이트·API에서 데이터를 가져오나요? 어디서? (감지: …)
4. 운영 DB와 개발용 DB가 나뉘어 있나요? 결제·알림톡은 테스트 키가 따로 있나요? (모르면 "모름") — "하나뿐"이나 "모름"이면 DB·외부 API를 쓰는 테스트는 돌리지 않고, 개발용 DB·테스트 키 준비를 계획서 맨 앞(Phase 0)에 넣는다고 알려 준다. "나뉘어 있음"이고 개발용 DB가 원격이면, 개발용 값을 사장님이 `docs/refactor/.allow-env`에 적어야 테스트가 그 DB를 쓸 수 있다고 안내한다. 주소 값은 `--check`가 보여 준 **호스트와 함께** `이름=호스트`로(나중에 운영 주소로 바뀌면 다시 가려짐), 키 값은 이름만 적는다. 명령 한 줄을 만들어 준다: 터미널에서 `printf 'DATABASE_URL=db.<개발용 호스트>\nSUPABASE_ANON_KEY\n' >> "<프로젝트 폴더>/docs/refactor/.allow-env"` (CLI 라면 입력창에 `! printf …` 도 됨) — 호스트가 개발용 프로젝트인지 사장님이 확인한 뒤에만.
5. 절대 멈추면 안 되는 기능은? (예: 주문 접수, 알림톡 발송)
6. 이번 목표(구멍 막기 / 속도 / 코드 정리 / 전부)와, 작업용 브랜치 `refactor/YYYY-MM-DD`를 만들어도 될까요?
7. (이 대화가 WSL 안에서 돌 때만 — 판정은 `../SKILL.md` 의 「사람에게 주는 명령」) 사람이 칠 명령은 어느 터미널에서 치시나요? (Ubuntu / Windows PowerShell) — 답은 PROFILE 의 "사람이 명령을 치는 터미널" 칸에 적고(WSL 이면 배포판 이름 = `WSL_DISTRO_NAME` 값도), 그 뒤로는 다시 묻지 않는다.

## 4. 답을 받은 뒤
- `docs/refactor/` 폴더를 만들고 `${CLAUDE_SKILL_DIR}/templates/PROFILE.md` 형식으로 PROFILE.md를 채운다(자동 감지 항목에는 파일:줄 근거).
- 점검 범위 스위치: 결제 있음 → 결제·주문 점검 켜짐 / 수집 있음 → 데이터 수집 점검 켜짐 / 판매·회원·광고 메시지 중 하나라도 있음 → 필수 표시·동의 점검 켜짐 / 로그인·관리자 있음 → 접근 권한 점검 켜짐.
- STATE.md를 갱신한다: project 이름, `phase: MAP`, `gate: none`, "대기 중인 결정·질문"에서 답한 질문 지우기, updated.
- 브랜치 허락을 받았고 미커밋 변경이 없을 때만 `git switch -c refactor/YYYY-MM-DD`. 미커밋 변경이 있으면 만들지 말고 "먼저 커밋해 주세요"라고 안내만 한다.
- `docs/refactor/.gitignore`가 있는지 확인한다(`/refactor:go`를 입력하면 플러그인이 `.allow-*`, `.turn*`, `*.tmp.*` 세 줄로 만든다. 없으면 사람에게 알린다). 허용 파일이 git에 올라가 다른 PC에서까지 보호가 풀리는 일을 막는다.
- `docs/refactor/`는 git에 올려 두라고 안내한다(여러 PC에서 이어서 작업하려면 필요). 프로젝트 `.gitignore`가 docs를 막고 있으면 알리기만 한다.

## 5. 보고 후 자동으로 1단계(코드 지도)로 넘어간다.
