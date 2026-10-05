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

# origin 의 기본 가지(0.3.4 — 새 가지·합치기): refs/remotes/origin/HEAD 가 가리키는 가지(그것이 refs/remotes/origin/ 아래일 때만)
#   → 없으면 origin/main → origin/master(그 자체가 심볼릭이면 기준이 아님 — guard.sh br_judge_in 과 같은 규칙). 로컬 참조만 본다(네트워크 없음)
#   $1 = 프로젝트 폴더 → RL_BNAME(가지 이름, origin/ 뺀 것)·RL_BOID(커밋)·RL_BTREE(트리). 못 정하면 1
rl_origin_base() {
  local out l r c t s
  RL_BNAME=""; RL_BOID=""; RL_BTREE=""
  out=$(git --no-replace-objects -c core.fsmonitor=false -C "$1" for-each-ref --format='%(refname) %(objectname) %(tree) %(symref)' \
        refs/remotes/origin/HEAD refs/remotes/origin/main refs/remotes/origin/master 2>/dev/null) || return 1
  out="$RL_NL$out$RL_NL"
  for r in HEAD main master; do
    case "$out" in *"${RL_NL}refs/remotes/origin/$r "*) ;; *) continue ;; esac
    l=${out#*"${RL_NL}refs/remotes/origin/$r "}; l=${l%%"$RL_NL"*}
    c=${l%% *}; l=${l#* }; t=${l%% *}; s=${l#* }
    [ "$s" = "$t" ] && s=""
    if [ "$r" = HEAD ]; then
      # %(symref) 는 심볼릭을 끝까지 따라간 대상 — 그것이 origin 아래가 아니면 기준으로 쓰지 않는다
      case "$s" in refs/remotes/origin/HEAD) continue ;; refs/remotes/origin/?*) ;; *) continue ;; esac
      r=${s#refs/remotes/origin/}
    else
      [ -n "$s" ] && continue
    fi
    [ -n "$c" ] && [ -n "$t" ] || continue
    RL_BNAME=$r; RL_BOID=$c; RL_BTREE=$t
    return 0
  done
  return 1
}

# 지금 위치(HEAD)의 내용이 커밋 $2 에 다 들어 있나(0.3.4 — 새 가지 R8): $1 = 프로젝트 폴더
#   반환 0 = 들어 있음 · 1 = 안 들어 있음(깨끗이 합쳐지는데 결과가 $2 와 다름) · 2 = 판정 불가(까닭은 RL_MERGED_WHY 에 한 줄)
#   판정 순서(0.3.4 보완 F3): ① HEAD 가 $2 의 조상 ② 트리가 같음(HEAD^{tree} == $2^{tree} — git 판과 상관없이)
#   ③ git cherry $2 HEAD: 범위 $2..HEAD 에 병합 커밋이 없고, 출력이 1줄 이상이며 전부 "-"(같은 변경이 $2 에 이미 있음 — rebase 로 합친 꼴.
#      옛 git·합친 뒤 기본 가지에 같은 줄을 또 고친 커밋이 와도 통함) ④ git merge-tree --write-tree $2 HEAD 의 결과 트리 == $2 의 트리
#   안전장치(guard.sh br_judge_in)와 같은 방어: 대체 객체 무시 · fsmonitor 끔 · renormalize 끔 ·
#   합치기 드라이버(merge.<이름>.driver) 설정이 있으면 merge-tree 를 부르지 않는다(판정 불가 — 드라이버 프로그램이 이 안에서 돌고,
#   늘 "우리 쪽"을 남기는 드라이버면 안 합친 내용도 합친 것처럼 보인다). git 2.38 미만(--write-tree 없음)·충돌도 판정 불가
rl_merged_into() {
  local rc bt ht t m c l
  local G=(git --no-replace-objects -c core.fsmonitor=false -C "$1")
  RL_MERGED_WHY=""
  "${G[@]}" merge-base --is-ancestor HEAD "$2" 2>/dev/null; rc=$?
  [ "$rc" = 0 ] && return 0
  [ "$rc" = 1 ] || { RL_MERGED_WHY="git 이 두 커밋을 비교하지 못했습니다"; return 2; }
  bt=$("${G[@]}" rev-parse -q --verify "$2^{tree}" 2>/dev/null)
  ht=$("${G[@]}" rev-parse -q --verify 'HEAD^{tree}' 2>/dev/null)
  [ -n "$bt" ] && [ -n "$ht" ] || { RL_MERGED_WHY="git 이 두 커밋을 비교하지 못했습니다"; return 2; }
  [ "$ht" = "$bt" ] && return 0
  m=$("${G[@]}" rev-list --merges --count "$2..HEAD" 2>/dev/null)
  if [ "$m" = 0 ] && c=$("${G[@]}" cherry "$2" HEAD 2>/dev/null) && [ -n "$c" ]; then
    rc=0
    while IFS= read -r l; do case "$l" in "- "?*) ;; *) rc=1; break ;; esac; done <<RLCH
