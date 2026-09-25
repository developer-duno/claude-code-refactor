#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Vibe Refactor 안전장치 (PreToolUse 훅) — hooks.json이 run.sh를 거쳐 실행한다.
#
# Claude가 도구를 쓰기 직전에 실행된다. 위험한 호출이면 stderr 메시지와 함께 42로 끝나고(run.sh가 2 = 차단으로 바꾼다),
# 아니면 0으로 통과시킨다. 이 스크립트가 고장 나거나 실행되지 못하면 막지 못하고 통과된다 — 사고를 줄이는 보조 장치이지,
# 모든 우회를 막는 벽이 아니다.
#
# 항상 켜진 규칙 — 플러그인이 켜진 모든 대화:
#   1. 비밀값 노출: .env·키 파일 읽기/출력/복사/수정, 환경변수 출력, 원격 주소 속 토큰, git 기록 속 옛 비밀값,
#      비밀값 파일이 든 범위의 내용 검색(Grep 도구 포함)
#   2. 되돌릴 수 없는 명령: 강제 push, reset --hard, clean -f, checkout ., rm -rf ~ 류, DB 삭제·초기화
#   3. 사람 전용: 승인 스크립트, .allow-* 허용 파일, APPROVALS.log, .turn*, 플러그인 폴더
# 리팩토링 진행 중(docs/refactor/STATE.md가 있고 phase가 DONE이 아님)에만 켜지는 규칙:
#   4. push·배포·DB 구조 적용·운영 DB 접속·배포성 npm 스크립트·플러그인 끄기·Claude 설정 수정·stash
#   5. 기준선 테스트와 이미 커밋된 마이그레이션 파일 수정(스냅숏 갱신·포맷터 포함)
#      → 사람이 docs/refactor/.allow-baseline-edit / .allow-migration-edit 를 만들면 풀린다
#   6. /refactor:go 실행 중: 읽기 전용 단계에서는 docs/refactor 밖 수정 금지,
#      모든 단계에서 테스트·빌드·앱 실행은 안전 실행기(refactor-safe-run)를 거쳐야 한다(운영 키 대신 가짜 값)
#
# Bash·PowerShell·Monitor(셸 명령), 파일 도구, Grep, MCP 도구를 본다. 그 밖의 도구도 command 칸이 있으면 셸 명령으로 본다.
# bash 3.2 이상(macOS·Linux·Windows Git Bash). 거의 모든 판정을 bash 내장 기능으로 해서 빠르다.
# ─────────────────────────────────────────────────────────────────────────────

LC_ALL=C
export LC_ALL
shopt -u patsub_replacement 2>/dev/null
shopt -s nocasematch

IFS= read -r -d '' input || true

BS='\'; Q='"'; SL='/'; PH=$'\001'; NL=$'\n'; TAB=$'\t'
P_BS2='\\'; P_BSQ='\"'; P_BSSL='\/'; P_BSN='\n'; P_BSR='\r'; P_BST='\t'

block() {
  printf '[refactor 안전장치] %s\n' "$1" >&2
  if [ -n "${2:-}" ]; then printf '  → %s\n' "$2" >&2; fi
  printf '  (같은 결과를 내는 다른 명령으로 우회하지 말고, 무엇이 막혔는지 사용자에게 보고하세요. → 로 안내된 방법은 써도 됩니다.)\n' >&2
  exit 42
}
has() { [[ $1 =~ $2 ]]; }

