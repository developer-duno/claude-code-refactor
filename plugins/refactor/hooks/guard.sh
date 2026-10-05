#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Vibe Refactor 안전장치 (PreToolUse 훅) — hooks.json이 run.sh를 거쳐 실행한다.
#
# Claude가 도구를 쓰기 직전에 실행된다. 위험한 호출이면 stderr 메시지와 함께 42로 끝나고(run.sh가 2 = 차단으로 바꾼다),
# 아니면 0으로 통과시킨다. 이 스크립트가 고장 나거나 실행되지 못하면 막지 못하고 통과된다 — 사고를 줄이는 보조 장치이지,
# 모든 우회를 막는 벽이 아니다.
#
# 이 훅은 리팩토링 중에만 판정한다(0.3.0) — 켜짐 = docs/refactor/STATE.md 가 있고 마무리 확인(/refactor:approve 마무리) 전이거나,
# 이 세션이 /refactor:go 로 시작한 턴(표시 파일 .turn.<세션ID>)일 때. 그 밖의 대화(STATE 없음·마무리 확인됨)는 아무것도 보지 않고 통과한다
# (run.sh 는 CLAUDE_PROJECT_DIR 아래에 docs/refactor 폴더가 없으면 이 파일을 띄우지도 않는다). Claude Code 가 프로젝트 폴더를 알려 주지 않았거나
# 그 폴더를 열 수 없으면 빠른 길을 타지 않고 이 훅이 판정한다 — 그 폴더를 열 수 없으면 아래 문도 꺼짐으로 통과시키지 않는다(판정 불가 = 켜짐 쪽).
# 환경 변수 REFACTOR_GUARD_ALWAYS=1(정확히 1)이면 0.2.4 처럼 플러그인이 켜진 모든 대화에서 판정한다.
#
# 켜져 있는 동안 늘 보는 규칙:
#   1. 비밀값 노출: .env·키 파일 읽기/출력/복사/수정, 환경변수 출력, 원격 주소 속 토큰, git 기록 속 옛 비밀값,
#      비밀값 파일이 든 범위의 내용 검색(Grep 도구 포함)
#   2. 되돌릴 수 없는 명령: 강제 push, reset --hard, clean -f, checkout ., rm -rf ~ 류, DB 삭제·초기화
#   3. 사람 전용: 승인 스크립트, .allow-* 허용 파일, APPROVALS.log, .turn*, 플러그인 폴더
# 리팩토링 진행 중(docs/refactor/STATE.md가 있고 phase가 DONE이 아님)에만 켜지는 규칙:
#   4. push·배포·DB 구조 적용·운영 DB 접속·배포성 npm 스크립트·플러그인 끄기·Claude 설정 수정·stash
#   5. 기준선 테스트와 이미 커밋된 마이그레이션 파일 수정(스냅숏 갱신·포맷터 포함)
#      → 사람이 docs/refactor/.allow-baseline-edit / .allow-migration-edit 를 만들면 풀린다
#        (.allow-baseline-edit 에 단계 ID 를 적으면 그 단계들이 열려 있는 동안 카드에 적힌 기준선만 — 끝나면 저절로 닫힘, 0.3.2)
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
  { F=${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/refactor}; F=${F//"$BS"/$SL}; [ -d "$F" ] || mkdir -p "$F"; F=$F/problems.log; LC_ALL=C.UTF-8; m=${1%%"$NL"*}; w=${m%% *}; case "$w" in *[./"$BS"~]*) m="<파일>${m#"$w"}" ;; esac; case "$m" in *'('*')'*) m="${m%%(*}(<파일>)${m##*)}" ;; esac; t=""; (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] >= 402 )) && TZ=KST-9 printf -v t '%(%Y-%m-%d %H:%M)T' -1; [ -n "$t" ] || t=$(TZ=KST-9 date '+%Y-%m-%d %H:%M'); printf '%s | guard | 차단: %s\n' "$t" "${m:0:60}" >> "$F"; (( RANDOM % 64 )) || { s=$(wc -c < "$F"); [ "${s//[!0-9]/}" -gt 204800 ] && tail -c 102400 "$F" | tail -n +2 > "$F.tmp" && mv -f "$F.tmp" "$F"; }; } 2>/dev/null   # 문제 기록(problems.log)에 규칙 설명 첫 줄 앞 60자와 시각만 남긴다 — 첫 ( 부터 마지막 ) 까지와 맨 앞의 파일 이름은 <파일>로 바꾸고 명령·값은 적지 않는다(공개 신고에 붙을 수 있음). 실패는 무시, 가끔 200KB 넘으면 최근 절반만. %(…)T 는 bash 4.2+ 에서만(3.2 는 date) — 프로그램을 거의 띄우지 않아 차단이 늦어지지 않는다
  printf '[refactor 안전장치] %s\n' "$1" >&2
  if [ -n "${2:-}" ]; then printf '  → %s\n' "$2" >&2; fi
  if [ -n "${fence_note:-}" ] && [ "${1#"$fence_why "}" != "$1" ]; then printf '  → %s\n' "$fence_note" >&2; fi   # 울타리 차단("$fence_why …")에만
  if [ -n "${BLOCK_NOTE:-}" ]; then printf '  %s\n' "$BLOCK_NOTE" >&2; fi
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
# 비밀값 판정용 사본(UVS): 실행되지 않는 따옴표 없는 cat·tee 문서 본문만 "읽기·실행 동작이 있는 줄"을 남긴다
#   (줄 머리 명령이 읽기 동사 · < · $( ) · ` · 파일 여는 코드(open( 등) · 실행 코드(subprocess 등) · 같은 줄에 읽기 동사/함수 호출/> 와 비밀값 이름).
#   남긴 줄이 쓰는 변수를 정의한 줄도 남긴다(p='.env' … open(p) · F=.env … cat $F). 코드 인터프리터(python - <<EOF 등)·셸 본문은 통째로 본다
#   (여러 줄에 걸친 open(⏎'.env'⏎) · 목록 · 파이프로 넘기는 출력을 줄 단위로는 판정할 수 없다).
unesc_line() {
  case "$1" in *'<<'*) ;; *) [ "${#1}" -gt 6000 ] || { unesc_short "$1"; UVS=$UV; return 0; } ;; esac
  UV=$(printf '%s' "$1" | awk '
  function keepl(s,   lo) {
    lo = tolower(s)
    if (lo ~ /\$\(|`/ || lo ~ RVS || lo ~ /^[ \t]*\.[ \t]+[^ \t]/ || lo ~ /(^|[^<])<([^<]|$)/ || lo ~ />[ \t]*["\047]?\$/) return 1
    if (lo ~ CRD || lo ~ CEX) return 2
    if (lo ~ SEC) { if (lo ~ RVW || lo ~ />/) return 1; if (lo ~ /[a-z_][a-z0-9_.]*[ \t]*\(/) return 2 }
    return 0
  }
  function cmdw(s) { sub(/^[ \t({]*(sudo[ \t]+)?/, "", s); sub(/[ \t].*$/, "", s); gsub(/["\047]/, "", s); sub(/^.*[\/\002]/, "", s); return tolower(s) }
  function mdrun(s, t,   q, n, P, j, pc, k, W, i2) {   # 줄 s 에서 문서 t 가 나오는 조각 중 하나라도 "보기 전용"이 아니면 1(= 실행될 수 있음)
    if (!index(s, t)) return 0
    q = s; gsub(/&&|\|\||;/, "\005", q); n = split(q, P, "\005")
    for (j = 1; j <= n; j++) {
      pc = P[j]
      if (!index(pc, t)) continue
      # 보기 전용 = 명령이 wc·tail·head·cat·ls·grep·stat·du 이고, $( · <( · 백틱 · 파일로 쓰기(>) · eval·xargs·cp·mv·ln·install·source·.·tee 가 없고,
      #   뒤 파이프가 인터프리터로 넘기지 않음(tail x.md | cut 은 보기, cat x.md | bash 는 실행)
      if (pc ~ /\$\(|<\(|`/) return 1
      gsub(/[0-9]*>&[0-9]+|[0-9]*>>?[ \t]*\/dev\/null/, " ", pc)
      if (pc ~ />/) return 1
      if (tolower(pc) ~ /(^|[ \t|])(eval|xargs|cp|mv|ln|install|source|tee|\.)([ \t]|$)/) return 1
      k = split(pc, W, "|")
      if (cmdw(W[1]) !~ /^(wc|tail|head|cat|ls|grep|stat|du)$/) return 1
      for (i2 = 2; i2 <= k; i2++) if (cmdw(W[i2]) ~ /^(bash|sh|zsh|dash|ksh|fish|python[0-9.]*|py|pypy3?|node|nodejs|ruby|perl|php|deno|bun|tsx|ts-node|pwsh|powershell|source|\.|eval|exec|xargs|sudo|env|tee|parallel)$/) return 1
    }
    return 0
  }
  function hdfind(s,   i, n, c, r, pre) {   # 따옴표·주석 밖의 첫 히어독 표시 → HDP(위치)·HDL(길이), 없으면 0. 따옴표 상태(QS: 0 밖 · 1 작은 · 2 큰)와
    HDP = 0; n = length(s)                   #   $( · ( · 백틱 겹(QD·QST·QTY)은 다음 줄로 넘긴다("$(cat <<'EOF'" 의 << 는 치환 안이라 히어독이다)
    for (i = 1; i <= n; i++) {
      c = substr(s, i, 1)
      if (c == "\002" && QS != 1) { i++; continue }
      if (QS == 1) { if (c == "\047") QS = 0; continue }
      if (c == "`") { if (QD > 0 && QTY[QD] == "`") { QS = QST[QD]; QD-- } else { QD++; QST[QD] = QS; QTY[QD] = "`"; QS = 0 }; continue }
      if (c == "$" && substr(s, i + 1, 1) == "(") { QD++; QST[QD] = QS; QTY[QD] = "("; QS = 0; i++; continue }
      if (QS == 2) { if (c == "\"") QS = 0; continue }
      if (c == "\"") { QS = 2; continue }
      if (c == "\047") { QS = 1; continue }
      if (c == "(") { QD++; QST[QD] = 0; QTY[QD] = "("; continue }
      if (c == ")") { if (QD > 0 && QTY[QD] == "(") { QS = QST[QD]; QD-- }; continue }
      if (c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[ \t;&|(]/)) break   # 주석: 줄 끝까지
      if (HDP || c != "<" || substr(s, i + 1, 1) != "<") continue
      r = substr(s, i)
      if (!match(r, /^<<-?[ \t]*["\047\/\002]?[A-Za-z_][A-Za-z0-9_]*["\047]?/)) { i++; continue }
      pre = substr(s, 1, i - 1)
      if (pre ~ /[<0-9]$/ || pre ~ /\$\(\([^)]*$/) { i++; continue }   # <<< 문자열, $(( 1<<X )) 계산은 히어독이 아님
      HDP = i; HDL = RLENGTH; i += RLENGTH - 1
    }
    return HDP
  }
  function rhs(s,   p) { p = index(s, "="); return (p ? substr(s, p + 1) : s) }
  function callargs(s,   t, out, st, i, d, c, n2) {
    out = ""; t = s
    while (match(tolower(t), CALL)) {
      st = RSTART + RLENGTH; d = 1; n2 = length(t)
      for (i = st; i <= n2 && d > 0; i++) { c = substr(t, i, 1); if (c == "(") d++; else if (c == ")") d-- }
      out = out " " substr(t, st, i - st); t = substr(t, i)
    }
    return out
  }
  function refs(s, k,   t, nm) {
    t = s
    while (match(t, /\$\{?[A-Za-z_][A-Za-z0-9_]*/)) { nm = substr(t, RSTART, RLENGTH); sub(/^\$\{?/, "", nm); REF[nm] = 1; t = substr(t, RSTART + RLENGTH) }
    if (k == 2) { t = callargs(s); if (tolower(s) ~ /\.(read_text|read_bytes|read|readlines)[ \t]*\(/) t = t " " rhs(s) }
    else if (k == 3) t = rhs(s)
    else return
    gsub(/"[^"]*"|\047[^\047]*\047/, " ", t)
    while (match(t, /[A-Za-z_][A-Za-z0-9_]*/)) { REF[substr(t, RSTART, RLENGTH)] = 1; t = substr(t, RSTART + RLENGTH) }
  }
  function assigns(s,   t, lhs, p, nm) {
    t = s; sub(/^[ \t]+/, "", t)
    if (t ~ /^for[ \t(]/) { lhs = t; sub(/^for[ \t]*\(?[ \t]*/, "", lhs); if (!match(lhs, /[ \t](in|of)([ \t]|$)/)) return 0; lhs = substr(lhs, 1, RSTART - 1) }
    else {
      p = index(t, "="); if (p < 2 || substr(t, p + 1, 1) == "=") return 0
      lhs = substr(t, 1, p - 1)
      if (lhs ~ /[!<>=]$/ || lhs !~ /^[A-Za-z_$][]A-Za-z0-9_$ \t,:.+*\/|&[-]*$/) return 0
    }
    while (match(lhs, /[A-Za-z_][A-Za-z0-9_]*/)) { nm = substr(lhs, RSTART, RLENGTH); if (nm in REF) return 1; lhs = substr(lhs, RSTART + RLENGTH) }
    return 0
  }
  BEGIN { RS = "\001"
    RVL = "cat|bat|less|more|head|tail|nl|od|xxd|hexdump|strings|grep|egrep|fgrep|rg|ag|ack|awk|gawk|mawk|sed|cut|sort|uniq|diff|cmp|comm|paste|column|cp|mv|scp|rsync|install|tee|xargs|export|python|python3|py|node|ruby|perl|php|deno|bun|tsx|ts-node|sh|bash|zsh|dash|source|base64|openssl|gpg|curl|wget|nc|ncat|socat|dd|tar|zip|gzip|bzip2|xz|7z|read|mapfile|readarray|vi|vim|nvim|nano|emacs|code|open|type|get-content|gc|copy-item|cpi|move-item|compress-archive|select-string|findstr|envsubst|jq|yq|rm|unlink|shred|truncate|git|ln|eval"
    RVS = "(^|[;&|])[ \t]*[({]*[ \t]*((sudo|then|do|else|elif|if|while|until|!|exec|command|builtin|time|nohup|env|xargs)[ \t]+)*(" RVL ")([ \t;&|)]|$)"
    RVW = "(^|[^a-z0-9_-])(" RVL ")([^a-z0-9_-]|$)"
    CRD = "open[ \t]*\\(|path[ \t]*\\(|read_text|read_bytes|readfile|read_file|fs\\.|load_dotenv|dotenv|require[ \t]*\\([ \t]*[\"\047]fs|fopen|file_get_contents|createreadstream"
    CEX = "subprocess|popen|system[ \t]*\\(|spawn|exec[a-z_]*[ \t]*\\(|child_process|eval[ \t]*\\(|shutil\\.|os\\.(rename|replace|link|symlink)|copyfile|check_output|getoutput|\\.run[ \t]*\\("
    CALL = "(^|[^a-z0-9_])(open|path|fopen|file_get_contents|load_dotenv|readfile|readfilesync|read_file|createreadstream|system|popen|spawn|spawnsync|execsync|execfile|execfilesync|exec|execv|execvp|check_output|check_call|run|call|getoutput|getstatusoutput|copy|copy2|copyfile|copyfileobj|copytree|move|rename|symlink)[ \t]*\\("
    SEC = "\\.env|\\.dev\\.vars|credential|secret|\\.npmrc|\\.pgpass|\\.netrc|\\.pypirc|\\.git/config|\\.aws/|\\.docker/config|\\.kube/config|/environ|\\.pem|\\.p12|\\.pfx|\\.jks|\\.keystore|id_rsa|id_dsa|id_ecdsa|id_ed25519|service.?account|firebase-adminsdk|\\.key([^a-z0-9_]|$)|~[0-9]|\\.[a-z0-9]*[*?[]"
  } {
    s = $0; gsub(/\\\\\\r\\n|\\\\\\n/, "", s); gsub(/\\\\/, "\002", s); gsub(/\\"/, "\"", s); gsub(/\\\//, "/", s); gsub(/\\r/, "", s); gsub(/\\t/, " ", s)
    n = split(s, L, /\\n/); nh = 0; delim = ""; QS = 0; QD = 0
    for (i = 1; i <= n; i++) {
      line = L[i]
      if (delim != "") { t = line; sub(/^[ \t]+/, "", t); if (t == delim) { HE[nh] = i; delim = "" }; continue }
      if (!hdfind(line)) continue   # 따옴표·주석 밖의 << 만(cat "x <<'EOF'" · cat > a.md # <<'EOF' 는 히어독이 아님)
      pre = substr(line, 1, HDP - 1); post = substr(line, HDP + HDL); tok = substr(line, HDP, HDL)
      nh++; HS[nh] = i; HE[nh] = n + 1
      d = tok; sub(/^<<-?[ \t]*/, "", d); HQ[nh] = (d ~ /^["\047\/\002]/); gsub(/["\047\/\002]/, "", d); delim = d
      HC[nh] = (pre ~ /(^|[;&|(]|\$\()[ \t]*(cat|tee)([ \t]|$)[^;&|(]*$/ && post !~ /\|/)
      # 쓰는 대상 전부(\003 로 잇기): 같은 조각의 모든 > · >> 대상과 tee 의 파일 인자 전부(-a·--append·-i 등 옵션은 건너뜀)
      tg = ""; w = pre " " post; if (match(post, /[;&|]/)) w = pre " " substr(post, 1, RSTART - 1)
      while (match(w, />>?[ \t]*["\047]?[^ \t"\047;&|<>]+/)) { x = substr(w, RSTART, RLENGTH); w = substr(w, RSTART + RLENGTH); sub(/^>>?[ \t]*["\047]?/, "", x); if (x != "/dev/null") tg = tg "\003" x }
      if (match(pre, /(^|[^a-z0-9_.-])tee([ \t][^;&|]*)?$/)) {
        x = substr(pre, RSTART, RLENGTH); sub(/^[^a-z0-9_.-]?tee/, "", x); k = split(x, W2, /[ \t]+/)
        for (j = 1; j <= k; j++) { y = W2[j]; gsub(/["\047]/, "", y); if (y == "" || y ~ /^[->]/ || y == "/dev/null") continue; tg = tg "\003" y }
      }
      HT[nh] = tg; HP[nh] = post
    }
    for (h = 1; h <= nh; h++) {
      DROP[h] = 0
      if (!HC[h]) continue
      run = 0; nt = split(HT[h], TG, "\003")
      for (j = 2; j <= nt && !run; j++) {   # 대상 하나라도 실행되면 실행(TG[1] 은 빈 칸)
        t = TG[j]; sub(/^.*[\/\002]/, "", t)   # 파일 이름으로 찾는다(./x.sh, /tmp/x.sh 모두)
        if (t == "") continue
        if (tolower(t) ~ /\.(md|markdown)$/) {
          # 문서(.md)에 쓰는 본문은 글이다(사장님 결정) — 기본은 0.2.1 처럼 뒤에 그 이름이 나오면 실행될 수 있다고 보고,
          #   나오는 곳이 모두 보기 전용 명령(tail -1 x.md · wc -c x.md · tail x.md | cut …)의 인자일 때만 글로 본다(mdrun)
          if (mdrun(HP[h], t)) run = 1
          for (i = HE[h] + 1; i <= n && !run; i++) if (mdrun(L[i], t)) run = 1
        } else {
          if (index(HP[h], t) && HP[h] ~ /(bash|sh|zsh|dash|python3?|node|ruby|perl|php|deno|bun|source|\.)[ \t]/) run = 1
          for (i = HE[h] + 1; i <= n && !run; i++) if (index(L[i], t) && L[i] ~ /(bash|sh|zsh|dash|python3?|node|ruby|perl|php|deno|bun|source|chmod|\.\/|\.)[ \t]*/) run = 1
        }
      }
      if (!run) DROP[h] = HQ[h] ? 1 : 2   # 1 = 본문 빼기, 2 = 실행되는 부분만 남기기
    }
    # 비밀값·원격 주소 판정용 사본(outs): 실행되지 않는 따옴표 없는 cat·tee 문서 본문(DROP 2)만 줄을 거른다(K: 1 셸 동작 · 2 코드 동작 · 3 변수 정의).
    # 코드 인터프리터 본문·뒤에서 실행되는 본문(DROP 0)은 0.2.1 처럼 통째로 본다(사장님 결정 — 코드는 줄 필터 안 함). 따옴표 구분자 + 실행 안 됨(DROP 1)은 본문을 아예 뺀다
    for (h = 1; h <= nh; h++) {
      FI[h] = (DROP[h] == 2)
      if (!FI[h]) continue
      for (i = HS[h] + 1; i < HE[h] && i <= n; i++) K[i] = keepl(L[i])
      for (pass = 0; pass < 4; pass++) {
        split("", REF); ch = 0
        for (i = HS[h] + 1; i < HE[h] && i <= n; i++) if (K[i]) refs(L[i], K[i])
        for (i = HS[h] + 1; i < HE[h] && i <= n; i++) if (!K[i] && assigns(L[i])) { K[i] = 3; ch = 1 }
        if (!ch) break
      }
    }
    out = ""; outs = ""
    for (i = 1; i <= n; i++) {
      inb = 0
      for (k = 1; k <= nh; k++) if (i > HS[k] && i <= HE[k]) { inb = k; break }
      if (inb && i == HE[inb]) continue
      if (inb && DROP[inb] == 1) continue
      if (inb && FI[inb] && K[i]) outs = outs (outs == "" ? "" : " ; ") L[i]
      if (!(inb && FI[inb])) outs = outs (outs == "" ? "" : " ; ") L[i]
      if (inb && DROP[inb] == 2) {
        t = L[i]; parts = ""
        while (match(t, /\$\([^)]*\)|`[^`]*`|\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/)) { parts = parts " " substr(t, RSTART, RLENGTH); t = substr(t, RSTART + RLENGTH) }
        if (parts != "") out = out " ; " parts
        continue
      }
      out = out (out == "" ? "" : " ; ") L[i]
    }
    printf "%s\004%s", substr(out, 1, 20000), substr(outs, 1, 20000) }')
  UVS=${UV#*$'\004'}; UV=${UV%%$'\004'*}
  UVS=${UVS//$'\002'/$BS}
  UV=${UV//$'\002'/$BS}   # 이스케이프된 역슬래시(\\)는 awk 안에서 \002 로 두었다가 되돌린다(unesc_short 와 같게 — 역슬래시로 쪼갠 단어 판정)
}
# JSON 이스케이프를 풀되 줄바꿈은 진짜 줄바꿈으로 둔다(SQL 판정용 — 줄바꿈은 문장 구분이 아니다). 줄 이어쓰기는 지운다 → UV
#   큰 값(1KB 초과)은 awk 한 번으로 — bash 3.2 의 ${v//…} 는 맞는 곳마다 남은 길이를 다시 훑어 값이 크면 길이의 제곱으로 느려진다.
#   awk 판도 아래 bash 판과 같은 순서로 같은 글자를 바꾼다(결과는 글자 하나까지 같다 — 시험이 무작위 입력으로 대조한다).
#   awk 판은 split·정규식을 쓰지 않고 index·substr 로 글자 그대로 찾는다 — 맥 기본 awk(BWK)의 split 은 한 글자 구분자일 때
#   줄바꿈에서도 갈라(run.c split) \001→\ 되돌리기가 줄바꿈까지 \ 로 바꿨다. 날 CR·\001 글자가 든 값은 bash 판으로(Windows 에서 CR 이 달라졌다.
#   JSON 입력에는 날 제어 글자가 없어 실제로는 거의 안 탄다). 끝에 x 를 붙였다 떼는 것은 $( ) 가 끝 줄바꿈을 지우지 않게 하려는 것.
#   awk 가 없거나 실패해 끝 표시 x 가 안 돌아오면 아래 bash 판으로 계산한다(빈 값으로 판정을 건너뛰어 통과시키지 않게).
unesc_nl() {
  local v=$1 o
  if [ "${#v}" -gt 1024 ]; then case "$v" in *$'\r'*|*"$PH"*) ;; *)
    if o=$(printf '%sx' "$v" | awk 'function rlit(s, f, w,   i, n, out) { n = length(f); out = ""; while ((i = index(s, f)) > 0) { out = out substr(s, 1, i - 1) w; s = substr(s, i + n) } return out s }
      { j = (NR > 1 ? j "\n" : "") $0 }
      END { B = "\\"; P = "\001"; j = rlit(j, B B, P); j = rlit(rlit(j, P B "r" B "n", ""), P B "n", ""); j = rlit(rlit(j, B "\"", "\""), B "/", "/")
        j = rlit(rlit(rlit(j, B "r", ""), B "n", "\n"), B "t", " "); printf "%s", rlit(j, P, B) }'); then
      case "$o" in *x) UV=${o%x}; return 0 ;; esac
    fi ;; esac
  fi
  v=${v//"$P_BS2"/$PH}
  v=${v//"$PH$P_BSR$P_BSN"/}; v=${v//"$PH$P_BSN"/}
  v=${v//"$P_BSQ"/$Q}; v=${v//"$P_BSSL"/$SL}
  v=${v//"$P_BSR"/}; v=${v//"$P_BSN"/$NL}; v=${v//"$P_BST"/ }
  UV=${v//$PH/$BS}
}
unesc_short() {
  local v=$1
  v=${v//"$P_BS2"/$PH}
  # 줄 이어쓰기(\ + 줄바꿈)는 지운다(bash 와 같이) — 단어가 두 조각으로 나뉘어 규칙을 피하지 않게(res\⏎et → reset)
  v=${v//"$PH$P_BSR$P_BSN"/}; v=${v//"$PH$P_BSN"/}
  v=${v//"$P_BSQ"/$Q}; v=${v//"$P_BSSL"/$SL}
  v=${v//"$P_BSN"/ ; }; v=${v//"$P_BSR"/ ; }; v=${v//"$P_BST"/ }
  UV=${v//$PH/$BS}
}
# 하위 에이전트 지시문의 줄 수 → NLC(줄바꿈 표시 \n 의 수 + 날 \001 의 수 — 옛 계산과 같다), 줄바꿈 표시를 진짜 줄바꿈으로 바꾼 값 → NLV.
#   큰 값(1KB 초과)은 awk 한 번으로(bash 3.2 에서 ${x//[!…]/} 로 세면 길이의 세제곱, \n 바꾸기는 제곱으로 느려진다 — 20KB 에 50초).
#   날 CR·\001 글자가 든 값은 bash 판으로(unesc_nl 과 같은 까닭 — awk 판은 \001 을 셀 일이 없다).
#   awk 가 없거나 실패하면(끝 표시 x 가 없음·줄 수가 숫자가 아님) 아래 bash 판으로 계산한다.
nl_split() {
  if [ "${#1}" -gt 1024 ] && case "$1" in *$'\r'*|*"$PH"*) false ;; esac && NLV=$(printf '%sx' "$1" | awk '{ c += gsub(/\\n/, "\n"); s = (NR > 1 ? s "\n" : "") $0 } END { printf "%d\n%s", c, s }'); then
    NLC=${NLV%%"$NL"*}
    case "$NLC" in ''|*[!0-9]*) ;; *) case "$NLV" in *x) NLV=${NLV#*"$NL"}; NLV=${NLV%x}; return 0 ;; esac ;; esac
  fi
  NLV=${1//"$P_BSN"/}; NLC=$(( (${#1} - ${#NLV}) / 2 + ${#NLV} )); NLV=${NLV//$PH/}; NLC=$(( NLC - ${#NLV} )); NLV=${1//"$P_BSN"/$NL}
}
# 따옴표(' " `) 가운데 개수가 홀수인 것이 하나라도 있으면 참. 큰 값(1KB 초과)은 awk 한 번으로(${x//[!…]/} 는 bash 3.2 에서 길이의 세제곱)
#   awk 의 답은 종료 코드가 아니라 글자(odd·even)로 받는다 — awk 가 없거나 실패하면(다른 답) 아래 bash 판으로.
quote_odd() {
  if [ "${#1}" -gt 1024 ]; then
    case $(printf '%s' "$1" | awk '{ s += gsub(/\047/, ""); d += gsub(/"/, ""); b += gsub(/`/, "") } END { print ((s % 2 || d % 2 || b % 2) ? "odd" : "even") }') in
      odd) return 0 ;; even) return 1 ;;
    esac
  fi
  local q=${1//[!\'\"\`]/}
  local sq=${q//[!\']/} dq=${q//[!\"]/} bq=${q//[!\`]/}
  [ $((${#sq} % 2)) -ne 0 ] || [ $((${#dq} % 2)) -ne 0 ] || [ $((${#bq} % 2)) -ne 0 ]
}

# ── 기본 정보 ───────────────────────────────────────────────────────────────
jget tool_name; tool=$JV
jget session_id; sid=$JV
BLOCK_NOTE=""
proj_raw=${CLAUDE_PROJECT_DIR:-}
if [ -z "$proj_raw" ]; then jget cwd; unesc_line "$JV"; proj_raw=$UV; fi
proj=${proj_raw//"$BS"/$SL}
proj=${proj%/}
WINPATH=0
case "${OSTYPE:-}" in msys*|cygwin*|win32*) WINPATH=1 ;; esac
case "$proj" in [A-Za-z]:/*) WINPATH=1 ;; esac
# Git Bash 표기(/c/…)는 드라이브 표기(c:/…)로 맞춘다 — normpath 가 모든 경로를 같은 모양으로 바꾼다
if [ "$WINPATH" = 1 ]; then case "$proj" in /[A-Za-z]/*) proj="${proj:1:1}:/${proj:3}" ;; esac; fi
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

# /refactor:go 로 시작한 턴인가(UserPromptSubmit 훅 turn.sh가 세션마다 .turn.<세션ID> 에 기록: 1줄 "go <세션ID>", 2줄 "ready <실행 대기 단계들>")
# 옛 버전의 .turn 은 그 안의 세션 ID가 이번 세션과 같을 때만 인정한다(아래 t_sid 비교)
go_turn=0; t_ready="?"; tfile=""
case "$sid" in ""|*/*|*"$BS"*|*..*) ;; *) [ -f "$rdir/.turn.$sid" ] && tfile="$rdir/.turn.$sid" ;; esac
[ -z "$tfile" ] && [ -f "$rdir/.turn" ] && tfile="$rdir/.turn"
if [ -n "$tfile" ]; then
  t_kind=""; t_sid=""; t_rk=""; t_rest=""
  { read -r t_kind t_sid; read -r t_rk t_rest; } < "$tfile"
  [ "$t_kind" = "go" ] && [ -n "$sid" ] && [ "$t_sid" = "$sid" ] && go_turn=1
  [ "$t_rk" = "ready" ] && t_ready=$t_rest
fi
# 0.3.0: 경비원(이 훅)은 리팩토링 중에만 판정한다 — 켜짐 = (STATE 있음 그리고 마무리 확인 전: refactor_on) 또는 (이 세션의 /refactor:go 표시: go_turn).
#   그 밖(STATE 없음·마무리 확인됨)은 아무것도 보지 않고 통과(긴 입력 상한보다 먼저 — 꺼짐 경로에서는 외부 프로그램을 띄우지 않는다. DONE 의 마무리 확인만 예외).
#   REFACTOR_GUARD_ALWAYS=1(정확히 1)이면 이 문을 건너뛰어 0.2.4 처럼 늘 판정한다(run.sh 의 빠른 길도 같은 스위치를 본다).
#   프로젝트 폴더($proj)가 있는 폴더일 때만 꺼짐으로 통과한다 — 빈 값이거나 이 bash 로 열 수 없는 경로면(판정 불가 = 켜짐 쪽) 0.2.4 처럼 판정한다.
if [ "${REFACTOR_GUARD_ALWAYS:-}" != 1 ] && [ "$refactor_on" = 0 ] && [ "$go_turn" = 0 ] && [ -d "$proj" ]; then exit 0; fi

# 긴 입력 상한: 아주 긴 입력은 판정이 느려지거나 규칙을 비껴갈 수 있어 판정하지 않고 막는다(셸 명령 16KB는 check_shell 에서)
if [ "${#input}" -gt 32768 ]; then
  case "$tool" in
    Grep) block "검색 입력이 너무 깁니다(32KB 초과)." "검색어와 범위를 줄여 주세요." ;;
    Edit|MultiEdit)
      jget old_string; [ "${#JV}" -gt 32768 ] && block "바꿀 부분(old_string)이 너무 깁니다(32KB 초과)." "여러 번에 나눠 고치거나 Write 도구로 파일 전체를 쓰세요." ;;
    Agent|Task)
      # 하위 에이전트 지시문(prompt+description)이 32KB 를 넘으면 판정(줄마다 코드 조각 검사)이 훅 제한 시간을 넘길 수 있다 — 무거운 판정 전에 길이만 재고 막는다
      n=$(printf '%s' "$input" | awk 'function rall(s, re, w,   n, i, P, out) { n = split(s, P, re); if (n < 2) return s; out = P[1]; for (i = 2; i <= n; i++) out = out w P[i]; return out }
        { j = j $0 "\n" } END { j = rall(rall(j, "\\\\\\\\", "\002\002"), "\\\\\"", "\003\003"); t = 0
          if (match(j, /"prompt"[ \t]*:[ \t]*"[^"]*"/)) { v = substr(j, RSTART, RLENGTH); sub(/^"prompt"[ \t]*:[ \t]*"/, "", v); t += length(v) - 1 }
          if (match(j, /"description"[ \t]*:[ \t]*"[^"]*"/)) { v = substr(j, RSTART, RLENGTH); sub(/^"description"[ \t]*:[ \t]*"/, "", v); t += length(v) - 1 }
          print t }' 2>/dev/null)
      [ "${n:-0}" -gt 32768 ] && block "도구 입력이 너무 깁니다(32KB 초과) — 파일로 저장해 경로를 넘기세요." "지시문을 파일(예: /tmp/지시.md)로 저장하고, 하위 에이전트에게는 그 파일 경로를 읽으라고 짧게 쓰세요." ;;
  esac
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
# 기준선 허용 파일(0.3.2 #10): 없으면 잠김, 0바이트(예전 touch)면 예전처럼 전부 허용(allow_baseline=1).
#   내용이 있으면(단계 ID 목록) 기준선을 고치는 자리(파일 도구·셸 쓰기)에 닿았을 때 abl_load 가 한 번만 읽는다 — 평소 도구 호출엔 비용 0
allow_baseline=0; abl_mode=""; abl_ids=""; abl_paths=""; abl_why=""
if [ -f "$rdir/.allow-baseline-edit" ]; then
  if [ -s "$rdir/.allow-baseline-edit" ]; then abl_mode=lazy; else allow_baseline=1; abl_mode=ALL; fi
fi
abl_load() { # → abl_mode: ALL(공백·주석만 = 전부 허용) / OPEN(지금 실행 중인 단계 있음, abl_paths = 카드에 적힌 경로들) / WAIT(열린 단계가 STATE.md current_step 에 안 적힘, 0.3.3) / SHUT·DONE·UNKNOWN(열린 단계 없음) / NONE
  [ "$abl_mode" = lazy ] || return 0
  abl_mode=SHUT; abl_ids="?"
  [ -n "${REFACTOR_ROOT:-}" ] && [ -f "$lib" ] || return 0   # 플러그인 폴더를 모르면 닫힌 쪽
  declare -F rl_allow_baseline >/dev/null 2>&1 || eval "$(tr -d '\r' < "$lib")"
  local out l1
  out=$(rl_allow_baseline "$rdir")
  l1=${out%%"$NL"*}; [ "$l1" != "$out" ] && abl_paths=${out#*"$NL"}
  abl_mode=${l1%% *}; abl_ids=""; [ "$l1" != "$abl_mode" ] && abl_ids=${l1#* }
  case "$abl_mode" in ALL|OPEN|WAIT|SHUT|DONE|UNKNOWN|NONE) ;; *) abl_mode=SHUT; abl_ids="?" ;; esac
  [ "$abl_mode" = ALL ] && allow_baseline=1
  return 0
}
abl_closed_why() { # 열린 단계가 없을 때의 까닭 → abl_why (파일이 없으면 빈 칸)
  abl_why=""
  case "$abl_mode" in
    SHUT|DONE|UNKNOWN) abl_why="허용 파일(.allow-baseline-edit)에 적힌 단계($abl_ids)는 계획서에 없거나 승인·실행 대기 상태가 아닙니다(끝난 단계면 저절로 닫힌 것)." ;;
    WAIT) abl_why="허용 파일의 단계($abl_ids)는 지금 실행 중으로 적힌 단계가 아닙니다 — 그 단계를 시작할 때 STATE.md 의 current_step 을 \"<ID> (진행 중)\" 으로 먼저 적습니다(7-execute 순서 1)." ;;
  esac
}
abl_file_ok() { # $1 고치려는 기준선 파일(절대경로) — 허용 파일이 이 파일을 열어 주나(아니면 abl_why 에 까닭)
  abl_why=""
  [ "$allow_baseline" = 1 ] && return 0
  [ -n "$abl_mode" ] || return 1
  abl_load
  [ "$abl_mode" = ALL ] && return 0
  if [ "$abl_mode" = OPEN ]; then
    [ -n "$abl_paths" ] && rl_abl_hit "${1#"$proj"/}" "$abl_paths" && return 0
    abl_why="이 파일은 지금 실행 중인 단계($abl_ids)의 '깨질 것으로 예상되는 기준선' 칸에 없습니다 — 카드에 적힌 파일만 고칩니다."
    return 1
  fi
  abl_closed_why; return 1
}
abl_any_open() { # 셸 명령(스냅숏 갱신·기준선 폴더 쓰기)은 단계 수준: 열린 단계가 있고 그 카드들에 적힌 기준선이 하나라도 있으면 허용(파일 수준은 턴 끝 알림이 본다)
  abl_why=""
  [ "$allow_baseline" = 1 ] && return 0
  [ -n "$abl_mode" ] || return 1
  abl_load
  [ "$abl_mode" = ALL ] && return 0
  if [ "$abl_mode" = OPEN ]; then
    [ -n "$abl_paths" ] && return 0
    abl_why="지금 실행 중인 단계($abl_ids)의 카드에 '깨질 것으로 예상되는 기준선' 파일이 적혀 있지 않습니다(\"없음\") — 기준선을 바꾸지 않는 단계입니다."
    return 1
  fi
  abl_closed_why; return 1
}
allow_migration=0; [ -f "$rdir/.allow-migration-edit" ] && allow_migration=1

ro_phase=0
case "$phase" in SETUP|MAP|CHECKUP|DEEP|VERIFY|BASELINE_PLAN|PLAN) ro_phase=1 ;; esac
fence=0; fence_why=""; fence_note=""
if [ "$go_turn" = 1 ] && [ "$ro_phase" = 1 ]; then fence=1; fence_why="지금은 /refactor:go 의 읽기 전용 단계($phase)라"; fi
# /refactor:go 중 docs/refactor 밖 수정은 허락된 경우에만: 단계 실행(EXECUTE)+실행 대기 있음, 또는 기준선 작성(BASELINE)+승인 유효.
# 그 밖의 단계 이름(마무리 확인 없는 DONE, 목록에 없는 이름 등)은 모두 막는다.
if [ "$go_turn" = 1 ] && [ "$fence" = 0 ] && [ "$phase" != "EXECUTE" ] && [ "$phase" != "BASELINE" ]; then fence=1; fence_why="지금 단계($phase)에서는 코드를 고치지 않아(단계 실행은 승인된 실행 대기 단계가 있을 때만)"; fi
# 기준선 작성(BASELINE)인데 기준선 계획 승인이 유효하지 않으면(승인 없음·계획 바뀜·계획서가 이미 있음) 코드를 고치지 않는다
if [ "$go_turn" = 1 ] && [ "$phase" = "BASELINE" ] && [ "$in_baseline_phase" = 0 ]; then fence=1; fence_why="기준선 계획 승인이 유효하지 않아(승인 없음·승인 뒤 계획 바뀜·계획서가 이미 있음)"; fi
# 단계 실행(EXECUTE)인데 이번 /refactor:go 를 시작할 때 실행 대기(승인됨) 단계가 하나도 없었으면 코드를 고치지 않는다.
# "?" = 입력 훅(turn.sh)이 실행 대기를 다 계산하기 전에 끊김(닫힌 표시만 남음) → 원인과 재입력 안내를 따로 보여 준다(울타리 차단 문구에만)
if [ "$go_turn" = 1 ] && [ "$phase" = "EXECUTE" ] && { [ -z "$t_ready" ] || [ "$t_ready" = "?" ]; }; then
  fence=1; fence_why="승인된 실행 대기 단계가 없어(지금 상태의 ▶ 실행 대기가 비어 있음)"
  [ "$t_ready" = "?" ] && { fence_why="입력 처리가 늦어 실행 대기 단계를 확인하지 못해"; fence_note="사용자에게 /refactor:go 를 다시 입력해 달라고 하세요."; }
fi

has_env_file=0
for f in "$proj"/.env*; do
  [ -e "$f" ] || continue
  case "${f##*/}" in *.example|*.sample|*.template|*.dist|.envrc) ;; *) has_env_file=1 ;; esac
done

MSG_APPROVE="사용자에게 /refactor:approve <단계ID> (기준선은 /refactor:approve baseline) 명령을 안내하고 멈추세요. 대화 중 '좋아요'는 승인이 아닙니다."
# 안내 예시의 단계 ID: /refactor:go 턴이면 이번 실행 대기 단계(.turn 의 ready), 아니면 예시
abl_ex="P1-1 P1-2"
if [ "$go_turn" = 1 ] && [ -n "$t_ready" ] && [ "$t_ready" != "?" ]; then abl_ex=${t_ready//[!A-Za-z0-9_ -]/}; [ -n "${abl_ex// /}" ] || abl_ex="P1-1 P1-2"; fi
# 0.3.4 §4: PowerShell 대안(Set-Content)은 프로젝트 경로가 Windows 꼴일 때만 — 리눅스·WSL 경로(/home/…)는 PowerShell 에서 못 쓴다
abl_ps=""; [ "$WINPATH" = 1 ] && abl_ps="(PowerShell 은 Set-Content -Encoding ascii -Path \"…\" -Value \"$abl_ex\")"
# 0.3.4 §9: 🛠 카드의 기준선 허용은 승인할 때 자동으로 열린다 — 닫혀 있을 때만 사람에게 허용을 부탁한다
MSG_ALLOW_B="🛠 단계의 기준선 허용은 승인할 때 자동으로 열립니다 — 닫혀 있으면: 기준선을 새 동작으로 바꿔야 하는 🛠 단계라면 멈추고 사용자에게 입력창에 /refactor:approve 허용 $abl_ex 를 입력해 달라고 요청하세요(터미널이 없어도 됩니다 — 원격·VS Code). 터미널에서는 printf '$abl_ex\n' > \"$rdir/.allow-baseline-edit\" 도 됩니다$abl_ps. 이번에 승인된 🛠 단계 ID 를 모두 적으면 한 번으로 끝 · 적힌 단계가 모두 끝나면 저절로 닫힙니다. 고칠 수 있는 파일은 지금 실행 중인 단계의 카드에 적힌 파일('깨질 것으로 예상되는 기준선' 칸에 백틱으로 적힌 것)뿐입니다."
# 허용은 이미 있는데 실행 중 단계가 안 맞아 막힐 때(WAIT · OPEN 인데 카드 밖 파일)의 안내 — 사람에게 다시 부탁할 일이 아니다(검사 보완 F2)
MSG_ALLOW_CS="허용은 이미 있습니다 — STATE.md 의 current_step 을 지금 실행할 단계 \"<ID> (진행 중)\" 으로 먼저 고친 뒤 다시 하세요(사람에게 부탁할 것 없음). 카드에 없는 기준선 파일은 고치지 않습니다."
# WAIT 일 때만 덧붙인다(R3 — OPEN 은 실행 중 단계가 이미 허용 파일에 있어 까닭이 다르다)
MSG_ALLOW_K5="current_step 이 맞는데도 막히면 그 단계가 허용 파일에 없는 것입니다(승인할 때 자동으로 열리지만 닫혔을 수 있음) — 사용자에게 /refactor:approve 허용 <그 ID> 를 부탁하세요."
abl_hint() { case "$abl_mode" in WAIT) AH="$MSG_ALLOW_CS $MSG_ALLOW_K5" ;; OPEN) AH=$MSG_ALLOW_CS ;; *) AH=$MSG_ALLOW_B ;; esac; }   # 기준선 차단의 → 안내 → AH(abl_file_ok·abl_any_open 뒤에 부른다)
MSG_ALLOW_M="구조 변경은 새 마이그레이션 파일로 만드세요. 이미 있는 파일을 꼭 고쳐야 하면 사람에게 요청: 터미널에서 touch \"$rdir/.allow-migration-edit\" (CLI 라면 입력창에 ! touch \"…\" 도 됨 · 끝나면 지우기)."
MSG_HUMAN="🛠 단계의 기준선 허용은 승인할 때 자동으로 열립니다 — 닫혀 있으면 사용자에게 입력창에 /refactor:approve 허용 $abl_ex 를 입력해 달라고 요청하세요(터미널이 없어도 됩니다 — 원격·VS Code). 터미널에서는 printf '$abl_ex\n' > \"$rdir/.allow-baseline-edit\" 도 됩니다(CLI 라면 입력창에 ! printf … 도 됨). 적힌 단계가 모두 끝나면 저절로 닫히고, 지금 실행 중인 단계의 카드에 적힌 파일만 고칠 수 있습니다."

normpath() { # $1 → NP (절대경로, / 구분자, ./ 와 ../ 정리). $2 = 상대경로의 기준 폴더(없으면 프로젝트)
  local p=${1//"$BS"/$SL} re_dot='/\./' re_up='/[^/]+/\.\./' re_dbl='//+' b
  case "$p" in
    /*|[A-Za-z]:/*) ;;
    "~") p=$HOME ;;
    "~/"*) p="$HOME/${p#\~/}" ;;
    *) p="${2:-$proj}/$p" ;;
  esac
  # Windows 표기: NTFS 스트림(파일::$DATA)은 떼고, 이름 끝의 점·공백은 무시된다(.env. = .env)
  case "$p" in *::*) p=${p%%::*} ;; esac
  p="$p/"
  while [[ $p =~ $re_dbl ]]; do p=${p/"${BASH_REMATCH[0]}"/$SL}; done
  while [[ $p =~ $re_dot ]]; do p=${p/"${BASH_REMATCH[0]}"/$SL}; done
  while [[ $p =~ $re_up ]]; do p=${p/"${BASH_REMATCH[0]}"/$SL}; done
  p=${p%/}
  b=${p##*/}
  case "$b" in ""|.|..) ;; *[.\ ]) while :; do case "$p" in *[!/][.\ ]) p=${p%?} ;; *) break ;; esac; done ;; esac
  # Git Bash 경로(/c/…)는 드라이브 표기(c:/…)로 맞춘다(프로젝트 경로와 비교할 수 있게)
  if [ "$WINPATH" = 1 ]; then case "$p" in /[A-Za-z]/*|/[A-Za-z]) p="${p:1:1}:/${p:3}" ;; esac; fi
  [ -z "$p" ] && p=/
  NP=$p
}
HOMEC=""; [ -n "${HOME:-}" ] && { normpath "$HOME" /; HOMEC=$NP; }
# 이 플러그인 폴더(run.sh 가 REFACTOR_ROOT 로 알려 줌) — --plugin-dir 로 띄웠을 때도 플러그인 파일을 고치지 못하게
plugroot=""
if [ -n "${REFACTOR_ROOT:-}" ]; then
  plugroot=${REFACTOR_ROOT//"$BS"/$SL}
  case "$plugroot" in /*|[A-Za-z]:/*) ;; *) plugroot="$PWD/$plugroot" ;; esac
  normpath "$plugroot" /; plugroot=$NP
  [ "$plugroot" = / ] && plugroot=""
fi

# ── 경로 분류 (대소문자 무시) ───────────────────────────────────────────────
is_secret_path() {
  local b=${1##*/}
  case "$b" in *.example|*.sample|*.template|*.dist) return 1 ;; esac
  case "$b" in
    .env|.env.*|.env-*|.env_*|*.env|.dev.vars|.dev.vars.*) return 0 ;;   # .envrc(direnv)는 사장님 결정으로 읽기 허용
    *.pem|*.key|*.p12|*.pfx|*.jks|*.keystore|id_rsa|id_dsa|id_ecdsa|id_ed25519) return 0 ;;
    secrets.json|secrets.yaml|secrets.yml|secrets.toml|.secrets|credentials.json|.netrc|.pypirc|.npmrc|.pgpass|.git-credentials) return 0 ;;
    *service-account*.json|*service_account*.json|*serviceaccount*.json|*firebase-adminsdk*.json|client_secret*.json) return 0 ;;
  esac
  case "$1" in */.git/config|*/.aws/credentials|*/.docker/config.json|*/.kube/config) return 0 ;; esac
  # Windows 8.3 짧은 이름(ENV~1 = .env 등): 이름에 ~숫자가 있고 그 폴더에 비밀값 파일이 있으면 그 파일일 수 있다고 본다
  case "$b" in
    *'~'[0-9]*)
      local d=${1%/*} f
      [ "$d" = "$1" ] && d=.
      for f in "$d"/.env* "$d"/*.env "$d"/.dev.vars* "$d"/*.pem "$d"/*.key "$d"/*.p12 "$d"/*.pfx "$d"/credentials.json "$d"/secrets.* "$d"/*service*account*.json "$d"/*firebase-adminsdk*.json "$d"/client_secret*.json "$d"/.netrc "$d"/.npmrc "$d"/.pgpass "$d"/.git-credentials; do
        [ -f "$f" ] || continue
        case "${f##*/}" in *'~'[0-9]*) continue ;; esac
        is_secret_path "$f" && return 0
      done ;;
  esac
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
  git -c core.fsmonitor=false -C "$proj" ls-files --error-unmatch -- "$1" >/dev/null 2>&1   # 저장소 설정의 fsmonitor 프로그램을 띄우지 않는다(guard 의 git 호출 전부 — 남의 프로그램이 감시 파이프를 물려받지 않게)
}
is_human_only() {
  case "$1" in */docs/refactor/.allow-*|*/docs/refactor/approvals.log|*/docs/refactor/.turn*|*/docs/refactor/approved/*) return 0 ;; esac
  return 1
}
is_plan_file() { case "$1" in */docs/refactor/refactor_plan.md|*/docs/refactor/baseline.md) return 0 ;; esac; return 1; }
is_claude_settings() { case "$1" in */.claude/settings.json|*/.claude/settings.local.json) return 0 ;; esac; return 1; }
is_plugin_dir() {
  case "$1" in */.claude/plugins/*) return 0 ;; esac
  if [ -n "$plugroot" ]; then case "$1" in "$plugroot"|"$plugroot"/*) return 0 ;; esac; fi
  return 1
}
under_refactor_docs() { case "$1" in "$rdir"/*) return 0 ;; esac; return 1; }

# 승인 칸 검사(awk): 편집 뒤 "승인 줄에 체크 표시"가 늘어나면 BLOCK. 입력 = 훅 JSON(표준입력)
AWK_APPROVAL='
# 모두 바꾸기: gsub 는 바꿀 곳이 수천 개면(큰 파일의 \n) 수 초가 걸려 split 으로 나눠 잇는다
function rall(s, re, w,   n, i, P, out) { n = split(s, P, re); if (n < 2) return s; out = P[1]; for (i = 2; i <= n; i++) out = out w P[i]; return out }
function unesc(s) { s = rall(s, "\\\\\\\\", "\001"); s = rall(s, "\\\\\"", "\""); return unesc2(s) }
function unesc2(s) { s = rall(s, "\\\\/", "/"); s = rall(s, "\\\\r", ""); s = rall(s, "\\\\n", "\n"); return rall(s, "\\\\t", "\t") }
function grab(json, key, arr,   n, re, v, rest) {
  n = 0; rest = json
  # 이스케이프된 \\ 와 \" 를 먼저 다른 글자로 바꿔 두고 값의 끝(다음 ")을 단순한 정규식으로 찾는다(큰 입력에서 수 초 → 1초 안)
  rest = rall(rall(rest, "\\\\\\\\", "\002"), "\\\\\"", "\003")
  re = "\"" key "\"[ \t]*:[ \t]*\"[^\"]*\""
  while (match(rest, re)) {
    v = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
    sub(/^"[^"]*"[ \t]*:[ \t]*"/, "", v); v = substr(v, 1, length(v) - 1)
    arr[++n] = unesc2(rall(rall(v, "\003", "\""), "\002", "\001"))
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
  # 파일을 한 번에 읽는다(줄마다 이어 붙이면 큰 계획서에서 수 초가 걸린다)
  RS = "\001"; if ((getline content < PLAN) <= 0) content = ""; RS = "\n"
  gsub(/\r\n/, "\n", content); if (content != "" && substr(content, length(content)) != "\n") content = content "\n"
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
  [ "${#raw}" -gt 32768 ] && block "파일 경로가 너무 깁니다(32KB 초과)." "경로를 확인하세요."
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
  # 아래 정규식들은 큰 입력(수백 KB)에서 수 초가 걸린다 — 사람 전용 파일 이름이 아예 없으면(대부분) 건너뛴다(같은 글자를 보는 앞단 검사라 빠뜨림 없음)
  local hkw=0
  case "$input" in *approvals.log*|*.allow-*|*docs/refactor/.turn*|*docs/refactor/approved/*) hkw=1 ;; esac
  if [ "$hkw" = 1 ]; then
    local ctext=$input re_human_note='![[:space:]]*(touch|rm|printf|echo)[^!]*(\.allow-[a-z-]+|approvals\.log)'
    local HT='(approvals\.log|\.allow-(baseline|migration|env)|docs/refactor/\.turn|docs/refactor/approved/)'
    while [[ $ctext =~ $re_human_note ]]; do ctext=${ctext/"${BASH_REMATCH[0]}"/ }; done
    case "$name" in
      *.md|*.markdown)
        if has "$ctext" "(^|\\\\n|\"content\"[[:space:]]*:[[:space:]]*\"|\"new_string\"[[:space:]]*:[[:space:]]*\")[[:space:]]*([$][[:space:]]+)?(sudo[[:space:]]+)?(echo|printf|cat|tee|touch|python3?|node|ruby|perl|pwsh|add-content|set-content|out-file)[[:space:]]([^\\\\]|\\\\[^n])*${HT}" \
           && has "$ctext" "(>>?|tee|touch|open|append|write|add-content|set-content|out-file)([^\\\\]|\\\\[^n])*${HT}"; then
          block "승인 기록(APPROVALS.log)·허용 파일(.allow-*)·.turn 에 쓰는 명령을 문서에 적지 않습니다(사람 전용)." "사람에게 안내하는 줄이면 명령 앞에 '터미널에서' 를 붙여 적으세요(예: 터미널에서 printf 'P1-1 P1-2\n' > \"…/.allow-baseline-edit\" (CLI 라면 입력창에 ! printf … 도 됨))."
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

  fi

  if is_plan_file "$path"; then
    local r
    r=$(printf '%s\n' "$input" | awk -v PLAN="$path" -v TOOL="$tool" "$AWK_APPROVAL" 2>/dev/null)
    [ "$r" = "BLOCK" ] && block "승인 칸(- **승인**: … / 기준선 계획 승인: …)에 체크 표시를 넣는 편집은 사용자만 합니다." "$MSG_APPROVE"
  fi

  if [ "$refactor_on" = 1 ]; then
    is_claude_settings "$path" && block "리팩토링 진행 중에는 Claude 설정 파일($name)을 고치지 않습니다." "권한·훅 설정 변경은 사람이 직접 합니다."
    # 이미 커밋된 기준선은 기준선 작성 단계에서도 고치지 않는다(새 기준선 파일은 커밋 전까지 고쳐도 된다)
    if [ -e "$path" ] && is_baseline_path "$path" && ! abl_file_ok "$path" && is_tracked "$path"; then
      abl_hint; block "이미 커밋된 기준선 테스트($name)는 허용 없이 고치지 않습니다.${abl_why:+ $abl_why}" "$AH 이번 단계의 새 테스트는 tests/baseline 밖(예: tests/refactor/)에 만드세요."
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
SECRET_SAMPLES=".env .env.local .env.production .env.development .env.test app.env .dev.vars server.pem server.key"
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
# 비밀값 파일 이름 꼴 — 훑기(unignored_secret_scan)의 파일 glob 과 git 목록의 pathspec 이 이 한 목록을 같이 쓴다(어긋나지 않게)
# 후보를 고르는 꼴일 뿐이고 판정은 is_secret_path 가 한다(id_rsa* 로 고른 id_rsa.pub 은 거기서 빠진다). 대소문자는 가리지 않는다(0.3.0 —
#   pathspec 은 icase, 훑기는 nocaseglob. is_secret_path 는 원래 nocasematch 라 .ENV 도 비밀값으로 본다).
#   글자 그대로인 이름은 한 글자를 [ ] 로 감싼다 — glob 글자가 없으면 셸이 펼치지 않아 훑기에서 nocaseglob 이 듣지 않는다(.NETRC)
#   .npmrc 는 저장소에 올려 두는 설정 파일인 경우가 많아 범위 검색을 매번 막게 되므로 넣지 않는다(직접 읽기는 is_secret_path 가 막는다).
SEC_NAME_GLOBS=(".env*" "*.env" ".dev.vars*" "*.pem" "*.key" "*.p12" "*.pfx" "*.jks" "*.keystore" "id_rsa*" "id_dsa*" "id_ecdsa*" "id_ed25519*" "[c]redentials.json" "secrets.*" ".[s]ecrets" "*service*account*.json" "*firebase-adminsdk*.json" "client_secret*.json" ".[p]gpass" ".[n]etrc" ".[p]ypirc" ".[g]it-credentials")
MSG_WIDE="범위가 넓어 판정할 수 없습니다 — 폴더를 좁혀 주세요."
MSG_WIDE2="path로 코드 폴더(예: src)를 지정하거나 type(예: \"js\")으로 파일 종류를 좁히세요."
SEC_REPOS=0
# 이 폴더 아래에 git이 무시하지 않는 비밀값 파일이 있나 → SEC_FOUND(첫 파일 이름)
# git 저장소(작업 트리) 안이면 폴더를 훑지 않고 git 이 아는 파일 목록(추적 + 안 추적, 무시된 것 제외)에서 이름 꼴로 찾는다 —
#   깊이·폴더 수 제한이 없고 숨김·vendor 같은 폴더도 본다. 목록이 안을 보여 주지 않는 안 추적 중첩 저장소("폴더/" 한 줄)와
#   서브모듈(gitlink)은 그 폴더를 다시 판정한다. git 이 없거나 목록 명령이 실패하면(git 밖 포함) 지금 방식(훑기)으로 내려간다.
#   git 호출: 범위당 2번(목록 1 + gitlink 찾기 1, 비밀값을 찾으면 1번) + 중첩 저장소·서브모듈마다 같은 수
unignored_secret_under() { # $1 폴더 $2 (있으면) 이 glob에 맞는 파일만
  local root=$1 g=${2:-} p f rc="" out pat pspec=() subs=() s
  SEC_FOUND=""
  [ -d "$root" ] || return 1
  if ! command -v git >/dev/null 2>&1; then unignored_secret_scan "$root" "$g"; return; fi
  for pat in "${SEC_NAME_GLOBS[@]}"; do pspec+=(":(glob,icase)**/$pat"); done
  # -z 목록은 $( ) 가 NUL 을 버리므로 read -d '' 로 읽는다. 끝에 종료 코드를 "/rc=N" 으로 붙인다(목록 이름은 /로 시작하지 않는다)
  # ":(glob)**/" = 끝이 / 인 항목 = 안 추적 중첩 저장소(git 은 그 안을 보여 주지 않는다)
  while IFS= read -r -d '' p; do
    case "$p" in
      /rc=*) rc=${p#/rc=}; continue ;;
      */) subs+=("${p%/}"); continue ;;
    esac
    f=$root/$p
    [ -f "$f" ] || continue
    is_secret_path "$f" || continue
    if [ -n "$g" ]; then glob_hits_secret "$g" "${f##*/}" || continue; fi
    SEC_FOUND=$f; return 0
  done < <(git -c core.fsmonitor=false -c core.quotePath=false -C "$root" ls-files -z -co --exclude-standard -- "${pspec[@]}" ':(glob)**/' 2>/dev/null; printf '/rc=%s\0' "$?")
  if [ "$rc" != 0 ]; then unignored_secret_scan "$root" "$g"; return; fi
  # 서브모듈(gitlink, 모드 160000): 목록에 그 안의 파일이 나오지 않는다
  out=$(git -c core.fsmonitor=false -c core.quotePath=false -C "$root" ls-files -c -s 2>/dev/null | grep '^160000 '; echo "/rc=${PIPESTATUS[0]}")
  rc=""
  while IFS= read -r p; do
    case "$p" in
      /rc=*) rc=${p#/rc=} ;;
      *"$TAB"'"'*) block "$MSG_WIDE [Grep · 하위 저장소 이름]" "$MSG_WIDE2" ;;   # 이름이 인용됨(특수 글자) — 폴더를 찾을 수 없으니 막는다
      *"$TAB"*) subs+=("${p#*"$TAB"}") ;;
    esac
  done <<EOF
$out
EOF
  if [ "$rc" != 0 ]; then unignored_secret_scan "$root" "$g"; return; fi
  for s in "${subs[@]}"; do
    [ -d "$root/$s" ] || continue
    SEC_REPOS=$((SEC_REPOS + 1))
    [ "$SEC_REPOS" -gt 20 ] && block "$MSG_WIDE [Grep · 저장소 수 $SEC_REPOS>20]" "$MSG_WIDE2"
    if [ -e "$root/$s/.git" ]; then
      unignored_secret_under "$root/$s" "$g" && return 0
    else
      unignored_secret_scan "$root/$s" "$g" && return 0   # 저장소가 아닌 gitlink 폴더(초기화 안 된 서브모듈 등)
    fi
  done
  SEC_FOUND=""
  return 1
}
# 지금 방식(git 밖·git 실패): 세 단계 아래까지 훑어 비밀값 이름 꼴 파일을 찾고, git 저장소면 무시된 것을 뺀다 → SEC_FOUND
unignored_secret_scan() { # $1 폴더 $2 (있으면) 이 glob에 맞는 파일만
  local root=$1 f d1 d2 list="" ign n=0 g=${2:-} pat t0=$SECONDS
  SEC_FOUND=""
  [ -d "$root" ] || return 1
  # 세 단계 아래까지(숨김 폴더 포함) 훑되, node_modules 같은 큰 폴더에는 들어가지 않는다
  # 폴더가 너무 많거나(200개) 오래 걸리면(이 함수 시작부터 5초) 판정할 수 없으니 통과시키지 않고 막는다
  local dirs=("$root") d3
  # 하위 폴더 목록을 먼저 펼쳐 개수를 보고, 넘으면 더 들어가지 않고 바로 막는다(맞지 않은 glob 글자 2개 몫은 여유)
  local l1=("$root"/*/ "$root"/.[!.]*/) l2 l3
  [ "${#l1[@]}" -gt 202 ] && block "$MSG_WIDE [Grep · 폴더 수 ${#l1[@]}>200]" "$MSG_WIDE2"
  for d1 in "${l1[@]}"; do
    heavy_dir "$d1" && continue
    dirs+=("${d1%/}")
    l2=("$d1"*/ "$d1".[!.]*/)
    n=$((${#dirs[@]} + ${#l2[@]})); [ "$n" -gt 202 ] && block "$MSG_WIDE [Grep · 폴더 수 $n>200]" "$MSG_WIDE2"
    for d2 in "${l2[@]}"; do
      heavy_dir "$d2" && continue
      dirs+=("${d2%/}")
      l3=("$d2"*/)
      n=$((${#dirs[@]} + ${#l3[@]})); [ "$n" -gt 201 ] && block "$MSG_WIDE [Grep · 폴더 수 $n>200]" "$MSG_WIDE2"
      for d3 in "${l3[@]}"; do heavy_dir "$d3" && continue; dirs+=("${d3%/}"); done
      [ $((SECONDS - t0)) -ge 5 ] && block "$MSG_WIDE [Grep · 시간 5초]" "$MSG_WIDE2"
    done
  done
  n=0
  shopt -s nocaseglob   # 이름 꼴은 대소문자를 가리지 않는다(.ENV · ID_RSA) — 아래 반복문에서만 켠다
  for d1 in "${dirs[@]}"; do
    for pat in "${SEC_NAME_GLOBS[@]}"; do
      for f in "$d1"/$pat; do
        [ -f "$f" ] || continue
        is_secret_path "$f" || continue
        if [ -n "$g" ]; then glob_hits_secret "$g" "${f##*/}" || continue; fi
        list="$list$f$NL"; n=$((n + 1)); [ "$n" -ge 40 ] && break 3
      done
    done
  done
  shopt -u nocaseglob
  [ -z "$list" ] && return 1
  # git 저장소면 무시된 파일은 뺀다(Grep 도구가 보지 않음). git이 아니면 모두 보인다고 본다.
  if command -v git >/dev/null 2>&1 && git -c core.fsmonitor=false -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    ign=$(printf '%s' "$list" | git -c core.fsmonitor=false -C "$root" check-ignore --stdin 2>/dev/null)
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

# SQL 을 문장으로 나누는 awk(LC_ALL=C 에서 한 글자씩): -- 줄 주석·/* */ 주석은 지우고, 작은따옴표 안(값)은 '_' 로 비우고,
# 큰따옴표 안(이름)은 그대로, 따옴표 밖의 ; 에서만 문장을 나눈다. 줄바꿈은 문장 구분이 아니라 칸이다(UPDATE x⏎SET …⏎WHERE …).
# 위험 낱말이 든 문장만 한 줄에 하나씩(16KB 까지) 내보낸다. 값 속 글자('a;b', 'where')가 판정을 흔들지 않게.
# 작은따옴표 안 역슬래시는 글자다(표준 문자열 'C:\' 는 거기서 끝난다) — E'…' 에서만 \' 를 이스케이프로 본다.
# 달러 따옴표($$…$$ · $tag$…$tag$)는 값('_')으로 비우되, 그 안을 SQL 로도 따로 한 번 더 나눠 본다(함수 본문일 수도, 글자일 수도 있으니 두 해석 모두).
AWK_SQL='function fl(e) { if (e > r0) b = b substr(s, r0, e - r0) }
function em(   t) { t = b; gsub(/[\n\r\t]/, " ", t); if (tolower(t) ~ /drop|alter|truncate|flush|delete|update|remove/) print substr(t, 1, 16384); b = "" }
function lex(x,   i, c, p, rest, tag, bs) {
  s = x; n = length(s); st = 0; b = ""; r0 = 1
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (st == 0) {
      if (c == "\047") { fl(i); b = b "\047_\047"; st = 1; p = (i > 1) ? substr(s, i - 1, 1) : ""; es = ((p == "e" || p == "E") && (i == 2 || substr(s, i - 2, 1) !~ /[A-Za-z0-9_$]/)) }
      else if (c == "\"") st = 2
      else if (c == "-" && substr(s, i + 1, 1) == "-") { fl(i); b = b " "; st = 3; i++ }
      else if (c == "/" && substr(s, i + 1, 1) == "*") { fl(i); b = b " "; st = 4; i++ }
      else if (c == "$" && (i == 1 || substr(s, i - 1, 1) !~ /[A-Za-z0-9_$]/)) {
        rest = substr(s, i)
        if (match(rest, /^[$]([A-Za-z_][A-Za-z0-9_]*)?[$]/)) { tag = substr(rest, 1, RLENGTH); fl(i); b = b "\047_\047"; st = 5; i += RLENGTH - 1; bs = i + 1 }
      }
      else if (c == ";") { fl(i); em(); r0 = i + 1 }
    } else if (st == 1) { if (c == "\\" && es) i++; else if (c == "\047") { st = 0; r0 = i + 1 } }
    else if (st == 2) { if (c == "\"") st = 0 }
    else if (st == 3) { if (c == "\n") { st = 0; r0 = i } }
    else if (st == 4) { if (c == "*" && substr(s, i + 1, 1) == "/") { st = 0; i++; r0 = i + 1 } }
    else if (st == 5) { if (c == "$" && substr(s, i, length(tag)) == tag) { if (nq < 50) q[++nq] = substr(s, bs, i - bs); st = 0; i += length(tag) - 1; r0 = i + 1 } }
  }
  if (st == 0 || st == 2) fl(n + 1)
  if (st == 5 && nq < 50) q[++nq] = substr(s, bs)
  em() }
BEGIN { RS = "\001" }
{ nq = 1; q[1] = $0; for (k = 1; k <= nq; k++) lex(q[k]) }'
# SQL·DB 명령이 데이터를 통째로 지우거나 구조를 삭제하는가
#  $2 = sql  : 순수 SQL(MCP 도구의 query·sql 칸, 줄바꿈 그대로) — AWK_SQL 로 문장을 나눠 문장마다 아래 판정
#  $2 = shell: 셸 명령(줄바꿈 그대로) — 따옴표 안 문자열은 SQL 로(psql -c "UPDATE …⏎WHERE …"), 따옴표 밖(히어독·redis-cli FLUSHALL)은
#              예전처럼 줄바꿈을 명령 구분으로 본다
sql_destructive() {
  local pt out rest m c re_q="\"(([^\"\\\\]|\\\\.)*)\"|'([^']*)'"
  if [ "$2" = "sql" ]; then
    case "$1" in *drop*|*alter*|*truncate*|*flush*|*delete*|*update*|*remove*) ;; *) return 1 ;; esac
    out=$(printf '%s' "$1" | awk "$AWK_SQL" 2>/dev/null)
    while IFS= read -r pt; do
      [ -n "$pt" ] && sql_stmt_destructive "$pt" sql && return 0
    done <<< "$out"
    return 1
  fi
  rest=$1; out=""
  while [[ $rest =~ $re_q ]]; do
    m=${BASH_REMATCH[0]}; c=${BASH_REMATCH[1]}${BASH_REMATCH[3]}
    out="$out${rest%%"$m"*} "; rest=${rest#*"$m"}
    if [ "${m:0:1}" = '"' ]; then c=${c//\\\"/\"}; c=${c//\\\\/\\}; fi
    sql_destructive "$c" sql && return 0
  done
  out="$out$rest"
  sql_stmt_destructive "${out//$NL/ ; }" shell
}
# 문장(또는 따옴표를 뺀 셸 명령) 하나를 판정한다. $2: shell / sql
sql_stmt_destructive() {
  local t=$1 seg rest stop re_lc re_bc='/\*([^*]|\*+[^*/])*\*+/'
  if [ "$2" = "sql" ]; then stop='[^;]*'; else stop='[^;"]*'; fi
  # 주석(/* … */, -- …)은 지우고 본다 — DELETE FROM x -- where … 가 조건처럼 보이거나 DROP/**/TABLE 로 규칙을 피하지 않게
  while [[ $t =~ $re_bc ]]; do t=${t/"${BASH_REMATCH[0]}"/ }; done
  if [ "$2" = "sql" ]; then re_lc='--[^;]*'; else re_lc="--[[:space:]][^;\"']*"; fi
  while [[ $t =~ $re_lc ]]; do t=${t/"${BASH_REMATCH[0]}"/ }; done
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
  # 경로 인자(path·file_path·paths·uri·file …)가 비밀값 파일이면 막는다(도구 이름과 무관하게 인자 이름으로)
  # (키가 입력에 없으면 건너뛴다. 키마다 따로 찾고 나머지는 정규식 끝 (.*) 로 받는다 — 여러 이름을 한 정규식에 묶거나 ${x#*…} 로 자르면
  #  200KB 입력에서 수십 초가 걸려 훅 제한 시간을 넘긴다)
  local rest v arr pk re_pk
  local re_s='"(([^"\\]|\\.)*)"'
  for pk in path file_path filepath file filename uri url paths files source destination target; do
    case "$input" in *"\"$pk\""*) ;; *) continue ;; esac
    rest=$input; re_pk="\"$pk\"[[:space:]]*:[[:space:]]*(\"(([^\"\\\\]|\\\\.)*)\"|\\[[^]]*\\])(.*)"
    while [[ $rest =~ $re_pk ]]; do
      arr=${BASH_REMATCH[1]}; v=${BASH_REMATCH[2]}; rest=${BASH_REMATCH[4]}
      case "$arr" in '['*) ;; *) arr="\"$v\"" ;; esac
      while [[ $arr =~ $re_s ]]; do
        v=${BASH_REMATCH[1]}; arr=${arr#*"${BASH_REMATCH[0]}"}
        unesc_line "$v"; v=${UV#file://}; v=${v%%\?*}
        [ -z "$v" ] && continue
        normpath "$v"
        is_secret_path "$NP" && block "비밀값 파일(${NP##*/})은 MCP 도구로도 열거나 보내지 않습니다." "이름·git 추적 여부만 확인하세요(git ls-files, ls -a). 필요한 값은 사람에게 물어보세요."
      done
    done
  done
  # 명령·코드 인자(command·cmd·script·code …)는 셸 명령 판정을 그대로 태운다. query 는 실행 도구(sql·exec·run·shell…)일 때만
  # (MCP 입력은 크기로 막지 않는다 — 노션 긴 글·큰 SQL 도 정상 작업. 대신 키가 입력에 아예 없으면 jget 을 건너뛰어 큰 입력도 빨리 끝낸다)
  local k q=""
  for k in command cmd script shell_command commandline args_command; do
    case "$input" in *"\"$k\""*) ;; *) continue ;; esac
    jget "$k"; [ -n "$JV" ] && check_shell "$JV"
  done
  case "$input" in *'"code"'*) jget code; [ -n "$JV" ] && check_shell "python3 -c $JV" ;; esac
  # 아주 큰 SQL(입력 256KB 초과): 값 꺼내기·문장 나누기가 1MB 에서 훅 제한 시간을 넘기므로 정밀 판정은 하지 않는다.
  # 위험 낱말(sql_destructive 가 보는 drop·alter·truncate·flush·delete·update·remove)이 낱말로 있는지만 awk 로 한 번 보고, 있으면 막는다
  if [ "${#input}" -gt 262144 ] && has "$tool" 'sql|execute|migration|query_database|run_query'; then
    if printf '%s' "$input" | awk 'BEGIN { RS = "\001" } { s = tolower($0); f = (s ~ /(^|[^a-z0-9_]|[\\][nrt])(drop|alter|truncate|flushall|flushdb|delete|update|remove)([^a-z0-9_]|$)/) } END { exit !f }' 2>/dev/null; then
      block "SQL 이 너무 커서(256KB 초과) 정밀 판정을 못 합니다 — 나눠서 보내세요." "INSERT 처럼 무해한 부분과 지우기·바꾸기 문장을 나눠 256KB 이하로 보내세요. 운영 DB 작업은 사람이 백업을 확인한 뒤 직접 합니다."
    fi
  else
    case "$input" in *'"query"'*) jget query; q=$JV ;; esac
  fi
  # 16KB 넘는 query 는 셸 명령 길이 상한(파일로 저장해 실행)에 걸리므로 셸 판정은 건너뛰고 아래 SQL 파괴 판정만 한다(큰 INSERT 등)
  if [ -n "$q" ] && [ "${#q}" -le 16384 ] && has "$tool" 'sql|exec|run|shell|bash|terminal|command|script|eval|query_database'; then
    check_shell "$q"
  fi
  if [ "${#input}" -le 262144 ] && has "$tool" 'sql|execute|migration|query_database|run_query'; then
    local sqltext=""
    # SQL 은 자르지 않고 푼다(unesc_line 은 2만 자에서 자른다 — 큰 SQL 끝의 DROP 을 놓치지 않게)
    if [ -n "$q" ]; then unesc_nl "$q"; sqltext=$UV; fi
    if [ -z "$sqltext" ]; then case "$input" in *'"sql"'*) jget sql; if [ -n "$JV" ]; then unesc_nl "$JV"; sqltext=$UV; fi ;; esac; fi
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
# 파이썬·노드 같은 인터프리터 코드가 이 경로에 쓰는가($1 = 경로 정규식). 검사 대상: lr · 0.3.7 G6: 단순 따옴표를 벗기기 전 사본 lr0 도(다를 때만)
interp_writes() {
  iw_one "$lr" "$1" && return 0
  [ -n "${lr0:-}" ] && [ "$lr0" != "$lr" ] && iw_one "$lr0" "$1"
}
iw_one() {
  has "$1" "${S}(python3?|py|node|ruby|php|perl|deno|bun|pwsh|powershell)[[:space:]]" || return 1
  has "$1" "$2" || return 1
  # 0.3.5 F7②: open 의 방식 글자에 > 도(perl open(F,">",…) · ">>")
  has "$1" "open[(][^)]*['\"][wax+>]|write_?text|write_?bytes|writefile|write_file|appendfile|fs[.](write|append|rm|unlink|rename|copy|truncate)|[.]unlink|rmtree|os[.](remove|rename|replace)|shutil[.](move|copy)|set-content|out-file|add-content|[.]replace[(]" || return 1
  return 0
}
# 0.3.5 X2: 인터프리터 코드가 플러그인 폴더(.claude/plugins · 지금 플러그인 폴더 plugroot)에 쓰는가. 플러그인 폴더 경로는 글자 그대로의 정규식으로
#   (구분자 / 와 \ 는 같게 · Windows 의 c:/… 는 Git Bash 꼴 /c/… 도). 인터프리터 낱말이 없으면 경로 정규식을 만들지 않는다(평소 비용 0)
interp_plug_writes() {
  has "$lr" "${S}(python3?|py|node|ruby|php|perl|deno|bun|pwsh|powershell)[[:space:]]" || return 1
  # 0.3.7 G7: 명령이 도는 폴더(cwd)가 플러그인 폴더 안이면 상대경로(open('scripts/…','w'))도 — 쓰기 낱말만으로 막는다(plugroot 가 비면 그 비교는 건너뜀)
  case "$cwd/" in */.claude/plugins/*) interp_writes '.' && return 0 ;; esac
  if [ -n "$plugroot" ]; then case "$cwd/" in "$plugroot"/*) interp_writes '.' && return 0 ;; esac; fi
  interp_writes '\.claude[/\\]+plugins' && return 0
  [ -n "$plugroot" ] || return 1
  local p=$plugroot c i re="" alt=""
  for ((i = 0; i < ${#p}; i++)); do
    c=${p:i:1}
    case "$c" in
      [A-Za-z0-9]) re="$re$c" ;;
      /) re="$re[/\\\\]+" ;;
      "$BS") re="$re\\\\" ;;
      '^') re="$re\\^" ;;
      ']') re="$re\\]" ;;
      '[') re="$re\\[" ;;
      *) re="$re[$c]" ;;
    esac
  done
  # c:/… 이면 Git Bash 꼴 /c/… 도(앞 세 글자 c[:][/\\]+ 를 [/\\]+c[/\\]+ 로)
  case "$p" in [A-Za-z]:/*) alt="|[/\\\\]+${p:0:1}${re#?\[:\]}" ;; esac
  interp_writes "$re$alt"
}

# 0.3.4 T5: $1 이 따옴표 밖에서 끝나는가(bash 의 따옴표 규칙) — 밖의 \X · '…'(안은 그대로) · "…"(안의 \X) · $'…'(안의 \X) · $"…" · $ 다음 한 글자.
#   따옴표·역슬래시가 없으면 정규식을 돌리지 않는다. 명령 치환 $( )·` ` 안의 따옴표는 따로 보지 않는다(지금도 그런 문자열은 지우지 않음)
RE_QOUT='^([^"'"'"'\\$]|\\.|[$]('"'"'([^'"'"'\\]|\\.)*'"'"'|"([^"\\]|\\.)*"|\\.|[^'"'"'"\\]|$)|'"'"'[^'"'"']*'"'"'|"([^"\\]|\\.)*")*$'
q_outside() { case "$1" in *[\"\'\\]*) [[ $1 =~ $RE_QOUT ]] ;; *) return 0 ;; esac; }
# 앵커가 따옴표 안일 때 그 따옴표가 닫히는 자리까지 한 번에 넘긴다(한 글자씩 넘기면 큰따옴표 안에 앵커가 많은 긴 명령이 느려진다) →
#   QN = $2(앵커부터의 원문)에서 넘길 글자 수 · -1 = 끝까지 안 닫힘(뒤에는 따옴표 밖 자리가 없다). $1 = 마지막 밖 자리부터 앵커 앞까지(따옴표 안에서 끝남)
RE_QPRE='^([^"'"'"'\\$]|\\.|[$]('"'"'([^'"'"'\\]|\\.)*'"'"'|"([^"\\]|\\.)*"|\\.|[^'"'"'"\\]|$)|'"'"'[^'"'"']*'"'"'|"([^"\\]|\\.)*")*'
RE_Q1='^('"'"'[^'"'"']*'"'"'|"([^"\\]|\\.)*"|[$]'"'"'([^'"'"'\\]|\\.)*'"'"'|[$]"([^"\\]|\\.)*"|\\.)'
q_skip() {
  local r
  [[ $1 =~ $RE_QPRE ]]; r=${1:${#BASH_REMATCH[0]}}
  QN=1; [ -n "$r" ] || return 0
  if [[ $r$2 =~ $RE_Q1 ]] && [ "${#BASH_REMATCH[0]}" -gt "${#r}" ]; then QN=$((${#BASH_REMATCH[0]} - ${#r})); else QN=-1; fi
}
# 따옴표 인자 하나를 _Q_로 바꾼다(명령 치환이 든 것은 그대로). $1 정규식(따옴표 인자가 마지막 괄호) $2 그 괄호 번호 $3 원문 → BQ
#   0.3.4 T4·T5: 지울 따옴표 인자의 앞과 끝이 둘 다 따옴표 밖일 때만 지운다(따옴표 안의 ; 를 앵커로 읽거나 "a\" 를 닫힌 따옴표로 읽어
#   cat ';git commit -m x'; git push -f; cat 'y' 의 밖 명령을 문구로 지우지 않게). 아니면 한 글자 넘겨 다시 찾는다.
#   밖 판정은 "마지막으로 밖이었던 자리"(qt 의 시작) 뒤 글자만 다시 잰다 — 앞부분 전체를 매번 재면 긴 명령에서 느려진다
blank_quoted() {
  local re=$1 gi=$2 rest=$3 out="" m0 mq pre qt="" qa=0 re_cs='[$][(]|`' re_se='^[(][[:space:]]*(echo|printf|write-output)'
  case "$rest" in *[\"\'\\]*) qa=1 ;; esac
  while [[ $rest =~ $re ]]; do
    m0=${BASH_REMATCH[0]}; mq=${BASH_REMATCH[$gi]}
    pre=${rest%%"$m0"*}
    if [ "$qa" = 1 ]; then
      if ! q_outside "$qt$pre"; then   # 앵커가 따옴표 안 → 그 따옴표 끝까지 넘김
        q_skip "$qt$pre" "${rest:${#pre}}"
        [ "$QN" -lt 0 ] && break
        QN=$((${#pre} + QN)); out="$out${rest:0:$QN}"; rest=${rest:$QN}; qt=""; continue
      fi
      if ! q_outside "$qt$pre${m0%"$mq"}" || ! q_outside "$qt$pre$m0"; then   # 인자 앞·끝이 따옴표 안("a\" 꼴·$'…\'…') → 한 글자 넘김
        out="$out$pre${m0:0:1}"; qt="$qt$pre${m0:0:1}"; rest=${rest:$((${#pre} + 1))}; continue
      fi
    fi
    out="$out$pre"
    rest=${rest#*"$m0"}
    # $(echo "…") 의 문구는 명령의 인자가 되므로 지우지 않는다(cat $(echo ".env"))
    if [[ $mq =~ $re_cs ]] || { [ "${out: -1}" = '$' ] && [[ $m0 =~ $re_se ]]; }; then
      out="$out$m0"; case "$m0" in *'$') qt="$qt$pre$m0" ;; *) qt="" ;; esac   # 끝이 $ 면 다음 따옴표가 $'…' 가 되므로 그 자리부터 다시 재지 않는다
    else out="$out${m0%"$mq"}_Q_"; qt=""; fi
  done
  BQ="$out$rest"
}
# 프로젝트(또는 두 단계 아래 폴더)에 .env 가 있나 — 전체 검색 규칙에서만 부른다
env_near() {
  local f
  [ "$has_env_file" = 1 ] && return 0
  for f in "$proj"/*/.env* "$proj"/*/*/.env*; do
    [ -e "$f" ] || continue
    case "${f##*/}" in *.example|*.sample|*.template|*.dist|.envrc) ;; *) return 0 ;; esac
  done
  return 1
}
under_proj() { case "$1" in "$proj"/*) return 0 ;; esac; return 1; }

# echo·printf 의 따옴표 없는 글자도 뺀다(echo .env >> .gitignore 는 막지 않게). > 리다이렉트 대상과 $( ) 는 남긴다 → BQ
#   0.3.4 T5: 앵커(; & | ( 줄 머리)와 지울 인자의 끝이 둘 다 따옴표 밖일 때만(blank_quoted 와 같은 판정 · 같은 qt)
blank_echo_words() {
  local rest=$1 out="" m0 lead args kept r pre qt="" qa=0
  local re='(^|[;&|(])([[:space:]]*(echo|printf|write-host|write-output))([^;&|]*)'
  local re_r='[0-9]*>>?[[:space:]]*[^[:space:];&|<>]+' re_cs='[$][(]|`'
  case "$rest" in *[\"\'\\]*) qa=1 ;; esac
  while [[ $rest =~ $re ]]; do
    m0=${BASH_REMATCH[0]}; lead="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"; args=${BASH_REMATCH[4]}
    pre=${rest%%"$m0"*}
    if [ "$qa" = 1 ]; then
      if ! q_outside "$qt$pre"; then
        q_skip "$qt$pre" "${rest:${#pre}}"
        [ "$QN" -lt 0 ] && break
        QN=$((${#pre} + QN)); out="$out${rest:0:$QN}"; rest=${rest:$QN}; qt=""; continue
      fi
      if ! q_outside "$qt$pre$m0"; then out="$out$pre${m0:0:1}"; qt="$qt$pre${m0:0:1}"; rest=${rest:$((${#pre} + 1))}; continue; fi
    fi
    out="$out$pre"; rest=${rest#*"$m0"}
    if [[ $args =~ $re_cs ]] || { [ "${out: -1}" = '$' ] && [ "${m0:0:1}" = '(' ]; }; then   # $(echo .env) 는 인자가 된다
      out="$out$m0"; case "$m0" in *'$') qt="$qt$pre$m0" ;; *) qt="" ;; esac; continue
    fi
    kept=""
    while [[ $args =~ $re_r ]]; do r=${BASH_REMATCH[0]}; kept="$kept $r"; args=${args#*"$r"}; done
    out="$out$lead _Q_$kept "; qt=""
  done
  BQ="$out$rest"
}

# PowerShell에서 비밀값 이름의 환경변수 값을 꺼내는가($env:X 는 그 자체로 값을 출력한다). 대입·if 조건 안은 제외
ps_env_read() {
  local t=$lr m nm pre post re='\$env:([a-z0-9_]+)'
  local re_asg='^[[:space:]]*=[^=]' re_test='((if|elseif|while)[[:space:]]*[(][[:space:]]*(-not[[:space:]]+|!)?|isnullorempty[(]|isnullorwhitespace[(])$'
  while [[ $t =~ $re ]]; do
    m=${BASH_REMATCH[0]}; nm=${BASH_REMATCH[1]}; pre=${t%%"$m"*}; post=${t#*"$m"}
    if [[ $post =~ $re_asg ]] || [[ $pre =~ $re_test ]]; then t=$post; continue; fi
    sens_name "$nm" && return 0   # 이름을 _ 로 나눈 단어로 본다($env:MONKEY 는 아님)
    t=$post
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
  local w=() i=0 j w1 w2 w3 k
  # 래퍼(cmd /c · powershell -c · { } · ( ) · if/then · for … do · ! · stdbuf · nohup · env VAR=1 · xargs · bash -c)를 벗기고 본다
  seg_words "$1"; w=("${SW[@]}"); i=$SI
  while [ "$i" -lt "${#w[@]}" ]; do
    case "${w[$i]}" in
      *=*|sudo|time|nohup|command|exec|cross-env|xvfb-run) i=$((i + 1)) ;;
      env) i=$((i + 1)); while [ "$i" -lt "${#w[@]}" ] && [[ ${w[$i]} == -* ]]; do i=$((i + 1)); done ;;
      timeout|nice) i=$((i + 1)); while [ "$i" -lt "${#w[@]}" ] && [[ ${w[$i]} == -* || ${w[$i]} =~ ^[0-9.]+[smhd]?$ ]]; do i=$((i + 1)); done ;;
      *) break ;;
    esac
  done
  w1=${w[$i]:-}; w1=${w1##*/}; w1=${w1##*"$BS"}; w1=${w1%.exe}; w1=${w1%.cmd}
  # npm 류는 --prefix·-w/--workspace·--filter·-r·-C 같은 옵션을 건너뛰고 서브커맨드를 본다
  k=$((i + 1))
  case "$w1" in
    npm|pnpm|yarn|bun)
      while [ "$k" -lt "${#w[@]}" ]; do
        case "${w[$k]}" in
          --prefix|-w|--workspace|--filter|-F|-C|--dir|--cwd|--userconfig|--cache|--registry|--loglevel) k=$((k + 2)) ;;
          -*) k=$((k + 1)) ;;
          *) break ;;
        esac
      done ;;
  esac
  w2=${w[$k]:-}; w3=${w[$((k + 1))]:-}
  case "$w1" in
    npm|pnpm|yarn|bun)
      case "$w2" in
        run|run-script)
          case "$w3" in ""|lint|lint:*|typecheck|type-check|tsc|check-types|format:check|fmt:check|prettier:check) return 1 ;; esac
          return 0 ;;
        exec|dlx|x) npx_runs "${w[@]:$((k + 1))}"; return $? ;;
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

# ── 셸 명령 정규화·분해 도우미 ──────────────────────────────────────────────
# 전각 글자(ｒｍ·．·～·전각 공백)를 반각으로 바꾼다 → FW. Windows 의 글자 맞춤 변환으로 실제 명령이 될 수 있어 판정 전에 맞춘다
fw_norm() {
  FW=$1
  case "$FW" in *$'\xef\xbc'*|*$'\xef\xbd'*|*$'\xe3\x80\x80'*) ;; *) return 0 ;; esac
  local i c h2 h3 ch a
  FW=${FW//$'\xe3\x80\x80'/ }
  for ((i = 33; i <= 126; i++)); do
    c=$((i + 65248))
    printf -v h2 '%x' $((128 | ((c >> 6) & 63)))
    printf -v h3 '%x' $((128 | (c & 63)))
    printf -v ch "\\xef\\x$h2\\x$h3"
    case "$FW" in
      *"$ch"*) printf -v h2 '%x' "$i"; printf -v a "\\x$h2"; FW=${FW//"$ch"/"$a"} ;;
    esac
  done
}

# 단어 안의 빈 따옴표 쌍('' "")을 지운다(re''set → reset, n""pm → npm, .e''nv → .env) — bash 에서는 같은 단어다.
# 홀로 선 '' "" 는 빈 인자(grep -n "" .env)라 그대로 둔다 → EQ
rm_empty_quotes() {
  EQ=$1
  case "$EQ" in *"''"*|*'""'*) ;; *) return 0 ;; esac
  EQ=${EQ//"\$''"/}; EQ=${EQ//'$""'/}   # $'' · $"" 도 빈 문자열이다(re$''set → reset)
  local re="([^[:space:];&|<>()])(''|\"\")+|(''|\"\")+([^[:space:];&|<>()])" m k=0
  while [[ $EQ =~ $re ]] && [ "$k" -lt 200 ]; do
    m=${BASH_REMATCH[0]}; EQ=${EQ/"$m"/"${BASH_REMATCH[1]}${BASH_REMATCH[4]}"}; k=$((k + 1))
  done
}
# 공백·특수문자·$·와일드카드가 없는 따옴표 인자는 따옴표를 벗긴다("--hard" → --hard, '.env' → .env, re'set' → reset) → UQ
# 공백·;&|<>·괄호·$ 가 든 문자열(명령·코드·검색어)은 따옴표째 그대로 둔다 — 그 안은 기존 판정이 따옴표를 경계로 본다. <<'EOF' 구분자도 그대로
unquote_simple() {
  UQ=$1
  case "$UQ" in *[\"\']*) ;; *) return 0 ;; esac
  local s=$1 out="" m c re="\"([^\"]*)\"|'([^']*)'" re_ok='^[A-Za-z0-9_./:@%+=,~-]+$' re_hd='<<-?[[:space:]]*$'
  while [[ $s =~ $re ]]; do
    m=${BASH_REMATCH[0]}; c=${BASH_REMATCH[1]}${BASH_REMATCH[2]}
    out="$out${s%%"$m"*}"; s=${s#*"$m"}
    if [[ $c =~ $re_ok ]] && ! [[ $out =~ $re_hd ]]; then
      [ "${out: -1}" = '$' ] && out=${out%?}   # $'--hard' · $"x" 도 같은 글자다(ANSI-C·로캘 따옴표)
      out="$out$c"
    else out="$out$m"; fi
  done
  UQ="$out$s"
}
# bash 처럼 역슬래시를 푼 모양 → BSV: 따옴표 밖 \X → X(\\ → \), 큰따옴표 안은 \$ \` \" \\ 만, 작은따옴표 안은 그대로
# (git re\set → git reset, cat .e\nv → cat .env). 경로 판정은 원형으로 하므로 이 모양은 판정 문자열 뒤에 덧붙여서만 쓴다
unbs() {
  BSV=$1
  case "$BSV" in *"$BS"*) ;; *) return 0 ;; esac
  local s=$1 out="" m o re="\"(([^\"\\\\]|\\\\.)*)\"|'[^']*'"
  while [[ $s =~ $re ]]; do
    m=${BASH_REMATCH[0]}; o=${s%%"$m"*}; s=${s#*"$m"}
    o=${o//"$BS$BS"/$PH}; o=${o//"$BS"/}; o=${o//$PH/$BS}
    if [ "${m:0:1}" = '"' ]; then m=${m//"$BS$BS"/$PH}; m=${m//"$BS\$"/\$}; m=${m//"$BS\`"/\`}; m=${m//"$BS$Q"/$Q}; m=${m//$PH/$BS}; fi
    out="$out$o$m"
  done
  s=${s//"$BS$BS"/$PH}; s=${s//"$BS"/}; s=${s//$PH/$BS}
  BSV="$out$s"
}
# 판정용 변형 → VV: bash 가 풀었을 때와 같은 뜻의 모양. 원형 뒤에 덧붙여 모든 규칙이 같이 본다
#  1) $'…'(ANSI-C) 를 푼다(\xHH·\NNN·\uHHHH·\n …) — $'…' 안에서는 치환·명령 실행이 없으므로 eval 로 글자만 푼다
#  2) 단어 가운데의 정의되지 않은 변수·$@·$* 는 빈 글자(refactor-app${x}rove · git re${x}set) — 단어 머리의 $DIR 등은 그대로
#  3) 한 단계 중괄호 {a,b} 는 펼친다(--from{-hook,} → --from-hook --from)
#  4) 역슬래시를 푼다(unbs), 단순 따옴표 인자는 벗긴다
mk_variant() {
  VV=$1
  case "$VV" in *[\$\\{]*) ;; *) return 0 ;; esac
  local s=$1 out m c v n pre post body rest alts k=0
  local re_a="[\$]'(([^'\\\\]|\\\\.)*)'" re_v="[\$]([{]([A-Za-z_][A-Za-z0-9_]*|[@*])[}]|([A-Za-z_][A-Za-z0-9_]*)|([@*]))"
  local re_b='([^[:space:]{}$]*)[{]([^{}[:space:]]*,[^{}[:space:]]*)[}]([^[:space:]{}]*)' re_w='[[:alnum:]._/-]'
  case "$s" in *"\$'"*)
    out=""
    while [[ $s =~ $re_a ]]; do
      m=${BASH_REMATCH[0]}; c=${BASH_REMATCH[1]}
      out="$out${s%%"$m"*}"; s=${s#*"$m"}
      v=""; eval "v=\$'$c'" 2>/dev/null || v=$c   # $'…' 는 글자 풀기뿐(치환·실행 없음). c 에는 이스케이프 안 된 ' 가 없다(정규식)
      case "$v" in *"'"*) v="\"${v//\"/}\"" ;; *) v="'$v'" ;; esac
      out="$out$v"
    done
    s="$out$s" ;;
  esac
  case "$s" in *'$'*)
    out=""
    while [[ $s =~ $re_v ]]; do
      m=${BASH_REMATCH[0]}; n=${BASH_REMATCH[2]}${BASH_REMATCH[3]}${BASH_REMATCH[4]}
      out="$out${s%%"$m"*}"; s=${s#*"$m"}
      # 단어 가운데·끝(앞이 글자)에 있고 정의되지 않은 변수만 빈 글자로 본다(단어 머리의 $DIR 등은 그대로)
      if [[ ${out: -1} =~ $re_w ]]; then
        case "$n" in '@'|'*') continue ;; esac
        [ -n "${!n+x}" ] || continue
      fi
      out="$out$m"
    done
    s="$out$s" ;;
  esac
  case "$s" in *'{'*','*'}'*)
    out=""
    while [[ $s =~ $re_b ]] && [ "$k" -lt 20 ]; do
      k=$((k + 1)); m=${BASH_REMATCH[0]}; pre=${BASH_REMATCH[1]}; body=${BASH_REMATCH[2]}; post=${BASH_REMATCH[3]}
      out="$out${s%%"$m"*}"; s=${s#*"$m"}
      if [ "${out: -1}" = '$' ]; then out="$out$m"; continue; fi   # $ 바로 뒤 중괄호(변수 표기)는 중괄호 펼치기가 아니다
      alts=""; rest="$body,"
      while [ -n "$rest" ]; do alts="$alts $pre${rest%%,*}$post"; rest=${rest#*,}; done
      out="$out${alts# }"
    done
    s="$out$s" ;;
  esac
  unbs "$s"; unquote_simple "$BSV"; VV=$UQ
}
# 고가치 규칙 전용 사본 → BV: 변수 참조 표기를 문자열 처리로만 지운다(가드 자신의 환경을 쓰지 않는다 — eval·산술·명령 치환 없음).
#   정의되지 않은 변수를 bash 가 어떻게 풀지 흉내: ${NAME}·$NAME·$1..$9·${9}·$@·$*·$#·$?·$$·$!·$- → 빈 글자,
#   ${x:-word}·${x-word}·${x:=word}·${x=word} → word, ${x:+word}·${x+word}·${x:?..}·${x/a/b}·${x#p}·${x:1} → 빈 글자.
#   (치환·자르기는 값을 알아야 정확하므로 "정의 안 됨"으로만 흉내 낸다 — x=abc; git re${x/b/}set 같은 드문 모양은 과잉차단될 수 있다)
#   이미 정의된 사용자 변수(a=x; …$a)는 expand_vars 가 먼저 값으로 바꾸므로 여기 남지 않는다 → 과잉차단 없음.
blank_vars() {
  BV=$1
  case "$BV" in *'$'*) ;; *) return 0 ;; esac
  local s=$1 out m op word k=0
  local re1='[$][{]([A-Za-z_][A-Za-z0-9_]*|[0-9]+|[-@*#?!$])(([:]?[-=+?])([^{}]*)|([/#%^,:][^{}]*))?[}]'   # ${x/a/b}·${x#p}·${x:1} 등은 정의 안 된 변수로 보고 빈 글자
  local re2='[$]([A-Za-z_][A-Za-z0-9_]*|[0-9]|[-@*#?!$])'
  out=""
  while [[ $s =~ $re1 ]] && [ "$k" -lt 200 ]; do
    k=$((k + 1)); m=${BASH_REMATCH[0]}; op=${BASH_REMATCH[3]}; word=${BASH_REMATCH[4]}
    out="$out${s%%"$m"*}"; s=${s#*"$m"}
    case "$op" in *-|*=) out="$out$word" ;; esac   # :-·-·:=·= 는 기본값(word)으로, 그 밖(:+·+·:?·없음)은 빈 글자
  done
  s="$out$s"; out=""; k=0
  while [[ $s =~ $re2 ]] && [ "$k" -lt 200 ]; do
    k=$((k + 1)); m=${BASH_REMATCH[0]}
    out="$out${s%%"$m"*}"; s=${s#*"$m"}
  done
  BV="$out$s"
}
# 와일드카드로 쓴 보호 이름을 실행하는가(bash …/refactor-appro?e.sh · bash …/hooks/tur?.sh · run.sh tu?n) — bash 글로브로 대 본다.
# 기본 이름 글로브(* · *.sh · *.*)만 보지 않는다(bash -n hooks/*.sh 같은 문법 검사)
#   $2 = 볼 이름 목록(없으면 승인·훅 진입점 — 0.3.5 합치기 스크립트는 따로 부른다: 막는 문구가 다르다)
glob_protected_exec() {
  case "$1" in *[\*\?\[]*) ;; *) return 1 ;; esac
  local s seg a b i nm names=${2:-"refactor-approve.sh refactor-approve turn.sh guard.sh post-check.sh session-start.sh turn guard post-check session-start run.sh"}
  cut_segs "$1"; s=$CUTS
  while [ -n "$s" ]; do
    seg=${s%%"$NL"*}; if [ "$seg" = "$s" ]; then s=""; else s=${s#*"$NL"}; fi
    case "$seg" in *[\*\?\[]*) ;; *) continue ;; esac
    seg_words "$seg"
    case "$SCMD" in bash|sh|zsh|dash|ksh|source|.|exec|run.sh|*[\*\?\[]*) ;; *) continue ;; esac
    for ((i = SI; i < ${#SW[@]}; i++)); do
      a=${SW[$i]}; case "$a" in *[\*\?\[]*) ;; *) continue ;; esac
      b=${a##*/}; case "$b" in '*'|'*.sh'|'*.*') continue ;; esac   # 기본 이름(* · *.sh · *.*)만 건너뛴다 — [t]urn.sh · ?urn.sh 는 대 본다
      for nm in $names; do [[ $nm == $b ]] && return 0; done
    done
  done
  return 1
}
# 인터프리터 코드(python -c · node -e · perl -e · ruby -e · php -r · 인터프리터로 흘리는 히어독) 안에 승인 스크립트·훅 진입점 이름이 있는가
# — subprocess·child_process·os.system 으로 부르는 길(문자열을 이어 붙여 --from-hook 을 만들어도). cat·grep·head 로 읽는 것은 아니다
#   $2 = 볼 이름 정규식(없으면 승인·훅 진입점 — 0.3.5 합치기 스크립트는 'refactor-merge' 로 따로 부른다: 막는 문구가 다르다)
interp_approve() {
  local nre="refactor-approve|[/\\\\](turn|guard|post-check|session-start)[.]sh|run[.]sh[^;&|]{0,24}(turn|guard|post-check|session-start)"
  [ -n "${2:-}" ] && nre=$2
  has "$1" "$nre" || return 1
  has "$1" "${S}(python3?|py|pypy3|node|ruby|perl|php|deno|bun)([[:space:]][^;&|]*)?[[:space:]](-[a-z]*[ecpr]|--eval|--print)[[:space:]]|${S}(python3?|py|pypy3|node|ruby|perl|php|deno|bun)([[:space:]]+-)?[[:space:]]*<<" || return 1
  # 읽기만 하는 코드(print(open(…).read()) · console.log)는 통과 — 프로그램을 띄우거나 모듈을 불러올 수 있는 낱말이 하나라도 있으면 막는다
  #   (넓게 잡는다: import·require·os.·process.·getattr·eval·` 등. 승인 스크립트 이름과 같이 나올 때만 보므로 과잉차단 비용이 작다)
  local t=$1; t=${t//\'/}; t=${t//\"/}
  has "$t" 'subprocess|popen|system|spawn|exec|fork|child|shell|passthru|proc_open|pty|pexpect|plumbum|sh[.]|os[.]|commands|__|import|require|getattr|globals|eval|compile|deno[.]|bun[.]|process[.]|module|_load|dlopen|ffi|ctypes|win32|wsh|activex|check_output|startfile|call[(]|run[(]|`|qx|%x|open3|kernel|open[^)]*[|]|[$][(]|command|use[[:space:]]|load'
}
MSG_HOOK_EXEC="플러그인 훅(turn·guard·post-check·session-start)은 Claude Code 가 사용자 입력·도구 호출 때 실행합니다(사람 전용). 승인은 사용자가 /refactor:approve 를 입력할 때 입력 훅이 처리합니다."
MSG_APPROVE_EXEC="승인 스크립트는 사용자가 /refactor:approve 명령으로만 실행합니다."
MSG_NESTED="승인은 사용자가 입력창에서 직접 합니다 — 새 Claude 세션을 띄워 승인하는 것도 우회입니다."
# 고가치 규칙(사람 전용: 승인·훅 진입점·중첩 claude). $1 판정 문자열(검색어·문구는 뺀 것), $2 중첩 claude 판정용
hv_human() {
  nested_claude_approve "$2" && block "$MSG_NESTED" "$MSG_APPROVE"
  # 명령 치환·경로·winpty 로 부르는 claude(“$(which claude)” -p …): claude 낱말과 승인 명령이 한 명령에 같이 있으면 막는다
  #   뒤 경계에 점을 넣지 않는다 — CLAUDE.md 같은 파일 이름은 claude 실행이 아니다(.exe·.cmd 만 실행 파일로 본다)
  if has "$1" "(^|[^[:alnum:]._/-])claude([.](exe|cmd))?([^[:alnum:]_.-]|$)" && has "$1" 'refactor:(approve|go)|from-hook'; then block "$MSG_NESTED" "$MSG_APPROVE"; fi
  if has "$1" 'refactor-approve' && approve_exec "$1"; then block "$MSG_APPROVE_EXEC" "$MSG_APPROVE"; fi
  glob_protected_exec "$1" && block "$MSG_HOOK_EXEC" "$MSG_APPROVE"
  # 0.3.5 G2: 합치기 스크립트를 실행하는 꼴(승인 스크립트와 같은 판정 · 글로브 이름) — 허락된 명령 그대로(G3, MOK)일 때만 건너뛴다
  if [ "${MOK:-0}" != 1 ]; then
    if has "$1" 'refactor-merge' && approve_exec "$1" refactor-merge; then merge_block; fi
    glob_protected_exec "$1" "refactor-merge.sh refactor-merge" && merge_block
  fi
  # 0.4.0 G2: 자동 모드 스크립트(refactor-auto)를 실행하는 꼴(승인 스크립트와 같은 판정 · 글로브 이름 · 새 Claude 세션에 넘기기) —
  #   유효한 자동 허락(.turn-auto/.turn-merged)이 있고 정해진 꼴 그대로(AOK)일 때만 건너뛴다
  if [ "${AOK:-0}" != 1 ]; then
    nested_claude_approve "$2" 'refactor-auto' && auto_block
    if has "$1" "(^|[^[:alnum:]._/-])claude([.](exe|cmd))?([^[:alnum:]_.-]|$)" && has "$1" 'refactor-auto'; then auto_block; fi
    if has "$1" 'refactor-auto' && approve_exec "$1" refactor-auto; then auto_block; fi
    glob_protected_exec "$1" "refactor-auto.sh refactor-auto" && auto_block
  fi
  if has "$1" "run\\.sh[\"']?[[:space:]]+[\"']?(turn|guard|post-check|session-start)([\"'[:space:];&|)]|$)" \
    || has "$1" "${S}(sudo[[:space:]]+)?(bash|sh|zsh|dash|source|exec)[[:space:]]+(-[^[:space:]]+[[:space:]]+)*[\"']?[^[:space:]\"';&|]*[/\\\\]hooks[/\\\\](turn|guard|post-check|session-start)\\.sh([\"'[:space:];&|)]|$)" \
    || has "$1" "(^|[;&|({\`])[[:space:]]*(sudo[[:space:]]+)?\\.[[:space:]]+[\"']?[^[:space:]\"';&|]*[/\\\\]hooks[/\\\\](turn|guard|post-check|session-start)\\.sh([\"'[:space:];&|)]|$)" \
    || has "$1" "(^|[;&|(])[[:space:]]*[\"']?[^[:space:]\"';&|]*[/\\\\]hooks[/\\\\](turn|guard|post-check|session-start)\\.sh([\"'[:space:];&|)]|$)" \
    || has "$1" '--from-hook'; then
    block "$MSG_HOOK_EXEC" "$MSG_APPROVE"
  fi
  return 0
}
# 가지 강제 삭제가 보이는가 → 0. git branch 명령(; & | 앞까지) 안에 옵션 묶음 속 D(-D·-vD), 또는 삭제(-d·--delete 와 그 줄임 --d…)와
#   강제(-f·--force 와 그 줄임 --f…)가 함께(-df·-fd·-d -f·--delete -q --force·--dele --forc). 옵션 글자는 대소문자를 가린다(-d 와 -D).
#   낱말 앞뒤의 따옴표·괄호·백틱은 떼고 본다(bash -c 'git branch -df x')
br_force_del() {
  local rest=$1 seg w o del force IFS=$' \t' re_gb='git[[:space:]]+branch([^;&|]*)'
  while [[ $rest =~ $re_gb ]]; do
    seg=${BASH_REMATCH[1]}; rest=${rest#*"${BASH_REMATCH[0]}"}
    del=0; force=0
    shopt -u nocasematch
    set -f
    for w in $seg; do
      while :; do case "$w" in [\"\'\(\`]*) w=${w#?} ;; *) break ;; esac; done
      while :; do case "$w" in *[\"\'\)\`]) w=${w%?} ;; *) break ;; esac; done
      case "$w" in
        --?*) o=${w#--}; o=${o%%=*}
              [ -n "$o" ] && { case delete in "$o"*) del=1 ;; esac; case force in "$o"*) force=1 ;; esac; } ;;
        -?*) o=${w#-}
             case "$o" in *D*) del=1; force=1 ;; esac
             case "$o" in *d*) del=1 ;; esac
             case "$o" in *f*) force=1 ;; esac ;;
      esac
    done
    set +f
    shopt -s nocasematch
    [ "$del" = 1 ] && [ "$force" = 1 ] && return 0
  done
  return 1
}
# 0.3.2: 다른 가지·커밋으로 옮기는 git switch / git checkout / gh pr checkout 이 보이는가 → 0. 리팩토링 중에만 부른다(check_shell 의 refactor_on 구역).
#   통과: 지금 위치에서 새 가지 만들기(switch -c/--create · checkout -b — 시작점 없음·HEAD·@) · checkout --orphan <새>(시작점 없음) ·
#   인자 없는 --detach/-d · checkout 경로 모드(-- 뒤 낱말이 있을 때 · -p · 비옵션 2개 이상 · 작업 폴더 기준으로 디스크에 있는 이름 하나) ·
#   switch/checkout <지금 가지>(.git/HEAD 와 같을 때).
#   막음: 그 밖의 가지·커밋·태그·-·@{-N}·변수·명령 치환 · switch --orphan · -t/--track · 시작점을 준 만들기 ·
#   강제 만들기(-C·-B·--force-create — 있는 가지를 덮고 옮긴다) · `git checkout <가지> --`(-- 뒤가 비면 가지 이동).
#   명령 이름(git·switch·checkout·gh pr)은 대소문자를 가리지 않고, 옵션 글자만 가린다(-c 와 -C — br_force_del 처럼 nocasematch 를 끈다).
#   옵션 줄임(--det)·묶음(-qc)·= 꼴을 본다. git 은 부르지 않는다
br_switch() {
  has "$1" 'gh[[:space:]]+pr[[:space:]]+checkout([[:space:]]|$)' && return 0
  local r
  shopt -u nocasematch; set -f
  br_switch_in "$1"; r=$?
  set +f; shopt -s nocasematch
  return $r
}
br_switch_in() {
  local rest=$1 sub seg w raw o v k c n pos dyn create fcreate detach orphan track pathm dd paths wantarg skipn IFS=$' \t\n'
  local re_sw="[Gg][Ii][Tt][[:space:]]+([Ss][Ww][Ii][Tt][Cc][Hh]|[Cc][Hh][Ee][Cc][Kk][Oo][Uu][Tt])(([[:space:]][^;&|${NL}]*)?)"
  while [[ $rest =~ $re_sw ]]; do
    sub=${BASH_REMATCH[1]}; seg=${BASH_REMATCH[2]}; rest=${rest#*"${BASH_REMATCH[0]}"}
    case "$sub" in [Ss][Ww]*) sub=switch ;; *) sub=checkout ;; esac
    create=0; fcreate=0; detach=0; orphan=0; track=0; pathm=0; dd=0; paths=0; wantarg=0; skipn=0; n=0; pos=""; dyn=0
    for w in $seg; do
      raw=$w
      case "$raw" in '#'*) break ;; esac   # 따옴표 없는 # 로 시작하는 낱말부터는 주석(bash·PowerShell) — 인자로 세지 않는다
      while :; do case "$w" in [\"\'\(\`]*) w=${w#?} ;; *) break ;; esac; done
      while :; do case "$w" in *[\"\'\)\`]) w=${w%?} ;; *) break ;; esac; done
      [ -n "$w" ] || continue
      [ "$skipn" = 1 ] && { skipn=0; continue; }
      case "$w" in *'>'*|'<'*) case "$w" in *'>'|'<') skipn=1 ;; esac; continue ;; esac   # 리다이렉트(> 파일)는 인자가 아니다
      [ "$wantarg" = 1 ] && { wantarg=0; continue; }   # -c <새 가지> · --orphan <새 가지> 의 이름
      [ "$dd" = 1 ] && { paths=1; break; }   # checkout … -- <파일>: 경로가 하나라도 있어야 파일 되돌리기
      [ "$pathm" = 1 ] && break
      case "$w" in
        --) [ "$sub" = checkout ] && dd=1 ;;
        --?*) o=${w#--}; v=""; case "$o" in *=*) v=1; o=${o%%=*} ;; esac
              k=""
              case "$o" in
                force|discard-changes|merge|quiet|progress|no-progress|guess|no-guess|no-track|recurse-submodules|no-recurse-submodules|ignore-other-worktrees|overwrite-ignore|no-overwrite-ignore|ours|theirs|overlay|no-overlay|ignore-skip-worktree-bits|pathspec-file-nul) ;;
                conflict) [ -z "$v" ] && wantarg=1 ;;
                patch|pathspec-from-file) [ "$sub" = checkout ] && pathm=1 ;;
                *) case detach in "$o"*) k=detach ;; esac; case track in "$o"*) k=track ;; esac
                   case create in "$o"*) k=create ;; esac; case force-create in "$o"*) k=fcreate ;; esac
                   case orphan in "$o"*) k=orphan ;; esac ;;
              esac
              case "$k" in
                create) create=1; [ -z "$v" ] && wantarg=1 ;;
                fcreate) fcreate=1 ;;
                orphan) orphan=1; [ -z "$v" ] && wantarg=1 ;;
                detach) detach=1 ;;
                track) track=1 ;;
              esac ;;
        -?*) o=${w#-}
             while [ -n "$o" ]; do
               c=${o:0:1}; o=${o:1}
               case "$sub$c" in
                 switchc|checkoutb) create=1; [ -z "$o" ] && wantarg=1; o="" ;;   # -cnew 꼴은 남은 글자가 이름
                 switchC|checkoutB) fcreate=1; o="" ;;
                 *d) detach=1 ;;
                 *t) track=1 ;;
                 checkoutp) pathm=1 ;;
               esac
             done ;;
        *) n=$((n + 1)); pos=$w; case "$raw" in *[\$\`]*) dyn=1 ;; esac ;;   # 변수·명령 치환($( ) · ` `)은 무엇이 될지 모른다
      esac
    done
    [ "$fcreate" = 1 ] && return 0   # 강제 만들기는 있는 가지를 지금 위치로 덮고 옮긴다
    [ "$sub" = checkout ] && { [ "$pathm" = 1 ] || [ "$paths" = 1 ]; } && continue   # 파일 되돌리기(-- <파일> · -p): 가지는 그대로
    [ "$track" = 1 ] && return 0
    if [ "$create" = 1 ]; then
      [ "$n" = 0 ] && continue
      [ "$n" = 1 ] && { [ "$pos" = HEAD ] || [ "$pos" = @ ]; } && continue
      return 0
    fi
    if [ "$orphan" = 1 ]; then
      [ "$sub" = checkout ] && [ "$n" = 0 ] && continue   # switch --orphan 은 추적 파일을 모두 지운다
      return 0
    fi
    if [ "$detach" = 1 ]; then [ "$n" = 0 ] && continue; return 0; fi
    [ "$n" = 0 ] && continue
    [ "$n" = 1 ] && [ "$dyn" = 0 ] && br_cur_branch && [ "$pos" = "$CURB" ] && continue   # 지금 가지(아무 일 없음)
    if [ "$sub" = checkout ]; then
      [ "$n" -ge 2 ] && [ "$dyn" = 0 ] && continue   # <가지> <파일…> 또는 파일 여럿: 경로 모드(변수·명령 치환이 끼면 막음)
      [ "$dyn" = 1 ] && return 0
      case "$pos" in -|@\{*) return 0 ;; esac
      # git 은 이름을 작업 폴더 기준으로 푼다 — 프로젝트 기준으로 보면 하위 폴더에서 친 '루트 폴더 이름과 같은 가지'가 통과한다
      case "$pos" in
        /*|[A-Za-z]:*) [ -e "$pos" ] && continue ;;
        *) [ -e "${cwd:-$proj}/$pos" ] && continue ;;
      esac
      return 0
    fi
    return 0
  done
  return 1
}
# 프로젝트의 지금 가지 이름 → CURB. .git 이 파일(gitdir: …)이면 그 폴더의 HEAD. 분리 HEAD·못 읽음 → 1
br_cur_branch() {
  local g="$proj/.git" l=""
  if [ -f "$g" ]; then
    IFS= read -r l < "$g" || [ -n "$l" ] || return 1
    l=${l%$'\r'}
    case "$l" in "gitdir: "*) g=${l#gitdir: } ;; *) return 1 ;; esac
    case "$g" in /*|[A-Za-z]:*) ;; *) g="$proj/$g" ;; esac
  fi
  [ -f "$g/HEAD" ] || return 1
  l=""; IFS= read -r l < "$g/HEAD" || [ -n "$l" ] || return 1
  l=${l%$'\r'}
  case "$l" in "ref: refs/heads/"?*) CURB=${l#ref: refs/heads/} ;; *) return 1 ;; esac
}
# 가지 이름·경로 낱말 하나 → BW(따옴표 벗긴 값). 판정할 수 없는 글자가 있으면 1:
#   $ ` * ? [ { ; & | < > 따옴표 · 맨 앞의 ~ 와 =~ · :~(bash 가 홈 폴더로 바꿈 — 그 밖의 가운데 ~ 는 Windows 짧은 이름 RUNNER~1 꼴이라 허용) ·
#   따옴표 없는 \ ( ) # · Windows 가 아닐 때의 \ · 큰따옴표 안의 \\ (셸이 바꿔 읽음) · 빈 값
br_word() {
  local w=$1 q=""
  case "$w" in \"*\") w=${w:1:${#w}-2}; q=d ;; \'*\') w=${w:1:${#w}-2}; q=s ;; esac
  [ -n "$w" ] || return 1
  case "$w" in \~*|*=\~*|*:\~*|*[\$\`\*\?\[\{\;\&\|\<\>\"\']*) return 1 ;; esac
  case "$w" in *"$BS"*) { [ "$WINPATH" = 1 ] && [ -n "$q" ]; } || return 1 ;; esac
  case "$q" in
    "") case "$w" in *[\(\)\#]*) return 1 ;; esac ;;
    d) case "$w" in *"$BS$BS"*) return 1 ;; esac ;;
  esac
  BW=$w
}
# 가지 강제 삭제의 허용 판정(check_shell 한 번에 한 번) → BRV=ok(허용) 또는 no + BRM1·BRM2(막을 때의 문구).
#   허용 = Bash 도구의 맨 위 명령(BRTOP=1)이 정확히 [cd <경로> && ]git [-C <경로> ]branch <강제 삭제 옵션들> <가지 1~10개> 이고(원래 명령 cmd0 로 본다),
#   그 저장소에서 가지마다: 기본 가지(origin 원격이 있으면 origin/HEAD(refs/remotes/origin/ 아래일 때만) → origin/main → origin/master,
#   없으면 로컬 main → master. 기준으로 쓰려는 origin 참조가 그 자체로 심볼릭이면 건너뜀)의 조상이거나, merge-tree --write-tree 결과가
#   기본 가지 트리와 같음(스쿼시 합침). 하나라도 아니면 통째로 막는다. 저장소 위치는 도구 입력의 작업 폴더(cwd) 기준 — cwd 가 없거나,
#   cd 경로가 절대경로·./ 꼴이 아니거나(CDPATH), 경로에 .. 조각이 있으면(링크를 따라 올라감) 판정하지 않는다.
#   합치기 드라이버(merge.<이름>.driver) 설정이 있으면 조상이 아닌 가지는 merge-tree 를 부르지 않고 막는다.
#   git 호출(모두 replace 참조 무시): 저장소마다 2번(참조 목록·origin/드라이버 설정) + 조상 목록 1번 + 조상이 아닌 가지마다 merge-tree 1번.
#   판정 15초 넘으면 막음
br_judge() {
  shopt -u nocasematch
  br_judge_in
  shopt -s nocasematch
}
# 판정 불가 첫 줄 — 이유 낱말을 괄호 안과 끝의 기록 칸에 같이 둔다(문제 기록은 첫 ( ~ 마지막 ) 를 <파일> 로 가리므로 기록 칸은 괄호 밖·괄호 없이)
br_cant() { BRM1="가지 삭제를 판정할 수 없어 막았습니다($1). [가지 삭제 · $1]"; }
# 참조 목록($out, 줄 꼴 "<참조> <커밋> <트리> <가리키는 참조>")에서 $1 의 줄 → BR_O(커밋)·BR_T(트리)·BR_S(심볼릭이면 가리키는 참조, 아니면 빈 값). 없으면 1
br_ref() {
  local l
  case "$out" in *"${NL}$1 "*) ;; *) return 1 ;; esac
  l=${out#*"${NL}$1 "}; l=${l%%"$NL"*}
  BR_O=${l%% *}; l=${l#* }; BR_T=${l%% *}; BR_S=${l#* }
  [ "$BR_S" = "$BR_T" ] && BR_S=""
  return 0
}
br_judge_in() {
  BRV=no
  local why="한 줄 삭제 명령이 아님" s=${cmd0:-} rest k=0 i=0 cdp="" cp="" w o del=0 force=0 names="" pats="" n nn=0 loc out out2 rc
  local bref="" boid="" btree="" bshort="" bname="" origin=0 drv=0 noid anc bad="" bad1="" t0=$SECONDS IFS=$' \t'
  local re_tok="^(\"[^\"]*\"|'[^']*'|[^[:space:]\"']+)([[:space:]]+|$)"
  local -a T
  BRM2="지울 가지 이름을 그대로 적어 git branch -D <가지> 한 줄로 실행하세요(2>&1·파이프 같은 덧붙임 없이, 다른 저장소면 git -C <절대경로> 하나만)."
  case "$s" in *'$'*|*'`'*) why="이름이 변수·명령 결과" ;; esac
  br_cant "$why"
  [ "${BRTOP:-0}" = 1 ] && [ "$why" = "한 줄 삭제 명령이 아님" ] && [ "${#s}" -le 2048 ] || return 0
  # 줄바꿈·CR 이 남아 있으면 판정하지 않는다(낱말 나누기가 공백처럼 다뤄 다음 줄을 가지 이름으로 읽지 않게)
  case "$s" in *"$NL"*|*$'\r'*) return 0 ;; esac
  # JSON 의 \u 이스케이프는 풀지 않으므로(unesc_short) 그런 명령은 판정하지 않는다
  rest=${rawcmd:-}; rest=${rest//"$P_BS2"/}; case "$rest" in *"$BS"u*) return 0 ;; esac
  # 낱말로 나누기(따옴표 하나로 감싼 낱말 또는 따옴표 없는 낱말, 사이는 공백). 그 밖의 꼴은 판정하지 않는다
  while :; do case "$s" in [[:space:]]*) s=${s#?} ;; *) break ;; esac; done
  while :; do case "$s" in *[[:space:]]) s=${s%?} ;; *) break ;; esac; done
  while [ -n "$s" ]; do
    [[ $s =~ $re_tok ]] || return 0
    T[k]=${BASH_REMATCH[1]}; k=$((k + 1)); s=${s:${#BASH_REMATCH[0]}}
    [ "$k" -gt 40 ] && return 0
  done
  if [ "${T[0]:-}" = cd ]; then
    [ "$k" -gt 3 ] && br_word "${T[1]}" && [ "${T[2]}" = "&&" ] || return 0
    case "$BW" in -*) return 0 ;; esac
    cdp=$BW; i=3
  fi
  [ "${T[i]:-}" = git ] || return 0; i=$((i + 1))
  if [ "${T[i]:-}" = -C ]; then
    br_word "${T[i+1]:-}" || return 0
    case "$BW" in -*) return 0 ;; esac
    cp=$BW; i=$((i + 2))
  fi
  [ "${T[i]:-}" = branch ] || return 0; i=$((i + 1))
  # 옵션: 강제 삭제에 쓰는 것만(-d -D -f -q 묶음 · --delete --force --quiet 와 그 줄임)
  while [ "$i" -lt "$k" ]; do
    w=${T[i]}
    case "$w" in
      --?*) o=${w#--}
            case "$o" in *[!a-z]*) return 0 ;; esac
            case delete in "$o"*) del=1; i=$((i + 1)); continue ;; esac
            case force in "$o"*) force=1; i=$((i + 1)); continue ;; esac
            case quiet in "$o"*) i=$((i + 1)); continue ;; esac
            return 0 ;;
      -?*) o=${w#-}
           case "$o" in *[!dDfq]*) return 0 ;; esac
           case "$o" in *D*) del=1; force=1 ;; esac
           case "$o" in *d*) del=1 ;; esac
           case "$o" in *f*) force=1 ;; esac
           i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  [ "$del" = 1 ] && [ "$force" = 1 ] || return 0
  # 가지 이름(1~10개, - 로 시작하지 않음)
  while [ "$i" -lt "$k" ]; do
    br_word "${T[i]}" || return 0
    case "$BW" in -*|*[[:space:]]*) return 0 ;; esac
    names="$names $BW"; pats="$pats refs/heads/$BW"; nn=$((nn + 1)); i=$((i + 1))
  done
  [ "$nn" -ge 1 ] || return 0
  [ "$nn" -gt 10 ] && { br_cant "가지가 10개 넘음"; return 0; }
  for n in $names; do
    case "$n" in main|master) br_cant "기본 가지 자신"; return 0 ;; esac
  done
  # 저장소 위치: -C 경로, 아니면 cd 경로, 아니면 도구 입력의 작업 폴더(상대경로는 그 앞 기준)
  br_cant "저장소 위치를 알 수 없음"
  [ -n "${BRCWD:-}" ] || return 0
  # cd 경로는 절대경로이거나 . ./ 로 시작할 때만 — 그 밖의 상대경로는 셸의 CDPATH 에 따라 다른 폴더로 갈 수 있다
  if [ -n "$cdp" ]; then
    case "$cdp" in /*|[A-Za-z]:/*|[A-Za-z]:"$BS"*|.|./*) ;; *) return 0 ;; esac
  fi
  # 경로 조각이 정확히 .. 이면 판정하지 않는다 — guard 는 글자로 정리하지만 셸·git 은 링크를 따라간 실제 폴더에서 올라간다
  for o in "$cdp" "$cp"; do
    o=${o//"$BS"/$SL}
    case "/$o/" in */../*) return 0 ;; esac
  done
  loc=$BRCWD
  [ -n "$cdp" ] && { normpath "$cdp" "$loc"; loc=$NP; }
  [ -n "$cp" ] && { normpath "$cp" "$loc"; loc=$NP; }
  [ -d "$loc" ] || return 0
  # 1) 참조 목록(기본 가지 후보 + 지울 가지들) — 저장소가 아니면 여기서 끝
  set -f
  out=$(git --no-replace-objects -c core.fsmonitor=false -C "$loc" for-each-ref --format='%(refname) %(objectname) %(tree) %(symref)' \
        refs/remotes/origin/HEAD refs/remotes/origin/main refs/remotes/origin/master refs/heads/main refs/heads/master $pats 2>&1); rc=$?
  set +f
  if [ "$rc" != 0 ]; then
    case "$out" in *"not a git repository"*) ;; *) br_cant "git 오류" ;; esac
    return 0
  fi
  out="$NL$out$NL"
  # 2) origin 원격·합치기 드라이버 설정(지역·전역·시스템, 이름만): 0 하나라도 있음 · 1 둘 다 없음 · 그 밖 = 오류
  out2=$(git --no-replace-objects -c core.fsmonitor=false -C "$loc" config --name-only --get-regexp '^(remote[.]origin[.]|merge[.].+[.]driver$)' 2>/dev/null); rc=$?
  br_cant "git 오류"
  case "$rc" in 0) ;; 1) out2="" ;; *) return 0 ;; esac
  case "$NL$out2" in *"${NL}remote.origin."*) origin=1 ;; esac
  case "$NL$out2" in *"${NL}merge."*) drv=1 ;; esac
  br_cant "시간 초과"
  [ $((SECONDS - t0)) -gt 15 ] && return 0
  # 기본 가지
  if [ "$origin" = 1 ]; then
    # origin/HEAD 의 %(symref) 는 심볼릭을 끝까지 따라간 대상이다(origin/HEAD → origin/develop → refs/heads/x 면 refs/heads/x) —
    #   그 대상이 origin 아래가 아니면 기준으로 쓰지 않는다. 그래서 대상 자체가 심볼릭인 경우는 따로 볼 필요가 없다(git 호출을 늘리지 않음)
    if br_ref refs/remotes/origin/HEAD; then
      case "$BR_S" in refs/remotes/origin/HEAD) ;; refs/remotes/origin/?*) bref=$BR_S; boid=$BR_O; btree=$BR_T ;; esac
    fi
    for o in main master; do
      [ -n "$bref" ] && break
      br_ref refs/remotes/origin/$o || continue
      [ -n "$BR_S" ] && continue                      # 그 자체로 심볼릭(git symbolic-ref refs/remotes/origin/main refs/heads/x) — 기준이 아니다
      bref=refs/remotes/origin/$o; boid=$BR_O; btree=$BR_T
    done
    bshort=${bref#refs/remotes/}; bname=${bref#refs/remotes/origin/}
  else
    for o in main master; do
      [ -n "$bref" ] && break
      br_ref refs/heads/$o || continue
      [ -n "$BR_S" ] && continue                      # 그 자체로 심볼릭(git symbolic-ref refs/heads/main refs/heads/x) — 기준이 아니다
      bref=refs/heads/$o; boid=$BR_O; btree=$BR_T
    done
    bshort=${bref#refs/heads/}; bname=$bshort
  fi
  br_cant "기본 가지를 못 찾음"
  [ -n "$bref" ] && [ -n "$boid" ] && [ -n "$btree" ] || return 0
  for n in $names; do
    [ "$n" = "$bname" ] && { br_cant "기본 가지 자신"; return 0; }
    case "$out" in *"${NL}refs/heads/$n "*) ;; *) br_cant "가지 없음"; return 0 ;; esac
  done
  # 3) 기본 가지의 조상인 가지(보통 합침) 목록
  set -f
  anc=$(git --no-replace-objects -c core.fsmonitor=false -C "$loc" for-each-ref --merged="$boid" --format='%(refname)' $pats 2>/dev/null); rc=$?
  set +f
  br_cant "git 오류"
  [ "$rc" = 0 ] || return 0
  anc="$NL$anc$NL"
  # 4) 조상이 아닌 가지: merge-tree 결과 트리 == 기본 가지 트리(스쿼시 합침). 합치기 드라이버 설정이 있으면 merge-tree 를 부르지 않는다
  #    (드라이버 프로그램이 이 안에서 실행되고, 늘 "우리 쪽"을 남기는 드라이버면 안 합친 가지도 합친 것처럼 보인다)
  for n in $names; do
    case "$anc" in *"${NL}refs/heads/$n$NL"*) continue ;; esac
    [ "$drv" = 1 ] && { bad="$bad $n"; continue; }
    br_cant "시간 초과"
    [ $((SECONDS - t0)) -gt 15 ] && return 0
    noid=${out#*"${NL}refs/heads/$n "}; noid=${noid%% *}
    out2=$(git --no-replace-objects -c core.fsmonitor=false -c merge.renormalize=false -C "$loc" merge-tree --write-tree "$boid" "$noid" 2>&1); rc=$?
    case "$rc" in
      0) [ "${out2%%"$NL"*}" = "$btree" ] && continue ;;
      1) ;;
      # 2.38 미만: --write-tree 가 없다(사용법 오류 129, 또는 옛 꼴이 --write-tree 를 커밋 이름으로 읽어 실패 — 추정)
      129) br_cant "git 2.38 미만"; return 0 ;;
      *) br_cant "git 오류"
         case "$out2" in *--write-tree*) br_cant "git 2.38 미만" ;; esac; return 0 ;;
    esac
    [ -z "$bad1" ] && bad1=$n
    bad="$bad $n"
  done
  if [ "$drv" = 1 ] && [ -n "$bad" ]; then
    br_cant "합치기 드라이버 설정"
    BRM2="이 저장소에는 합칠 때 쓰는 프로그램 설정이 있어 스쿼시 합침을 확인할 수 없습니다. 사용자에게 git branch -D${bad} 명령을 드려 직접 실행하게 하세요."
    return 0
  fi
  br_cant "시간 초과"
  [ $((SECONDS - t0)) -gt 15 ] && return 0
  if [ -n "$bad" ]; then
    BRM1="합치지 않은 가지는 지우지 않습니다($bad1: 기본 가지 $bshort 에 없는 내용이 있음). [가지 삭제 · 안 합쳐짐]"
    BRM2="사람이 직접 결정합니다. 사용자에게 git branch -D${bad} 명령을 드려 직접 실행하게 하세요. 방금 GitHub 에서 합쳤다면 git fetch origin 을 먼저 실행한 뒤 다시 시도하세요."
    return 0
  fi
  BRV=ok
}
# 고가치 규칙(되돌릴 수 없는 git 명령). 끝 경계에 따옴표·괄호도 넣는다(bash -c 'git reset --hard' · (git push -f))
hv_git() {
  local t=$1
  has "$t" "git[[:space:]]+reset[^;&|]*[[:space:]]--h(a(r(d)?)?)?([[:space:]=;&|)\"']|$)" && block "git reset --hard 는 저장 안 된 작업을 지웁니다." "되돌릴 곳이 있으면 그 줄만 직접 원래대로 고치세요. 전체 되돌리기는 사람이 결정합니다."
  if has "$t" "git[[:space:]]+clean[^;&|]*[[:space:]](-[a-z]*f|--f(o(r(c(e)?)?)?)?([[:space:]\"')]|$))" && ! has "$t" 'git[[:space:]]+clean[^;&|]*[[:space:]](-[a-z]*n[a-z]*|--d(r(y(-(r(u(n)?)?)?)?)?)?)([[:space:]]|$)'; then
    block "git clean -f 는 git에 없는 파일을 영구 삭제합니다." "지울 목록만 보려면 git clean -n (사람이 확인 후 직접 실행)."
  fi
  if has "$t" "git[[:space:]]+(checkout|restore)[^;&|]*[[:space:]][\"']?(\\.|\\./|\\./\\*|:/|:/\\*|:\\(top\\)|\\*|\\*\\*)[\"']?([[:space:]]|$|[;&|)])"; then
    if ! has "$t" 'git[[:space:]]+restore[^;&|]*--staged' || has "$t" 'git[[:space:]]+restore[^;&|]*(--worktree|[[:space:]]-w([[:space:]]|$))'; then
      block "git checkout . / git restore . 는 모든 파일의 변경을 한꺼번에 지웁니다." "되돌릴 때는 이번에 바꾼 파일 이름을 하나씩 지정하세요(git restore <파일>)."
    fi
  fi
  has "$t" "git[[:space:]]+(checkout|switch)[^;&|]*[[:space:]](-f|--force|--discard-changes)([[:space:]\"')]|$)" && block "강제 checkout/switch 는 저장 안 된 변경을 버립니다." "먼저 git status를 사람에게 보여 주세요."
  has "$t" 'git[[:space:]]+stash[[:space:]]+(drop|clear)' && block "git stash drop/clear 는 보관된 작업을 영구 삭제합니다." "사람이 직접 결정합니다."
  if has "$t" "git[[:space:]]+push[^;&|]*([[:space:]](--force[^[:space:]\"')]*|--mirror|--delete|-d)([[:space:]\"')]|$)|[[:space:]]-[a-z]*f[a-z]*([[:space:]\"')]|$)|[[:space:]]\\+[^[:space:]]+|[[:space:]]:[^[:space:]]+)"; then
    block "강제 push·원격 브랜치 삭제는 원격 저장소의 기록을 덮어씁니다." "push는 사람이 직접 합니다."
  fi
  # 가지 강제 삭제(모든 철자): 판정은 check_shell 한 번에 한 번만(br_judge — 4벌 판정 문자열 어느 쪽에서 보여도 같은 결론)
  if br_force_del "$t"; then
    [ -z "${BRV:-}" ] && br_judge
    [ "$BRV" = ok ] || block "$BRM1" "$BRM2"
  fi
  has "$t" 'git[[:space:]]+(filter-branch|filter-repo|update-ref[[:space:]]+-d)|git[[:space:]]+reflog[[:space:]]+(expire|delete)|git[[:space:]]+gc[^;&|]*--prune=now' && block "git 기록을 다시 쓰거나 지우는 명령입니다." "사람이 직접 결정합니다."
  # 원격 추적 참조(refs/remotes/…)를 직접 쓰는 update-ref — 가지 삭제의 기준(origin/main 등)을 지울 가지 쪽으로 옮기는 길
  #   (첫 인자 = 바꿀 참조. -m <메시지> 는 값을 건너뛴다. git update-ref refs/heads/x refs/remotes/origin/main 처럼 값으로만 쓰는 것은 통과).
  #   --stdin 은 바꿀 참조를 명령 밖(파이프·파일)에서 받아 판정할 수 없으므로 늘 막는다
  if has "$t" "git[[:space:]]+update-ref([[:space:]]+(-m[[:space:]]*(\"[^\"]*\"|'[^']*'|[^[:space:]]+)|-[^[:space:]]+))*[[:space:]]+[\"']?refs/remotes/" \
    || has "$t" "git[[:space:]]+update-ref[^;&|]*[[:space:]]--stdin([[:space:]\"')]|$)"; then
    block "git 기록을 다시 쓰거나 지우는 명령입니다." "사람이 직접 결정합니다."
  fi
  # 원격 가지·저장소 삭제: gh api 의 DELETE 요청이 …/git/refs/(가지·태그) 나 repos/<주인>/<저장소>(저장소 통째)를 겨냥 · gh repo delete
  local gseg grest=$t re_gha="gh[[:space:]]+api([[:space:]][^;&|]*)?"
  while [[ $grest =~ $re_gha ]]; do
    gseg=${BASH_REMATCH[0]}; grest=${grest#*"$gseg"}
    case "$gseg" in *%*) pct_dec "$gseg"; gseg=$PD ;; esac   # 0.4.0 보완: git/re%66s 같은 %XX 철자
    # 0.3.7 G2: -H 'X-HTTP-Method-Override: DELETE' 도 DELETE 와 같게
    if { has "$gseg" "[[:space:]](-X[[:space:]]*|--method([[:space:]]+|=))[\"']?delete([\"'[:space:])]|$)" \
        || { [[ $gseg =~ $RE_HMO ]] && has "$gseg" "x-http-method-override[[:space:]]*:[[:space:]]*[\"']?delete([\"'[:space:])]|$)"; }; } \
      && has "$gseg" "/git/refs/|[[:space:]][\"']?/?repos/[^/[:space:]\"']+/[^/[:space:]\"']+/?([\"'[:space:])]|$)"; then
      block "$MSG_GHDEL" "사용자에게 명령을 안내하고 사람이 직접 실행하게 하세요."
    fi
  done
  has "$t" "gh[[:space:]]+repo[[:space:]]+delete([[:space:]\"')]|$)" && block "$MSG_GHDEL" "사용자에게 명령을 안내하고 사람이 직접 실행하게 하세요."
  # 0.3.7 G4: 리팩토링 중에는 저장소 설정 바꾸기(gh repo rename·archive · edit --default-branch·--visibility · sync --force) — 설명·홈페이지·주제 고치기와 조회는 통과
  if [ "$refactor_on" = 1 ] && [ "${AGENT_MODE:-0}" != 1 ]; then
    if has "$t" "gh([.]exe)?[[:space:]]+repo[[:space:]]+(rename|archive)([^A-Za-z0-9_-]|$)" \
      || has "$t" "gh([.]exe)?[[:space:]]+repo[[:space:]]+edit([[:space:]][^;&|]*)?[[:space:]][\"']?(--default-branch|--visibility)([[:space:]=\"')]|$)" \
      || has "$t" "gh([.]exe)?[[:space:]]+repo[[:space:]]+sync([[:space:]][^;&|]*)?[[:space:]][\"']?--force([[:space:]=\"')]|$)"; then
      block "$MSG_REPOSET" "$MSG_REPOSET2"
    fi
  fi
  return 0
}
MSG_GHDEL="원격 가지·저장소 삭제는 사람이 직접 합니다(gh api DELETE 도 같습니다)."
# 0.3.7 G2: gh api 의 -H/--header 값 X-HTTP-Method-Override: <방식>(따옴표·= 붙임·-iH 묶음 · 대소문자 무시) — BASH_REMATCH[4] = 방식 값
RE_HMO="[[:space:]][\"']?(-i*h|--header)([[:space:]]+|=)?[\"']?x-http-method-override[[:space:]]*:[[:space:]]*([\"']?)([^[:space:]\"';&|)]*)"
# 0.3.7 G3·G4: 저장소 설정(기본 가지·이름·보관·공개 여부·가지 보호·강제 동기화·가지 이름 바꾸기)
MSG_REPOSET="리팩토링 중에는 저장소 설정(기본 가지·이름·공개 여부·가지 보호·강제 동기화)을 바꾸지 않습니다 — 끝난 뒤 사람이 GitHub 화면에서 하세요."
MSG_REPOSET2="읽기(gh repo view · gh api repos/<주인>/<저장소>)는 됩니다. 꼭 지금 바꿔야 하면 멈추고 사람에게 부탁하세요."
MSG_GHW="리팩토링 진행 중에는 GitHub API 로 가지·파일을 직접 쓰지 않습니다(PR 없이 합치는 길)."
MSG_GHW2="PR 합치기는 사용자에게 /refactor:approve 합치기 를 입력해 달라고 하세요. 가지·파일 변경은 git 커밋과 /refactor:approve 푸시 로 합니다."
# 0.4.0 보완(검사 A#9): gh api 조각의 %XX 중 영문·숫자·/ - _ . 를 풀어 판정한다(deploy%6Dents = deployments) → PD. 그 밖의 %XX 는 그대로
pct_dec() {
  local s=$1 out="" h c m re='%([0-9A-Fa-f]{2})'
  while [[ $s =~ $re ]]; do
    m=${BASH_REMATCH[0]}; h=${BASH_REMATCH[1]}
    out=$out${s%%"$m"*}; s=${s#*"$m"}
    printf -v c "\\x$h"
    case "$c" in [A-Za-z0-9/_.-]) out=$out$c ;; *) out=$out%$h ;; esac
  done
  PD=$out$s
}
# 0.3.5 F16: gh api 조각($1)이 읽기가 아닌 요청인가(0 = 쓰기). gh 공식 문서: 방식을 주지 않으면 GET, 필드(-f·-F·--field·--raw-field)가 있으면 POST ·
#   --method GET 이면 필드는 질의 문자열. 그래서 -X·--method 값이 하나라도 GET 이 아니면(변수·따옴표로 쪼갠 값 포함) 쓰기 · 방식 값이 모두 GET 이면 읽기 ·
#   방식이 없으면 필드나 --input 이 있을 때 쓰기. 짧은 옵션 묶음은 gh api 의 켜기 옵션 -i 하나뿐이라 -iX·-if 까지 본다
gha_write() {
  local s=$1 m any=0 re_m="[[:space:]][\"']?(-i*x[[:space:]]*=?|--method([[:space:]]+|=))[\"']?([^[:space:]\"';&|)]*)"
  # 0.3.7 G2: -H/--header 의 X-HTTP-Method-Override 값이 GET 이 아니면(빈 값·변수 포함) 쓰기 — 방식 옵션이 GET 이어도
  while [[ $s =~ $RE_HMO ]]; do
    m=${BASH_REMATCH[4]}; s=${s#*"${BASH_REMATCH[0]}"}
    case "$m" in [Gg][Ee][Tt]) ;; *) return 0 ;; esac
  done
  s=$1
  while [[ $s =~ $re_m ]]; do
    any=1; m=${BASH_REMATCH[3]}; s=${s#*"${BASH_REMATCH[0]}"}
    case "$m" in [Gg][Ee][Tt]) ;; *) return 0 ;; esac
  done
  [ "$any" = 1 ] && return 1
  has "$1" "[[:space:]][\"']?(-i*f|--field|--raw-field|--input)"
}
# $1 = 'gh api' 로 시작하는 글자 → GS = 따옴표(' ") 밖의 ; & | 줄바꿈 앞까지(따옴표가 닫히지 않으면 끝까지). 따옴표 묶음 단위로 건너뛴다
gha_scan() {
  local r=$1 p c q
  GS=""
  while :; do
    p=${r%%[\"\';\&\|$NL]*}; GS=$GS$p; r=${r#"$p"}
    c=${r:0:1}
    case "$c" in
      \"|\') r=${r:1}; q=${r%%"$c"*}; GS=$GS$c$q; [ "$q" = "$r" ] && return 0; GS=$GS$c; r=${r#"$q$c"} ;;
      *) return 0 ;;
    esac
  done
}
# 고가치 규칙(대량 삭제·기록 폴더 삭제) — hv_git 처럼 lq·lz·hv·hvz 사본마다 부른다(eval "rm -rf doc"'s/refactor').
#   $2 = 1 이면 빈 변수를 지운 사본(hv·hvz): 머리의 $DIR 을 지우면 없던 / · . 가 생기므로(rm -rf $OUT/* → rm -rf /*)
#   큰 폴더 판정은 하지 않고 기록 폴더(docs/refactor)·--no-preserve-root 만 본다
hv_del() {
  local t=$1 vm=${2:-0} rest seg
  local re_rm="${S}(sudo[[:space:]]+)?rm[[:space:]][^;&|]*"
  local re_rm_target="[[:space:]][\"']?(/|/[*]|~|~/|~/[*]|[\$]home/?|[\$][{]home[}]/?|[.]|[.]/|[.]/[*]|[.][.]|[.][.]/?|[*]|[.]git/?|[a-z]:[/\\\\]?)[\"']?([[:space:])\"'\`;|&]|$)"
  rest=$t
  while [[ $rest =~ $re_rm ]]; do
    seg=${BASH_REMATCH[0]}
    if has "$seg" '[[:space:]](-[a-z]*r[a-z]*|--recursive)([[:space:]]|$)'; then
      if { [ "$vm" = 0 ] && has "$seg" "$re_rm_target"; } || has "$seg" '--no-preserve-root|docs/refactor'; then
        block "$MSG_RM_BIG" "$MSG_RM_HINT 폴더를 옮긴 뒤 지우려면 같은 줄에서 \`cd X && rm -rf …\` 처럼 \`&&\` 로 이어 주세요."
      fi
    fi
    rest=${rest#*"$seg"}
  done
  if [ "$vm" = 0 ]; then
    has "$t" "${S}(rmdir|rd)[[:space:]]+(/{1,2}[a-z][[:space:]]+)*/{1,2}s([[:space:]]|$)" && block "폴더 통째 삭제(rmdir /s)는 막혀 있습니다." "사람이 직접 하세요."
    if has "$t" 'remove-item[^;&|]*-recurse' && has "$t" "remove-item[^;&|]*[[:space:]][\"']?([.]|[*]|~|[a-z]:[/\\\\]?|[.]git)[\"']?([[:space:]]|$)"; then
      block "Remove-Item -Recurse 로 프로젝트·홈 전체를 지우는 명령은 막혀 있습니다." "사람이 직접 하세요."
    fi
  fi
  # 리팩토링 진행 중: 기록 폴더 안의 파일 지우기(하위 에이전트 지시문 판정에서는 건너뛴다 — 그 도구 호출이 따로 판정된다)
  if [ "$refactor_on" = 1 ] && [ "${AGENT_MODE:-0}" != 1 ]; then
    has "$t" "${S}(rm|unlink|remove-item)[[:space:]][^;&|]*docs/refactor/" && block "$MSG_RDOC" "$MSG_RDOC2"
  fi
  return 0
}
# 셸 명령 원문의 SQL 이 데이터를 통째로 지우거나 구조를 삭제하는가(한 번만 계산해 SQLRAW 에 둔다 — check_shell 의 지역 변수)
sql_raw_destructive() {
  if [ -z "${SQLRAW:-}" ]; then
    SQLRAW=0
    # SQL 은 줄바꿈을 살린 원문으로 본다(줄바꿈이 " ; " 로 바뀐 lr 로는 여러 줄 UPDATE…WHERE 가 두 문장으로 쪼개진다)
    unesc_nl "$rawcmd"; fw_norm "$UV"; rm_empty_quotes "$FW"; expand_vars "$EQ"; sql_destructive "$EV" shell && SQLRAW=1
  fi
  [ "$SQLRAW" = 1 ]
}
# 고가치 규칙(DB 삭제·초기화) — lq·lz·hv·hvz 사본마다(bash -c "supa"'base db reset' · sh -c "drop"'db x')
hv_db() {
  local t=$1
  local dbcli="${S}(psql|pg_restore|mysql|mariadb|sqlite3|sqlcmd|mongo|mongosh|redis-cli|supabase|prisma|drizzle-kit|sequelize|knex|typeorm|rails|rake|artisan|manage\\.py|alembic|turso|wrangler|neonctl|pscale|duckdb|clickhouse|clickhouse-client|cockroach|bq|firebase)${E}"
  if has "$t" "$dbcli" && sql_raw_destructive; then
    block "DB 데이터를 통째로 지우거나 구조를 삭제하는 명령은 막혀 있습니다." "운영 DB 작업은 사람이 백업을 확인한 뒤 직접 합니다."
  fi
  if has "$t" 'supabase[[:space:]]+db[[:space:]]+reset|prisma[[:space:]]+migrate[[:space:]]+reset|prisma[[:space:]]+db[[:space:]]+push[^;&|]*(--force-reset|--accept-data-loss)|drizzle-kit[[:space:]]+drop|rails[[:space:]]+db:(drop|reset|purge|schema:load)|rake[[:space:]]+db:(drop|reset|purge)|artisan[[:space:]]+(migrate:fresh|migrate:reset|db:wipe)|manage\.py[[:space:]]+(flush|reset_db|sqlflush)|sequelize[^;&|]*db:drop|typeorm[^;&|]*schema:drop|knex[^;&|]*migrate:rollback[^;&|]*--all|firebase[[:space:]]+firestore:delete|turso[[:space:]]+db[[:space:]]+(destroy|delete)|terraform[[:space:]]+destroy|vercel[[:space:]]+(rm|remove)([[:space:]]|$)' \
    || has "$t" "${S}dropdb${E}"; then
    block "DB·서비스를 초기화하거나 삭제하는 명령은 막혀 있습니다." "사람이 백업을 확인한 뒤 직접 실행합니다."
  fi
  return 0
}
# 0.4.0 G5(#11): netlify api <메서드> 가 읽기(get…·list…)가 아닌가 → 0. 메서드 = api 뒤 첫 낱말 중 옵션이 아닌 것(값을 받는 옵션
#   --data·-d·--auth·--filter·--http-proxy·--http-proxy-certificate-filename 은 값까지 건너뜀). 그 밖(create…·update…·delete…·restore…·rollback…·
#   cancel…·lock…·unlock…·모르는 이름·변수)은 쓰기로 본다. 메서드가 없으면(목록 --list·도움말·# 주석 뒤) 아니다. npx netlify-cli@x api … 도 같게
netlify_api_write() {
  local rest=$1 seg i m w=() re="${S}(netlify(-cli)?|ntl)(@[^[:space:];&|]*)?[[:space:]]+api([[:space:]][^;&|]*)?"   # 보완: ntl = netlify 별칭
  while [[ $rest =~ $re ]]; do
    seg=${BASH_REMATCH[0]}; rest=${rest#*"$seg"}
    seg=${BASH_REMATCH[5]}; seg=${seg//\"/ }; seg=${seg//\'/ }
    set -f; w=($seg); set +f
    m=""; i=0
    while [ "$i" -lt "${#w[@]}" ]; do
      case "${w[$i]}" in
        --data|-d|--auth|--filter|--http-proxy|--http-proxy-certificate-filename) i=$((i + 2)) ;;
        -*) i=$((i + 1)) ;;
        *) m=${w[$i]}; break ;;
      esac
    done
    case "$m" in ""|"#"*) continue ;; esac
    has "$m" '^(get|list)[A-Za-z0-9_]*$' && continue
    return 0
  done
  return 1
}
# 고가치 규칙(리팩토링 진행 중: 배포·마이그레이션 적용·원격 DB 접속) — lq·lz·hv·hvz 사본마다(bash -c "ver"'cel --prod').
#   $2 = 원격 DB 주소 판정용 문자열(원형은 lr, 사본은 그 사본)
hv_deploy() {
  local t=$1 r=${2:-$1} remote_db=0
  # 0.3.4 F4: 하위명령 낱말 뒤 경계 = 영문·숫자가 아닌 글자 또는 끝 — 글자가 이어지는 낱말(upgrade·deployments·reloadLogs)만 풀리고
  #   :·-·=·, 가 붙은 꼴(wrangler secret:put · railway up:x)은 막힌다. vercel aliases 는 alias 와 같이
  #   0.3.7 G1: heroku rollback·releases:rollback·pg:reset · netlify rollback·sites:delete(같은 경계 — heroku releases·releases:info·restart 는 통과)
  #   보완(검사 A#7): heroku apps:destroy(netlify sites:delete 와 같은 성격 — apps:info 는 통과)
  #   0.4.0 G4: gh release create·delete·edit·upload · gh pr|release|workflow 뒤 하위명령 앞의 -R|--repo <저장소>(옵션 순서만 다른 철자)도 같게
  #   0.4.0 보완(검사 C#5·A#9): vercel --target production(=) · ntl(netlify 별칭) deploy·rollback·sites:delete · gh workflow enable·disable · gh run rerun
  local ghr="([[:space:]]+(-r|--repo)(=|[[:space:]]+)[^[:space:];&|]+)?"
  local re_deploy="${S}(vercel([[:space:]][^;&|]*)?(--prod|--target([[:space:]]+|=)[\"']?production|[[:space:]](deploy|promote|rollback|alias|aliases|redeploy)([^A-Za-z0-9]|$))|vercel[[:space:]]*($|[;&|])|(netlify|ntl)[[:space:]]+deploy|heroku[[:space:]]+(rollback|releases:rollback|pg:reset|apps:destroy)([^A-Za-z0-9]|$)|(netlify|ntl)[[:space:]]+(rollback|sites:delete)([^A-Za-z0-9]|$)|firebase[[:space:]]+deploy|wrangler[[:space:]]+(deploy|publish|rollback|versions[[:space:]]+deploy|pages[[:space:]]+(deploy|deployment[[:space:]]+(create|delete))|secret|secrets-store)([^A-Za-z0-9]|$)|(fly|flyctl)[[:space:]]+deploy|railway[[:space:]]+(up|deploy|redeploy|down|restart|deployment[[:space:]]+(up|redeploy))([^A-Za-z0-9]|$)|gcloud[[:space:]][^;&|]*deploy|eb[[:space:]]+deploy|(serverless|sls)[[:space:]]+deploy|amplify[[:space:]]+publish|docker[[:space:]]+push|kubectl[[:space:]]+(apply|delete|rollout)|terraform[[:space:]]+apply|pm2[[:space:]]+(deploy|restart|reload)([^A-Za-z0-9]|$)|gh[[:space:]]+(pr${ghr}[[:space:]]+merge|release${ghr}[[:space:]]+(create|delete|edit|upload)|workflow${ghr}[[:space:]]+(run|enable|disable)|run${ghr}[[:space:]]+rerun)|ssh[[:space:]]|scp[[:space:]])"
  local re_pkg_deploy="${S}(npm|pnpm|yarn|bun)[[:space:]]+((run|run-script)[[:space:]]+)?([a-z0-9_-]+:)?(deploy|release|publish|ship)([[:space:]:]|$)"
  # 0.4.0 G6(#10): vercel 의 첫 하위 명령이 조회(ls·list·inspect·logs)인 조각에서만 --prod 는 배포가 아니다(vercel ls --prod = 운영 배포 목록) —
  #   그 조각(; & | 앞까지)의 --prod 만 지운 사본(tv)으로 배포 규칙을 본다. 하위 명령 앞에 옵션이 있거나(vercel --prod ls) 다른 하위 명령이면 그대로 막는다
  local tv=$t
  if has "$t" 'vercel' && has "$t" '--prod'; then
    # 보완(검사 A#2): 조각은 $( · ` · <( · >( · 줄바꿈 앞에서도 끊는다 — 그 안의 진짜 배포 명령(vercel ls $(vercel --prod))의 --prod 를 지우지 않게
    local vrest=$t vout="" vm re_vro="${S}vercel[[:space:]]+(ls|list|inspect|logs)([[:space:]][^;&|\`(${NL}]*)?"
    while [[ $vrest =~ $re_vro ]]; do
      vm=${BASH_REMATCH[0]}; vout=$vout${vrest%%"$vm"*}; vrest=${vrest#*"$vm"}
      while [[ $vm =~ --prod ]]; do vm=${vm/"${BASH_REMATCH[0]}"/--x}; done
      vout=$vout$vm
    done
    tv=$vout$vrest
  fi
  if has "$tv" "$re_deploy" || has "$t" "$re_pkg_deploy"; then
    # 0.3.4 §10-5: PR 합치기(gh pr merge)가 걸렸을 때만 입력창 명령을 안내한다(합치기는 승인 스크립트가 검사 뒤 직접 한다)
    local dh="필요한 명령을 사람에게 안내하세요."
    has "$t" "${S}gh[[:space:]]+pr${ghr}[[:space:]]+merge" && dh="PR 합치기는 사용자에게 /refactor:approve 합치기 를 입력해 달라고 하세요(자동 검사가 모두 초록이고 기본 가지에 새 커밋이 없을 때만 합쳐짐). 그 밖의 명령은 사람에게 안내하세요."
    block "리팩토링 진행 중에는 배포·원격 서버 명령을 사람이 직접 합니다." "$dh"
  fi
  netlify_api_write "$t" && block "리팩토링 진행 중에는 배포·원격 서버 명령을 사람이 직접 합니다." "필요한 명령을 사람에게 안내하세요. 읽기는 netlify api get…·list… 로 됩니다."
  # 0.3.5 X1: gh api 로 PR 합치기(REST pulls/<번호>/merge · 가지 합치기 /merges · graphql mergePullRequest·enablePullRequestAutoMerge·mergeBranch)
  #   — gh pr merge 차단을 비껴가는 길. 방식 옵션(-X·--method)과 상관없이 막는다(합쳐졌는지 보는 읽기 GET 도 — 안내에 조회 대안).
  #   번호 칸은 숫자가 아니어도(변수·따옴표) 본다. gh.exe·경로 붙은 gh 도(조각 = gh api 부터 ; & | 앞까지)
  #   F16-e: graphql 변이 enqueuePullRequest(합치기 대기열)·updateRef(s)·createCommitOnBranch·deleteRef 도 같은 차단.
  #   F16-f: 경로 판정 전에 // 를 / 로 모은다(pulls/70//merge · git//refs — 판정용 사본만)
  #   F16-a·b: …/git/refs(가지 참조 옮기기 = PR 없이 합치기)·…/contents(API 로 직접 커밋)를 읽기가 아닌 요청으로 겨냥(gha_write)
  #   F16-d: graphql 질의를 파일에서 읽으면(-f·-F·--field·--raw-field 값이 @ 로 시작 · --input) 변이 이름을 볼 수 없어 막는다
  local mseg mn mrest=$t re_mga="gh([.]exe)?[[:space:]]+api([[:space:]][^;&|]*)?" d2=// d1=/
  while [[ $mrest =~ $re_mga ]]; do
    mseg=${BASH_REMATCH[0]}; mrest=${mrest#*"$mseg"}
    # 보완: 조각이 따옴표 안의 ; & |(--jq '.a|.b' · -H 'a;b')에서 끊겼으면(따옴표 짝이 안 맞음) 따옴표 밖의 구분자까지 다시 잡는다 — 뒤의 -X·경로·필드를 놓치지 않게
    if quote_odd "$mseg"; then gha_scan "$mseg$mrest"; mrest=${mseg}${mrest}; mrest=${mrest:${#GS}}; mseg=$GS; fi
    mn=$mseg; case "$mn" in *%*) pct_dec "$mn"; mn=$PD ;; esac
    while [[ $mn == *"$d2"* ]]; do mn=${mn//"$d2"/$d1}; done
    if has "$mn" "pulls/[^/[:space:]]*/merge([^A-Za-z0-9_]|$)|/merges([^A-Za-z0-9_]|$)|mergepullrequest|enablepullrequestautomerge|mergebranch|enqueuepullrequest|updateref|createcommitonbranch|deleteref"; then
      block "리팩토링 진행 중에는 배포·원격 서버 명령을 사람이 직접 합니다." "PR 합치기는 사용자에게 /refactor:approve 합치기 를 입력해 달라고 하세요(자동 검사가 모두 초록이고 기본 가지에 새 커밋이 없을 때만 합쳐짐). 그 밖의 명령은 사람에게 안내하세요. 합쳐졌는지 보려면 gh pr view <번호> --json state,mergedAt 를 쓰세요."
    fi
    # 0.3.7 G3: 저장소 설정 쓰기 — 저장소 뿌리(repos/<주인>/<저장소> 뒤가 ? · 공백 · 따옴표 · 끝: 기본 가지·이름·보관·공개 여부) ·
    #   가지 이름 바꾸기(/branches/<가지>/rename) · 가지 보호(/branches/<가지>/protection(/…)) · 강제 동기화(/merge-upstream). 읽기(GET)는 통과
    #   보완(검사 C#4·A#7): 이웃 꼴 — 저장소 규칙 묶음(/rulesets(/<번호>) — 지금 GitHub 가 권하는 가지 보호) · 소유권 넘기기(/transfer) ·
    #   번호로 부르는 저장소 뿌리(repositories/<번호>)
    if has "$mn" "[[:space:]][\"']?/?repos/[^/[:space:]\"']+/[^/[:space:]\"'?]+/?([?\"'[:space:])]|$)|[[:space:]][\"']?/?repositories/[0-9]+/?([?\"'[:space:])]|$)|/branches/[^[:space:]\"']+/(rename|protection)([/?\"'[:space:])]|$)|/merge-upstream([?\"'[:space:])]|$)|/rulesets(/[0-9]+)?/?([?\"'[:space:])]|$)|/transfer([?\"'[:space:])]|$)" \
      && gha_write "$mn"; then
      block "$MSG_REPOSET" "$MSG_REPOSET2"
    fi
    if has "$mn" "/git/refs([/\"'[:space:]?)]|$)|/contents([/\"'[:space:]?)]|$)" && gha_write "$mn"; then
      block "$MSG_GHW" "$MSG_GHW2"
    fi
    # 0.4.0 G4(#11): 배포 기록(…/deployments · …/deployments/<번호>/statuses) · 워크플로 실행(…/actions/workflows/<x>/dispatches · repos/<o>/<r>/dispatches) ·
    #   릴리스(…/releases · …/releases/<번호>/assets) · Pages 빌드(…/pages/builds) 쓰기 = 배포 명령(gh workflow run · gh release create 와 같은 묶음).
    #   쓰기 판정은 gha_write(-X·--method 가 GET 이 아님 · 방식 없이 -f·-F·--field·--raw-field·--input) — 읽기(GET)는 통과
    if has "$mn" "/(deployments|dispatches|releases)([/?\"'[:space:])]|$)|/pages/builds([/?\"'[:space:])]|$)" && gha_write "$mn"; then
      block "리팩토링 진행 중에는 배포·원격 서버 명령을 사람이 직접 합니다." "필요한 명령을 사람에게 안내하세요."
    fi
    # 0.4.0 보완(검사 C#5·A#9): 워크플로 다시 돌리기(…/actions/runs|jobs/<번호>/rerun · rerun-failed-jobs) 쓰기 = 배포(gh run rerun 과 같은 묶음) ·
    #   배포 환경 설정(…/environments/<이름>(/…) — 보호 규칙·대기 시간·비밀값) 쓰기 = 저장소 설정 · GraphQL 변이 createDeployment(배포 기록) ·
    #   updateRepository·create|update|deleteBranchProtectionRule(저장소 설정) — 질의 글자에서 본다. 읽기(GET·query)는 통과
    if has "$mn" "/actions/(runs|jobs)/[^/[:space:]\"']+/(rerun|rerun-failed-jobs)([/?\"'[:space:])]|$)" && gha_write "$mn"; then
      block "리팩토링 진행 중에는 배포·원격 서버 명령을 사람이 직접 합니다." "필요한 명령을 사람에게 안내하세요."
    fi
    if has "$mn" "/environments/[^/[:space:]\"'?]+" && gha_write "$mn"; then
      block "$MSG_REPOSET" "$MSG_REPOSET2"
    fi
    if has "$mn" "[[:space:]][\"']?/?graphql([\"'[:space:]?)]|$)"; then
      has "$mn" "createdeployment" && block "리팩토링 진행 중에는 배포·원격 서버 명령을 사람이 직접 합니다." "필요한 명령을 사람에게 안내하세요."
      has "$mn" "updaterepository|(create|update|delete)branchprotectionrule" && block "$MSG_REPOSET" "$MSG_REPOSET2"
    fi
    if has "$mn" "[[:space:]][\"']?/?graphql([\"'[:space:]?)]|$)" \
      && has "$mn" "[[:space:]][\"']?((-i*f|--field|--raw-field)([[:space:]]+|=)?[\"']?[^[:space:]=\"']*[\"']?=[\"']?@|--input([[:space:]=\"']|$))"; then
      block "$MSG_GHW" "GraphQL 질의는 명령 안에 그대로 적으세요(파일에서 읽으면 판정할 수 없습니다)"
    fi
  done
  # F16-c: gh 별칭 만들기(이름을 바꾼 pr merge 등으로 판정을 피하는 길) — 목록·지우기는 통과
  has "$t" "gh([.]exe)?[[:space:]]+alias[[:space:]]+(set|import)([^a-z0-9_-]|$)" && block "리팩토링 진행 중에는 gh 별칭을 만들지 않습니다(명령 이름을 바꿔 판정을 피하는 길)." "원래 gh 명령을 그대로 쓰세요."
  local re_pkg_db="${S}(npm|pnpm|yarn|bun)[[:space:]]+((run|run-script)[[:space:]]+)?[a-z0-9_:-]*(migrat[a-z]*|(db|prisma|supabase|drizzle)[:_-](push|migrate|reset|seed|deploy|drop|up|apply))"
  # 0.3.4 T1: 마이그레이션 상태 조회(rails·rake db:migrate:status[:<DB 이름>] · artisan migrate:status · sequelize db:migrate:status)는 적용이 아니다 —
  #   그 낱말만(끝 경계까지) 공백으로 바꾼 사본으로 아래 CLI 규칙을 본다. 쓰기 꼴(db:migrate:reset·db:migrate:primary·migrate:rollback …)은 지금처럼 접두로 막힌다.
  #   프로젝트 스크립트 이름(re_pkg_db — npm run db:migrate:status)은 무엇을 하는지 몰라 원래 문자열로 본다
  local tm=$t re_mst="([[:space:]\"'])(db:)?migrate:status(:[a-z0-9_-]+)?([[:space:]\"')\`;&|]|$)"
  while [[ $tm =~ $re_mst ]]; do tm=${tm/"${BASH_REMATCH[0]}"/"${BASH_REMATCH[1]} ${BASH_REMATCH[4]}"}; done
  if has "$tm" 'supabase[[:space:]]+(db[[:space:]]+push|functions[[:space:]]+deploy|secrets[[:space:]]+set)|supabase[[:space:]]+migration[[:space:]]+(up|repair)[^;&|]*(--linked|--db-url)|prisma[[:space:]]+(migrate[[:space:]]+(deploy|resolve)|db[[:space:]]+(push|execute))|drizzle-kit[[:space:]]+(push|migrate)|sequelize[^;&|]*db:migrate|knex[^;&|]*migrate:(latest|up|down|rollback)|alembic[[:space:]]+(upgrade|downgrade)|manage\.py[[:space:]]+migrate|rails[[:space:]]+db:migrate|rake[[:space:]]+db:migrate|artisan[[:space:]]+migrate' \
    || has "$t" "$re_pkg_db" \
    || has "$t" "${S}docker(-compose|[[:space:]]+compose)[^;&|]*[[:space:]]down[^;&|]*[[:space:]](-v|--volumes)([[:space:]]|$)" \
    || has "$t" '(^|[[:space:]:])db:(reset|drop|wipe|purge)([[:space:]]|$)' \
    || { has "$t" 'prisma[[:space:]]+migrate[[:space:]]+dev' && ! has "$t" '--create-only'; }; then
    block "리팩토링 진행 중에는 DB 구조 변경(마이그레이션 적용)을 사람이 직접 합니다." "로컬 테스트 DB라면 사람이 터미널에서 <명령> 으로 실행합니다(CLI 라면 입력창에 ! <명령> 도 됨)."
  fi
  if has "$t" "${S}(psql|mysql|mariadb|mongosh|mongo|redis-cli|sqlcmd)${E}"; then
    has "$r" '[$][{]?[A-Za-z_]*(URL|URI|DSN|DATABASE|DB_|CONN)' && remote_db=1
    if has "$r" '://'; then has "$r" '://([^/@[:space:]]*@)?(localhost|127[.]0[.]0[.]1|[[]::1[]])([:/[:space:]"'"'"']|$)' || remote_db=1; fi
    if has "$r" '[[:space:]](-h|--host)([[:space:]=]|$)'; then has "$r" '[[:space:]](-h|--host)(=|[[:space:]]+)["'"'"']?(localhost|127[.]0[.]0[.]1|::1)([[:space:]"'"'"']|$)' || remote_db=1; fi
  fi
  if [ "$remote_db" = 1 ]; then
    block "리팩토링 진행 중에는 원격 DB(운영일 수 있음)에 직접 접속해 조회하지 않습니다(고객 개인정보가 화면에 찍힐 수 있음)." "필요한 확인은 사람에게 요청하세요."
  fi
  return 0
}
# /refactor:go 중 안전 실행기 강제. $1 판정 문자열, $2 = 1 이면 안전 실행기 뒤 따옴표 명령을 감싼 뒤 따옴표 글자를 모두 뺀다(lz 용)
go_runner() {
  local rq=$1 rseg runsh=${REFACTOR_ROOT:-<플러그인 폴더>}
  local re_mark="run\\.sh[\"']?[[:space:]]+refactor-safe-run[[:space:]]+(--|--check)([[:space:]]|$)"
  local re_plug="run\\.sh[\"']?[[:space:]]+refactor-(status|board|report)([[:space:]]|$)"
  runsh=${runsh//"$BS"/$SL}; runsh="${runsh%/}/hooks/run.sh"
  # 안전 실행기 뒤에 따옴표로 넘긴 명령(sh -c "npm test && npm run build")은 통째로 감싼 것이니 쪼개지 않는다
  blank_quoted "(refactor-safe-run[[:space:]]+--[[:space:]][^;&|]*)(\"[^\"]*\"|'[^']*')" 2 "$rq"; rq=$BQ
  if [ "${2:-0}" = 1 ]; then join_assign_vals "$rq"; rq=${JA//\'/}; rq=${rq//\"/}; fi   # #7: 대입 값(R='a b.ts')은 따옴표를 빼기 전에 한 단어로
  rq=${rq//&&/$NL}; rq=${rq//||/$NL}; rq=${rq//;/$NL}; rq=${rq//|/$NL}; rq=${rq//(/$NL}; rq=${rq//\`/$NL}
  local re_cmt='[[:space:]]#.*$'
  while [ -n "$rq" ]; do
    rseg=${rq%%"$NL"*}; if [ "$rseg" = "$rq" ]; then rq=""; else rq=${rq#*"$NL"}; fi
    [[ $rseg =~ $re_cmt ]] && rseg=${rseg%%"${BASH_REMATCH[0]}"}   # 주석(# …)은 명령이 아니다
    has "$rseg" "$re_mark" && continue
    has "$rseg" "$re_plug" && continue   # 플러그인 자체 현황 스크립트(경로에 띄어쓰기가 있어도)
    # 0.4.0 G2: 자동 마감은 인자 없는 /refactor:go 차례 안에서 돈다 — 허락된 자동 모드 스크립트 꼴 그대로(AOK — 명령 전체가 그 한 줄)일 때만
    [ "${AOK:-0}" = 1 ] && has "$rseg" "run\\.sh[\"']?[[:space:]]+refactor-auto([[:space:]]|$)" && continue
    if runs_project_code "$rseg"; then
      block "리팩토링(/refactor:go) 중에는 테스트·빌드·앱 실행을 안전 실행기로만 합니다 — 운영 DB·운영 키 대신 가짜 값(127.0.0.1:9 등)을 넣어, 실수로 운영 데이터를 바꾸거나 알림을 보내지 않게 합니다." "명령 앞에 붙이세요(&&·; 로 이은 명령마다 각각): bash \"$runsh\" refactor-safe-run -- <명령>   예) bash \"$runsh\" refactor-safe-run -- npm test   · 무엇이 가짜 값으로 바뀌는지(이름만): bash \"$runsh\" refactor-safe-run --check"
    fi
  done
  return 0
}
# 패키지 실행기의 셸 모드(npx -c '…' · npx --call … · npm exec -c · pnpm exec -c · yarn exec -c)는 안의 명령만 남긴다 → SC
strip_call_opt() {
  SC=$1
  case "$SC" in *-c*|*--call*) ;; *) return 0 ;; esac
  local q="'" m k=0 inner
  local re="(^|[;&|({[:space:]])(npx|pnpx|bunx|npm[[:space:]]+(exec|x)|pnpm[[:space:]]+(exec|dlx)|yarn[[:space:]]+(exec|dlx))(([[:space:]]+-[^[:space:]]+)*)[[:space:]]+(-c|--call)(=|[[:space:]]+)(\"([^\"]*)\"|${q}([^${q}]*)${q}|([^[:space:];&|]+))"
  while [[ $SC =~ $re ]] && [ "$k" -lt 5 ]; do
    m=${BASH_REMATCH[0]}; inner="${BASH_REMATCH[11]}${BASH_REMATCH[12]}${BASH_REMATCH[13]}"
    SC=${SC/"$m"/"${BASH_REMATCH[1]}$inner"}; k=$((k + 1))
  done
}
# 명령을 && || ; | ` $( 로 나눈 조각들 → CUTS(줄바꿈 구분)
cut_segs() { local s=$1; s=${s//&&/$NL}; s=${s//||/$NL}; s=${s//;/$NL}; s=${s//|/$NL}; s=${s//\`/$NL}; CUTS=${s//\$(/$NL}; }
# 새 Claude 세션(claude -p … · npx claude · node …/claude-code/…)에 승인 명령·--from-hook 을 넘기는가 — 새 세션의 입력 훅이 사람 입력으로 보고 승인한다
#   $2 = 볼 낱말 정규식(없으면 승인 명령 — 0.4.0 자동 모드 스크립트는 'refactor-auto' 로 따로 부른다: 막는 문구가 다르다)
nested_claude_approve() {
  has "$1" 'claude' && has "$1" "${2:-refactor:(approve|go)|from-hook}" || return 1
  local s seg i a
  cut_segs "$1"; s=$CUTS
  while [ -n "$s" ]; do
    seg=${s%%"$NL"*}; if [ "$seg" = "$s" ]; then s=""; else s=${s#*"$NL"}; fi
    case "$seg" in *claude*) ;; *) continue ;; esac
    seg_words "$seg"
    case "$SCMD" in
      claude|claude.cmd) return 0 ;;
      npx|pnpx|bunx|node|bun|deno|pnpm|yarn|npm)
        for ((i = SI + 1; i < ${#SW[@]}; i++)); do
          a=${SW[$i]}
          case "$a" in exec|dlx|x|run) continue ;; -*) continue ;; esac
          case "$a" in *claude*) return 0 ;; esac
          break
        done ;;
    esac
  done
  return 1
}
# 0.4.0 보완(검사 A#9 #23): 다른(또는 이) Claude 세션을 이어서(--resume·-r·--continue·-c) 출력 모드(-p·--print)로 부르는가 — 넘긴 글(파이프·< 파일 포함)은
#   그 세션의 입력 훅이 사람 입력으로 보고 처리한다(승인 낱말을 글 안에 숨기면 판정할 수 없다). 조각(&& || ; | ` $( 로 나눔)마다 claude 낱말 뒤의 낱말만 본다 —
#   띄어쓰기가 든 따옴표 글은 한 낱말로 비우고(질문 글 속 -r 은 옵션이 아님) 남은 따옴표 글자는 떼며(--res"ume"), 짧은 옵션 묶음(-pc)도 글자로 본다.
#   새 세션(claude -p "질문")·대화형(claude -c)은 통과. 따옴표를 모두 뺀 사본(lz)에는 쓰지 않는다(질문 글이 낱말로 풀려 헛막힘) — lq·hv 로 본다
MSG_RESUME="리팩토링 진행 중에는 Claude 세션을 이어서(--resume·--continue) 출력 모드(-p)로 부르지 않습니다 — 넘긴 글이 그 세션에서 사람 입력처럼 처리됩니다."
MSG_RESUME2="새 질문은 새 세션(claude -p \"<질문>\")으로 하세요. 다른 세션에 이어서 할 일은 사람에게 부탁하세요."
#   재검사 A2#3: claude 찾기는 nested_claude_approve 와 같은 방식도 — 조각 첫 낱말(경로 뗀 이름)이 claude(.exe·.cmd)이거나(./claude · ~/.local/bin/claude),
#   실행기(npx·pnpx·bunx·node·bun·deno·pnpm·yarn·npm — exec·dlx·x·run 과 옵션은 건너뜀) 뒤 첫 낱말이 *claude-code* · */claude 꼴이면 그 뒤 낱말을 본다.
#   $( · ` 자리는 알 수 없는 낱말($X)로 남기고, 풀 수 없는 낱말($ 가 남음)은 출력 모드·이어서 둘 다일 수 있다고 보고 막는다
claude_resume_print() {
  has "$1" 'claude' || return 1
  local s seg cw i a re_cl="(^|[^[:alnum:]._/-])claude([.](exe|cmd))?([^[:alnum:]_.-]|$)"
  s=$1; s=${s//&&/$NL}; s=${s//||/$NL}; s=${s//;/$NL}; s=${s//|/$NL}; s=${s//\`/ \$X$NL}; s=${s//\$(/ \$X$NL}
  while [ -n "$s" ]; do
    seg=${s%%"$NL"*}; if [ "$seg" = "$s" ]; then s=""; else s=${s#*"$NL"}; fi
    case "$seg" in *claude*) ;; *) continue ;; esac
    if [[ $seg =~ $re_cl ]]; then crp_words "${seg#*"${BASH_REMATCH[0]}"}" && return 0; fi
    seg_words "$seg"; cw=""
    case "$SCMD" in
      claude|claude.cmd) cw=${SW[$SI]} ;;
      npx|pnpx|bunx|node|bun|deno|pnpm|yarn|npm)
        for ((i = SI + 1; i < ${#SW[@]}; i++)); do
          a=${SW[$i]}
          case "$a" in exec|dlx|x|run) continue ;; -*) continue ;; esac
          case "$a" in *claude-code*|*/claude|*/claude.exe|*/claude.cmd|claude|claude.exe|claude.cmd) cw=$a ;; esac
          break
        done ;;
    esac
    [ -z "$cw" ] && continue
    seg=${seg#*"$cw"}; case "$seg" in [\"\']*) seg=${seg:1} ;; esac
    crp_words "$seg" && return 0
  done
  return 1
}
# claude 낱말 뒤 글($1)에 출력 모드(-p·--print)와 이어서(--resume·-r·--continue·-c)가 둘 다 있는가 — 풀 수 없는 낱말($ 가 남음)은 둘 다로 본다
crp_words() {
  local seg=$1 w raw pr=0 rs=0 sk=0 re_q="\"[^\"]*[[:space:]][^\"]*\"|'[^']*[[:space:]][^']*'"
  while [[ $seg =~ $re_q ]]; do seg=${seg/"${BASH_REMATCH[0]}"/ Q }; done
  set -f
  for w in $seg; do
    raw=$w; w=${w//\"/}; w=${w//\'/}
    # 리다이렉트 대상(> "$OUT")은 옵션이 아니다 — 단 보안 검사(10-05): 리다이렉트인지는 따옴표를 벗기기 **전** 낱말로 본다('>' · ">" 는 글이다) ·
    #   건너뛸 자리에 - 로 시작하는 낱말이 오면 건너뛰지 않고 판정한다(막는 쪽)
    if [ "$sk" = 1 ]; then sk=0; case "$w" in -*) ;; *) continue ;; esac; fi
    # 리다이렉트 기호로 시작하는 낱말(>"$OUT" · 2>"$ERR" · <"$IN" · &>x)은 따옴표가 있어도 대상이다(재검사 A3 🟡 헛막힘)
    case "$raw" in '<'*|'>'*|[0-9]'>'*|[0-9]'<'*|'&>'*) case "$raw" in '<'|'<<'|'<<<'|'>'|'>>'|'>|'|[0-9]'>'|[0-9]'>>'|'&>') sk=1 ;; esac; continue ;; esac
    # 따옴표 밖 기호가 낱말 중간·끝에 붙으면(-p>x · --resume>>x · -c&>x · -r<f) 기호 앞부분을 옵션으로 판정하고, 기호로 끝나면 다음 낱말만 대상으로 건너뛴다
    #   (보안 검사 10-05 — 낱말 통째로 건너뛰면 붙여 쓴 옵션을 못 봤다)
    case "$raw" in *\"*|*\'*) ;; *'<'*|*'>'*)
      case "$w" in *'<'|*'>'|*'>|'|*'<<'|*'<<<') sk=1 ;; esac
      w=${w%%[<>]*}; w=${w%&}; w=${w%[0-9]}
      [ -n "$w" ] || continue ;;
    esac
    case "$w" in
      *'$'*) pr=1; rs=1 ;;
      --print|--print=*) pr=1 ;;
      --resume|--resume=*|--continue|--from-pr|--from-pr=*) rs=1 ;;
      --*) ;;
      -[A-Za-z]*) case "$w" in *[!A-Za-z-]*) ;; *) case "$w" in *p*) pr=1 ;; esac; case "$w" in *[rc]*) rs=1 ;; esac ;; esac ;;
    esac
  done
  set +f
  [ "$pr" = 1 ] && [ "$rs" = 1 ]
}
# 승인 스크립트를 "실행"하는 모양인가(읽기·검색은 아니다): bash·sh·source·. 로 부르기, 직접 실행, run.sh refactor-approve,
# 셸로 흘려 넣기(cat … | bash · bash < … · <( ) · eval · xargs bash · -exec bash). $1 = 판정용 명령(따옴표 정리됨)
#   $2 = 스크립트 이름(없으면 refactor-approve — 0.3.5 합치기 스크립트 refactor-merge 도 같은 판정)
approve_exec() {
  local s seg nm=${2:-refactor-approve} re_penv='^[[:space:]]*[^[:space:]]*[/\\]env([.]exe)?[[:space:]]'
  has "$1" "[|][[:space:]]*(sudo[[:space:]]+)?(ba|z|da|k)?sh([[:space:]]|$)|(^|[;&|({[:space:]])(bash|sh|zsh|dash|source|\\.)[[:space:]]*<|<[(]|(^|[;&|({[:space:]])eval([[:space:]]|$)|(xargs|-exec|-execdir)[[:space:]]+([^;&|]*[[:space:]])?(sudo[[:space:]]+)?(bash|sh|zsh|dash|source)([[:space:]]|$)" && return 0
  cut_segs "$1"; s=$CUTS
  while [ -n "$s" ]; do
    seg=${s%%"$NL"*}; if [ "$seg" = "$s" ]; then s=""; else s=${s#*"$NL"}; fi
    case "$seg" in *"$nm"*) ;; *) continue ;; esac
    # 0.3.5: 경로 붙은 env(/usr/bin/env bash …)는 env 로 — seg_words 가 그 뒤의 명령 이름을 보게
    [[ $seg =~ $re_penv ]] && seg="env ${seg#*"${BASH_REMATCH[0]}"}"
    seg_words "$seg"
    case "$SCMD" in *"$nm"*|run.sh|bash|sh|zsh|dash|ksh|source|.) return 0 ;; esac
  done
  return 1
}
# cd·pushd·Set-Location 조각이면 그 폴더를 cwd 로 삼는다(뒤 조각의 상대경로 기준). popd 는 처음 폴더로. 대상을 판정할 수 없으면 cwd 그대로.
# 0 = cd 류 조각이었음. 부르는 쪽이 끝나면 cwd 를 되돌린다(CWD_BASE)
cd_seg() {
  case "$1" in *cd*|*pushd*|*popd*|*location*|*chdir*|*sl\ *) ;; *) return 1 ;; esac
  seg_words "$1"
  case "$SCMD" in cd|pushd|chdir|set-location|sl|push-location|popd|pop-location) ;; *) return 1 ;; esac
  [ "${CD_FIXED:-0}" = 1 ] && return 0   # 기준 폴더를 하나로 고정해 다시 보는 중
  case "$SCMD" in popd|pop-location) cwd=$CWD_BASE; return 0 ;; esac
  local i a t="" old=$cwd
  for ((i = SI + 1; i < ${#SW[@]}; i++)); do a=${SW[$i]}; case "$a" in -) t=-; break ;; -*) continue ;; esac; t=$a; break; done
  [ -z "$t" ] && t="~"
  if [ "$t" = "-" ]; then cwd=${CD_PREV:-$cwd}; CD_PREV=$old; return 0; fi   # cd - = 바로 앞 폴더
  resolve_tok "$t" && { CD_PREV=$old; cwd=$RP; }
  return 0
}
# 명령 속 cd 가 거쳐 가는 폴더들 → CDC(줄마다 하나): cd 로 들어간 폴더 모두 + 실패해도 뒤가 이어지는 cd(; · || · 줄바꿈 뒤,
# 서브셸 (cd …) 안)의 바로 앞 폴더. 실패하는 cd·서브셸·cd - 로 기준 폴더를 속여도 이 폴더들 하나하나를 기준으로 다시 보면
# 보호 경로를 놓치지 않는다. 앞 폴더를 보지 않는 경우: cd X && … 뒤에 ; · || · 줄바꿈이 더는 없을 때(실패하면 뒤가 돌지 않음),
# cd X || exit(실패하면 끝남), (cd X && …) 서브셸 안에서 끝날 때(닫는 괄호 뒤에 명령이 없음).
# 서로 다른 후보가 CDC_MAX(8)개를 넘으면 모으기를 멈추고 CDC_OVER=1 — 후보마다 다시 보는 비용이 cd 개수의 제곱이 되지 않게(cd_all 이 보수적으로 판정)
CDC_MAX=8
cd_cands() {
  CDC=""; CDC_OVER=0
  case "$1" in *cd*|*pushd*|*popd*|*location*|*chdir*|*sl\ *) ;; *) return 0 ;; esac
  local s=$1 seg c0=$cwd pre CWD_BASE=$cwd CD_PREV=$cwd CD_FIXED=0 AND=$'\003' OR=$'\004' n=0 addpre r
  s=${s//&&/$AND$NL}; s=${s//||/$OR$NL}; s=${s//;/$NL}; s=${s//|/$AND$NL}; s=${s//\`/$NL}
  while [ -n "$s" ]; do
    seg=${s%%"$NL"*}; if [ "$seg" = "$s" ]; then s=""; else s=${s#*"$NL"}; fi
    pre=$cwd
    cd_seg "${seg%["$AND$OR"]}" || continue
    addpre=1
    case "$seg" in
      *"$AND") r=${s//"$AND$NL"/}; case "$r" in *"$NL"*) ;; *) addpre=0 ;; esac ;;   # && · | 만 이어지면 cd 실패 시 뒤가 안 돈다
      *"$OR") r=${s%%"$NL"*}; r=${r#"${r%%[![:space:]]*}"}; case "$r" in exit|exit[[:space:]]*|return|return[[:space:]]*) addpre=0 ;; esac ;;
    esac
    case "$seg" in *'('*)   # 서브셸: 닫는 괄호 뒤에 명령이 남을 때만 앞 폴더(서브셸 밖) 후보
      r="$seg$NL$s"; addpre=0
      case "$r" in *')'*) r=${r#*')'}; r=${r//[$' \t)']/}; r=${r//"$NL"/}; r=${r//"$AND"/}; r=${r//"$OR"/}; [ -n "$r" ] && addpre=1 ;; esac ;;
    esac
    if [ "$addpre" = 1 ]; then case "$NL$CDC" in *"$NL$pre$NL"*) ;; *) CDC="$CDC$pre$NL"; n=$((n + 1)) ;; esac; fi
    case "$NL$CDC" in *"$NL$cwd$NL"*) ;; *) CDC="$CDC$cwd$NL"; n=$((n + 1)) ;; esac
    if [ "$n" -gt "$CDC_MAX" ]; then CDC_OVER=1; break; fi
  done
  cwd=$c0
}
# $1 함수 $2 명령: cd 를 따라 순서대로 한 번 보고, 명령에 cd 가 있으면 거쳐 간 폴더마다 기준을 고정해 다시 본다
cd_all() {
  local c cands c0=$cwd
  cd_cands "$2"; cands=$CDC
  "$1" "$2"
  # 후보가 너무 많으면(cd 를 8곳 넘게) 후보마다 다시 보지 않는다 — 대신 기록 폴더·상위 폴더를 가리키는 상대 이름이 보이면 보수적으로 막는다
  if [ "$CDC_OVER" = 1 ]; then
    has "$2" '(^|[^[:alnum:]_-])(docs|refactor|approved|approvals[.]log|state[.]md|refactor_plan[.]md|baseline[.]md|plugins)([^[:alnum:]_-]|$)|[.]allow-|[.]turn|[.][.]' &&
      block "cd 로 여러 폴더(8곳 넘게)를 오가면서 기록 폴더(docs/refactor)·상위 폴더를 가리키는 명령은 판정할 수 없어 막습니다." "명령을 나누거나 절대경로로 적으세요."
    cands=""
  fi
  if [ -n "$cands" ]; then
    # 여기서 막히면 cd 가 실패했을 때(; · || 뒤)의 폴더 기준으로 위험한 것 — 안내에 && 로 잇는 법을 덧붙인다(규칙은 그대로)
    local bn=$BLOCK_NOTE
    BLOCK_NOTE="${bn:+$bn$NL  }폴더를 옮긴 뒤 지우거나 옮기려면 같은 줄에서 \`cd X && rm -rf …\` 처럼 \`&&\` 로 이어 주세요(; 뒤는 cd 가 실패해도 실행됩니다)."
    CD_FIXED=1
    while IFS= read -r c; do [ -n "$c" ] || continue; cwd=$c; "$1" "$2"; done <<< "$cands"
    CD_FIXED=0
    BLOCK_NOTE=$bn
  fi
  cwd=$c0
}

# 같은 명령 안에서 대입한 단순 변수(NAME=값, PowerShell $name = 값)를 값으로 펼친다 — 두 번 돌려 한 단계 안쪽 변수까지 → EV
expand_vars() {
  EV=$1
  case "$EV" in *'$'*) ;; *) return 0 ;; esac
  case "$EV" in *=*) ;; *) return 0 ;; esac
  local pass rest m name val k re_ref re_lhs P_LHS=$'\002' q="'" re
  local re_sh="(^|[;&|({[:space:]])([A-Za-z_][A-Za-z0-9_]*)=(\"([^\"]*)\"|${q}([^${q}]*)${q}|([^[:space:];&|()\"${q}<>]*))"
  local re_ps="(^|[;&|({[:space:]])[$]([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(\"([^\"]*)\"|${q}([^${q}]*)${q}|([^[:space:];&|()\"${q}<>=]+))"
  for pass in 1 2; do
    for re in "$re_sh" "$re_ps"; do
      [ "$re" = "$re_ps" ] && [ "$tool" != "PowerShell" ] && continue
      rest=$EV
      while [[ $rest =~ $re ]]; do
        m=${BASH_REMATCH[0]}; name=${BASH_REMATCH[2]}
        case "${BASH_REMATCH[3]}" in \"*) val=${BASH_REMATCH[4]} ;; "$q"*) val=${BASH_REMATCH[5]} ;; *) val=${BASH_REMATCH[6]} ;; esac
        # 0.3.2: PowerShell 의 따옴표 값 대입($R = 'app/x.ts')은 bash 의 R='app/x.ts' 처럼 한 낱말로 붙인다 — 띄어 두면 따옴표를 벗긴 뒤
        #   값이 명령 자리로 읽혀 '실행'으로 헛막힌다. 따옴표 없는 값($R = npm test)은 PowerShell 이 명령으로 실행하므로 붙이지 않는다
        if [ "$re" = "$re_ps" ]; then
          case "${BASH_REMATCH[3]}" in [\"\']*) EV=${EV/"$m"/"${BASH_REMATCH[1]}\$$name=${BASH_REMATCH[3]}"} ;; esac
        fi
        rest=${rest#*"$m"}
        [ -z "$val" ] && continue
        EV=${EV//"\${$name}"/$val}   # ${x}set 처럼 중괄호 표기는 바로 뒤에 글자가 붙어도 그 변수다
        # 0.3.2: PowerShell 대입의 왼쪽($R = …)은 참조가 아니다 — 값으로 바꾸면 'app/x.ts = …' 가 명령 자리로 읽혀 헛막힌다.
        #   치환 동안만 그 $ 를 자리표시(\002)로 바꿔 두었다가 되돌린다(== 비교는 대입이 아님)
        if [ "$tool" = "PowerShell" ]; then
          re_lhs="[$](${name}[[:space:]]*=([^=]|$))"; k=0
          while [[ $EV =~ $re_lhs ]] && [ "$k" -lt 20 ]; do EV=${EV/"${BASH_REMATCH[0]}"/"$P_LHS${BASH_REMATCH[1]}"}; k=$((k + 1)); done
        fi
        re_ref="[$]([{]${name}[}]|${name})([^A-Za-z0-9_]|$)"
        k=0
        while [[ $EV =~ $re_ref ]] && [ "$k" -lt 20 ]; do
          EV=${EV/"${BASH_REMATCH[0]}"/"$val${BASH_REMATCH[2]}"}; k=$((k + 1))
        done
        EV=${EV//"$P_LHS"/'$'}
      done
    done
  done
}

# 현재 폴더·홈·프로젝트를 가리키는 표현을 한 가지 모양으로($PWD·$HOME·$CLAUDE_PROJECT_DIR) → NV
norm_dirvars() {
  local s=$1
  s=${s//'$(pwd)'/'$PWD'}; s=${s//'`pwd`'/'$PWD'}; s=${s//'${PWD}'/'$PWD'}; s=${s//'$(Get-Location)'/'$PWD'}; s=${s//'$pwd'/'$PWD'}
  s=${s//'${HOME}'/'$HOME'}; s=${s//'$env:USERPROFILE'/'$HOME'}; s=${s//'$env:HOME'/'$HOME'}; s=${s//'%USERPROFILE%'/'$HOME'}; s=${s//'%HOMEPATH%'/'$HOME'}
  s=${s//'${CLAUDE_PROJECT_DIR}'/'$CLAUDE_PROJECT_DIR'}; s=${s//'$env:CLAUDE_PROJECT_DIR'/'$CLAUDE_PROJECT_DIR'}
  NV=$s
}

# #7: 따옴표로 감싼 대입 값(R='app/[id]/x.ts' · R="a b" · PowerShell $r = '…')의 따옴표를 떼고 값 안의 공백·괄호를 자리표시로 바꿔 한 단어로 묶는다 → JA
#     따옴표를 공백으로 바꾸거나(seg_words) 모두 빼기(go_runner) 전에 부른다 — 값이 둘로 갈라지면 뒤쪽이 명령 자리로 밀려 '실행'으로 헛막힌다.
#     따옴표 문자열 안의 a='…' 은 건드리지 않고, $( · ` 가 든 값(명령 치환)은 그대로 둬 안의 명령을 계속 본다. 대입 뒤 단어를 건너뛰지는 않는다(X= node x.js 는 그대로 본다)
join_assign_vals() {
  JA=$1
  case "$JA" in *=*[\"\']*) ;; *) return 0 ;; esac
  local s=$1 out="" pre m v sep='[[:space:]{}()]' re_as="(^|[[:space:];&|(])(\\\$[A-Za-z_][A-Za-z0-9_:]*[[:space:]]*=[[:space:]]*|[A-Za-z_][A-Za-z0-9_]*=)(('[^']*'|\"[^\"]*\")+)|'[^']*'|\"[^\"]*\""
  while [[ $s =~ $re_as ]]; do
    m=${BASH_REMATCH[0]}; v=${BASH_REMATCH[3]}; pre=${s%%"$m"*}; s=${s#*"$m"}
    if [ -n "${BASH_REMATCH[2]}" ] && { [ -n "${BASH_REMATCH[1]}" ] || [ -z "$out$pre" ]; } && [[ $v != *'$('* && $v != *'`'* ]]; then
      v=${v//\'/}; v=${v//\"/}; v=${v//$sep/$PH}
      m="${BASH_REMATCH[1]}${BASH_REMATCH[2]}$v"
    fi
    out="$out$pre$m"
  done
  JA="$out$s"
}
# 명령 조각 하나를 단어로 나누고(따옴표·괄호는 지움) 앞에 붙은 래퍼(sudo·env·nohup·xargs·if/then·eval·corepack·cmd /c·powershell -c·bash -c …)를 건너뛴다
# → SW(단어 배열), SI(명령 이름 위치), SCMD(명령 이름: 경로·.exe 뗌), INCMD(cmd /c 안), XARGS(xargs 로 받음)
seg_words() {
  local s=$1 n re_cmdopt='^/{1,2}[a-z](:[a-z]+)?$' re_shc='^-[a-z]*c[a-z]*$'
  join_assign_vals "$s"; s=$JA   # #7: 따옴표 대입 값은 따옴표를 공백으로 바꾸기 전에 한 단어로(아래 join_assign_vals)
  s=${s//\"/ }; s=${s//\'/ }; s=${s//\{/ }; s=${s//\}/ }; s=${s//)/ }; s=${s//(/ }
  set -f; SW=($s); set +f
  n=${#SW[@]}; SI=0; INCMD=0; XARGS=0; LASTWRAP=""
  while [ "$SI" -lt "$n" ]; do
    case "${SW[$SI]}" in env|nice|stdbuf|timeout|xargs|cmd|cmd.exe|powershell|pwsh|bash|sh|nohup|command|exec|builtin|sudo|time) LASTWRAP=${SW[$SI]} ;; esac
    case "${SW[$SI]}" in
      sudo|doas|nohup|command|exec|builtin|time|'!'|if|then|else|elif|do|while|until|'&'|eval|corepack) SI=$((SI + 1)) ;;   # eval "…"·corepack pnpm … 는 안의 명령으로 본다
      -*) break ;;
      *=*) SI=$((SI + 1)) ;;
      env|nice|stdbuf|timeout|xargs)
        [ "${SW[$SI]}" = xargs ] && XARGS=1
        SI=$((SI + 1))
        while [ "$SI" -lt "$n" ]; do
          case "${SW[$SI]}" in
            -I|-n|-P|-L|-d|-s|-E|-u|-S|-a|-C|--delimiter|--max-args|--max-procs|--replace|--unset|--signal|--kill-after|--chdir|--arg-file) SI=$((SI + 2)) ;;
            -*|[0-9]*|*=*) SI=$((SI + 1)) ;;
            *) break ;;
          esac
        done ;;
      cmd|cmd.exe) INCMD=1; SI=$((SI + 1)); while [ "$SI" -lt "$n" ] && [[ ${SW[$SI]} =~ $re_cmdopt ]]; do SI=$((SI + 1)); done ;;
      powershell|powershell.exe|pwsh|pwsh.exe)
        SI=$((SI + 1))
        while [ "$SI" -lt "$n" ]; do
          case "${SW[$SI]}" in
            -executionpolicy|-ep|-ex|-exec|-windowstyle|-w|-inputformat|-outputformat|-configurationname|-workingdirectory|-wd) SI=$((SI + 2)) ;;
            -file|-f) SI=$((SI + 1)); break ;;
            -*) SI=$((SI + 1)) ;;
            *) break ;;
          esac
        done ;;
      bash|sh|zsh|dash|ksh|bash.exe|sh.exe)
        if [[ ${SW[$((SI + 1))]:-} =~ $re_shc ]]; then SI=$((SI + 2)); else break; fi ;;
      *) break ;;
    esac
  done
  SCMD=${SW[$SI]:-}; SCMD=${SCMD##*/}; SCMD=${SCMD##*"$BS"}; SCMD=${SCMD%.exe}
}

# 명령 조각 하나에서 "쓰기 대상" 자리의 단어를 뽑는다(동사 목록이 아니라 자리로 판단)
#  TGA: 모르는 명령은 인자 전부를 대상으로 본다(사람 전용 파일·기록 폴더 보호용)
#  TGK: 알려진 쓰기 명령만(플러그인 폴더·읽기 전용 단계 보호용 — 스크립트 실행 인자를 쓰기로 오해하지 않게)
#  공통: 리다이렉트(> >>) 대상, 쓰기 옵션 값(of= --output -o(curl·sort) -O(wget) -C(tar) -d(unzip) -o<폴더>(7z) --directory -t …)
#  읽기 명령(cat·grep·ls·echo …)의 인자는 대상이 아니다. 줄 머리: f=파일, d=폴더(그 안에 무엇이든 생길 수 있음)
#  복사·이동: CPDST(목적지), CPSRC(원본들, 줄바꿈 구분), SEGMV=1(이동·개명), SEGDEL=1(지우기 명령)
seg_targets() {
  local s=$1 i n t a nx cls="" sub="" wf=0 skip=0 nargs=0 last="" tarf=0 tarc=0
  local args=()
  TGA=""; TGK=""; CPDST=""; CPSRC=""; SEGMV=0; SEGDEL=0
  local re_rd='(^|[^=>-])[0-9&]?>>?[|]?[[:space:]]*([^[:space:]<>;&|]+)' rr=$s
  while [[ $rr =~ $re_rd ]]; do
    t=${BASH_REMATCH[2]}; rr=${rr#*"${BASH_REMATCH[0]}"}
    case "$t" in '&'*|'='*) continue ;; esac
    TGA="${TGA}f $t$NL"; TGK="${TGK}f $t$NL"
  done
  seg_words "$s"
  n=${#SW[@]}
  # 패키지 실행기(npx·pnpm exec/dlx·yarn·bunx·npm exec …)로 부른 포맷터·린터는 그 도구 이름으로 판정한다
  case "$SCMD" in
    npx|pnpx|bunx|pnpm|yarn|npm|bun)
      local j=$((SI + 1))
      case "$SCMD:${SW[$j]:-}" in pnpm:exec|pnpm:dlx|yarn:exec|yarn:dlx|npm:exec|npm:x|bun:x) j=$((j + 1)) ;; esac
      while [ "$j" -lt "$n" ]; do
        case "${SW[$j]}" in
          -p|--package|-c|--call) j=$((j + 2)) ;;
          --) j=$((j + 1)); break ;;
          -*) j=$((j + 1)) ;;
          *) break ;;
        esac
      done
      t=${SW[$j]:-}; t=${t##*/}; t=${t%%@*}
      case "$t" in prettier|eslint|biome|stylelint|standard|dprint|rome|oxlint) SI=$j; SCMD=$t ;; esac ;;
  esac
  for ((i = SI + 1; i < n; i++)); do
    a=${SW[$i]}
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case "$a" in
      *'>'|*'>|'|'<'|'<<'|'<<<'|[0-9]'<') skip=1; continue ;;
      *'>'*|'<'*) continue ;;
    esac
    args+=("$a")
  done
  case "$SCMD" in
    cat|bat|less|more|head|tail|nl|od|xxd|hexdump|strings|grep|egrep|fgrep|rg|ag|ack|cut|diff|cmp|comm|paste|column|wc|ls|dir|stat|file|test|'['|'[['|realpath|readlink|basename|dirname|du|df|md5sum|sha1sum|sha256sum|sha512sum|shasum|cksum|b2sum|echo|printf|type|get-content|gc|select-string|sls|findstr|test-path|get-item|gi|get-childitem|gci|write-host|write-output|jq|yq|which|where|cd|pushd|popd|set-location|pwd|true|false|:|tree|view|code|open|start|explorer|tr|fold|fmt|iconv|base64|awk|gawk|mawk|sed|perl|find|git|sort|tar|unzip|7z|7za|7zr|curl|wget|dd)
      cls=r ;;
    mv|move|move-item|mi|ren|rename|rni|rename-item) cls=mv; SEGMV=1 ;;
    cp|copy|copy-item|cpi|install|rsync|scp|xcopy|robocopy|ln|mklink) cls=cp ;;
    rm|unlink|rmdir|rd|del|erase|remove-item|ri|touch|mkdir|md|new-item|ni|truncate|shred|chmod|chown|chgrp|tee|patch|set-content|sc|add-content|ac|out-file|clear-content|clc|rimraf|trash|srm|tee-object)
      cls=w; case "$SCMD" in rm|unlink|rmdir|rd|del|erase|remove-item|ri|shred|rimraf|trash|srm) SEGDEL=1 ;; esac ;;
    prettier|eslint|biome|ruff|black|isort|gofmt|dprint|rubocop|autopep8|standard|stylelint|rome|oxlint) cls=fmt ;;
    *) cls=u ;;
  esac
  # 읽기 명령 중 옵션에 따라 쓰는 것
  case "$SCMD" in
    sed) for a in "${args[@]}"; do case "$a" in -i*|--in-place*|-[a-z]*i) cls=w ;; esac; done ;;
    perl) for a in "${args[@]}"; do case "$a" in -i*|-[a-z]*i[a-z]*) cls=w ;; esac; done ;;
    awk|gawk) for a in "${args[@]}"; do [ "$a" = inplace ] && cls=w; done ;;
    find) for a in "${args[@]}"; do case "$a" in -delete|-exec|-execdir|-ok|-okdir|-fprint|-fprint0|-fprintf|-fls) cls=u ;; esac; done ;;
    git)
      sub=${args[0]:-}
      case "$sub" in
        apply|am) cls=w ;;
        mv) cls=mv; SEGMV=1; args=("${args[@]:1}") ;;
        checkout|restore|rm|reset|clean|stash|merge|rebase|cherry-pick|revert|pull|switch|worktree|submodule) cls=u ;;
      esac ;;
  esac
  [ "$cls" = fmt ] && { for a in "${args[@]}"; do case "$a" in --write|-w|--fix|--apply|--apply-unsafe|format|fmt|-a|-A|--autocorrect|--autocorrect-all|-i|--in-place) wf=1 ;; esac; done; [ "$wf" = 1 ] && cls=w || cls=r; }
  SARGS=("${args[@]}")   # 0.4.0 WC: 리다이렉트를 뺀 인자(copy_dir_seg 가 옵션째 다시 본다)
  # 쓰기 옵션 값
  for ((i = 0; i < ${#args[@]}; i++)); do
    a=${args[$i]}; nx=${args[$((i + 1))]:-}
    case "$a" in
      of=*) TGA="${TGA}f ${a#of=}$NL"; TGK="${TGK}f ${a#of=}$NL" ;;
      --output=*|--output-file=*|--output-document=*|--target-directory=*) TGA="${TGA}f ${a#*=}$NL"; TGK="${TGK}f ${a#*=}$NL" ;;
      --output|--output-file|--output-document|-outfile|-filepath|-destination|--target-directory) [ -n "$nx" ] && { TGA="${TGA}f $nx$NL"; TGK="${TGK}f $nx$NL"; } ;;
      --directory=*|--output-dir=*|--directory-prefix=*) TGA="${TGA}d ${a#*=}$NL"; TGK="${TGK}d ${a#*=}$NL" ;;
      --directory|--output-dir|--directory-prefix) [ -n "$nx" ] && { TGA="${TGA}d $nx$NL"; TGK="${TGK}d $nx$NL"; } ;;
    esac
    case "$SCMD:$a" in
      curl:-o|sort:-o|wget:-O|cp:-t|mv:-t|install:-t|ln:-t) [ -n "$nx" ] && { TGA="${TGA}f $nx$NL"; TGK="${TGK}f $nx$NL"; } ;;
      tar:-C|unzip:-d|wget:-P) [ -n "$nx" ] && { TGA="${TGA}d $nx$NL"; TGK="${TGK}d $nx$NL"; } ;;
      7z:-o?*|7za:-o?*|7zr:-o?*) TGA="${TGA}d ${a#-o}$NL"; TGK="${TGK}d ${a#-o}$NL" ;;
    esac
  done
  # tar: 만들기(c·--create)면 -f 뒤 파일에 쓴다(-C 는 위에서 폴더로 본다)
  if [ "$SCMD" = tar ]; then
    local re_tcl='^-?[a-zA-Z]+$'
    for ((i = 0; i < ${#args[@]}; i++)); do
      a=${args[$i]}
      [ "$a" = "-C" ] && { i=$((i + 1)); continue; }
      [ "$a" = "--create" ] && tarc=1
      if [[ $a =~ $re_tcl ]] && { [ "$i" -eq 0 ] || [ "${a:0:1}" = "-" ]; }; then
        case "$a" in *c*) [ "$a" != "-C" ] && tarc=1 ;; esac
      fi
    done
    if [ "$tarc" = 1 ]; then
      for ((i = 0; i < ${#args[@]}; i++)); do
        a=${args[$i]}; nx=${args[$((i + 1))]:-}
        case "$a" in --file=*) TGA="${TGA}f ${a#*=}$NL"; TGK="${TGK}f ${a#*=}$NL"; continue ;; esac
        if { [ "$a" = "--file" ] || { [[ $a =~ $re_tcl ]] && [ "${a%f}" != "$a" ]; }; } && [ -n "$nx" ]; then TGA="${TGA}f $nx$NL"; TGK="${TGK}f $nx$NL"; fi
      done
    fi
  fi
  # 인자 자리
  local nonopt=()
  for a in "${args[@]}"; do case "$a" in -*|of=*|'') ;; *) nonopt+=("$a") ;; esac; done
  n=${#nonopt[@]}
  case "$cls" in
    w) for a in "${nonopt[@]}"; do TGA="${TGA}f $a$NL"; TGK="${TGK}f $a$NL"; done
       [ "$n" -eq 0 ] && [ "$wf" = 1 ] && TGK="${TGK}d .$NL" ;;
    u) for a in "${nonopt[@]}"; do TGA="${TGA}f $a$NL"; done ;;
    mv|cp)
      if [ "$n" -gt 0 ]; then
        last=${nonopt[$((n - 1))]}
        if [ "$SCMD" = rename ]; then
          for a in "${nonopt[@]}"; do TGA="${TGA}f $a$NL"; TGK="${TGK}f $a$NL"; CPSRC="$CPSRC$a$NL"; done
        else
          CPDST=$last; TGA="${TGA}f $last$NL"; TGK="${TGK}f $last$NL"
          for ((i = 0; i < n - 1; i++)); do
            CPSRC="$CPSRC${nonopt[$i]}$NL"
            [ "$cls" = mv ] && { TGA="${TGA}f ${nonopt[$i]}$NL"; TGK="${TGK}f ${nonopt[$i]}$NL"; }
          done
        fi
      fi ;;
  esac
  return 0
}

# 단어 하나를 절대경로로 → RP. 판정할 수 없으면(모르는 변수·명령 치환) 1
resolve_tok() {
  local t=$1
  t=${t//\"/}; t=${t//\'/}
  t=${t//'$HOME'/$HOME}; t=${t//'$PWD'/$cwd}; t=${t//'$CLAUDE_PROJECT_DIR'/$proj}
  case "$t" in ''|-*|*'`'*|*'$'*) return 1 ;; esac
  normpath "$t" "$cwd"; RP=$NP
  return 0
}
# 사람 전용 파일(허용 파일·승인 기록·.turn*·approved/)인가 — 절대경로
is_human_path() {
  case "${1##*/}" in .allow-*|approvals.log|.turn|.turn.*|.turn-*) return 0 ;; esac
  case "$1" in "$rdir"/approved|"$rdir"/approved/*) return 0 ;; esac
  return 1
}
# 기록 폴더 자체·그 상위 폴더, 또는 그 안의 STATE.md·APPROVALS.log·approved·.turn*·.allow-* 인가 — 절대경로
is_record_path() {
  case "$rdir/" in "$1"/*) return 0 ;; esac
  case "$1" in "$rdir"/state.md|"$rdir"/approvals.log|"$rdir"/approved|"$rdir"/approved/*|"$rdir"/.turn*|"$rdir"/.allow-*) return 0 ;; esac
  return 1
}
# 프로젝트·현재 폴더·홈 자신이나 그 상위, 드라이브·루트, .git 폴더인가 — 절대경로
is_big_path() {
  local x
  case "$1" in /|[A-Za-z]:|[A-Za-z]:/|*/.git) return 0 ;; esac
  for x in "$proj" "$cwd" "$HOMEC"; do
    [ -z "$x" ] && continue
    case "$x/" in "$1"/*) return 0 ;; esac
  done
  return 1
}
# 삭제 대상 단어가 큰 폴더(위)를 가리키는가: 끝의 /* 는 그 폴더 전체로 본다
big_tok() {
  local t=$1
  t=${t//\"/}; t=${t//\'/}
  case "$t" in '*'|'.*'|'./*'|'./.*'|'*.*') t=. ;; */'*'|*/'.*'|*/'*.*') t=${t%/*} ;; esac
  resolve_tok "$t" || return 1
  is_big_path "$RP"
}
# 와일드카드(* ? [ ])가 든 삭제 대상은 실제 폴더에서 펼쳐 기록 폴더·큰 폴더에 닿는지 본다(rm -rf doc?/refactor · docs/refacto[r]) → GD = rdoc|big
glob_del_tok() {
  GD=""
  case "$1" in *[\*\?\[]*) ;; *) return 1 ;; esac
  local t=${1//\"/} f n=0 IFS=$NL
  t=${t//\'/}
  case "$t" in ''|-*|*'$'*|*'`'*) return 1 ;; esac
  case "$t" in /*|[A-Za-z]:/*) ;; "~/"*) t="$HOME/${t#\~/}" ;; *) t="$cwd/$t" ;; esac
  for f in $t; do
    [ -e "$f" ] || continue
    normpath "$f" /
    is_record_path "$NP" && { GD=rdoc; return 0; }
    is_big_path "$NP" && { GD=big; return 0; }
    n=$((n + 1)); [ "$n" -ge 500 ] && break
  done
  return 1
}

MSG_RM_BIG="rm -r 로 프로젝트·홈·저장소·리팩토링 기록 전체를 지우는 명령은 막혀 있습니다."
MSG_RM_HINT="지울 폴더를 정확히 지정하고, 큰 삭제는 사람이 직접 하세요."
# find 로 지우는데 시작 폴더가 큰 폴더이고 이름·경로 조건이 없는가(find . -delete, find ~ -exec rm -rf {} +)
find_del_big() {
  seg_words "$1"
  local n=${#SW[@]} i a del=0 filt=0 starts=() st=1
  for ((i = SI + 1; i < n; i++)); do
    a=${SW[$i]}
    if [ "$st" = 1 ]; then case "$a" in -*|'!'|'\('|'\)') st=0 ;; *) starts+=("$a"); continue ;; esac; fi
    case "$a" in
      -delete) del=1 ;;
      -exec|-execdir|-ok|-okdir) case "${SW[$((i + 1))]:-}" in rm|*/rm|rmdir|rimraf|remove-item|ri) del=1 ;; esac ;;
      -name|-iname|-path|-ipath|-wholename|-iwholename|-regex|-iregex|-newer|-mtime|-mmin|-atime|-amin|-ctime|-cmin|-size|-user|-group|-perm|-links|-samefile|-inum|-lname|-ilname|-empty) filt=1 ;;
    esac
  done
  [ "$del" = 1 ] && [ "$filt" = 0 ] || return 1
  [ "${#starts[@]}" -eq 0 ] && starts=(.)
  for a in "${starts[@]}"; do big_tok "$a" && return 0; done
  return 1
}
# 재귀 삭제(rm -r·rimraf·Remove-Item -Recurse·rd /s·del /s·find -delete·xargs rm -r)가 큰 폴더를 겨냥하는가
del_seg() { # $1 조각 $2 파이프 앞 조각
  seg_words "$1"
  local n=${#SW[@]} i a rec=0 c=$SCMD tg=() ps=0 re_psr='^-r(e(c(u(r(s(e)?)?)?)?)?)?$' re_shr='^-[a-zA-Z]*[rR][a-zA-Z]*$'
  # npx rimraf . 처럼 패키지 실행기로 부른 삭제 도구
  case "$c" in
    npx|pnpx|bunx) SI=$((SI + 1)); while [ "$SI" -lt "$n" ] && [[ ${SW[$SI]} == -* ]]; do SI=$((SI + 1)); done; c=${SW[$SI]:-}; c=${c%@*} ;;
  esac
  case "$c" in
    rm|rimraf|remove-item|ri|rmdir|rd|del|erase|trash) ;;
    find) find_del_big "$1" && block "$MSG_RM_BIG" "$MSG_RM_HINT"; return 0 ;;
    *) return 0 ;;
  esac
  { [ "$tool" = "PowerShell" ] || [ "$c" = remove-item ] || [ "$c" = ri ]; } && ps=1
  [ "$c" = rimraf ] && rec=1
  for ((i = SI + 1; i < n; i++)); do
    a=${SW[$i]}
    case "$a" in
      --recursive) rec=1 ;;
      /s|//s|/q|//q|/f|//f|/a|//a|/p|//p)
        case "$c" in rd|rmdir|del|erase) case "$a" in */s) rec=1 ;; esac; continue ;; esac
        tg+=("$a") ;;
      -*)
        if [ "$ps" = 1 ]; then [[ $a =~ $re_psr ]] && rec=1; else [[ $a =~ $re_shr ]] && rec=1; fi ;;
      *) tg+=("$a") ;;
    esac
  done
  [ "$rec" = 1 ] || return 0
  local msg=$MSG_RM_BIG
  [ "$ps" = 1 ] && msg="Remove-Item -Recurse 로 프로젝트·홈 전체를 지우는 명령은 막혀 있습니다."
  case "$c" in rd|rmdir|del|erase) [ "$ps" = 0 ] && msg="폴더 통째 삭제(rd /s·del /s)로 프로젝트·홈 전체를 지우는 명령은 막혀 있습니다." ;; esac
  for a in "${tg[@]}"; do
    big_tok "$a" && block "$msg" "$MSG_RM_HINT"
    resolve_tok "$a" && is_record_path "$RP" && block "$MSG_RDOC" "$MSG_RDOC2"   # cd docs && rm -rf refactor 처럼 경로로 따진 기록 폴더
    if glob_del_tok "$a"; then [ "$GD" = rdoc ] && block "$MSG_RDOC" "$MSG_RDOC2"; block "$msg" "$MSG_RM_HINT"; fi   # rm -rf doc?/refactor · docs/refacto[r]
  done
  # xargs rm -r: 파이프 앞 명령이 큰 폴더를 넘기는가(pwd, echo ~, ls -d .., 조건 없는 find .)
  if [ "${#tg[@]}" -eq 0 ] && [ "$XARGS" = 1 ] && [ -n "${2:-}" ]; then
    seg_words "$2"
    case "$SCMD" in
      pwd|get-location) block "$msg" "$MSG_RM_HINT" ;;
      find)
        local fl=0; for a in "${SW[@]}"; do case "$a" in -name|-iname|-path|-ipath|-regex|-iregex|-newer|-mtime|-mmin|-size|-empty|-wholename) fl=1 ;; esac; done
        if [ "$fl" = 0 ]; then
          for ((i = SI + 1; i < ${#SW[@]}; i++)); do a=${SW[$i]}; case "$a" in -*) break ;; esac; big_tok "$a" && block "$msg" "$MSG_RM_HINT"; done
          [ "$((SI + 1))" -ge "${#SW[@]}" ] && block "$msg" "$MSG_RM_HINT"
        fi ;;
      *) for ((i = SI + 1; i < ${#SW[@]}; i++)); do a=${SW[$i]}; case "$a" in -*) continue ;; esac; big_tok "$a" && block "$msg" "$MSG_RM_HINT"; done ;;
    esac
  fi
  return 0
}
del_scan() { cd_all del_scan1 "$1"; }
del_scan1() { # $1 명령(lq) — && || ; 로 나눈 명령마다 파이프 조각을 차례로 본다(cd·pushd 를 만나면 뒤 조각의 상대경로는 그 폴더 기준)
  local s=$1 cl pl seg prev CWD_BASE=$cwd CD_PREV=$cwd
  s=${s//&&/$NL}; s=${s//||/$NL}; s=${s//;/$NL}; s=${s//\`/$NL}
  while [ -n "$s" ]; do
    cl=${s%%"$NL"*}; if [ "$cl" = "$s" ]; then s=""; else s=${s#*"$NL"}; fi
    cd_seg "$cl" && continue
    prev=""; pl=$cl
    while [ -n "$pl" ]; do
      seg=${pl%%|*}; if [ "$seg" = "$pl" ]; then pl=""; else pl=${pl#*|}; fi
      case "$seg" in *rm*|*rimraf*|*remove-item*|*ri\ *|*rd\ *|*rmdir*|*del\ *|*erase*|*find*|*trash*|*RM*|*Rm*|*Remove*|*RD*|*Rd*|*DEL*|*Del*) del_seg "$seg" "$prev" ;; esac
      prev=$seg
    done
  done
  cwd=$CWD_BASE
}
# 인터프리터 코드로 큰 폴더를 통째로 지우는가(shutil.rmtree('.'), fs.rmSync(process.cwd(),{recursive:true}) …)
interp_del_big() {
  local rest=$1 arg lit re='(rmtree|rmsync|rmdirsync|fs[.]rm|promises[.]rm|rimraf[.]?sync|rimraf|removeall|remove_dir_all|rm_rf|rm_r|directory\]::delete|deletedirectory)[[:space:]]*[(][[:space:]]*([^,)]*[)]?)'
  local re_lit="[\"']([^\"']*)[\"']" re_dyn='getcwd|[.]cwd[(]|home[(]|expanduser|environ|process[.]env|__dirname|userprofile|homedir'
  while [[ $rest =~ $re ]]; do
    arg=${BASH_REMATCH[2]}; rest=${rest#*"${BASH_REMATCH[0]}"}
    if [[ $arg =~ $re_dyn ]]; then return 0; fi
    if [[ $arg =~ $re_lit ]]; then lit=${BASH_REMATCH[1]}; [ -z "$lit" ] && lit=.; big_tok "$lit" && return 0; fi
  done
  return 1
}

# 변수 이름 판정 ────────────────────────────────────────────────────────────
# 값을 봐도 되는 흔한 환경변수(사장님 결정 목록)
safe_env_name() {
  case "$1" in PATH|HOME|USER|USERNAME|SHELL|LANG|LC_*|TERM|PWD|OLDPWD|TMPDIR|TEMP|TMP|NODE_ENV|CI|EDITOR|PAGER|HOSTNAME|OS|OSTYPE|BASH_VERSION|SHLVL|_) return 0 ;; esac
  return 1
}
# 비밀값이 든 이름인가 — 부분 글자가 아니라 _ 로 나눈 단어로 본다($MONKEY 는 아님, $API_KEY·$MONKEY_KEY 는 비밀).
# URL·URI 는 DB·연결 계열(DATABASE·REDIS·MONGO·DSN·CONNECTION …)과 같이 있을 때만 비밀로 본다($VERCEL_URL 은 아님)
sens_name() {
  safe_env_name "$1" && return 1
  local n=${1//-/_} c url=0 db=0 IFS=_
  set -f
  for c in $n; do
    case "$c" in
      key|keys|apikey|secretkey|accesskey|privatekey|secret|secrets|clientsecret|token|tokens|authtoken|accesstoken|refreshtoken|apitoken|idtoken|pass|passwd|password|passwords|passphrase|pwd|private|credential|credentials|cred|creds|dsn|cookie|cookies|session|sessions|jwt|bearer|auth|salt|signature)
        set +f; return 0 ;;
      url|uri|urls|string|str) url=1 ;;
      database|db|redis|mongo|mongodb|postgres|postgresql|pg|mysql|mariadb|conn|connection|connectionstring) db=1 ;;
    esac
  done
  set +f
  [ "$url" = 1 ] && [ "$db" = 1 ] && return 0
  case "$1" in *[Cc][Oo][Nn][Nn][Ee][Cc][Tt][Ii][Oo][Nn]*) return 0 ;; esac
  return 1
}
# 문자열 속 $NAME·${NAME}·$env:NAME 중 비밀값 이름이 있는가
vars_sensitive() {
  local rest=$1 re='[$]([{]|env:)?([A-Za-z_][A-Za-z0-9_]*)'
  while [[ $rest =~ $re ]]; do
    rest=${rest#*"${BASH_REMATCH[0]}"}
    sens_name "${BASH_REMATCH[2]}" && return 0
  done
  return 1
}
# 환경변수 전체를 찍는 명령 조각인가(env, printenv, set, export -p, declare, (set), env -0, command env, bash -c env, cmd /c set …)
# 안전 이름만 지정하면(printenv PATH, declare -p HOME) 통과
env_dump_seg() {
  seg_words "$1"
  local n=${#SW[@]} i=$SI c=$SCMD a opt=0 names=0 hadopt=0
  # env 는 래퍼로 벗겨지므로(env FOO=1 node …) 뒤에 명령이 없으면 덤프다(env, env -0, command env, bash -c env)
  if [ "$i" -ge "$n" ]; then [ "$LASTWRAP" = env ] && return 0; return 1; fi
  case "$c" in
    printenv)
      i=$((i + 1)); for ((; i < n; i++)); do a=${SW[$i]}; case "$a" in -*) continue ;; esac; names=1; safe_env_name "$a" || return 0; done
      [ "$names" = 0 ] && return 0; return 1 ;;
    set)
      [ $((n - i)) -eq 1 ] && return 0
      if [ "$INCMD" = 1 ]; then a=${SW[$((i + 1))]}; safe_env_name "$a" || return 0; fi
      return 1 ;;
    export|declare|typeset|local|readonly)
      i=$((i + 1))
      for ((; i < n; i++)); do
        a=${SW[$i]}
        case "$a" in
          -*) hadopt=1; case "$c:$a" in export:-p|*:-*p*|*:-*x*) opt=1 ;; esac ;;
          *=*) return 1 ;;
          *) names=1; safe_env_name "$a" || { [ "$opt" = 1 ] && return 0; } ;;
        esac
      done
      case "$c" in local|readonly) return 1 ;; esac
      [ "$names" = 0 ] && { [ "$hadopt" = 0 ] || [ "$opt" = 1 ]; } && return 0
      return 1 ;;
  esac
  return 1
}
# 코드 한 줄(node -e·python -c …)이 보는 환경변수가 모두 안전 이름인가(process.env.NODE_ENV 등). 통째(process.env)·dotenv 는 아니다
env_refs_safe() {
  local rest=$1 re='(process[.]env|os[.]environ|import[.]meta[.]env|deno[.]env[.]get|os[.]getenv|getenv|env)((\.|\[|[{]|\.get\(|\()[[:space:]]*["'"'"']?([A-Za-z_][A-Za-z0-9_]*))?' any=0 nm
  has "$rest" 'dotenv|load_dotenv' && return 1
  while [[ $rest =~ $re ]]; do
    rest=${rest#*"${BASH_REMATCH[0]}"}
    nm=${BASH_REMATCH[4]}
    case "${BASH_REMATCH[1]}" in env) [ -z "$nm" ] && continue ;; esac
    [ -z "$nm" ] && return 1
    case "$nm" in get|keys|items|values|copy|tostring|toobject) return 1 ;; esac
    safe_env_name "$nm" || return 1
    any=1
  done
  [ "$any" = 1 ]
}

MSG_RDOC="리팩토링 기록(docs/refactor)은 지우지 않습니다."
MSG_RDOC2="다시 하려면 /refactor:go 다시 <단계> 를 쓰세요(이전 파일은 *-prev.md로 남음)."
# 셸 명령의 쓰기 대상(목적지)으로 판정: 사람 전용 파일, 기록 폴더 이동·개명, 플러그인 폴더, 읽기 전용 단계의 프로젝트 파일
shell_targets() { cd_all shell_targets1 "$1"; }
shell_targets1() { # $1 판정용 명령(lq, $PWD·$HOME 정리됨) — cd·pushd 를 만나면 뒤 조각의 상대경로는 그 폴더 기준
  local s=$1 seg tl line kind t b src CWD_BASE=$cwd CD_PREV=$cwd
  s=${s//&&/$NL}; s=${s//||/$NL}; s=${s//;/$NL}; s=${s//|/$NL}; s=${s//\`/$NL}
  while [ -n "$s" ]; do
    seg=${s%%"$NL"*}; if [ "$seg" = "$s" ]; then s=""; else s=${s#*"$NL"}; fi
    case "$seg" in *[![:space:]]*) ;; *) continue ;; esac
    cd_seg "$seg" && continue
    seg_targets "$seg"
    tl=$TGA
    while [ -n "$tl" ]; do
      line=${tl%%"$NL"*}; tl=${tl#*"$NL"}
      kind=${line%% *}; t=${line#* }
      resolve_tok "$t" || continue
      is_human_path "$RP" && block "허용 파일(.allow-*)·승인 기록(APPROVALS.log)·.turn·approved/ 는 사람과 플러그인만 만들고 지우고 바꿉니다." "$MSG_HUMAN"
      if [ "$kind" = d ]; then
        case "$RP" in "$rdir"|"$rdir"/*) block "리팩토링 기록 폴더(docs/refactor)에 압축을 풀거나 파일을 한꺼번에 넣지 않습니다(사람 전용 파일을 덮어쓸 수 있음)." "$MSG_HUMAN" ;; esac
      fi
      if [ "$SEGMV" = 1 ] && [ "$t" != "$CPDST" ] && is_record_path "$RP"; then block "$MSG_RDOC" "$MSG_RDOC2"; fi
      # 리팩토링 진행 중: 기록 폴더 안 파일 지우기(cd docs/refactor && rm STATE.md 처럼 경로로 따진 것)
      if [ "$SEGDEL" = 1 ] && [ "$refactor_on" = 1 ]; then case "$RP" in "$rdir"|"$rdir"/*) block "$MSG_RDOC" "$MSG_RDOC2" ;; esac; fi
    done
    # 기록 폴더로 복사·이동해 들어가면서 사람 전용 파일 이름을 쓰는가(cp /tmp/APPROVALS.log docs/refactor/)
    if [ -n "$CPDST" ] && resolve_tok "$CPDST"; then
      case "$RP" in
        "$rdir")
          tl=$CPSRC
          while [ -n "$tl" ]; do
            src=${tl%%"$NL"*}; tl=${tl#*"$NL"}; src=${src%/}; b=${src##*/}
            case "$b" in .allow-*|approvals.log|.turn|.turn.*|.turn-*|approved) block "허용 파일(.allow-*)·승인 기록(APPROVALS.log)·.turn·approved/ 는 사람과 플러그인만 만들고 지우고 바꿉니다." "$MSG_HUMAN" ;; esac
          done ;;
      esac
    fi
    tl=$TGK
    while [ -n "$tl" ]; do
      line=${tl%%"$NL"*}; tl=${tl#*"$NL"}
      t=${line#* }
      resolve_tok "$t" || continue
      if [ -n "$plugroot" ]; then
        case "$RP" in "$plugroot"|"$plugroot"/*) block "플러그인 폴더는 고치지 않습니다." "플러그인 수정은 사람이 원본 저장소에서 합니다." ;; esac
      fi
      # 프로젝트 폴더 자체(npx eslint . --fix, 대상 없는 --write)도 그 안 전부를 바꾸는 것이다
      if [ "$fence" = 1 ] && { [ "$RP" = "$proj" ] || under_proj "$RP"; } && ! under_refactor_docs "$RP"; then
        block "$fence_why docs/refactor 밖의 파일을 셸 명령으로 바꾸지 않습니다." "발견한 문제는 보고서와 계획서 후보로만 적으세요. 임시 파일은 /tmp 나 \$TMPDIR 에 쓰세요. (리팩토링과 상관없는 평소 작업이면 사용자에게 새 대화에서 하자고 안내하세요.)"
      fi
    done
  done
  cwd=$CWD_BASE
}
# 0.4.0 WC: 기록 폴더(docs/refactor) 자체나 그 상위 폴더(docs · 프로젝트 · 절대경로)로 폴더째·와일드카드 복사·옮기기, 거기에 압축 풀기,
#   그 폴더를 잇거나 그 자리에 링크 만들기 → 막는다. 이름을 적은 파일 복사·기록 폴더 밖·기록 폴더에서 밖으로는 그대로 통과.
#   (지금까지는 목적지가 기록 폴더 자체일 때 원본 이름만 봐서 cp -r /tmp/d/. docs/refactor · cp /tmp/d/.t* docs/refactor/ · cp -r /tmp/refactor docs/ 가 지나갔다)
RE_UNPACK_ENV='(^|[^A-Za-z0-9_])(TAR_OPTIONS|UNZIPOPT|UNZIP)([^A-Za-z0-9_]|$)'   # FC4 K2
MSG_CPDIR="폴더째·와일드카드 복사는 기록 폴더 안의 허락 파일·승인 기록을 덮어쓸 수 있어 막습니다 — 파일 이름을 하나씩 적어 복사하세요."
MSG_UNPACK="리팩토링 기록 폴더(docs/refactor)에 압축을 풀거나 파일을 한꺼번에 넣지 않습니다(사람 전용 파일을 덮어쓸 수 있음)."
MSG_LINK="기록 폴더(docs/refactor)나 그 상위 폴더를 잇거나 그 자리에 링크를 만들면 허락 파일·승인 기록을 다른 이름으로 바꿀 수 있어 막습니다 — 링크 없이 파일을 하나씩 다루세요."
# 단어가 기록 폴더 자체나 그 상위 폴더인가($2 = in 이면 기록 폴더 안도, rec 이면 그 안의 STATE.md·APPROVALS.log·approved·.turn*·.allow-* 도).
#   판정할 수 없는 단어(모르는 변수)는 끝이 docs·docs/refactor 인 꼴만
#   경로 비교는 다른 판정처럼 대소문자를 가리지 않는다(copy_dir_seg1 이 옵션 글자 때문에 꺼 둔 nocasematch 를 여기서만 켠다)
cpd_hit() { shopt -s nocasematch; cpd_hit1 "$@"; local r=$?; shopt -u nocasematch; return $r; }
cpd_hit1() {
  local t=${1//\"/}
  t=${t//\'/}
  if resolve_tok "$t"; then
    case "$RP" in ''|/|[A-Za-z]:|[A-Za-z]:/) return 0 ;; esac   # 루트·드라이브
    case "$rdir/" in "$RP"/*) return 0 ;; esac
    if [ "${2:-}" = in ]; then case "$RP" in "$rdir"/*) return 0 ;; esac; fi
    if [ "${2:-}" = rec ]; then { is_record_path "$RP" || is_human_path "$RP"; } && return 0; fi
    return 1
  fi
  t=${t//"$BS"/$SL}; t=${t%"${t##*[!/]}"}
  case "$t" in docs|*/docs|docs/refactor|*/docs/refactor) return 0 ;; esac
  return 1
}
# 목적지가 어디인가 → CW = self(기록 폴더 자체나 그 안) | up(그 상위·루트·드라이브) | no. 판정할 수 없는 단어는 끝이 docs/refactor 면 self, docs 면 up
#   up 이면 FIRST = 목적지에서 기록 폴더까지 남은 경로의 첫 칸(FC2 G2 — 프로젝트 상위면 프로젝트 이름, docs 면 refactor)
cpd_where() { shopt -s nocasematch; cpd_where1 "$1"; shopt -u nocasematch; }
cpd_where1() {
  local t=${1//\"/} rel
  CW=no; FIRST=""; t=${t//\'/}
  if resolve_tok "$t"; then
    case "$RP" in "$rdir"|"$rdir"/*) CW=self; return 0 ;; esac
    case "$RP" in ''|/) CW=up; rel=${rdir#/} ;;
      [A-Za-z]:|[A-Za-z]:/) CW=up; rel=${rdir#?:}; rel=${rel#/} ;;
      *) case "$rdir/" in "$RP"/*) CW=up; rel=${rdir#"$RP"/} ;; esac ;;
    esac
    [ "$CW" = up ] && FIRST=${rel%%/*}
    return 0
  fi
  t=${t//"$BS"/$SL}; t=${t%"${t##*[!/]}"}
  case "$t" in docs/refactor|*/docs/refactor) CW=self ;; docs|*/docs) CW=up; FIRST=refactor ;; esac
  return 0
}
# 원본 이름을 미리 알 수 없는가: 와일드카드·중괄호 · 변수·명령 치환 · 끝이 / 또는 /. · . 이나 ..
#   (FC F7: 변수가 든 경로라도 마지막 이름 조각이 보통 이름이고 허락 파일 꼴이 아니면 안다 — cp $HOME/notes.md docs/refactor/)
cpd_unknown() { shopt -s nocasematch; cpd_unknown1 "$1"; local r=$?; shopt -u nocasematch; return $r; }
cpd_unknown1() {
  local t=${1//\"/} b
  t=${t//\'/}; t=${t//"$BS"/$SL}
  case "$t" in *[\*\?\[\{]*|*/|*/.|*/..|.|..) return 0 ;; esac
  case "$t" in
    *'$'*|*'`'*)
      case "$t" in */*) ;; *) return 0 ;; esac
      b=${t##*/}
      case "$b" in ''|*'$'*|*'`'*|.allow-*|approvals.log|.turn|.turn.*|.turn-*|approved|state.md) return 0 ;; esac ;;
  esac
  return 1
}
# FC F7: 상위 폴더로 폴더째 복사할 때 막는 원본 — 모름(변수·명령 치환) · 끝이 / · /. · 와일드카드 · 이름이 refactor·docs
#   또는 목적지에서 기록 폴더까지의 첫 칸(FIRST — FC2 G2: cp -r /tmp/x/<프로젝트 이름> ..) · 대소문자 무시
cpd_upsrc() { shopt -s nocasematch; cpd_upsrc1 "$1"; local r=$?; shopt -u nocasematch; return $r; }
cpd_upsrc1() {
  local t=${1//\"/} b
  t=${t//\'/}; t=${t//"$BS"/$SL}
  case "$t" in *[\*\?\[\{]*|*'$'*|*'`'*|*/|*/.|*/..|.|..) return 0 ;; esac
  cpd_upname "$t"
}
# 원본 마지막 이름이 refactor·docs·FIRST 인가(nocasematch 켠 채로 부른다)
cpd_upname() {
  local b=${1%"${1##*[!/]}"}
  b=${b##*/}
  case "$b" in refactor|docs) return 0 ;; esac
  [ -n "${FIRST:-}" ] && [ "$b" = "$FIRST" ] && return 0
  [ -n "${FIRST:-}" ] && case "$b" in "$FIRST") return 0 ;; esac
  return 1
}
# 링크 원본: 지금 폴더 기준과 링크가 놓일 폴더($2) 기준 둘 다 풀어 하나라도 기록 폴더·그 상위·그 안의 사람 전용 파일이면 0
cpd_lnsrc() {
  cpd_hit "$1" rec && return 0
  [ -n "${2:-}" ] || return 1
  local c0=$cwd r=1
  cwd=$2; cpd_hit "$1" rec && r=0; cwd=$c0
  return $r
}
# 링크가 놓일 폴더: 목적지가 있는 폴더거나 끝이 / 면 그 폴더, 아니면 그 상위 → LDIR(판정할 수 없으면 빈 값)
cpd_linkdir() {
  LDIR=""
  local t=${1//\"/}
  t=${t//\'/}
  resolve_tok "$t" || return 0
  case "$t" in */) LDIR=$RP; return 0 ;; esac
  if [ -d "$RP" ]; then LDIR=$RP; else LDIR=${RP%/*}; [ -n "$LDIR" ] || LDIR=/; fi
}
# 조각 하나(seg_targets 를 부른 뒤 — SCMD·SARGS·XARGS·cwd)를 본다. 옵션 글자는 대소문자를 가린다(cp -t 와 -T) — 명령 이름은 먼저 가린다
copy_dir_seg() {
  local k=""
  case "$SCMD" in
    cp|install|scp) k=cp ;;
    mv) k=mv ;;
    rsync) k=rsync ;;
    copy-item|cpi|copy) k=psc ;;
    move-item|mi|move) k=psm ;;
    xcopy|robocopy) k=win ;;
    ln) k=ln ;;
    mklink) k=mklink ;;
    tar|bsdtar) k=tar ;;
    unzip) k=unzip ;;
    7z|7za|7zr) k=7z ;;
    expand-archive) k=xa ;;
    new-item|ni) k=ni ;;
    *) return 0 ;;
  esac
  local wk=0 rec=0 lnk=0 tt=0 bk=0 sc=$SCMD envx=0 j
  case "$SCMD" in copy|move|xcopy|robocopy) wk=1 ;; esac
  # FC3 H3: 같은 조각에 붙인 대입(TAR_OPTIONS=… tar · env UNZIP=… unzip)은 풀기 옵션을 몰래 더한다 — seg_words 가 명령 앞(SI 전)에 남긴 낱말
  for ((j = 0; j < SI; j++)); do case "${SW[$j]}" in TAR_OPTIONS=*|UNZIP=*|UNZIPOPT=*) envx=1 ;; esac; done
  case "$SCMD" in robocopy|rsync) rec=1 ;; esac
  shopt -u nocasematch
  copy_dir_seg1 "$k"
  shopt -s nocasematch
  return 0
}
# 짧은 옵션 묶음(-rt X · -tX · -S .bak)에서 값을 받는 글자($2 목록) 뒤를 값으로 → OV(값) · OVN=1(값이 다음 낱말) · OL(값 앞 글자들)
cpd_short() {
  local o=${1#-} c
  OL=""; OV=""; OVN=0; OC=""
  while [ -n "$o" ]; do
    c=${o:0:1}; o=${o:1}
    case "$2" in *"$c"*) OC=$c; if [ -n "$o" ]; then OV=$o; else OVN=1; fi; return 0 ;; esac
    OL="$OL$c"
  done
}
# 긴 옵션 이름($1, -- 뗀 = 앞)이 $2 의 줄임인가(--targ → target-directory)
cpd_long() { [ -n "$1" ] && case "$2" in "$1"*) return 0 ;; esac; return 1; }
copy_dir_seg1() {
  local k=$1 i a nx skip=0 tdir="" pos=() srcs=() dirs=() ext=0 out=0 ab=0 n d s j nm vl="" itype="" npath="" nname="" ltgt=() tvl=gCTXfFLbHVIKN tq="" o c cfail=0
  case "$sc" in cp|mv|ln) vl=tS ;; install) vl=tSmog ;; scp) vl=PiFoclJS ;; rsync) vl=efTBM ;; bsdtar) tvl="${tvl}s" ;; esac
  for ((i = 0; i < ${#SARGS[@]}; i++)); do
    a=${SARGS[$i]}; nx=${SARGS[$((i + 1))]:-}
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case "$a" in '\'|'+') continue ;; esac   # find -exec 끝(\; · +) (FC F4 · 배경 실행 & 는 copy_dir_targets1 이 조각 경계로 — FC F1)
    case "$k" in
      cp|mv|ln|rsync)
        case "$a" in
          --*)
            nm=${a#--}; nm=${nm%%=*}
            if [ "$k" != rsync ] && cpd_long "$nm" target-directory; then
              case "$a" in *=*) tdir=${a#*=} ;; *) tdir=$nx; skip=1 ;; esac
            else
              case "$a" in --rec*|--ar*) [ "$k" = cp ] && rec=1 ;; --l|--li*|--sy*) [ "$sc" = cp ] && lnk=1 ;; --no-t*) tt=1 ;; --b|--ba*) bk=1 ;; esac
              case "$a" in *=*) ;; *)
                case "$k:$nm" in
                  rsync:exclude|rsync:include|rsync:filter|rsync:rsh|rsync:backup-dir|rsync:log-file|rsync:exclude-from|rsync:include-from|rsync:files-from|rsync:partial-dir|rsync:temp-dir|rsync:compare-dest|rsync:copy-dest|rsync:link-dest|rsync:chmod|rsync:chown|rsync:block-size|rsync:max-size|rsync:min-size|rsync:timeout|rsync:port|rsync:password-file|rsync:out-format|rsync:suffix|rsync:remote-option|rsync:rsync-path|rsync:log-file-format|rsync:usermap|rsync:groupmap|rsync:checksum-choice|rsync:compress-choice)
                    skip=1 ;;
                  *) { cpd_long "$nm" suffix && [ "${#nm}" -ge 2 ]; } && skip=1
                     [ "$sc" = install ] && { cpd_long "$nm" mode || cpd_long "$nm" owner || cpd_long "$nm" group; } && skip=1 ;;
                esac ;;
              esac
            fi ;;
          -[A-Za-z]*)
            cpd_short "$a" "$vl"
            [ "$k" = cp ] && case "$OL" in *r*|*R*|*a*) rec=1 ;; esac
            [ "$sc" = cp ] && case "$OL" in *l*|*s*) lnk=1 ;; esac
            [ "$k" != rsync ] && case "$OL" in *T*) tt=1 ;; esac   # FC2 G1: -T = 원본 안쪽을 목적지에 붓는다
            [ "$sc" = mv ] && case "$OL" in *b*) bk=1 ;; esac      # FC2 G6: mv -b = 있던 것을 백업하고 갈아 끼운다
            if [ -n "$OC" ]; then
              if [ "$OC" = t ] && [ "$k" != rsync ]; then
                if [ "$OVN" = 1 ]; then tdir=$nx; skip=1; else tdir=$OV; fi
              elif [ "$OVN" = 1 ]; then skip=1
              fi
            fi ;;
          -*) ;;
          *) pos+=("$a") ;;
        esac ;;
      psc|psm)
        case "$a" in
          -[Rr]|-[Rr][Ee]*) rec=1 ;;
          -[Dd][Ee][Ss]*) tdir=$nx; skip=1 ;;
          -[Pp][Aa][Tt]*|-[Ll][Ii]*) srcs+=("$nx"); skip=1 ;;
          /[A-Za-z]*/*) pos+=("$a") ;;
          /[A-Za-z]*) [ "$wk" = 1 ] || pos+=("$a") ;;
          -*) ;;
          *) pos+=("$a") ;;
        esac ;;
      win|mklink)
        case "$a" in
          /[A-Za-z]*/*) pos+=("$a") ;;
          /[SsEe]) rec=1 ;;
          /[A-Za-z]*) ;;
          -*) ;;
          *) pos+=("$a") ;;
        esac ;;
      tar)
        case "$a" in
          --extract|--get|--extr*) ext=1 ;;
          --ab|--abs*|--insecure) ab=1 ;;   # 보안 검사(10-06): 절대경로·.. 를 그대로 풀면 풀 곳과 상관없이 어디든 씀(GNU 긴 옵션 줄임 · bsdtar --insecure = -P)
          --to-stdout|--to-command*) out=1 ;;
          --directory=*) dirs+=("${a#*=}") ;;
          --directory) dirs+=("$nx"); skip=1 ;;
          --*) ;;
          -[A-Za-z]*)   # FC3 H1·H2: 앞 글자부터 보다가 값 받는 글자에서 멈춘다(-xPfOevil.tar 의 O 는 파일 이름) · C 의 값은 풀 곳
            cpd_short "$a" "$tvl"
            # FC4 K1: x·P 는 묶음 어디에 있든(맥 bsdtar 의 값 글자는 GNU 와 달라 -xHPf 의 P 를 놓칠 수 있음 — 파일 이름 속 P 헛막힘은 받아들임) ·
            #   O 는 값 글자 앞부분만(파일 이름의 O 로 판정을 건너뛰지 않게) · C 가 있는데 풀 곳으로 못 잡았으면 애매 → 막음(cfail)
            case "$a" in *x*) ext=1 ;; esac; case "$OL" in *O*) out=1 ;; esac; case "$a" in *P*) ab=1 ;; esac
            case "$a" in *C*) [ "$OC" = C ] || cfail=1 ;; esac
            if [ -n "$OC" ]; then
              if [ "$OVN" = 1 ]; then [ "$OC" = C ] && dirs+=("$nx"); skip=1
              else [ "$OC" = C ] && dirs+=("$OV"); fi
            fi ;;
          *)
            if [ "$i" -eq 0 ]; then
              case "$a" in
                *[!A-Za-z]*) ;;
                *)   # 옛꼴 첫 낱말(xfC): 글자는 모두 옵션 · 값 받는 글자마다 뒤 위치 인자를 차례로 소비(tq)
                  case "$a" in *x*) ext=1 ;; esac; case "$a" in *O*) out=1 ;; esac; case "$a" in *P*) ab=1 ;; esac
                  o=$a; while [ -n "$o" ]; do c=${o:0:1}; o=${o:1}; case "$tvl" in *"$c"*) tq="$tq$c" ;; esac; done ;;
              esac
            elif [ -n "$tq" ]; then
              c=${tq:0:1}; tq=${tq:1}; [ "$c" = C ] && dirs+=("$a")
            fi ;;
        esac ;;
      unzip)
        ext=1
        case "$a" in
          -d) dirs+=("$nx"); skip=1 ;;
          -d?*) dirs+=("${a#-d}") ;;
          --*) ;;
          -*:*) ab=1 ;;   # unzip -: = ../ 를 그대로 풂
          -[A-Za-z]*) case "$a" in *[lvtzZpc]*) out=1 ;; esac ;;
        esac ;;
      7z)
        case "$a" in
          -o?*) dirs+=("${a#-o}") ;;
          -so) out=1 ;;
          -spf*) ab=1 ;;   # 7z -spf = 절대경로 그대로
          -*) ;;
          *) [ "${#pos[@]}" -eq 0 ] && case "$a" in x|e) ext=1 ;; esac; pos+=("$a") ;;
        esac ;;
      xa)   # FC F6: Expand-Archive [-Path] <zip> [-DestinationPath] <폴더> — 풀 곳이 없으면 지금 폴더
        ext=1
        case "$a" in
          -[Dd]*) dirs+=("$nx"); skip=1 ;;
          -[Pp][Aa]*|-[Ll][Ii]*) skip=1; pos+=("$nx") ;;
          -*) ;;
          *) pos+=("$a") ;;
        esac ;;
      ni)   # FC F6: New-Item -ItemType SymbolicLink|Junction|HardLink -Path/-Name <링크> -Target/-Value <원본>
        case "$a" in
          -[Ii]*|-[Tt][Yy]*) itype=$nx; skip=1 ;;
          -[Pp][Aa][Tt]*|-[Ll][Ii]*) npath=$nx; skip=1 ;;
          -[Nn]*) nname=$nx; skip=1 ;;
          -[Tt]*|-[Vv][Aa]*) ltgt+=("$nx"); skip=1 ;;
          -*) ;;   # -PassThru·-Force·-WhatIf 처럼 값 없는 옵션은 다음 낱말을 삼키지 않는다(FC2 G5)
          *) if [ -z "$npath" ]; then npath=$a; else ltgt+=("$a"); fi ;;
        esac ;;
    esac
  done
  # 풀기: 풀 곳(없으면 지금 폴더)이 기록 폴더·그 안·그 상위면(루트에서 tar xzf 도 — 안에 무엇이 있는지 모름)
  case "$k" in
    tar|unzip|7z|xa)
      [ "$k" = xa ] && [ "${#dirs[@]}" -eq 0 ] && [ "${#pos[@]}" -ge 2 ] && dirs=("${pos[1]}")
      [ "$ext" = 1 ] || return 0
      [ "$ab" = 1 ] && block "$MSG_UNPACK" "$MSG_HUMAN"     # FC3 H1: 절대경로·.. 그대로 풀기는 표준출력 표시와 상관없이
      case "$tq" in *C*) cfail=1 ;; esac                    # FC4 K1: 옛꼴 C 의 값 낱말이 모자람 → 애매
      [ "$cfail" = 1 ] && block "$MSG_UNPACK" "$MSG_HUMAN"  # FC4 K1: 묶음 안 C 의 풀 곳을 판정할 수 없음
      # FC4 K2: 명령 원문 어디에든(앞 조각의 export·declare -x·set·대입 포함) 풀기 옵션 환경 변수 이름이 보이면 — 이름은 대소문자를 가린다(unzip 명령은 아님)
      [[ $rawcmd =~ $RE_UNPACK_ENV ]] && envx=1
      # FC3 H3: TAR_OPTIONS·UNZIP·UNZIPOPT 대입이 붙은 풀기(unzip 의 목록 보기 -l·-t·-p 같은 것만 통과 — tar 는 -O 여도 막음)
      [ "$envx" = 1 ] && { [ "$out" = 0 ] || [ "$k" != unzip ]; } && block "$MSG_UNPACK" "$MSG_HUMAN"
      { [ "$out" = 0 ] || [ "$k" != unzip ]; } && UNPK=1   # FC5 E1: 풀기가 있다 — 같은 명령에 환경을 바꾸는 명령이 있으면 끝에서 막는다
      [ "$out" = 0 ] || return 0
      [ "${#dirs[@]}" -eq 0 ] && dirs=(.)
      for d in "${dirs[@]}"; do cpd_where "$d"; [ "$CW" != no ] && block "$MSG_UNPACK" "$MSG_HUMAN"; done
      return 0 ;;
  esac
  n=${#pos[@]}
  # 링크(심볼릭·하드·mklink /d /j /h · New-Item 링크): 가리킬 원본이나 만들 자리(목적지 폴더)가 기록 폴더·그 상위, 또는 그 안의 사람 전용 파일이면.
  #   상대 원본은 지금 폴더 기준과 링크가 놓일 폴더 기준 둘 다 본다(FC F5) · xargs·{}·명령 치환으로 넘긴 원본(모름)도 막는다(FC F4)
  if [ "$k" = ni ]; then
    case "$itype" in symboliclink|junction|hardlink|[Ss][Yy][Mm]*|[Jj][Uu][Nn]*|[Hh][Aa][Rr][Dd]*) ;; *) return 0 ;; esac
    local lk=$npath   # 링크 자리 = -Path, -Name 이 있으면 -Path/-Name(FC2 G5)
    [ -n "$nname" ] && { if [ -n "$lk" ]; then lk="$lk/$nname"; else lk=$nname; fi; }
    LDIR=""
    [ -n "$lk" ] && { cpd_hit "$lk" rec && block "$MSG_LINK"; cpd_linkdir "$lk"; }
    for s in "${ltgt[@]}"; do cpd_lnsrc "$s" "$LDIR" && block "$MSG_LINK"; done
    return 0
  fi
  if [ "$k" = ln ] || [ "$k" = mklink ]; then
    local lk="" ls=()
    if [ "$k" = mklink ]; then
      [ "$n" -ge 1 ] && lk=${pos[0]}; [ "$n" -ge 2 ] && ls=("${pos[@]:1}")
    elif [ -n "$tdir" ]; then lk=$tdir; ls=("${pos[@]}")
    elif [ "$n" -eq 1 ]; then lk=.; ls=("${pos[0]}")
    elif [ "$n" -ge 2 ]; then lk=${pos[$((n - 1))]}; ls=("${pos[@]:0:$((n - 1))}")
    fi
    [ -n "$lk" ] && cpd_hit "$lk" rec && block "$MSG_LINK"
    LDIR=""; [ -n "$lk" ] && cpd_linkdir "$lk"
    { [ "$n" -eq 1 ] || [ -n "$tdir" ]; } && [ "$k" = ln ] && [ -n "$lk" ] && { resolve_tok "${lk//\"/}" && LDIR=$RP; }
    [ "$XARGS" = 1 ] && block "$MSG_LINK"
    for s in "${ls[@]}"; do
      case "$s" in *'$bt'*) block "$MSG_LINK" ;; esac
      cpd_lnsrc "$s" "$LDIR" && block "$MSG_LINK"
    done
    return 0
  fi
  # 복사·옮기기: 목적지 → d, 원본 → srcs
  if [ -n "$tdir" ]; then
    d=$tdir; srcs+=("${pos[@]}")
  elif [ "$k" = win ]; then
    [ "$n" -ge 2 ] || return 0
    d=${pos[1]}; srcs+=("${pos[0]}")
    [ "$sc" = robocopy ] && for ((j = 2; j < n; j++)); do srcs+=("${pos[$j]}"); done
  else
    [ "$n" -ge 1 ] || return 0
    d=${pos[$((n - 1))]}
    for ((j = 0; j < n - 1; j++)); do srcs+=("${pos[$j]}"); done
  fi
  [ "$XARGS" = 1 ] && srcs+=('$bt')   # FC F4: xargs 로 넘긴 원본 = 모름
  [ "${#srcs[@]}" -gt 0 ] || return 0
  # FC F6: cp -l·-s·--link·--symbolic-link 은 원본을 잇는다 — 원본이 기록 폴더나 그 안·그 상위면
  if [ "$lnk" = 1 ]; then for s in "${srcs[@]}"; do cpd_hit "$s" in && block "$MSG_LINK"; done; fi
  cpd_where "$d"
  case "$CW" in
    self)   # 기록 폴더 자체나 그 안: 폴더째 · 이름을 알 수 없는 원본 · mv -T(기록 폴더를 통째 갈아 끼움 — FC2 G6)
      [ "$rec" = 1 ] && block "$MSG_CPDIR"
      [ "$tt" = 1 ] && [ "$sc" = mv ] && block "$MSG_CPDIR"
      for s in "${srcs[@]}"; do cpd_unknown "$s" && block "$MSG_CPDIR"; done ;;
    up)     # 그 상위(FC F7 — 헛막힘 좁히기): 폴더째 그리고 원본이 모름·/.·/·와일드카드·이름이 refactor·docs 일 때만
      #   FC2 G1: -T·--no-target-directory·robocopy·xcopy 는 원본 안쪽을 붓는다 = /. 와 같다
      if [ "$tt" = 1 ] && { [ "$rec" = 1 ] || [ "$sc" = mv ]; }; then block "$MSG_CPDIR"; fi
      if [ "$k" = win ] && [ "$rec" = 1 ]; then block "$MSG_CPDIR"; fi
      if [ "$rec" = 1 ]; then for s in "${srcs[@]}"; do cpd_upsrc "$s" && block "$MSG_CPDIR"; done; fi
      #   FC2 G6: mv -b·--backup = 있던 것을 백업하고 갈아 끼운다(mv -b /tmp/refactor docs/)
      if [ "$bk" = 1 ]; then for s in "${srcs[@]}"; do cpd_upsrc "$s" && block "$MSG_CPDIR"; done; fi ;;
  esac
  return 0
}
# 명령 전체: 백틱·$( ) 치환은 한 단어 $bt(이름을 알 수 없는 낱말)로 접고 안의 명령은 뒤에 따로 붙여 본다(FC F2) · {} 도 $bt(FC F4) ·
#   find -exec/-execdir/-ok/-okdir 뒤는 새 조각(FC F4) · 단독 & 도 조각 경계(FC F1) — cd 를 따라 조각마다 copy_dir_seg
copy_dir_targets() {
  local s=$1 o="" in="" BT='`' r m dp ii ch pc DQS='"/' SQS="'/"
  while :; do case "$s" in *"$BT"*"$BT"*) o="$o${s%%"$BT"*}\$bt"; r=${s#*"$BT"}; in="$in$NL${r%%"$BT"*}"; s=${r#*"$BT"} ;; *) break ;; esac; done
  s="$o$s"; o=""
  # $( ) 는 괄호 깊이로(겹친 $( ) · 따옴표 안 괄호 — FC2 G4): 다음 ) 까지 잘라 그 안의 ( 수만큼 깊이를 더한다
  while :; do
    case "$s" in *'$('*) ;; *) break ;; esac
    o="$o${s%%'$('*}\$bt"; r=${s#*'$('}; dp=1; ii=""
    while :; do
      case "$r" in *')'*) ;; *) ii="$ii$r"; r=""; break ;; esac
      ch=${r%%')'*}; r=${r#*')'}; pc=${ch//[!(]/}
      dp=$((dp + ${#pc} - 1)); ii="$ii$ch"
      [ "$dp" -le 0 ] && break
      ii="$ii)"
    done
    in="$in$NL$ii"; s=$r
  done
  s="$o$s"
  # 따옴표를 닫은 바로 뒤에 / 가 오면 따옴표를 지워 한 낱말로("$PWD"/docs/refactor — FC2 G3 · 이 사본에서만, 공유 판정 문자열은 그대로)
  s=${s//"$DQS"/$SL}; s=${s//"$SQS"/$SL}
  s="$s$in"
  s=${s//'{}'/'$bt'}
  for m in -execdir -exec -okdir -ok; do s=${s//" $m "/"$NL"}; done
  UNPK=0; ENVSET=0
  cd_all copy_dir_targets1 "$s"
  # FC5 E1: 풀기와 함께 환경을 바꾸는 명령(export·declare·typeset·local·readonly·set·eval·source·. ·env -S)이 같은 명령에 있으면
  #   TAR_OPTIONS·UNZIP 를 글자를 꼬아(TAR_OPT""IONS·TAR_\OPTIONS·eval·source 파일) 넣을 수 있어 막는다(애매하면 막기)
  [ "$UNPK" = 1 ] && [ "$ENVSET" = 1 ] && block "$MSG_UNPACK" "$MSG_HUMAN"
}
copy_dir_targets1() {
  local s=$1 seg CWD_BASE=$cwd CD_PREV=$cwd j
  s=${s//&&/$NL}; s=${s//||/$NL}; s=${s//;/$NL}; s=${s//|/$NL}; s=${s//&/$NL}
  while [ -n "$s" ]; do
    seg=${s%%"$NL"*}; if [ "$seg" = "$s" ]; then s=""; else s=${s#*"$NL"}; fi
    case "$seg" in *[![:space:]]*) ;; *) continue ;; esac
    cd_seg "$seg" && continue
    seg_targets "$seg"
    case "$SCMD" in export|declare|typeset|local|readonly|set|eval|source|.) ENVSET=1 ;; esac
    for ((j = 0; j < SI; j++)); do [ "${SW[$j]}" = eval ] || [ "${SW[$j]}" = -S ] && ENVSET=1; case "${SW[$j]}" in --split-string*|-[a-zA-Z]*S) ENVSET=1 ;; esac; done
    copy_dir_seg
  done
  cwd=$CWD_BASE
}
# 8.3 짧은 이름(ENV~1) 인자가 비밀값 파일일 수 있는가
seg_short_secret() {
  case "$1" in *'~'[0-9]*) ;; *) return 1 ;; esac
  has "$1" '^[[:space:]]*git[[:space:]]' && return 1   # git 의 HEAD~3 같은 버전 표기
  local tok t b toks=() re_83='^[A-Za-z0-9_$-]{1,6}~[0-9]+([.][A-Za-z0-9]{1,3})?$'
  set -f; for tok in $1; do toks+=("$tok"); done; set +f
  for tok in "${toks[@]}"; do
    # 8.3 모양(경로 끝 이름 = 영숫자 1~6자 + ~숫자 + 확장자 0~3자)만 짧은 이름 후보로 본다 — 글 속 "2~4단" 같은 물결표는 아니다.
    # 확장자가 없으면 앞부분에 글자가 있어야 한다(ENV~1 · CREDEN~1 은 후보, 글 속 "1~5" 같은 숫자 범위는 아님)
    # 앞뒤 기호를 먼저 뗀다: 따옴표 · 앞의 ( < · 뒤의 ) > 부터 끝까지 · 끝 점($(cat ENV~1) · cat <ENV~1 · cat ENV~1>o.txt · cat ENV~1.)
    t=${tok//\"/}; t=${t//\'/}; t=${t%%[\)\>]*}; t=${t##*[\<\(]}
    while [ "${t%.}" != "$t" ]; do t=${t%.}; done
    b=${t##*/}; b=${b##*"$BS"}
    [[ $b =~ $re_83 ]] || continue
    case "$b" in *.*|*[A-Za-z]*'~'*) ;; *) continue ;; esac
    resolve_tok "$t" && is_secret_path "$RP" && return 0
  done
  return 1
}
# PowerShell Env: 드라이브로 환경변수를 찍는가(gci env:, Get-ChildItem -Path env:, Get-Item Env:*) — 안전 이름 하나만 보면 통과
ps_env_provider() {
  local rest=$1 nm re="(^|[;&|({\`\"'[:space:]])(get-childitem|gci|dir|ls|get-item|gi|get-content|gc|type|cat|get-itemproperty|gp)([[:space:]]+-(path|literalpath|name))?[[:space:]]+[\"']?env:[/\\\\]?([^[:space:]\"';&|)]*)"
  local re_nmo="^[\"']?[[:space:]]*[|][[:space:]]*(select-object|select)[[:space:]]+(-property[[:space:]]+|-expandproperty[[:space:]]+)?[\"']?name[\"']?[[:space:]]*($|[;|)])"
  while [[ $rest =~ $re ]]; do
    nm=${BASH_REMATCH[5]}; rest=${rest#*"${BASH_REMATCH[0]}"}
    [[ $rest =~ $re_nmo ]] && continue   # 이름만 고르는 목록(gci env: | select-object name)은 값이 안 나온다
    [ -z "$nm" ] && return 0
    case "$nm" in *'*'*|*'?'*|*'['*) return 0 ;; esac
    safe_env_name "$nm" || return 0
  done
  return 1
}
# <<< 로 비밀값 이름의 변수를 넘기는가(cat <<< "$OPENAI_API_KEY")
herestr_sens() {
  local rest=$1 re="<<<[[:space:]]*[\"']?[$][{]?([A-Za-z_][A-Za-z0-9_]*)"
  while [[ $rest =~ $re ]]; do
    rest=${rest#*"${BASH_REMATCH[0]}"}
    sens_name "${BASH_REMATCH[1]}" && return 0
  done
  return 1
}
# awk 가 ENVIRON(환경변수)을 찍는가 — 안전 이름(ENVIRON["HOME"])만 보면 통과
awk_env_print() {
  # awk 의 내장 배열은 대문자 낱말 ENVIRON 뿐이다(대소문자 구분) — "environment" 같은 글자·/ENVIRONMENT/ 패턴은 아니다
  has "$1" "${S}(g|m|n)?awk[[:space:]]" && has "$1" 'print' && hascs "$1" '(^|[^[:alnum:]_])ENVIRON([^[:alnum:]_]|$)' || return 1
  local rest=$1 re="(^|[^[:alnum:]_])ENVIRON([[][[:space:]]*[\"']?([A-Za-z_][A-Za-z0-9_]*)|[^[:alnum:]_]|$)" nm hit=1
  shopt -u nocasematch
  while [[ $rest =~ $re ]]; do
    rest=${rest#*"${BASH_REMATCH[0]}"}; nm=${BASH_REMATCH[3]}
    if [ -z "$nm" ] || ! safe_env_name "$nm"; then hit=0; break; fi
  done
  shopt -s nocasematch
  return $hit
}
# jq 가 환경변수(env · $ENV)를 통째로 또는 비밀값 이름으로 찍는가(jq -n env · jq -n '$ENV' · env.API_KEY)
# jq 는 대소문자를 가린다: 내장은 env 와 $ENV 뿐이고 $env 는 사용자 변수다. --arg env x 처럼 변수 이름으로 쓴 env 는 빼고 본다.
# .env 같은 필드·파일 이름(config/env.json)도 아니다
jq_env() {
  has "$1" "${S}jq[[:space:]]" || return 1
  local seg nm rest=$1 re_seg="${S}jq[[:space:]][^;&|]*" s2 hit=1
  local re_arg='--(arg|argjson|slurpfile|rawfile)[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+'
  local re='(^|[^.$/[:alnum:]_"-])(env|[$]ENV)([.]([A-Za-z_][A-Za-z0-9_]*))?([^[:alnum:]_:"]|$)'   # "env" 문자열·{env: …} 객체 키는 아니다
  while [[ $rest =~ $re_seg ]]; do
    seg=${BASH_REMATCH[0]}; rest=${rest#*"$seg"}; s2=${seg#*jq}
    while [[ $s2 =~ $re_arg ]]; do s2=${s2/"${BASH_REMATCH[0]}"/ }; done
    shopt -u nocasematch
    while [[ $s2 =~ $re ]]; do
      s2=${s2#*"${BASH_REMATCH[0]}"}; nm=${BASH_REMATCH[4]}
      [ -z "$nm" ] && { hit=0; break 2; }
      [[ $nm =~ [A-Z] ]] || continue   # env.json 같은 파일 이름은 아니다(환경변수 이름은 대문자)
      safe_env_name "$nm" || { hit=0; break 2; }
    done
    shopt -s nocasematch
  done
  shopt -s nocasematch
  return $hit
}
# echo·printf·Write-Host 가 비밀값 이름의 변수를 찍는가
echo_sens() {
  local rest=$1 re='(^|[;&|(`"[:space:]])(echo|printf|write-host|write-output)([^;&|]*)'
  while [[ $rest =~ $re ]]; do
    rest=${rest#*"${BASH_REMATCH[0]}"}
    vars_sensitive "${BASH_REMATCH[3]}" && return 0
  done
  return 1
}
# [Environment]::GetEnvironmentVariable("이름") 이 비밀값 이름인가
ps_getenv_sens() {
  local rest=$1 re="\\[(system[.])?environment\\]::getenvironmentvariable[[:space:]]*[(][[:space:]]*[\"']([a-z0-9_]+)"
  while [[ $rest =~ $re ]]; do
    rest=${rest#*"${BASH_REMATCH[0]}"}
    sens_name "${BASH_REMATCH[2]}" && return 0
  done
  return 1
}
# 읽기 전용 단계: 인터프리터 코드가 프로젝트 안(docs/refactor 밖) 파일에 쓰는가(쓰는 경로를 알 수 없으면 쓰는 것으로 본다)
#   0.3.7 G6: 단순 따옴표를 벗기기 전 사본 lr0 도(다를 때만 — 히어독 본문의 open('src/x.py','w'))
interp_writes_proj() {
  iwp_one "$lr" && return 0
  [ -n "${lr0:-}" ] && [ "$lr0" != "$lr" ] && iwp_one "$lr0"
}
iwp_one() {
  has "$1" "${S}(python3?|py|node|ruby|php|perl|deno|bun|pwsh|powershell)[[:space:]]" || return 1
  has "$1" "open[(][^)]*['\"][wax+>]|write_?text|write_?bytes|writefile|write_file|appendfile|fs[.](write|append|rm|unlink|rename|copy|truncate|mkdir)|[.]unlink|rmtree|os[.](remove|rename|replace|makedirs|mkdir)|shutil[.](move|copy)|set-content|out-file|add-content" || return 1
  local rest=$1 re_lit="[\"']([^\"'[:space:]]*[/.][^\"'[:space:]]*)[\"']" lit any=0
  while [[ $rest =~ $re_lit ]]; do
    lit=${BASH_REMATCH[1]}; rest=${rest#*"${BASH_REMATCH[0]}"}
    case "$lit" in *'$'*|*'{'*|*'%'*) continue ;; esac
    resolve_tok "$lit" || continue
    any=1
    under_proj "$RP" && ! under_refactor_docs "$RP" && return 0
  done
  [ "$any" = 0 ]
}

# 대소문자를 구분하는 정규식 검사(옵션 -C 와 -c 를 가를 때)
hascs() { shopt -u nocasematch; [[ $1 =~ $2 ]]; local r=$?; shopt -s nocasematch; return $r; }
# --include 가 하나라도 있고 모두 비밀값 파일에 맞지 않으면 범위를 좁힌 것(--include='*' · '*env*' 는 넓음)
include_narrow() {
  local rest=$1 re="--include(=|[[:space:]]+)[\"']?([^[:space:]\"']+)" g any=0
  while [[ $rest =~ $re ]]; do
    g=${BASH_REMATCH[2]}; rest=${rest#*"${BASH_REMATCH[0]}"}; any=1
    glob_hits_secret "$g" && return 1
  done
  [ "$any" = 1 ]
}
# rg -g/--glob 이 하나라도 있고(제외 !… 는 빼고) 모두 비밀값 파일에 맞지 않으면 좁힌 것
glob_narrow() {
  local rest=$1 re="(-g|--glob|--iglob)(=|[[:space:]]+)?[\"']?([^[:space:]\"']+)" g any=0
  while [[ $rest =~ $re ]]; do
    g=${BASH_REMATCH[3]}; rest=${rest#*"${BASH_REMATCH[0]}"}
    case "$g" in '!'*) continue ;; esac
    any=1; glob_hits_secret "$g" && return 1
  done
  [ "$any" = 1 ]
}
# 검색 경로 하나가 넓은가: 프로젝트(또는 그 위)·현재 폴더 전체, 비밀값 파일에도 맞는 와일드카드(findstr /s *, sls -Path *)
tok_wide() {
  local t=${1//\"/}; t=${t//\'/}
  case "$t" in .|./|..|../|'*'|'./*'|'*.*'|'.*'|'$PWD'|'~'|'$HOME'|/) return 0 ;; esac
  case "$t" in *'*'*|*'?'*) glob_hits_secret "${t##*/}" && return 0 ;; esac
  resolve_tok "${t%/}" || return 1
  case "$proj/" in "$RP"/*) return 0 ;; esac
  return 1
}
# 명령 조각이 숨김 파일까지 넓은 범위의 파일 이름을 내놓는가(find . · find <프로젝트> · ls -A · ls -a) — xargs grep · grep $(…) 의 파일 목록 판정
lists_wide() {
  seg_words "$1"
  local i a st=1 starts=() filt=0 all=0
  case "$SCMD" in
    find)
      for ((i = SI + 1; i < ${#SW[@]}; i++)); do
        a=${SW[$i]}
        if [ "$st" = 1 ]; then case "$a" in -*|'!'|'\(') st=0 ;; *) starts+=("$a"); continue ;; esac; fi
        case "$a" in -name|-iname|-path|-ipath|-wholename|-iwholename|-regex|-iregex) glob_hits_secret "${SW[$((i + 1))]:-}" || filt=1 ;; esac
      done ;;
    ls|dir|gci|get-childitem)
      for ((i = SI + 1; i < ${#SW[@]}; i++)); do
        a=${SW[$i]}
        case "$a" in --all|--almost-all|-force) all=1 ;; --*) ;; -*a*) all=1 ;; -*) ;; *) starts+=("$a") ;; esac
      done
      [ "$all" = 1 ] || return 1 ;;
    *) return 1 ;;
  esac
  [ "$filt" = 1 ] && return 1
  [ "${#starts[@]}" -eq 0 ] && return 0
  for a in "${starts[@]}"; do tok_wide "$a" && return 0; done
  return 1
}
# 비밀값 파일이 무시되지 않은 넓은 범위를 내용 검색하는 조각인가(grep -r · rg -uu/--hidden/--no-ignore · findstr /s · Select-String
# · 앞 명령이 넓은 파일 목록을 넘기는 xargs grep). $2 = 바로 앞 조각(파이프 앞)
wide_search_seg() {
  local s=$1 c i a skip=0 toks=() np=0
  seg_words "$s"; c=$SCMD
  # find . | xargs grep … : 파일 목록을 받는 검색은 목록이 넓으면(숨김 파일 포함) 넓은 검색이다
  if [ "$XARGS" = 1 ] && [ -n "${2:-}" ]; then
    case "$c" in
      grep|egrep|fgrep|rg)
        hascs "$s" '[[:space:]](-[a-zA-Z]*[lLcq][a-zA-Z]*|--files-with(out)?-match(es)?|--files-with-matches|--count|--quiet)([[:space:]]|$)' && return 1
        lists_wide "$2"; return $? ;;
    esac
  fi
  case "$c" in
    grep|egrep|fgrep)
      hascs "$s" '[[:space:]](-[a-zA-Z]*[rR][a-zA-Z]*|--recursive|--dereference-recursive)([[:space:]]|$)' || return 1
      hascs "$s" '[[:space:]](-[a-zA-Z]*[lLcq][a-zA-Z]*|--files-with(out)?-match(es)?|--count|--quiet)([[:space:]]|$)' && return 1
      has "$lr" '--exclude=[^[:space:]]*env' && return 1
      include_narrow "$lr" && return 1 ;;
    rg)
      hascs "$s" '[[:space:]](-[a-zA-Z]*[lcq][a-zA-Z]*|--files-with-matches|--files-without-match|--count|--count-matches|--files|--quiet)([[:space:]]|$)' && return 1
      hascs "$s" '[[:space:]](-[a-zA-Z.]*u[a-zA-Z.]*|-[a-zA-Z]*[.][a-zA-Z]*|--hidden|--no-ignore[a-z-]*)([[:space:]]|$)' || return 1
      hascs "$s" '[[:space:]](-t|--type)([[:space:]=]|$)|[[:space:]]-t[a-z]' && return 1
      glob_narrow "$s" && return 1 ;;
    findstr)
      has "$s" '[[:space:]]/{1,2}[a-z]*s[a-z]*([[:space:]]|$)' || return 1
      has "$s" '[[:space:]]/{1,2}[a-z]*m[a-z]*([[:space:]]|$)' && return 1 ;;
    select-string|sls) ;;
    *) return 1 ;;
  esac
  for ((i = SI + 1; i < ${#SW[@]}; i++)); do
    a=${SW[$i]}
    [ "$skip" = 1 ] && { skip=0; continue; }
    case "$a" in
      _Q_) continue ;;
      -path|-literalpath) toks+=("${SW[$((i + 1))]:-}"); skip=1; continue ;;
      -e|-f|--regexp|--file|-g|--glob|--iglob|-t|--type|-T|--type-not|-m|--max-count|-A|-B|-C|--include|--exclude|--exclude-dir|-pattern|-include|-exclude|-encoding|-context) skip=1; continue ;;
      -*) continue ;;
    esac
    if [ "$c" = findstr ]; then case "$a" in /*) [ "${#a}" -le 4 ] && continue; case "$a" in /[a-z]:*|//[a-z]:*) continue ;; esac ;; esac; fi
    np=$((np + 1))
    # findstr·Select-String 의 첫 인자는 검색어
    case "$c" in findstr|select-string|sls) [ "$np" -eq 1 ] && continue ;; esac
    toks+=("$a")
  done
  case "$c" in select-string|sls) [ "${#toks[@]}" -eq 0 ] && return 1 ;; esac
  [ "${#toks[@]}" -eq 0 ] && return 0
  for a in "${toks[@]}"; do tok_wide "$a" && return 0; done
  return 1
}
# PowerShell: 재귀 목록(gci -Recurse)을 Select-String·Get-Content 로 넘기는가(좁히는 -Include/-Filter 가 비밀값 파일에 안 맞으면 통과)
ps_wide_search() {
  local s=$1 opts re="(get-childitem|gci|ls|dir)([^;&|]*)[|][[:space:]]*(select-string|sls|get-content|gc|cat|type)([[:space:]]|$)" re_f="-(include|filter)[[:space:]]+[\"']?([^[:space:]\"',]+)"
  [[ $s =~ $re ]] || return 1
  opts=${BASH_REMATCH[2]}
  has "$opts" '[[:space:]]-r(e(c(u(r(s(e)?)?)?)?)?)?([[:space:]]|$)' || return 1
  if [[ $opts =~ $re_f ]] && ! glob_hits_secret "${BASH_REMATCH[2]}"; then return 1; fi
  return 0
}
# 원격 주소(토큰이 들어 있을 수 있음)를 그대로 내보내는가 — git remote -v·get-url·show, git config --get-regexp·remote.<이름>.url.
# 예외(통과): (a) 그 파이프 조각이 git 으로 시작하고(리다이렉트 > · 명령 치환 없음) 바로 뒤 조각이 개수만 세는 grep -c/-q · wc -l/-c 하나뿐일 때
#            (b) --get-regexp 인자가 '^(이름|이름…)\.' 꼴이고 이름이 영숫자·- 뿐이며 remote·url 이 들어 있지 않을 때(원격 주소가 나올 수 없는 조회라 뒤 파이프와 무관)
#   명령 치환 $( ) · ` ` · <( ) 는 안쪽(괄호가 더 없는 것)부터 따로 판정한다 — 안에서 개수만 세면(echo "$(git config … | grep -c x || true)")
#   밖으로 나가는 건 개수뿐이라 통과, 안에서 원문이 나오면(echo "$(git remote -v)" · x=$(git remote -v)) 차단. 원격 주소 조회였던 자리는 _CS_ 로,
#   그 밖의 치환은 괄호만 벗겨 안쪽 낱말을 바깥 판정에 남긴다
remote_url_out() {
  local s=$1 m names nm ok c pl k i p nx inner
  local re_ru='git[[:space:]]+(remote([[:space:]]+(-v|--verbose|get-url|show))|config[^;&|]*(--get-regexp|remote[.][^[:space:]]*[.]url))'
  local re_gr='--get-regexp[[:space:]]+("\^\(([[:alnum:]|-]+)\)\\\."|'"'"'\^\(([[:alnum:]|-]+)\)\\\.'"'"')'
  local re_cnt='^[[:space:]]*(grep([[:space:]]+-[^[:space:]]+)*[[:space:]]+(-[a-zA-Z]*[cq][a-zA-Z]*|--count|--quiet|--silent)([[:space:]]|$)|wc[[:space:]]+-[lc]+([[:space:]]|$))'
  local re_cs='[$<][(]([^()]*)[)]|`([^`]*)`' kk=0
  has "$s" "$re_ru" || return 1
  # (b) 좁은 정규식 인자는 자리표시로 바꿔 둔다(인자 속 | 가 파이프 조각을 가르지 않게)
  while [[ $s =~ $re_gr ]]; do
    m=${BASH_REMATCH[0]}; names="${BASH_REMATCH[2]}${BASH_REMATCH[3]}|"; ok=1
    while [ -n "$names" ]; do
      nm=${names%%|*}; names=${names#*|}
      case "$nm" in ""|*remote*|*url*) ok=0 ;; esac
    done
    if [ "$ok" = 1 ]; then s=${s/"$m"/--get-regexp __GRX__}; else s=${s/"$m"/--get-regexp __GRBAD__}; fi
  done
  # 명령 치환은 안쪽부터 따로 판정하고 자리표시로 바꾼다(괄호가 섞여 짝을 못 찾으면 그대로 두고 아래에서 통째로 본다 — 보수적)
  while [[ $s =~ $re_cs ]] && [ "$kk" -lt 40 ]; do
    kk=$((kk + 1)); m=${BASH_REMATCH[0]}; inner="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
    remote_url_out "$inner" && return 0
    # 안쪽이 원격 주소 조회(개수만 셈)일 때만 자리표시로 — 아니면 괄호·백틱만 벗겨 안쪽 낱말을 바깥 판정에 남긴다
    #   (git config --get "$(echo remote.origin.url)" 의 remote.origin.url 이 사라지지 않게)
    if has "$inner" "$re_ru"; then s=${s/"$m"/_CS_}; else s=${s/"$m"/" $inner "}; fi
  done
  s=${s//&&/$NL}; s=${s//||/$NL}; s=${s//;/$NL}
  while [ -n "$s" ]; do
    c=${s%%"$NL"*}; if [ "$c" = "$s" ]; then s=""; else s=${s#*"$NL"}; fi
    has "$c" "$re_ru" || continue
    local P=(); pl=$c; k=0
    while :; do P[k]=${pl%%|*}; k=$((k + 1)); [ "$pl" = "${pl#*|}" ] && break; pl=${pl#*|}; done
    for ((i = 0; i < k; i++)); do
      p=${P[$i]}
      has "$p" "$re_ru" || continue
      # (b) 좁은 --get-regexp(원격 주소가 나올 수 없음) — 뒤 파이프와 무관
      case "$p" in *'--get-regexp __GRX__'*) has "${p//--get-regexp __GRX__/ }" "$re_ru" || continue ;; esac
      # (a) git 으로 시작하는 조각의 출력을 개수만 세는 조각 하나로 받고 끝
      if [ "$((i + 2))" -eq "$k" ]; then
        nx=${P[$((i + 1))]}
        if has "$p" '^[[:space:]({]*git[[:space:]]' && ! has "$p" '[>`]|[$][(]|<[(]' && hascs "$nx" "$re_cnt" && ! has "$nx" '[$][(]|`'; then continue; fi
      fi
      return 0
    done
  done
  return 1
}
# 0.3.4 T6: 원격 저장소·올리기 설정을 바꾸는 git 명령인가 → 0. 리팩토링 중에만 부른다(바꾼 뒤의 허락 push 가 다른 저장소로 갈 수 있다).
#   git remote add|set-url|rename|remove|rm|set-head|set-branches(set-head: origin/HEAD 는 승인 스크립트가 기본 가지를 가리는 데 쓴다) ·
#   git config 가 remote.*·url.*·push.*·branch.*·include.*·includeIf.* 키를 쓰는 꼴 — 옛 문법(키 + 값 · --add·--unset·--unset-all·
#   --replace-all·--rename-section·--remove-section) · 새 문법(set·unset·rename-section·remove-section) · 편집기(-e·--edit·edit — 어느 키든 바뀐다).
#   읽기(--get*·-l/--list·get·list·값 없는 키 하나)는 통과. 조각(; & | 줄바꿈)마다 따로 본다 — 앞 조각의 읽기 옵션이 뒤 조각의 쓰기를 가리지 않게.
#   git branch -u(이 가지의 추적 대상)는 push 가 가는 저장소를 바꾸지 않아 보지 않는다
rmt_write() {
  local s=$1 c args w mode nv skip dd wr rd prot ren IFS=$' \t\n'
  local re_rm="git(\.exe)?([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+remote([[:space:]]+-[^[:space:]]+)*[[:space:]]+(add|set-url|rename|remove|rm|set-head|set-branches)([[:space:]]|$)"
  local re_cf="git(\.exe)?([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+config(([[:space:]].*)?)$"
  local re_pk='^(remote|url|push|branch|include|includeif)([.]|$)'
  has "$s" 'git(\.exe)?[[:space:]]' || return 1
  s=${s//&&/$NL}; s=${s//||/$NL}; s=${s//;/$NL}; s=${s//|/$NL}; s=${s//&/$NL}
  while [ -n "$s" ]; do
    c=${s%%"$NL"*}; if [ "$c" = "$s" ]; then s=""; else s=${s#*"$NL"}; fi
    has "$c" "$re_rm" && return 0
    [[ $c =~ $re_cf ]] || continue
    args=${BASH_REMATCH[4]}; mode=""; nv=0; skip=0; dd=0; wr=0; rd=0; prot=0; ren=0
    set -f
    for w in $args; do
      case "$w" in '#'*) break ;; esac   # 따옴표 없는 # 부터는 주석
      while :; do case "$w" in [\"\'\(\`]*) w=${w#?} ;; *) break ;; esac; done
      while :; do case "$w" in *[\"\'\)\`]) w=${w%?} ;; *) break ;; esac; done
      [ -n "$w" ] || continue
      [ "$skip" = 1 ] && { skip=0; continue; }
      case "$w" in *'>'*|'<'*) case "$w" in *'>'|'<') skip=1 ;; esac; continue ;; esac   # 리다이렉트(> 파일)는 인자가 아니다
      if [ "$dd" = 0 ]; then
        case "$w" in
          --) dd=1; continue ;;
          -e|--edit) wr=2; continue ;;
          --rename-section) wr=1; ren=1; continue ;;
          --add|--unset|--unset-all|--replace-all|--remove-section) wr=1; continue ;;
          --get|--get-all|--get-regexp|--get-urlmatch|--get-color|--get-colorbool|-l|--list) rd=1; continue ;;
          -f|--file|--blob|--type|--default|--comment|--value) skip=1; continue ;;
          -*) continue ;;
        esac
        if [ -z "$mode" ] && [ "$nv" = 0 ]; then
          case "$w" in
            rename-section) mode=w; ren=1; continue ;;
            set|unset|remove-section) mode=w; continue ;;
            edit) wr=2; continue ;;
            get|list) mode=r; continue ;;
          esac
        fi
      fi
      nv=$((nv + 1))   # 키(1) · 값 또는 rename-section 의 새 이름(2)
      [[ $w =~ $re_pk ]] && { [ "$nv" = 1 ] || { [ "$nv" = 2 ] && [ "$ren" = 1 ]; }; } && prot=1
    done
    set +f
    [ "$wr" = 2 ] && return 0
    [ "$prot" = 1 ] || continue
    if [ "$wr" = 1 ] || [ "$mode" = w ]; then return 0; fi
    [ "$rd" = 1 ] || [ "$mode" = r ] && continue
    [ "$nv" -ge 2 ] && return 0   # 옛 문법 키 + 값
  done
  return 1
}
# 인터프리터로 docs/refactor 안 파일이나 .md 문서를 실행하는가. 코드 옵션(셸 -c·-[a-z]*c · python -c · node·bun·deno -e·-p·--eval·--print ·
#   ruby·perl -e·-E) 뒤 토큰은 코드 문자열이라 파일로 보지 않는다(bash -e·-p · sh -e 는 코드 옵션이 아니다)
#   (bash -lc 'f=~/x.md; cat a.md >> "$f"' 는 실행이 아니다. 그 안의 bash x.md · source a.md 는 따옴표를 경계로 따로 잡힌다). 옵션은 대소문자를 가린다(python -E 는 코드 옵션 아님)
md_exec() {
  local rest=$1 m opts co
  local re="${S}(sudo[[:space:]]+)?(bash|sh|zsh|dash|ksh|source|python3?|py|node|ruby|perl|php|deno|bun|tsx|ts-node|pwsh|powershell)[[:space:]]+((-[^[:space:]]+[[:space:]]+)*)[\"']?[^[:space:]\"';&|]*(docs/refactor/[^[:space:];&|]*|[.]md)([\"'[:space:];&|)]|$)"
  while [[ $rest =~ $re ]]; do
    m=${BASH_REMATCH[0]}; opts=" ${BASH_REMATCH[4]}"
    rest=${rest#*"$m"}
    # 코드 옵션은 인터프리터마다 다르다(bash -e 는 "오류 나면 멈춤"이지 코드 문자열이 아니다)
    case "${BASH_REMATCH[3]}" in
      bash|sh|zsh|dash|ksh) co='[[:space:]]-[a-z]*c[[:space:]]' ;;
      python|python3|py) co='[[:space:]]-c[[:space:]]' ;;
      node|bun|deno|tsx|ts-node) co='[[:space:]](-e|-p|--eval|--print)[[:space:]]' ;;
      ruby|perl) co='[[:space:]](-e|-E)[[:space:]]' ;;
      pwsh|powershell) co='[[:space:]]-c[[:space:]]' ;;
      *) co='' ;;
    esac
    [ -n "$co" ] && hascs "$opts" "$co" || return 0
  done
  return 1
}
# 낱말 끝의 .exe(대소문자 무관 · 앞에 경로가 붙은 꼴 · 따옴표로 감싼 꼴)를 뗀다 → XN: <이름>.exe 로 쓴 명령은 <이름> 으로 쓴 것과 같은 판정.
#   규칙 대부분이 명령 이름 바로 뒤 공백을 요구해서 .exe 를 붙이면 놓쳤다(Windows Git Bash·WSL 에서는 .exe 가 그대로 실행된다:
#   git.exe reset --hard · cat.exe .env · supabase.exe db reset …). 명령 자리(맨 앞·; & | ( ` { 뒤)의 공백 없는 경로는 함께 뗀다
#   (/usr/bin/cat.exe .env → cat .env). 그 밖 자리의 경로 앞부분은 그대로 둔다(인자 자리의 경로 — rm -rf docs/refactor/x.exe — 를
#   지우지 않는다). 이름은 글자·숫자·_ 로 시작해야 뗀다(.exe · ..exe · *.exe 는 그대로).
#   파일 이름 자리의 a.exe 도 a 가 되지만 그런 낱말만으로 걸리는 규칙은 없다(평범한 명령 차등 시험이 지킨다).
#   20번 떼고도 남아 있으면 판정할 수 없으니 막는다. 가지 강제 삭제의 허용 판정은 원래 명령(cmd0)을 보므로 git.exe 로 쓴 삭제는 막는다
exe_norm() {
  local s=$1 m0 k=0
  local rp="(^|[;&|(\`{][[:space:]]*)([\"']?)[^[:space:]\"';&|()\`]*[/\\\\]([[:alnum:]_][[:alnum:]_.+-]*)[.]exe([\"']?([[:space:];&|)\`]|$))"
  local re="(^|[[:space:];&|(\`{\"'/\\\\])([[:alnum:]_][[:alnum:]_.+-]*)[.]exe([\"']?([[:space:];&|)\`]|$))"
  while [[ $s =~ $rp ]]; do
    [ "$k" -ge 20 ] && block "명령에 .exe 낱말이 너무 많아(20개 넘음) 판정할 수 없어 막았습니다." "명령을 나눠 실행하세요."
    k=$((k + 1)); m0=${BASH_REMATCH[0]}
    s=${s/"$m0"/"${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}${BASH_REMATCH[4]}"}
  done
  while [[ $s =~ $re ]]; do
    [ "$k" -ge 20 ] && block "명령에 .exe 낱말이 너무 많아(20개 넘음) 판정할 수 없어 막았습니다." "명령을 나눠 실행하세요."
    k=$((k + 1)); m0=${BASH_REMATCH[0]}
    s=${s/"$m0"/"${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}"}
  done
  XN=$s
}
# 판정용 모양 만들기 — $1 = 풀어 놓은 명령 → NC(정규화한 명령) · LR(무해한 리다이렉트·git 전역 옵션 정리, 따옴표 그대로) · LX(비밀값 판정용)
# check_shell 이 원형으로 한 번, heredoc 본문을 거른 비밀값 판정용 사본(UVS)이 다르면 그것으로 한 번 더 부른다
mk_views() {
  local c=$1 r x m0 m4 conv
  # 판정 전 정규화: 전각 글자 → 반각, 단어 안의 빈 따옴표 쌍 지우기(re''set → reset),
  # 같은 명령 안에서 대입한 단순 변수 → 값(F=.env; cat $F → cat .env), 패키지 실행기 셸 모드(npx -c '…') → 안의 명령
  fw_norm "$c"; c=$FW
  rm_empty_quotes "$c"; c=$EQ
  expand_vars "$c"; c=$EV
  strip_call_opt "$c"; c=$SC
  case "$c" in *.exe*) exe_norm "$c"; c=$XN ;; esac
  NC=$c
  # 안전 이름만 찾는 환경변수 검색(env | grep PATH)은 덤프가 아니다 — 판정용 문자열에서 env 를 true 로 바꾼다(-v 는 제외)
  local re_egs="(^|[;&|({[:space:]])(env|printenv)[[:space:]]*[|][[:space:]]*(grep|egrep|findstr|select-string|sls)(([[:space:]]+-[a-uw-zA-UW-Z]+)*)[[:space:]]+[\"']?\^?([A-Za-z_][A-Za-z0-9_]*)=?[\"']?([[:space:];&|)]|$)"
  while [[ $c =~ $re_egs ]]; do
    safe_env_name "${BASH_REMATCH[6]}" || break
    m0=${BASH_REMATCH[0]}; c=${c/"$m0"/"${BASH_REMATCH[1]}true | ${BASH_REMATCH[3]} ${BASH_REMATCH[6]}${BASH_REMATCH[7]}"}
  done
  # 이름만 남기는 환경변수 목록(env | cut -d= -f1, sed 's/=.*//', awk -F= '{print $1}')도 덤프가 아니다 — 바로 뒤 거르개가 그 명령 하나일 때만
  local re_d="-d[[:space:]]*[\"']?=[\"']?" re_f='-f[[:space:]]*1'
  local re_enm="(^|[;&|({[:space:]])(env|printenv)[[:space:]]*[|][[:space:]]*(cut[[:space:]]+${re_d}[[:space:]]+${re_f}|cut[[:space:]]+${re_f}[[:space:]]+${re_d}|sed[[:space:]]+(-e[[:space:]]+)?[\"']?s/=[.][*][$]?//g?[\"']?|g?awk[[:space:]]+-F[[:space:]]*[\"']?=[\"']?[[:space:]]+[\"']?[{][[:space:]]*print[[:space:]]+[$]1[[:space:]]*;?[[:space:]]*[}][\"']?)([[:space:]]*($|[;&|)]))"
  while [[ $c =~ $re_enm ]]; do
    m0=${BASH_REMATCH[0]}; c=${c/"$m0"/"${BASH_REMATCH[1]}true | ${BASH_REMATCH[3]}${BASH_REMATCH[5]}"}
  done

  # lr: 무해한 리다이렉트 제거 + git 전역 옵션 정리(git -C . reset → git reset)
  r=$c
  local re_null='[0-9&]*>>?[[:space:]]*/dev/null|[0-9]*>&[0-9]|[0-9]*>[[:space:]]*nul([[:space:];|&]|$)'
  while [[ $r =~ $re_null ]]; do r=${r/"${BASH_REMATCH[0]}"/ }; done
  local re_gopt="git[[:space:]]+(-[Cc][[:space:]]+(\"[^\"]*\"|'[^']*'|[^[:space:]]+)|--no-pager|-P|--paginate|--git-dir=[^[:space:]]+|--work-tree=[^[:space:]]+|--namespace=[^[:space:]]+|--bare|--no-replace-objects|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs|--no-optional-locks)[[:space:]]+"
  while [[ $r =~ $re_gopt ]]; do r=${r/"${BASH_REMATCH[0]}"/git }; done
  # 0.4.0 보완(검사 A#1 · 재검사 A2#1·#2): gh 바로 뒤 저장소 옵션(gh -R o/r pr merge · gh --repo=o/r release upload · gh -Ro/r …)도 옵션 순서만 다른 철자.
  #   판정 글(r)은 고치지 않는다 — 옵션을 걷어낸 사본(g2)을 만들어 뒤에 덧붙이고 원문과 사본을 둘 다 모든 규칙이 본다
  #   (r 을 직접 고치면 echo "gh -R 'x"; <위험 명령>; echo ' y' 처럼 따옴표 짝을 짜 맞춘 꼴이 위험 명령까지 지웠다).
  #   걷어내는 값은 좁게: 따옴표 값은 공백·; & | 없이, 맨 값은 저장소 이름 글자만. 값을 알 수 없는 꼴($R · "$R" · ${R} · "$(…)" · `…` · <(…) · o/r$x)은
  #   사본에서 자리표시 X 로 바꾼 뒤 걷어낸다(gh 규칙이 뒤 하위 명령을 보게 — 원문은 그대로라 그 안의 명령도 판정된다)
  local g2=$r gk=0
  local re_ghb="(^|[;&|({\`\"'[:space:]])gh([.]exe)?[[:space:]]+(-r(=|[[:space:]]+)?|--repo(=|[[:space:]]+))"
  # 재검사 A3 #1·#2: 사본에서만 걷어내므로 값은 넓게 — 맨 글자·'…'·"…"·`…`·$(…)·<(…) 를 이어 붙인 한 덩어리(o\/r · {o/r,} · o/'r' · "$R" …)를
  #   통째로 걷어낸다(최대 40번 — -R 을 여러 번 적은 꼴도). 원문(r)은 그대로 모든 규칙이 보므로 넓혀도 막는 판정이 줄지 않는다
  local re_ghall="${re_ghb}(([^[:space:];&|()<>\"'\`]|'[^']*'|\"[^\"]*\"|\`[^\`]*\`|[\$<][(][^()]*[)])+)[[:space:]]+"
  while [[ $g2 =~ $re_ghall ]] && [ "$gk" -lt 40 ]; do gk=$((gk + 1)); g2=${g2/"${BASH_REMATCH[0]}"/"${BASH_REMATCH[1]}gh${BASH_REMATCH[2]} "}; done
  [ "$g2" != "$r" ] && r="$r ; popd ; $g2"
  LR=$r

  # lx: 비밀값 판정용 — 따옴표 속 파일 경로는 남기고(grep KEY ".env" 도 잡게), 검색어·커밋 메시지·echo 문구만 뺀다
  #   큰따옴표 검색어 안의 \" 는 따옴표 끝이 아니다(grep -E "prefix=['\"](a|b)" src 의 나머지가 명령으로 읽히지 않게)
  blank_quoted "(^|[;&|(])[[:space:]]*(sudo[[:space:]]+)?(grep|egrep|fgrep|rg|ag|ack|git[[:space:]]+grep)(([[:space:]]+-[^[:space:]]+)*)[[:space:]]+(\"([^\"\\\\]|\\\\.)*\"|'[^']*')" 6 "$r"
  # 따옴표 없는 검색어도 뺀다(grep -rn process.env src)
  blank_quoted "(^|[;&|(])[[:space:]]*(sudo[[:space:]]+)?(grep|egrep|fgrep|rg|ag|ack|git[[:space:]]+grep)(([[:space:]]+-[^[:space:]]+)*)[[:space:]]+([^-[:space:]\"'_][^[:space:];&|]*)" 6 "$BQ"
  blank_quoted "(-m|--message|--grep|--author|-S|-G)(=|[[:space:]]+)(\"[^\"]*\"|'[^']*')" 3 "$BQ"
  blank_quoted "(^|[;&|(])[[:space:]]*(echo|printf|write-host|write-output)([^;&|\"']*)(\"[^\"]*\"|'[^']*')" 4 "$BQ"
  # jq·yq 의 첫 따옴표 인자는 필터(jq '.env' config/env.json 의 .env 는 필드 이름)라 뺀다. 옵션은 인자 개수를 아는 것만 건너뛴다
  #   (--arg 이름 값 · --indent n · -r 등). -f/--from-file 이 있으면 첫 인자가 파일이라 맞지 않게 f 는 뺐다
  blank_quoted "(^|[;&|(])[[:space:]]*(sudo[[:space:]]+)?(jq|gojq|jaq|yq([[:space:]]+(e|eval|ea|eval-all))?)(([[:space:]]+(--(arg|argjson|slurpfile|rawfile)[[:space:]]+[^[:space:];&|]+[[:space:]]+[^[:space:];&|]+|--indent[[:space:]]+[0-9]+|-[a-eg-zA-Z]+|--[a-eg-z][a-z0-9-]*))*)[[:space:]]+(\"[^\"]*\"|'[^']*')" 10 "$BQ"
  blank_echo_words "$BQ"
  x=$BQ
  # Windows 경로의 \ 를 / 로: PowerShell은 전부, Bash는 경로처럼 생긴 조각(C:\ .\ ..\ ~\)만 — 정규식 속 \. 은 건드리지 않는다
  if [ "$tool" = "PowerShell" ]; then
    local re_wbs='([[:alnum:]_.:~-])\\'
    while [[ $x =~ $re_wbs ]]; do m0=${BASH_REMATCH[0]}; x=${x/"$m0"/"${BASH_REMATCH[1]}/"}; done
  else
    local re_wtok="(^'?|[[:space:]\"=]|[^\$]')([A-Za-z]:\\\\|\\.\\.?\\\\|~\\\\)[^[:space:]\"']*"   # $'.\x65…'(ANSI-C) 는 경로가 아니다
    while [[ $x =~ $re_wtok ]]; do m0=${BASH_REMATCH[0]}; conv=${m0//"$BS"/$SL}; x=${x/"$m0"/"$conv"}; done
  fi
  local re_envfile="--(env-file|exclude|exclude-dir)(=|[[:space:]]+)(\"[^\"]*\"|'[^']*'|[^[:space:]]+)" re_ex='\.(env|envrc|dev\.vars)[[:alnum:]_.-]*\.(example|sample|template|dist)'
  while [[ $x =~ $re_envfile ]]; do x=${x/"${BASH_REMATCH[0]}"/ }; done
  # 예시 파일로 새 .env 만들기(cp .env.example .env)는 대상이 아직 없을 때만 통과 — 있으면 덮어쓰기라 아래에서 막힌다
  local re_cpex="(^|[;&|(])[[:space:]]*(cp|copy|copy-item|cpi)[[:space:]]+(-[a-z]+[[:space:]]+)*[\"']?([^[:space:]\"';&|]*\\.(env|dev\\.vars)[[:alnum:]_.-]*\\.(example|sample|template|dist))[\"']?[[:space:]]+(-destination[[:space:]]+)?[\"']?([^[:space:]\"';&|]+)[\"']?[[:space:]]*($|[;&|)])"
  while [[ $x =~ $re_cpex ]]; do
    m0=${BASH_REMATCH[0]}; m4=${BASH_REMATCH[1]}
    { resolve_tok "${BASH_REMATCH[8]}" && [ ! -e "$RP" ] && is_secret_path "$RP"; } || break
    x=${x/"$m0"/"$m4 true "}
  done
  while [[ $x =~ $re_ex ]]; do x=${x/"${BASH_REMATCH[0]}"/ }; done
  unquote_simple "$x"; LX=$UQ
}
# lq(위험 명령 판정용) 만들기 — $1 = lr → LQ. 검색·출력·커밋 메시지의 따옴표 인자는 빼고 본다(grep "vercel --prod" 같은 검색이 막히지 않게).
#   단, $( ) · ` ` 명령 치환이 든 문자열은 실행되는 명령이므로 그대로 둔다.
mk_lq() {
  local m0 dv dk=0
  # 0.3.3 K2: 안전 실행기로 감싼 명령(…run.sh" refactor-safe-run -- git commit -m "…" — 7-execute 5-1 의 단계 커밋)도 그냥 꼴과 같이 문구를 뺀다
  #   (R3: 그 접두는 명령 시작 자리의 bash <경로> 뒤에서만 — 따옴표 안의 글자로 경계를 어긋나게 읽지 않게. 그룹이 둘 늘어 문구 그룹 = 6 · 0.3.4 T4: 경로 묶음도 \" 를 따옴표 끝으로 보지 않아 "a\" 꼬아 쓰기로 경계가 어긋나지 않게 — 문구 그룹 = 7)
  # 0.3.2: 가운데 묶음은 > 를 건너지 않는다 — echo x >> "docs/refactor/APPROVALS.log" 의 리다이렉트 대상(따옴표)을 문구로 보고 비우면 쓰기 판정이 대상을 못 본다
  blank_quoted "(^|[;&|(]|(^|[;&|(])[[:space:]]*bash[[:space:]]+(\"([^\"\\\\]|\\\\.)*\"|'[^']*'|[^[:space:];&|\"']+)[[:space:]]+refactor-safe-run[[:space:]]+--[[:space:]])[[:space:]]*(grep|egrep|fgrep|rg|ag|ack|git[[:space:]]+grep|git[[:space:]]+log|git[[:space:]]+commit|echo|printf|write-host|write-output)([^;&|\"'>]*)(\"([^\"\\\\]|\\\\.)*\"|'[^']*')" 7 "$1"
  unquote_simple "$BQ"; LQ=$UQ   # 검색어·문구를 뺀 뒤 단순 따옴표 인자는 벗긴다(git reset "--hard" → git reset --hard)
  # 보내는 데이터는 실행되지 않는다 — curl·wget 류의 -d·--data·--json·-F 따옴표 값과 JSON 값("키":"값")은 비운다
  #   (curl -d '{"cmd":"git reset --hard"}' …). $( )·` ` 가 든 큰따옴표 값은 실행되므로 그대로 둔다
  local re_http="(^|[;&|(])[[:space:]]*(curl|wget|http|https|xh|iwr|irm|invoke-webrequest|invoke-restmethod)([[:space:]][^;&|]*)?[[:space:]](-d|--data[a-z-]*|--json|-f|--form[a-z-]*|--body[a-z-]*|--post-data|-body)(=|[[:space:]]+)('[^']*'|\"[^\"\$\`]*\")"
  local re_jsv="\"[[:space:]]*:[[:space:]]*\"[^\"\$\`]*\""
  while [[ $LQ =~ $re_http ]] && [ "$dk" -lt 20 ]; do
    dk=$((dk + 1)); m0=${BASH_REMATCH[0]}; dv=${BASH_REMATCH[6]}; LQ=${LQ/"$m0"/"${m0%"$dv"}_"}
  done
  while [[ $LQ =~ $re_jsv ]] && [ "$dk" -lt 40 ]; do dk=$((dk + 1)); LQ=${LQ/"${BASH_REMATCH[0]}"/\":_}; done
}
# 비밀값 판정 문자열 → SX: 코드의 process.env 류는 빼고, 빈 변수를 지운 사본(cat .e${s}nv)과
# 래퍼(bash -c · sh -c · eval) 안에서 섞인 따옴표를 모두 뺀 사본(bash -c "cat .e'n'v")을 덧붙인다
mk_sx() {
  local s=$1 b z re_codeenv='(process|import[.]meta|deno|bun)[.]env([^[:alnum:]_]|$)'
  SX=$s
  while [[ $SX =~ $re_codeenv ]]; do SX=${SX/"${BASH_REMATCH[0]}"/ }; done
  blank_vars "$s"
  if [ "$BV" != "$s" ]; then
    b=$BV; while [[ $b =~ $re_codeenv ]]; do b=${b/"${BASH_REMATCH[0]}"/ }; done; SX="$SX$NL$b"
  fi
  # 래퍼가 있을 때만(래퍼 없는 보통 명령은 공백 든 문자열이 붙어 과잉차단이 나므로 제외)
  if has "$s" "(^|[;&|({[:space:]])(eval|(sudo[[:space:]]+)?(ba|z|da|k)?sh[[:space:]]+(-[^[:space:]]+[[:space:]]+)*-[a-z]*c)([[:space:]]|$)"; then
    z=${s//\'/}; z=${z//\"/}
    if [ "$z" != "$s" ]; then
      while [[ $z =~ $re_codeenv ]]; do z=${z/"${BASH_REMATCH[0]}"/ }; done; SX="$SX$NL$z"
    fi
  fi
}
# test·[ 로 존재만 보는 조각(test -f .env · [ -f .env ] · [[ -e .env ]])
RE_TESTSEG='^[[:space:]]*((if|elif|while|until|then|do|else|!)[[:space:]]+)*(test|\[|\[\[)[[:space:]]+(![[:space:]]+)?-[fesrd][[:space:]]'
# 비밀값 이름이 든 test·[ 조각이 모두 "이름 확인만 하는 명령 치환" 안에 있는가 → 0. $1 = 판정 문자열(lr 과 빈 변수를 지운 사본), $2 = 변수를 펼치기 전 명령. check_shell 의 re_env·re_key 를 쓴다
#   그런 치환 = ① echo·printf 의 인자이거나, 대입 값인데 그 변수를 명령 어디에서도 쓰지 않음(cat $(…) · head -1 $(…) 처럼 다른 명령의 인자면 아님)
#              ② 안이 test·[ 조각과 고정 낱말(. / ~ * ? $ ` < > 없음, 비밀값 이름 아님)만 내는 echo·printf 뿐(printf .e; printf nv 조립은 아님)
#              ③ echo 의 출력이 파일(>)이나 글 거르개(tr·cut·head·tail·grep·sed·wc·sort·uniq·cat) 밖의 파이프(xargs·sh …)로 가지 않음
test_only_subst() {
  local s=$1 out="" m pre post ctx inner pcs pc tl nx w nm hast bad
  local re_cs='[$][(]([^()]*)[)]|`([^`]*)`' sepc=";&|(\`$NL"
  local re_e='^[[:space:]]*((then|do|else)[[:space:]]+)*(echo|printf)(([[:space:]]+-[neE]+)*)([[:space:]]+[^]$`./~*?\<>[]*)?[[:space:]]*$'
  local re_asg='^[[:space:]]*((local|export|readonly|declare)[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=["]?$'
  while [[ $s =~ $re_cs ]]; do
    m=${BASH_REMATCH[0]}; inner="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
    pre=${s%%"$m"*}; post=${s#*"$m"}; s=$post
    pcs=${inner//&&/$NL}; pcs=${pcs//||/$NL}; pcs=${pcs//;/$NL}; pcs=${pcs//|/$NL}; hast=0; bad=0
    while [ -n "$pcs" ]; do
      pc=${pcs%%"$NL"*}; if [ "$pc" = "$pcs" ]; then pcs=""; else pcs=${pcs#*"$NL"}; fi
      if has "$pc" "$RE_TESTSEG"; then hast=1; continue; fi
      has "$pc" '^[[:space:]]*((fi|true|false|:)[[:space:]]*)?$' && continue
      has "$pc" "$re_e" && ! has "$pc" "$re_env" && ! has "$pc" "$re_key" && continue
      bad=1
    done
    # 안에 test·[ 조각이 없는 치환은 이 판정과 무관 — 기호 없는 자리표시로 바꿔 뒤 치환의 앞말을 가리지 않게
    if [ "$hast" = 0 ]; then out="$out$pre _S_ "; continue; fi
    ctx="$out$pre"; ctx=${ctx##*[$sepc]}
    if [ "$bad" = 1 ]; then :
    elif has "$ctx" '^[[:space:]]*((then|do|else)[[:space:]]+)*(echo|printf)([[:space:]]|$)'; then
      tl=${post%%[;&|$NL]*}; nx=${post#"$tl"}
      has "$tl" '>' && bad=1
      if [ "${nx:0:1}" = '|' ] && [ "${nx:1:1}" != '|' ]; then
        w=${nx:1}; w=${w#"${w%%[![:space:]]*}"}; w=${w%%[[:space:]]*}
        case "$w" in tr|cut|head|tail|grep|egrep|fgrep|sed|wc|sort|uniq|cat|column|nl) ;; *) bad=1 ;; esac
      fi
    elif [[ $ctx =~ $re_asg ]]; then
      nm=${BASH_REMATCH[3]}
      has "$2" "[\$][{]?${nm}([^A-Za-z0-9_]|$)" && bad=1   # 변수 펼치기(expand_vars) 전 원형으로 본다
    else bad=1; fi
    if [ "$bad" = 0 ]; then out="$out$pre _TS_ "; else out="$out$pre$m"; fi
  done
  s="$out$s"
  s=${s//&&/$NL}; s=${s//||/$NL}; s=${s//;/$NL}; s=${s//|/$NL}; s=${s//(/$NL}; s=${s//\`/$NL}
  while [ -n "$s" ]; do
    pc=${s%%"$NL"*}; if [ "$pc" = "$s" ]; then s=""; else s=${s#*"$NL"}; fi
    has "$pc" "$RE_TESTSEG" || continue
    if has "$pc" "$re_env" || has "$pc" "$re_key" || seg_glob_secret "$pc" || seg_short_secret "$pc"; then return 1; fi
  done
  return 0
}

# 0.3.3 외출 중 push 허락(사람이 /refactor:approve 푸시 → 입력 훅이 만든 docs/refactor/.turn-push.<세션ID>):
#   1줄 "push <가지>"(가지 글자 [A-Za-z0-9._/-], 첫 글자는 영숫자·_) · 2줄 만든 시각(초). 이 세션 것이고 만든 지 0~1800초일 때만 → PB(허락된 가지)
#   push 가 보이는 명령에서만 부른다(date 1회 — 평소 도구 호출엔 비용 0)
push_grant() {
  PB=""
  hascs "$sid" '^[A-Za-z0-9_-]{1,128}$' || return 1
  local f="$rdir/.turn-push.$sid" l1="" l2="" now
  [ -f "$f" ] || return 1
  { IFS= read -r l1; IFS= read -r l2; } < "$f" 2>/dev/null
  l1=${l1%$'\r'}; l2=${l2%$'\r'}
  hascs "$l1" '^push [A-Za-z0-9_][A-Za-z0-9._/-]*$' || return 1
  hascs "$l2" '^[0-9]{1,12}$' || return 1
  now=$(date +%s 2>/dev/null)
  hascs "$now" '^[0-9]{1,12}$' || return 1
  now=$((10#$now - 10#$l2))
  [ "$now" -ge 0 ] && [ "$now" -le 1800 ] || return 1
  PB=${l1#push }
  return 0
}
# 0.3.5 합치기 허락(사람이 /refactor:approve 합치기 → 입력 훅이 만든 docs/refactor/.turn-merge.<세션ID>, push_grant 와 같은 꼴):
#   1줄 "merge <가지> <PR번호 또는 -> <rebase|squash|merge> <HEAD 40자 또는 64자>" · 2줄 만든 시각(초) · 3줄 허락된 명령 글자 그대로
#   bash "<플러그인>/hooks/run.sh" refactor-merge "<프로젝트 폴더>" <세션ID>. 이 세션 것이고 만든 지 0~1800초이고, 3줄의 플러그인 경로가
#   이 훅의 REFACTOR_ROOT(역슬래시 → /, 끝 / 뗌)와 같고 끝의 세션 ID 가 훅 입력의 것과 같을 때만 → ML(3줄). 줄 끝 \r 은 뗀다.
#   refactor-merge 낱말이 보이는 명령에서만 부른다(date 1회 — 평소 도구 호출엔 비용 0)
merge_grant() {
  ML=""
  hascs "$sid" '^[A-Za-z0-9_-]{1,128}$' || return 1
  local f="$rdir/.turn-merge.$sid" l1="" l2="" l3="" now pr=${REFACTOR_ROOT:-} mid
  [ -f "$f" ] || return 1
  { IFS= read -r l1; IFS= read -r l2; IFS= read -r l3; } < "$f" 2>/dev/null
  l1=${l1%$'\r'}; l2=${l2%$'\r'}; l3=${l3%$'\r'}
  hascs "$l1" '^merge [A-Za-z0-9_][A-Za-z0-9._/-]* (-|[0-9]{1,7}) (rebase|squash|merge) [0-9a-f]{40}([0-9a-f]{24})?$' || return 1
  hascs "$l2" '^[0-9]{1,12}$' || return 1
  pr=${pr//"$BS"/$SL}; while [ "${pr%/}" != "$pr" ]; do pr=${pr%/}; done
  [ -n "$pr" ] || return 1
  # 3줄 = bash "<플러그인>/hooks/run.sh" refactor-merge "<프로젝트 폴더>" <세션ID> — 대소문자를 가려 본다(전역 nocasematch 를 여기서만 끔) ·
  #   프로젝트 폴더 칸에는 " 가 없어야 한다
  shopt -u nocasematch
  case "$l3" in "bash \"$pr/hooks/run.sh\" refactor-merge \""*"\" $sid") mid=0 ;; *) mid=1 ;; esac
  shopt -s nocasematch
  [ "$mid" = 0 ] || return 1
  mid=${l3#"bash \"$pr/hooks/run.sh\" refactor-merge \""}; mid=${mid%"\" $sid"}
  case "$mid" in ""|*\"*) return 1 ;; esac
  now=$(date +%s 2>/dev/null)
  hascs "$now" '^[0-9]{1,12}$' || return 1
  now=$((10#$now - 10#$l2))
  [ "$now" -ge 0 ] && [ "$now" -le 1800 ] || return 1
  ML=$l3
  return 0
}
# 0.3.5 G3: 이 명령이 허락된 합치기 명령 그대로인가 → 0(그때만 합치기 스크립트 실행 차단 G2 를 건너뛴다 — 다른 규칙은 그대로 본다).
#   도구가 Bash · 도구 입력의 맨 위 명령(PTOP) · 유효한 허락(merge_grant) · JSON 이스케이프(\" \/)만 푼 원문(앞뒤 공백만 뗌)이
#   허락 3줄과 글자 그대로(대소문자도) 같거나 3줄 + " 2>&1". 그 밖의 역슬래시(줄 이어쓰기·줄바꿈·탭·\\·\u…)가 있으면 비교 전에 아니다.
#   MG = 허락 파일이 유효했는가(막을 때 안내를 고른다)
merge_ok() {
  MG=0
  merge_grant || return 1
  MG=1
  [ "$tool" = Bash ] && [ "$PTOP" = 1 ] || return 1
  local r=${rawcmd//"$BS$Q"/$Q} x=1
  r=${r//"$P_BSSL"/$SL}
  case "$r" in *"$BS"*) return 1 ;; esac
  while [ "${r# }" != "$r" ]; do r=${r# }; done
  while [ "${r% }" != "$r" ]; do r=${r% }; done
  shopt -u nocasematch
  { [ "$r" = "$ML" ] || [ "$r" = "$ML 2>&1" ]; } && x=0
  shopt -s nocasematch
  return $x
}
MSG_MERGE_EXEC="PR 합치기 스크립트는 사용자가 /refactor:approve 합치기 를 입력한 그 차례에만 실행합니다."
MSG_MERGE_NO="사용자에게 /refactor:approve 합치기 를 입력해 달라고 하세요(자동 검사가 모두 초록이고 기본 가지에 새 커밋이 없을 때만 합쳐짐)."
# G2·G4: 합치기 스크립트 실행 차단 — 허락이 유효하면 허락된 꼴을, 아니면 입력창 명령을 안내한다(막을 때만 허락 파일을 읽는다)
merge_block() {
  [ "${MG:-}" = 1 ] || { [ -z "${MG:-}" ] && merge_grant && MG=1; }
  if [ "${MG:-}" = 1 ]; then block "$MSG_MERGE_EXEC" "허락은 그대로입니다 — 아래 꼴 그대로 한 번만 다시 실행하세요(그래도 막히면 사용자에게 /refactor:approve 합치기 를 다시 입력해 달라고 하세요): $ML"; fi
  block "$MSG_MERGE_EXEC" "$MSG_MERGE_NO"
}
# 0.4.0 G2 자동 모드 허락: 사람이 /refactor:approve B<n> 자동 → 승인 스크립트가 만든 docs/refactor/.turn-auto.B<n>(합치기 전 단계 preflight·push·pr·merge),
#   합친 뒤 자동 모드 스크립트가 만든 .turn-merged.B<n>(deploy-wait·verify). guard 는 여기까지만 본다 — 파일 이름 꼴(B+숫자) · 2줄 = 만든 시각(초)이고
#   0~7200초 안 · 3줄 = 이 세션 ID(글자 그대로). 가지·카드·go= 대조는 스크립트가 한다. $1 = 파일 앞머리(.turn-auto. / .turn-merged.) · 하나라도 유효하면 0.
#   refactor-auto 낱말이 보이는 명령에서만 부른다(date 1회 — 평소 도구 호출엔 비용 0)
auto_grant() {
  hascs "$sid" '^[A-Za-z0-9_-]{1,128}$' || return 1
  local f l1 l2 l3 now="" re="^${1//./[.]}B[0-9]{1,6}\$"
  for f in "$rdir/$1"B*; do
    [ -f "$f" ] || continue
    hascs "${f##*/}" "$re" || continue
    l1=""; l2=""; l3=""
    { IFS= read -r l1; IFS= read -r l2; IFS= read -r l3; } < "$f" 2>/dev/null
    l2=${l2%$'\r'}; l3=${l3%$'\r'}
    hascs "$l2" '^[0-9]{1,12}$' || continue
    [ "$l3" = "$sid" ] || continue
    [ -n "$now" ] || now=$(date +%s 2>/dev/null)
    hascs "$now" '^[0-9]{1,12}$' || return 1
    l1=$((10#$now - 10#$l2))
    [ "$l1" -ge 0 ] && [ "$l1" -le 7200 ] && return 0
  done
  return 1
}
# 0.4.0 G2: 이 명령이 허락된 자동 모드 스크립트 호출 그대로인가 → 0(그때만 hv_human 의 실행 차단과 go 턴 안전 실행기 강제를 건너뛴다 — 다른 규칙은 그대로 본다).
#   도구가 Bash · 맨 위 명령(PTOP) · JSON 이스케이프(\" \/)만 푼 원문(앞뒤 공백 뗌)에 다른 역슬래시가 없고, 꼴이 정확히
#   bash <run.sh 경로> refactor-auto <단계> [인자…] [2>&1] — 경로는 따옴표("…", $ ` 없음) 또는 맨글자이고 . .. 를 정리하면 이 플러그인의 hooks/run.sh ·
#   단계 = preflight·push·pr·merge(유효한 .turn-auto 필요) / deploy-wait·verify(유효한 .turn-merged 필요) · 인자 = 따옴표 글("…", $ ` 없음) ·
#   맨글자 [A-Za-z0-9_./:@%+,=-] · "$CLAUDE_PROJECT_DIR" · "${CLAUDE_PROJECT_DIR}". 대소문자를 가린다
auto_ok() {
  [ "$tool" = Bash ] && [ "$PTOP" = 1 ] && [ -n "$plugroot" ] || return 1
  local r=${rawcmd//"$BS$Q"/$Q} p st kind qa='"[^"$`]+"' ua='[A-Za-z0-9_./:@%+,=~-]+' pd='"[$]CLAUDE_PROJECT_DIR"|"[$][{]CLAUDE_PROJECT_DIR[}]"' re
  r=${r//"$P_BSSL"/$SL}
  while [ "${r# }" != "$r" ]; do r=${r# }; done
  while [ "${r% }" != "$r" ]; do r=${r% }; done
  # Windows 경로(C:\…\run.sh — JSON 원문에서는 \\)는 첫 따옴표 경로 안에서만 / 로 바꿔 본다(그 밖의 역슬래시는 아래에서 막는다)
  case "$r" in 'bash "'*'"'*) p=${r#bash \"}; p=${p%%\"*}; st=${r#"bash \"$p\""}; p=${p//"$BS$BS"/$SL}; r="bash \"$p\"$st" ;; esac
  case "$r" in *"$BS"*) return 1 ;; esac
  # 보완(검사 A#5): 인자는 정확히 셋 — <프로젝트 폴더> <B 번호> <세션 ID>(7-execute 「8. 자동 마감」·입력 훅이 알려 주는 꼴). 프로젝트 폴더는 . .. 를 정리하면
  #   이 대화 프로젝트($proj — "$CLAUDE_PROJECT_DIR" 도 됨) · 세션 ID 는 훅 입력의 session_id 와 글자 그대로 같을 때만(합치기 0.3.5 처럼 꼴 고정)
  local pa sa
  re="^bash +(${qa}|${ua}) +refactor-auto +(preflight|push|pr|merge|deploy-wait|verify) +(${pd}|${qa}|${ua}) +B[0-9]{1,6} +([A-Za-z0-9_-]{1,128})( +2>&1)?\$"
  hascs "$r" "$re" || return 1
  p=${BASH_REMATCH[1]}; st=${BASH_REMATCH[2]}; pa=${BASH_REMATCH[3]}; sa=${BASH_REMATCH[4]}
  [ "$sa" = "$sid" ] || return 1
  p=${p#\"}; p=${p%\"}
  case "$p" in "~"*) return 1 ;; esac
  normpath "$p" "$cwd"
  [ "$NP" = "$plugroot/hooks/run.sh" ] || return 1
  case "$pa" in
    '"$CLAUDE_PROJECT_DIR"'|'"${CLAUDE_PROJECT_DIR}"') ;;
    *) pa=${pa#\"}; pa=${pa%\"}
       case "$pa" in "~"*) return 1 ;; esac
       normpath "$pa" "$cwd"; pa=$NP; normpath "$proj" /
       [ "$pa" = "$NP" ] || return 1 ;;
  esac
  case "$st" in deploy-wait|verify) kind=.turn-merged. ;; *) kind=.turn-auto. ;; esac
  auto_grant "$kind"
}
MSG_AUTO_EXEC="자동 모드 스크립트는 /refactor:approve B<n> 자동 으로 켠 묶음에서만 돕니다."
MSG_AUTO_NO="사용자에게 /refactor:approve B<n> 자동 을 입력해 달라고 하세요(승인 뒤 2시간 안 · 인자 없는 /refactor:go 한 차례 안에서만). 그 밖에는 푸시·합치기를 사용자가 /refactor:approve 푸시 · /refactor:approve 합치기 로 합니다."
# G2: 자동 모드 스크립트 실행 차단 — 이 세션의 자동 허락이 하나라도 유효하면 정해진 꼴을, 아니면 입력창 명령을 안내한다(막을 때만 허락 파일을 읽는다)
auto_block() {
  if auto_grant .turn-auto. || auto_grant .turn-merged.; then
    block "$MSG_AUTO_EXEC" "허락은 그대로입니다 — 7-execute 「8. 자동 마감」 의 명령을 다른 명령·래퍼와 섞지 않고 한 줄 그대로 실행하세요: bash \"$plugroot/hooks/run.sh\" refactor-auto <단계> …(preflight·push·pr·merge 는 합치기 전, deploy-wait·verify 는 합친 뒤)"
  fi
  block "$MSG_AUTO_EXEC" "$MSG_AUTO_NO"
}
# $1 판정용 문자열 하나가 "허락된 가지($2)로 보내는 정확한 push 한 번" 인가. 조각(&& || ; | & ( ) 백틱 줄바꿈)으로 나눠
#   push 낱말(따옴표 뗀 뒤 대소문자 무시)이 정확히 한 번 · 그 조각이 git push [-u|--set-upstream] origin <가지>(가지는 따옴표 한 쌍까지) [2>&1] 뿐 ·
#   그 조각에 \ 없음 · 모든 조각의 첫 낱말이 git·echo·tail·head·true·wc(0.3.4 T7 허용 목록 — 작업 폴더·저장소·git 을 바꾸는 조각이 끼지 않게) ·
#   2>&1 꼴 말고 리다이렉트 글자(> <) 없음(0.3.4 F11)
push_exact() {
  local s=$1 ab=$2 re_dup='[0-9]?>&[0-9]([[:space:]|;&)]|$)' seg n=0 ps="" t w i
  # 파일 번호끼리 잇기(2>&1 · >&2)는 숫자 바로 뒤가 공백·| ; & )·끝일 때만 지운다(뒤 글자는 남김) — >&2file 은 파일 리다이렉트라 아래에서 막힌다
  while [[ $s =~ $re_dup ]]; do s=${s/"${BASH_REMATCH[0]}"/ ${BASH_REMATCH[1]}}; done
  # 0.3.4 F11: 파일 번호끼리 잇기(2>&1) 말고 리다이렉트 글자(> <)가 남아 있으면 막는다 — 같은 명령의 다른 조각이 파일(.git/hooks 등)을 쓰거나 읽지 않게
  case "$s" in *[\<\>]*) return 1 ;; esac
  s=${s//&&/$NL}; s=${s//||/$NL}; s=${s//;/$NL}; s=${s//|/$NL}; s=${s//&/$NL}; s=${s//(/$NL}; s=${s//)/$NL}; s=${s//\`/$NL}
  while [ -n "$s" ]; do
    seg=${s%%"$NL"*}; if [ "$seg" = "$s" ]; then s=""; else s=${s#*"$NL"}; fi
    set -f; w=($seg); set +f
    for t in "${w[@]}"; do
      t=${t//\"/}; t=${t//\'/}
      case "$t" in
        [Pp][Uu][Ss][Hh]) n=$((n + 1)); ps=$seg ;;
      esac
    done
    t=${w[0]:-}; t=${t//\"/}; t=${t//\'/}
    # 0.3.4 T7: 조각의 첫 낱말은 허용 목록만(빈 조각 포함) — 막을 목록(cd·pushd·…)은 대입·export·함수 정의·중괄호·제어 낱말·trap 뒤의
    #   폴더·저장소·git 바꾸기를 못 따라간다. git 조각은 둘째 낱말이 옵션(-C·-c·--git-dir …)·config·remote 가 아닐 때만
    #   (0.3.4 F11: printf 는 뺀다 — printf -v PATH … 로 내보낸 변수를 바꿔 뒤 git 이 다른 프로그램이 될 수 있다)
    case "$t" in ""|git|echo|tail|head|true|wc) ;; *) return 1 ;; esac
    case "$t" in [Gg][Ii][Tt]) case "${w[1]//[\"\']/}" in -*|[Cc][Oo][Nn][Ff][Ii][Gg]|[Rr][Ee][Mm][Oo][Tt][Ee]) return 1 ;; esac ;; esac
  done
  [ "$n" = 1 ] || return 1
  case "$ps" in *"$BS"*) return 1 ;; esac
  set -f; w=($ps); set +f
  [ "${w[0]:-}" = git ] && [ "${w[1]:-}" = push ] || return 1
  i=2
  { [ "${w[2]:-}" = -u ] || [ "${w[2]:-}" = --set-upstream ]; } && i=3
  [ "${w[$i]:-}" = origin ] || return 1
  i=$((i + 1)); t=${w[$i]:-}
  case "$t" in \"*\") t=${t#\"}; t=${t%\"} ;; \'*\') t=${t#\'}; t=${t%\'} ;; esac
  [ -n "$t" ] && [ "$t" = "$ab" ] || return 1
  [ "${#w[@]}" -eq $((i + 1)) ]
}

# 허락 push 의 자리 확인(검사 보완 F3·F4) → 통과면 0, 아니면 PW 에 까닭. 정확한 꼴 판정이 모두 맞은 뒤에만 부른다(git 1회)
#   F3: 훅 입력의 작업 폴더(BRCWD — check_shell 이 정규화, 비었으면 빈 값)가 프로젝트 폴더이거나 그 아래 — 앞 호출의 cd 로 다른 저장소에 있으면 막는다
#       (0.3.4 T8: 그 아래라도 프로젝트 폴더까지 올라가는 길에 .git 이 있으면 프로젝트 안의 다른 저장소라 막는다)
#   F4: 프로젝트 저장소 설정에 remote.origin.push(올리기 규칙)가 있으면 허락된 가지 말고 다른 가지로 갈 수 있어 막는다. git 이 없거나,
#       origin 주소(remote.origin.url)가 안 보이면(git 저장소가 아님 · origin 없음 — 설정이 없을 때와 종료 코드가 같아 주소로 가린다) 막는다
push_where() {
  PW=""; PWH="푸시 허락으로는 올릴 수 없는 저장소 설정입니다 — 사람이 터미널에서 올립니다."
  local pn out ln v inp=0 nc=0
  normpath "$proj" /; pn=$NP
  # K1: 리눅스·맥 경로(WINPATH=0)는 대소문자를 가린다 — 전역 nocasematch 를 이 비교에서만 끈다(대소문자만 다른 다른 저장소를 프로젝트로 보지 않게)
  if [ -n "${BRCWD:-}" ] && [ "$pn" != / ]; then
    if [ "$WINPATH" = 1 ]; then
      case "$BRCWD/" in "$pn"/*) inp=1 ;; esac
    else
      shopt -q nocasematch && nc=1; shopt -u nocasematch
      case "$BRCWD/" in "$pn"/*) inp=1 ;; esac
      [ "$nc" = 1 ] && shopt -s nocasematch
    fi
  fi
  if [ "$inp" = 0 ]; then
    PW="(지금 작업 폴더가 리팩토링 프로젝트 밖입니다)"; PWH="프로젝트 폴더로 옮긴 뒤(cd 는 따로 한 번 실행) 같은 꼴로 다시 — 허락은 그대로입니다."; return 1
  fi
  # 0.3.4 T8: 프로젝트 안의 다른 저장소(중첩 저장소·서브모듈·프로젝트 안 링크 → 밖 저장소 · 같은 저장소 워크트리도) — 작업 폴더에서 프로젝트 폴더
  #   바로 아래까지 한 칸씩 올라가며 .git(폴더·파일)이 있으면 막는다(push 는 작업 폴더의 저장소 원격으로 간다). 외부 명령 0
  local up=${BRCWD%/} upo
  while [ "${#up}" -gt "${#pn}" ]; do
    if [ -e "$up/.git" ]; then
      PW="(지금 작업 폴더가 프로젝트 안의 다른 git 저장소입니다 — 서브모듈·중첩 저장소·링크)"; PWH="프로젝트 폴더로 옮긴 뒤(cd 는 따로 한 번 실행) 같은 꼴로 다시 — 허락은 그대로입니다."; return 1
    fi
    upo=$up; up=${up%/*}; [ "$up" = "$upo" ] && break
  done
  command -v git >/dev/null 2>&1 || { PW="(git 을 찾지 못했습니다)"; return 1; }
  # F4·K4: 올리기 규칙(remote.origin.push)이 있거나, push.default 가 upstream·tracking(가지의 upstream 으로 감 — 허락된 가지 이름과 다른 원격 가지로 갈 수 있음)이면 막는다
  out=$(git --no-replace-objects -c core.fsmonitor=false -C "$proj" config --get-regexp '^(remote[.]origin[.](url|push)|push[.]default)$' 2>/dev/null)
  case "$NL$out$NL" in
    *"${NL}remote.origin.push${NL}"*|*"${NL}remote.origin.push "*) PW="원격에 올리기 규칙(remote.origin.push)이 설정돼 있어 허락 push 를 쓸 수 없습니다 — 사람이 터미널에서 올립니다."; return 1 ;;
  esac
  while IFS= read -r ln; do
    case "$ln" in
      "push.default "*) v=${ln#push.default }
        case "$v" in [Uu][Pp][Ss][Tt][Rr][Ee][Aa][Mm]|[Tt][Rr][Aa][Cc][Kk][Ii][Nn][Gg]) PW="push.default 가 $v 라 허락된 가지가 아닌 원격 가지로 올라갈 수 있습니다."; return 1 ;; esac ;;
    esac
  done <<PWOUT
$out
PWOUT
  case "$NL$out" in
    *"${NL}remote.origin.url "*) return 0 ;;
  esac
  PW="(origin 원격 주소를 확인하지 못했습니다 — git 저장소가 아니거나 origin 이 없음)"; return 1
}

check_shell() { # $1(있으면) = 판정할 명령(JSON 이스케이프 그대로). 없으면 도구 입력의 command 칸
  local rawcmd
  if [ "$#" -gt 0 ]; then rawcmd=$1; else jget command; rawcmd=$JV; fi
  [ "${#rawcmd}" -gt 16384 ] && block "명령이 너무 깁니다(16KB 초과) — 파일로 저장해 실행하세요." "Write 도구로 스크립트 파일을 만들고, 무엇을 하는지 사용자에게 보여 준 뒤 bash <파일> 로 실행하세요."
  unesc_line "$rawcmd"; local cmd=$UV cmds=$UVS
  [ -z "$cmd" ] && return 0
  local m0 m4 pre rest seg SQLRAW=""
  # 명령이 실행되는 폴더(Bash 도구의 현재 폴더) — 와일드카드 파일 이름을 실제로 펼쳐 볼 때 쓴다
  jget cwd; unesc_line "$JV"; cwd=${UV//"$BS"/$SL}; cwd=${cwd%/}
  # 가지 강제 삭제 허용 판정(br_judge)의 결과·문구 — 이 호출에서 한 번만. 허용은 Bash 도구의 맨 위 명령(인자 없이 부른 check_shell)일 때만.
  #   도구 입력에 작업 폴더(cwd)가 없거나 비었으면 BRCWD 를 비워 둔다(프로젝트 폴더로 짐작해 판정하지 않는다)
  local BRV="" BRM1="" BRM2="" BRTOP=0 BRCWD=""
  if [ -z "$cwd" ]; then cwd=$proj; else BRCWD=1; fi
  normpath "$cwd" /; cwd=$NP
  [ -n "$BRCWD" ] && BRCWD=$cwd
  [ "$#" -eq 0 ] && [ "$tool" = Bash ] && BRTOP=1
  local PTOP=0; [ "$#" -eq 0 ] && PTOP=1   # push 허락(0.3.3)은 도구 입력의 맨 위 명령에만(bash -c 안쪽 등 다시 부른 판정에는 쓰지 않는다)

  # 판정용 모양(mk_views): 정규화한 명령(cmd) · lr · lx. 비밀값 판정용 사본(cmds, heredoc 본문을 줄 단위로 거른 것)이 다르면 그것으로도 lx 를 만든다
  local lxs="" cmd0=$cmd
  mk_views "$cmd"; cmd=$NC; lr=$LR; local lx=$LX
  local LRS=""
  if [ "$cmds" != "$cmd0" ]; then mk_views "$cmds"; lxs=$LX; LRS=$LR; fi
  # git -c 로 별칭을 만들어 실행하거나 clean 안전 설정을 끄는 길, 위험 명령 별칭을 저장하는 길
  if has "$cmd" "git[[:space:]]+([^;&|]*[[:space:]])?-c[[:space:]]*[\"']?alias[.]"     || has "$cmd" "git[[:space:]][^;&|]*config[^;&|]*alias[.][^[:space:]]+[[:space:]][^;&|]*(reset|clean|checkout|restore|push|stash|branch|filter|reflog|gc|update-ref|!)"; then
    block "git 별칭(alias)으로 명령 이름을 바꿔 실행하지 않습니다(안전장치 판정을 피하는 길)." "원래 git 명령을 그대로 쓰세요."
  fi
  if has "$cmd" "clean[.]requireforce[[:space:]]*=[[:space:]]*[\"']?(false|0|no|off)"; then
    block "git clean 안전 설정(clean.requireForce)을 끄는 명령은 막혀 있습니다." "지울 목록만 보려면 git clean -n (사람이 확인 후 직접 실행)."
  fi
  mk_lq "$lr"; lq=$LQ
  # 원격 주소 판정용(lqs·lrs): heredoc 본문을 줄 단위로 거른 사본이 있으면 그것으로(문서에 쓴 "git remote get-url origin" 글은 아니다)
  local lqs=$lq lrs=$lr
  if [ -n "$lxs" ]; then lrs=$LRS; mk_lq "$lrs"; lqs=$LQ; fi

  # lq·lx 를 만든 뒤에는 나머지 판정용 lr 도 단순 따옴표 인자를 벗긴다('node' -e … · cat '.env' 도 같은 명령으로)
  #   0.3.7 G6: 벗기기 전 사본 lr0 — 히어독 본문의 open('…','w') 는 벗기면 open(…,w) 가 되어 쓰기 낱말 판정을 비껴간다(interp_writes 가 둘 다 본다)
  lr0=$lr
  unquote_simple "$lr"; lr=$UQ
  # 판정용 변형(mk_variant: $'…' 풀기·단어 가운데 빈 변수·{a,b} 펼치기·역슬래시 풀기)을 원형 뒤에 덧붙여 같이 본다
  # (git re\set · git re${x}set · cat .e$'\x6e'v · --from{-hook,}). 원형은 그대로(윈도우 경로 C:\… 판정). popd = cd 기준 폴더 되돌리기
  local lqv lz
  mk_variant "$lq"; lqv=$VV; [ "$VV" != "$lq" ] && lq="$lq ; popd ; $VV"
  mk_variant "$lx"; [ "$VV" != "$lx" ] && lx="$lx ; popd ; $VV"
  if [ -n "$lxs" ]; then mk_variant "$lxs"; [ "$VV" != "$lxs" ] && lxs="$lxs ; popd ; $VV"; fi
  # lz: 따옴표 글자를 모두 뺀 사본(claude -p '/refactor:app'"rove" · bash -c "git re"'set --hard' · eval "n"'pm test') —
  #     공백 든 문자열까지 붙여 버리므로 과잉차단을 피해 고가치 규칙(승인·훅 진입점·중첩 claude·git 파괴·go 안전 실행기)에만 쓴다
  lz=${lqv//\'/}; lz=${lz//\"/}; [ "$lz" = "$lqv" ] && lz=""
  # hv: 고가치 규칙 전용 — 정의되지 않은 변수 참조를 문자열 처리로 지운 사본(refactor-app${m}rove → refactor-approve · git re${x:-s}et → git reset).
  #     가드 자신의 환경을 안 쓰므로 가드 내부 변수명이 입력에 영향을 주지 않는다. 이미 정의된 사용자 변수는 expand_vars 가 먼저 값으로 바꾸므로 여기 안 남는다.
  #     고가치 규칙(승인·훅 진입점·중첩 claude·git 파괴·go 안전 실행기)에만 쓴다 → 지워서 위험 이름이 사라지면 못 잡을 뿐(거짓 음성), 없던 위험을 만들지 않는다.
  local hv="" hvz=""
  blank_vars "$lq"; [ "$BV" != "$lq" ] && hv=$BV
  [ -n "$lz" ] && { blank_vars "$lz"; [ "$BV" != "$lz" ] && hvz=$BV; }

  # 1) 사람 전용 ------------------------------------------------------------
  # 0.3.5 G3: 합치기 낱말(refactor-merge — 원형·따옴표 뺀 사본·변수 지운 사본)이 보일 때만 허락을 읽어 "허락된 명령 그대로"인지 본다(MOK).
  #   MG = 허락 파일이 유효했나(빈 값 = 아직 안 읽음 — 글로브 꼴로 막힐 때 merge_block 이 그때 읽는다)
  local MOK=0 MG="" ML=""
  if has "$cmd0$NL$lq$NL$lz$NL$hv$NL$hvz" 'refactor-merge'; then merge_ok && MOK=1; fi
  # 0.4.0 G2: 자동 모드 낱말(refactor-auto)이 보일 때만 허락을 읽어 "허락된 꼴 그대로"인지 본다(AOK)
  local AOK=0
  if has "$cmd0$NL$lq$NL$lz$NL$hv$NL$hvz" 'refactor-auto'; then auto_ok && AOK=1; fi
  # 승인·훅 진입점·중첩 claude(새 Claude 세션은 그 입력을 사람 입력으로 본다) — 원형과 따옴표를 모두 뺀 사본(lz) 둘 다.
  # 승인 스크립트는 실행하는 모양만 막는다(cat·grep·head 로 읽는 것은 통과)
  hv_human "$lq" "$lr"
  [ -n "$lz" ] && hv_human "$lz" "$lz"
  [ -n "$hv" ] && hv_human "$hv" "$hv"
  [ -n "$hvz" ] && hv_human "$hvz" "$hvz"
  if claude_resume_print "$lq" || { [ -n "$hv" ] && claude_resume_print "$hv"; }; then block "$MSG_RESUME" "$MSG_RESUME2"; fi
  # 0.3.5: 합치기 스크립트 판정을 먼저 — 승인 이름 정규식(run.sh 뒤 24글자 안의 turn·guard…)이 경로 글자(예: /tmp/guardtest-…)에 걸려 안내 문구가 바뀌지 않게(둘 다 막음)
  #   0.3.7 G5: 승인 스크립트 낱말(refactor-approve)도 보이면 합치기 안내 대신 아래 승인 문구로(허락이 살아 있을 때 합치기 명령을 다시 권하지 않게)
  [ "$MOK" != 1 ] && ! has "$lr" 'refactor-approve' && interp_approve "$lr" 'refactor-merge' && merge_block
  # 0.4.0 G2: 인터프리터 코드(python -c · node -e · 히어독) 안의 자동 모드 스크립트도 같은 판정 — 승인 스크립트 낱말이 함께 보이면 아래 승인 문구로
  [ "$AOK" != 1 ] && ! has "$lr" 'refactor-approve' && interp_approve "$lr" 'refactor-auto' && auto_block
  interp_approve "$lr" && block "$MSG_APPROVE_EXEC" "$MSG_APPROVE"
  if writes_to '(docs/refactor/)?\.allow-[a-z-]+|approvals\.log|docs/refactor/\.turn|docs/refactor/approved/' || interp_writes '\.allow-|approvals\.log|docs/refactor/\.turn|docs/refactor/approved/'; then
    block "허용 파일(.allow-*)·승인 기록(APPROVALS.log)·.turn 은 사람과 플러그인만 만들고 지웁니다." "$MSG_HUMAN"
  fi
  # docs/refactor 안의 파일이나 .md 문서를 프로그램으로 실행하지 않는다(기록 폴더에 스크립트를 두고 돌리는 길)
  # (. 는 명령 자리일 때만 source 다 — find . -name '*.md' 의 . 은 폴더)
  if md_exec "$lq" \
    || has "$lq" "(^|[;&|({\`])[[:space:]]*(sudo[[:space:]]+)?\\.[[:space:]]+[\"']?[^[:space:]\"';&|]*(docs/refactor/[^[:space:];&|]*|[.]md)([\"'[:space:];&|)]|$)" \
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
  # 0.3.5 X2: 인터프리터 코드(python -c open(…,'w') · node -e appendFileSync …)로 플러그인 폴더에 쓰기 — 같은 경로(.claude/plugins + 지금 플러그인 폴더)
  interp_plug_writes && block "플러그인 폴더(.claude/plugins)는 고치지 않습니다." "플러그인 수정은 사람이 원본 저장소에서 합니다."
  # 쓰기 대상(목적지) 기준: 사람 전용 파일, 기록 폴더 이동·개명, 플러그인 폴더, 읽기 전용 단계의 프로젝트 파일
  norm_dirvars "$lq"; local tq=$NV pb=${plugroot##*/} tchk=0
  has "$tq" 'approvals|allow-|[.]turn|approved|refactor|state[.]md|docs|[.][.]|plugins|>' && tchk=1
  if [ -n "$plugroot" ]; then case "$cwd/" in "$plugroot"/*) tchk=1 ;; esac; [ -n "$pb" ] && case "$tq" in *"$pb"*) tchk=1 ;; esac; fi
  [ "$fence" = 1 ] && tchk=1
  [ "$tchk" = 1 ] && shell_targets "$tq"
  # 0.4.0 WC: 기록 폴더나 그 상위로 폴더째·와일드카드 복사·옮기기 · 거기에 압축 풀기 · 링크(복사·풀기·링크 낱말이 보일 때만 — tar xf x.tar 처럼 docs 낱말이 없어도)
  has "$tq" '(^|[^[:alnum:]_.-])(cp|copy|copy-item|cpi|install|rsync|scp|xcopy|robocopy|mv|move|move-item|mi|ln|mklink|tar|bsdtar|unzip|7z|7za|7zr)([.]exe)?([[:space:]"'"'"']|$)' && copy_dir_targets "$tq"
  has "$tq" '(^|[^[:alnum:]_.-])(expand-archive|new-item|ni)([[:space:]"'"'"']|$)' && copy_dir_targets "$tq"   # FC F6: PowerShell 풀기·링크

  # 2) 비밀값 ---------------------------------------------------------------
  # 명령 전체를 한 덩어리로 본다: 비밀값 파일 이름이 나오고(이름·존재만 보는 명령 조각은 제외), 명령 어딘가에
  # 내용을 읽기·옮기기·보내기·실행하는 동작이 있으면 막는다. 조각마다 따로 보면 파이프·$( )로 나뉜 명령을 놓친다.
  # sx = 원형(lx)으로 만든 판정 문자열(환경변수 덤프·키 파일·넓은 검색용), sxs = heredoc 본문을 줄 단위로 거른 사본(lxs)으로 만든 것(비밀값 파일 판정용)
  mk_sx "$lx"; local sx=$SX sxs=$SX
  [ -n "$lxs" ] && { mk_sx "$lxs"; sxs=$SX; }
  local SEC_ALT='\.env([._-][[:alnum:]_.-]*)?|\.dev\.vars([.][[:alnum:]_.-]+)?|\.git-credentials|\.npmrc|\.pgpass|\.git/config|\.aws/credentials|\.docker/config\.json|\.kube/config'
  local re_env="(^|[[:space:]\"'=:/<>(|;&@,[])(${SEC_ALT}|[[:alnum:]_-]+\\.env|/proc/[^[:space:]/]+/environ)([^[:alnum:]_.-]|$)"
  local re_key="(\\.(pem|p12|pfx|jks|keystore)|(^|[^[:alnum:]])id_(rsa|dsa|ecdsa|ed25519)|service[-_]?account[^[:space:]\"']*\\.json|firebase-adminsdk[^[:space:]\"']*\\.json|client_secret[^[:space:]\"']*\\.json|(^|[^[:alnum:]_])(credentials\\.json|secrets\\.(json|ya?ml|toml)|\\.netrc|\\.pypirc|\\.secrets))([^[:alnum:]_.]|$)"
  local re_keyfile="(^|[[:space:]\"'=/@])[[:alnum:]_.-]+\\.key([[:space:]\"')]|$)"
  local readverb="${S}(cat|bat|less|more|head|tail|nl|od|xxd|hexdump|strings|grep|egrep|fgrep|rg|ag|ack|awk|gawk|mawk|sed|cut|sort|uniq|diff|cmp|comm|paste|column|cp|mv|scp|rsync|install|tee|xargs|export|python|python3|py|node|ruby|perl|php|deno|bun|tsx|ts-node|sh|bash|zsh|dash|source|base64|openssl|gpg|curl|wget|nc|ncat|socat|dd|tar|zip|gzip|bzip2|xz|7z|read|mapfile|readarray|vi|vim|nvim|nano|emacs|code|open|type|get-content|gc|copy-item|cpi|move-item|compress-archive|select-string|findstr|envsubst|jq|yq|rm|unlink|shred|truncate)${E}"
  local fileverb="${S}(cat|bat|less|more|head|tail|nl|od|xxd|hexdump|strings|cp|mv|scp|rsync|base64|openssl|curl|dd|type|get-content|gc|copy-item|vi|vim|nvim|nano|emacs|code|open)${E}"
  local indirect=0 hit=0 envdump=0 ts_ok=0
  has "$sxs" 'xargs|[$][(]|`|<[(]|(^|[;&|[:space:]])(read|mapfile|readarray|eval|parallel)([[:space:]]|$)|[[:space:]]-(exec|execdir|ok|okdir)([[:space:]]|$)|[|][[:space:]]*(sudo[[:space:]]+)?(ba|z|da|k)?sh([[:space:]]|$)' && indirect=1
  # 명령 치환 등(indirect)이 있어도 test·[ 로 존재만 보는 조각은 이름 확인이다 — 단 그 조각이 모두 "이름 확인만 하는 명령 치환" 안에 있을 때만
  # (test_only_subst: echo "있나: $(test -f .env && echo yes)"). cat $(test -f .env && echo .env) · test -f .env && cat $(…) 는 예전대로 본다
  if [ "$indirect" = 1 ]; then blank_vars "$lr"; test_only_subst "$lr$NL$BV" "$cmd0" && ts_ok=1; fi
  local segs=$sx
  segs=${segs//&&/$NL}; segs=${segs//||/$NL}; segs=${segs//;/$NL}; segs=${segs//|/$NL}; segs=${segs//(/$NL}; segs=${segs//\`/$NL}
  rest=$segs
  while [ -n "$rest" ]; do
    seg=${rest%%"$NL"*}
    if [ "$seg" = "$rest" ]; then rest=""; else rest=${rest#*"$NL"}; fi
    if has "$seg" '(^|[[:space:](){}])(env|set|export|printenv|declare|typeset)([[:space:](){}]|$)' && env_dump_seg "$seg"; then envdump=1; fi
    if has "$seg" "$re_keyfile" && has "$seg" "$fileverb"; then
      block "키 파일(.key)의 내용을 보거나 복사·전송하는 명령은 막혀 있습니다." "파일 이름과 git 추적 여부만 확인하세요(git ls-files, ls -a)."
    fi
  done
  # 비밀값 파일 이름이 나오는가(heredoc 본문은 거른 사본 sxs 로)
  rest=$sxs
  rest=${rest//&&/$NL}; rest=${rest//||/$NL}; rest=${rest//;/$NL}; rest=${rest//|/$NL}; rest=${rest//(/$NL}; rest=${rest//\`/$NL}
  while [ -n "$rest" ]; do
    seg=${rest%%"$NL"*}
    if [ "$seg" = "$rest" ]; then rest=""; else rest=${rest#*"$NL"}; fi
    if is_meta_seg "$seg"; then
      [ "$indirect" = 0 ] && continue
      [ "$ts_ok" = 1 ] && has "$seg" "$RE_TESTSEG" && continue
    fi
    if has "$seg" "$re_env" || has "$seg" "$re_key" || seg_glob_secret "$seg" || seg_short_secret "$seg"; then hit=1; break; fi
  done
  if [ "$hit" = 1 ]; then
    if has "$sxs" "$readverb" \
      || has "$sxs" '(^|[;&|(])[[:space:]]*(\.|source)[[:space:]]+' \
      || has "$sxs" "(^|[^<])<[[:space:]]*[\"']?[^[:space:]\"'<>]*(${SEC_ALT}|[[:alnum:]_-]+\\.env)" \
      || has "$sxs" 'git[[:space:]]+(add|show|diff|grep|blame|cat-file|archive|log[^;&|]*[[:space:]](-p|--patch|-u))([[:space:]]|$)' \
      || has "$sxs" ">>?[[:space:]]*[\"']?[^[:space:]]*(${SEC_ALT})"; then
      block "비밀값 파일(.env·키 파일 등)의 내용을 보거나 복사·전송·수정·삭제하는 명령은 막혀 있습니다." "이름·추적 여부만 확인하세요: git ls-files, git check-ignore -v .env, ls -a. 어떤 변수가 있는지는 안전 실행기 --check(이름만 출력)로 보세요. 코드에서 '.env' 글자를 찾으려면 Grep 도구(files_with_matches)를 쓰세요."
    fi
  fi
  # .env가 있는 프로젝트에서 프로젝트 전체(또는 그 위 폴더)를 셸 명령으로 내용 검색하면 .env 줄이 찍힌다
  # (grep -r · rg -uu/--hidden/--no-ignore · findstr /s · Select-String · gci -Recurse | sls). 좁은 --include·-g·폴더 지정은 통과
  local MSG_WS="검색할 폴더를 지정하거나(예: src), -l(파일 이름만), --include=\"*.ts\" 로 파일 종류를 좁히세요."
  rest=$segs; local wprev=""
  while [ -n "$rest" ]; do
    seg=${rest%%"$NL"*}
    if [ "$seg" = "$rest" ]; then rest=""; else rest=${rest#*"$NL"}; fi
    case "$seg" in *grep*|*rg*|*findstr*|*select-string*|*sls*) ;; *) wprev=$seg; continue ;; esac
    if wide_search_seg "$seg" "$wprev" && env_near; then
      block "이 프로젝트에는 .env가 있어서, 프로젝트 전체를 내용 검색하면 비밀값 줄이 찍힐 수 있습니다." "$MSG_WS"
    fi
    wprev=$seg
  done
  # grep … $(ls -A) · grep … $(find .) 처럼 명령 치환으로 넓은 파일 목록(숨김 파일 포함)을 넘기는 검색
  local re_gls="(^|[;&|(\`[:space:]])(e|f)?grep[[:space:]]([^;&|]*)[$][(]([^)]*)[)]|(^|[;&|(\`[:space:]])rg[[:space:]]([^;&|]*)[$][(]([^)]*)[)]"
  rest=$lx
  while [[ $rest =~ $re_gls ]]; do
    rest=${rest#*"${BASH_REMATCH[0]}"}; m0=" ${BASH_REMATCH[3]}${BASH_REMATCH[6]} "; m4="${BASH_REMATCH[4]}${BASH_REMATCH[7]}"
    hascs "$m0" '[[:space:]](-[a-zA-Z]*[lLcq][a-zA-Z]*|--files-with(out)?-match(es)?|--count|--quiet)[[:space:]]' && continue
    if lists_wide "$m4" && env_near; then
      block "이 프로젝트에는 .env가 있어서, 프로젝트 전체를 내용 검색하면 비밀값 줄이 찍힐 수 있습니다." "$MSG_WS"
    fi
  done
  if ps_wide_search "$lx" && env_near; then
    block "이 프로젝트에는 .env가 있어서, 프로젝트 전체를 내용 검색하면 비밀값 줄이 찍힐 수 있습니다." "$MSG_WS"
  fi
  # 환경변수 통째 출력·비밀값 변수 출력
  if [ "$envdump" = 1 ] \
    || ps_env_provider "$lx" \
    || has "$lr" '\[(system[.])?environment\]::getenvironmentvariables' \
    || ps_getenv_sens "$lr" \
    || echo_sens "$lr" \
    || { [ "$tool" = "PowerShell" ] && ps_env_read; } \
    || { has "$lr" '<<-?[[:space:]]*[A-Za-z_]' && vars_sensitive "$lr"; } \
    || herestr_sens "$lr" \
    || awk_env_print "$lr" \
    || jq_env "$lr" \
    || { has "$lr" "${S}(node|python3?|py|deno|bun|ruby|php|perl|tsx|ts-node)([[:space:]][^;&|]*)?[[:space:]](-e|-c|-p|-r|--eval|--print|-[a-z]*e)[[:space:]]" \
         && has "$lr" 'process[.]env|os[.]environ|import[.]meta[.]env|getenv|env\[|dotenv|load_dotenv|%env|[$]env[{]' \
         && { has "$lr" "[[:space:]](-p|--print)[[:space:]]" || has "$lr" 'console[.](log|dir|error|info|table|warn|debug|trace)|std(out|err)[.]write|print|json[.](stringify|dumps)|puts|echo|var_dump|say[[:space:]]'; } \
         && ! env_refs_safe "$lr"; }; then
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
  if remote_url_out "$lqs" && ! has "$lrs" '[*][*][*][*]'; then
    block "원격 저장소 주소에는 토큰이 들어 있을 수 있어 그대로 출력하지 않습니다." "가려서 보세요: git remote -v | sed -E 's#//[^/@]*@#//****@#'"
  fi

  # 3) 되돌릴 수 없는 git 명령 ---------------------------------------------
  hv_git "$lq"
  [ -n "$lz" ] && hv_git "$lz"
  [ -n "$hv" ] && hv_git "$hv"
  [ -n "$hvz" ] && hv_git "$hvz"

  # 4) 대량 삭제 ------------------------------------------------------------
  # 원형(lq)과 따옴표를 모두 뺀 사본(lz)·빈 변수를 지운 사본(hv·hvz)으로 본다(eval "rm -rf doc"'s/refactor' · rm -rf docs/re${x:-f}actor)
  hv_del "$lq"
  [ -n "$lz" ] && hv_del "$lz"
  [ -n "$hv" ] && hv_del "$hv" 1
  [ -n "$hvz" ] && hv_del "$hvz" 1
  del_scan "$tq"
  interp_del_big "$lr" && block "$MSG_RM_BIG" "$MSG_RM_HINT"
  # 지울·옮길 대상이 명령 치환($( )·` `)이면 무엇을 지우는지 판정할 수 없다(rm -rf "$(git rev-parse --show-toplevel)")
  local q_="[\"']?" re_csdel; re_csdel="${S}(sudo[[:space:]]+)?(rm[[:space:]]+([^;&|]*[[:space:]])?(-[a-z]*r[a-z]*|--recursive)[[:space:]]+([^;&|]*[[:space:]])?|(rmdir|rd)[[:space:]]+([^;&|]*[[:space:]])?|(mv|move-item|mi)[[:space:]]+(-[^[:space:]]+[[:space:]]+)*)${q_}([$][(]|\`)"
  has "$tq" "$re_csdel" && block "지울 대상이 명령 결과라 판정할 수 없습니다 — 경로를 직접 쓰세요." "지울 폴더를 정확한 경로로 적으세요. 큰 삭제는 사람이 직접 합니다."

  # 5) DB 삭제·초기화 ------------------------------------------------------
  # 원형과 사본(lz·hv·hvz) 모두(bash -c "supa"'base db reset' · sh -c "drop"'db x')
  hv_db "$lq"
  [ -n "$lz" ] && hv_db "$lz"
  [ -n "$hv" ] && hv_db "$hv"
  [ -n "$hvz" ] && hv_db "$hvz"

  # ── 여기부터는 리팩토링 진행 중에만 ── (하위 에이전트 지시문 판정에서는 건너뛴다: 하위 에이전트의 도구 호출이 따로 판정된다)
  [ "$refactor_on" = 1 ] || return 0
  [ "${AGENT_MODE:-0}" = 1 ] && return 0

  # 0.3.4 T6: 원격 저장소 주소·올리기 설정 바꾸기(바꾼 뒤의 허락 push 가 다른 저장소로 갈 수 있다) — 원형과 사본(lz·hv·hvz) 모두
  if rmt_write "$lq" || { [ -n "$lz" ] && rmt_write "$lz"; } || { [ -n "$hv" ] && rmt_write "$hv"; } || { [ -n "$hvz" ] && rmt_write "$hvz"; }; then
    block "리팩토링 중에는 원격 저장소·올리기 설정을 바꾸지 않습니다(바꾼 뒤의 push 가 다른 저장소로 갈 수 있음)." "원격 저장소·올리기 설정 변경은 사람이 터미널에서 합니다 — 필요하면 멈추고 사람에게 부탁하세요. 읽기(git remote · git config --get <키>)는 됩니다."
  fi

  if has "$lq" 'git[[:space:]]+push'; then
    # 0.3.3: 사람이 /refactor:approve 푸시 로 허락한 턴이면 맨 위 명령의 정확한 꼴(git push [-u] origin <허락된 가지>)만 통과.
    #   판정용 사본(원형 cmd0·lq·lz·hv·hvz) 모두가 정확한 꼴이어야 하고, 줄 이어쓰기·역슬래시(JSON 의 \\)가 있으면 막는다
    local push_hint="단계 커밋은 그대로 두고, 사람이 터미널에서 git push 로 실행하게 하세요(CLI 라면 입력창에 ! git push 도 됨). 원격이라 터미널이 없으면 사용자에게 /refactor:approve 푸시 를 입력해 달라고 하세요(작업 가지만 · 그 차례에만)."
    if [ "$PTOP" = 1 ] && push_grant; then
      case "$rawcmd" in *"$BS$BS"*) false ;; *) true ;; esac \
        && push_exact "$cmd0" "$PB" && push_exact "$lq" "$PB" \
        && { [ -z "$lz" ] || push_exact "$lz" "$PB"; } && { [ -z "$hv" ] || push_exact "$hv" "$PB"; } && { [ -z "$hvz" ] || push_exact "$hvz" "$PB"; } \
        || block "리팩토링 진행 중에는 push를 사람이 직접 합니다(push가 자동 배포로 이어질 수 있음)." "$push_hint 허락된 꼴은 git push -u origin $PB 뿐입니다."
      push_where || block "리팩토링 진행 중에는 push를 사람이 직접 합니다(push가 자동 배포로 이어질 수 있음). $PW" "$PWH"
    else
      block "리팩토링 진행 중에는 push를 사람이 직접 합니다(push가 자동 배포로 이어질 수 있음)." "$push_hint"
    fi
  fi
  if has "$lq" 'git[[:space:]]+stash([[:space:]]|$)' && ! has "$lq" 'git[[:space:]]+stash[[:space:]]+(list|show)'; then
    block "리팩토링 중에는 git stash를 쓰지 않습니다(다른 작업이 섞여 사라질 수 있음)." "커밋이 필요하면 7-execute 5-1 대로 그 단계 파일만 — 단계 밖 변경이면 멈추고 사람에게 알리세요."
  fi
  # 0.3.2: 다른 가지·커밋으로 옮기기 — 기록 폴더(STATE)가 없는 곳으로 가면 안전장치가 통째로 꺼진다. 원형과 사본(lz·hv·hvz) 모두(bash -c "git sw"'itch x')
  if br_switch "$lq" || { [ -n "$lz" ] && br_switch "$lz"; } || { [ -n "$hv" ] && br_switch "$hv"; } || { [ -n "$hvz" ] && br_switch "$hvz"; }; then
    block "리팩토링 중에는 다른 가지·커밋으로 옮기지 않습니다(리팩토링 기록이 없는 곳으로 가면 안전장치가 통째로 꺼짐)." "가지를 옮겨야 하면 멈추고 사람에게 부탁하세요(사람이 터미널에서 git switch <가지>). PR 을 합친 뒤 최신 기본 가지에서 새 작업 가지가 필요하면 사용자에게 /refactor:approve 새 가지 를 입력해 달라고 하세요. 지금 위치에서 새 가지 만들기(git switch -c <새 가지>)와 파일 되돌리기(git restore <파일> · git checkout -- <파일>)는 됩니다. 강제 만들기(-C·-B)는 다른 가지를 덮어쓸 수 있어 막습니다 — -c·-b 로 만드세요."
  fi
  if has "$lq" "$re_glp" && ! has "$lq" 'git[[:space:]]+log[^;&|]*[[:space:]]--[[:space:]]+[^[:space:]-]'; then
    block "리팩토링 진행 중에는 파일을 지정하지 않은 git log -p 를 쓰지 않습니다(옛 비밀값이 찍힐 수 있음)." "파일을 지정하세요: git log -p -- <파일>, 또는 목록만: git log --oneline"
  fi
  if has "$lq" 'git[[:space:]]+show([[:space:]]|$)' \
    && ! has "$lq" 'git[[:space:]]+show[^;&|]*([[:space:]](--stat|--name-only|--name-status|--oneline|--no-patch|-s|--summary|--shortstat|--numstat)([[:space:]]|$)|--format|--pretty|[^[:space:]]:[^[:space:]]|[[:space:]]--[[:space:]]+[^[:space:]])'; then
    block "커밋 내용 전체를 출력하면 옛 비밀값이 찍힐 수 있습니다." "요약만 보거나(git show --stat <커밋>) 파일을 지정하세요(git show <커밋> -- <파일>)."
  fi
  # 배포·마이그레이션 적용·원격 DB — 원형과 사본(lz·hv·hvz) 모두(bash -c "ver"'cel --prod')
  hv_deploy "$lq" "$lr"
  [ -n "$lz" ] && hv_deploy "$lz"
  [ -n "$hv" ] && hv_deploy "$hv"
  [ -n "$hvz" ] && hv_deploy "$hvz"
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
    if [ "$snap" = 1 ] && ! abl_any_open; then
      abl_hint; block "스냅숏·골든 파일을 새 결과로 덮어쓰는 옵션은 기준선을 바꿀 수 있어 막혀 있습니다.${abl_why:+ $abl_why}" "$AH"
    fi
    if { writes_to "$RE_BL_CMD" || interp_writes "$RE_BL_CMD"; } && ! abl_any_open; then
      abl_hint; block "기준선 테스트 폴더의 파일을 바꾸거나 지우는 명령은 막혀 있습니다.${abl_why:+ $abl_why}" "$AH"
    fi
  fi
  if [ "$allow_migration" = 0 ] && { writes_to "$RE_MIG_CMD" || interp_writes "$RE_MIG_CMD"; }; then
    block "마이그레이션 폴더의 파일을 셸 명령으로 바꾸거나 지우지 않습니다." "새 마이그레이션은 파일 쓰기 도구로 새 파일을 만드세요(커밋 전의 새 파일은 고쳐도 됩니다). $MSG_ALLOW_M"
  fi
  # (기록 폴더 안 파일 지우기(rm … docs/refactor/)는 4) 의 hv_del 이 사본마다 본다)

  # /refactor:go 실행 중에는 프로젝트 코드를 돌리는 명령(테스트·빌드·개발 서버·스크립트)을 안전 실행기로만(따옴표를 모두 뺀 사본도)
  if [ "$go_turn" = 1 ]; then
    go_runner "$lq" 0
    [ -n "$lz" ] && go_runner "$lqv" 1
    [ -n "$hv" ] && go_runner "$hv" 0
  fi

  if [ "$fence" = 1 ]; then
    if has "$lq" "${S}(sed[[:space:]]+(-[a-z]*i|--in-place)|perl[[:space:]]+-[a-z]*i|g?awk[[:space:]]+-i[[:space:]]+inplace|git[[:space:]]+(checkout|restore|apply|am|cherry-pick|revert|merge|rebase|commit|reset|stash)|(npm|pnpm|yarn|bun)[[:space:]]+(install|i|add|remove|uninstall|update|up|upgrade)|pip3?[[:space:]]+install|poetry[[:space:]]+(add|install|update)|uv[[:space:]]+(add|pip|sync))${E}" \
      && ! has "$lq" 'git[[:space:]]+(checkout[[:space:]]+(-b|-B|--orphan)|stash[[:space:]]+(list|show))([[:space:]]|$)'; then
      block "$fence_why 코드·패키지·git 기록을 바꾸는 명령을 쓰지 않습니다." "발견한 문제는 보고서와 계획서 후보로만 적으세요. (리팩토링과 상관없는 평소 작업이면 사용자에게 새 대화에서 하자고 안내하세요.)"
    fi
    if interp_writes_proj; then
      block "$fence_why 코드로 docs/refactor 밖의 파일을 쓰지 않습니다." "발견한 문제는 보고서와 계획서 후보로만 적으세요. 임시 파일은 /tmp 에 쓰세요."
    fi
  fi
  return 0
}

# ── 하위 에이전트(Agent·Task): 지시문에 막힌 명령을 "명령 형태로" 넣어 시키는 우회 ─────────────
# 코드 조각(```…```, `…`, 줄 맨 앞 $ ·!)만 셸 명령 판정에 태운다. 문장 속 언급(.env 는 읽지 마)과
# 금지 목록 줄(…금지·하지 마·never·do not 이 있는 줄)은 통과. 문장 속 "cat .env" 처럼 읽기 동사+비밀값 파일이 붙은 형태는 막는다.
check_agent() {
  local p k frag line rest re_fence='```[a-zA-Z0-9_-]*(([^`]|`[^`]|``[^`])*)```' re_tick='`([^`]+)`' conv batch=""
  local re_ban='금지|하지[[:space:]]*마|하지[[:space:]]*말|말[[:space:]]*것|쓰지[[:space:]]*마|쓰지[[:space:]]*않|부르지[[:space:]]*마|부르지[[:space:]]*않|실행하지|건드리지|never|do not|don'"'"'t|must not|forbidden|prohibited|avoid'
  AGENT_MODE=1
  BLOCK_NOTE="(하위 에이전트에게 시키는 것도 같은 우회입니다. 금지 사항을 적는 거라면 명령 형태 없이 '비밀값 파일은 열지 말 것'처럼 쓰세요.)"
  # 판정할 명령 조각은 모아서(12KB 까지 한 번에) 셸 판정에 넣는다 — 줄마다 따로 부르면 수천 줄에서 훅 제한 시간을 넘긴다.
  # 따옴표 개수가 맞지 않는 조각은 옆 조각과 섞여 판정을 흐리지 않게 따로 본다
  agent_cmd() {
    local f=$1
    if quote_odd "$f"; then check_shell "$f"; return; fi
    if [ $((${#batch} + ${#f})) -gt 12000 ] && [ -n "$batch" ]; then check_shell "$batch"; batch=""; fi
    batch="$batch$P_BSN$f"
  }
  for k in prompt description; do
    jget "$k"; p=$JV
    [ -z "$p" ] && continue
    # 줄 수 상한: 줄마다 명령 판정을 하므로 아주 긴 지시문은 판정하지 않고 막는다(파일로 넘기면 된다)
    nl_split "$p"; conv=$NLV
    [ "${NLC:-0}" -gt 2000 ] && block "도구 입력이 너무 깁니다(2,000줄 초과) — 파일로 저장해 경로를 넘기세요." "지시문을 파일(예: /tmp/지시.md)로 저장하고, 하위 에이전트에게는 그 파일 경로를 읽으라고 짧게 쓰세요."
    # 줄 나누기는 한 번에(here-string) — ${x#*…} 를 줄마다 되풀이하면 줄 수의 제곱만큼 느려진다
    while IFS= read -r line; do
      has "$line" "$re_ban" && continue
      # 문장 속 읽기 동사 + 비밀값 파일(cat .env, head .env.local, Get-Content .env)
      if has "$line" "(^|[^[:alnum:]_-])(cat|head|tail|less|more|bat|type|get-content|gc|source|base64|xxd|strings|printenv)[[:space:]]+[\"'\`]?[^[:space:]\"'\`]*(\\.env([._-][[:alnum:]_.-]*)?|\\.dev\\.vars|\\.pem|\\.key|id_rsa|id_ed25519|credentials\\.json|\\.netrc|\\.npmrc|\\.git-credentials)([^[:alnum:]_.-]|$)"; then
        block "비밀값 파일을 읽으라는 지시를 하위 에이전트에게 보내지 않습니다."
      fi
      # 줄 맨 앞 $ · ! 명령
      case "$line" in '$ '*|'! '*|'!'[a-z]*) agent_cmd "${line#?}" ;; esac
      # 한 줄 코드(`…`)
      rest=$line
      while [[ $rest =~ $re_tick ]]; do
        frag=${BASH_REMATCH[1]}; rest=${rest#*"${BASH_REMATCH[0]}"}
        case "$frag" in *[[:space:]]*|printenv|env|set|export) agent_cmd "$frag" ;; esac
      done
    done <<< "$conv"
    # 여러 줄 코드 블록(```…```): 금지 목록이 아니면 판정.
    # 블록 안에 "$ " 로 시작하는 줄이 하나라도 있으면 그 줄들만 명령이고(위 줄 판정에서 이미 봤다) 나머지 줄은 출력이다 — 건너뛴다
    rest=$p
    while [[ $rest =~ $re_fence ]]; do
      frag=${BASH_REMATCH[1]}; rest=${rest#*"${BASH_REMATCH[0]}"}
      case "$frag" in "$P_BSN"*) frag=${frag#"$P_BSN"} ;; esac
      case "$frag" in '$ '*|*"$P_BSN"'$ '*) continue ;; esac
      has "$frag" "$re_ban" && continue
      check_shell "$frag"
    done
  done
  [ -n "$batch" ] && check_shell "$batch"
  AGENT_MODE=0; BLOCK_NOTE=""
  return 0
}

case "$tool" in
  Agent|Task) check_agent ;;
  Bash|PowerShell|Monitor) check_shell ;;
  Read|Edit|Write|MultiEdit|NotebookEdit) check_file_tool ;;
  Grep) check_grep_tool ;;
  mcp__*) check_mcp ;;
  *) jget command; [ -n "$JV" ] && check_shell ;;   # 셸 명령을 받는 다른 도구(새로 생긴 도구 포함)
esac
exit 0