$c
RLCH
    [ "$rc" = 0 ] && return 0
  fi
  "${G[@]}" config --name-only --get-regexp '^merge[.].+[.]driver$' >/dev/null 2>&1; rc=$?
  [ "$rc" = 0 ] && { RL_MERGED_WHY="이 저장소에 합치기 드라이버(merge.<이름>.driver) 설정이 있어 내용 비교를 하지 않았습니다"; return 2; }
  [ "$rc" = 1 ] || { RL_MERGED_WHY="git 이 저장소 설정을 읽지 못했습니다"; return 2; }
  t=$("${G[@]}" -c merge.renormalize=false merge-tree --write-tree "$2" HEAD 2>/dev/null); rc=$?
  case "$rc" in
    0) [ "${t%%"$RL_NL"*}" = "$bt" ] && return 0; return 1 ;;
    1) RL_MERGED_WHY="합친 뒤 기본 가지에서 같은 곳이 다시 바뀌어 git 이 내용을 맞춰 보지 못했습니다(겹침)" ;;
    *) RL_MERGED_WHY="이 PC 의 git 이 내용 비교(git merge-tree --write-tree — git 2.38 이상)를 하지 못했습니다" ;;
  esac
  return 2
}

# 시간 한도 안에서 명령 실행(0.3.4 — 합치기의 gh 호출): $1 = 초, 나머지 = 명령. 종료 코드는 명령의 것, 한도에 걸렸으면 124
#   bash 만으로(외부 timeout·perl 에 기대지 않는다 — 맥에는 timeout 이 없고, gh(Go)는 perl alarm 의 SIGALRM 을 무시하며,
#   Windows 는 System32 의 다른 timeout.exe 가 먼저 잡힐 수 있다). bash 3.2 에서도 돈다(bash 4.3 의 '아무 하나 끝나기를 기다리기' 옵션은 안 씀)
#   명령을 백그라운드로 띄우고, 감시(출력을 /dev/null 로 — 안 그러면 $( ) 가 감시가 끝날 때까지 기다린다)가 N초 뒤 표시 파일을 만들고
#   TERM → 1초 뒤에도 살아 있으면 KILL. 명령이 먼저 끝나면 감시를 끈다(감시는 TERM 을 받으면 자기 sleep 도 끄고 나간다)
rl_bounded() {
  local s=$1 md pid wpid rc
  shift
  md=$(mktemp -d 2>/dev/null) || md=$(mktemp -d -t rlbound 2>/dev/null) || md=""
  if [ -z "$md" ]; then "$@"; return; fi
  "$@" &
  pid=$!
  (
    sp=""
    trap '[ -n "$sp" ] && kill "$sp" 2>/dev/null; exit 0' TERM
    sleep "$s" &
    sp=$!
    wait "$sp"
    kill -0 "$pid" 2>/dev/null || exit 0
    : > "$md/t"
    kill -TERM "$pid" 2>/dev/null
    sleep 1 &
    sp=$!
    wait "$sp"
    kill -KILL "$pid" 2>/dev/null
    exit 0
  ) >/dev/null 2>&1 &
  wpid=$!
  wait "$pid"
  rc=$?
  kill -TERM "$wpid" 2>/dev/null
  wait "$wpid" 2>/dev/null
  [ -f "$md/t" ] && rc=124
  rm -rf "$md"
  return "$rc"
}

