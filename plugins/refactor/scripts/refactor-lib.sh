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
RL_NL=$'\n'
RL_TAB=$'\t'

rl_now() { TZ=KST-9 date '+%Y-%m-%d %H:%M'; }
rl_today() { TZ=KST-9 date '+%Y-%m-%d'; }
# 아래 함수들은 RL_TODAY(날짜)가 있으면 date 를 다시 부르지 않는다 — 승인 스크립트가 rl_now 한 번으로 정해 둔다
# (바쁜 PC 에서는 외부 명령 한 번이 0.3초 넘게 걸려, 승인 처리가 입력 훅 제한 시간에 닿지 않게 외부 명령 수를 줄인다)

# cksum 출력("CRC 길이 …") → "CRC.길이" (awk 없이)
rl_cksum_fmt() {
  local s=$1 crc rest
  s=${s#"${s%%[![:space:]]*}"}; crc=${s%%[[:space:]]*}; rest=${s#"$crc"}; rest=${rest#"${rest%%[![:space:]]*}"}
  printf '%s.%s\n' "$crc" "${rest%%[[:space:]]*}"
}

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
function readlog(   line, f, k, act, id, hv, x) {
  if (LOG == "") return
  while ((getline line < LOG) > 0) {
    k = split(line, f, "|")
    if (k < 4) continue
    act = trim(f[2]); id = toupper(trim(f[3])); hv = trim(f[4])
    # "/refactor:go 다시" 로 남긴 재설정 줄: 그 앞의 승인·보류는 모두 무효(지문이 같아도 다시 승인해야 한다)
    if (act == "재설정") { for (x in LAST) delete LAST[x]; for (x in LH) delete LH[x]; continue }
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
          addtxt(cur, s); if (ALT) addtxt("a" cur, s)
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
        else if ((r = rest_of(s, "완료")) != "") { addtxt(cur, "(완료 줄 덧붙임) " r); if (ALT) addtxt("a" cur, "(완료 줄 덧붙임) " r) }
        continue
      }
      if (!INF[i]) {
        if ((v = field(s, "종류")) != "") KIND[cur] = v
        if ((v = field(s, "위험도")) != "") RISK[cur] = v
        if ((v = field(s, "사람이 직접 할 일")) != "") HUMAN[cur] = v
      }
      addtxt(cur, s); if (ALT) addtxt("a" cur, s)
    }
    for (c = 1; c <= nc; c++) {
      f = DIR "/c" c; printf "%s", TXT[c] > f; close(f)
      if (ALT) { f = DIR "/a" c; printf "%s", TXT["a" c] > f; close(f) }
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
#   RL_CARDDIR(빈 임시 폴더)를 주면 그 폴더를 쓰고 지우지 않는다 — c<순번>(카드 본문)·sums(지문)를 다시 쓸 수 있게.
#   RL_ALT=1 이면 a<순번>(승인 줄을 표준 모양으로 다시 쓴 뒤의 본문 = 승인 줄 덧붙임 제외)과 그 지문도 남긴다(승인 직후 상태를 다시 읽지 않고 알려고)
rl_cards() {
  local plan=$1 log=${2:-} tmp=${RL_CARDDIR:-}
  [ -f "$plan" ] || return 0
  [ -n "$tmp" ] || tmp=$(mktemp -d 2>/dev/null) || tmp=$(mktemp -d -t rlcards 2>/dev/null) || return 1
  if awk -v MODE=cards -v PLAN="$plan" -v DIR="$tmp" -v ALT="${RL_ALT:-}" "$RL_AWK" > "$tmp/rec"; then
    (set +f; cd "$tmp" && set -- [ac][0-9]* && [ -f "$1" ] && cksum "$@") > "$tmp/sums" 2>/dev/null
    awk -v MODE=join -v LOG="$log" -v SUMS="$tmp/sums" "$RL_AWK" < "$tmp/rec"
  fi
  [ -n "${RL_CARDDIR:-}" ] || rm -rf "$tmp"
}

# 카드 한 장의 지문용 본문(표준출력) — 승인할 때 approved/<ID>.md 로 남기고, 바뀐 내용을 보여 줄 때 쓴다
rl_card_text() { # $1 계획서 $2 ID
  local tmp n
  tmp=$(mktemp -d 2>/dev/null) || tmp=$(mktemp -d -t rlcard 2>/dev/null) || return 1
  # 앞 awk 가 쓰는 중에 뒤 awk 가 먼저 끝나면 "print to standard output failed" 소음이 나므로 끝까지 읽는다
  n=$(awk -v MODE=cards -v PLAN="$1" -v DIR="$tmp" "$RL_AWK" | awk -F "$RL_US" -v ID="$2" '$1 == "CARD" && $3 == ID && !f { print $2; f = 1 }')
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
  awk -v MODE=rewrite -v PLAN="$1" -v ACT="$2" -v IDS=" $3 " -v TODAY="${RL_TODAY:-$(rl_today)}" "$RL_AWK" > "$tmp" && [ -s "$tmp" ] && mv "$tmp" "$1"
  if [ -e "$tmp" ]; then rm -f "$tmp"; fi
}
rl_rewrite_base() {
  local tmp="$1.tmp.$$"
  awk -v MODE=baserewrite -v PLAN="$1" -v ACT="$2" -v TODAY="${RL_TODAY:-$(rl_today)}" "$RL_AWK" > "$tmp" && [ -s "$tmp" ] && mv "$tmp" "$1"
  if [ -e "$tmp" ]; then rm -f "$tmp"; fi
}

# 승인 기록의 지문(없으면 none) — 턴 중에 바뀌었는지 확인할 때 쓴다. 줄 끝 \r 은 빼고 잰다(git 이 CRLF 로 바꿔 받아도 같은 지문)
#   read 가 0 을 돌려주면 NUL 에서 멈춘 것(파일 끝까지 못 읽음) → \r 이 있을 때처럼 tr 로 전체를 잰다
rl_log_sum() {
  local c="" s
  [ -f "$1" ] || { echo none; return 0; }
  if IFS= read -r -d '' c < "$1" || case "$c" in *$'\r'*) true ;; *) false ;; esac; then
    s=$(tr -d '\r' < "$1" | cksum)
  else
    s=$(cksum < "$1")
  fi
  rl_cksum_fmt "$s"
}
# 승인 기록이 /refactor:approve 가 마지막으로 남긴 모양 그대로인가(approved/.log-sum 과 비교). 기록이 없으면 그대로로 본다
#   0.2.0 이 원본 바이트로 잰 봉인값과 맞아도 그대로로 본다(다음 승인 때 새 방식으로 다시 봉인된다)
rl_log_intact() { # $1 docs/refactor 폴더
  local want="" s
  [ -f "$1/APPROVALS.log" ] || return 0
  [ -f "$1/approved/.log-sum" ] || return 1
  IFS= read -r -d '' want < "$1/approved/.log-sum" || :
  want=${want//$'\r'/}; want=${want//$'\n'/}
  [ "$(rl_log_sum "$1/APPROVALS.log")" = "$want" ] && return 0
  s=$(cksum < "$1/APPROVALS.log")
  [ "$(rl_cksum_fmt "$s")" = "$want" ]
}
# 봉인: 지문과 기록 사본을 남기고, docs/refactor/.gitattributes 가 없으면 만들어 기록이 LF 로 유지되게 한다
#   사본은 파일 끝까지 읽혔으면(NUL 없음) 읽은 그대로 써서 cp 를 부르지 않는다
rl_log_seal() {
  local c=""
  [ -f "$1/.gitattributes" ] || printf '* text eol=lf\n' > "$1/.gitattributes" 2>/dev/null
  { [ -d "$1/approved" ] || mkdir -p "$1/approved"; } && rl_log_sum "$1/APPROVALS.log" > "$1/approved/.log-sum" || return 1
  if [ -f "$1/APPROVALS.log" ] && ! IFS= read -r -d '' c < "$1/APPROVALS.log"; then
    printf '%s' "$c" > "$1/approved/.log-copy" 2>/dev/null || :
  else
    cp "$1/APPROVALS.log" "$1/approved/.log-copy" 2>/dev/null || :
  fi
}
# 봉인 뒤에 달라진 줄(최대 10줄): "+ 더해진 줄" / "- 없어진 줄". 봉인이 아예 없으면 NOSEAL 한 줄
rl_log_changes() { # $1 docs/refactor 폴더
  [ -f "$1/approved/.log-sum" ] || { echo NOSEAL; return 0; }
  [ -f "$1/approved/.log-copy" ] || { echo "   (봉인 때의 기록 사본이 없어 달라진 줄을 보여 줄 수 없음 — git diff 로 확인)"; return 0; }
  local tmp
  tmp=$(mktemp 2>/dev/null) || tmp=$(mktemp -t rllog 2>/dev/null) || return 0
  tr -d '\r' < "$1/approved/.log-copy" > "$tmp"
  tr -d '\r' < "$1/APPROVALS.log" | diff "$tmp" - 2>/dev/null | grep -E '^[<>]' | sed -e 's/^>/   + 더해진 줄:/' -e 's/^</   - 없어진 줄:/' | awk 'NR <= 10'
  rm -f "$tmp"
}
# 마무리(DONE)를 사람이 /refactor:approve 마무리 로 확인했나 — 승인 기록의 마지막 줄이 "마무리" 이고 기록이 그대로일 때만
rl_done_confirmed() { # $1 docs/refactor 폴더
  local last="" line
  [ -f "$1/APPROVALS.log" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do [ -n "${line//[[:space:]]/}" ] && last=$line; done < "$1/APPROVALS.log"
  case "$last" in *"| 마무리 |"*) rl_log_intact "$1" ;; *) return 1 ;; esac
}

