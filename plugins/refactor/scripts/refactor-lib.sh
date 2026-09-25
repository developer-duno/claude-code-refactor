# shellcheck shell=bash
# ─────────────────────────────────────────────────────────────────────────────
# Vibe Refactor — 공용 읽기 도구 (승인 스크립트·현황 스크립트·안전장치가 불러 쓴다. 혼자 실행하지 않는다)
#
# 승인의 근거는 docs/refactor/APPROVALS.log 하나뿐이다. 계획서의 체크 표시는 보기 좋게 옮겨 적은 것일 뿐이다.
#   - 승인 기록 한 줄:  2026-09-26 10:00 KST | 승인 | P1-2 | card=<지문> | 사용자가 /refactor:approve 로 실행
#   - 지문 = 단계 카드 내용의 cksum(CRC + 길이). 승인·완료 칸의 체크 표시와 날짜만 빼고, 그 줄에 덧붙인 글은 포함한다.
#     공백 개수·줄 끝 공백·빈 줄 개수 차이는 무시한다. 승인 뒤 카드 내용이 바뀌면 "승인 뒤 카드 바뀜 → 다시 승인 필요"가 된다.
#   - 기준선 계획의 지문 = BASELINE.md 전체에서 '기준선 계획 승인:' 줄과 '## 결과'(또는 '## 기준선 결과') 제목부터 끝까지를 뺀 내용.
#     '기준선 계획 승인:' 줄이 둘 이상이면 어느 것인지 모호하므로 승인하지 않는다.
#   - 같은 단계의 기록이 여러 줄이면 마지막 줄이 이긴다(승인 → 보류 → 승인 …).
#
# 계획서 읽기 규칙(모두 같은 규칙을 쓴다):
#   - 코드 블록(``` 또는 ~~~ 로 열고 같은 기호로 닫음) 안은 카드·승인 줄로 보지 않는다. 닫히지 않은 코드 블록은 무시하고 경고한다.
#   - 카드 = "### [ID] 제목" 줄부터 다음 #·##·### 제목 줄 전까지(#### 이하 작은 제목은 카드 안에 포함).
#   - 승인 줄 = 줄 맨 앞(들여쓰기·목록 기호 허용)이 **승인**: (또는 **승인:**) 인 줄만. 문장 중간이나 쌍점 없는 **승인** 은 승인 줄이 아니다.
# ─────────────────────────────────────────────────────────────────────────────

RL_US=$'\037'

rl_now() { TZ=KST-9 date '+%Y-%m-%d %H:%M'; }
rl_today() { TZ=KST-9 date '+%Y-%m-%d'; }

