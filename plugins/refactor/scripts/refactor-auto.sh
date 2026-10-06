#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Vibe Refactor — 자동 마감 스크립트 (0.4.0 자동 모드, /refactor:approve B1 자동 의 뒷부분 · 7-execute 「8. 자동 마감」)
#
# 사용자가 입력창에 /refactor:approve B1 자동 을 치면 승인 스크립트가 묶음을 승인하고 허락 파일 docs/refactor/.turn-auto.B1 을 만든다.
# 그다음 인자 없는 /refactor:go 한 차례(입력 훅이 그 파일의 go= 를 채움)에서 묶음 카드가 모두 끝나면 Claude 가 Bash 도구로 단계마다 한 줄 그대로:
#   bash "<플러그인>/hooks/run.sh" refactor-auto <단계> "<프로젝트 폴더>" <B1> <세션ID>
#   단계 = preflight → push → pr → merge(여기까지 .turn-auto 필요) → deploy-wait → verify(합친 뒤 — .turn-merged 필요)
# 안전장치(guard)는 이 꼴 그대로이고 유효한 허락 파일이 있을 때만 통과시킨다(그 안에서 부르는 git·gh·curl·node 는 판정 대상이 아니다).
#
# 종료 코드(합치기 스크립트와 같은 규칙): 0 = 다음 단계로 · 3 = 같은 명령을 그대로 다시(허락 유지) · 1 = 거절(멈추고 보고)
#   결과 첫 줄은 ✅(다음)·⏳/⚠️(다시 — 3)·⛔/⚠️(거절 — 1) 로 시작한다. 각 호출은 최악 약 110초 안(Bash 도구 기본 한도 120초).
# 허락 검사(§2-1 #3 — 수명·사람 입력은 push·merge 앞까지): preflight·push·pr·merge = .turn-auto.<B> 가 유효(① B ② 만든 지 0~7200초
#   ③ 이 세션 ④ 지금 가지 = 승인 때 가지 ⑪ go= 채워짐 — 사람이 인자 없는 /refactor:go 를 침). 합치기 전 단계의 거절(1)은 그 묶음의 자동 모드를 끝낸다
#   (.turn-auto·.turn-autopre 를 지움 — 사람 입력이면 끝 규칙과 같게, 다시 만들지 않는다). 합친 뒤(deploy-wait·verify)는 .turn-merged.<B> 만 본다
#   (입력 훅이 지우지 않음 — 결정 다: 합친 뒤 읽기 단계는 시간·사람 입력과 무관하게 끝까지). verify 가 끝나면(통과·실패) .turn-merged 를 지운다.
#   허락을 지울 때는 끝 표시 .turn-autoend.<B> 를 남긴다(셸 명령 뒤 점검 전용 — 그 차례에 더한 자동 줄을 알리지 않게 · 다음 사람 입력에 입력 훅이 지움).
#   0.4.0 보완: 허락은 봉인된 기록의 "| 자동 | B<n> | - | <시각> <가지> <방식>" 줄과 같아야 하고, push·merge 는 preflight 때 커밋(.turn-autopre ③)일 때만.
# 기록: 푸시·합치기 허락 줄만 승인 기록에 "| - | 자동 B1 으로 실행" 꼴로 더하고 봉인한다(셸 명령 뒤 점검은 이 꼴만 더해졌으면 알리지 않는다 — §2-3).
# 되돌리기·배포·자동 되돌리기는 하지 않는다(검증 실패면 멈추고 사람에게 되돌리는 길을 알린다).
# 0.4.0 새 가지: verify 가 통과하면 다음 묶음의 작업 가지를 만든다(git fetch origin 뒤 lib rl_new_branch — 사람 /refactor:approve 새 가지 와 같은 확인 ·
#   기록 끝 칸만 "자동 B<n> 으로 실행"). merge-only · 합친 뒤 사람 입력(.turn-nextok 없음) · 받아 오기 실패 · 남은 묶음 0 이면 만들지 않고 안내만(종료 코드 0 그대로).
#
# 시험용 줄이기 전용 환경 변수(정수 · 기본값보다 크거나 정수가 아니면 무시):
#   REFACTOR_AUTO_INTERVAL(10) · REFACTOR_AUTO_WINDOW(60 — deploy-wait 한 호출의 상한 · 한 바퀴 최악 시간까지 넣어 다음 바퀴를 시작할지 정함) · REFACTOR_AUTO_DEPLOY_LIMIT(1800, 1 이상) · REFACTOR_AUTO_HTTP_LIMIT(8, 1 이상) ·
#   REFACTOR_AUTO_GH_LIMIT(15, 1 이상) · REFACTOR_AUTO_PUSH_LIMIT(60, 1 이상) · REFACTOR_AUTO_PAGE_LIMIT(15, 1 이상)
# ─────────────────────────────────────────────────────────────────────────────

LC_ALL=C
export LC_ALL
set -f

t0=$SECONDS
say() { printf '%s\n' "$*"; }
usage() {
  say "❓ 쓰는 법: bash \"<플러그인>/hooks/run.sh\" refactor-auto <단계> \"<프로젝트 폴더>\" <B1> <세션ID> (단계 = preflight·push·pr·merge·deploy-wait·verify — 7-execute 「8. 자동 마감」 대로)"
  [ -n "${1:-}" ] && say "   ($1)"
  exit 1
}

