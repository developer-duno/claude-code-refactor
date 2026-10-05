#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Vibe Refactor — PR 합치기 스크립트 (0.3.5, /refactor:approve 합치기 의 뒷부분)
#
# 사용자가 입력창에 /refactor:approve 합치기 [번호] [방식] 을 치면 입력 훅(refactor-approve.sh)이 허락 파일
# docs/refactor/.turn-merge.<세션ID> 를 만들고 "실행할 명령"을 알려 준다. Claude 가 그 차례에 Bash 도구로 그 명령을 그대로 실행하면
# 이 스크립트가 허락을 확인한 뒤 gh 로 PR 을 확인하고 합친다. 안전장치(guard)는 그 명령 글자 그대로일 때만 통과시킨다.
#   사용: bash "<플러그인>/hooks/run.sh" refactor-merge "<프로젝트 폴더>" <세션ID>
#
# 종료 코드: 0 = 합침(또는 이미 합쳐져 있음·마무리 뒤) · 3 = 다시 실행(허락 유지 — 같은 명령을 그대로 다시) · 1 = 거절
#   (2·124·127 은 쓰지 않는다 — run.sh 가 문제 기록에 남기는 코드다)
# 허락 소모: "다시 실행(3)" 말고는 어떤 결과든 허락 파일을 지운다. 합치기 호출은 허락을 먼저 지운 뒤에 한다(인자가 틀린 실행 S0·마무리 뒤 S1·
#   되풀이 사이 사람이 새로 만든 허락(F9)은 그대로 둠)
# 입력 감시(0.3.7, S2b): 허락과 함께 적힌 대화 기록 파일에 사람 입력 줄이 새로 생기면 조회 앞·간격의 매초·비교 앞·합치기 직전에 알아채고
#   허락을 지운 뒤 1(⛔ 사용자 입력이 있어 …). 경로가 없으면 감시 꺼짐(0.3.6 과 같음). 결과 끝 줄 "입력 감시: 켬/꺼짐"
# 승인 기록(APPROVALS.log)·봉인(approved/)·턴 스냅숏(.turn-dirty.*)은 건드리지 않는다(턴 중에 기록이 바뀌면 post-check 가 알린다 — 기록은 허락할 때 한 줄뿐)
# gh 호출은 셋뿐: pr view(조회) · api compare(기본 가지에 새 커밋?) · pr merge <N> --<방식> --match-head-commit <PR 머리>.
#   --admin·--auto·--delete-branch 는 어떤 입력으로도 붙지 않는다. gh 로그인 정보(토큰)는 읽거나 넘기지 않는다(gh 기본 로그인 그대로)
#
# 시간(Bash 도구 기본 한도 120초 안 — 한 호출 최악 110초 이하): 조회 15 · 비교 15 · 합치기 30 · 받아 오기 10초(rl_bounded — 한도 뒤 TERM, 1초 뒤 KILL)
#   검사가 도는 중·GitHub 가 계산 중이면 시작 뒤 20초 안에서만 다시 조회를 시작(간격 10초) — 그 뒤면 "같은 명령을 다시"(3)
#   초록 두 번 연속(0.3.5 보완 F2): 검사가 전부 초록이어도 바로 합치지 않고 간격 뒤 한 번 더 조회해 ⓐ 검사 이름 집합 같음 ⓑ 전부 초록
#     ⓒ PR 머리 같음 일 때만 진행(단계별로 붙는 검사가 앞 단계만 초록인 순간에 합치지 않게). 처음 본 초록 다음의 확인 조회 1번(한 호출에
#     한 번)은 창 확인을 면제한다(조회가 느려 첫 조회가 창 끝 가까이 끝나도 그 호출에서 확인까지 간다 — 재검사 A2·C2). 그 확인 조회가 다시
#     기다림이면 창 규칙 그대로(창 밖이면 3). 창이 0 이면 면제도 없다(다시 조회하지 않음)
#   최악 = 창 안에서 시작한 마지막 조회 19 + 조회 16 + 간격 10 + 창 면제 확인 조회 16 + 비교 16 + 합치기 31 = 108초(면제는 한 번뿐이라 확인 조회 뒤에
#     또 조회하는 길은 창 안에서만 — 그 길은 이보다 짧다). 받아 오기는 그때까지 95초 이하를 썼을 때만(95 + 11 = 106초)
#   검사가 0개면 허락을 만든 지 120초 안에는 "아직 등록 안 됨"(도는 중으로 봄 — 3), 그 뒤면 거절
# 시험용 줄이기 전용 환경 변수(정수 · 기본값보다 크거나 정수가 아니면 무시):
#   REFACTOR_MERGE_VIEW_LIMIT(15, 1 이상) · REFACTOR_MERGE_CMP_LIMIT(15, 1 이상) · REFACTOR_MERGE_MERGE_LIMIT(30, 1 이상) ·
#   REFACTOR_MERGE_FETCH_LIMIT(10, 1 이상) · REFACTOR_MERGE_WINDOW(20) · REFACTOR_MERGE_INTERVAL(10) · REFACTOR_MERGE_FETCH_BUDGET(95) ·
#   REFACTOR_MERGE_NOCHECK_GRACE(120)
# ─────────────────────────────────────────────────────────────────────────────

