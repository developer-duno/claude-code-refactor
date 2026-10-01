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
  { F=${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/refactor}; F=${F//"$BS"/$SL}; [ -d "$F" ] || mkdir -p "$F"; F=$F/problems.log; LC_ALL=C.UTF-8; m=${1%%"$NL"*}; w=${m%% *}; case "$w" in *[./"$BS"~]*) m="<파일>${m#"$w"}" ;; esac; case "$m" in *'('*')'*) m="${m%%(*}(<파일>)${m##*)}" ;; esac; t=""; (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] >= 402 )) && TZ=KST-9 printf -v t '%(%Y-%m-%d %H:%M)T' -1; [ -n "$t" ] || t=$(TZ=KST-9 date '+%Y-%m-%d %H:%M'); printf '%s | guard | 차단: %s\n' "$t" "${m:0:60}" >> "$F"; (( RANDOM % 64 )) || { s=$(wc -c < "$F"); [ "${s//[!0-9]/}" -gt 204800 ] && tail -c 102400 "$F" | tail -n +2 > "$F.tmp" && mv -f "$F.tmp" "$F"; }; } 2>/dev/null   # 문제 기록(problems.log)에 규칙 설명 첫 줄 앞 60자와 시각만 남긴다 — 첫 ( 부터 마지막 ) 까지와 맨 앞의 파일 이름은 <파일>로 바꾸고 명령·값은 적지 않는다(공개 신고에 붙을 수 있음). 실패는 무시, 가끔 200KB 넘으면 최근 절반만. %(…)T 는 bash 4.2+ 에서만(3.2 는 date) — 프로그램을 거의 띄우지 않아 차단이 늦어지지 않는다
  printf '[refactor 안전장치] %s\n' "$1" >&2
  if [ -n "${2:-}" ]; then printf '  → %s\n' "$2" >&2; fi
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
  case "${f##*/}" in *.example|*.sample|*.template|*.dist|.envrc) ;; *) has_env_file=1 ;; esac
done