RL_AWK='
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
function readall(path,   line, n) { n = 0; while ((getline line < path) > 0) L[++n] = line; close(path); return n }
function isfence(s) { return (s ~ /^(   |  | )?(```|~~~)/) }
function fch(s) { sub(/^ +/, "", s); return substr(s, 1, 1) }
function flen(s) { sub(/^ +/, "", s); if (match(s, /^`+/) || match(s, /^~+/)) return RLENGTH; return 0 }
function fclose_ok(s, ch, ln) {
  sub(/^ +/, "", s); sub(/[ \t\r]+$/, "", s)
  if (ch == "`") { if (s !~ /^`+$/) return 0 } else { if (s !~ /^~+$/) return 0 }
  return length(s) >= ln
}
# 코드 블록 짝 맞추기 → INF[줄]=1 이면 코드 블록 안. 닫는 짝이 없는 여는 줄은 무시하고 UNCLOSED 를 센다
function fences(n,   i, k, j, nf, F, found, m) {
  nf = 0; UNCLOSED = 0
  for (i = 1; i <= n; i++) { INF[i] = 0; if (isfence(L[i])) F[++nf] = i }
  k = 1
  while (k <= nf) {
    found = 0
    for (j = k + 1; j <= nf; j++) if (fclose_ok(L[F[j]], fch(L[F[k]]), flen(L[F[k]]))) { found = j; break }
    if (found) { for (m = F[k]; m <= F[found]; m++) INF[m] = 1; k = found + 1 }
    else { UNCLOSED++; k++ }
  }
}
function is_card(s) { return (s ~ /^###[ \t]*\[[A-Za-z0-9_-]+\]/) }
function is_head(s) { return (s ~ /^(#|##|###)([ \t]|$)/) }
# 승인·완료 줄에서 체크 칸·날짜를 뺀 나머지(덧붙인 글) — 지문에 넣는다
function rest_of(s, label) { sub("^[ \t>]*([-+*][ \t]+|[0-9]+[.)][ \t]+)?\\*\\*" label ":?\\*\\*[ \t]*:?[ \t]*", "", s); sub(/^\[[ xX]\]/, "", s); sub("^[ \t]*" label, "", s); sub(/^[ \t]*\([0-9-]+\)/, "", s); return trim(s) }
function is_results(s) { return (s ~ /^##[ \t]*(기준선[ \t]*)?결과/) }
function card_id(s) { match(s, /\[[A-Za-z0-9_-]+\]/); return toupper(substr(s, RSTART + 1, RLENGTH - 2)) }
function is_appr(s) { return (s ~ /^[ \t>]*([-+*][ \t]+|[0-9]+[.)][ \t]+)?\*\*승인(:\*\*|\*\*[ \t]*:)/) }
function is_done(s) { return (s ~ /^[ \t>]*([-+*][ \t]+|[0-9]+[.)][ \t]+)?\*\*완료(:\*\*|\*\*[ \t]*:)/) }
function is_base(s) { return (s ~ /^[ \t>]*([-+*][ \t]+|[0-9]+[.)][ \t]+)?(\*\*)?기준선[ \t]*계획[ \t]*승인(\*\*)?[ \t]*:/) }
function box3(s) { if (s ~ /^\[[xX]\]/) return "x"; if (s ~ /^\[ \]/) return "o"; return "?" }
function boxof(s, label) { sub("^[ \t>]*([-+*][ \t]+|[0-9]+[.)][ \t]+)?\\*\\*" label ":?\\*\\*[ \t]*:?[ \t]*", "", s); return box3(s) }
function basebox(s) { sub("^[ \t>]*([-+*][ \t]+|[0-9]+[.)][ \t]+)?(\\*\\*)?기준선[ \t]*계획[ \t]*승인(\\*\\*)?[ \t]*:(\\*\\*)?[ \t]*", "", s); return box3(s) }
function lead(s) { if (match(s, /^[ \t>]*([-+*][ \t]+|[0-9]+[.)][ \t]+)?/)) return substr(s, 1, RLENGTH); return "" }
# 지문용 본문: 줄 끝 공백·\r 제거, 앞뒤 빈 줄 제거, 빈 줄 여러 개는 하나로
function addtxt(c, s) {
  sub(/[ \t\r]+$/, "", s); gsub(/[ \t]+/, " ", s)
  if (s == "") { if (TXT[c] != "") PEND[c] = 1; return }
  if (PEND[c]) { TXT[c] = TXT[c] "\n"; PEND[c] = 0 }
  TXT[c] = TXT[c] s "\n"
}
function field(s, name,   t) {
  t = s
  if (t !~ ("^[ \t>]*([-+*][ \t]+)?\\*\\*[^*]*" name "[^*]*\\*\\*")) return ""
  sub("^[ \t>]*([-+*][ \t]+)?\\*\\*[^*]*" name "[^*]*\\*\\*[ \t]*:?[ \t]*", "", t)
  return trim(t)
}
function readlog(   line, f, k, act, id, hv) {
  if (LOG == "") return
  while ((getline line < LOG) > 0) {
    k = split(line, f, "|")
    if (k < 4) continue
    act = trim(f[2]); id = toupper(trim(f[3])); hv = trim(f[4])
    if (hv !~ /^(card|plan)=[0-9]+\.[0-9]+$/) continue
    if (act == "승인") { LAST[id] = "a"; LH[id] = hv }
    else if (act == "보류" || act == "승인 취소") { LAST[id] = "h"; LH[id] = hv }
  }
  close(LOG)
}
function logstate(id, hv) {
  if (!(id in LAST)) return "pending"
  if (LAST[id] == "h") return "held"
  return (LH[id] == hv) ? "approved" : "changed"
}
BEGIN {
  US = "\037"
  if (MODE == "cards") {
    n = readall(PLAN); fences(n); nc = 0; cur = 0
    for (i = 1; i <= n; i++) {
      s = L[i]
      if (!INF[i] && is_head(s)) {
        if (is_card(s)) {
          cur = ++nc; ID[cur] = card_id(s); CNT[ID[cur]]++
          t = s; sub(/^###[ \t]*\[[A-Za-z0-9_-]+\][ \t]*/, "", t); TITLE[cur] = trim(t)
          BOX[cur] = "none"; DONE[cur] = 0; NB[cur] = 0
          addtxt(cur, s)
        } else cur = 0
        continue
      }
      if (!cur) continue
      if (!INF[i] && is_appr(s)) {
        b = boxof(s, "승인"); NB[cur]++; BOX[cur] = (NB[cur] > 1 && BOX[cur] != b) ? "?" : b
        if ((r = rest_of(s, "승인")) != "") addtxt(cur, "(승인 줄 덧붙임) " r)
        continue
      }
      if (!INF[i] && is_done(s)) {
        if (boxof(s, "완료") == "x") DONE[cur] = 1
        else if ((r = rest_of(s, "완료")) != "") addtxt(cur, "(완료 줄 덧붙임) " r)
        continue
      }
      if (!INF[i]) {
        if ((v = field(s, "종류")) != "") KIND[cur] = v
        if ((v = field(s, "위험도")) != "") RISK[cur] = v
        if ((v = field(s, "사람이 직접 할 일")) != "") HUMAN[cur] = v
      }
      addtxt(cur, s)
    }
    for (c = 1; c <= nc; c++) {
      f = DIR "/c" c; printf "%s", TXT[c] > f; close(f)
      print "CARD" US c US ID[c] US TITLE[c] US BOX[c] US DONE[c] US CNT[ID[c]] US KIND[c] US RISK[c] US HUMAN[c]
    }
    if (UNCLOSED) print "WARN" US "fence" US UNCLOSED
    exit
  }
  if (MODE == "rewrite") {   # IDS=" P1-1 P1-2 " 인 카드의 승인 줄만 표준 모양으로 다시 쓴다(ACT=x 승인 / o 보류)
    n = readall(PLAN); fences(n); cur = ""
    for (i = 1; i <= n; i++) {
      s = L[i]
      if (!INF[i] && is_head(s)) cur = is_card(s) ? card_id(s) : ""
      else if (!INF[i] && cur != "" && index(IDS, " " cur " ") && is_appr(s)) {
        cr = (s ~ /\r$/) ? "\r" : ""
        s = lead(s) "**승인**: " (ACT == "x" ? "[x] 승인 (" TODAY ")" : "[ ] 승인") cr
      }
      print s
    }
    exit
  }
  if (MODE == "base" || MODE == "baserewrite") {   # 기준선 계획: "기준선 계획 승인:" 줄(코드 블록 밖, 줄 맨 앞)
    n = readall(PLAN); fences(n); FOUND = 0; NF = 0; RES = n + 1
    for (i = 1; i <= n; i++) {
      if (INF[i]) continue
      if (is_base(L[i])) { NF++; if (!FOUND) FOUND = i }
      else if (FOUND && is_results(L[i]) && RES > n) RES = i   # 결과 제목은 승인 줄 뒤에 있어야 인정
    }
    if (MODE == "baserewrite") {
      for (i = 1; i <= n; i++) {
        s = L[i]
        if (i == FOUND) { cr = (s ~ /\r$/) ? "\r" : ""; s = lead(s) "기준선 계획 승인: " (ACT == "x" ? "[x] (" TODAY ")" : "[ ]") cr }
        print s
      }
      exit
    }
    if (INFO) { print (!FOUND ? "nofield" US "none" : (NF > 1 ? "multi" : "field") US basebox(L[FOUND])); exit }
    if (!FOUND) exit
    for (i = 1; i < RES; i++) if (INF[i] || !is_base(L[i])) addtxt(1, L[i])
    printf "%s", TXT[1]
    exit
  }
  if (MODE == "baselog") { readlog(); print logstate("BASELINE", HV); exit }
  if (MODE == "join") {
    FS = US
    while ((getline line < SUMS) > 0) { split(line, a, " "); nm = a[3]; sub(/^.*\//, "", nm); H[nm] = a[1] "." a[2] }
    close(SUMS)
    readlog()
  }
}
MODE == "join" && $1 == "CARD" { h = "card=" H["c" $2]; print $0 US h US logstate($3, h); next }
MODE == "join" { print }
'

# 계획서 카드 목록(표준출력, 칸 구분 = \037):
#   CARD 순번 ID 제목 체크(x/o/?/none) 완료(0/1) 같은ID개수 종류 위험도 사람할일 지문(card=…) 기록상태(approved/changed/held/pending)
#   WARN fence <닫히지 않은 코드 블록 수>
rl_cards() {
  local plan=$1 log=${2:-} tmp
  [ -f "$plan" ] || return 0
  tmp=$(mktemp -d 2>/dev/null) || tmp=$(mktemp -d -t rlcards 2>/dev/null) || return 1
  if awk -v MODE=cards -v PLAN="$plan" -v DIR="$tmp" "$RL_AWK" > "$tmp/rec"; then
    (set +f; cd "$tmp" && set -- c[0-9]* && [ -f "$1" ] && cksum "$@") > "$tmp/sums" 2>/dev/null
    awk -v MODE=join -v LOG="$log" -v SUMS="$tmp/sums" "$RL_AWK" < "$tmp/rec"
  fi
  rm -rf "$tmp"
}

# 카드 한 장의 지문용 본문(표준출력) — 승인할 때 approved/<ID>.md 로 남기고, 바뀐 내용을 보여 줄 때 쓴다
rl_card_text() { # $1 계획서 $2 ID
  local tmp n
  tmp=$(mktemp -d 2>/dev/null) || tmp=$(mktemp -d -t rlcard 2>/dev/null) || return 1
  n=$(awk -v MODE=cards -v PLAN="$1" -v DIR="$tmp" "$RL_AWK" | awk -F "$RL_US" -v ID="$2" '$1 == "CARD" && $3 == ID { print $2; exit }')
  [ -n "$n" ] && [ -f "$tmp/c$n" ] && cat "$tmp/c$n"
  rm -rf "$tmp"
}

rl_base_text() { awk -v MODE=base -v PLAN="$1" "$RL_AWK"; }   # 기준선 계획의 지문용 본문

# 바뀐 내용 보여 주기: $1 승인 때 남긴 본문 파일, 표준입력 = 지금 본문 → 바뀐 줄(최대 12줄, 앞에 -/+)
rl_show_diff() {
  local tmp
  [ -f "$1" ] || { echo "     (승인 때의 내용이 남아 있지 않아 비교할 수 없음 — 카드를 직접 읽어 보세요)"; cat > /dev/null; return 0; }
  tmp=$(mktemp 2>/dev/null) || tmp=$(mktemp -t rldiff 2>/dev/null) || { cat > /dev/null; return 0; }
  cat > "$tmp"
  diff "$1" "$tmp" 2>/dev/null | grep -E '^[<>]' | sed -e 's/^</     - 승인 때:/' -e 's/^>/     + 지금:/' | head -n 12
  rm -f "$tmp"
}

# 기준선 계획 상태 → RL_STATE(nofile/nofield/multi/pending/approved/changed/held), RL_HASH(plan=…), RL_BOX(x/o/?/none)
rl_base_state() {
  local info
  RL_STATE=nofile; RL_HASH=""; RL_BOX=""
  [ -f "$1" ] || return 0
  info=$(awk -v MODE=base -v INFO=1 -v PLAN="$1" "$RL_AWK")
  RL_BOX=${info#*"$RL_US"}
  case "$info" in nofield*) RL_STATE=nofield; return 0 ;; multi*) RL_STATE=multi; return 0 ;; esac
  RL_HASH=$(awk -v MODE=base -v PLAN="$1" "$RL_AWK" | cksum | awk '{ print $1 "." $2 }')
  RL_HASH="plan=$RL_HASH"
  RL_STATE=$(awk -v MODE=baselog -v LOG="${2:-}" -v HV="$RL_HASH" "$RL_AWK")
}

# 계획서 승인 줄 다시 쓰기: $1 계획서 $2 "x"(승인)/"o"(보류) $3 대상 ID들(공백 구분)
rl_rewrite_plan() {
  local tmp="$1.tmp.$$"
  awk -v MODE=rewrite -v PLAN="$1" -v ACT="$2" -v IDS=" $3 " -v TODAY="$(rl_today)" "$RL_AWK" > "$tmp" && [ -s "$tmp" ] && mv "$tmp" "$1"
  rm -f "$tmp"
}
rl_rewrite_base() {
  local tmp="$1.tmp.$$"
  awk -v MODE=baserewrite -v PLAN="$1" -v ACT="$2" -v TODAY="$(rl_today)" "$RL_AWK" > "$tmp" && [ -s "$tmp" ] && mv "$tmp" "$1"
  rm -f "$tmp"
}

# 승인 기록의 지문(없으면 none) — 턴 중에 바뀌었는지 확인할 때 쓴다
rl_log_sum() { if [ -f "$1" ]; then cksum < "$1" | awk '{ print $1 "." $2 }'; else echo none; fi; }
# 승인 기록이 /refactor:approve 가 마지막으로 남긴 모양 그대로인가(approved/.log-sum 과 비교). 기록이 없으면 그대로로 본다
rl_log_intact() { # $1 docs/refactor 폴더
  [ -f "$1/APPROVALS.log" ] || return 0
  [ -f "$1/approved/.log-sum" ] || return 1
  [ "$(rl_log_sum "$1/APPROVALS.log")" = "$(tr -d '\r\n' < "$1/approved/.log-sum")" ]
}
rl_log_seal() { mkdir -p "$1/approved" && rl_log_sum "$1/APPROVALS.log" > "$1/approved/.log-sum" && { cp "$1/APPROVALS.log" "$1/approved/.log-copy" 2>/dev/null || :; }; }
# 봉인 뒤에 달라진 줄(최대 10줄): "+ 더해진 줄" / "- 없어진 줄". 봉인이 아예 없으면 NOSEAL 한 줄
rl_log_changes() { # $1 docs/refactor 폴더
  [ -f "$1/approved/.log-sum" ] || { echo NOSEAL; return 0; }
  [ -f "$1/approved/.log-copy" ] || { echo "   (봉인 때의 기록 사본이 없어 달라진 줄을 보여 줄 수 없음 — git diff 로 확인)"; return 0; }
  diff "$1/approved/.log-copy" "$1/APPROVALS.log" 2>/dev/null | grep -E '^[<>]' | sed -e 's/^>/   + 더해진 줄:/' -e 's/^</   - 없어진 줄:/' | head -n 10
}
# 마무리(DONE)를 사람이 /refactor:approve 마무리 로 확인했나 — 승인 기록의 마지막 줄이 "마무리" 이고 기록이 그대로일 때만
rl_done_confirmed() { # $1 docs/refactor 폴더
  local last="" line
  [ -f "$1/APPROVALS.log" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do [ -n "${line//[[:space:]]/}" ] && last=$line; done < "$1/APPROVALS.log"
  case "$last" in *"| 마무리 |"*) rl_log_intact "$1" ;; *) return 1 ;; esac
}

# 보호된 파일(커밋된 기준선·마이그레이션) 중 커밋 안 된 변경 목록: "<git status 줄>\t<내용 지문>" 줄들
rl_protected_dirty() {
  local proj=$1 rdir=$2 raw line path keep h specs=()
  command -v git >/dev/null 2>&1 || return 0
  [ -f "$rdir/.allow-baseline-edit" ] || specs+=('*baseline/*')
  [ -f "$rdir/.allow-migration-edit" ] || specs+=('*supabase/migrations/*' '*prisma/migrations/*' '*alembic/versions/*' '*db/migrate/*' '*database/migrations/*' 'migrations/*' '*/migrations/*' 'drizzle/*.sql' 'drizzle/meta/*')
  [ "${#specs[@]}" -eq 0 ] && return 0
  raw=$(git -C "$proj" status --porcelain --untracked-files=no -- "${specs[@]}" 2>/dev/null)
  [ -z "$raw" ] && return 0
  local re_bl='(^|/)(tests?|__tests__|specs?)/([^/]+/)*baseline/'
  local re_mig='(^|/)(supabase/migrations|prisma/migrations|alembic/versions|db/migrate|database/migrations|migrations)/[^/]+|^drizzle/([^/]+[.]sql|meta/)'
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    path=${line:3}; path=${path##* -> }; path=${path//\"/}
    case "$path" in docs/refactor/*) continue ;; esac
    keep=0
    if [ ! -f "$rdir/.allow-baseline-edit" ] && [[ $path =~ $re_bl ]]; then keep=1; fi
    if [ ! -f "$rdir/.allow-migration-edit" ] && [[ $path =~ $re_mig ]]; then keep=1; fi
    [ "$keep" = 1 ] || continue
    if [ -f "$proj/$path" ]; then h=$(git -C "$proj" hash-object -- "$path" 2>/dev/null); else h=gone; fi
    printf '%s\t%s\n' "$line" "${h:-?}"
  done <<EOF
$raw
EOF
}