LC_ALL=C
export LC_ALL
set -f

t0=$SECONDS
say() { printf '%s\n' "$*"; }
usage() {
  say "❓ 쓰는 법: bash \"<플러그인>/hooks/run.sh\" refactor-merge \"<프로젝트 폴더>\" <세션ID> (이 스크립트는 /refactor:approve 합치기 가 알려 준 명령으로만 실행합니다)"
  [ -n "${1:-}" ] && say "   ($1)"
  exit 1
}

# ── S0 인자·lib ─────────────────────────────────────────────────────────────
[ "$#" = 2 ] || usage
proj=$1
proj=${proj//"\\"//}
proj=${proj%/}
sid=$2
[ -n "$proj" ] && [ -d "$proj" ] || usage "프로젝트 폴더가 없습니다"
[[ $sid =~ ^[A-Za-z0-9_-]{1,128}$ ]] || usage "세션 ID 꼴이 아닙니다"
root=${REFACTOR_ROOT:-}
[ -z "$root" ] && case "${BASH_SOURCE[0]}" in */*) root="${BASH_SOURCE[0]%/*}/.." ;; esac
lib="$root/scripts/refactor-lib.sh"
{ [ -n "$root" ] && [ -f "$lib" ]; } || usage "도구 파일(refactor-lib.sh)을 찾지 못했습니다 — 플러그인을 다시 설치해 주세요"
libsrc=""; IFS= read -r -d '' libsrc < "$lib" || :
eval "${libsrc//$'\r'/}"; unset libsrc
US=$RL_US

dir="$proj/docs/refactor"
mf="$dir/.turn-merge.$sid"
tpf="$dir/.turn-mergetp.$sid"   # 0.3.7: 합치기 허락과 함께 승인 스크립트가 만든 대화 기록 경로(1줄) — 없으면 입력 감시 꺼짐

# 줄이기 전용 한도: $1 = 환경 변수 값, $2 = 기본값, $3 = 가장 작은 값 → LIMV
lim() {
  LIMV=$2
  case "$1" in ""|*[!0-9]*) return 0 ;; esac
  [ "${#1}" -le 4 ] || return 0
  [ $((10#$1)) -le "$2" ] && [ $((10#$1)) -ge "$3" ] && LIMV=$((10#$1))
  return 0
}
lim "${REFACTOR_MERGE_VIEW_LIMIT:-}" 15 1; QL=$LIMV
lim "${REFACTOR_MERGE_CMP_LIMIT:-}" 15 1; CL=$LIMV
lim "${REFACTOR_MERGE_MERGE_LIMIT:-}" 30 1; ML=$LIMV
lim "${REFACTOR_MERGE_FETCH_LIMIT:-}" 10 1; FL=$LIMV
lim "${REFACTOR_MERGE_WINDOW:-}" 20 0; WIN=$LIMV
lim "${REFACTOR_MERGE_INTERVAL:-}" 10 0; IVL=$LIMV
lim "${REFACTOR_MERGE_FETCH_BUDGET:-}" 95 0; FB=$LIMV
lim "${REFACTOR_MERGE_NOCHECK_GRACE:-}" 120 0; GR=$LIMV

MG_AUTH="   권한·저장소를 찾지 못함 오류라면: gh 로그인 계정이 이 저장소에 쓰기 권한이 있는지 사람이 확인해 주세요(gh auth status) — 다른 계정이면 사람이 터미널에서 바꾼 뒤 다시 /refactor:approve 합치기"
drop() { [ -e "$mf" ] && rm -f "$mf"; [ -e "$tpf" ] && rm -f "$tpf"; return 0; }
# 거절(허락을 지우고 1)
no() { drop; say "$1"; [ -n "${2:-}" ] && say "$2"; say "   (합치지 않았습니다 — 허락은 끝났습니다. 다시 하려면 사용자가 /refactor:approve 합치기)"; exit 1; }
# 다시 실행(허락 유지 · 3) — 남은 분은 허락을 만든 시각으로 잰다
again() {
  local rem
  rem=$(( 1800 - ($(date +%s) - gt) ))
  [ "$rem" -lt 0 ] && rem=0
  say "$1"
  say "   (허락은 그대로입니다 — 약 $(( (rem + 59) / 60 ))분 남음. 같은 명령을 그대로 다시 실행하세요.)"
  exit 3
}

# ── S1 마무리 뒤 ────────────────────────────────────────────────────────────
if rl_done_confirmed "$dir"; then
  say "ℹ️ 이미 마무리되어 안전장치가 꺼져 있습니다 — 평소처럼 합칠 수 있습니다"
  exit 0
fi

# ── S2 허락 파일: 3줄(줄 끝 \r 뗌) · 1줄 꼴 · 만든 지 0~1800초 · 3줄 = 허락된 명령 꼴 ───────────────
NO_GRANT="⛔ 합치기 허락이 없거나 끝났습니다 — 사용자가 /refactor:approve 합치기 를 입력해야 합니다"
[ -f "$mf" ] || no "$NO_GRANT"
g1=""; g2=""; g3=""
{ IFS= read -r g1; IFS= read -r g2; IFS= read -r g3; } < "$mf"
g1=${g1%$'\r'}; g2=${g2%$'\r'}; g3=${g3%$'\r'}
re_g1='^merge ([A-Za-z0-9_][A-Za-z0-9._/-]*) (-|[0-9]{1,7}) (rebase|squash|merge) ([0-9a-f]{40}([0-9a-f]{24})?)$'
[[ $g1 =~ $re_g1 ]] || no "$NO_GRANT"
gbr=${BASH_REMATCH[1]}; gpr=${BASH_REMATCH[2]}; mth=${BASH_REMATCH[3]}; goid=${BASH_REMATCH[4]}
[[ $g2 =~ ^[0-9]{1,12}$ ]] || no "$NO_GRANT"
gt=$((10#$g2))
age=$(( $(date +%s) - gt ))
{ [ "$age" -ge 0 ] && [ "$age" -le 1800 ]; } || no "$NO_GRANT"
case "$g3" in 'bash "'*' refactor-merge '*) ;; *) no "$NO_GRANT" ;; esac
[ "$gpr" = "-" ] && gpr=""

# ── S2b 입력 감시(0.3.7 — 2분 틈): 허락과 함께 적힌 대화 기록 파일(훅 입력의 transcript_path)을 지켜본다 ──
#   턴 도중 친 사람 말은 돌던 명령이 끝나 전달될 때에야 입력 훅이 허락을 지운다(0.3.6 실측) → 이 스크립트가 도는 동안의 입력은
#   대화 기록에 곧바로 쓰이는 줄로 알아챈다: 지금 크기 > 시작 크기면 늘어난 부분에서 "type":"queue-operation" · "operation":"enqueue" 가 든 줄 중
#   "content" 칸이 없거나 그 값이 < 로 시작하지 않는 줄(사람이 친 것 — 작업 완료 알림 등은 content 가 <task-notification … 처럼 < 로 시작) 이 있으면 멈춘다.
#   grep·tail·wc 만(파이썬 없음 · bash 3.2). 줄이 반쯤 쓰인 순간에 본 조각도 같은 거름망 — 알림이 잘려 사람 줄로 보이면 합치지 않는 쪽(안전 쪽)으로 틀린다.
#   경로가 없거나 읽을 수 없으면 감시 꺼짐(0.3.6 과 같은 동작). 결과 블록 끝에 "입력 감시: 켬/꺼짐" 한 줄
TP=""; TP0=0; FSZ=0
fsize() { local s; s=$(wc -c < "$1" 2>/dev/null) || return 1; s=${s//[!0-9]/}; [ -n "$s" ] || return 1; FSZ=$((10#$s)); }
if [ -f "$tpf" ]; then
  IFS= read -r TP < "$tpf" || :
  TP=${TP%$'\r'}
  { [ -n "$TP" ] && [ -f "$TP" ] && [ -r "$TP" ] && fsize "$TP"; } && TP0=$FSZ || TP=""
fi
if [ -n "$TP" ]; then WLINE="입력 감시: 켬"; else WLINE="입력 감시: 꺼짐(대화 기록 경로 없음)"; fi
trap 'say "$WLINE"' EXIT
human_typed() {
  [ -n "$TP" ] && fsize "$TP" && [ "$FSZ" -gt "$TP0" ] || return 1
  tail -c "$((FSZ - TP0))" "$TP" 2>/dev/null | grep '"type":"queue-operation"' | grep '"operation":"enqueue"' | grep -v '"content":"<' | grep -q .
}
# 사람 입력이 보이면: 허락이 이 실행이 읽은 것 그대로일 때만 허락·경로 파일을 지우고(바뀌었으면 사람이 새로 만든 것 — S17 과 같게 둔다) 거절
watch_input() {
  local r1="" r2=""
  human_typed || return 0
  if [ -f "$mf" ]; then
    { IFS= read -r r1; IFS= read -r r2; } < "$mf"
    [ "${r1%$'\r'}" = "$g1" ] && [ "${r2%$'\r'}" = "$g2" ] && drop
  fi
  say "⛔ 사용자 입력이 있어 허락이 끝났습니다 — 합치지 않았습니다. 다시 합치려면 /refactor:approve 합치기 를 다시 입력하세요."
  exit 1
}

# ── S3 승인 기록 봉인 ───────────────────────────────────────────────────────
rl_log_intact "$dir" || no "⛔ 승인 기록이 봉인과 다릅니다 — /refactor:approve 확인 먼저"

# 승인 기록 대조(0.3.5 보완 F7① — S2 의 마지막 확인, 봉인이 맞을 때만 기록을 믿고 읽음): 허락은 사람 입력(입력 훅)이 기록 한 줄과 함께 만든다 —
#   기록의 마지막 비지 않은 줄이 이 허락의 줄이어야 한다(Claude 는 기록을 못 쓰고 봉인이 지킨다 → 다른 길로 허락 파일만 만들어 둔 것은 여기서 걸린다).
#   읽기만 한다(I5). 한계: 기록 줄에는 허락 시각(초)이 없어 같은 가지·번호·방식·커밋의 옛 허락 줄이 마지막이면 구별하지 못한다
if [ -n "$gpr" ]; then gprw="PR #$gpr"; else gprw="PR(지금 가지)"; fi
glast=""
if [ -f "$dir/APPROVALS.log" ]; then
  while IFS= read -r x || [ -n "$x" ]; do x=${x%$'\r'}; [ -n "${x//[[:space:]]/}" ] && glast=$x; done < "$dir/APPROVALS.log"
fi
case "$glast" in
  *" KST | 합치기 | 허락 $gbr $gprw ($mth) @${goid:0:7} | - | 사용자가 /refactor:approve 로 실행") ;;
  *) no "⛔ 합치기 허락이 승인 기록과 맞지 않습니다 — 사용자가 /refactor:approve 합치기 를 다시 입력해야 합니다" ;;
esac

# git 호출 방어(승인 스크립트·안전장치와 같게): 대체 객체 무시 · fsmonitor 끔 · 합칠 때 renormalize 끔
G=(git --no-replace-objects -c core.fsmonitor=false -c merge.renormalize=false -C "$proj")

# ── S4 허락한 가지·커밋 그대로인가 ───────────────────────────────────────────
br=$("${G[@]}" symbolic-ref -q --short HEAD 2>/dev/null) || br=""
hoid=$("${G[@]}" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null) || hoid=""
if [ "$br" != "$gbr" ] || [ "$hoid" != "$goid" ]; then
  no "⛔ 허락한 뒤 가지·커밋이 달라졌습니다(허락: $gbr@${goid:0:7} · 지금: ${br:-(가지 없음)}@${hoid:0:7})"
fi

# ── S5 기본 가지·gh ──────────────────────────────────────────────────────────
rl_origin_base "$proj" || no "❓ origin 의 기본 가지를 찾지 못했습니다(origin/HEAD·origin/main·origin/master 참조 없음)"
bname=$RL_BNAME
[ "$br" = "$bname" ] && no "⛔ 지금 가지가 기본 가지($bname)입니다 — 작업 가지의 PR 만 합칩니다"
command -v gh >/dev/null 2>&1 || no "❓ gh(GitHub CLI)를 찾지 못했습니다 — 사람이 GitHub 화면이나 터미널에서 합쳐 주세요"

mtmp=$(mktemp -d 2>/dev/null) || mtmp=$(mktemp -d -t rlmerge 2>/dev/null) || mtmp=""
[ -n "$mtmp" ] || again "⚠️ 임시 폴더를 만들지 못했습니다"
trap 'rm -rf "$mtmp"; say "$WLINE"' EXIT
# gh 의 첫 오류 줄(200자까지) → GE. 제어 문자는 ? 로(결과에 터미널 제어 글자가 그대로 실리지 않게)
gh_err() {
  local x
  GE=""
  while IFS= read -r x; do x=${x%$'\r'}; [ -n "${x//[[:space:]]/}" ] && { GE=${x:0:200}; break; }; done < "$mtmp/e"
  GE=${GE//[[:cntrl:]]/?}
  [ -n "$GE" ] || GE="(오류 문구 없음)"
}
# gh 호출의 출력·오류는 $( ) 가 아니라 임시 파일로 받는다(gh 감싸개가 띄운 자식이 출력 통로를 쥐고 남으면
#   $( ) 는 시간 한도와 상관없이 그 자식이 끝날 때까지 기다린다. 파일이면 한도에서 바로 돌아온다)
export GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 GIT_TERMINAL_PROMPT=0
# 조회 칸: 첫 줄 = 번호·상태·초안·포크·기본 가지·머리 가지·머리 커밋·합칠 수 있음, 그다음 줄마다 검사 하나(종류·status·conclusion·state·이름)
JQV='([.number, .state, .isDraft, .isCrossRepository, .baseRefName, .headRefName, .headRefOid, .mergeable] | map(tostring) | join("\u001f")), ((.statusCheckRollup // [])[] | [(.__typename // "-"), (.status // "-"), (.conclusion // "-"), (.state // "-"), (.name // .context // "-")] | map(tostring) | join("\u001f"))'

# ── 조회 → 확인(되풀이: 검사 도는 중·계산 중·처음 본 초록이면 창 안에서 다시) ───────────────────────────────
cf_have=0; cf_set=""; cf_oid=""; cf_free=1
while :; do
  watch_input
  set -- pr view
  [ -n "$gpr" ] && set -- "$@" "$gpr"
  (cd "$proj" && rl_bounded "$QL" gh "$@" --json number,state,isDraft,isCrossRepository,baseRefName,headRefName,headRefOid,mergeable,statusCheckRollup --jq "$JQV") >"$mtmp/o" 2>"$mtmp/e"; prc=$?
  pv=$(< "$mtmp/o")
  if [ "$prc" != 0 ]; then
    case "$prc" in
      124|142) again "⚠️ PR 을 조회하지 못했습니다: ${QL}초 안에 끝나지 않음" ;;
    esac
    gh_err
    # 다시 해도 같은 오류(저장소·PR 없음·권한·로그인 — 0.3.5 보완 F10)는 거절 + 계정 안내, 그 밖(연결 끊김 등)은 다시 실행
    #   요청 한도(rate limit — 403 이어도)·주소 찾기 실패(could not resolve host — DNS)는 기다리면 풀리므로 다시 실행(재검사 A2 🟡).
    #   GraphQL 의 "could not resolve to a …"(저장소·PR 없음)는 영구 그대로
    gel=$(printf '%s' "$GE" | tr 'A-Z' 'a-z')
    case "$gel" in
      *"rate limit"*|*"could not resolve host"*) again "⚠️ PR 을 조회하지 못했습니다: $GE" ;;
    esac
    case "$gel" in
      *"not found"*|*"could not resolve"*|*"no pull requests"*|*"no open pull"*|*"http 401"*|*"http 403"*|*"http 404"*|*auth*)
        no "⛔ PR 을 조회하지 못했습니다: $GE" "$MG_AUTH" ;;
    esac
    again "⚠️ PR 을 조회하지 못했습니다: $GE"
  fi
  first=${pv%%"$RL_NL"*}; rest=""
  case "$pv" in *"$RL_NL"*) rest=${pv#*"$RL_NL"} ;; esac
  IFS="$US" read -r pn pst pdr pfk pbase phead poid pmg <<EOF
$first
EOF
  if ! [[ $pn =~ ^[0-9]+$ ]] || ! [[ $poid =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]; then
    no "⛔ PR 정보를 읽지 못했습니다(gh 응답 형식이 예상과 다름)"
  fi
  # S8·S9 상태 → 초안 → 포크 → 가지
  # S8 이미 합쳐짐: 지금 가지의 PR 이고 그 머리 = 지금 커밋(= 허락한 커밋, S4)일 때만 "이미 합쳐져 있음"(0.3.5 보완 F1 — 번호 없이 조회하면
  #   gh 가 그 가지의 합쳐진 옛 PR 을 돌려줄 수 있다: 합친 뒤 새 커밋·번호 잘못 줌이면 합친 것이 아니므로 거절)
  if [ "$pst" = MERGED ]; then
    if [ "$phead" = "$br" ] && [ "$poid" = "$hoid" ]; then
      drop; say "ℹ️ PR #$pn 은 이미 합쳐져 있습니다 — 다음 묶음: /refactor:approve 새 가지"; exit 0
    fi
    no "⛔ PR #$pn 은 이미 합쳐진 PR 입니다($phead@${poid:0:7}) — 지금 커밋(${hoid:0:7})은 새 PR 이 필요합니다(gh pr create) · 다른 PR 이면 번호를 확인하세요"
  fi
  [ "$pst" = OPEN ] || no "⛔ PR #$pn 은 열려 있는 PR 이 아닙니다(상태: $pst)"
  [ "$pdr" = false ] || no "⛔ PR #$pn 은 초안(draft)입니다 — 사람이 GitHub 화면에서 '준비됨'으로 바꾼 뒤 다시"
  [ "$pfk" = false ] || no "⛔ PR #$pn 은 포크의 PR 입니다 — 사람이 GitHub 화면·터미널에서 합쳐 주세요"
  [ "$phead" = "$br" ] || no "⛔ PR #$pn 은 다른 가지($phead)의 것입니다(지금 가지: $br)"
  # S11 머리 커밋 ≠ 지금 커밋 — 네트워크 없이 로컬 객체로 넷으로 가른다
  if [ "$poid" != "$hoid" ]; then
    W_BEHIND="⛔ PR #$pn 에 이 컴퓨터에 없는 커밋이 있습니다(GitHub 의 Update branch·다른 사람의 push) — Claude 에게 \"작업 가지 최신 내용 받아 와\"라고 한 뒤 다시 /refactor:approve 합치기"
    "${G[@]}" cat-file -e "$poid^{commit}" 2>/dev/null || no "$W_BEHIND"
    "${G[@]}" merge-base --is-ancestor "$hoid" "$poid" 2>/dev/null && no "$W_BEHIND"
    "${G[@]}" merge-base --is-ancestor "$poid" "$hoid" 2>/dev/null && no "⛔ 아직 안 올린 커밋이 있습니다(PR 의 마지막 커밋 ${poid:0:7} · 지금 ${hoid:0:7}) — 먼저 /refactor:approve 푸시, 그다음 다시 /refactor:approve 합치기"
    no "⛔ PR 의 마지막 커밋과 지금 커밋이 갈라져 있습니다 — 사람이 확인해 주세요"
  fi
  [ "$pbase" = "$bname" ] || no "⛔ PR #$pn 은 기본 가지($bname)로 가는 PR 이 아닙니다(받는 가지: $pbase)"
  wait_msg=""
  case "$pmg" in
    MERGEABLE) ;;
    CONFLICTING) no "⛔ PR #$pn 에 충돌이 있습니다 — 충돌을 먼저 풀어야 합니다" ;;
    UNKNOWN) wait_msg="⏳ GitHub 가 아직 계산 중입니다(PR #$pn 을 합칠 수 있는지)" ;;
    *) no "⛔ PR #$pn 을 합칠 수 있는 상태가 아닙니다(mergeable: $pmg)" ;;
  esac
  if [ -z "$wait_msg" ]; then
    # 자동 검사: 실패 · 안 끝난 것 · 0개(허락 뒤 120초 안이면 아직 등록 안 됨) · 성공(SUCCESS)이 하나도 없음(전부 NEUTRAL·SKIPPED)
    cn=0; cok=0; cpend=""; cfail=""; clist=""
    while IFS="$US" read -r ctype cstat cconc cstate cname; do
      [ -n "$ctype" ] || continue
      cn=$((cn + 1)); cname=${cname:0:80}; cname=${cname//[[:cntrl:]]/?}
      clist="$clist$ctype:$cname$RL_NL"
      case "$ctype" in
        CheckRun)
          if [ "$cstat" != COMPLETED ]; then cpend="$cpend, $cname"
          else case "$cconc" in SUCCESS) cok=$((cok + 1)) ;; NEUTRAL|SKIPPED) ;; *) cfail="$cfail, $cname" ;; esac
          fi ;;
        StatusContext)
          case "$cstate" in SUCCESS) cok=$((cok + 1)) ;; PENDING|EXPECTED) cpend="$cpend, $cname" ;; *) cfail="$cfail, $cname" ;; esac ;;
        *) cfail="$cfail, $cname(알 수 없는 검사 종류 $ctype)" ;;
      esac
    done <<EOF
$rest
EOF
    [ -n "$cfail" ] && no "⛔ PR #$pn 의 자동 검사 실패(${cfail#, }) — 고친 뒤 다시"
    if [ -n "$cpend" ]; then
      wait_msg="⏳ PR #$pn 의 자동 검사가 아직 도는 중입니다(${cpend#, })"
    elif [ "$cn" = 0 ] && [ $(( $(date +%s) - gt )) -le "$GR" ]; then
      wait_msg="⏳ 자동 검사가 아직 등록되지 않았습니다(PR #$pn — 방금 올렸으면 곧 등록됩니다)"
    elif [ "$cn" = 0 ] || [ "$cok" = 0 ]; then
      no "⛔ PR #$pn 에 통과한 자동 검사가 없습니다 — 검사 없이는 여기서 합치지 않습니다. 사람이 GitHub 화면·터미널에서 합쳐 주세요"
    fi
  fi
  # 초록 두 번 연속(F2): 처음 본 초록은 기억만 하고 한 번 더 조회 — 검사 이름 집합·PR 머리가 같고 다시 전부 초록일 때만 나간다
  cf_conf=0
  if [ -z "$wait_msg" ]; then
    cset=$(printf '%s' "$clist" | sort)
    [ "$cf_have" = 1 ] && [ "$cset" = "$cf_set" ] && [ "$poid" = "$cf_oid" ] && break
    if [ "$cf_have" = 1 ]; then wait_msg="⏳ 검사 목록이 바뀌었습니다 — 다시 확인합니다"
    else wait_msg="⏳ 자동 검사가 모두 초록입니다 — 한 번 더 확인하려고 같은 명령을 다시 실행합니다"; cf_conf=1
    fi
    cf_have=1; cf_set=$cset; cf_oid=$poid
  else
    cf_have=0
  fi
  # 다음 조회를 시작할 시각이 창(시작 뒤 WIN 초) 안일 때만 기다렸다 다시 조회(창이 0 이면 다시 조회하지 않는다)
  #   단 처음 본 초록 다음의 확인 조회 1번(한 호출에 한 번)은 창 확인을 면제한다(재검사 A2·C2 🟠 — gh 조회가 느려 첫 조회가 창 끝 가까이
  #   끝나면 매 호출이 "한 번 더 확인"(3)만 되풀이해 영영 못 합쳤다). 그 확인 조회가 다시 기다림이면 그때부터는 창 규칙 그대로
  if [ "$cf_conf" = 1 ] && [ "$cf_free" = 1 ] && [ "$WIN" -gt 0 ]; then
    cf_free=0
  else
    [ $((SECONDS - t0 + IVL)) -lt "$WIN" ] || again "$wait_msg"
  fi
  # 간격은 1초씩 쉬며 매초 입력 감시(0.3.7)
  iw=0
  while [ "$iw" -lt "$IVL" ]; do sleep 1; watch_input; iw=$((iw + 1)); done
done

# ── S15·S16 기본 가지에 PR 이 모르는 새 커밋이 들어왔나(GitHub 쪽 기준 — 로컬 참조는 옛 것일 수 있다) ──
watch_input
(cd "$proj" && rl_bounded "$CL" gh api "repos/{owner}/{repo}/compare/$bname...$poid" --jq .behind_by) >"$mtmp/o" 2>"$mtmp/e"; crc=$?
cb=$(< "$mtmp/o")
if [ "$crc" != 0 ] || ! [[ $cb =~ ^[0-9]+$ ]]; then
  case "$crc" in 124|142) GE="${CL}초 안에 끝나지 않음" ;; 0) GE="응답 형식이 예상과 다름" ;; *) gh_err ;; esac
  again "⚠️ 기본 가지와 PR 을 비교하지 못했습니다: $GE"
fi
[ "$cb" = 0 ] || no "⛔ 기본 가지($bname)에 새 커밋 ${cb}개가 들어와 있습니다 — GitHub PR 화면의 Update branch(또는 사람이 확인) → 검사가 다시 초록 → Claude 에게 \"작업 가지 최신 내용 받아 와\" → 다시 /refactor:approve 합치기"

# ── S17 합치기 — 허락을 먼저 지운 뒤, 확인한 머리 커밋일 때만(--match-head-commit). 그 밖의 옵션은 붙이지 않는다 ──
# 되풀이 조회 사이에 사람이 새로 입력했으면(입력 훅이 허락을 지우거나 새 허락으로 바꿈) 합치지 않는다(0.3.5 보완 F9 — I6).
#   바뀐 허락은 사람이 새로 만든 것이라 지우지 않는다(그 차례의 실행이 쓴다)
r1=""; r2=""
[ -f "$mf" ] && { IFS= read -r r1; IFS= read -r r2; } < "$mf"
r1=${r1%$'\r'}; r2=${r2%$'\r'}
if [ ! -f "$mf" ] || [ "$r1" != "$g1" ] || [ "$r2" != "$g2" ]; then
  say "⛔ 허락이 사라졌거나 바뀌었습니다(사용자가 새로 입력함) — 합치지 않았습니다"
  # 바뀐 경우는 새 허락이 남아 있다(지우지 않음) → 꼬리도 그에 맞게(재검사 A2 🟢). 사라진 경우는 거절 꼬리 그대로
  if [ -f "$mf" ]; then say "   (새 허락은 그대로입니다 — 같은 명령을 그대로 다시 실행하세요.)"
  else say "   (합치지 않았습니다 — 허락은 끝났습니다. 다시 하려면 사용자가 /refactor:approve 합치기)"
  fi
  exit 1
fi
# 0.3.7: 합치기 바로 전에 한 번 더 입력 감시(비교하는 동안 친 말도 여기서 걸린다)
watch_input
drop
if [ -e "$mf" ]; then
  say "⚠️ 합치기 허락 파일을 지우지 못해 합치지 않았습니다 — 사람이 확인해 주세요: $mf"
  exit 1
fi
(cd "$proj" && rl_bounded "$ML" gh pr merge "$pn" "--$mth" --match-head-commit "$poid") >"$mtmp/o" 2>"$mtmp/e"; mrc=$?
if [ "$mrc" != 0 ]; then
  case "$mrc" in
    124|142) say "⚠️ 합치기 요청이 ${ML}초 안에 끝나지 않았습니다 — 합쳐졌는지 알 수 없습니다. gh pr view $pn --json state,mergedAt 로 확인하세요"
             say "   (허락은 끝났습니다.)"; exit 1 ;;
  esac
  gh_err
  no "⛔ gh 가 합치기를 거절했습니다: $GE — 합쳐지지 않았습니다" "$MG_AUTH"
fi
say "✅ 합쳤습니다: PR #$pn ($br → $bname, $mth)"
say "   ⚠️ 기본 가지에 합쳐지면 운영 배포가 시작될 수 있습니다 — 배포 확인을 Claude 에게 부탁하세요"
# ── S20 바로 /refactor:approve 새 가지 를 칠 수 있게 기본 가지를 받아 온다(시간이 남을 때만 · 실패해도 알림만) ──
if [ $((SECONDS - t0)) -le "$FB" ]; then
  if rl_bounded "$FL" "${G[@]}" fetch -q origin "$bname" >/dev/null 2>&1; then say "   (origin/$bname 을 받아 왔습니다.)"
  else say "   (origin/$bname 을 받아 오지 못했습니다 — 새 가지 전에 Claude 에게 '최신 내용 받아 와'라고 하세요.)"
  fi
else
  say "   (시간이 모자라 origin/$bname 을 받아 오지 않았습니다 — 새 가지 전에 Claude 에게 '최신 내용 받아 와'라고 하세요.)"
fi
say "다음 묶음: /refactor:approve 새 가지"
exit 0