# 기준선 허용 파일(docs/refactor/.allow-baseline-edit) 읽기(0.3.2 #10) — $1 docs/refactor 폴더. 표준출력 1줄째:
#   NONE            파일 없음(기준선은 잠김)
#   ALL             공백만(개행·BOM·CR·NUL 포함) — 예전처럼 기준선 전부 허용(사람이 지운다)
#   OPEN <ID…>      적힌 단계 중 지금 열린 단계(승인 기록 approved · 완료 아님 · 같은 ID 카드 하나 · 승인 줄 있음 · 승인 기록 봉인 그대로
#                   = turn.sh ready_ids 와 같은 조건). 2줄째부터 그 카드들의 "깨질 것으로 예상되는 기준선" 칸에 백틱으로 적힌 경로(한 줄에 하나)
#   SHUT <적힌 ID…> 열린 단계가 없고 아직 안 끝난 단계가 있음(승인 대기·보류·카드 바뀜 등) — 잠김
#   DONE <적힌 ID…> 계획서 카드와 맞는 ID 가 하나 이상 있고 그것들이 모두 끝남(계획서에서 사라진 ID 는 끝난 것으로 봄) — 저절로 닫힘(turn.sh 가 다음 입력 때 지운다)
#   UNKNOWN <적힌 ID…> 계획서 카드와 맞는 ID 가 하나도 없음(오타·계획서 없음), 또는 공백 아닌 글자가 있는데 ID 가 0개(주석만·* 등 — ID 자리에 ?) — 잠김, 지우지 않는다
#   $2 = approved 이면 2줄째부터의 경로를 "열린 단계" 대신 "적힌 ID 중 승인된 카드 전부(완료 포함)" 로 낸다(상태 줄은 같다) —
#        턴 끝 알림(rl_protected_dirty)용: 같은 턴에 카드 파일을 고친 뒤 완료 표시를 해도 그 파일을 헛경보하지 않게
#   파일 읽기: NUL·CR 은 떼고(PowerShell 5.1 의 > 는 UTF-16), # 뒤는 주석, ID 글자([A-Za-z0-9_-]) 밖의 글자(BOM 포함)는 칸 나눔, 대소문자 무시
#   경로: 프로젝트 폴더 기준 상대경로로 맞춘다(\ → /, 앞의 ./ 와 / 는 뗌) — 고치려는 파일과 정확히 같을 때만 연다(rl_abl_hit)
rl_allow_baseline() {
  local rd=$1 want=${2:-} ids tmp="" open="" left=0 matched=0 kind_ n_ id t box done_ cnt k r h hv st intact=0 ok
  [ -f "$rd/.allow-baseline-edit" ] || { echo NONE; return 0; }
  ids=$(tr -d '\000\r' < "$rd/.allow-baseline-edit" 2>/dev/null | LC_ALL=C awk '{ s = $0
    if (NR == 1 && substr(s, 1, 3) == "\357\273\277") s = substr(s, 4)
    if (NR == 1 && (substr(s, 1, 2) == "\377\376" || substr(s, 1, 2) == "\376\377")) s = substr(s, 3)
    gsub(/[[:space:]]/, "", s); if (s != "") ns = 1
    sub(/#.*/, ""); gsub(/[^A-Za-z0-9_-]+/, " "); n = split($0, a, " ")
    for (i = 1; i <= n; i++) { u = toupper(a[i]); if (!(u in S)) { S[u] = 1; o = o " " u } } }
    END { if (o != "") print substr(o, 2); else if (ns) print "?" }')
  [ -n "$ids" ] || { echo ALL; return 0; }
  [ "$ids" = "?" ] && { echo "UNKNOWN ?"; return 0; }
  set --
  if [ -f "$rd/REFACTOR_PLAN.md" ]; then
    tmp=$(mktemp -d 2>/dev/null) || tmp=$(mktemp -d -t rlallow 2>/dev/null) || tmp=""
    rl_log_intact "$rd" && intact=1
    while IFS="$RL_US" read -r kind_ n_ id t box done_ cnt k r h hv st; do
      [ "$kind_" = CARD ] || continue
      case " $ids " in *" $id "*) ;; *) continue ;; esac
      matched=1
      ok=0; [ "$intact" = 1 ] && [ "$st" = approved ] && [ "${cnt:-1}" = 1 ] && [ "$box" != none ] && ok=1
      if [ "$ok" = 1 ] && [ "$done_" != 1 ]; then
        open="$open $id"; [ -n "$tmp" ] && [ "$want" != approved ] && set -- "$@" "$tmp/c$n_"
      elif [ "$done_" != 1 ]; then
        left=1
      fi
      [ "$ok" = 1 ] && [ -n "$tmp" ] && [ "$want" = approved ] && set -- "$@" "$tmp/c$n_"
    done <<RLAB