# ── 인자·lib ────────────────────────────────────────────────────────────────
[ "$#" = 4 ] || usage
st=$1; proj=$2; B=$3; sid=$4
proj=${proj//"\\"//}; proj=${proj%/}
case "$st" in preflight|push|pr|merge|deploy-wait|verify) ;; *) usage "단계 이름이 아닙니다: $st" ;; esac
re_b='^B(0|[1-9][0-9]{0,5})$'   # 승인 스크립트와 같게 앞에 0 을 붙인 이름(B01)은 받지 않는다
[[ $B =~ $re_b ]] || usage "묶음 이름 꼴(B1)이 아닙니다"
[[ $sid =~ ^[A-Za-z0-9_-]{1,128}$ ]] || usage "세션 ID 꼴이 아닙니다"
[ -n "$proj" ] && [ -d "$proj" ] || usage "프로젝트 폴더가 없습니다"
root=${REFACTOR_ROOT:-}
[ -z "$root" ] && case "${BASH_SOURCE[0]}" in */*) root="${BASH_SOURCE[0]%/*}/.." ;; esac
lib="$root/scripts/refactor-lib.sh"
{ [ -n "$root" ] && [ -f "$lib" ]; } || usage "도구 파일(refactor-lib.sh)을 찾지 못했습니다 — 플러그인을 다시 설치해 주세요"
libsrc=""; IFS= read -r -d '' libsrc < "$lib" || :
eval "${libsrc//$'\r'/}"; unset libsrc
US=$RL_US; NL=$RL_NL

dir="$proj/docs/refactor"
log="$dir/APPROVALS.log"
AF="$dir/.turn-auto.$B"       # 자동 허락(승인 스크립트가 만듦 — 합치기 전 단계)
PF="$dir/.turn-autopre.$B"    # preflight 가 적은 것(1줄 = 시각 · 2줄 = 판 표지 옛 값(merge 첫 호출이 합치기 직전 값으로 고침) · 3줄 = 그때 커밋 — push·merge 는 이 커밋일 때만)
MF="$dir/.turn-merged.$B"     # 합친 뒤 허락(merge 단계가 만듦 — deploy-wait·verify)
EF="$dir/.turn-autoend.$B"    # 끝 표시(자동 모드가 끝날 때 남김 — ① B ② 끝난 시각 ③ 세션 ④ 가지 ⑤ 방식). 셸 명령 뒤 점검이 이 차례의 자동 줄을 알리지 않게만 쓴다
                              #   (자동 단계의 허락 근거가 아니다 — 이 스크립트·합치기 스크립트는 읽지 않음). 입력 훅이 다음 사람 입력에 지운다
NX="$dir/.turn-nextok.$B"     # 합친 뒤 사람 입력 없음 표시(merge 가 씀 — ① B ② 시각 ③ 세션 ④⑤⑥ 합치기 허락 때의 대화 기록 경로·크기·시각(0.4.1 R7 — 없으면 빈 줄)).
                              #   입력 훅이 사람 입력마다 지운다 · verify 성공 끝에 새 가지를 만들 근거 · verify·합친 뒤 거절이 끝에 지운다

lim() {
  LIMV=$2
  case "$1" in ""|*[!0-9]*) return 0 ;; esac
  [ "${#1}" -le 5 ] || return 0
  [ $((10#$1)) -le "$2" ] && [ $((10#$1)) -ge "$3" ] && LIMV=$((10#$1))
  return 0
}
lim "${REFACTOR_AUTO_INTERVAL:-}" 10 0; IVL=$LIMV
lim "${REFACTOR_AUTO_WINDOW:-}" 60 0; WIN=$LIMV
lim "${REFACTOR_AUTO_DEPLOY_LIMIT:-}" 1800 1; DL=$LIMV
lim "${REFACTOR_AUTO_HTTP_LIMIT:-}" 8 1; HL=$LIMV
lim "${REFACTOR_AUTO_GH_LIMIT:-}" 15 1; GL=$LIMV
lim "${REFACTOR_AUTO_PUSH_LIMIT:-}" 60 1; PL=$LIMV
lim "${REFACTOR_AUTO_PAGE_LIMIT:-}" 15 1; PGL=$LIMV

G=(git --no-replace-objects -c core.fsmonitor=false -c merge.renormalize=false -C "$proj")
export GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 GIT_TERMINAL_PROMPT=0

TD=$(mktemp -d 2>/dev/null) || TD=$(mktemp -d -t rlauto 2>/dev/null) || TD=""
[ -n "$TD" ] || { say "⚠️ 임시 폴더를 만들지 못했습니다 — 같은 명령을 그대로 다시 실행하세요."; exit 3; }
trap 'rm -rf "$TD"' EXIT

END_PRE="   (자동 모드가 끝났습니다 — 코드·커밋은 그대로입니다. 이어 가려면 사람이 /refactor:approve 푸시 · /refactor:approve 합치기 로, 또는 고친 뒤 다시 /refactor:approve $B 자동 → /refactor:go)"
# 끝 표시(검사 C#1 — 성공한 자동 마감 끝의 헛경보 없애기): 지우기 전에 이 세션의 허락이면 .turn-autoend.<B> 를 남긴다
end_mark() { # $1 세션 $2 가지 $3 방식
  { printf '%s\n%s\n%s\n%s\n%s\n' "$B" "$(date +%s)" "$1" "$2" "$3" > "$EF.tmp.$$" && mv -f "$EF.tmp.$$" "$EF"; } 2>/dev/null || rm -f "$EF.tmp.$$"
  return 0
}
# 합치기 전 허락: 이 세션 · go= 채워짐(자동 차례가 시작됨) · 봉인된 기록의 자동 줄과 같을 때만 끝 표시
end_auto() {
  local x i=0 e1="" e2="" e3="" e4="" e5="" e11=""
  if [ -f "$AF" ]; then
    while IFS= read -r x || [ -n "$x" ]; do
      x=${x%$'\r'}; i=$((i + 1))
      case "$i" in 1) e1=$x ;; 2) e2=$x ;; 3) e3=$x ;; 4) e4=$x ;; 5) e5=$x ;; 11) e11=$x ;; esac
    done < "$AF"
    if [ "$e1" = "$B" ] && [ "$e3" = "$sid" ] && [[ $e11 =~ ^go=[0-9]{1,12}$ ]] && rl_log_intact "$dir" && rl_auto_rec "$dir" "$B" \
       && [ "$RL_AEP" = "$e2" ] && [ "$RL_ABR" = "$e4" ] && [ "$RL_AMTH" = "$e5" ]; then
      end_mark "$sid" "$e4" "$e5"
    fi
    rm -f "$AF"
  fi
  [ -e "$PF" ] && rm -f "$PF"
  return 0
}
# 합친 뒤 허락: 이 세션의 것이면 끝 표시(방식은 파일에 없음 — 셸 명령 뒤 점검의 .turn-merged 와 같게 아무거나 '*')
end_merged() {
  local x i=0 e1="" e3="" e12=""
  if [ -f "$MF" ]; then
    while IFS= read -r x || [ -n "$x" ]; do
      x=${x%$'\r'}; i=$((i + 1))
      case "$i" in 1) e1=$x ;; 3) e3=$x ;; 12) e12=$x ;; esac
    done < "$MF"
    [ "$e1" = "$B" ] && [ "$e3" = "$sid" ] && [ -n "$e12" ] && end_mark "$sid" "$e12" "*"
    rm -f "$MF"
  fi
  return 0
}
# 합치기 전 거절(허락을 지우고 1) · 다시(3) · 허락을 건드리지 않는 거절(다른 대화·순서 틀림 — 1)
no() { end_auto; say "$1"; [ -n "${2:-}" ] && say "$2"; say "$END_PRE"; exit 1; }
again() { say "$1"; [ -n "${2:-}" ] && say "$2"; say "   (자동 허락은 그대로입니다 — 같은 명령을 그대로 다시 실행하세요.)"; exit 3; }
refuse() { say "$1"; [ -n "${2:-}" ] && say "$2"; exit 1; }
# 합친 뒤 거절(.turn-merged 를 지우고 1 — 자동 모드 끝)
REVERT_WAY="   되돌리기는 사람이 합니다: ① 호스팅 화면(Vercel·Cloudflare·Railway 등)에서 이전 배포로 되돌리기(가장 빠름) ② 코드는 GitHub PR 화면의 Revert 버튼으로 되돌리는 PR 을 만들어 사람이 합칩니다(자동 되돌리기는 하지 않습니다)."
# 0.4.1 R6(N#2): 합친 뒤 자동 모드가 끝나면 사람 입력 표시(.turn-nextok)도 지운다(남으면 다음 차례에 엉뚱하게 읽힘)
nom() { end_merged; [ -e "$NX" ] && rm -f "$NX"; say "$1"; [ -n "${2:-}" ] && say "$2"; say "   (자동 모드가 끝났습니다 — 합친 것은 그대로입니다.)"; exit 1; }
clean() { local x=$1; x=${x//[[:cntrl:]]/?}; printf '%s' "${x:0:${2:-160}}"; }

# 파일 줄 → 배열 L(줄 끝 \r 뗌)
read_lines() {
  local x
  L=()
  while IFS= read -r x || [ -n "$x" ]; do L[${#L[@]}]=${x%$'\r'}; done < "$1"
}
age_ok() { # $1 만든 시각(초) $2 한도(초)
  local a
  [[ $1 =~ ^[0-9]{1,12}$ ]] || return 1
  a=$(( $(date +%s) - 10#$1 ))
  [ "$a" -ge 0 ] && [ "$a" -le "$2" ]
}

if rl_done_confirmed "$dir"; then
  refuse "⛔ 이미 마무리되어 안전장치가 꺼져 있습니다 — 자동 모드는 리팩토링 중에만 씁니다(아무것도 하지 않았습니다)."
fi

# ── 허락 검사 ───────────────────────────────────────────────────────────────
# 합치기 전: .turn-auto.<B> ①~⑪ (⑫ merge-only 는 있으면)
auto_valid() {
  local br
  [ -f "$AF" ] || refuse "⛔ $B 의 자동 허락이 없거나 끝났습니다 — 사람이 입력창에 /refactor:approve $B 자동 → /refactor:go 를 쳐야 합니다(다른 입력을 하면 자동 모드가 꺼집니다)."
  read_lines "$AF"
  [ "${L[0]:-}" = "$B" ] && [[ ${L[1]:-} =~ ^[0-9]{1,12}$ ]] || no "⛔ $B 의 자동 허락 파일 꼴이 맞지 않습니다."
  [ "${L[2]:-}" = "$sid" ] || refuse "⛔ $B 의 자동 허락은 다른 대화의 것입니다 — 자동 모드는 /refactor:approve $B 자동 을 친 그 대화에서만 돕니다(세션이 바뀌면 꺼짐 — 다시 $B 자동)."
  age_ok "${L[1]}" 7200 || no "⛔ $B 의 자동 허락이 끝났습니다(승인 뒤 2시간이 지남)."
  [[ ${L[10]:-} =~ ^go=[0-9]{1,12}$ ]] || refuse "⛔ 아직 자동 마감 차례가 아닙니다 — 사람이 인자 없는 /refactor:go 를 친 그 차례에서만 돕니다."
  br=$("${G[@]}" symbolic-ref -q --short HEAD 2>/dev/null) || br=""
  [ "$br" = "${L[3]:-}" ] || no "⛔ 지금 가지(${br:-없음})가 자동 모드를 승인한 때의 가지(${L[3]:-?})와 다릅니다."
  ABR=${L[3]}; AMTH=${L[4]:-}; ATP=${L[5]:-}; AURL=${L[6]:-}; AHOST=${L[7]:-}; AMARK=${L[8]:-}; ASCR=${L[9]:-}; AMODE=auto
  [ "${L[11]:-}" = merge-only ] && AMODE=merge-only
  case "$AMTH" in rebase|squash|merge) ;; *) no "⛔ $B 의 자동 허락에 합치는 방식이 없습니다." ;; esac
  # 사람이 B<n> 자동 을 쳤나(ⓐ — 검사 A#4): 봉인된 승인 기록의 마지막 "| 자동 | B<n> | - | <시각> <가지> <방식>" 줄이 허락 파일 ②④⑤ 와 같아야 한다
  rl_log_intact "$dir" || no "⛔ 승인 기록이 봉인과 다릅니다 — 사람이 /refactor:approve 확인 먼저"
  { rl_auto_rec "$dir" "$B" && [ "$RL_AEP" = "${L[1]}" ] && [ "$RL_ABR" = "$ABR" ] && [ "$RL_AMTH" = "$AMTH" ]; } \
    || no "⛔ $B 의 자동 허락이 승인 기록과 맞지 않습니다(기록에 사람이 친 '$B 자동' 줄이 없거나 시각·가지·방식이 다름) — 사람이 /refactor:approve $B 자동 을 다시"
  return 0
}
# preflight 가 적은 커밋(.turn-autopre ③)과 지금 커밋이 같은가(검사 A#3·C#2 — 묶음 밖 커밋 확인은 preflight 에서 하므로 그 뒤 새 커밋은 올리거나 합치지 않는다)
head_same() {
  local p1="" p2="" p3="" h
  { IFS= read -r p1; IFS= read -r p2; IFS= read -r p3; } < "$PF"
  p3=${p3%$'\r'}
  h=$("${G[@]}" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null) || h=""
  { [[ $p3 =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] && [ "$h" = "$p3" ]; } \
    || no "⛔ preflight 뒤에 새 커밋이 생겼습니다 — 묶음 밖 커밋 확인을 다시 하려면 사람이 /refactor:approve $B 자동 을 다시"
}
# 합친 뒤: .turn-merged.<B> ① B ② 합친 시각(초) ③ 세션 ④ 합친 커밋(또는 -) ⑤ 합친 시각(글) ⑥ 운영 주소 ⑦ 배포 끝 보는 법 ⑧ 판 표지
#   ⑨ 확인할 화면 ⑩ 판 표지 옛 값 ⑪ auto|merge-only ⑫ 작업 가지 ⑬ deployed=<배포 끝을 본 판 표지 값>(deploy-wait 가 더함)
merged_valid() {
  [ -f "$MF" ] || refuse "⛔ $B 의 합친 뒤 허락(.turn-merged)이 없습니다 — 자동 모드의 merge 단계가 합친 뒤에만 씁니다."
  read_lines "$MF"
  [ "${L[0]:-}" = "$B" ] && [ "${L[2]:-}" = "$sid" ] || refuse "⛔ $B 의 합친 뒤 허락이 이 대화의 것이 아닙니다."
  age_ok "${L[1]:-}" 7200 || nom "⛔ $B 를 합친 지 2시간이 지났습니다 — 배포 확인·라이브 검증은 사람이 해 주세요."
  MEP=$((10#${L[1]})); MSHA=${L[3]:-}; MURL=${L[5]:-}; MHOST=${L[6]:-}; MMARK=${L[7]:-}; MSCR=${L[8]:-}; MOLD=${L[9]:-}
  MMODE=${L[10]:-auto}; MBR=${L[11]:-}; MNEW=""; MDEP=0
  case "${L[12]:-}" in deployed=*) MDEP=1; MNEW=${L[12]#deployed=} ;; esac
  [[ $MSHA =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || MSHA=""
  return 0
}

# ── HTTP(curl) ──────────────────────────────────────────────────────────────
# http_get <주소> <받을 파일> → HC(응답 코드 · 못 받으면 000). 캐시 우회 머리(#20) · 넘겨주기 5번까지 · 한도 HL 초
http_get() {
  HC=000
  command -v curl >/dev/null 2>&1 || { HC=nocurl; return 1; }
  HC=$(curl -sS -L --max-redirs 5 --max-time "$HL" -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' -o "$2" -w '%{http_code}' "$1" 2>"$TD/curl.e") || :
  [[ $HC =~ ^[0-9]{3}$ ]] || HC=000
  [ "$HC" = 200 ]
}
bust() { printf '%s?_=%s' "$1" "$(date +%s)"; }
# 판 표지 읽기: $1 = "경로→앞 글자" · $2 = 운영 주소 → MV(값 · 못 읽으면 빈 값), MWHY(까닭)
marker_read() {
  local path=${1%%"→"*} pre=${1#*"→"} c="" rest stop=$'"\'< \t\r\n'
  MV=""; MWHY=""
  if ! http_get "$(bust "$2$path")" "$TD/m"; then MWHY="판 표지 주소($path)가 $HC"; return 1; fi
  IFS= read -r -d '' c < "$TD/m" || :
  if [ -z "$pre" ]; then
    while IFS= read -r rest || [ -n "$rest" ]; do rest=${rest%$'\r'}; [ -n "${rest//[[:space:]]/}" ] && { MV=$rest; break; }; done <<EOF
$c
EOF
    MV=${MV#"${MV%%[![:space:]]*}"}; MV=${MV%"${MV##*[![:space:]]}"}
  else
    case "$c" in *"$pre"*) rest=${c#*"$pre"}; MV=${rest%%[$stop]*} ;; *) MWHY="판 표지 주소($path)에 '$pre' 가 없음"; return 1 ;; esac
  fi
  MV=$(clean "$MV" 200)
  [ -n "$MV" ] || { MWHY="판 표지 값이 비어 있음($path)"; return 1; }
  return 0
}
# 확인할 화면 하나: $1 경로 $2 기대 글자 $3 운영 주소 → 0 이면 통과, 아니면 SWHY
screen_get() {
  SWHY=""
  case "$1" in */api/*|/api|*\?*) SWHY="$1 — 확인할 화면에 /api/ 주소·? 는 쓰지 않습니다(PROFILE.md 오류)"; return 1 ;; esac
  if ! http_get "$(bust "$3$1")" "$TD/s"; then SWHY="$1 — 응답 $HC"; return 1; fi
  grep -qF -- "$2" "$TD/s" || { SWHY="$1 — 기대 글자 '$(clean "$2" 60)' 가 없음"; return 1; }
  return 0
}

# ── 묶음 승인 기록 → BIDS(그 묶음의 카드 ID — 승인 기록 정본, 마지막 '재설정' 뒤) ─────────────
#   BFOUND = 그 줄이 있음(카드 0개 — 묶음 카드가 모두 이미 완료라 자동 마감만 켠 승인 — 도 있음) · PIDS = 계획서에서 묶음 칸이 그 B 인 모든 카드(완료 포함 — 검사 C#4:
#   진행 중 계획서에서 앞서 끝낸 그 묶음 카드의 커밋이 아직 안 합쳐져 가지에 있을 수 있다) · UIDS = PIDS 중 봉인된 기록에서 승인됐던 카드(그 B 의 "묶음 승인" 줄에
#   들었거나 "| 승인 | <ID> |" 줄이 있음 — 재검사 A2#4: 계획서의 묶음 칸만 바꾼 카드·새로 더한 카드는 묶음 밖) + BIDS. 묶음 밖 커밋 판정과 PR 본문은 UIDS 로
bundle_ids() {
  local x a b v k_ n_ id_ b_ rest_ aids=""
  BIDS=""; BFOUND=0; UIDS=""; PIDS=""
  [ -f "$log" ] || return 0
  while IFS= read -r x || [ -n "$x" ]; do
    x=${x%$'\r'}
    case "$x" in *" KST | 재설정 |"*) BIDS=""; BFOUND=0; aids=""; continue ;; esac
    case "$x" in *" KST | 보류 | "*) v=${x#*" KST | 보류 | "}; v=${v%% |*}; aids=${aids// $v / }; continue ;; esac
    case "$x" in *" KST | 승인 | "*) v=${x#*" KST | 승인 | "}; aids="$aids ${v%% |*} "; continue ;; esac
    case "$x" in *" KST | 묶음 승인 | $B | - | 카드 "*) v=${x#*" | 묶음 승인 | $B | - | 카드 "}; aids="$aids ${v#*개:} " ;; esac
    case "$x" in *" KST | 묶음 승인 | $B | - | 카드 "*) ;; *" KST | 묶음 보류 | $B | "*) BIDS=""; BFOUND=0; aids=""; continue ;; *) continue ;; esac
    v=${x#*" | 묶음 승인 | $B | - | 카드 "}; v=${v#*개:}
    BIDS=$v; BFOUND=1
  done < "$log"
  a=""; for b in $BIDS; do a="$a $b"; done; BIDS=${a# }
  a=""
  while IFS="$US" read -r k_ n_ id_ b_ rest_; do
    [ "$k_" = CB ] && [ "$b_" = "$B" ] && [ -n "$id_" ] || continue
    case " $a " in *" $id_ "*) ;; *) a="$a $id_" ;; esac
  done <<EOF
$(rl_card_bundles "$dir/REFACTOR_PLAN.md")
EOF
  PIDS=${a# }; a=""
  for b in $PIDS; do case "$aids" in *" $b "*) a="$a $b" ;; esac; done
  for b in $BIDS; do case " $a " in *" $b "*) ;; *) a="$a $b" ;; esac; done
  UIDS=${a# }
}

# ═════════════════════════════════════════════════════════════════════════════
case "$st" in
# ── 0. preflight: 기준선 통과 · 묶음 밖 커밋 없음 · 운영 주소 200 · 판 표지 옛 값 · 확인할 화면(옛 판) ──
preflight)
  auto_valid
  rl_log_intact "$dir" || no "⛔ 승인 기록이 봉인과 다릅니다 — 사람이 /refactor:approve 확인 먼저"
  bundle_ids
  [ "$BFOUND" = 1 ] || no "⛔ 승인 기록에 $B 의 묶음 승인 줄이 없습니다"
  # 묶음 카드가 모두 끝났나(계획서 완료 칸 — 승인 기록의 그 묶음 카드 목록 기준)
  left=""; last=""
  recs=$(rl_cards "$dir/REFACTOR_PLAN.md" "$log" 2>/dev/null)
  for x in $BIDS; do
    last=$x; d_=""
    while IFS="$US" read -r k_ n_ id_ t_ bx_ dn_ rest_; do [ "$k_" = CARD ] && [ "$id_" = "$x" ] && { d_=$dn_; break; }; done <<EOF
$recs
EOF
    [ "$d_" = 1 ] || left="$left $x"
  done
  [ -z "$left" ] || no "⛔ $B 묶음에 아직 안 끝난 카드가 있습니다:$left — 묶음 카드가 모두 끝나야 자동 마감을 합니다"
  # 승인 때 카드 0개(모두 이미 완료 — 자동 마감만 켬)면 기준선 결과는 계획서의 그 묶음 마지막 카드로
  if [ -z "$last" ]; then for x in $PIDS; do last=$x; done; fi
  [ -n "$last" ] || no "⛔ 계획서에 $B 묶음 카드가 없습니다"
  # 기준선 통과(#6): 묶음 마지막 카드의 EXECUTION_LOG "- 기준선 결과: <ID> 통과 N/N"(N > 0, 같은 수) — 사장님 결정 10-05: STATE red_open(프로젝트 전체의
  #   안 막은 🔴 수)은 보지 않는다(다른 묶음의 🔴 가 이 묶음 자동 마감을 막지 않게 · 이 묶음 카드가 다 끝났는지는 위에서 봄)
  bok=0
  if [ -f "$dir/EXECUTION_LOG.md" ]; then
    re_bl="^- 기준선 결과: $last 통과 ([0-9]+)/([0-9]+)[[:space:]]*\$"
    while IFS= read -r x || [ -n "$x" ]; do
      x=${x%$'\r'}
      [[ $x =~ $re_bl ]] && [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ] && [ $((10#${BASH_REMATCH[2]})) -gt 0 ] && bok=1
    done < "$dir/EXECUTION_LOG.md"
  fi
  [ "$bok" = 1 ] || no "⛔ 기준선 통과를 확인하지 못했습니다: EXECUTION_LOG.md 에 묶음 마지막 카드($last)의 '- 기준선 결과: $last 통과 N/N' 줄이 없습니다"
  # 묶음 밖 커밋(#5): origin/<기본>..<지금 커밋> 의 제목이 전부 "refactor: <묶음 카드 ID> …"(완료 카드 포함 — UIDS) 또는 기준선 커밋 꼴.
  #   지금 커밋을 먼저 읽어 그 커밋까지만 보고 .turn-autopre ③ 에 적는다(push·merge 는 이 커밋일 때만 — 검사 A#3·C#2)
  rl_origin_base "$proj" || no "❓ origin 의 기본 가지를 찾지 못했습니다(origin/HEAD·origin/main·origin/master 참조 없음)"
  hoid=$("${G[@]}" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null) || hoid=""
  [[ $hoid =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || no "⛔ 지금 커밋을 읽지 못했습니다"
  subs=$("${G[@]}" log --format='%H %s' "$RL_BOID..$hoid" 2>/dev/null) || no "⛔ 커밋 목록을 읽지 못했습니다"
  [ -n "$subs" ] || no "⛔ origin/$RL_BNAME 위에 올릴 커밋이 없습니다"
  # 기준선 커밋 꼴(검사 C#9): 제목이 "test: 기준선" 으로 시작하고, 바꾼 파일(하나 이상)이 tests/baseline/ 아래와 기록 폴더 docs/refactor/ 아래뿐
  #   (5-baseline 이 기록 파일을 같은 커밋에 싣는다 · 합치기 커밋은 파일 목록이 비어 거절 · 이름만 같은 커밋은 거절)
  #   재검사 A2#6: tests/baseline/ 아래 파일이 하나 이상 있어야 한다(docs/refactor 만 바꾼 'test: 기준선 …' 은 묶음 밖)
  #   0.4.1 R5(A2#6 나머지): docs/refactor 아래는 기록 파일 꼴만 — *.md(하위 폴더 포함) · *.log · approved/.log-sum · approved/.log-copy(봉인) ·
  #   바로 아래 .gitattributes · .gitignore. 그 밖(run.js·*.sh·*.json 등)이 들면 묶음 밖
  base_only() {
    local fl f n=0
    fl=$("${G[@]}" diff-tree --no-commit-id --name-only --no-renames -r --root "$1" 2>/dev/null) || return 1
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      case "$f" in
        tests/baseline/*) n=$((n + 1)) ;;
        docs/refactor/*.md|docs/refactor/*.log|docs/refactor/approved/.log-sum|docs/refactor/approved/.log-copy|docs/refactor/.gitattributes|docs/refactor/.gitignore) ;;
        *) return 1 ;;
      esac
    done <<EOF
$fl
EOF
    [ "$n" -gt 0 ]
  }
  outside=""; on=0
  while IFS= read -r x; do
    [ -n "$x" ] || continue
    c_=${x%% *}; x=${x#"$c_"}; x=${x# }
    ok=0
    case "$x" in "test: 기준선"*) base_only "$c_" && ok=1 ;; "refactor: "*) i=${x#refactor: }; i=${i%% *}; case " $UIDS " in *" $i "*) [ "$i" != "${x#refactor: }" ] && ok=1 ;; esac ;; esac
    if [ "$ok" = 0 ]; then on=$((on + 1)); [ "$on" -le 3 ] && outside="$outside · $(clean "$x" 60)"; fi
  done <<EOF
$subs
EOF
  [ "$on" = 0 ] || no "⛔ 묶음 밖 커밋이 ${on}개 있습니다(${outside# · }) — $B 카드(${UIDS})의 'refactor: <ID> …' 커밋과 기준선 커밋(tests/baseline 파일이 들고 tests/baseline·docs/refactor 만 바꾼 'test: 기준선 …')만 자동으로 올립니다"
  # 운영 주소 200 · 판 표지 옛 값 · 확인할 화면(옛 판)
  http_get "$(bust "$AURL/")" "$TD/u" || no "⛔ 운영 주소($AURL)가 지금 $HC 입니다 — 자동 시작 전 멈춤(코드는 그대로)"
  old=""
  if [ -n "$AMARK" ]; then
    marker_read "$AMARK" "$AURL" || no "⛔ 판 표지를 읽지 못했습니다: $MWHY — PROFILE.md 의 판 표지 칸을 확인해 주세요"
    old=$MV
  fi
  sn=0; rest=$ASCR
  while [ -n "$rest" ]; do
    one=${rest%%;*}; [ "$one" = "$rest" ] && rest="" || rest=${rest#*;}
    [ -n "$one" ] || continue
    screen_get "${one%%"→"*}" "${one#*"→"}" "$AURL" || no "⛔ 확인할 화면(옛 판): $SWHY — 자동 시작 전 멈춤(PROFILE.md 의 확인할 화면은 옛 판·새 판 모두에 나오는 글자로)"
    sn=$((sn + 1))
  done
  { printf '%s\n%s\n%s\n' "$(date +%s)" "$old" "$hoid" > "$PF.tmp.$$" && mv -f "$PF.tmp.$$" "$PF"; } 2>/dev/null || { rm -f "$PF.tmp.$$"; again "⚠️ 판 표지 옛 값을 적지 못했습니다"; }
  say "✅ 자동 마감 시작 전 확인 끝($B): 카드$(for x in ${BIDS:-$UIDS}; do printf ' %s' "$x"; done) 모두 완료 · 기준선 통과 · 묶음 밖 커밋 없음 · 운영 주소 200 · 확인할 화면 ${sn}개$([ -n "$old" ] && printf ' · 판 표지 지금 값 %s' "$old")"
  say "   올릴 커밋: ${hoid:0:12} — 이 뒤에 커밋을 더하면 push·merge 가 멈춥니다(묶음 밖 커밋 확인은 여기서만 함)"
  [ "$AMODE" = merge-only ] && say "   배포 방식이 '수동'이라 합치기까지만 합니다."
  say "다음: refactor-auto push"
  exit 0 ;;

# ── 1. push: 0.3.3 푸시 거절 조건 그대로 + git push -u origin <승인 때 가지> ─────────────────
push)
  auto_valid
  [ -f "$PF" ] || refuse "⛔ 먼저 preflight 를 실행해야 합니다(7-execute 「8. 자동 마감」 순서)."
  head_same
  rl_log_intact "$dir" || no "⛔ 승인 기록이 봉인과 다릅니다 — 사람이 /refactor:approve 확인 먼저"
  [[ $ABR =~ ^[A-Za-z0-9._/-]+$ ]] && [[ $ABR =~ ^[A-Za-z0-9_] ]] || no "⛔ 가지 이름($ABR)을 올릴 수 없습니다"
  case "$ABR" in main|master) no "⛔ 기본 가지는 올리지 않습니다" ;; esac
  ob=$("${G[@]}" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)
  [ -n "$ob" ] && [ "${ob#origin/}" = "$ABR" ] && no "⛔ 기본 가지는 올리지 않습니다"
  pc=$("${G[@]}" config --get-regexp '^(remote[.]origin[.](url|push)|push[.]default)$' 2>/dev/null)
  pwhy=""; has_url=0
  while IFS= read -r x; do
    k=${x%% *}; v=${x#"$k"}; v=${v# }
    case "$k" in
      remote.origin.url) has_url=1 ;;
      remote.origin.push) pwhy="원격에 올리기 규칙(remote.origin.push)이 설정돼 있음" ;;
      push.default) case "$(printf '%s' "$v" | tr 'A-Z' 'a-z')" in upstream|tracking) pwhy="push.default 가 $v 임" ;; esac ;;
    esac
  done <<EOF
$pc
EOF
  [ -z "$pwhy" ] && [ "$has_url" = 0 ] && pwhy="origin 원격 주소가 없음"
  [ -z "$pwhy" ] || no "⛔ 자동으로 올릴 수 없는 저장소 설정입니다($pwhy) — 사람이 터미널에서 올립니다"
  rl_bounded "$PL" "${G[@]}" push -u origin "$ABR" >"$TD/o" 2>"$TD/e"; prc=$?
  if [ "$prc" != 0 ]; then
    [ "$prc" = 124 ] && again "⚠️ 올리기가 ${PL}초 안에 끝나지 않았습니다"
    e1=""; while IFS= read -r x; do [ -n "${x//[[:space:]]/}" ] && { e1=$(clean "$x" 200); break; }; done < "$TD/e"
    el=$(printf '%s' "$e1" | tr 'A-Z' 'a-z')
    case "$el" in
      *"could not resolve host"*|*"timed out"*|*"connection reset"*|*"unable to access"*|*"temporarily"*) again "⚠️ 올리지 못했습니다: $e1" ;;
    esac
    no "⛔ 올리지 못했습니다: ${e1:-(오류 문구 없음)}" "   (거절·권한·인증 오류는 다시 해도 같습니다 — 사람이 확인해 주세요)"
  fi
  # 보안 검사(10-05): 올리는 동안(네트워크) 기록에 다른 줄이 끼었으면 봉인에 싣지 않는다 — 덧붙이기 직전에 다시 대조
  rl_log_intact "$dir" || no "⛔ 승인 기록이 봉인과 다릅니다(올리는 동안 바뀜) — 사람이 /refactor:approve 확인 먼저"
  { printf '%s KST | 푸시 | %s | - | 자동 %s 으로 실행\n' "$(rl_now)" "$ABR" "$B" >> "$log"; } 2>/dev/null && rl_log_seal "$dir"
  say "✅ 올렸습니다: $ABR → origin (자동 $B)"
  say "다음: refactor-auto pr"
  exit 0 ;;

# ── 2. pr: 열린 PR 재사용, 없으면 gh pr create ─────────────────────────────
pr)
  auto_valid
  [ -f "$PF" ] || refuse "⛔ 먼저 preflight 를 실행해야 합니다(7-execute 「8. 자동 마감」 순서)."
  command -v gh >/dev/null 2>&1 || no "❓ gh(GitHub CLI)를 찾지 못했습니다"
  rl_origin_base "$proj" || no "❓ origin 의 기본 가지를 찾지 못했습니다"
  bname=$RL_BNAME
  (cd "$proj" && rl_bounded "$GL" gh pr list --head "$ABR" --state open --json number,isCrossRepository,baseRefName \
     --jq '.[] | "\(.number) \(.isCrossRepository) \(.baseRefName)"') >"$TD/o" 2>"$TD/e"; lrc=$?
  if [ "$lrc" != 0 ]; then
    e1=$(clean "$(head -n 1 "$TD/e" 2>/dev/null)" 200)
    again "⚠️ PR 목록을 읽지 못했습니다: ${e1:-응답 없음(${lrc})}"
  fi
  read -r pn pfk pbase < "$TD/o" || :
  if [[ ${pn:-} =~ ^[0-9]+$ ]]; then
    [ "$pfk" = false ] || no "⛔ PR #$pn 은 포크의 PR 입니다 — 사람이 GitHub 화면에서 합쳐 주세요"
    [ "$pbase" = "$bname" ] || no "⛔ PR #$pn 은 기본 가지($bname)로 가는 PR 이 아닙니다(받는 가지: $(clean "$pbase" 60))"
    say "✅ 열린 PR #$pn 을 씁니다($ABR → $bname)"
    say "다음: refactor-auto merge"
    exit 0
  fi
  # 제목 = "B1 <묶음 설명>" · 본문 = 카드 목록·커밋·되돌리는 법
  bundle_ids
  desc=""
  while IFS="$US" read -r k_ n_ id_ b_ d_ rest_; do [ "$k_" = CB ] && [ "$b_" = "$B" ] && [ -n "$d_" ] && { desc=$d_; break; }; done <<EOF
$(rl_card_bundles "$dir/REFACTOR_PLAN.md")
EOF
  title="$B${desc:+ $(clean "$desc" 80)}"
  {
    printf '%s\n\n' "자동 모드(/refactor:approve $B 자동)로 만든 PR 입니다 — 검사가 모두 초록이면 Claude 가 플러그인 합치기 스크립트로 합칩니다."
    printf '## 카드\n'
    recs=$(rl_cards "$dir/REFACTOR_PLAN.md" "$log" 2>/dev/null)
    for x in $UIDS; do
      t=""
      while IFS="$US" read -r k_ n_ id_ t_ rest_; do [ "$k_" = CARD ] && [ "$id_" = "$x" ] && { t=$t_; break; }; done <<EOF
$recs
EOF
      printf -- '- %s %s\n' "$x" "$(clean "$t" 100)"
    done
    printf '\n## 커밋\n'
    "${G[@]}" log --format='- %h %s' "$RL_BOID..HEAD" 2>/dev/null | head -n 30
    printf '\n## 되돌리는 법(사람)\n- 배포가 깨지면: 호스팅 화면에서 이전 배포로 되돌리기(가장 빠름)\n- 코드를 되돌리려면: 이 PR 화면의 Revert 버튼 → 되돌리는 PR 을 사람이 합칩니다\n'
  } > "$TD/body" 2>/dev/null
  (cd "$proj" && rl_bounded "$GL" gh pr create --base "$bname" --head "$ABR" --title "$title" --body-file "$TD/body") >"$TD/o" 2>"$TD/e"; crc=$?
  if [ "$crc" != 0 ]; then
    [ "$crc" = 124 ] && again "⚠️ PR 만들기가 ${GL}초 안에 끝나지 않았습니다(만들어졌으면 다음 실행이 그 PR 을 씁니다)"
    e1=$(clean "$(head -n 1 "$TD/e" 2>/dev/null)" 200)
    case "$(printf '%s' "$e1" | tr 'A-Z' 'a-z')" in
      *"already exists"*|*"could not resolve host"*|*"timed out"*|*"rate limit"*) again "⚠️ PR 을 만들지 못했습니다: $e1" ;;
    esac
    no "⛔ PR 을 만들지 못했습니다: ${e1:-(오류 문구 없음)}"
  fi
  url=$(grep -o 'https://[^[:space:]]*/pull/[0-9][0-9]*' "$TD/o" | head -n 1)
  pn=${url##*/}
  say "✅ PR 을 만들었습니다${pn:+: #$pn}($ABR → $bname · 제목 \"$title\")"
  say "다음: refactor-auto merge"
  exit 0 ;;

# ── 3. merge: 합치기 허락 파일(.turn-merge.<세션>)·대화 기록 경로 파일을 한 번만 만들고 합치기 스크립트를 그대로 부른다 ──
merge)
  auto_valid
  [ -f "$PF" ] || refuse "⛔ 먼저 preflight 를 실행해야 합니다(7-execute 「8. 자동 마감」 순서)."
  head_same
  rl_log_intact "$dir" || no "⛔ 승인 기록이 봉인과 다릅니다 — 사람이 /refactor:approve 확인 먼저"
  mf="$dir/.turn-merge.$sid"; mtp="$dir/.turn-mergetp.$sid"
  MNOTE=""
  if [ ! -f "$mf" ]; then
    # 처음 한 번만(다시(3) 뒤에는 남아 있는 허락을 그대로 쓴다 — 거절(1) 뒤에는 자동 허락이 지워져 여기 오지 않는다 · C 메모)
    # 판 표지 옛 값을 합치기 직전 값으로 고친다(검사 C#3 — preflight 뒤 앞선 배포가 끝나 표지가 바뀌었으면 합친 뒤 "바뀜"을 새 배포로 잘못 봄).
    #   읽지 못하면 preflight 값 그대로 + 결과에 한 줄
    if [ -n "$AMARK" ]; then
      if marker_read "$AMARK" "$AURL"; then
        p1=""; p2=""; p3=""; { IFS= read -r p1; IFS= read -r p2; IFS= read -r p3; } < "$PF"
        { printf '%s\n%s\n%s\n' "${p1%$'\r'}" "$MV" "${p3%$'\r'}" > "$PF.tmp.$$" && mv -f "$PF.tmp.$$" "$PF"; } 2>/dev/null \
          || { rm -f "$PF.tmp.$$"; MNOTE="   ⚠️ 판 표지 옛 값을 합치기 직전 값으로 고치지 못해 preflight 때 값을 씁니다"; }
      else
        MNOTE="   ⚠️ 합치기 직전에 판 표지를 다시 읽지 못해 preflight 때 값을 씁니다($MWHY)"
      fi
    fi
    hoid=$("${G[@]}" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null) || hoid=""
    [[ $hoid =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || no "⛔ 지금 커밋을 읽지 못했습니다"
    mroot=${root//"\\"//}; mroot=${mroot%/}
    case "$mroot$RL_TAB$proj" in *'"'*|*'$'*|*'`'*|*'\'*|*"$NL"*|*$'\r'*) no "⛔ 플러그인·프로젝트 폴더 경로에 특수 글자가 있어 합치기 허락을 만들 수 없습니다" ;; esac
    if [ -d "$mf" ] || ! { printf 'merge %s - %s %s\n%s\n%s\n' "$ABR" "$AMTH" "$hoid" "$(date +%s)" "bash \"$mroot/hooks/run.sh\" refactor-merge \"$proj\" $sid" > "$mf.tmp.$$" && mv -f "$mf.tmp.$$" "$mf"; }; then
      rm -f "$mf.tmp.$$"; again "⚠️ 합치기 허락 파일을 쓰지 못했습니다"
    fi
    rl_log_intact "$dir" || { rm -f "$mf"; no "⛔ 승인 기록이 봉인과 다릅니다 — 사람이 /refactor:approve 확인 먼저"; }
    if ! { printf '%s KST | 합치기 | 허락 %s PR(지금 가지) (%s) @%s | - | 자동 %s 으로 실행\n' "$(rl_now)" "$ABR" "$AMTH" "${hoid:0:7}" "$B" >> "$log"; } 2>/dev/null; then
      rm -f "$mf"; again "⚠️ 승인 기록을 쓰지 못했습니다"
    fi
    rl_log_seal "$dir"
    # 입력 감시 경로 파일(0.3.7 과 같은 3줄 — 경로 = 자동 허락 ⑥, 크기·시각 = 지금)
    rl_mergetp_write "$mtp" "$ATP"
    # 판 표지 읽기가 늦었으면 합치기 스크립트(한 호출 최악 약 110초)는 다음 실행에서(Bash 도구 한도 120초 안 — 허락은 만들어 둠)
    [ $((SECONDS - t0)) -gt 5 ] && again "⏳ 판 표지를 다시 읽느라 늦어 합치기 확인은 다음 실행에서 합니다(합치기 허락은 만들었습니다)" "$MNOTE"
  fi
  # 0.4.1 R7: 합치기 스크립트는 합치기 직전에 입력 감시 경로 파일(.turn-mergetp)을 지운다 → 그 세 줄을 먼저 읽어 두었다가 합친 뒤 표시 ④⑤⑥ 에 싣는다
  tq1=""; tq2=""; tq3=""
  [ -f "$mtp" ] && { IFS= read -r tq1; IFS= read -r tq2; IFS= read -r tq3; } < "$mtp"
  tq1=${tq1%$'\r'}; tq2=${tq2%$'\r'}; tq3=${tq3%$'\r'}
  bash "$root/hooks/run.sh" refactor-merge "$proj" "$sid" >"$TD/mo" 2>&1; mrc=$?
  mout=$(< "$TD/mo")
  case "$mrc" in
    0)
      case "$mout" in *"✅ 합쳤습니다"*|*"이미 합쳐져 있습니다"*) ;; *)
        end_auto; say "⛔ 합치지 않았습니다(자동 $B) — 합치기 스크립트 결과:"; [ -n "$MNOTE" ] && say "$MNOTE"; printf '%s\n' "$mout"; say "$END_PRE"; exit 1 ;;
      esac
      msha=""
      while IFS= read -r x; do case "$x" in "   합친 커밋: "*) msha=${x#"   합친 커밋: "} ;; esac; done <<EOF
$mout
EOF
      [[ $msha =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || msha="-"
      old=""; [ -f "$PF" ] && { IFS= read -r x; IFS= read -r old; } < "$PF"; old=${old%$'\r'}
      if ! { printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "$B" "$(date +%s)" "$sid" "$msha" "$(rl_now)" "$AURL" "$AHOST" "$AMARK" "$ASCR" "$old" "$AMODE" "$ABR" > "$MF.tmp.$$" && mv -f "$MF.tmp.$$" "$MF"; } 2>/dev/null; then
        rm -f "$MF.tmp.$$"
      fi
      # 0.4.0 사람 입력 표시(.turn-nextok.<B> — ① B ② 시각 ③ 세션): 합친 뒤 사람 입력이 없었는지 verify 가 새 가지를 만들기 전에 본다
      #   (입력 훅이 사람 입력마다 지움 · verify 가 끝에 지움). merge-only 는 사람이 "검증해" 라고 입력해야 verify 가 돌므로 쓰지 않는다
      if [ "$AMODE" != merge-only ] && [ -f "$MF" ]; then
        { printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$B" "$(date +%s)" "$sid" "$tq1" "$tq2" "$tq3" > "$NX.tmp.$$" && mv -f "$NX.tmp.$$" "$NX"; } 2>/dev/null || rm -f "$NX.tmp.$$"
      fi
      end_auto
      say "✅ 합쳤습니다(자동 $B) — 합친 커밋 ${msha:0:12}"
      [ -n "$MNOTE" ] && say "$MNOTE"
      printf '%s\n' "$mout"
      if [ "$AMODE" = merge-only ]; then
        say "✅ 여기까지 — 배포는 사람이 → 끝나면 Claude 에게 검증 부탁(그때 refactor-auto verify)"
      elif [ -f "$MF" ]; then
        say "다음: refactor-auto deploy-wait"
      else
        say "⚠️ 합친 뒤 허락(.turn-merged)을 쓰지 못해 배포 확인·라이브 검증을 자동으로 이어 가지 못합니다 — 사람이 확인해 주세요."
      fi
      exit 0 ;;
    3)
      say "⏳ 아직 합치지 않았습니다(자동 $B) — 합치기 스크립트 결과:"
      [ -n "$MNOTE" ] && say "$MNOTE"
      printf '%s\n' "$mout"
      say "   (자동 허락은 그대로입니다 — 같은 명령을 그대로 다시 실행하세요.)"
      exit 3 ;;
    *)
      end_auto
      say "⛔ 합치지 못했습니다(자동 $B) — 합치기 스크립트 결과:"
      [ -n "$MNOTE" ] && say "$MNOTE"
      printf '%s\n' "$mout"
      say "$END_PRE"
      exit 1 ;;
  esac ;;

# ── 4. deploy-wait: 호스팅별 읽기 + 판 표지가 옛 값에서 바뀜(+ sha 일치) — 호출 ≤60초 · 합친 뒤 30분까지 ──
deploy-wait)
  merged_valid
  [ "$MDEP" = 1 ] && { say "✅ 배포 끝은 이미 확인했습니다(판 표지 ${MNEW:-없음})"; say "다음: refactor-auto verify"; exit 0; }
  case "$MHOST" in vercel|github|railway|cloudflare|netlify|marker) ;; *)
    [ -n "$MMARK" ] || nom "⛔ 배포가 끝났는지 볼 방법이 없습니다(PROFILE 의 배포 끝 보는 법·판 표지 없음) — 사람이 배포를 확인한 뒤 Claude 에게 검증을 부탁하세요"
    MHOST=marker ;;
  esac
  # 한 호출 60초 안(§2-2 4): gh·vercel 한 번 10초까지 · 한 바퀴 최악(WI) = 호스팅 읽기 + 판 표지 읽기 — 다음 바퀴는 지금 + 간격 + WI 가 WIN 안일 때만
  [ "$GL" -gt 10 ] && GL=10
  case "$MHOST" in vercel) WI=$((GL + 1)) ;; github) WI=$((3 * (GL + 1))) ;; *) WI=0 ;; esac
  [ -n "$MMARK" ] && WI=$((WI + HL + 1))
  ago=$(( $(date +%s) - MEP ))
  [ "$ago" -le "$DL" ] || nom "⚠️ 합친 뒤 $((DL / 60))분이 지나도 배포가 끝나지 않았습니다 — 호스팅 화면에서 사람이 확인해 주세요" "$REVERT_WAY"
  # 합친 커밋을 모르면(합치기 결과에 줄이 없었음) 한 번 물어본다(vercel·github 만 필요)
  if [ -z "$MSHA" ] && [ -n "$MBR" ] && { [ "$MHOST" = vercel ] || [ "$MHOST" = github ]; } && command -v gh >/dev/null 2>&1; then
    (cd "$proj" && rl_bounded "$GL" gh pr list --head "$MBR" --state merged --json mergeCommit --jq '.[0].mergeCommit.oid // ""') >"$TD/o" 2>/dev/null && read -r x < "$TD/o"
    if [[ ${x:-} =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]; then
      MSHA=$x
      read_lines "$MF"; L[3]=$MSHA
      { for x in "${L[@]}"; do printf '%s\n' "$x"; done > "$MF.tmp.$$" && mv -f "$MF.tmp.$$" "$MF"; } 2>/dev/null || rm -f "$MF.tmp.$$"
    fi
  fi
  [ -n "$MMARK" ] || [ -n "$MSHA" ] || nom "⛔ 합친 커밋을 몰라 배포 끝을 볼 수 없고 판 표지도 없습니다 — 사람이 배포를 확인한 뒤 Claude 에게 검증을 부탁하세요"
  # 0.4.2 F6: GitHub 환경 이름을 주소에 넣을 때 — 영문·숫자·-._~ 밖은 바이트마다 %XX(공백·/·&·?·#·%·+ 포함 · LC_ALL=C 라 한 글자 = 한 바이트) → UE
  urlenc() {
    local s=$1 i c
    UE=""
    for ((i = 0; i < ${#s}; i++)); do
      c=${s:i:1}
      case "$c" in [A-Za-z0-9._~-]) UE=$UE$c ;; *) printf -v c '%%%02X' "'$c"; UE=$UE$c ;; esac
    done
  }
  # host_state → HS: ready / wait / none(호스팅으로는 못 가림 — 판 표지만) / fail / over
  #   github(0.4.2 F6 — 잔치 신고 S8): 조회 결과는 탭으로 나눈다(환경 이름에 띄어쓰기·빗금이 있어도 칸이 밀리지 않게) · 환경 조회는 이름을 URL 인코딩 ·
  #   같은 환경의 최신 배포가 없으면(빈 배열 → 빈 출력) over 아님 · 시각 비교는 둘 다 ISO 시각(20YY-MM-DDT…)일 때만
  host_state() {
    local o did denv dat s2 at2 st_ re_iso='^20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T'
    HS=none; HWHY=""
    case "$MHOST" in
      vercel)
        [ -n "$MSHA" ] || return 0
        command -v vercel >/dev/null 2>&1 || { HWHY="vercel CLI 없음"; return 0; }
        (cd "$proj" && rl_bounded "$GL" vercel ls -m "githubCommitSha=$MSHA" --prod --status READY) >"$TD/v" 2>&1
        if grep -Eq 'https://[^[:space:]]+\.vercel\.app' "$TD/v"; then HS=ready; else HS=wait; fi ;;
      github)
        [ -n "$MSHA" ] || return 0
        command -v gh >/dev/null 2>&1 || { HWHY="gh 없음"; return 0; }
        (cd "$proj" && rl_bounded "$GL" gh api "repos/{owner}/{repo}/deployments?sha=$MSHA&per_page=5" --jq '.[0] // empty | "\(.id)\t\(.environment)\t\(.created_at)"') >"$TD/g" 2>/dev/null || { HS=wait; return 0; }
        IFS=$'\t' read -r did denv dat < "$TD/g" || :
        [[ ${did:-} =~ ^[0-9]+$ ]] || { HS=wait; return 0; }
        (cd "$proj" && rl_bounded "$GL" gh api "repos/{owner}/{repo}/deployments/$did/statuses?per_page=1" --jq '.[0].state // "-"') >"$TD/g" 2>/dev/null || { HS=wait; return 0; }
        read -r st_ < "$TD/g" || :
        case "${st_:-}" in
          success)
            HS=ready
            urlenc "${denv:-}"
            (cd "$proj" && rl_bounded "$GL" gh api "repos/{owner}/{repo}/deployments?environment=$UE&per_page=1" --jq '.[0] // empty | "\(.sha)\t\(.created_at)"') >"$TD/g" 2>/dev/null \
              && IFS=$'\t' read -r s2 at2 < "$TD/g" && [ -n "${s2:-}" ] && [ "$s2" != null ] && [ "$s2" != "$MSHA" ] \
              && [[ ${at2:-} =~ $re_iso ]] && [[ ${dat:-} =~ $re_iso ]] && [[ "$at2" > "$dat" ]] && { HS=over; HWHY="더 새 커밋 ${s2:0:7} 의 배포가 뒤에 올라옴"; } ;;
          failure|error) HS=fail; HWHY="GitHub 배포 상태 $st_" ;;
          inactive) HS=over; HWHY="이 배포가 다른 배포로 바뀜(inactive)" ;;
          *) HS=wait ;;
        esac ;;
    esac
    return 0
  }
  while :; do
    host_state
    [ "$HS" = fail ] && nom "⛔ 배포가 실패했습니다($HWHY) — 운영은 옛 판 그대로일 수 있습니다" "$REVERT_WAY"
    [ "$HS" = over ] && nom "⚠️ 다른 배포가 덮었습니다($HWHY) — 라이브 검증을 하지 않고 멈춥니다(사람이 확인해 주세요)"
    mok=1; MV=""
    if [ -n "$MMARK" ]; then
      mok=0
      if marker_read "$MMARK" "$MURL" && [ "$MV" != "$MOLD" ]; then
        mok=1
        # 판 표지에 커밋 같은 16진 글자(7자 이상·영문 포함)가 있고 합친 커밋과 다르면 다른 배포가 덮은 것
        if [ -n "$MSHA" ]; then
          hx=$(printf '%s' "$MV" | grep -oE '[0-9a-f]{7,40}' | grep '[a-f]' | head -n 1)
          [ -n "$hx" ] && case "$MSHA" in "$hx"*) ;; *) nom "⚠️ 다른 배포가 덮었습니다(판 표지 $MV — 합친 커밋 ${MSHA:0:7} 이 아님) — 라이브 검증을 하지 않고 멈춥니다" ;; esac
        fi
      fi
    fi
    if [ "$HS" = none ] && [ -z "$MMARK" ]; then
      nom "⛔ 배포가 끝났는지 볼 방법이 없습니다(${HWHY:-호스팅 읽기 불가} · 판 표지 없음) — 사람이 배포를 확인한 뒤 Claude 에게 검증을 부탁하세요"
    fi
    if [ "$mok" = 1 ] && { [ "$HS" = ready ] || [ "$HS" = none ]; }; then
      { cat "$MF" && printf 'deployed=%s\n' "$MV"; } > "$MF.tmp.$$" 2>/dev/null && mv -f "$MF.tmp.$$" "$MF" || { rm -f "$MF.tmp.$$"; again "⚠️ 배포 확인 결과를 적지 못했습니다"; }
      say "✅ 배포가 끝났습니다($B · $MHOST$([ -n "$MSHA" ] && printf ' · 커밋 %s' "${MSHA:0:7}")$([ -n "$MMARK" ] && printf ' · 판 표지 %s → %s' "${MOLD:-?}" "$MV"))"
      say "다음: refactor-auto verify"
      exit 0
    fi
    [ $((SECONDS - t0 + IVL + WI)) -le "$WIN" ] && [ "$WIN" -gt 0 ] || again "⏳ 배포가 아직 끝나지 않았습니다(합친 지 $(( ($(date +%s) - MEP) / 60 ))분 · $((DL / 60))분까지 기다림$([ "$HS" = wait ] && printf ' · %s 아직' "$MHOST")$([ -n "$MMARK" ] && [ "$mok" = 0 ] && printf ' · 판 표지 그대로'))"
    [ "$IVL" -gt 0 ] && sleep "$IVL"
  done ;;