MSG_APPROVE="사용자에게 /refactor:approve <단계ID> (기준선은 /refactor:approve baseline) 명령을 안내하고 멈추세요. 대화 중 '좋아요'는 승인이 아닙니다."
MSG_ALLOW_B="기준선을 새 동작으로 바꿔야 하는 🛠 단계라면 멈추고 사람에게 요청하세요: 입력창에서 ! touch \"$rdir/.allow-baseline-edit\" (끝나면 지우기)."
MSG_ALLOW_M="구조 변경은 새 마이그레이션 파일로 만드세요. 이미 있는 파일을 꼭 고쳐야 하면 사람에게 요청: ! touch \"$rdir/.allow-migration-edit\" (끝나면 지우기)."
MSG_HUMAN="필요하면 사람에게 입력창에서 직접 실행해 달라고 요청하세요(예: ! touch \"$rdir/.allow-baseline-edit\")."

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
  git -C "$proj" ls-files --error-unmatch -- "$1" >/dev/null 2>&1
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
# 이 폴더(세 단계 아래까지)에 git이 무시하지 않는 비밀값 파일이 있나 → SEC_FOUND(첫 파일 이름)
unignored_secret_under() { # $1 폴더 $2 (있으면) 이 glob에 맞는 파일만
  local root=$1 f d1 d2 list="" ign n=0 g=${2:-}
  SEC_FOUND=""
  [ -d "$root" ] || return 1
  # 세 단계 아래까지(숨김 폴더 포함) 훑되, node_modules 같은 큰 폴더에는 들어가지 않는다
  # 폴더가 너무 많거나(200개) 오래 걸리면(5초) 판정할 수 없으니 통과시키지 않고 막는다
  local dirs=("$root") d3 MSG_WIDE="범위가 넓어 판정할 수 없습니다 — 폴더를 좁혀 주세요." MSG_WIDE2="path로 코드 폴더(예: src)를 지정하거나 glob(예: \"*.ts\")·type(예: \"js\")으로 파일 종류를 좁히세요."
  # 하위 폴더 목록을 먼저 펼쳐 개수를 보고, 넘으면 더 들어가지 않고 바로 막는다(맞지 않은 glob 글자 2개 몫은 여유)
  local l1=("$root"/*/ "$root"/.[!.]*/) l2 l3
  [ "${#l1[@]}" -gt 202 ] && block "$MSG_WIDE" "$MSG_WIDE2"
  for d1 in "${l1[@]}"; do
    heavy_dir "$d1" && continue
    dirs+=("${d1%/}")
    l2=("$d1"*/ "$d1".[!.]*/)
    [ $((${#dirs[@]} + ${#l2[@]})) -gt 202 ] && block "$MSG_WIDE" "$MSG_WIDE2"
    for d2 in "${l2[@]}"; do
      heavy_dir "$d2" && continue
      dirs+=("${d2%/}")
      l3=("$d2"*/)
      [ $((${#dirs[@]} + ${#l3[@]})) -gt 201 ] && block "$MSG_WIDE" "$MSG_WIDE2"
      for d3 in "${l3[@]}"; do heavy_dir "$d3" && continue; dirs+=("${d3%/}"); done
      [ "$SECONDS" -ge 5 ] && block "$MSG_WIDE" "$MSG_WIDE2"
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
# 파이썬·노드 같은 인터프리터 코드가 이 경로에 쓰는가($1 = 경로 정규식). 검사 대상: lr
interp_writes() {
  has "$lr" "${S}(python3?|py|node|ruby|php|perl|deno|bun|pwsh|powershell)[[:space:]]" || return 1
  has "$lr" "$1" || return 1
  has "$lr" "open[(][^)]*['\"][wax+]|write_?text|write_?bytes|writefile|write_file|appendfile|fs[.](write|append|rm|unlink|rename|copy|truncate)|[.]unlink|rmtree|os[.](remove|rename|replace)|shutil[.](move|copy)|set-content|out-file|add-content|[.]replace[(]" || return 1
  return 0
}

# 따옴표 인자 하나를 _Q_로 바꾼다(명령 치환이 든 것은 그대로). $1 정규식(따옴표 인자가 마지막 괄호) $2 그 괄호 번호 $3 원문 → BQ
blank_quoted() {
  local re=$1 gi=$2 rest=$3 out="" m0 mq re_cs='[$][(]|`' re_se='^[(][[:space:]]*(echo|printf|write-output)'
  while [[ $rest =~ $re ]]; do
    m0=${BASH_REMATCH[0]}; mq=${BASH_REMATCH[$gi]}
    out="$out${rest%%"$m0"*}"
    rest=${rest#*"$m0"}
    # $(echo "…") 의 문구는 명령의 인자가 되므로 지우지 않는다(cat $(echo ".env"))
    if [[ $mq =~ $re_cs ]] || { [ "${out: -1}" = '$' ] && [[ $m0 =~ $re_se ]]; }; then out="$out$m0"; else out="$out${m0%"$mq"}_Q_"; fi
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
blank_echo_words() {
  local rest=$1 out="" m0 lead args kept r
  local re='(^|[;&|(])([[:space:]]*(echo|printf|write-host|write-output))([^;&|]*)'
  local re_r='[0-9]*>>?[[:space:]]*[^[:space:];&|<>]+' re_cs='[$][(]|`'
  while [[ $rest =~ $re ]]; do
    m0=${BASH_REMATCH[0]}; lead="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"; args=${BASH_REMATCH[4]}
    out="$out${rest%%"$m0"*}"; rest=${rest#*"$m0"}
    if [[ $args =~ $re_cs ]] || { [ "${out: -1}" = '$' ] && [ "${m0:0:1}" = '(' ]; }; then out="$out$m0"; continue; fi   # $(echo .env) 는 인자가 된다
    kept=""
    while [[ $args =~ $re_r ]]; do r=${BASH_REMATCH[0]}; kept="$kept $r"; args=${args#*"$r"}; done
    out="$out$lead _Q_$kept "
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
glob_protected_exec() {
  case "$1" in *[\*\?\[]*) ;; *) return 1 ;; esac
  local s seg a b i nm names="refactor-approve.sh refactor-approve turn.sh guard.sh post-check.sh session-start.sh turn guard post-check session-start run.sh"
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
interp_approve() {
  has "$1" "refactor-approve|[/\\\\](turn|guard|post-check|session-start)[.]sh|run[.]sh[^;&|]{0,24}(turn|guard|post-check|session-start)" || return 1
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
  if has "$1" "run\\.sh[\"']?[[:space:]]+[\"']?(turn|guard|post-check|session-start)([\"'[:space:];&|)]|$)" \
    || has "$1" "${S}(sudo[[:space:]]+)?(bash|sh|zsh|dash|source|exec)[[:space:]]+(-[^[:space:]]+[[:space:]]+)*[\"']?[^[:space:]\"';&|]*[/\\\\]hooks[/\\\\](turn|guard|post-check|session-start)\\.sh([\"'[:space:];&|)]|$)" \
    || has "$1" "(^|[;&|({\`])[[:space:]]*(sudo[[:space:]]+)?\\.[[:space:]]+[\"']?[^[:space:]\"';&|]*[/\\\\]hooks[/\\\\](turn|guard|post-check|session-start)\\.sh([\"'[:space:];&|)]|$)" \
    || has "$1" "(^|[;&|(])[[:space:]]*[\"']?[^[:space:]\"';&|]*[/\\\\]hooks[/\\\\](turn|guard|post-check|session-start)\\.sh([\"'[:space:];&|)]|$)" \
    || has "$1" '--from-hook'; then
    block "$MSG_HOOK_EXEC" "$MSG_APPROVE"
  fi
  return 0
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
  shopt -u nocasematch
  if has "$t" "git[[:space:]]+branch[^;&|]*[[:space:]](-[a-zA-Z]*D[a-zA-Z]*|--delete[[:space:]]+--force|--force[[:space:]]+--delete)([[:space:]\"')]|$)"; then
    shopt -s nocasematch
    block "git branch -D 는 합치지 않은 브랜치를 영구 삭제합니다." "사람이 직접 결정합니다. 스쿼시 머지된 가지는 \`git branch -d\` 로 안 지워집니다(git 이 미합침으로 봄) — 그때는 사용자에게 \`git branch -D <가지>\` 명령을 드려 직접 실행하게 하세요."
  fi
  shopt -s nocasematch
  has "$t" 'git[[:space:]]+(filter-branch|filter-repo|update-ref[[:space:]]+-d)|git[[:space:]]+reflog[[:space:]]+(expire|delete)|git[[:space:]]+gc[^;&|]*--prune=now' && block "git 기록을 다시 쓰거나 지우는 명령입니다." "사람이 직접 결정합니다."
  # 원격 가지·저장소 삭제: gh api 의 DELETE 요청이 …/git/refs/(가지·태그) 나 repos/<주인>/<저장소>(저장소 통째)를 겨냥 · gh repo delete
  local gseg grest=$t re_gha="gh[[:space:]]+api([[:space:]][^;&|]*)?"
  while [[ $grest =~ $re_gha ]]; do
    gseg=${BASH_REMATCH[0]}; grest=${grest#*"$gseg"}
    if has "$gseg" "[[:space:]](-X[[:space:]]*|--method([[:space:]]+|=))[\"']?delete([\"'[:space:])]|$)" \
      && has "$gseg" "/git/refs/|[[:space:]][\"']?/?repos/[^/[:space:]\"']+/[^/[:space:]\"']+/?([\"'[:space:])]|$)"; then
      block "$MSG_GHDEL" "사용자에게 명령을 안내하고 사람이 직접 실행하게 하세요."
    fi
  done
  has "$t" "gh[[:space:]]+repo[[:space:]]+delete([[:space:]\"')]|$)" && block "$MSG_GHDEL" "사용자에게 명령을 안내하고 사람이 직접 실행하게 하세요."
  return 0
}
MSG_GHDEL="원격 가지·저장소 삭제는 사람이 직접 합니다(gh api DELETE 도 같습니다)."
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
# 고가치 규칙(리팩토링 진행 중: 배포·마이그레이션 적용·원격 DB 접속) — lq·lz·hv·hvz 사본마다(bash -c "ver"'cel --prod').
#   $2 = 원격 DB 주소 판정용 문자열(원형은 lr, 사본은 그 사본)
hv_deploy() {
  local t=$1 r=${2:-$1} remote_db=0
  local re_deploy="${S}(vercel([[:space:]][^;&|]*)?(--prod|[[:space:]](deploy|promote|rollback|alias|redeploy))|vercel[[:space:]]*($|[;&|])|netlify[[:space:]]+deploy|firebase[[:space:]]+deploy|wrangler[[:space:]]+(deploy|publish|pages[[:space:]]+deploy|secret)|(fly|flyctl)[[:space:]]+deploy|railway[[:space:]]+(up|deploy)|gcloud[[:space:]][^;&|]*deploy|eb[[:space:]]+deploy|(serverless|sls)[[:space:]]+deploy|amplify[[:space:]]+publish|docker[[:space:]]+push|kubectl[[:space:]]+(apply|delete|rollout)|terraform[[:space:]]+apply|pm2[[:space:]]+(deploy|restart|reload)|gh[[:space:]]+(pr[[:space:]]+merge|release[[:space:]]+create|workflow[[:space:]]+run)|ssh[[:space:]]|scp[[:space:]])"
  local re_pkg_deploy="${S}(npm|pnpm|yarn|bun)[[:space:]]+((run|run-script)[[:space:]]+)?([a-z0-9_-]+:)?(deploy|release|publish|ship)([[:space:]:]|$)"
  if has "$t" "$re_deploy" || has "$t" "$re_pkg_deploy"; then
    block "리팩토링 진행 중에는 배포·원격 서버 명령을 사람이 직접 합니다." "필요한 명령을 사람에게 안내하세요."
  fi
  local re_pkg_db="${S}(npm|pnpm|yarn|bun)[[:space:]]+((run|run-script)[[:space:]]+)?[a-z0-9_:-]*(migrat[a-z]*|(db|prisma|supabase|drizzle)[:_-](push|migrate|reset|seed|deploy|drop|up|apply))"
  if has "$t" 'supabase[[:space:]]+(db[[:space:]]+push|functions[[:space:]]+deploy|secrets[[:space:]]+set)|supabase[[:space:]]+migration[[:space:]]+(up|repair)[^;&|]*(--linked|--db-url)|prisma[[:space:]]+(migrate[[:space:]]+(deploy|resolve)|db[[:space:]]+(push|execute))|drizzle-kit[[:space:]]+(push|migrate)|sequelize[^;&|]*db:migrate|knex[^;&|]*migrate:(latest|up|down|rollback)|alembic[[:space:]]+(upgrade|downgrade)|manage\.py[[:space:]]+migrate|rails[[:space:]]+db:migrate|rake[[:space:]]+db:migrate|artisan[[:space:]]+migrate' \
    || has "$t" "$re_pkg_db" \
    || has "$t" "${S}docker(-compose|[[:space:]]+compose)[^;&|]*[[:space:]]down[^;&|]*[[:space:]](-v|--volumes)([[:space:]]|$)" \
    || has "$t" '(^|[[:space:]:])db:(reset|drop|wipe|purge)([[:space:]]|$)' \
    || { has "$t" 'prisma[[:space:]]+migrate[[:space:]]+dev' && ! has "$t" '--create-only'; }; then
    block "리팩토링 진행 중에는 DB 구조 변경(마이그레이션 적용)을 사람이 직접 합니다." "로컬 테스트 DB라면 사람이 입력창에서 ! <명령> 으로 실행합니다."
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
  if [ "${2:-0}" = 1 ]; then rq=${rq//\'/}; rq=${rq//\"/}; fi
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
nested_claude_approve() {
  has "$1" 'claude' && has "$1" 'refactor:(approve|go)|from-hook' || return 1
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
# 승인 스크립트를 "실행"하는 모양인가(읽기·검색은 아니다): bash·sh·source·. 로 부르기, 직접 실행, run.sh refactor-approve,
# 셸로 흘려 넣기(cat … | bash · bash < … · <( ) · eval · xargs bash · -exec bash). $1 = 판정용 명령(따옴표 정리됨)
approve_exec() {
  local s seg
  has "$1" "[|][[:space:]]*(sudo[[:space:]]+)?(ba|z|da|k)?sh([[:space:]]|$)|(^|[;&|({[:space:]])(bash|sh|zsh|dash|source|\\.)[[:space:]]*<|<[(]|(^|[;&|({[:space:]])eval([[:space:]]|$)|(xargs|-exec|-execdir)[[:space:]]+([^;&|]*[[:space:]])?(sudo[[:space:]]+)?(bash|sh|zsh|dash|source)([[:space:]]|$)" && return 0
  cut_segs "$1"; s=$CUTS
  while [ -n "$s" ]; do
    seg=${s%%"$NL"*}; if [ "$seg" = "$s" ]; then s=""; else s=${s#*"$NL"}; fi
    case "$seg" in *refactor-approve*) ;; *) continue ;; esac
    seg_words "$seg"
    case "$SCMD" in *refactor-approve*|run.sh|bash|sh|zsh|dash|ksh|source|.) return 0 ;; esac
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
  local pass rest m name val k re_ref q="'" re
  local re_sh="(^|[;&|({[:space:]])([A-Za-z_][A-Za-z0-9_]*)=(\"([^\"]*)\"|${q}([^${q}]*)${q}|([^[:space:];&|()\"${q}<>]*))"
  local re_ps="(^|[;&|({[:space:]])[$]([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(\"([^\"]*)\"|${q}([^${q}]*)${q}|([^[:space:];&|()\"${q}<>=]+))"
  for pass in 1 2; do
    for re in "$re_sh" "$re_ps"; do
      [ "$re" = "$re_ps" ] && [ "$tool" != "PowerShell" ] && continue
      rest=$EV
      while [[ $rest =~ $re ]]; do
        m=${BASH_REMATCH[0]}; name=${BASH_REMATCH[2]}
        case "${BASH_REMATCH[3]}" in \"*) val=${BASH_REMATCH[4]} ;; "$q"*) val=${BASH_REMATCH[5]} ;; *) val=${BASH_REMATCH[6]} ;; esac
        rest=${rest#*"$m"}
        [ -z "$val" ] && continue
        EV=${EV//"\${$name}"/$val}   # ${x}set 처럼 중괄호 표기는 바로 뒤에 글자가 붙어도 그 변수다
        re_ref="[$]([{]${name}[}]|${name})([^A-Za-z0-9_]|$)"
        k=0
        while [[ $EV =~ $re_ref ]] && [ "$k" -lt 20 ]; do
          EV=${EV/"${BASH_REMATCH[0]}"/"$val${BASH_REMATCH[2]}"}; k=$((k + 1))
        done
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

# 명령 조각 하나를 단어로 나누고(따옴표·괄호는 지움) 앞에 붙은 래퍼(sudo·env·nohup·xargs·if/then·eval·corepack·cmd /c·powershell -c·bash -c …)를 건너뛴다
# → SW(단어 배열), SI(명령 이름 위치), SCMD(명령 이름: 경로·.exe 뗌), INCMD(cmd /c 안), XARGS(xargs 로 받음)
seg_words() {
  local s=$1 n re_cmdopt='^/{1,2}[a-z](:[a-z]+)?$' re_shc='^-[a-z]*c[a-z]*$'
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
interp_writes_proj() {
  has "$lr" "${S}(python3?|py|node|ruby|php|perl|deno|bun|pwsh|powershell)[[:space:]]" || return 1
  has "$lr" "open[(][^)]*['\"][wax+]|write_?text|write_?bytes|writefile|write_file|appendfile|fs[.](write|append|rm|unlink|rename|copy|truncate|mkdir)|[.]unlink|rmtree|os[.](remove|rename|replace|makedirs|mkdir)|shutil[.](move|copy)|set-content|out-file|add-content" || return 1
  local rest=$lr re_lit="[\"']([^\"'[:space:]]*[/.][^\"'[:space:]]*)[\"']" lit any=0
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
  blank_quoted "(^|[;&|(])[[:space:]]*(grep|egrep|fgrep|rg|ag|ack|git[[:space:]]+grep|git[[:space:]]+log|git[[:space:]]+commit|echo|printf|write-host|write-output)([^;&|\"']*)(\"([^\"\\\\]|\\\\.)*\"|'[^']*')" 4 "$1"
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

check_shell() { # $1(있으면) = 판정할 명령(JSON 이스케이프 그대로). 없으면 도구 입력의 command 칸
  local rawcmd
  if [ "$#" -gt 0 ]; then rawcmd=$1; else jget command; rawcmd=$JV; fi
  [ "${#rawcmd}" -gt 16384 ] && block "명령이 너무 깁니다(16KB 초과) — 파일로 저장해 실행하세요." "Write 도구로 스크립트 파일을 만들고, 무엇을 하는지 사용자에게 보여 준 뒤 bash <파일> 로 실행하세요."
  unesc_line "$rawcmd"; local cmd=$UV cmds=$UVS
  [ -z "$cmd" ] && return 0
  local m0 m4 pre rest seg SQLRAW=""
  # 명령이 실행되는 폴더(Bash 도구의 현재 폴더) — 와일드카드 파일 이름을 실제로 펼쳐 볼 때 쓴다
  jget cwd; unesc_line "$JV"; cwd=${UV//"$BS"/$SL}; cwd=${cwd%/}; [ -z "$cwd" ] && cwd=$proj
  normpath "$cwd" /; cwd=$NP

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
  # 승인·훅 진입점·중첩 claude(새 Claude 세션은 그 입력을 사람 입력으로 본다) — 원형과 따옴표를 모두 뺀 사본(lz) 둘 다.
  # 승인 스크립트는 실행하는 모양만 막는다(cat·grep·head 로 읽는 것은 통과)
  hv_human "$lq" "$lr"
  [ -n "$lz" ] && hv_human "$lz" "$lz"
  [ -n "$hv" ] && hv_human "$hv" "$hv"
  [ -n "$hvz" ] && hv_human "$hvz" "$hvz"
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
  # 쓰기 대상(목적지) 기준: 사람 전용 파일, 기록 폴더 이동·개명, 플러그인 폴더, 읽기 전용 단계의 프로젝트 파일
  norm_dirvars "$lq"; local tq=$NV pb=${plugroot##*/} tchk=0
  has "$tq" 'approvals|allow-|[.]turn|approved|refactor|state[.]md|docs|[.][.]|plugins|>' && tchk=1
  if [ -n "$plugroot" ]; then case "$cwd/" in "$plugroot"/*) tchk=1 ;; esac; [ -n "$pb" ] && case "$tq" in *"$pb"*) tchk=1 ;; esac; fi
  [ "$fence" = 1 ] && tchk=1
  [ "$tchk" = 1 ] && shell_targets "$tq"

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