# JSON 문자열 값(첫 번째) → JV (이스케이프는 그대로)
jget() {
  JV=""
  local re="\"$1\"[[:space:]]*:[[:space:]]*\"(([^\"\\\\]|\\\\.)*)\""
  if [[ $input =~ $re ]]; then JV=${BASH_REMATCH[1]}; fi
}
# 판정용 풀기(줄바꿈 → " ; ") → UV. 아주 긴 값이나 히어독(<<)이 든 값은 awk로(bash 3.2에서 느려지지 않게)
# 히어독 본문: cat·tee 가 받아 파일이나 커밋 메시지로 쓰는 본문(출력이 파이프로 넘어가지 않고, 같은 명령 안에서 그 파일을
# 실행하지 않을 때)은 데이터다. 구분자가 따옴표로 묶였으면(<<'EOF') 본문을 판정에서 빼고, 따옴표가 없으면(<<EOF) 실제로
# 실행되는 부분($( )·`…`·$변수)만 남긴다. 그 밖의 본문(python3 - <<EOF, bash <<EOF, psql <<EOF 등)은 통째로 본다.
unesc_line() {
  case "$1" in *'<<'*) ;; *) [ "${#1}" -gt 6000 ] || { unesc_short "$1"; return 0; } ;; esac
  UV=$(printf '%s' "$1" | awk 'BEGIN { RS = "\001" } {
    s = $0; gsub(/\\\\\\r\\n|\\\\\\n/, " ", s); gsub(/\\\\/, "/", s); gsub(/\\"/, "\"", s); gsub(/\\\//, "/", s); gsub(/\\r/, "", s); gsub(/\\t/, " ", s)
    n = split(s, L, /\\n/); nh = 0; delim = ""
    for (i = 1; i <= n; i++) {
      line = L[i]
      if (delim != "") { t = line; sub(/^[ \t]+/, "", t); if (t == delim) { HE[nh] = i; delim = "" }; continue }
      if (!match(line, /<<-?[ \t]*["\047\/]?[A-Za-z_][A-Za-z0-9_]*["\047]?/)) continue
      pre = substr(line, 1, RSTART - 1); post = substr(line, RSTART + RLENGTH); tok = substr(line, RSTART, RLENGTH)
      if (pre ~ /[<0-9]$/ || pre ~ /\$\(\([^)]*$/) continue   # <<< 문자열, $(( 1<<X )) 계산은 히어독이 아님
      nh++; HS[nh] = i; HE[nh] = n + 1
      d = tok; sub(/^<<-?[ \t]*/, "", d); HQ[nh] = (d ~ /^["\047\/]/); gsub(/["\047\/]/, "", d); delim = d
      HC[nh] = (pre ~ /(^|[;&|(]|\$\()[ \t]*(cat|tee)([ \t]|$)[^;&|(]*$/ && post !~ /\|/)
      tg = ""
      if (match(pre, />[ \t]*["\047]?[^ \t"\047;&|<>]+/)) { tg = substr(pre, RSTART, RLENGTH); sub(/^>[ \t]*["\047]?/, "", tg) }
      else if (match(pre, /tee[ \t]+(-a[ \t]+)?["\047]?[^ \t"\047;&|<>]+/)) { tg = substr(pre, RSTART, RLENGTH); sub(/^tee[ \t]+(-a[ \t]+)?["\047]?/, "", tg) }
      else if (match(post, />[ \t]*["\047]?[^ \t"\047;&|<>]+/)) { tg = substr(post, RSTART, RLENGTH); sub(/^>[ \t]*["\047]?/, "", tg) }
      HT[nh] = tg; HP[nh] = post
    }
    for (h = 1; h <= nh; h++) {
      DROP[h] = 0
      if (!HC[h]) continue
      run = 0
      if (HT[h] != "") {
        t = HT[h]; sub(/^.*\//, "", t)   # 파일 이름으로 찾는다(./x.sh, /tmp/x.sh 모두)
        if (index(HP[h], t) && HP[h] ~ /(bash|sh|zsh|dash|python3?|node|ruby|perl|php|deno|bun|source|\.)[ \t]/) run = 1
        for (i = HE[h] + 1; i <= n && !run; i++) if (index(L[i], t) && L[i] ~ /(bash|sh|zsh|dash|python3?|node|ruby|perl|php|deno|bun|source|chmod|\.\/|\.)[ \t]*/) run = 1
      }
      if (!run) DROP[h] = HQ[h] ? 1 : 2   # 1 = 본문 빼기, 2 = 실행되는 부분만 남기기
    }
    out = ""
    for (i = 1; i <= n; i++) {
      inb = 0
      for (k = 1; k <= nh; k++) if (i > HS[k] && i <= HE[k]) { inb = k; break }
      if (inb && i == HE[inb]) continue
      if (inb && DROP[inb] == 1) continue
      if (inb && DROP[inb] == 2) {
        t = L[i]; parts = ""
        while (match(t, /\$\([^)]*\)|`[^`]*`|\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/)) { parts = parts " " substr(t, RSTART, RLENGTH); t = substr(t, RSTART + RLENGTH) }
        if (parts != "") out = out " ; " parts
        continue
      }
      out = out (out == "" ? "" : " ; ") L[i]
    }
    printf "%s", substr(out, 1, 20000) }')
}
unesc_short() {
  local v=$1
  v=${v//"$P_BS2"/$PH}
  # 줄 이어쓰기(\ + 줄바꿈)는 한 줄로 합친다 — 명령이 두 조각으로 나뉘어 규칙을 피하지 않게
  v=${v//"$PH$P_BSR$P_BSN"/ }; v=${v//"$PH$P_BSN"/ }
  v=${v//"$P_BSQ"/$Q}; v=${v//"$P_BSSL"/$SL}
  v=${v//"$P_BSN"/ ; }; v=${v//"$P_BSR"/ ; }; v=${v//"$P_BST"/ }
  UV=${v//$PH/$BS}
}

# ── 기본 정보 ───────────────────────────────────────────────────────────────
jget tool_name; tool=$JV
jget session_id; sid=$JV
proj_raw=${CLAUDE_PROJECT_DIR:-}
if [ -z "$proj_raw" ]; then jget cwd; unesc_line "$JV"; proj_raw=$UV; fi
proj=${proj_raw//"$BS"/$SL}
proj=${proj%/}
rdir="$proj/docs/refactor"

phase=""
if [ -f "$rdir/STATE.md" ]; then
  phase="UNKNOWN"
  re_phase='^phase:[[:space:]]*"?([A-Za-z_]+)'
  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1)); [ "$n" -gt 60 ] && break
    if [[ $line =~ $re_phase ]]; then phase=${BASH_REMATCH[1]}; break; fi
  done < "$rdir/STATE.md"
fi
refactor_on=0
case "$phase" in "") refactor_on=0 ;; *) refactor_on=1 ;; esac
# DONE은 사용자가 /refactor:approve 마무리 로 확인했을 때만 인정한다(AI가 STATE만 DONE으로 바꿔 안전장치를 끄지 못하게)
if [ "$phase" = "DONE" ] && [ -n "${REFACTOR_ROOT:-}" ] && [ -f "$REFACTOR_ROOT/scripts/refactor-lib.sh" ]; then
  eval "$(tr -d '\r' < "$REFACTOR_ROOT/scripts/refactor-lib.sh")"
  rl_done_confirmed "$rdir" && refactor_on=0
fi

# 기준선 작성 단계는 기준선 계획이 실제로 승인됐을 때만 인정한다(STATE의 phase만 바꿔서 풀 수 없게):
#   phase가 BASELINE + 승인 기록(APPROVALS.log)의 마지막 BASELINE 기록이 '승인'이고 지금 계획 내용과 지문이 같음
#   + 아직 계획서(REFACTOR_PLAN.md)가 없음(계획서 단계 뒤에 phase만 되돌려 다시 여는 것을 막는다)
# 계획서 파일 속 체크 표시는 보지 않는다(글자만 바꿔 승인을 흉내 낼 수 없게).
in_baseline_phase=0
lib="${REFACTOR_ROOT:-}/scripts/refactor-lib.sh"
if [ "$phase" = "BASELINE" ] && [ -f "$rdir/BASELINE.md" ] && [ -f "$rdir/APPROVALS.log" ] && [ ! -f "$rdir/REFACTOR_PLAN.md" ] \
   && [ -n "${REFACTOR_ROOT:-}" ] && [ -f "$lib" ]; then
  eval "$(tr -d '\r' < "$lib")"
  rl_base_state "$rdir/BASELINE.md" "$rdir/APPROVALS.log"
  [ "$RL_STATE" = "approved" ] && in_baseline_phase=1
fi
allow_baseline=0; [ -f "$rdir/.allow-baseline-edit" ] && allow_baseline=1
allow_migration=0; [ -f "$rdir/.allow-migration-edit" ] && allow_migration=1

# /refactor:go 로 시작한 턴인가(UserPromptSubmit 훅 turn.sh가 기록: 1줄 "go <세션ID>", 2줄 "ready <실행 대기 단계들>")
go_turn=0; t_ready="?"
if [ -f "$rdir/.turn" ]; then
  t_kind=""; t_sid=""; t_rk=""; t_rest=""
  { read -r t_kind t_sid; read -r t_rk t_rest; } < "$rdir/.turn"
  [ "$t_kind" = "go" ] && [ -n "$sid" ] && [ "$t_sid" = "$sid" ] && go_turn=1
  [ "$t_rk" = "ready" ] && t_ready=$t_rest
fi
ro_phase=0
case "$phase" in SETUP|MAP|CHECKUP|DEEP|VERIFY|BASELINE_PLAN|PLAN) ro_phase=1 ;; esac
fence=0; fence_why=""
if [ "$go_turn" = 1 ] && [ "$ro_phase" = 1 ]; then fence=1; fence_why="지금은 /refactor:go 의 읽기 전용 단계($phase)라"; fi
# /refactor:go 중 docs/refactor 밖 수정은 허락된 경우에만: 단계 실행(EXECUTE)+실행 대기 있음, 또는 기준선 작성(BASELINE)+승인 유효.
# 그 밖의 단계 이름(마무리 확인 없는 DONE, 목록에 없는 이름 등)은 모두 막는다.
if [ "$go_turn" = 1 ] && [ "$fence" = 0 ] && [ "$phase" != "EXECUTE" ] && [ "$phase" != "BASELINE" ]; then fence=1; fence_why="지금 단계($phase)에서는 코드를 고치지 않아(단계 실행은 승인된 실행 대기 단계가 있을 때만)"; fi
# 기준선 작성(BASELINE)인데 기준선 계획 승인이 유효하지 않으면(승인 없음·계획 바뀜·계획서가 이미 있음) 코드를 고치지 않는다
if [ "$go_turn" = 1 ] && [ "$phase" = "BASELINE" ] && [ "$in_baseline_phase" = 0 ]; then fence=1; fence_why="기준선 계획 승인이 유효하지 않아(승인 없음·승인 뒤 계획 바뀜·계획서가 이미 있음)"; fi
# 단계 실행(EXECUTE)인데 이번 /refactor:go 를 시작할 때 실행 대기(승인됨) 단계가 하나도 없었으면 코드를 고치지 않는다
if [ "$go_turn" = 1 ] && [ "$phase" = "EXECUTE" ] && { [ -z "$t_ready" ] || [ "$t_ready" = "?" ]; }; then fence=1; fence_why="승인된 실행 대기 단계가 없어(지금 상태의 ▶ 실행 대기가 비어 있음)"; fi

has_env_file=0
for f in "$proj"/.env*; do
  [ -e "$f" ] || continue
  case "${f##*/}" in *.example|*.sample|*.template|*.dist) ;; *) has_env_file=1 ;; esac
done

MSG_APPROVE="사용자에게 /refactor:approve <단계ID> (기준선은 /refactor:approve baseline) 명령을 안내하고 멈추세요. 대화 중 '좋아요'는 승인이 아닙니다."
MSG_ALLOW_B="기준선을 새 동작으로 바꿔야 하는 🛠 단계라면 멈추고 사람에게 요청하세요: 입력창에서 ! touch \"$rdir/.allow-baseline-edit\" (끝나면 지우기)."
MSG_ALLOW_M="구조 변경은 새 마이그레이션 파일로 만드세요. 이미 있는 파일을 꼭 고쳐야 하면 사람에게 요청: ! touch \"$rdir/.allow-migration-edit\" (끝나면 지우기)."
MSG_HUMAN="필요하면 사람에게 입력창에서 직접 실행해 달라고 요청하세요(예: ! touch \"$rdir/.allow-baseline-edit\")."

normpath() { # $1 → NP (절대경로, / 구분자, ./ 와 ../ 정리)
  local p=${1//"$BS"/$SL} re_dot='/\./' re_up='/[^/]+/\.\./' re_dbl='//+'
  case "$p" in
    /*|[A-Za-z]:/*) ;;
    "~/"*) p="$HOME/${p#\~/}" ;;
    *) p="$proj/$p" ;;
  esac
  while [[ $p =~ $re_dbl ]]; do p=${p/"${BASH_REMATCH[0]}"/$SL}; done
  while [[ $p =~ $re_dot ]]; do p=${p/"${BASH_REMATCH[0]}"/$SL}; done
  while [[ $p =~ $re_up ]]; do p=${p/"${BASH_REMATCH[0]}"/$SL}; done
  NP=$p
}

# ── 경로 분류 (대소문자 무시) ───────────────────────────────────────────────
is_secret_path() {
  local b=${1##*/}
  case "$b" in *.example|*.sample|*.template|*.dist) return 1 ;; esac
  case "$b" in
    .env|.env.*|.env-*|.env_*|*.env|.envrc|.dev.vars|.dev.vars.*) return 0 ;;
    *.pem|*.key|*.p12|*.pfx|*.jks|*.keystore|id_rsa|id_dsa|id_ecdsa|id_ed25519) return 0 ;;
    secrets.json|secrets.yaml|secrets.yml|secrets.toml|.secrets|credentials.json|.netrc|.pypirc|.npmrc|.pgpass|.git-credentials) return 0 ;;
    *service-account*.json|*service_account*.json|*serviceaccount*.json|*firebase-adminsdk*.json|client_secret*.json) return 0 ;;
  esac
  case "$1" in */.git/config|*/.aws/credentials|*/.docker/config.json|*/.kube/config) return 0 ;; esac
  return 1
}
RE_BASELINE_DIR='(^|/)(tests?|__tests__|specs?)/([^/]+/)*baseline/'
RE_MIGRATION_DIR='(^|/)(supabase/migrations|prisma/migrations|alembic/versions|db/migrate|database/migrations|migrations)/[^/]+'
is_baseline_path() { has "$1" "$RE_BASELINE_DIR"; }
is_migration_path() {
  has "$1" "$RE_MIGRATION_DIR" && return 0
  local rel=${1#"$proj"/}
  has "$rel" '^drizzle/([^/]+\.sql|meta/)' && return 0
  return 1
}
# git이 이미 추적하는 파일인가(새로 만든 파일은 아직 고쳐도 된다). git이 없으면 보호 쪽으로.
is_tracked() {
  command -v git >/dev/null 2>&1 || return 0
  git -C "$proj" ls-files --error-unmatch -- "$1" >/dev/null 2>&1
}
is_human_only() {
  case "$1" in */docs/refactor/.allow-*|*/docs/refactor/approvals.log|*/docs/refactor/.turn*|*/docs/refactor/approved/*) return 0 ;; esac
  return 1
}
is_plan_file() { case "$1" in */docs/refactor/refactor_plan.md|*/docs/refactor/baseline.md) return 0 ;; esac; return 1; }
is_claude_settings() { case "$1" in */.claude/settings.json|*/.claude/settings.local.json) return 0 ;; esac; return 1; }
is_plugin_dir() { case "$1" in */.claude/plugins/*) return 0 ;; esac; return 1; }
under_refactor_docs() { case "$1" in "$rdir"/*) return 0 ;; esac; return 1; }

# 승인 칸 검사(awk): 편집 뒤 "승인 줄에 체크 표시"가 늘어나면 BLOCK. 입력 = 훅 JSON(표준입력)
AWK_APPROVAL='
function unesc(s) { gsub(/\\\\/, "\001", s); gsub(/\\"/, "\"", s); gsub(/\\\//, "/", s); gsub(/\\r/, "", s); gsub(/\\n/, "\n", s); gsub(/\\t/, "\t", s); return s }
function grab(json, key, arr,   n, re, v, rest) {
  n = 0; rest = json
  re = "\"" key "\"[ \t]*:[ \t]*\"([^\"\\\\]|\\\\.)*\""
  while (match(rest, re)) {
    v = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
    sub(/^"[^"]*"[ \t]*:[ \t]*"/, "", v); v = substr(v, 1, length(v) - 1)
    arr[++n] = unesc(v)
  }
  return n
}
function marks(s,   n, i, k, L) {
  n = split(s, L, "\n"); k = 0
  for (i = 1; i <= n; i++)
    if (L[i] ~ /^[ \t>*+-]*(\*\*)?[ \t]*(승인|기준선[ \t]*계획[ \t]*승인)[ \t]*(\*\*)?[ \t]*(\([^)]*\))?[ \t]*(\*\*)?[ \t]*:/ && L[i] ~ /\[[xX]\]|✅|☑|✔|승인됨|승인함/) k++
  return k
}
function repl_first(s, o, w,   i) { i = index(s, o); if (i == 0) return s; return substr(s, 1, i - 1) w substr(s, i + length(o)) }
function repl_all(s, o, w,   out, i) { out = ""; while ((i = index(s, o)) > 0) { out = out substr(s, 1, i - 1) w; s = substr(s, i + length(o)) } return out s }
{ json = json $0 "\n" }
END {
  content = ""
  while ((getline line < PLAN) > 0) { sub(/\r$/, "", line); content = content line "\n" }
  close(PLAN)
  before = marks(content); oldm = 0; newm = 0
  if (TOOL == "Write") { after = (grab(json, "content", C) > 0) ? marks(C[1]) : 0 }
  else {
    no = grab(json, "old_string", O); nn = grab(json, "new_string", W)
    ra = (json ~ /"replace_all"[ \t]*:[ \t]*true/)
    t = content
    for (i = 1; i <= nn; i++) newm += marks(W[i])
    for (i = 1; i <= no; i++) { oldm += marks(O[i]); if (O[i] != "" && i <= nn) t = ra ? repl_all(t, O[i], W[i]) : repl_first(t, O[i], W[i]) }
    after = marks(t)
  }
  print ((after > before || newm > oldm) ? "BLOCK" : "OK")
}'

# ── 파일 도구: Read / Edit / Write / MultiEdit / NotebookEdit ──────────────
check_file_tool() {
  jget file_path; local raw=$JV
  if [ -z "$raw" ]; then jget notebook_path; raw=$JV; fi
  [ -z "$raw" ] && return 0
  unesc_line "$raw"; normpath "$UV"; local path=$NP
  local name=${path##*/}

  if is_secret_path "$path"; then
    if [ "$tool" = "Read" ]; then
      case "$path" in */.git/config) block "git 설정 파일에는 토큰이 든 원격 주소가 있을 수 있어 열지 않습니다." "원격 주소는 가려서 보세요: git remote -v | sed -E 's#//[^/@]*@#//****@#'" ;; esac
      case "$name" in .npmrc) block "npm 설정 파일(.npmrc)에는 배포 토큰이 있을 수 있어 열지 않습니다." "설정은 npm config list 로 보세요(토큰은 (protected)로 가려져 나옵니다)." ;; esac
      block "비밀값 파일($name)은 열지 않습니다." "이름·git 추적 여부만 확인하세요(git ls-files, git check-ignore -v $name, ls -a). 변수 이름 목록은 .env.example을 보거나, 안전 실행기의 --check 결과를 보거나, 사람에게 물어보세요."
    fi
    block "비밀값 파일($name)은 AI가 고치지 않습니다." "바꿀 내용(변수 이름·설명)을 사람에게 안내하고 사람이 직접 편집하게 하세요."
  fi
  [ "$tool" = "Read" ] && return 0

  is_human_only "$path" && block "$name 파일은 사람만 만들고 지웁니다." "$MSG_HUMAN"
  is_plugin_dir "$path" && block "플러그인 폴더(.claude/plugins)는 고치지 않습니다." "플러그인 수정은 사람이 원본 저장소에서 합니다."
  # 사람 전용 파일(승인 기록·허용 파일·.turn)에 쓰는 코드를 파일로 써 두었다가 실행하는 길을 막는다
  #  - 코드 파일(.md가 아닌 파일, docs/refactor 안 포함): 그 파일들에 "쓰는" 모양(>>, tee, open(…), appendFile, touch)이 있으면 막는다
  #  - .md 문서: 줄 맨 앞이 명령(echo·printf·cat·tee·touch …)이고 그 파일들에 쓰는 줄만 막는다(설명 문장·화살표·인용·`…` 은 괜찮다)
  #  - 사람에게 안내하는 "! touch …" 줄은 괜찮다
  local ctext=$input re_human_note='![[:space:]]*(touch|rm|printf|echo)[^!]*(\.allow-[a-z-]+|approvals\.log)'
  local HT='(approvals\.log|\.allow-(baseline|migration|env)|docs/refactor/\.turn|docs/refactor/approved/)'
  while [[ $ctext =~ $re_human_note ]]; do ctext=${ctext/"${BASH_REMATCH[0]}"/ }; done
  case "$name" in
    *.md|*.markdown)
      if has "$ctext" "(^|\\\\n|\"content\"[[:space:]]*:[[:space:]]*\"|\"new_string\"[[:space:]]*:[[:space:]]*\")[[:space:]]*([$][[:space:]]+)?(sudo[[:space:]]+)?(echo|printf|cat|tee|touch|python3?|node|ruby|perl|pwsh|add-content|set-content|out-file)[[:space:]]([^\\\\]|\\\\[^n])*${HT}" \
         && has "$ctext" "(>>?|tee|touch|open|append|write|add-content|set-content|out-file)([^\\\\]|\\\\[^n])*${HT}"; then
        block "승인 기록(APPROVALS.log)·허용 파일(.allow-*)·.turn 에 쓰는 명령을 문서에 적지 않습니다(사람 전용)." "사람에게 안내하는 줄이면 앞에 ! 를 붙여 적으세요(예: ! touch \"…/.allow-baseline-edit\")."
      fi ;;
    *)
      if has "$ctext" "(>>?|tee[[:space:]]+(-a[[:space:]]+)?|touch[[:space:]]+)[\\\\\\\"'[:space:]]*[^[:space:]\\\\\\\"']*${HT}|(open|appendfile|appendfilesync|writefile|writefilesync|write_text|add-content|set-content|out-file)[[:space:](]+[^)]{0,120}${HT}"; then
        block "승인 기록(APPROVALS.log)·허용 파일(.allow-*)·.turn 에 쓰는 코드를 파일로 쓰지 않습니다(사람 전용)." "$MSG_HUMAN"
      fi ;;
  esac
  if ! under_refactor_docs "$path"; then
    case "$name" in
      *.md|*.markdown) ;;
      *) has "$input" 'approvals\.log|\.allow-(baseline|migration)|docs/refactor/\.turn' \
           && block "승인 기록(APPROVALS.log)·허용 파일(.allow-*)·.turn 을 다루는 내용을 파일로 쓰지 않습니다(사람 전용)." "$MSG_HUMAN" ;;
    esac
  fi

  if is_plan_file "$path"; then
    local r
    r=$(printf '%s\n' "$input" | awk -v PLAN="$path" -v TOOL="$tool" "$AWK_APPROVAL" 2>/dev/null)
    [ "$r" = "BLOCK" ] && block "승인 칸(- **승인**: … / 기준선 계획 승인: …)에 체크 표시를 넣는 편집은 사용자만 합니다." "$MSG_APPROVE"
  fi

  if [ "$refactor_on" = 1 ]; then
    is_claude_settings "$path" && block "리팩토링 진행 중에는 Claude 설정 파일($name)을 고치지 않습니다." "권한·훅 설정 변경은 사람이 직접 합니다."
    # 이미 커밋된 기준선은 기준선 작성 단계에서도 고치지 않는다(새 기준선 파일은 커밋 전까지 고쳐도 된다)
    if [ -e "$path" ] && is_baseline_path "$path" && [ "$allow_baseline" = 0 ] && is_tracked "$path"; then
      block "이미 커밋된 기준선 테스트($name)는 허용 없이 고치지 않습니다." "$MSG_ALLOW_B 이번 단계의 새 테스트는 tests/baseline 밖(예: tests/refactor/)에 만드세요."
    fi
    if [ -e "$path" ] && is_migration_path "$path" && [ "$allow_migration" = 0 ] && is_tracked "$path"; then
      block "이미 커밋된 마이그레이션 파일($name)은 고치지 않습니다(운영 DB에 이미 적용됐을 수 있음)." "$MSG_ALLOW_M"
    fi
    if [ "$fence" = 1 ] && under_proj "$path" && ! under_refactor_docs "$path"; then
      block "$fence_why docs/refactor 밖의 파일을 고치지 않습니다." "발견한 문제는 보고서와 계획서 후보로만 적으세요. 고치는 일은 승인된 단계 실행에서 합니다. (리팩토링과 상관없는 평소 작업이면 사용자에게 새 대화에서 하자고 안내하세요.)"
    fi
  fi
  return 0
}

# ── Grep 도구: 비밀값 파일 내용을 결과로 보여 주는 검색 ─────────────────────
# Grep 도구는 숨김 파일도 찾고, git이 무시(.gitignore)하지 않은 .env는 결과에 그 줄을 그대로 보여 준다.
SECRET_SAMPLES=".env .env.local .env.production .env.development .env.test app.env .envrc .dev.vars server.pem server.key"
PLAIN_SAMPLES="package.json tsconfig.json index.ts app.js main.py README.md settings.py config.yaml"
# glob 하나가 이름 목록($2, 없으면 흔한 비밀값 파일 이름) 중 하나에 맞는가(중괄호 {a,b} 한 묶음은 풀어서 본다)
glob_hits_secret() {
  local g=${1##*/} alt pre post body s rest names=${2:-$SECRET_SAMPLES}
  local re_brace='^(.*)[{]([^{}]*)[}](.*)$'
  if [[ $g =~ $re_brace ]]; then
    pre=${BASH_REMATCH[1]}; body=${BASH_REMATCH[2]}; post=${BASH_REMATCH[3]}; rest=$body,
    while [ -n "$rest" ]; do
      alt=${rest%%,*}; rest=${rest#*,}
      glob_hits_secret "$pre$alt$post" "$names" && return 0
    done
    return 1
  fi
  for s in $names; do
    # shellcheck disable=SC2053
    [[ $s == $g ]] && return 0
  done
  return 1
}
# 비밀값 파일을 겨냥한 glob인가(.env* 처럼) — 평범한 파일(package.json 등)에도 맞는 넓은 glob은 아니다
glob_targets_secret() { glob_hits_secret "$1" && ! glob_hits_secret "$1" "$PLAIN_SAMPLES"; }
heavy_dir() { [ -d "$1" ] || return 0; case "${1%/}" in */node_modules|*/.git|*/.next|*/.nuxt|*/.cache|*/.turbo|*/.vercel|*/dist|*/build|*/.venv|*/venv|*/__pycache__|*/vendor|*/target|*/coverage|*/.idea|*/.vscode) return 0 ;; esac; return 1; }
# 이 폴더(세 단계 아래까지)에 git이 무시하지 않는 비밀값 파일이 있나 → SEC_FOUND(첫 파일 이름)
unignored_secret_under() { # $1 폴더 $2 (있으면) 이 glob에 맞는 파일만
  local root=$1 f d1 d2 list="" ign n=0 g=${2:-}
  SEC_FOUND=""
  [ -d "$root" ] || return 1
  # 세 단계 아래까지(숨김 폴더 포함) 훑되, node_modules 같은 큰 폴더에는 들어가지 않는다
  local dirs=("$root") d3 nd=0
  for d1 in "$root"/*/ "$root"/.[!.]*/; do
    heavy_dir "$d1" && continue
    dirs+=("${d1%/}")
    for d2 in "$d1"*/ "$d1".[!.]*/; do
      heavy_dir "$d2" && continue
      dirs+=("${d2%/}")
      for d3 in "$d2"*/; do heavy_dir "$d3" && continue; dirs+=("${d3%/}"); done
      nd=$((nd + 1)); [ "$nd" -ge 300 ] && break 2
    done
  done
  for d1 in "${dirs[@]}"; do
    for f in "$d1"/.env* "$d1"/*.env "$d1"/.dev.vars* "$d1"/*.pem "$d1"/*.key "$d1"/credentials.json "$d1"/secrets.* "$d1"/*service*account*.json "$d1"/*firebase-adminsdk*.json "$d1"/client_secret*.json; do
      [ -f "$f" ] || continue
      is_secret_path "$f" || continue
      if [ -n "$g" ]; then glob_hits_secret "$g" "${f##*/}" || continue; fi
      list="$list$f$NL"; n=$((n + 1)); [ "$n" -ge 40 ] && break 2
    done
  done
  [ -z "$list" ] && return 1
  # git 저장소면 무시된 파일은 뺀다(Grep 도구가 보지 않음). git이 아니면 모두 보인다고 본다.
  if command -v git >/dev/null 2>&1 && git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    ign=$(printf '%s' "$list" | git -C "$root" check-ignore --stdin 2>/dev/null)
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      case "$NL$ign$NL" in *"$NL$f$NL"*) continue ;; esac
      SEC_FOUND=$f; return 0
    done <<EOF
$list
EOF
    return 1
  fi
  SEC_FOUND=${list%%"$NL"*}
  return 0
}
check_grep_tool() {
  jget output_mode; [ "$JV" = "content" ] || return 0
  local root="" g
  local MSG_G="파일 이름만 필요하면 output_mode를 files_with_matches로 쓰세요. 내용이 필요하면 glob(예: \"*.ts\")이나 type(예: \"js\")으로 파일 종류를 좁히거나, path로 코드 폴더(예: src)를 지정하세요."
  jget path
  if [ -n "$JV" ]; then
    unesc_line "$JV"; normpath "$UV"; root=$NP
    is_secret_path "$root" && block "비밀값 파일 내용은 검색 결과로도 보지 않습니다." "$MSG_G"
  fi
  jget glob; g=$JV
  case "$g" in '!'*) g="" ;; esac   # 제외 규칙은 범위를 좁히지 않는다
  # .env* 처럼 비밀값 파일을 겨냥한 glob은 파일이 있든 없든 막는다
  if [ -n "$g" ] && glob_targets_secret "$g"; then block "비밀값 파일 내용은 검색 결과로도 보지 않습니다." "$MSG_G"; fi
  jget type; [ -n "$JV" ] && return 0
  if [ -z "$root" ]; then jget cwd; unesc_line "$JV"; normpath "${UV:-$proj}"; root=$NP; fi
  [ -f "$root" ] && return 0
  # 넓은 glob(*.json 등)이나 glob 없음: 검색 범위에 그 glob에 맞는, git이 무시하지 않는 비밀값 파일이 실제로 있을 때만 막는다
  if unignored_secret_under "$root" "$g"; then
    block "검색 범위에 git이 무시하지 않는 비밀값 파일(${SEC_FOUND##*/})이 있어, 내용 검색 결과에 그 값이 찍힐 수 있습니다." "$MSG_G 👤 .env가 .gitignore에 없으면 사람에게 추가를 요청하세요."
  fi
  return 0
}

# SQL·DB 명령이 데이터를 통째로 지우거나 구조를 삭제하는가. $2: shell(따옴표 안 SQL) / sql(순수 SQL)
sql_destructive() {
  local t=$1 seg rest stop
  if [ "$2" = "sql" ]; then stop='[^;]*'; else stop='[^;"]*'; fi
  has "$t" 'drop[[:space:]]+(table|database|schema|owner|policy|role|user|view|materialized|function|trigger|extension|type|sequence|index)' && return 0
  has "$t" 'alter[[:space:]]+table[^;]*[[:space:]]drop[[:space:]]' && return 0
  has "$t" 'truncate([[:space:]]+table)?[[:space:]]+[a-z_"`]' && return 0
  has "$t" 'flushall|flushdb|dropdatabase|[.]drop[(]|deletemany[(][{][}][)]|[.]remove[(][{][}][)]' && return 0
  local re_del="delete[[:space:]]+from[[:space:]]+$stop" re_upd="update[[:space:]]+[^;[:space:]]+[[:space:]]+set[[:space:]]$stop"
  rest=$t
  while [[ $rest =~ $re_del ]]; do seg=${BASH_REMATCH[0]}; has "$seg" 'where' || return 0; rest=${rest#*"$seg"}; done
  rest=$t
  while [[ $rest =~ $re_upd ]]; do seg=${BASH_REMATCH[0]}; has "$seg" 'where' || return 0; rest=${rest#*"$seg"}; done
  return 1
}

# ── MCP 도구(연결된 DB·배포·메일 등) ─────────────────────────────────────────
check_mcp() {
  # 셸 명령을 실행하는 MCP 도구(원격·로컬 터미널 등)는 셸 규칙도 적용한다
  if has "$tool" 'bash|shell|terminal|command'; then
    jget command; [ -n "$JV" ] && check_shell
  fi
  if has "$tool" 'sql|execute|migration|query_database|run_query'; then
    local sqltext=""
    jget query; if [ -n "$JV" ]; then unesc_line "$JV"; sqltext=$UV; fi
    if [ -z "$sqltext" ]; then jget sql; if [ -n "$JV" ]; then unesc_line "$JV"; sqltext=$UV; fi; fi
    if [ -n "$sqltext" ] && sql_destructive "$sqltext" sql; then
      block "DB 데이터를 통째로 지우거나 구조를 삭제하는 SQL은 막혀 있습니다." "운영 DB 작업은 사람이 백업을 확인한 뒤 직접 합니다."
    fi
  fi
  [ "$refactor_on" = 1 ] || return 0
  if has "$tool" '__(execute_sql|run_sql|run_query|sql_query|query_database|apply_migration)$|__[a-z_-]*(deploy|promote|rollback|merge_branch|reset_branch|rebase_branch|delete_branch|pause_project|restore_project)'; then
    block "리팩토링 진행 중에는 연결된 DB·배포 도구(MCP)로 운영 데이터를 조회·변경하거나 배포하지 않습니다." "코드와 설정 파일만 보고, 필요한 확인은 사람에게 요청하세요."
  fi
  if has "$tool" '__(send_message|send_email|send|reply|forward|post_message|chat_postmessage)$'; then
    block "리팩토링 진행 중에는 메시지·메일을 보내지 않습니다." "보낼 내용 초안만 사람에게 주세요."
  fi
  return 0
}

# ── 셸 명령: Bash / PowerShell ──────────────────────────────────────────────
S='(^|[;&|({`"'"'"'[:space:]])'   # 명령 단어 앞 경계(따옴표 포함: bash -c "cat .env" 도 잡는다)
E='([[:space:]]|$)'               # 명령 단어 뒤 경계
RE_BL_CMD='(tests?|__tests__|specs?)/([^[:space:]]*/)?baseline(/|[[:space:]"'"'"']|$)'
RE_MIG_CMD='(supabase/migrations|prisma/migrations|alembic/versions|db/migrate|database/migrations|(^|[[:space:]/"'"'"'])migrations|(^|[[:space:]"'"'"'])drizzle)/'

# 이 경로를 대상으로 쓰기·옮기기·지우기 하는가($1 = 경로 정규식). 검사 대상: lq
writes_to() {
  has "$lq" "${S}(rm|unlink|mv|ln|truncate|shred|chmod|chown|patch|tee|touch|sed[[:space:]]+(-[a-z]*i|--in-place)|perl[[:space:]]+-[a-z]*i|g?awk[[:space:]]+-i[[:space:]]+inplace|git[[:space:]]+(checkout|restore|rm|mv)|set-content|add-content|out-file|remove-item|move-item|new-item)[[:space:]][^;&|]*($1)" && return 0
  has "$lq" ">>?[[:space:]]*[\"']?[^[:space:];&|]*($1)" && return 0
  has "$lq" "${S}find[[:space:]][^;&|]*($1)[^;&|]*[[:space:]](-delete|-exec|-execdir|-ok)([[:space:]]|$)" && return 0
  # 복사류는 마지막 인자(목적지)만 본다
  local rest=$lq seg last re_cp="${S}(cp|install|rsync|copy-item|xcopy|robocopy)[[:space:]][^;&|]*"
  while [[ $rest =~ $re_cp ]]; do
    seg=${BASH_REMATCH[0]}; rest=${rest#*"$seg"}
    seg=${seg%"${seg##*[![:space:]]}"}; last=${seg##*[[:space:]]}; last=${last//\"/}; last=${last//\'/}
    has "$last" "$1" && return 0
  done
  return 1
}
# 파이썬·노드 같은 인터프리터 코드가 이 경로에 쓰는가($1 = 경로 정규식). 검사 대상: lr
interp_writes() {
  has "$lr" "${S}(python3?|py|node|ruby|php|perl|deno|bun|pwsh|powershell)[[:space:]]" || return 1
  has "$lr" "$1" || return 1
  has "$lr" "open[(][^)]*['\"][wax+]|write_?text|write_?bytes|writefile|write_file|appendfile|fs[.](write|append|rm|unlink|rename|copy|truncate)|[.]unlink|rmtree|os[.](remove|rename|replace)|shutil[.](move|copy)|set-content|out-file|add-content|[.]replace[(]" || return 1
  return 0
}

# 따옴표 인자 하나를 _Q_로 바꾼다(명령 치환이 든 것은 그대로). $1 정규식(따옴표 인자가 마지막 괄호) $2 그 괄호 번호 $3 원문 → BQ
blank_quoted() {
  local re=$1 gi=$2 rest=$3 out="" m0 mq re_cs='[$][(]|`'
  while [[ $rest =~ $re ]]; do
    m0=${BASH_REMATCH[0]}; mq=${BASH_REMATCH[$gi]}
    out="$out${rest%%"$m0"*}"
    rest=${rest#*"$m0"}
    if [[ $mq =~ $re_cs ]]; then out="$out$m0"; else out="$out${m0%"$mq"}_Q_"; fi
  done
  BQ="$out$rest"
}
# 프로젝트(또는 두 단계 아래 폴더)에 .env 가 있나 — 전체 검색 규칙에서만 부른다
env_near() {
  local f
  [ "$has_env_file" = 1 ] && return 0
  for f in "$proj"/*/.env* "$proj"/*/*/.env*; do
    [ -e "$f" ] || continue
    case "${f##*/}" in *.example|*.sample|*.template|*.dist) ;; *) return 0 ;; esac
  done
  return 1
}
under_proj() { case "$1" in "$proj"/*) return 0 ;; esac; return 1; }

# echo·printf 의 따옴표 없는 글자도 뺀다(echo .env >> .gitignore 는 막지 않게). > 리다이렉트 대상과 $( ) 는 남긴다 → BQ
blank_echo_words() {
  local rest=$1 out="" m0 lead args kept r
  local re='(^|[;&|(])([[:space:]]*(echo|printf|write-host|write-output))([^;&|]*)'
  local re_r='[0-9]*>>?[[:space:]]*[^[:space:];&|<>]+' re_cs='[$][(]|`'
  while [[ $rest =~ $re ]]; do
    m0=${BASH_REMATCH[0]}; lead="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"; args=${BASH_REMATCH[4]}
    out="$out${rest%%"$m0"*}"; rest=${rest#*"$m0"}
    if [[ $args =~ $re_cs ]]; then out="$out$m0"; continue; fi
    kept=""
    while [[ $args =~ $re_r ]]; do r=${BASH_REMATCH[0]}; kept="$kept $r"; args=${args#*"$r"}; done
    out="$out$lead _Q_$kept "
  done
  BQ="$out$rest"
}

# PowerShell에서 비밀값 이름의 환경변수 값을 꺼내는가($env:X 는 그 자체로 값을 출력한다). 대입·if 조건 안은 제외
ps_env_read() {
  local t=$lr m pre post re='\$env:[a-z0-9_]*(key|secret|token|pass|private|credential|url|uri|dsn|database|conn|cookie|session|jwt)[a-z0-9_]*'
  local re_asg='^[[:space:]]*=[^=]' re_test='((if|elseif|while)[[:space:]]*[(][[:space:]]*(-not[[:space:]]+|!)?|isnullorempty[(]|isnullorwhitespace[(])$'
  while [[ $t =~ $re ]]; do
    m=${BASH_REMATCH[0]}; pre=${t%%"$m"*}; post=${t#*"$m"}
    if [[ $post =~ $re_asg ]] || [[ $pre =~ $re_test ]]; then t=$post; continue; fi
    return 0
  done
  return 1
}

# 이름·존재만 보는 명령 조각인가(ls .env*, test -f .env, git check-ignore -v .env …)
is_meta_seg() {
  local P='^[[:space:]]*((if|elif|while|until|then|do|else|!)[[:space:]]+)*(sudo[[:space:]]+)?'
  has "$1" "${P}(ls|dir|test|\\[|\\[\\[|stat|file|wc|touch|which|du|realpath|basename|dirname|chmod|git[[:space:]]+(ls-files|check-ignore|status))([[:space:]]|$)" && return 0
  # git log 은 바뀐 내용(-p)을 찍지 않으면 커밋 목록뿐이다
  if has "$1" "${P}git[[:space:]]+log([[:space:]]|$)" && ! has "$1" '[[:space:]](-p|--patch|-u|--patch-with-stat|--cc|-c)([[:space:]]|$)'; then return 0; fi
  if has "$1" "${P}find[[:space:]]" && ! has "$1" '[[:space:]]-(exec|execdir|ok|okdir|delete|fprint|fprint0|fprintf|fls)([[:space:]]|$)'; then return 0; fi
  return 1
}
# 와일드카드(* ? [ ])가 든 인자가 비밀값 파일을 가리킬 수 있나: 흔한 이름과 맞춰 보고, 실제 폴더에서도 펼쳐 본다
seg_glob_secret() {
  local tok t b f n toks=()
  set -f; for tok in $1; do toks+=("$tok"); done; set +f
  for tok in "${toks[@]}"; do
    case "$tok" in *'*'*|*'?'*|*'['*']'*) ;; *) continue ;; esac
    t=${tok//\"/}; t=${t//\'/}; t=${t#*=}; t=${t#@}
    case "$t" in *'$'*|-*|'') continue ;; esac
    b=${t##*/}
    case "$b" in .*|*env*|*vars*|*pem*|*key*|*cred*) glob_hits_secret "$b" && return 0 ;; esac
    case "$t" in /*|[A-Za-z]:/*) ;; "~/"*) t="$HOME/${t#\~/}" ;; *) t="$cwd/$t" ;; esac
    n=0
    local IFS=$NL
    for f in $t; do
      [ -e "$f" ] || continue
      is_secret_path "$f" && return 0
      n=$((n + 1)); [ "$n" -ge 500 ] && break
    done
    unset IFS
  done
  return 1
}

# 프로젝트 코드를 실행하는 명령 조각인가(테스트·빌드·개발 서버·스크립트 파일·인라인 코드) — 안전 실행기 강제에 쓴다
# 정적 검사만 하는 도구(lint·타입 검사·포맷 확인)는 제외한다.
LINT_TOOLS=" eslint prettier tsc typescript vue-tsc svelte-check biome @biomejs/biome oxlint stylelint knip depcheck madge cspell markdownlint markdownlint-cli2 npm-check-updates ncu license-checker jscpd sort-package-json dprint ruff black isort flake8 mypy pyright pylint bandit "
runner_tool() {
  local t=${1##*/} n=${2:-} n2=${3:-}
  t=${t%\"}; t=${t%\'}; n=${n//\"/}; n=${n//\'/}
  case "$LINT_TOOLS" in *" $t "*) return 1 ;; esac
  case "$t" in
    vitest|jest|mocha|ava|cypress|nodemon|ts-node|tsx|vite-node|esno|esr|jiti|pytest|py.test|uvicorn|gunicorn|hypercorn|daphne|streamlit|celery|dotenv|dotenv-cli|env-cmd|dotenvx|jasmine|karma|tap|tox|nox|rspec)
      case "$n" in --version|-v|-V|--help|-h) return 1 ;; esac; return 0 ;;
    playwright) case "$n" in test|"") return 0 ;; esac; return 1 ;;
    next|vite|nuxt|nuxi|remix|astro|react-scripts|webpack|rollup|parcel|gatsby|expo|vercel|netlify|wrangler|svelte-kit|ng)
      case "$n" in dev|start|build|preview|serve|test|develop|e2e|export) return 0 ;; esac; return 1 ;;
    turbo|nx|lerna) case "$n" in ""|--version|-v|--help|-h|ls|list|graph|prune|login|link) return 1 ;; esac; return 0 ;;
    prisma) case "$n" in migrate|db|studio) return 0 ;; esac; return 1 ;;
    drizzle-kit) case "$n" in push|migrate|studio|introspect|pull) return 0 ;; esac; return 1 ;;
    supabase) case "$n" in functions|test) return 0 ;; esac; return 1 ;;
    uv|poetry|pipenv|pdm|hatch|rye|conda|pixi|mamba|micromamba)
      [ "$n" = run ] || [ "$n" = shell ] || return 1
      case "$LINT_TOOLS" in *" ${n2##*/} "*) return 1 ;; esac; return 0 ;;
    docker|docker-compose|podman)
      case "$n" in run|exec|up|start) return 0 ;; compose) case "$n2" in run|exec|up|start|watch) return 0 ;; esac ;; esac; return 1 ;;
    bundle) [ "$n" = exec ] && return 0; return 1 ;;
    rails) case "$n" in test|t|server|s|runner|r|console|c|spec) return 0 ;; esac; return 1 ;;
    rake) case "$n" in -T|--tasks|-P|--help) return 1 ;; esac; return 0 ;;
    gradle|gradlew|mvn|mvnw) return 0 ;;
    dotnet) case "$n" in test|run|watch) return 0 ;; esac; return 1 ;;
    python|python3|python3.*|py|pypy3)
      case "$n" in ""|--version|-V|-h|--help) return 1 ;; esac
      if [ "$n" = "-m" ]; then case "$LINT_TOOLS" in *" $n2 "*) return 1 ;; esac; case "$n2" in pip|venv|ensurepip|json.tool|py_compile|compileall|pydoc) return 1 ;; esac; fi
      return 0 ;;
    node|bun|ruby|php|perl|rscript)
      case "$n" in ""|--version|-v|-V|-h|--help|--check|-c|-l) return 1 ;; esac; return 0 ;;
    deno) case "$n" in test|run|task|eval|serve|repl|bench) return 0 ;; esac; return 1 ;;
    flask) case "$n" in run|shell) return 0 ;; esac; return 1 ;;
    go|cargo) case "$n" in test|run|bench) return 0 ;; esac; return 1 ;;
    make|just|task)
      case "$n" in -n|--dry-run|--version|-v|--help|-h|-p|--list|-l|lint|typecheck|type-check|fmt-check|format-check|check-format|help) return 1 ;; esac; return 0 ;;
    sh|bash|zsh|dash)
      case "$n" in ""|-n|--version|--help) return 1 ;; esac; return 0 ;;
    *.sh|*.py|*.js|*.mjs|*.cjs|*.ts|*.rb|*.php) return 0 ;;
  esac
  return 1
}
runs_project_code() {
  local w=() i=0 j w1 w2 w3
  set -f; read -r -a w <<< "$1"; set +f
  # 앞에 붙는 환경변수 지정·sudo·time·timeout 같은 것은 건너뛴다
  while [ "$i" -lt "${#w[@]}" ]; do
    case "${w[$i]}" in
      *=*|sudo|time|nohup|command|exec|cross-env|xvfb-run) i=$((i + 1)) ;;
      env) i=$((i + 1)); while [ "$i" -lt "${#w[@]}" ] && [[ ${w[$i]} == -* ]]; do i=$((i + 1)); done ;;
      timeout|nice) i=$((i + 1)); while [ "$i" -lt "${#w[@]}" ] && [[ ${w[$i]} == -* || ${w[$i]} =~ ^[0-9.]+[smhd]?$ ]]; do i=$((i + 1)); done ;;
      *) break ;;
    esac
  done
  w1=${w[$i]:-}; w1=${w1##*/}; w2=${w[$((i + 1))]:-}; w3=${w[$((i + 2))]:-}
  case "$w1" in
    npm|pnpm|yarn|bun)
      case "$w2" in
        run|run-script)
          case "$w3" in ""|lint|lint:*|typecheck|type-check|tsc|check-types|format:check|fmt:check|prettier:check) return 1 ;; esac
          return 0 ;;
        exec|dlx|x) npx_runs "${w[@]:$((i + 2))}"; return $? ;;
        ""|-*|install|i|ci|add|remove|rm|uninstall|un|update|up|upgrade|outdated|ls|list|ll|la|why|explain|audit|info|view|show|config|get|set|init|create|link|ln|unlink|pack|publish|version|help|cache|store|dedupe|prune|rebuild|root|bin|prefix|whoami|login|logout|doctor|fund|search|repo|docs|home|bugs|owner|access|ping|query|pkg|licenses|import|patch|workspaces|plugin|env|setup|approve-builds|lint|typecheck|type-check|tsc|check-types|format:check) return 1 ;;
        *) return 0 ;;   # test·start·build·dev 와 그 밖의 package.json 스크립트 이름(bun x.ts 포함)
      esac ;;
    npx|pnpx|bunx) npx_runs "${w[@]:$((i + 1))}"; return $? ;;
  esac
  runner_tool "$w1" "$w2" "$w3"
}
# npx 등으로 부르는 도구: lint·타입 검사·포맷 도구와 prisma generate 같은 것만 빼고 모두 프로젝트 코드 실행으로 본다
npx_runs() {
  local a=("$@") j=0 t
  while [ "$j" -lt "${#a[@]}" ] && [[ ${a[$j]} == -* ]]; do
    case "${a[$j]}" in -p|--package) j=$((j + 2)) ;; *) j=$((j + 1)) ;; esac
  done
  t=${a[$j]:-}; t=${t%@*}; [ -z "$t" ] && t=${a[$j]:-}
  [ -z "$t" ] && return 1
  case "$LINT_TOOLS" in *" ${t##*/} "*) return 1 ;; esac
  case "${t##*/}" in
    prisma) case "${a[$((j + 1))]:-}" in migrate|db|studio) return 0 ;; esac; return 1 ;;
    supabase) case "${a[$((j + 1))]:-}" in functions|test) return 0 ;; esac; return 1 ;;
    playwright) case "${a[$((j + 1))]:-}" in test|"") return 0 ;; esac; return 1 ;;
    next|vite|nuxt|nuxi|remix|astro|webpack|rollup|parcel|gatsby|expo|vercel|netlify|wrangler|ng|drizzle-kit|turbo|nx|lerna) runner_tool "$t" "${a[$((j + 1))]:-}" "${a[$((j + 2))]:-}"; return $? ;;
  esac
  return 0
}