# ── 5. verify: 운영 주소 200 · 판 표지 일치 · 확인할 화면 GET(캐시 우회) · playwright 가 있으면 화면 열기 ──
verify)
  merged_valid
  [ "$MDEP" = 1 ] || [ "$MMODE" = merge-only ] || refuse "⛔ 먼저 deploy-wait 로 배포 끝을 확인해야 합니다(7-execute 「8. 자동 마감」 순서)."
  fails=""; okn=0
  fail() { fails="$fails$NL   ✗ $1"; }
  http_get "$(bust "$MURL/")" "$TD/u" && okn=$((okn + 1)) || fail "운영 주소($MURL) — 응답 $HC"
  if [ -n "$MMARK" ]; then
    if marker_read "$MMARK" "$MURL"; then
      if [ "$MDEP" = 1 ]; then [ "$MV" = "$MNEW" ] && okn=$((okn + 1)) || fail "판 표지 $MV — 배포 확인 때 값($MNEW)과 다름"
      else [ "$MV" != "$MOLD" ] && okn=$((okn + 1)) || fail "판 표지 $MV — 합치기 전 값 그대로(새 배포가 아직 안 보임)"
      fi
    else fail "판 표지: $MWHY"
    fi
  fi
  rest=$MSCR; sn=0; : > "$TD/list"
  while [ -n "$rest" ]; do
    one=${rest%%;*}; [ "$one" = "$rest" ] && rest="" || rest=${rest#*;}
    [ -n "$one" ] || continue
    sn=$((sn + 1))
    if screen_get "${one%%"→"*}" "${one#*"→"}" "$MURL"; then okn=$((okn + 1)); printf '%s\t%s\n' "${one%%"→"*}" "${one#*"→"}" >> "$TD/list"
    else fail "화면 $SWHY"
    fi
  done
  # 화면 열기(playwright 가 프로젝트에 있을 때만 — 설치하지 않는다): 같은 출처의 GET·HEAD 아닌 요청은 막고(route abort) 콘솔 오류 0 · 기대 글자 · 스크린샷
  pw="화면 열기: 없음(playwright 없음 — GET 만 확인)"
  # 보안 검사(10-05): 프로젝트의 playwright 는 안전 실행기 밖에서 돈다 — 진짜 환경 변수(비밀값)를 넘기지 않게 환경을 비우고 꼭 필요한 것만 넘긴다
  #   (PATH·HOME·언어·임시 폴더 · 브라우저 위치 · Windows 실행에 필요한 것) · 사용자·전체 .npmrc 는 읽지 않는다(프로젝트 .npmrc 는 npm 이 읽지만 비밀값 환경 변수가 없어 ${…} 는 빈 값)
  #   (사용자·전체 npm 설정은 서로 다른 빈 파일로 — 같은 파일(/dev/null)을 둘에 주면 npm 이 "double-loading config" 로 바로 멈춘다 · 재검사 A3)
  : > "$TD/npmrc-u" 2>/dev/null; : > "$TD/npmrc-g" 2>/dev/null
  PWENV=(PATH="$PATH" HOME="${HOME:-$TD}" LANG=C.UTF-8 TMPDIR="$TD" npm_config_userconfig="$TD/npmrc-u" npm_config_globalconfig="$TD/npmrc-g" npm_config_update_notifier=false)
  for v_ in PLAYWRIGHT_BROWSERS_PATH SYSTEMROOT SystemRoot LOCALAPPDATA USERPROFILE APPDATA COMSPEC ComSpec; do [ -n "${!v_:-}" ] && PWENV+=("$v_=${!v_}"); done
  if [ -s "$TD/list" ] && (cd "$proj" && rl_bounded 20 env -i "${PWENV[@]}" npx --no-install playwright --version) >/dev/null 2>&1; then
    left=$(( 100 - (SECONDS - t0) ))
    if [ "$left" -lt 15 ]; then
      again "⏳ 시간이 모자라 화면 열기를 다음 실행에서 합니다(GET 확인은 끝남)"
    fi
    per=$PGL; n_=0; while IFS= read -r x; do n_=$((n_ + 1)); done < "$TD/list"
    [ $((per * n_ + 10)) -gt "$left" ] && per=$(( (left - 10) / n_ )); [ "$per" -lt 3 ] && per=3
    shot="$dir/verify/$B"
    mkdir -p "$shot" 2>/dev/null && { [ -f "$dir/verify/.gitignore" ] || printf '*\n' > "$dir/verify/.gitignore"; } 2>/dev/null
    cat > "$TD/pw.js" <<'PWJS'
const [, , base, shotdir, ep, listFile, limit] = process.argv;
const fs = require('fs');
let pw;
try { pw = require('playwright'); } catch (e) { console.log('NOPW\t' + String(e.message).split('\n')[0]); process.exit(0); }
(async () => {
  const origin = new URL(base).origin;
  let browser;
  try { browser = await pw.chromium.launch(); } catch (e) { console.log('NOPW\t' + String(e.message).split('\n')[0]); return; }
  const rows = fs.readFileSync(listFile, 'utf8').split('\n').filter(Boolean);
  let i = 0;
  for (const row of rows) {
    i++;
    const tab = row.indexOf('\t'); const p = row.slice(0, tab); const want = row.slice(tab + 1);
    const page = await browser.newPage();
    const errs = []; let aborted = 0;
    page.on('console', m => { if (m.type() === 'error') errs.push(m.text()); });
    page.on('pageerror', e => errs.push(String(e)));
    await page.route('**/*', r => {
      const q = r.request(); let o = '';
      try { o = new URL(q.url()).origin; } catch (e) {}
      if (o === origin && q.method() !== 'GET' && q.method() !== 'HEAD') { aborted++; return r.abort(); }
      return r.continue();
    });
    let line;
    try {
      const res = await page.goto(base + p + '?_=' + ep, { waitUntil: 'load', timeout: Number(limit) * 1000 });
      const text = await page.evaluate(() => (document.body ? document.body.innerText : ''));
      await page.screenshot({ path: shotdir + '/' + i + '.png', fullPage: true });
      const real = errs.filter(t => !(aborted > 0 && /ERR_FAILED|Failed to load resource/.test(t)));
      line = ['PAGE', p, res ? res.status() : 0, text.includes(want) ? 'yes' : 'no', real.length, (real[0] || '').replace(/\s+/g, ' ').slice(0, 120)];
    } catch (e) {
      line = ['PAGE', p, 0, 'no', errs.length, ('열기 실패: ' + String(e.message)).replace(/\s+/g, ' ').slice(0, 120)];
    }
    console.log(line.join('\t'));
    await page.close();
  }
  await browser.close();
})().catch(e => console.log('NOPW\t' + String(e.message).split('\n')[0]));
PWJS
    (cd "$TD" && rl_bounded $((per * n_ + 10)) env -i "${PWENV[@]}" NODE_PATH="$proj/node_modules" node "$TD/pw.js" "$MURL" "$shot" "$(date +%s)" "$TD/list" "$per") >"$TD/pwo" 2>/dev/null; pwrc=$?
    pwn=0; pwok=0; pwnot=""
    while IFS="$RL_TAB" read -r k_ p_ s_ y_ e_ m_; do
      case "$k_" in
        NOPW) pwnot=$(clean "$p_" 100) ;;
        PAGE)
          pwn=$((pwn + 1))
          if [ "$s_" = 200 ] && [ "$y_" = yes ] && [ "$e_" = 0 ]; then pwok=$((pwok + 1))
          else fail "화면 열기 $(clean "$p_" 60) — 응답 $s_ · 기대 글자 $([ "$y_" = yes ] && echo 있음 || echo 없음) · 콘솔 오류 ${e_}개$([ -n "$m_" ] && printf ' (%s)' "$(clean "$m_" 100)")"
          fi ;;
      esac
    done < "$TD/pwo"
    if [ -n "$pwnot" ]; then pw="화면 열기: 못 함($pwnot — GET 만 확인)"
    elif [ "$pwn" = 0 ]; then pw="화면 열기: 못 함(결과 없음 · 종료 $pwrc — GET 만 확인)"
    else pw="화면 열기: ${pwok}/${pwn} 통과 · 스크린샷 docs/refactor/verify/$B/"
    fi
  fi
  end_merged
  if [ -z "$fails" ]; then
    say "✅ 라이브 검증 통과($B): 운영 주소 200$([ -n "$MMARK" ] && printf ' · 판 표지 %s' "$MV") · 확인할 화면 ${sn}개 GET 통과"
    say "   $pw"
    # 0.4.0 새 가지(사장님 결정 3 — 자동 모드 성공 뒤 다음 묶음의 작업 가지까지 · 다음 묶음 승인은 사람): 검증 결과·종료 코드(0)는 그대로이고
    #   새 가지는 덧붙이는 일. 만들지 않는 네 경우 = merge-only(사람이 "검증해" 라고 입력해야 verify 가 돎) · 합친 뒤 사람 입력(.turn-nextok 없음·다름) ·
    #   받아 오기(fetch) 실패 · 남은 묶음 0 — 그리고 lib rl_new_branch 의 판정 실패(사람 길과 같은 확인). 표시 파일은 여기서 지운다
    nxw="다음: 보고 → 다음 묶음은 사람이 /refactor:approve 새 가지"
    nxok=0; nxtp=""; nxsz=""; nxts=""
    if [ -f "$NX" ]; then read_lines "$NX"; [ "${L[0]:-}" = "$B" ] && [ "${L[2]:-}" = "$sid" ] && age_ok "${L[1]:-}" 7200 && nxok=1; nxtp=${L[3]:-}; nxsz=${L[4]:-}; nxts=${L[5]:-}; fi
    rm -f "$NX"
    # 0.4.1 R7(#14): AskUserQuestion 답·권한 확인 응답이 입력 훅을 거치는지는 공식 문서에 없다 → 훅에 기대지 않고 새 가지 직전에 대화 기록을 한 번 더 본다
    #   (합치기 허락 때의 경로·크기·시각 — 합치기 스크립트와 같은 판정 lib rl_tp_human + AskUserQuestion 답 줄). 사람 입력이 보이면 "합친 뒤 입력" 길로.
    #   기록을 못 보면(경로 없음·못 읽음) 지금처럼 표시만 믿는다. 권한 확인 창 응답은 기록 꼴을 몰라 알아보지 못한다(한계)
    if [ "$nxok" = 1 ] && [ -n "$nxtp" ]; then
      rl_tp_prep "$nxtp" "$nxsz" "$nxts"
      rl_tp_human "$RL_TP" "$RL_TP0" "$RL_TPT" q && nxok=0
    fi
    if [ "$MMODE" = merge-only ]; then
      say "ℹ️ 배포 방식이 '수동'(합치기까지만)이라 새 가지는 만들지 않았습니다 — 다음 묶음은 /refactor:approve 새 가지"
    elif [ "$nxok" != 1 ]; then
      say "ℹ️ 합친 뒤 입력이 있어 새 가지는 만들지 않았습니다 — 다음 묶음은 /refactor:approve 새 가지"
    else
      # 받아 오기: 이 호출의 남은 시간 안(Bash 도구 한도 120초 — 화면 열기에 시간을 썼으면 짧아짐) · 올리기 한도(PL) 까지
      fl=$((108 - (SECONDS - t0))); [ "$fl" -gt "$PL" ] && fl=$PL
      fe=""
      if [ "$fl" -lt 5 ]; then frc=1; fe="검증에 시간을 다 써서 받아 오기를 하지 않음"
      else rl_bounded "$fl" "${G[@]}" fetch -q origin >/dev/null 2>"$TD/fe"; frc=$?; [ "$frc" = 124 ] && fe="${fl}초 안에 끝나지 않음"
      fi
      if [ "$frc" != 0 ]; then
        [ -n "$fe" ] || { while IFS= read -r x; do [ -n "${x//[[:space:]]/}" ] && { fe=$(clean "$x" 200); break; }; done < "$TD/fe"; }
        say "ℹ️ 최신 내용을 받아 오지 못해 새 가지는 만들지 않았습니다 — 다음 묶음은 /refactor:approve 새 가지"
        say "   (까닭: ${fe:-git fetch 종료 $frc})"
      else
        rl_next_bundle "$dir/REFACTOR_PLAN.md" "$log"
        if [ -z "$RL_NBC" ]; then
          say "✅ 남은 묶음이 없습니다 — 다 끝났으면 /refactor:approve 마무리"
          nxw="다음: 보고"
        else
          RL_TODAY=$(rl_today)
          rl_new_branch "$proj" "" "자동 $B 으로 실행"; nrc=$?
          printf '%s' "$RL_NBOUT"
          case "$nrc" in
            0) if [[ $RL_NBB =~ ^B[0-9]+$ ]]; then nxw="다음: /refactor:approve $RL_NBB 자동 → /refactor:go"
               else nxw="다음: /refactor:approve 로 다음 단계를 승인 → /refactor:go"; fi ;;
            1) say "   (새 가지는 사람이 — 위 까닭을 푼 뒤 /refactor:approve 새 가지)" ;;
            *) nxw="다음: 보고 → 사람이 git status 로 지금 가지를 확인" ;;
          esac
        fi
      fi
    fi
    say "$nxw"
    exit 0
  fi
  [ -e "$NX" ] && rm -f "$NX"   # 0.4.1 R6(N#2): 실패로 끝나도 표시를 지운다
  say "⛔ 라이브 검증 실패($B) — 합친 것은 그대로입니다(자동 되돌리기 없음):$fails"
  say "   $pw"
  say "$REVERT_WAY"
  exit 1 ;;
esac