$(RL_CARDDIR=$tmp rl_cards "$rd/REFACTOR_PLAN.md" "$rd/APPROVALS.log")
RLAB
  fi
  if [ -n "$open" ]; then
    echo "OPEN$open"
  elif [ "$left" = 1 ]; then
    echo "SHUT $ids"
  elif [ "$matched" = 0 ]; then
    echo "UNKNOWN $ids"
  else
    echo "DONE $ids"
  fi
  # 카드 본문의 "- **깨질 것으로 예상되는 기준선**:" 줄부터 다음 "- **" 칸·제목 줄 전까지, 백틱 안의 글을 경로로
  if [ "$#" -gt 0 ] && { [ -n "$open" ] || [ "$want" = approved ]; }; then
    LC_ALL=C awk 'FNR == 1 { on = 0 }
      /^[ \t>]*([-+*][ \t]+)?\*\*/ { on = ($0 ~ /^[ \t>]*([-+*][ \t]+)?\*\*[^*]*깨질[^*]*기준선/) }
      /^#/ { on = 0 }
      on { s = $0
        while (match(s, /`[^`]+`/)) {
          p = substr(s, RSTART + 1, RLENGTH - 2); s = substr(s, RSTART + RLENGTH)
          gsub(/\\/, "/", p); sub(/^[ \t]+/, "", p); sub(/[ \t]+$/, "", p); sub(/^(\.?\/)+/, "", p)
          if (p != "" && !(p in S)) { S[p] = 1; print p }
        } }' "$@" 2>/dev/null
  fi
  [ -n "$tmp" ] && rm -rf "$tmp"
  return 0
}
# 경로($1, 프로젝트 폴더 기준 상대경로)가 허용 경로 목록($2, 줄마다 하나)의 하나와 정확히 같은가
rl_abl_hit() {
  local rest="$2$RL_NL" p
  while [ -n "$rest" ]; do
    p=${rest%%"$RL_NL"*}; rest=${rest#*"$RL_NL"}
    [ -n "$p" ] || continue
    case "$1" in "$p") return 0 ;; esac
  done
  return 1
}

# 보호된 파일(커밋된 기준선·마이그레이션) 중 커밋 안 된 변경 목록: "<상태 두 글자> <경로>\t<내용 지문>" 줄들
#   -z 로 받아 한글·공백 파일 이름도 따옴표·\ 이스케이프 없이 그대로 쓴다(이름 바꾸기는 새 경로만)
rl_protected_dirty() {
  local proj=$1 rdir=$2 ent xy path old keep h specs=() abl=NONE ablp="" pfx=""
  command -v git >/dev/null 2>&1 || return 0
  # 기준선 허용 파일: 공백만(ALL)이면 기준선을 통째로 빼고, 단계 ID 가 적혀 있으면 그 중 승인된 카드(완료 포함)에 적힌 파일만 뺀다(0.3.2)
  #   (허용 파일이 남아 있는 동안 — 같은 턴에 카드 파일을 고치고 완료 표시를 해도 헛경보하지 않게. turn.sh 가 지우면 원래대로)
  #   git 은 저장소 루트 기준 경로를 내므로, 프로젝트가 저장소 하위 폴더면 그 접두를 떼고 카드 경로(프로젝트 기준)와 맞춘다
  if [ -f "$rdir/.allow-baseline-edit" ]; then
    abl=$(rl_allow_baseline "$rdir" approved)
    case "$abl" in *"$RL_NL"*) ablp=${abl#*"$RL_NL"}; abl=${abl%%"$RL_NL"*} ;; esac
    [ -n "$ablp" ] && pfx=$(git -C "$proj" rev-parse --show-prefix 2>/dev/null)
  fi
  [ "$abl" = ALL ] || specs+=('*baseline/*')
  [ -f "$rdir/.allow-migration-edit" ] || specs+=('*supabase/migrations/*' '*prisma/migrations/*' '*alembic/versions/*' '*db/migrate/*' '*database/migrations/*' 'migrations/*' '*/migrations/*' 'drizzle/*.sql' 'drizzle/meta/*')
  [ "${#specs[@]}" -eq 0 ] && return 0
  local re_bl='(^|/)(tests?|__tests__|specs?)/([^/]+/)*baseline/'
  local re_mig='(^|/)(supabase/migrations|prisma/migrations|alembic/versions|db/migrate|database/migrations|migrations)/[^/]+|^drizzle/([^/]+[.]sql|meta/)'
  while IFS= read -r -d '' ent; do
    [ "${#ent}" -gt 3 ] || continue
    xy=${ent:0:2}; path=${ent:3}
    case "$xy" in *R*|*C*) IFS= read -r -d '' old ;; esac   # 이름 바꾸기·복사: 다음 칸은 옛 경로
    case "$path" in *"$RL_NL"*|*"$RL_TAB"*|docs/refactor/*) continue ;; esac
    keep=0
    if [ "$abl" != ALL ] && [[ $path =~ $re_bl ]] && ! { [ -n "$ablp" ] && case "$path" in "$pfx"*) rl_abl_hit "${path#"$pfx"}" "$ablp" ;; *) false ;; esac; }; then keep=1; fi
    if [ ! -f "$rdir/.allow-migration-edit" ] && [[ $path =~ $re_mig ]]; then keep=1; fi
    [ "$keep" = 1 ] || continue
    if [ -f "$proj/$path" ]; then h=$(git -C "$proj" hash-object -- "$path" 2>/dev/null); else h=gone; fi
    printf '%s %s\t%s\n' "$xy" "$path" "${h:-?}"
  done < <(git -C "$proj" -c core.quotePath=false status --porcelain -z --untracked-files=no -- "${specs[@]}" 2>/dev/null)
}