# 기준선 허용 파일(docs/refactor/.allow-baseline-edit) 읽기(0.3.2 #10) — $1 docs/refactor 폴더. 표준출력 1줄째:
#   NONE            파일 없음(기준선은 잠김)
#   ALL             공백만(개행·BOM·CR·NUL 포함) — 예전처럼 기준선 전부 허용(사람이 지운다)
#   OPEN <ID…>      적힌 단계 중 지금 열린 단계(승인 기록 approved · 완료 아님 · 같은 ID 카드 하나 · 승인 줄 있음 · 승인 기록 봉인 그대로
#                   = turn.sh ready_ids 와 같은 조건) 중 지금 실행 중인 단계 — STATE.md 앞머리 current_step 값에 적힌 ID(0.3.3,
#                   ID 글자 밖은 칸 나눔·대소문자 무시 · 본문은 안 읽음). 2줄째부터 그 카드들의 "깨질 것으로 예상되는 기준선" 칸에 백틱으로 적힌 경로(한 줄에 하나)
#   WAIT <열린 ID…> 열린 단계는 있지만 current_step 에 그 단계가 안 적혀 있음(값 없음·"-"·STATE 없음·다른 단계 — 0.3.3) — 잠김, 경로 없음
#   SHUT <적힌 ID…> 열린 단계가 없고 아직 안 끝난 단계가 있음(승인 대기·보류·카드 바뀜 등) — 잠김
#   DONE <적힌 ID…> 계획서 카드와 맞는 ID 가 하나 이상 있고 그것들이 모두 끝남(계획서에서 사라진 ID 는 끝난 것으로 봄) — 저절로 닫힘(turn.sh 가 다음 입력 때 지운다)
#   UNKNOWN <적힌 ID…> 계획서 카드와 맞는 ID 가 하나도 없음(오타·계획서 없음), 또는 공백 아닌 글자가 있는데 ID 가 0개(주석만·* 등 — ID 자리에 ?) — 잠김, 지우지 않는다
#   $2 = approved 이면 2줄째부터의 경로를 "실행 중인 단계" 대신 "적힌 ID 중 승인된 카드 전부(완료 포함)" 로 낸다(상태 줄은 같다 — WAIT 여도 경로를 낸다) —
#        턴 끝 알림(rl_protected_dirty)용: 같은 턴에 카드 파일을 고친 뒤 완료 표시를 해도 그 파일을 헛경보하지 않게
#   $2 = split 이면 approved 와 같은 카드들의 경로를 "O<TAB><경로>"(완료 아닌 카드) / "D<TAB><ID><TAB><경로>"(완료 카드) 로 낸다(0.3.5 #1 —
#        rl_protected_dirty 가 완료 카드에만 속한 경로를 그 카드의 커밋 여부로 가른다). 한 경로가 두 꼴에 함께 나올 수 있다
#   파일 읽기: NUL·CR 은 떼고(PowerShell 5.1 의 > 는 UTF-16), # 뒤는 주석, ID 글자([A-Za-z0-9_-]) 밖의 글자(BOM 포함)는 칸 나눔, 대소문자 무시
#   경로: 프로젝트 폴더 기준 상대경로로 맞춘다(\ → /, 앞의 ./ 와 / 는 뗌) — 고치려는 파일과 정확히 같을 때만 연다(rl_abl_hit)
rl_allow_baseline() {
  local rd=$1 want=${2:-} ids tmp="" open="" left=0 matched=0 kind_ n_ id t box done_ cnt k r h hv st intact=0 ok dm="" all=0
  case "$want" in approved|split) all=1 ;; esac
  [ -f "$rd/.allow-baseline-edit" ] || { echo NONE; return 0; }
  ids=$(rl_allow_ids "$rd")
  [ -n "$ids" ] || { echo ALL; return 0; }
  [ "$ids" = "?" ] && { echo "UNKNOWN ?"; return 0; }
  # 지금 실행 중인 단계(0.3.3): STATE.md 앞머리(첫 줄 --- 부터 다음 --- 전까지)의 current_step 값 — bash 내장 read 만(외부 명령 없이)
  #   ID 글자 밖은 칸 나눔, 대문자로 → cw = " P1-1 P1-2 " 꼴
  local cw="" ln fm=0 lo=abcdefghijklmnopqrstuvwxyz up=ABCDEFGHIJKLMNOPQRSTUVWXYZ i=0 cur=""
  if [ -f "$rd/STATE.md" ]; then
    while IFS= read -r ln || [ -n "$ln" ]; do
      ln=${ln%$'\r'}
      if [ "$fm" = 0 ]; then
        ln=${ln#$'\357\273\277'}
        case "$ln" in ---*) fm=1; continue ;; *) break ;; esac
      fi
      case "$ln" in
        ---*) break ;;
        current_step:*) cw=${ln#current_step:}; break ;;
      esac
    done < "$rd/STATE.md"
  fi
  while [ "$i" -lt 26 ]; do cw=${cw//${lo:i:1}/${up:i:1}}; i=$((i + 1)); done
  # 같은 묶음의 숫자 범위 "P1-1~P1-5"(물결 앞뒤 공백 허용 · 시작 ≤ 끝 · 99칸 이하)는 사이 단계까지 펼친다(검사 보완 F1).
  #   묶음이 다르거나(P1-1~P2-3)·끝이 숫자가 아니거나(P1-3A)·거꾸로·너무 넓으면 펼치지 않는다(양 끝 낱말만 남는다)
  local re_rng='([A-Z0-9_]+)-([0-9]{1,6})[[:space:]]*~[[:space:]]*([A-Z0-9_]+)-([0-9]{1,6})([^A-Z0-9_-]|$)' rs=$cw ro="" rm rb rc rj rx
  while [[ $rs =~ $re_rng ]]; do
    rm=${BASH_REMATCH[0]}; rm=${rm%"${BASH_REMATCH[5]}"}; rx=${BASH_REMATCH[1]}; rb=$((10#${BASH_REMATCH[2]})); rc=$((10#${BASH_REMATCH[4]}))
    ro="$ro${rs%%"$rm"*}"; rs=${rs#*"$rm"}
    if [ "$rx" = "${BASH_REMATCH[3]}" ] && [ "$rb" -le "$rc" ] && [ $((rc - rb)) -le 99 ]; then
      rj=$rb; while [ "$rj" -le "$rc" ]; do ro="$ro $rx-$rj"; rj=$((rj + 1)); done; ro="$ro "
    else
      ro="$ro${rm//\~/ }"
    fi
  done
  cw=$ro$rs
  cw=${cw//[!A-Za-z0-9_-]/ }
  cw=" $cw "
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
        open="$open $id"
        case "$cw" in *" $id "*) cur="$cur $id"; [ -n "$tmp" ] && [ "$all" = 0 ] && set -- "$@" "$tmp/c$n_" ;; esac
      elif [ "$done_" != 1 ]; then
        left=1
      fi
      if [ "$ok" = 1 ] && [ -n "$tmp" ] && [ "$all" = 1 ]; then
        set -- "$@" "$tmp/c$n_"
        # split: 카드 파일 이름 → "<ID>:<D 완료|O 아님>" (rl_card_bl_paths -n 의 파일 이름 칸으로 찾는다)
        if [ "$done_" = 1 ]; then dm="$dm c$n_=$id:D"; else dm="$dm c$n_=$id:O"; fi
      fi
    done <<RLAB
$(RL_CARDDIR=$tmp rl_cards "$rd/REFACTOR_PLAN.md" "$rd/APPROVALS.log")
RLAB
  fi
  if [ -n "$cur" ]; then
    echo "OPEN$cur"
  elif [ -n "$open" ]; then
    echo "WAIT$open"
  elif [ "$left" = 1 ]; then
    echo "SHUT $ids"
  elif [ "$matched" = 0 ]; then
    echo "UNKNOWN $ids"
  else
    echo "DONE $ids"
  fi
  # 카드 본문의 "- **깨질 것으로 예상되는 기준선**:" 줄부터 다음 "- **" 칸·제목 줄 전까지, 백틱 안의 글을 경로로
  if [ "$#" -gt 0 ] && [ "$want" = split ]; then
    local f_ p_ v_
    rl_card_bl_paths -n "$@" | while IFS="$RL_TAB" read -r f_ p_; do
      [ -n "$p_" ] && [ "$p_" != "?" ] || continue
      case "$dm " in *" $f_="*) ;; *) continue ;; esac
      v_=${dm#*" $f_="}; v_=${v_%% *}
      case "$v_" in *:D) printf 'D\t%s\t%s\n' "${v_%:D}" "$p_" ;; *) printf 'O\t%s\n' "$p_" ;; esac
    done
  elif [ "$#" -gt 0 ] && { [ -n "$cur" ] || [ "$all" = 1 ]; }; then
    rl_card_bl_paths "$@"
  fi
  [ -n "$tmp" ] && rm -rf "$tmp"
  return 0
}
# 기준선 허용 파일에서 단계 ID 뽑기(0.3.3 — rl_allow_baseline 에서 뗌) — $1 docs/refactor 폴더. 출력 1줄:
#   ID 들(대문자·공백 구분·중복 제거) / ?(공백 아닌 글자가 있는데 ID 0개) / 빈 출력(공백만 또는 파일 없음)
#   NUL·CR 은 떼고(PowerShell 5.1 의 > 는 UTF-16), 첫 줄의 BOM 은 떼고, # 뒤는 주석, ID 글자([A-Za-z0-9_-]) 밖은 칸 나눔
rl_allow_ids() {
  [ -f "$1/.allow-baseline-edit" ] || return 0
  tr -d '\000\r' < "$1/.allow-baseline-edit" 2>/dev/null | LC_ALL=C awk '{ s = $0
    if (NR == 1 && substr(s, 1, 3) == "\357\273\277") s = substr(s, 4)
    if (NR == 1 && (substr(s, 1, 2) == "\377\376" || substr(s, 1, 2) == "\376\377")) s = substr(s, 3)
    gsub(/[[:space:]]/, "", s); if (s != "") ns = 1
    sub(/#.*/, ""); gsub(/[^A-Za-z0-9_-]+/, " "); n = split($0, a, " ")
    for (i = 1; i <= n; i++) { u = toupper(a[i]); if (!(u in S)) { S[u] = 1; o = o " " u } } }
    END { if (o != "") print substr(o, 2); else if (ns) print "?" }'
}
# 카드 본문 파일들의 "- **깨질 것으로 예상되는 기준선**:" 칸(그 줄부터 다음 "- **" 칸·제목 줄 전까지)에서 백틱 안의 글을 경로로(0.3.3 — rl_allow_baseline 에서 뗌)
#   경로는 \ → /, 앞뒤 공백·앞의 ./ 와 / 를 뗀다. 기본 = 한 줄에 경로 하나(전체 중복 제거)
#   -n = "<파일 이름(폴더 뺀 끝 이름)><TAB><경로>" 를 파일마다(그 파일 안에서만 중복 제거). 칸에 글이 있는데(공백 뗀 글이 "없음" 으로
#        시작하지 않음) 백틱 경로가 0개인 파일은 "<파일 이름><TAB>?" 한 줄. 칸이 없거나 "없음" 이면 그 파일은 줄 없음
rl_card_bl_paths() { # [-n] <카드 본문 파일…>
  local nm=0
  [ "${1:-}" = -n ] && { nm=1; shift; }
  [ "$#" -gt 0 ] || return 0
  LC_ALL=C awk -v NM="$nm" '
    function fl() { if (NM == 1 && cur != "" && txt != "" && index(txt, "없음") != 1 && np == 0) print cur "\t?" }
    FNR == 1 { fl(); on = 0; fi++; cur = FILENAME; sub(/.*\//, "", cur); txt = ""; np = 0 }
    /^[ \t>]*([-+*][ \t]+)?\*\*/ { on = ($0 ~ /^[ \t>]*([-+*][ \t]+)?\*\*[^*]*깨질[^*]*기준선/); hd = on }
    /^#/ { on = 0 }
    on { s = $0
      if (NM == 1) { u = s; if (hd) sub(/^[ \t>]*([-+*][ \t]+)?\*\*[^*]*\*\*[ \t]*:?/, "", u); hd = 0; gsub(/[[:space:]]/, "", u); txt = txt u }
      while (match(s, /`[^`]+`/)) {
        p = substr(s, RSTART + 1, RLENGTH - 2); s = substr(s, RSTART + RLENGTH)
        gsub(/\\/, "/", p); sub(/^[ \t]+/, "", p); sub(/[ \t]+$/, "", p); sub(/^(\.?\/)+/, "", p)
        if (p == "") continue
        if (NM == 1) { if (!((fi, p) in S)) { S[fi, p] = 1; np++; print cur "\t" p } }
        else if (!(p in S)) { S[p] = 1; print p }
      } }
    END { fl() }' "$@" 2>/dev/null
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
  local proj=$1 rdir=$2 ent xy path old keep h specs=() abl=NONE ablp="" ablo="" abld="" pfx="" pfxd=0 rp dl rest dids did subj lgd=0 lgs="" lga="" lgl lgx lgr lgh since lgc=()
  command -v git >/dev/null 2>&1 || return 0
  # 기준선 허용 파일: 공백만(ALL)이면 기준선을 통째로 빼고, 단계 ID 가 적혀 있으면 그 중 승인된 카드(완료 포함)에 적힌 파일만 뺀다(0.3.2)
  #   (허용 파일이 남아 있는 동안 — 같은 턴에 카드 파일을 고치고 완료 표시를 해도 헛경보하지 않게. turn.sh 가 지우면 원래대로)
  #   단, 완료 카드에만 속한 경로는 그 카드가 이미 커밋됐으면 빼지 않는다(0.3.5 #1 — 이어서 실행 중 뒤 단계가 앞 단계의 커밋된 기준선을
  #   다시 바꾸면 알림). 커밋됨 = 그 경로를 적은 완료 카드 전부에 이번 묶음 안에서 제목이 "refactor: <ID> " 로 시작하는 커밋이 있음
  #   (7-execute 의 커밋 메시지 규칙 · 이번 묶음 = 아래 0.3.7 #6)
  #   git 은 저장소 루트 기준 경로를 내므로, 프로젝트가 저장소 하위 폴더면 그 접두를 떼고 카드 경로(프로젝트 기준)와 맞춘다
  if [ -f "$rdir/.allow-baseline-edit" ]; then
    abl=$(rl_allow_baseline "$rdir" split)
    case "$abl" in *"$RL_NL"*) ablp=${abl#*"$RL_NL"}; abl=${abl%%"$RL_NL"*} ;; esac
    # ablo = 완료 아닌 카드의 경로(줄마다 하나) · abld = 완료 카드의 "<ID><TAB><경로>" 줄
    rest="$ablp$RL_NL"
    while [ -n "$rest" ]; do
      dl=${rest%%"$RL_NL"*}; rest=${rest#*"$RL_NL"}
      case "$dl" in O"$RL_TAB"*) ablo="$ablo${dl#O"$RL_TAB"}$RL_NL" ;; D"$RL_TAB"*) abld="$abld${dl#D"$RL_TAB"}$RL_NL" ;; esac
    done
    [ -n "$ablo$abld" ] && { pfx=$(git -C "$proj" rev-parse --show-prefix 2>/dev/null); pfxd=1; }
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
    # HEAD 에 없는 새 파일(index 에 막 올림 = 첫 칸 A · 올릴 예정 표시 git add -N = 둘째 칸만 A)은 "이미 커밋된 파일"이 아니다(0.3.4 보완 F1 —
    #   기준선 단계의 새 기준선·단계 실행의 새 마이그레이션을 git add 하면 헛경보가 났다). 고침·지움·이름 바꾸기·복사(M·D·R·C)는 그대로 잡는다.
    #   합치기 충돌(AA·AU — HEAD 에 파일이 있음)은 새 파일이 아니라 잡는다(재검사 R)
    case "$xy" in "A "|AM|AD|" A") continue ;; esac
    case "$path" in *"$RL_NL"*|*"$RL_TAB"*|docs/refactor/*) continue ;; esac
    keep=0
    if [ "$abl" != ALL ] && [[ $path =~ $re_bl ]]; then
      keep=1
      if [ -n "$ablo$abld" ]; then
        case "$path" in "$pfx"*) rp=${path#"$pfx"} ;; *) rp="" ;; esac
        if [ -z "$rp" ]; then
          :
        elif rl_abl_hit "$rp" "$ablo"; then
          keep=0                                  # 완료 아닌 승인 카드의 경로(그 카드의 정당한 변경)
        else
          dids=""; rest=$abld
          while [ -n "$rest" ]; do
            dl=${rest%%"$RL_NL"*}; rest=${rest#*"$RL_NL"}
            [ "${dl#*"$RL_TAB"}" = "$rp" ] && dids="$dids ${dl%%"$RL_TAB"*}"
          done
          # 완료 카드에만 속한 경로일 때만 git 을 더 부른다(평소 비용 0 · 완료 카드 ID 마다 1회): 그 경로를 가진 완료 카드 **전부**가
          #   이번 묶음 안에 자기 커밋(제목이 "refactor: <ID> " 로 시작 — 경로 무관)을 가졌으면 남기고(알림), 아니면 뺀다(조용 — 0.3.5 보완 F3:
          #   같은 기준선을 적은 뒤 카드가 완료 표시 ~ 커밋 사이면 조용).
          #   이번 묶음 = 승인 기록의 마지막 "새 가지 | … @<sha>" 줄이 있으면 <sha>..HEAD, 그 카드의 마지막 "승인 | <ID>" 줄 시각이 있으면 그 뒤
          #   (0.3.7 #6 — 기록 전체를 보면 지난 묶음·되돌린 실행의 같은 ID 커밋 때문에 커밋 전에도 헛알림이 났다). 기록 시각은 KST(rl_now)라
          #   git 에는 +0900 을 붙여 넘긴다(git 은 시간대가 없는 시각을 그 PC 의 TZ 로 읽는다 — CI·다른 시간대 PC). 둘 다 없으면 기록 전체.
          #   0.3.5 의 ②(그 경로를 마지막으로 바꾼 커밋의 제목)는 뺐다(0.3.7 #7) — 앞 단계 커밋이 안 건드린 기준선이 완료 뒤 바뀌어도 알린다.
          #   git 호출은 완료 카드 ID 마다 log 1회(카드 커밋과 revert 를 함께 읽음)
          if [ -n "$dids" ]; then
            if [ "$lgd" = 0 ]; then   # 승인 기록은 한 번만 읽는다(git 호출 0)
              lgd=1
              if [ -f "$rdir/APPROVALS.log" ]; then
                while IFS= read -r lgl || [ -n "$lgl" ]; do
                  lgl=${lgl%$'\r'}
                  case "${lgl:0:16}" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]" "[0-9][0-9]:[0-9][0-9]) ;; *) continue ;; esac
                  lgx=${lgl:16}
                  case "$lgx" in
                    " KST | 승인 | "*) lgx=${lgx#" KST | 승인 | "}; lga="$lga${lgx%%" | "*}$RL_TAB${lgl:0:16}$RL_NL" ;;
                    " KST | 새 가지 | "*)
                      lgx=${lgx#" KST | 새 가지 | "}; lgx=${lgx%%" | "*}; lgx=${lgx##*@}; lgs=""
                      case "$lgx" in *[!0-9a-f]*) ;; ????*) lgs=$lgx ;; esac ;;
                  esac
                done < "$rdir/APPROVALS.log"
              fi
            fi
            keep=1
            for did in $dids; do
              since=""; rest=$lga
              while [ -n "$rest" ]; do
                dl=${rest%%"$RL_NL"*}; rest=${rest#*"$RL_NL"}
                [ "${dl%%"$RL_TAB"*}" = "$did" ] && since=${dl#*"$RL_TAB"}
              done
              # 같은 호출로 그 범위의 revert 도 읽는다: 본문에 "This reverts commit <해시>" 가 있으면 그 카드 커밋은 되돌려짐 = 커밋 안 됨
              #   (0.3.7 — README 의 되돌리는 길 "git revert → 다시 실행" 에서 완료 표시 ~ 커밋 사이 헛알림이 나지 않게).
              #   한계: 되돌린 것을 다시 되돌리면(Reapply) 그 카드 커밋은 여전히 되돌려진 것으로 보여 다음 커밋까지 알림이 늦을 수 있다
              #   범위를 넣은 git log 가 실패하면(새 가지 줄의 sha 가 저장소에 없음·모호 — 보완 A#4) 범위 없이 다시 부른다(놓치는 쪽 → 알리는 쪽)
              lgc=(git --no-replace-objects -c core.fsmonitor=false -c log.showSignature=false -c log.follow=false -c grep.patternType=basic -C "$proj" log --format='%H%x01%s%x01%b%x02' --grep="^refactor: $did " --grep='^This reverts commit ' ${since:+"--since=$since +0900"})
              lgx=$("${lgc[@]}" ${lgs:+"$lgs..HEAD"} 2>/dev/null) || { [ -n "$lgs" ] && lgx=$("${lgc[@]}" 2>/dev/null); }
              subj=""; lgr=" "; lgh=""
              while [ -n "$lgx" ]; do
                lgl=${lgx%%$'\x02'*}
                case "$lgx" in *$'\x02'*) lgx=${lgx#*$'\x02'} ;; *) lgx="" ;; esac
                lgl=${lgl#"$RL_NL"}
                case "$lgl" in *$'\x01'*$'\x01'*) ;; *) continue ;; esac
                dl=${lgl#*$'\x01'}
                case "${dl%%$'\x01'*}" in "refactor: $did "*) lgh="$lgh ${lgl%%$'\x01'*}" ;; esac
                dl=${dl#*$'\x01'}
                while :; do
                  case "$dl" in *"This reverts commit "*) dl=${dl#*"This reverts commit "}; lgr="$lgr${dl:0:40} " ;; *) break ;; esac
                done
              done
              for dl in $lgh; do case "$lgr" in *" $dl "*) ;; *) subj=$dl; break ;; esac; done
              [ -n "$subj" ] || { keep=0; break; }
            done
          fi
        fi
      fi
    fi
    if [ ! -f "$rdir/.allow-migration-edit" ] && [[ $path =~ $re_mig ]]; then keep=1; fi
    [ "$keep" = 1 ] || continue
    # 지문은 프로젝트 기준 경로로(0.3.7 #8 — git status 는 저장소 루트 기준이라 하위 폴더 프로젝트에서 늘 gone 이었다). 접두는 목록에 남는 줄이
    #   처음 나올 때 한 번만 구한다(목록이 비면 git 호출 0 추가). 출력 칸의 경로는 그대로 저장소 기준(턴 시작 스냅숏과 같은 꼴)
    [ "$pfxd" = 1 ] || { pfx=$(git -C "$proj" rev-parse --show-prefix 2>/dev/null); pfxd=1; }
    rp=${path#"$pfx"}
    if [ -f "$proj/$rp" ]; then h=$(git -C "$proj" hash-object -- "$rp" 2>/dev/null); else h=gone; fi
    printf '%s %s\t%s\n' "$xy" "$path" "${h:-?}"
  done < <(git -C "$proj" -c core.quotePath=false status --porcelain -z --untracked-files=no -- "${specs[@]}" 2>/dev/null)
}