check_shell() {
  jget command; local rawcmd=$JV; unesc_line "$JV"; local cmd=$UV
  [ -z "$cmd" ] && return 0
  local m0 m4 pre rest seg
  # 명령이 실행되는 폴더(Bash 도구의 현재 폴더) — 와일드카드 파일 이름을 실제로 펼쳐 볼 때 쓴다
  jget cwd; unesc_line "$JV"; cwd=${UV//"$BS"/$SL}; cwd=${cwd%/}; [ -z "$cwd" ] && cwd=$proj

  # lr: 무해한 리다이렉트 제거 + git 전역 옵션 정리(git -C . reset → git reset)
  lr=$cmd
  local re_null='[0-9&]*>>?[[:space:]]*/dev/null|[0-9]*>&[0-9]|[0-9]*>[[:space:]]*nul([[:space:];|&]|$)'
  while [[ $lr =~ $re_null ]]; do lr=${lr/"${BASH_REMATCH[0]}"/ }; done
  local re_gopt="git[[:space:]]+(-[Cc][[:space:]]+(\"[^\"]*\"|'[^']*'|[^[:space:]]+)|--no-pager|-P|--paginate|--git-dir=[^[:space:]]+|--work-tree=[^[:space:]]+|--namespace=[^[:space:]]+|--bare|--no-replace-objects|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs|--no-optional-locks)[[:space:]]+"
  while [[ $lr =~ $re_gopt ]]; do lr=${lr/"${BASH_REMATCH[0]}"/git }; done

  # lq: 위험 명령 판정용 — 검색·출력·커밋 메시지의 따옴표 인자는 빼고 본다(grep "vercel --prod" 같은 검색이 막히지 않게).
  #     단, $( ) · ` ` 명령 치환이 든 문자열은 실행되는 명령이므로 그대로 둔다.
  blank_quoted "(^|[;&|(])[[:space:]]*(grep|egrep|fgrep|rg|ag|ack|git[[:space:]]+grep|git[[:space:]]+log|git[[:space:]]+commit|echo|printf|write-host|write-output)([^;&|\"']*)(\"[^\"]*\"|'[^']*')" 4 "$lr"
  lq=$BQ

  # lx: 비밀값 판정용 — 따옴표 속 파일 경로는 남기고(grep KEY ".env" 도 잡게), 검색어·커밋 메시지·echo 문구만 뺀다
  blank_quoted "(^|[;&|(])[[:space:]]*(sudo[[:space:]]+)?(grep|egrep|fgrep|rg|ag|ack|git[[:space:]]+grep)(([[:space:]]+-[^[:space:]]+)*)[[:space:]]+(\"[^\"]*\"|'[^']*')" 6 "$lr"
  # 따옴표 없는 검색어도 뺀다(grep -rn process.env src)
  blank_quoted "(^|[;&|(])[[:space:]]*(sudo[[:space:]]+)?(grep|egrep|fgrep|rg|ag|ack|git[[:space:]]+grep)(([[:space:]]+-[^[:space:]]+)*)[[:space:]]+([^-[:space:]\"'_][^[:space:];&|]*)" 6 "$BQ"
  blank_quoted "(-m|--message|--grep|--author|-S|-G)(=|[[:space:]]+)(\"[^\"]*\"|'[^']*')" 3 "$BQ"
  blank_quoted "(^|[;&|(])[[:space:]]*(echo|printf|write-host|write-output)([^;&|\"']*)(\"[^\"]*\"|'[^']*')" 4 "$BQ"
  blank_echo_words "$BQ"
  local lx=$BQ conv
  # Windows 경로의 \ 를 / 로: PowerShell은 전부, Bash는 경로처럼 생긴 조각(C:\ .\ ..\ ~\)만 — 정규식 속 \. 은 건드리지 않는다
  if [ "$tool" = "PowerShell" ]; then
    local re_wbs='([[:alnum:]_.:~-])\\'
    while [[ $lx =~ $re_wbs ]]; do m0=${BASH_REMATCH[0]}; lx=${lx/"$m0"/"${BASH_REMATCH[1]}/"}; done
  else
    local re_wtok="(^|[[:space:]\"'=])([A-Za-z]:\\\\|\\.\\.?\\\\|~\\\\)[^[:space:]\"']*"
    while [[ $lx =~ $re_wtok ]]; do m0=${BASH_REMATCH[0]}; conv=${m0//"$BS"/$SL}; lx=${lx/"$m0"/"$conv"}; done
  fi
  local re_envfile="--(env-file|exclude|exclude-dir)(=|[[:space:]]+)(\"[^\"]*\"|'[^']*'|[^[:space:]]+)" re_ex='\.(env|envrc|dev\.vars)[[:alnum:]_.-]*\.(example|sample|template|dist)'
  while [[ $lx =~ $re_envfile ]]; do lx=${lx/"${BASH_REMATCH[0]}"/ }; done
  while [[ $lx =~ $re_ex ]]; do lx=${lx/"${BASH_REMATCH[0]}"/ }; done

  # 1) 사람 전용 ------------------------------------------------------------
  has "$lr" 'refactor-approve' && block "승인 스크립트는 사용자가 /refactor:approve 명령으로만 실행합니다." "$MSG_APPROVE"
  if writes_to '(docs/refactor/)?\.allow-[a-z-]+|approvals\.log|docs/refactor/\.turn|docs/refactor/approved/' || interp_writes '\.allow-|approvals\.log|docs/refactor/\.turn|docs/refactor/approved/'; then
    block "허용 파일(.allow-*)·승인 기록(APPROVALS.log)·.turn 은 사람과 플러그인만 만들고 지웁니다." "$MSG_HUMAN"
  fi
  # docs/refactor 안의 파일이나 .md 문서를 프로그램으로 실행하지 않는다(기록 폴더에 스크립트를 두고 돌리는 길)
  if has "$lq" "${S}(sudo[[:space:]]+)?(bash|sh|zsh|dash|source|\\.|python3?|py|node|ruby|perl|php|deno|bun|tsx|ts-node|pwsh|powershell)[[:space:]]+(-[^[:space:]]+[[:space:]]+)*[\"']?[^[:space:]\"';&|]*(docs/refactor/[^[:space:];&|]*|[.]md)([\"'[:space:];&|)]|$)" \
    || has "$lq" "(^|[;&|(])[[:space:]]*[\"']?(\\./)?docs/refactor/[^[:space:];&|]+"; then
    block "docs/refactor 안의 파일이나 .md 문서는 실행하지 않습니다(기록 폴더는 사람과 플러그인만 다룹니다)." "실행할 코드는 프로젝트의 scripts/ 등에 두고, 무엇을 하는지 사용자에게 먼저 보여 주세요."
  fi
  # 히어독(<<)으로 파일을 만들면서 사람 전용 파일 이름을 담는 명령(스크립트를 만들어 나중에 실행하는 길)
  if has "$rawcmd" '<<' && has "$rawcmd" 'approvals\.log|\.allow-(baseline|migration)|docs/refactor/\.turn'; then
    block "승인 기록(APPROVALS.log)·허용 파일(.allow-*)·.turn 을 다루는 내용을 파일로 쓰지 않습니다(사람 전용)." "$MSG_HUMAN"
  fi
  if has "$lq" '(refactor_plan|baseline)\.md' && has "$lr" '승인|\[[x ]\]|\\\[[x ]'; then
    if writes_to '(refactor_plan|baseline)\.md' || interp_writes '(refactor_plan|baseline)\.md'; then
      block "승인 칸은 사용자만 체크합니다." "$MSG_APPROVE"
    fi
  fi
  writes_to '\.claude/plugins' && block "플러그인 폴더(.claude/plugins)는 고치지 않습니다." "플러그인 수정은 사람이 원본 저장소에서 합니다."

  # 2) 비밀값 ---------------------------------------------------------------
  # 명령 전체를 한 덩어리로 본다: 비밀값 파일 이름이 나오고(이름·존재만 보는 명령 조각은 제외), 명령 어딘가에
  # 내용을 읽기·옮기기·보내기·실행하는 동작이 있으면 막는다. 조각마다 따로 보면 파이프·$( )로 나뉜 명령을 놓친다.
  local sx=$lx re_codeenv='(process|import[.]meta|deno|bun)[.]env([^[:alnum:]_]|$)'
  while [[ $sx =~ $re_codeenv ]]; do sx=${sx/"${BASH_REMATCH[0]}"/ }; done
  local SEC_ALT='\.env([._-][[:alnum:]_.-]+)?|\.envrc|\.dev\.vars([.][[:alnum:]_.-]+)?|\.git-credentials|\.npmrc|\.pgpass|\.git/config|\.aws/credentials|\.docker/config\.json|\.kube/config'
  local re_env="(^|[[:space:]\"'=:/<>(|;&@])(${SEC_ALT}|[[:alnum:]_-]+\\.env|/proc/[^[:space:]/]+/environ)([^[:alnum:]_.-]|$)"
  local re_key="(\\.(pem|p12|pfx|jks|keystore)|(^|[^[:alnum:]])id_(rsa|dsa|ecdsa|ed25519)|service[-_]?account[^[:space:]\"']*\\.json|firebase-adminsdk[^[:space:]\"']*\\.json|client_secret[^[:space:]\"']*\\.json|(^|[^[:alnum:]_])(credentials\\.json|secrets\\.(json|ya?ml|toml)|\\.netrc|\\.pypirc|\\.secrets))([^[:alnum:]_.]|$)"
  local re_keyfile="(^|[[:space:]\"'=/@])[[:alnum:]_.-]+\\.key([[:space:]\"')]|$)"
  local readverb="${S}(cat|bat|less|more|head|tail|nl|od|xxd|hexdump|strings|grep|egrep|fgrep|rg|ag|ack|awk|gawk|mawk|sed|cut|sort|uniq|diff|cmp|comm|paste|column|cp|mv|scp|rsync|install|tee|xargs|export|python|python3|py|node|ruby|perl|php|deno|bun|tsx|ts-node|sh|bash|zsh|dash|source|base64|openssl|gpg|curl|wget|nc|ncat|socat|dd|tar|zip|gzip|bzip2|xz|7z|read|mapfile|readarray|vi|vim|nvim|nano|emacs|code|open|type|get-content|gc|copy-item|cpi|move-item|compress-archive|select-string|findstr|envsubst|jq|yq|rm|unlink|shred|truncate)${E}"
  local fileverb="${S}(cat|bat|less|more|head|tail|nl|od|xxd|hexdump|strings|cp|mv|scp|rsync|base64|openssl|curl|dd|type|get-content|gc|copy-item|vi|vim|nvim|nano|emacs|code|open)${E}"
  local indirect=0 hit=0 envdump=0
  has "$sx" 'xargs|[$][(]|`|<[(]|(^|[;&|[:space:]])(read|mapfile|readarray|eval|parallel)([[:space:]]|$)|[[:space:]]-(exec|execdir|ok|okdir)([[:space:]]|$)|[|][[:space:]]*(sudo[[:space:]]+)?(ba|z|da|k)?sh([[:space:]]|$)' && indirect=1
  local segs=$sx
  segs=${segs//&&/$NL}; segs=${segs//||/$NL}; segs=${segs//;/$NL}; segs=${segs//|/$NL}; segs=${segs//(/$NL}; segs=${segs//\`/$NL}
  rest=$segs
  while [ -n "$rest" ]; do
    seg=${rest%%"$NL"*}
    if [ "$seg" = "$rest" ]; then rest=""; else rest=${rest#*"$NL"}; fi
    if has "$seg" '^[[:space:]]*(env|set|export|printenv([[:space:]].*)?|export[[:space:]]+-p|(declare|typeset)[[:space:]]+-[a-z]*p[a-z]*([[:space:]].*)?|(declare|typeset)[[:space:]]+-[a-z]*x[a-z]*)[[:space:]]*$'; then envdump=1; fi
    if has "$seg" "$re_keyfile" && has "$seg" "$fileverb"; then
      block "키 파일(.key)의 내용을 보거나 복사·전송하는 명령은 막혀 있습니다." "파일 이름과 git 추적 여부만 확인하세요(git ls-files, ls -a)."
    fi
    [ "$hit" = 1 ] && continue
    if [ "$indirect" = 0 ] && is_meta_seg "$seg"; then continue; fi
    if has "$seg" "$re_env" || has "$seg" "$re_key" || seg_glob_secret "$seg"; then hit=1; fi
  done
  if [ "$hit" = 1 ]; then
    if has "$sx" "$readverb" \
      || has "$sx" '(^|[;&|(])[[:space:]]*(\.|source)[[:space:]]+' \
      || has "$sx" "(^|[^<])<[[:space:]]*[\"']?[^[:space:]\"'<>]*(${SEC_ALT}|[[:alnum:]_-]+\\.env)" \
      || has "$sx" 'git[[:space:]]+(add|show|diff|grep|blame|cat-file|archive|log[^;&|]*[[:space:]](-p|--patch|-u))([[:space:]]|$)' \
      || has "$sx" ">>?[[:space:]]*[\"']?[^[:space:]]*(${SEC_ALT})"; then
      block "비밀값 파일(.env·키 파일 등)의 내용을 보거나 복사·전송·수정·삭제하는 명령은 막혀 있습니다." "이름·추적 여부만 확인하세요: git ls-files, git check-ignore -v .env, ls -a. 어떤 변수가 있는지는 안전 실행기 --check(이름만 출력)로 보세요. 코드에서 '.env' 글자를 찾으려면 Grep 도구(files_with_matches)를 쓰세요."
    fi
  fi
  # .env가 있는 프로젝트에서 프로젝트 전체(또는 그 위 폴더)를 셸 grep으로 내용 검색하면 .env 줄이 찍힌다
  rest=$segs
  while [ -n "$rest" ]; do
    seg=${rest%%"$NL"*}
    if [ "$seg" = "$rest" ]; then rest=""; else rest=${rest#*"$NL"}; fi
    if has "$seg" '^[[:space:]]*(sudo[[:space:]]+)?(grep|egrep|fgrep)[[:space:]]' \
      && has "$seg" '[[:space:]](-[a-zA-Z]*[rR][a-zA-Z]*|--recursive|--dereference-recursive)([[:space:]]|$)' \
      && ! has "$seg" '[[:space:]](-[a-zA-Z]*[lLcq][a-zA-Z]*|--files-with(out)?-match(es)?|--count|--quiet)([[:space:]]|$)' \
      && ! { has "$lr" '--exclude=[^[:space:]]*env' || { has "$lr" '--include=' && ! has "$lr" '--include=[^[:space:]]*env'; }; }; then
      local nargs=0 tok wide=0 t2
      set -f
      for tok in $seg; do
        case "$tok" in grep|egrep|fgrep|sudo|-*|_Q_) continue ;; esac
        nargs=$((nargs + 1))
        t2=${tok//\"/}; t2=${t2//\'/}; t2=${t2%/}
        case "$t2" in
          .|./|..|\*|./\*|\$PWD|\$\{PWD\}|\$\(pwd\)|\~|\$HOME|/) wide=1 ;;
          /*|[A-Za-z]:/*|\~/*) normpath "$t2"; case "$proj/" in "$NP"/*|"$NP") wide=1 ;; esac ;;
        esac
      done
      set +f
      if { [ "$nargs" -eq 0 ] || [ "$wide" = 1 ]; } && env_near; then
        block "이 프로젝트에는 .env가 있어서, 프로젝트 전체를 내용 검색하면 비밀값 줄이 찍힐 수 있습니다." "검색할 폴더를 지정하거나(예: src), -l(파일 이름만), --include=\"*.ts\" 로 파일 종류를 좁히세요."
      fi
    fi
  done
  # 환경변수 통째 출력·비밀값 변수 출력
  if [ "$envdump" = 1 ] \
    || has "$lx" "${S}(get-childitem|gci|dir|ls)[[:space:]]+env:" \
    || has "$lx" "${S}(get-item|gi|get-content|gc|type|cat)[[:space:]]+env:" \
    || has "$lr" '\[(system[.])?environment\]::getenvironmentvariables' \
    || has "$lr" "\\[(system[.])?environment\\]::getenvironmentvariable[[:space:]]*[(][[:space:]]*[\"'][a-z0-9_]*(key|secret|token|pass|private|credential|url|uri|dsn|database|conn|cookie|session|jwt)" \
    || has "$lr" '(echo|printf|write-host|write-output)[^;&|]*\$(\{|env:)?[a-z0-9_]*(key|secret|token|pass|private|credential|cred|url|uri|dsn|database|conn|cookie|session|jwt|bearer)' \
    || { [ "$tool" = "PowerShell" ] && ps_env_read; } \
    || { has "$lr" '<<-?[[:space:]]*[A-Za-z_]' && has "$lr" '\$\{?[a-z0-9_]*(key|secret|token|pass|private|credential|dsn|database_url|db_url|cookie|session|jwt)'; } \
    || has "$lq" "${S}docker(-compose|[[:space:]]+compose)[^;&|]*[[:space:]]config([[:space:]]|$)" \
    || { has "$lr" "${S}(node|python3?|py|deno|bun|ruby|php|perl|tsx|ts-node)([[:space:]][^;&|]*)?[[:space:]](-e|-c|-p|-r|--eval|--print)[[:space:]]" \
         && has "$lr" 'process[.]env|os[.]environ|import[.]meta[.]env|getenv|env\[|dotenv|load_dotenv' \
         && { has "$lr" "[[:space:]](-p|--print)[[:space:]]" || has "$lr" 'console[.](log|dir|error|info|table)|print|json[.](stringify|dumps)|puts|echo|var_dump'; }; }; then
    block "환경변수(비밀값이 들어 있을 수 있음)를 화면에 출력하는 명령은 막혀 있습니다." "변수가 있는지만 확인하려면: [ -n \"\$변수이름\" ] && echo 있음 — 어떤 이름이 있는지는 안전 실행기 --check 로 보세요."
  fi
  # git 기록 속 옛 비밀값: 바뀐 내용 전체(-p)를 검색·출력하는 명령
  local re_glp='git[[:space:]]+log[^;&|]*[[:space:]](-p|--patch|-u)([[:space:]]|$)'
  if has "$lq" "$re_glp"; then
    if has "$lq" 'git[[:space:]]+log[^;&|]*[[:space:]](-S|-G)' \
      || has "$lq" "git[[:space:]]+log[^;&|]*[[:space:]](-p|--patch|-u)([[:space:]][^;&|]*)?[|][[:space:]]*(sudo[[:space:]]+)?(grep|egrep|fgrep|rg|ag|ack|findstr|select-string|awk|sed)([[:space:]]|$)"; then
      block "git 기록의 바뀐 내용 전체(-p)를 검색하면 옛 비밀값이 화면에 찍힙니다." "커밋 목록만 보세요: git log --all --oneline -S \"<접두어>\" (값 없이 커밋 번호만 나옵니다)"
    fi
  fi
  if has "$lq" 'git[[:space:]]+grep[^;&|]*([$][(]|`)[[:space:]]*git[[:space:]]+rev-list|git[[:space:]]+grep[^;&|]*[[:space:]](HEAD|[0-9a-f]{7,40}|--no-index|--untracked|--no-exclude-standard)([~^:[:space:]]|$)' \
    && ! has "$lq" 'git[[:space:]]+grep[^;&|]*[[:space:]](-[a-z]*[lLcq][a-z]*|--files-with(out)?-match(es)?|--count|--name-only|--quiet)([[:space:]]|$)'; then
    block "git grep 으로 옛 버전이나 git 밖 파일을 내용 검색하면 비밀값이 찍힐 수 있습니다." "파일·커밋 이름만 보세요: git grep -l <검색어> <버전>, git log --all --oneline -S \"<접두어>\""
  fi
  if has "$lq" 'git[[:space:]]+(remote([[:space:]]+(-v|--verbose|get-url|show))|config[^;&|]*(--list|[[:space:]]-l([[:space:]]|$)|--get-regexp|remote[.][^[:space:]]*[.]url))' && ! has "$lr" '[*][*][*][*]'; then
    block "원격 저장소 주소에는 토큰이 들어 있을 수 있어 그대로 출력하지 않습니다." "가려서 보세요: git remote -v | sed -E 's#//[^/@]*@#//****@#'"
  fi

  # 3) 되돌릴 수 없는 git 명령 ---------------------------------------------
  has "$lq" 'git[[:space:]]+reset[^;&|]*--hard' && block "git reset --hard 는 저장 안 된 작업을 지웁니다." "되돌릴 곳이 있으면 그 줄만 직접 원래대로 고치세요. 전체 되돌리기는 사람이 결정합니다."
  if has "$lq" 'git[[:space:]]+clean[^;&|]*[[:space:]](-[a-z]*f|--force)' && ! has "$lq" 'git[[:space:]]+clean[^;&|]*[[:space:]](-[a-z]*n[a-z]*|--dry-run)([[:space:]]|$)'; then
    block "git clean -f 는 git에 없는 파일을 영구 삭제합니다." "지울 목록만 보려면 git clean -n (사람이 확인 후 직접 실행)."
  fi
  if has "$lq" 'git[[:space:]]+(checkout|restore)[^;&|]*[[:space:]](\.|:/|\*)([[:space:]]|$|[;&|])'; then
    if ! has "$lq" 'git[[:space:]]+restore[^;&|]*--staged' || has "$lq" 'git[[:space:]]+restore[^;&|]*(--worktree|[[:space:]]-w([[:space:]]|$))'; then
      block "git checkout . / git restore . 는 모든 파일의 변경을 한꺼번에 지웁니다." "되돌릴 때는 이번에 바꾼 파일 이름을 하나씩 지정하세요(git restore <파일>)."
    fi
  fi
  has "$lq" 'git[[:space:]]+(checkout|switch)[^;&|]*[[:space:]](-f|--force|--discard-changes)([[:space:]]|$)' && block "강제 checkout/switch 는 저장 안 된 변경을 버립니다." "먼저 git status를 사람에게 보여 주세요."
  has "$lq" 'git[[:space:]]+stash[[:space:]]+(drop|clear)' && block "git stash drop/clear 는 보관된 작업을 영구 삭제합니다." "사람이 직접 결정합니다."
  if has "$lq" 'git[[:space:]]+push[^;&|]*([[:space:]](--force[^[:space:]]*|--mirror|--delete|-d)([[:space:]]|$)|[[:space:]]-[a-z]*f[a-z]*([[:space:]]|$)|[[:space:]]\+[^[:space:]]+|[[:space:]]:[^[:space:]]+)'; then
    block "강제 push·원격 브랜치 삭제는 원격 저장소의 기록을 덮어씁니다." "push는 사람이 직접 합니다."
  fi
  shopt -u nocasematch
  if has "$lq" 'git[[:space:]]+branch[^;&|]*[[:space:]](-[a-zA-Z]*D[a-zA-Z]*|--delete[[:space:]]+--force|--force[[:space:]]+--delete)([[:space:]]|$)'; then
    shopt -s nocasematch
    block "git branch -D 는 합치지 않은 브랜치를 영구 삭제합니다." "사람이 직접 결정합니다."
  fi
  shopt -s nocasematch
  has "$lq" 'git[[:space:]]+(filter-branch|filter-repo|update-ref[[:space:]]+-d)|git[[:space:]]+reflog[[:space:]]+(expire|delete)|git[[:space:]]+gc[^;&|]*--prune=now' && block "git 기록을 다시 쓰거나 지우는 명령입니다." "사람이 직접 결정합니다."

  # 4) 대량 삭제 ------------------------------------------------------------
  local re_rm="${S}(sudo[[:space:]]+)?rm[[:space:]][^;&|]*"
  local re_rm_target="[[:space:]][\"']?(/|/[*]|~|~/|~/[*]|[\$]home/?|[\$][{]home[}]/?|[.]|[.]/|[.]/[*]|[.][.]|[.][.]/?|[*]|[.]git/?|[a-z]:[/\\\\]?)[\"']?([[:space:])\"'\`;|&]|$)"
  rest=$lq
  while [[ $rest =~ $re_rm ]]; do
    seg=${BASH_REMATCH[0]}
    if has "$seg" '[[:space:]](-[a-z]*r[a-z]*|--recursive)([[:space:]]|$)'; then
      if has "$seg" "$re_rm_target" || has "$seg" '--no-preserve-root|docs/refactor'; then
        block "rm -r 로 프로젝트·홈·저장소·리팩토링 기록 전체를 지우는 명령은 막혀 있습니다." "지울 폴더를 정확히 지정하고, 큰 삭제는 사람이 직접 하세요."
      fi
    fi
    rest=${rest#*"$seg"}
  done
  has "$lq" "${S}(rmdir|rd)[[:space:]]+/s" && block "폴더 통째 삭제(rmdir /s)는 막혀 있습니다." "사람이 직접 하세요."
  if has "$lq" 'remove-item[^;&|]*-recurse' && has "$lq" "remove-item[^;&|]*[[:space:]][\"']?([.]|[*]|~|[a-z]:[/\\\\]?|[.]git)[\"']?([[:space:]]|$)"; then
    block "Remove-Item -Recurse 로 프로젝트·홈 전체를 지우는 명령은 막혀 있습니다." "사람이 직접 하세요."
  fi

  # 5) DB 삭제·초기화 ------------------------------------------------------
  local dbcli="${S}(psql|pg_restore|mysql|mariadb|sqlite3|sqlcmd|mongo|mongosh|redis-cli|supabase|prisma|drizzle-kit|sequelize|knex|typeorm|rails|rake|artisan|manage\\.py|alembic|turso|wrangler|neonctl|pscale|duckdb|clickhouse|clickhouse-client|cockroach|bq|firebase)${E}"
  if has "$lq" "$dbcli" && sql_destructive "$lr" shell; then
    block "DB 데이터를 통째로 지우거나 구조를 삭제하는 명령은 막혀 있습니다." "운영 DB 작업은 사람이 백업을 확인한 뒤 직접 합니다."
  fi
  if has "$lq" 'supabase[[:space:]]+db[[:space:]]+reset|prisma[[:space:]]+migrate[[:space:]]+reset|prisma[[:space:]]+db[[:space:]]+push[^;&|]*(--force-reset|--accept-data-loss)|drizzle-kit[[:space:]]+drop|rails[[:space:]]+db:(drop|reset|purge|schema:load)|rake[[:space:]]+db:(drop|reset|purge)|artisan[[:space:]]+(migrate:fresh|migrate:reset|db:wipe)|manage\.py[[:space:]]+(flush|reset_db|sqlflush)|sequelize[^;&|]*db:drop|typeorm[^;&|]*schema:drop|knex[^;&|]*migrate:rollback[^;&|]*--all|firebase[[:space:]]+firestore:delete|turso[[:space:]]+db[[:space:]]+(destroy|delete)|terraform[[:space:]]+destroy|vercel[[:space:]]+(rm|remove)([[:space:]]|$)' \
    || has "$lq" "${S}dropdb${E}"; then
    block "DB·서비스를 초기화하거나 삭제하는 명령은 막혀 있습니다." "사람이 백업을 확인한 뒤 직접 실행합니다."
  fi

  # ── 여기부터는 리팩토링 진행 중에만 ──
  [ "$refactor_on" = 1 ] || return 0

  has "$lq" 'git[[:space:]]+push' && block "리팩토링 진행 중에는 push를 사람이 직접 합니다(push가 자동 배포로 이어질 수 있음)." "커밋 메시지 초안만 주고, 사람이 입력창에서 ! git push 로 실행하게 하세요."
  if has "$lq" 'git[[:space:]]+stash([[:space:]]|$)' && ! has "$lq" 'git[[:space:]]+stash[[:space:]]+(list|show)'; then
    block "리팩토링 중에는 git stash를 쓰지 않습니다(다른 작업이 섞여 사라질 수 있음)." "먼저 사람에게 커밋을 부탁하세요."
  fi
  if has "$lq" "$re_glp" && ! has "$lq" 'git[[:space:]]+log[^;&|]*[[:space:]]--[[:space:]]+[^[:space:]-]'; then
    block "리팩토링 진행 중에는 파일을 지정하지 않은 git log -p 를 쓰지 않습니다(옛 비밀값이 찍힐 수 있음)." "파일을 지정하세요: git log -p -- <파일>, 또는 목록만: git log --oneline"
  fi
  if has "$lq" 'git[[:space:]]+show([[:space:]]|$)' \
    && ! has "$lq" 'git[[:space:]]+show[^;&|]*([[:space:]](--stat|--name-only|--name-status|--oneline|--no-patch|-s|--summary|--shortstat|--numstat)([[:space:]]|$)|--format|--pretty|[^[:space:]]:[^[:space:]]|[[:space:]]--[[:space:]]+[^[:space:]])'; then
    block "커밋 내용 전체를 출력하면 옛 비밀값이 찍힐 수 있습니다." "요약만 보거나(git show --stat <커밋>) 파일을 지정하세요(git show <커밋> -- <파일>)."
  fi
  local re_deploy="${S}(vercel([[:space:]][^;&|]*)?(--prod|[[:space:]](deploy|promote|rollback|alias|redeploy))|vercel[[:space:]]*($|[;&|])|netlify[[:space:]]+deploy|firebase[[:space:]]+deploy|wrangler[[:space:]]+(deploy|publish|pages[[:space:]]+deploy|secret)|(fly|flyctl)[[:space:]]+deploy|railway[[:space:]]+(up|deploy)|gcloud[[:space:]][^;&|]*deploy|eb[[:space:]]+deploy|(serverless|sls)[[:space:]]+deploy|amplify[[:space:]]+publish|docker[[:space:]]+push|kubectl[[:space:]]+(apply|delete|rollout)|terraform[[:space:]]+apply|pm2[[:space:]]+(deploy|restart|reload)|gh[[:space:]]+(pr[[:space:]]+merge|release[[:space:]]+create|workflow[[:space:]]+run)|ssh[[:space:]]|scp[[:space:]])"
  local re_pkg_deploy="${S}(npm|pnpm|yarn|bun)[[:space:]]+((run|run-script)[[:space:]]+)?([a-z0-9_-]+:)?(deploy|release|publish|ship)([[:space:]:]|$)"
  if has "$lq" "$re_deploy" || has "$lq" "$re_pkg_deploy"; then
    block "리팩토링 진행 중에는 배포·원격 서버 명령을 사람이 직접 합니다." "필요한 명령을 사람에게 안내하세요."
  fi
  local re_pkg_db="${S}(npm|pnpm|yarn|bun)[[:space:]]+((run|run-script)[[:space:]]+)?[a-z0-9_:-]*(migrat[a-z]*|(db|prisma|supabase|drizzle)[:_-](push|migrate|reset|seed|deploy|drop|up|apply))"
  if has "$lq" 'supabase[[:space:]]+(db[[:space:]]+push|functions[[:space:]]+deploy|secrets[[:space:]]+set)|supabase[[:space:]]+migration[[:space:]]+(up|repair)[^;&|]*(--linked|--db-url)|prisma[[:space:]]+(migrate[[:space:]]+(deploy|resolve)|db[[:space:]]+(push|execute))|drizzle-kit[[:space:]]+(push|migrate)|sequelize[^;&|]*db:migrate|knex[^;&|]*migrate:(latest|up|down|rollback)|alembic[[:space:]]+(upgrade|downgrade)|manage\.py[[:space:]]+migrate|rails[[:space:]]+db:migrate|rake[[:space:]]+db:migrate|artisan[[:space:]]+migrate' \
    || has "$lq" "$re_pkg_db" \
    || { has "$lq" 'prisma[[:space:]]+migrate[[:space:]]+dev' && ! has "$lq" '--create-only'; }; then
    block "리팩토링 진행 중에는 DB 구조 변경(마이그레이션 적용)을 사람이 직접 합니다." "로컬 테스트 DB라면 사람이 입력창에서 ! <명령> 으로 실행합니다."
  fi
  local remote_db=0
  if has "$lq" "${S}(psql|mysql|mariadb|mongosh|mongo|redis-cli|sqlcmd)${E}"; then
    has "$lr" '[$][{]?[A-Za-z_]*(URL|URI|DSN|DATABASE|DB_|CONN)' && remote_db=1
    if has "$lr" '://'; then has "$lr" '://([^/@[:space:]]*@)?(localhost|127[.]0[.]0[.]1|[[]::1[]])([:/[:space:]"'"'"']|$)' || remote_db=1; fi
    if has "$lr" '[[:space:]](-h|--host)([[:space:]=]|$)'; then has "$lr" '[[:space:]](-h|--host)(=|[[:space:]]+)["'"'"']?(localhost|127[.]0[.]0[.]1|::1)([[:space:]"'"'"']|$)' || remote_db=1; fi
  fi
  if [ "$remote_db" = 1 ]; then
    block "리팩토링 진행 중에는 원격 DB(운영일 수 있음)에 직접 접속해 조회하지 않습니다(고객 개인정보가 화면에 찍힐 수 있음)." "필요한 확인은 사람에게 요청하세요."
  fi
  has "$lq" 'claude[[:space:]]+plugins?[[:space:]]+(disable|uninstall|remove)' && block "리팩토링 진행 중에는 플러그인을 끄지 않습니다." "끄는 것은 사람이 직접 합니다."
  writes_to '\.claude/settings(\.local)?\.json' && block "리팩토링 진행 중에는 Claude 설정 파일을 고치지 않습니다." "권한·훅 설정 변경은 사람이 직접 합니다."
  if has "$lq" "${S}(prettier[^;&|]*[[:space:]](--write|-w)|eslint[^;&|]*--fix|biome[^;&|]*[[:space:]](--write|--apply|format)|ruff[[:space:]]+format|ruff[^;&|]*--fix|black|isort|autopep8[^;&|]*(-i|--in-place)|standard[^;&|]*--fix|dprint[[:space:]]+fmt|gofmt[^;&|]*-w|rubocop[^;&|]*[[:space:]](-a|-A|--autocorrect))[^;&|]*[[:space:]](\\.|\\./|[*]|[*][*]|\\./src/?|src/?|tests?/?)([[:space:]]|$)" \
    || has "$lq" "${S}(npm|pnpm|yarn|bun)[[:space:]]+((run|run-script)[[:space:]]+)?(lint|format|fmt|prettier|fix)[^;&|]*(--fix|--write)" \
    || has "$lq" "${S}(npm|pnpm|yarn|bun)[[:space:]]+((run|run-script)[[:space:]]+)?(format|fmt|fix)([[:space:]]|$)"; then
    block "리팩토링 진행 중에는 프로젝트 전체를 한꺼번에 고치는 포맷터·자동 수정을 돌리지 않습니다(단계 범위 밖·기준선까지 바뀜)." "이번 단계 파일만 지정해서 실행하세요(예: npx prettier --write src/price.js)."
  fi

  if [ "$in_baseline_phase" = 0 ] && [ "$allow_baseline" = 0 ]; then
    local snap=0 sq=$lq sseg
    sq=${sq//&&/$NL}; sq=${sq//||/$NL}; sq=${sq//;/$NL}; sq=${sq//|/$NL}
    while [ -n "$sq" ]; do
      sseg=${sq%%"$NL"*}; if [ "$sseg" = "$sq" ]; then sq=""; else sq=${sq#*"$NL"}; fi
      if has "$sseg" "${S}(vitest|jest|playwright|mocha|ava|cypress|npx|pnpm|yarn|npm|bun|bunx)${E}" \
        && has "$sseg" '([[:space:]]-u([[:space:]]|$)|--update([[:space:]=]|$)|--update-?snapshots?|--updatesnapshot)'; then snap=1; fi
    done
    has "$lq" '(--snapshot-update|--force-regen|--regen-all|--update-golden|update_snapshots=|update_golden=)' && snap=1
    if [ "$snap" = 1 ]; then
      block "스냅숏·골든 파일을 새 결과로 덮어쓰는 옵션은 기준선을 바꿀 수 있어 막혀 있습니다." "$MSG_ALLOW_B"
    fi
    if writes_to "$RE_BL_CMD" || interp_writes "$RE_BL_CMD"; then
      block "기준선 테스트 폴더의 파일을 바꾸거나 지우는 명령은 막혀 있습니다." "$MSG_ALLOW_B"
    fi
  fi
  if [ "$allow_migration" = 0 ] && { writes_to "$RE_MIG_CMD" || interp_writes "$RE_MIG_CMD"; }; then
    block "마이그레이션 폴더의 파일을 셸 명령으로 바꾸거나 지우지 않습니다." "새 마이그레이션은 파일 쓰기 도구로 새 파일을 만드세요(커밋 전의 새 파일은 고쳐도 됩니다). $MSG_ALLOW_M"
  fi
  has "$lq" "${S}(rm|unlink|remove-item)[[:space:]][^;&|]*docs/refactor/" && block "리팩토링 기록(docs/refactor)은 지우지 않습니다." "다시 하려면 /refactor:go 다시 <단계> 를 쓰세요(이전 파일은 *-prev.md로 남음)."

  # /refactor:go 실행 중에는 프로젝트 코드를 돌리는 명령(테스트·빌드·개발 서버·스크립트)을 안전 실행기로만
  if [ "$go_turn" = 1 ]; then
    local rq=$lq rseg runsh=${REFACTOR_ROOT:-<플러그인 폴더>}
    local re_mark="run\\.sh[\"']?[[:space:]]+refactor-safe-run[[:space:]]+(--|--check)([[:space:]]|$)"
    local re_plug="run\\.sh[\"']?[[:space:]]+refactor-(status|board)([[:space:]]|$)"
    runsh=${runsh//"$BS"/$SL}; runsh="${runsh%/}/hooks/run.sh"
    # 안전 실행기 뒤에 따옴표로 넘긴 명령(sh -c "npm test && npm run build")은 통째로 감싼 것이니 쪼개지 않는다
    blank_quoted "(refactor-safe-run[[:space:]]+--[[:space:]][^;&|]*)(\"[^\"]*\"|'[^']*')" 2 "$rq"; rq=$BQ
    rq=${rq//&&/$NL}; rq=${rq//||/$NL}; rq=${rq//;/$NL}; rq=${rq//|/$NL}; rq=${rq//(/$NL}; rq=${rq//\`/$NL}
    local re_cmt='[[:space:]]#.*$'
    while [ -n "$rq" ]; do
      rseg=${rq%%"$NL"*}; if [ "$rseg" = "$rq" ]; then rq=""; else rq=${rq#*"$NL"}; fi
      [[ $rseg =~ $re_cmt ]] && rseg=${rseg%%"${BASH_REMATCH[0]}"}   # 주석(# …)은 명령이 아니다
      has "$rseg" "$re_mark" && continue
      has "$rseg" "$re_plug" && continue   # 플러그인 자체 현황 스크립트(경로에 띄어쓰기가 있어도)
      if runs_project_code "$rseg"; then
        block "리팩토링(/refactor:go) 중에는 테스트·빌드·앱 실행을 안전 실행기로만 합니다 — 운영 DB·운영 키 대신 가짜 값(127.0.0.1:9 등)을 넣어, 실수로 운영 데이터를 바꾸거나 알림을 보내지 않게 합니다." "명령 앞에 붙이세요(&&·; 로 이은 명령마다 각각): bash \"$runsh\" refactor-safe-run -- <명령>   예) bash \"$runsh\" refactor-safe-run -- npm test   · 무엇이 가짜 값으로 바뀌는지(이름만): bash \"$runsh\" refactor-safe-run --check"
      fi
    done
  fi

  if [ "$fence" = 1 ]; then
    if has "$lq" "${S}(sed[[:space:]]+(-[a-z]*i|--in-place)|perl[[:space:]]+-[a-z]*i|g?awk[[:space:]]+-i[[:space:]]+inplace|git[[:space:]]+(checkout|restore|apply|am|cherry-pick|revert|merge|rebase|commit|reset|stash)|(npm|pnpm|yarn|bun)[[:space:]]+(install|i|add|remove|uninstall|update|up|upgrade)|pip3?[[:space:]]+install|poetry[[:space:]]+(add|install|update)|uv[[:space:]]+(add|pip|sync))${E}" \
      && ! has "$lq" 'git[[:space:]]+(checkout[[:space:]]+(-b|-B|--orphan)|stash[[:space:]]+(list|show))([[:space:]]|$)'; then
      block "$fence_why 코드·패키지·git 기록을 바꾸는 명령을 쓰지 않습니다." "발견한 문제는 보고서와 계획서 후보로만 적으세요. (리팩토링과 상관없는 평소 작업이면 사용자에게 새 대화에서 하자고 안내하세요.)"
    fi
  fi
  return 0
}

case "$tool" in
  Bash|PowerShell|Monitor) check_shell ;;
  Read|Edit|Write|MultiEdit|NotebookEdit) check_file_tool ;;
  Grep) check_grep_tool ;;
  mcp__*) check_mcp ;;
  *) jget command; [ -n "$JV" ] && check_shell ;;   # 셸 명령을 받는 다른 도구(새로 생긴 도구 포함)
esac
exit 0
