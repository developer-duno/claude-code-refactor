#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Vibe Refactor — 승인 스크립트 (/refactor:approve 전용)
#
# 사용자가 입력창에 /refactor:approve 를 치면 입력 훅(turn.sh)이 --from-hook 을 붙여 실행한다 — 승인은 여기서만 처리된다.
# 스킬의 ! 명령(훅보다 먼저 돈다)도 이 스크립트를 부르지만 --from-hook 이 없으므로 아무것도 바꾸지 않고 현황만 보여 준다.
# Claude가 직접 부르는 것은 안전장치 훅이 막는다. 사용자가 입력한 인자는 표준입력으로 받는다(셸 주입 방지).
#   $1 = 프로젝트 폴더, $2 = --from-hook (입력 훅이 부를 때만)
#   표준입력 = 인자 (예: "P0-1 P1-2" / "P1" / "baseline" / "보류 P1-2" / "확인" / "마무리" / "허용 P1-1" / "허용 닫기" / "푸시" /
#              "새 가지" / "새 가지 refactor/hotfix-1" / "합치기" / "합치기 68 rebase" / 비움=현황)
#   환경변수 REFACTOR_TURN_SID = 입력 훅이 넘기는 세션 ID("푸시"의 허락 파일 이름에 쓴다)
# "허용"(0.3.3)은 승인된 🛠 단계의 기준선 허용 파일(.allow-baseline-edit)에 단계 ID 를 적는다.
#   0.3.4 부터는 승인할 때도 🛠 카드의 기준선 칸에 백틱 경로가 있으면 같은 루틴으로 자동으로 적는다(보류하면 뺀다 · 🔧·종류 칸 없는 카드는 안 연다) — '허용'은 닫은 뒤 다시 열 때 쓴다.
# "새 가지"(0.3.4)는 지금 가지의 내용이 origin/<기본 가지> 에 다 들어 있을 때 거기서 새 작업 가지를 만들어 옮긴다(네트워크 없음).
# "합치기"(0.3.4)는 지금 가지의 PR 을 gh 로 확인(열림·검사 초록·기본 가지에 새 커밋 없음 등)한 뒤 합친다 — 승인 모드 중 유일하게 네트워크를 쓴다.
# "허용 닫기"는 그 파일을 지운다(기록에 줄을 남기지 않는다 — 닫는 쪽은 안전한 방향이고, 마무리 뒤에 닫아도 "마지막 줄 = 마무리"가 그대로).
# "푸시"(0.3.3)는 지금 작업 가지를 이번 차례에만 올리도록 허락하는 표시(docs/refactor/.turn-push.<세션ID>)를 만든다(기본 가지는 거절).
# --from-hook 이 없으면 인자가 있어도 파일을 하나도 바꾸지 않고, 안내 한 줄 + 현황을 출력하고 exit 0.
# 인자 없는 현황 보기도 파일을 바꾸지 않는다.
# 승인 기록을 남길 때마다 기록의 지문을 approved/.log-sum 에 봉인한다. 기록이 이 스크립트 밖에서 바뀌면(봉인과 다르면)
# 실행 대기가 비워지고, 사람이 git diff 로 확인한 뒤 "확인"을 입력해야 다시 봉인된다.
# "마무리"는 실행 대기 단계가 없을 때 리팩토링을 끝낸다(STATE를 DONE으로 — 이 기록이 있어야 안전장치가 DONE을 인정).
#
# 승인의 근거는 docs/refactor/APPROVALS.log 에 남기는 한 줄(단계 ID + 카드 지문)이다.
# 계획서의 체크 표시는 사람이 보기 좋게 옮겨 적을 뿐이며, 승인한 카드의 승인 줄만 표준 모양으로 다시 쓴다.
# 항상 exit 0 — ! 명령이 0 이 아닌 코드로 끝나면 스킬 호출 전체가 취소되므로, 문제는 메시지로 알린다.
# ─────────────────────────────────────────────────────────────────────────────

LC_ALL=C
export LC_ALL
set -f

proj=${1:-$PWD}
proj=${proj//"\\"//}
proj=${proj%/}
from_hook=0
[ "${2:-}" = "--from-hook" ] && from_hook=1
IFS= read -r -d '' raw || true
raw=${raw//,/ }
raw=${raw//$'\r'/ }
raw=${raw//$'\n'/ }

dir="$proj/docs/refactor"
plan="$dir/REFACTOR_PLAN.md"
base="$dir/BASELINE.md"
state="$dir/STATE.md"
log="$dir/APPROVALS.log"

say() { printf '%s\n' "$*"; }

root=${REFACTOR_ROOT:-}
[ -z "$root" ] && case "${BASH_SOURCE[0]}" in */*) root="${BASH_SOURCE[0]%/*}/.." ;; esac
lib="$root/scripts/refactor-lib.sh"
if [ -z "$root" ] || [ ! -f "$lib" ]; then
  say "⚠️ 승인 도구 파일(refactor-lib.sh)을 찾지 못해 아무것도 바꾸지 않았습니다. 플러그인을 다시 설치해 주세요."
  exit 0
fi
# 외부 명령 없이 읽는다(tr 대신 내장 read — 입력 훅 안에서 돌므로 외부 명령 수가 곧 걸리는 시간이다)
libsrc=""; IFS= read -r -d '' libsrc < "$lib" || :
eval "${libsrc//$'\r'/}"; unset libsrc
US=$RL_US
now=$(rl_now)
RL_TODAY=${now%% *}   # 날짜는 이 한 번으로 정한다(라이브러리의 다시 쓰기 함수도 이 값을 쓴다)

if [ ! -d "$dir" ]; then
  say "❓ 이 폴더에는 리팩토링 기록(docs/refactor)이 없습니다: $proj"
  say "   먼저 /refactor:go 로 시작하세요."
  exit 0
fi

# ── 입력 훅 밖(스킬의 ! 명령 등)에서는 아무것도 바꾸지 않는다: 인자를 버리고 현황만 ────────────
if [ "$from_hook" != 1 ]; then
  case "$raw" in *[![:space:]]*)
    say "ℹ️ 승인 처리는 사용자가 입력창에 /refactor:approve 를 칠 때 입력 훅이 합니다 — 결과는 같은 턴의 '[Vibe Refactor 승인 처리 결과]' 블록에 나옵니다"
    say "   (아래는 처리 전일 수 있는 현황입니다. 이 실행은 아무것도 바꾸지 않았습니다.)"
    say "" ;;
  esac
  raw=""
fi
# 파일을 바꿔도 되는 실행인가: 입력 훅이 부르고 인자가 있을 때만(인자 없는 현황 보기는 읽기만)
rw=0
case "$raw" in *[![:space:]]*) rw=1 ;; esac

# ── 인자 해석 ────────────────────────────────────────────────────────────────
# '보류'는 맨 앞에만 쓴다(P1-1 보류 P1-2 처럼 섞으면 무엇을 보류하려는지 모호하므로 거절).
mode="approve"; want_base=0; ids=""; phases=""; bad=""; pos=0; conflict=""; special=""; close=0
# 0.3.4: '새 가지'(mode=branch — nbw=1 은 '새' 다음 '가지'를 기다림, nbname = 붙인 이름 원문, nbn = 이름 낱말 수)
#        '합치기'(mode=merge — mprn = PR 번호, mth = 방식, mnn·mmn = 번호·방식 낱말 수)
nbw=0; nbname=""; nbn=0; mprn=""; mth=""; mnn=0; mmn=0
# 영문 소문자만 대문자로(tr '[:lower:]' '[:upper:]' 를 LC_ALL=C 에서 쓴 것과 같게, 외부 명령 없이)
upper_ascii() {
  local s=$1 o="" c lo=abcdefghijklmnopqrstuvwxyz UP=ABCDEFGHIJKLMNOPQRSTUVWXYZ p i
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case "$c" in [a-z]) p=${lo%%"$c"*}; c=${UP:${#p}:1} ;; esac
    o=$o$c
  done
  UPV=$o
}
for tok in $raw; do
  t_=${tok//[;.()\[\]]/}
  upper_ascii "$t_"; up=$UPV
  [ -z "$up" ] && continue
  pos=$((pos + 1))
  case "$up" in
    BASELINE|기준선|기준선계획) want_base=1 ;;
    HOLD|보류|취소|CANCEL|UNDO)
      if [ "$pos" = 1 ]; then mode="hold"; else conflict="'$tok'은(는) 맨 앞에만 쓸 수 있습니다"; fi ;;
    APPROVE|승인)
      if [ "$pos" != 1 ]; then conflict="'$tok'은(는) 맨 앞에만 쓸 수 있습니다"; fi ;;
    ALLOW|허용)
      if [ "$pos" = 1 ]; then mode="allow"; else conflict="'$tok'은(는) 맨 앞에만 쓸 수 있습니다"; fi ;;
    CLOSE|닫기)
      if [ "$pos" = 2 ] && [ "$mode" = "allow" ]; then close=1; else conflict="'$tok'은(는) '허용' 바로 뒤에만 쓸 수 있습니다(예: /refactor:approve 허용 닫기)"; fi ;;
    PUSH|푸시)
      if [ "$pos" = 1 ]; then mode="push"; else conflict="'$tok'은(는) 단독으로만 쓸 수 있습니다(예: /refactor:approve 푸시)"; fi ;;
    새가지|NEWBRANCH)
      if [ "$pos" = 1 ]; then mode="branch"; else conflict="'$tok'은(는) 맨 앞에만 쓸 수 있습니다(예: /refactor:approve 새 가지)"; fi ;;
    새|NEW)
      if [ "$pos" = 1 ]; then nbw=1; else conflict="'$tok'은(는) 맨 앞에만 쓸 수 있습니다(예: /refactor:approve 새 가지)"; fi ;;
    가지|BRANCH)
      if [ "$pos" = 2 ] && [ "$nbw" = 1 ]; then mode="branch"; nbw=0; else conflict="'$tok'은(는) '새' 바로 뒤에만 쓸 수 있습니다(예: /refactor:approve 새 가지)"; fi ;;
    합치기|MERGE)
      if [ "$pos" = 1 ]; then mode="merge"
      elif [ "$mode" = "merge" ] && [ "$up" = MERGE ]; then mth=merge; mmn=$((mmn + 1))
      else conflict="'$tok'은(는) 맨 앞에만 쓸 수 있습니다(예: /refactor:approve 합치기)"; fi ;;
    확인|CONFIRM|SEAL) special=confirm ;;
    마무리|DONE|FINISH|끝|완료) special=done ;;
    ALL|전체|모두) bad="$bad $tok(전체 승인은 지원하지 않음 — P0·P1 같은 묶음이나 단계 번호로)" ;;
    *)
      if [[ $up =~ ^P[0-9]+-[0-9]+[A-Z]?$ ]]; then case " $ids " in *" $up "*) ;; *) ids="$ids $up" ;; esac
      elif [[ $up =~ ^P[0-9]+$ ]]; then phases="$phases $up"
      elif [ "$mode" = "branch" ]; then nbname=$tok; nbn=$((nbn + 1))   # 이름은 원문 그대로(대문자로 바꾸거나 .;()[] 를 지우기 전)
      elif [ "$mode" = "merge" ]; then
        case "$up" in
          REBASE|리베이스) mth=rebase; mmn=$((mmn + 1)) ;;
          SQUASH|스쿼시) mth=squash; mmn=$((mmn + 1)) ;;
          병합) mth=merge; mmn=$((mmn + 1)) ;;
          *) if [[ $up =~ ^#?[0-9]{1,7}$ ]]; then mprn=$((10#${up#\#})); mnn=$((mnn + 1)); else bad="$bad $tok"; fi ;;
        esac
      else bad="$bad $tok"
      fi ;;
  esac
done
# '푸시'는 단독으로만, '허용 닫기'는 뒤에 아무것도 없이, '허용'은 단계 번호하고만(기준선 계획·확인·마무리와 섞지 않음)
if [ -z "$conflict" ]; then
  if [ "$mode" = "push" ] && [ "$pos" -gt 1 ]; then conflict="'푸시'는 단독으로 입력하세요(뒤에 아무것도 붙이지 않습니다)"
  elif [ "$close" = 1 ] && [ "$pos" -gt 2 ]; then conflict="'허용 닫기' 뒤에는 아무것도 붙이지 않습니다"
  elif [ "$mode" = "allow" ] && { [ "$want_base" = 1 ] || [ -n "$special" ]; }; then conflict="'허용'은 단계 번호하고만 함께 씁니다(baseline·확인·마무리와 섞지 않음)"
  elif [ "$nbw" = 1 ]; then conflict="'새'는 '새 가지'로만 씁니다(예: /refactor:approve 새 가지)"
  elif [ "$mode" = "branch" ] && { [ -n "$ids$phases" ] || [ "$want_base" = 1 ] || [ -n "$special" ]; }; then conflict="'새 가지'는 단계 번호·baseline·확인·마무리와 섞지 않습니다(뒤에는 가지 이름 하나만)"
  elif [ "$mode" = "branch" ] && [ "$nbn" -gt 1 ]; then conflict="'새 가지' 뒤에는 가지 이름을 하나만 붙입니다(예: /refactor:approve 새 가지 refactor/hotfix-1)"
  elif [ "$mode" = "merge" ] && { [ -n "$ids$phases" ] || [ "$want_base" = 1 ] || [ -n "$special" ]; }; then conflict="'합치기'는 단계 번호·baseline·확인·마무리와 섞지 않습니다(뒤에는 PR 번호와 방식만)"
  elif [ "$mode" = "merge" ] && { [ "$mnn" -gt 1 ] || [ "$mmn" -gt 1 ]; }; then conflict="'합치기' 뒤에는 PR 번호 하나와 방식(rebase·squash·merge) 하나까지만 붙입니다(예: /refactor:approve 합치기 68 rebase)"
  fi
fi

say "== /refactor:approve 결과 ($now KST) =="
if [ -n "$conflict" ]; then
  say "❓ $conflict — 아무것도 바꾸지 않았습니다."
  say "   승인: /refactor:approve P1-1 P1-2    ·    승인 취소: /refactor:approve 보류 P1-2"
  say "   기준선 허용: /refactor:approve 허용 P1-1    ·    허용 닫기: /refactor:approve 허용 닫기    ·    올리기 허락: /refactor:approve 푸시"
  say "   PR 합치기: /refactor:approve 합치기 68 rebase    ·    합친 뒤 새 작업 가지: /refactor:approve 새 가지"
  exit 0
fi
[ -n "$bad" ] && say "❓ 알아듣지 못한 입력:$bad"
if [ "$mode" = "approve" ]; then act_word="승인"; else act_word="보류"; fi
if [ -n "$special" ] && { [ -n "$ids$phases" ] || [ "$want_base" = 1 ] || [ "$mode" = "hold" ]; }; then
  say "❓ '확인'·'마무리'는 단독으로 입력하세요(예: /refactor:approve 확인). 아무것도 바꾸지 않았습니다."
  exit 0
fi

set_state_front() { # $1 awk 변수 이름=값들 — STATE.md 앞머리 칸 갱신
  [ -f "$state" ] || return 0
  local tmp="$state.tmp.$$"
  awk "$@" '
    NR == 1 && $0 ~ /^---/ { fm = 1; print; next }
    fm && $0 ~ /^---/ { fm = 0; print; next }
    fm && A != "" && $0 ~ /^steps_approved:/ { print "steps_approved: " A; next }
    fm && D != "" && $0 ~ /^steps_done:/ { print "steps_done: " D; next }
    fm && T != "" && T > 0 && $0 ~ /^steps_total:/ { print "steps_total: " T; next }
    fm && N != "" && $0 ~ /^next:/ { print "next: \"" N "\""; next }
    fm && U != "" && $0 ~ /^updated:/ { print "updated: " U; next }
    { print }
  ' "$state" > "$tmp" && [ -s "$tmp" ] && mv "$tmp" "$state"
  if [ -e "$tmp" ]; then rm -f "$tmp"; fi
}

# rl_card_bl_paths -n 의 출력(BLP)에서 카드 순번 $1(본문 파일 c<순번>)의 기준선 경로 → BLV = "`a` `b`" / "?"(칸에 글은 있는데 백틱 경로 0) / ""(칸 없음·"없음")
BLP=""
bl_of() {
  local rest="$BLP$RL_NL" line f p
  BLV=""
  while [ -n "$rest" ]; do
    line=${rest%%"$RL_NL"*}; rest=${rest#*"$RL_NL"}
    f=${line%%"$RL_TAB"*}; p=${line#*"$RL_TAB"}
    [ "$f" = "c$1" ] && [ "$f" != "$line" ] || continue
    if [ "$p" = "?" ]; then BLV="?"; else BLV="$BLV \`$p\`"; fi
  done
  BLV=${BLV# }
}

# 기준선 허용 파일 쓰기 — '허용 <ID>'(0.3.3)와 승인하면 자동 허용(0.3.4)이 같이 쓰는 루틴.
#   $1 = 더할 ID 들, $2 = 지금 허용 대상인 ID 들(파일에 있던 ID 중 이것만 남긴다 — 나머지는 AW_DROPPED)
#   허용 파일 = (지금 파일의 ID 중 $2 에 있는 것) ∪ ($1) 한 줄(임시 파일 → mv). 빈 파일(공백만 = 기준선 전부 허용)이었으면 이 목록으로 좁혀진다(AW_NARROWED=1)
#   바뀔 때만 써서 기록에 "허용" 줄(지문 칸 "-" — 승인 상태 계산은 이 줄을 건너뜀) + 봉인 → AW_WROTE=1. 쓰기 실패면 1(기록 안 바뀜)
af="$dir/.allow-baseline-edit"
allow_write() {
  local x
  AW_HAD=0; AW_NARROWED=0; AW_OLD=""; AW_NEW=""; AW_DROPPED=""; AW_WROTE=0
  if [ -f "$af" ]; then AW_HAD=1; AW_OLD=$(rl_allow_ids "$dir"); [ -z "$AW_OLD" ] && AW_NARROWED=1; fi
  for x in $AW_OLD; do
    [ "$x" = "?" ] && continue
    case " $2 " in
      *" $x "*) case " $AW_NEW " in *" $x "*) ;; *) AW_NEW="$AW_NEW $x" ;; esac ;;
      *) AW_DROPPED="$AW_DROPPED $x" ;;
    esac
  done
  for x in $1; do case " $AW_NEW " in *" $x "*) ;; *) AW_NEW="$AW_NEW $x" ;; esac; done
  AW_NEW=${AW_NEW# }
  [ "$AW_HAD" = 1 ] && [ "$AW_OLD" = "$AW_NEW" ] && return 0
  if ! { printf '%s\n' "$AW_NEW" > "$af.tmp.$$" && mv -f "$af.tmp.$$" "$af"; }; then
    rm -f "$af.tmp.$$"; return 1
  fi
  printf '%s KST | 허용 | %s | - | 사용자가 /refactor:approve 로 실행\n' "$now" "$AW_NEW" >> "$log"
  rl_log_seal "$dir"
  AW_WROTE=1
}
allow_notes() {   # allow_write 뒤의 알림 두 줄(좁힘 · 뺀 ID)
  [ "$AW_NARROWED" = 1 ] && [ "$AW_OLD" != "$AW_NEW" ] && say "   (빈 허용 파일 — 기준선 전부 허용 — 이었는데 이 단계들로 좁혔습니다.)"
  [ -n "$AW_DROPPED" ] && say "   (허용 파일에 있던${AW_DROPPED} 은(는) 지금 허용 대상이 아니라 뺐습니다.)"
  return 0
}

# ── 기준선 허용 닫기(0.3.3): 허용 파일을 지운다. 닫는 쪽은 안전한 방향이라 봉인이 깨져 있어도 하고, 기록에는 남기지 않는다 ──
if [ "$close" = 1 ]; then
  if [ -f "$dir/.allow-baseline-edit" ]; then
    rm -f "$dir/.allow-baseline-edit"
    if [ -f "$dir/.allow-baseline-edit" ]; then say "⚠️ 기준선 허용 파일(.allow-baseline-edit)을 지우지 못했습니다 — 터미널에서 rm \"$dir/.allow-baseline-edit\""
    else say "🔒 기준선 허용을 닫았습니다(.allow-baseline-edit 를 지움). 이제 기준선 테스트는 고칠 수 없습니다."
    fi
  else
    say "ℹ️ 기준선 허용은 이미 닫혀 있습니다(.allow-baseline-edit 없음)."
  fi
  exit 0
fi

# ── 승인 기록 봉인 확인 ──────────────────────────────────────────────────────
intact=1
rl_log_intact "$dir" || intact=0
if [ "$special" = "confirm" ]; then
  if [ ! -f "$log" ]; then say "ℹ️ 승인 기록이 아직 없습니다."; exit 0; fi
  rl_log_seal "$dir"
  if [ "$intact" = 1 ]; then say "ℹ️ 승인 기록은 이미 봉인과 일치합니다."; else say "✅ 사람이 확인한 지금의 승인 기록을 봉인했습니다. 이제 기록에 있는 승인이 다시 인정됩니다."; fi
  say "   (이 기록이 그대로 인정됩니다: docs/refactor/APPROVALS.log — 모르는 줄이 있었다면 먼저 지우고 다시 '확인'하세요)"
  exit 0
fi
if [ "$intact" = 0 ]; then
  chg=$(rl_log_changes "$dir")
  if [ "$chg" = "NOSEAL" ]; then
    say "⏸ 승인 기록에 봉인이 없습니다(이전 버전에서 시작한 프로젝트). 기록을 한 번 훑어본 뒤 /refactor:approve 확인 을 입력하세요(한 번만)."
  else
    say "⛔ 승인 기록(APPROVALS.log)이 /refactor:approve 밖에서 바뀌었습니다(봉인과 다름). 확인 전까지 어떤 단계도 실행 대기로 보지 않습니다. 봉인 뒤 달라진 줄:"
    say "$chg"
    say "   👤 직접 한 승인이 아니면 그 줄을 지운 뒤 /refactor:approve 확인 을 입력하세요."
  fi
  if [ -n "$ids$phases$special" ] || [ "$want_base" = 1 ] || [ "$mode" = "allow" ] || [ "$mode" = "push" ] || [ "$mode" = "branch" ] || [ "$mode" = "merge" ]; then say "   (그래서 이번 요청은 처리하지 않았습니다.)"; exit 0; fi
fi

# ── 푸시 허락(0.3.3): 이번 차례에만 작업 가지를 올려도 된다는 표시 docs/refactor/.turn-push.<세션ID> ─────────
#   2줄: "push <가지>" / 만든 시각(초). 입력 훅이 그 세션의 다음 사람 입력 때 지우고, 안전장치는 30분이 지난 것을 무시한다.
#   기본 가지(main·master·origin/HEAD 가 가리키는 가지)·떨어진 HEAD·git 저장소 밖·마무리 확인 뒤는 거절(아무것도 안 씀)
if [ "$mode" = "push" ]; then
  if rl_done_confirmed "$dir"; then
    say "ℹ️ 이미 마무리되어 안전장치가 꺼져 있습니다 — 허락 없이 올릴 수 있습니다(아무것도 바꾸지 않았습니다)."
    exit 0
  fi
  psid=${REFACTOR_TURN_SID:-}
  if ! [[ $psid =~ ^[A-Za-z0-9_-]{1,128}$ ]]; then
    say "⚠️ 대화(세션) 정보를 받지 못해 push 허락을 만들지 않았습니다 — 입력창에 /refactor:approve 푸시 를 다시 쳐 주세요."
    exit 0
  fi
  br=$(git -C "$proj" symbolic-ref -q --short HEAD 2>/dev/null); grc=$?
  if [ "$grc" -gt 1 ]; then
    say "❓ 이 폴더는 git 저장소가 아니라(또는 git 이 저장소 설정을 읽지 못해) push 허락을 만들지 않았습니다: $proj"; exit 0
  fi
  if [ "$grc" = 1 ] || [ -z "$br" ]; then
    say "❓ 지금 가지가 없습니다(특정 커밋에 떨어진 상태) — 작업 가지로 옮긴 뒤 다시 입력하세요. push 허락을 만들지 않았습니다."; exit 0
  fi
  # 안전장치가 허락 파일을 읽는 조건과 같게: 첫 글자는 영문·숫자·_, 나머지는 영문·숫자·._/-
  if ! [[ $br =~ ^[A-Za-z0-9._/-]+$ ]]; then
    say "❓ 가지 이름($br)에 영문·숫자·._/- 밖의 글자가 있어 push 허락을 만들지 않았습니다 — 사람이 터미널에서 올려 주세요."; exit 0
  fi
  if ! [[ $br =~ ^[A-Za-z0-9_] ]]; then
    say "❓ 이 가지 이름($br)은 허락할 수 없습니다(첫 글자가 - . / 임) — 사람이 터미널에서 올려 주세요."; exit 0
  fi
  defb=""
  case "$br" in
    main|master) defb=$br ;;
    *) ob=$(git -C "$proj" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null); [ "${ob#origin/}" = "$br" ] && [ -n "$ob" ] && defb=$br ;;
  esac
  if [ -n "$defb" ]; then
    say "⛔ 기본 가지는 올리지 않습니다 — 작업 가지에서(지금 가지: $br). push 허락을 만들지 않았습니다."
    say "   기본 가지 올리기와 PR 합치기는 사람이 터미널에서 합니다."
    exit 0
  fi
  # 안전장치가 허락 push 를 통과시키는 저장소 설정인지 먼저 본다(허락을 내 놓고 안전장치가 막는 헛걸음 방지 — git 1회, 주소 값은 출력하지 않음):
  #   origin 주소 없음 · remote.origin.push(올리기 규칙) 있음 · push.default 가 upstream/tracking(지금 가지가 따라가는 원격 가지로 올라감) 이면 거절
  pc=$(git -C "$proj" config --get-regexp '^(remote[.]origin[.](url|push)|push[.]default)$' 2>/dev/null)
  pwhy=""; has_url=0
  while IFS= read -r x; do
    k=${x%% *}; v=${x#"$k"}; v=${v# }
    case "$k" in
      remote.origin.url) has_url=1 ;;
      remote.origin.push) pwhy="원격에 올리기 규칙(remote.origin.push)이 설정돼 있음" ;;
      push.default) upper_ascii "$v"; case "$UPV" in UPSTREAM|TRACKING) pwhy="push.default 가 $v 임(따라가는 원격 가지로 올라감)" ;; esac ;;
    esac
  done <<EOF
$pc
EOF
  [ -z "$pwhy" ] && [ "$has_url" = 0 ] && pwhy="origin 원격 주소가 없음"
  if [ -n "$pwhy" ]; then
    say "⛔ 푸시 허락으로는 올릴 수 없는 저장소 설정입니다($pwhy) — 사람이 터미널에서 올립니다. push 허락을 만들지 않았습니다."
    exit 0
  fi
  ep=$(date +%s)
  pf="$dir/.turn-push.$psid"
  if ! { printf 'push %s\n%s\n' "$br" "$ep" > "$pf.tmp.$$" && mv -f "$pf.tmp.$$" "$pf"; }; then
    rm -f "$pf.tmp.$$"; say "⚠️ push 허락 파일을 쓰지 못했습니다(아무것도 바꾸지 않았습니다)."; exit 0
  fi
  printf '%s KST | 푸시 | %s | - | 사용자가 /refactor:approve 로 실행\n' "$now" "$br" >> "$log"
  rl_log_seal "$dir"
  say "✅ push 허락: 작업 가지 $br 를 이번 차례에만 올릴 수 있습니다(다음 입력부터 다시 막힘 · 30분 안). 올리는 명령: git push -u origin $br"
  # 무엇이 올라가는지: 원격 origin 에 아직 없는 커밋(최근 것부터 최대 5줄) · 커밋 안 된 변경 수(리팩토링 기록 docs/refactor 는 빼고 — 승인 기록이 방금 바뀌므로)
  pl=$(git -C "$proj" log --oneline --no-decorate --no-color HEAD --not --remotes=origin 2>/dev/null)
  pn=0; pshow=""
  while IFS= read -r x; do
    [ -n "$x" ] || continue
    pn=$((pn + 1)); [ "$pn" -le 5 ] && pshow="$pshow     $x$RL_NL"
  done <<EOF
$pl
EOF
  if [ "$pn" = 0 ]; then say "   (올릴 새 커밋이 없습니다)"; else say "   올라갈 커밋 ${pn}개:"; printf '%s' "$pshow"; fi
  dn=0
  while IFS= read -r x; do [ -n "$x" ] && dn=$((dn + 1)); done <<EOF
$(git -C "$proj" status --porcelain -- . ':!docs/refactor' 2>/dev/null)
EOF
  [ "$dn" -gt 0 ] && say "   ⚠️ 커밋 안 된 변경 ${dn}개는 올라가지 않습니다."
  say "   기본 가지 올리기·강제 push·PR 합치기는 계속 막힙니다."
  exit 0
fi

# git 호출 방어(안전장치 guard.sh br_judge_in 과 같게): 대체 객체 무시 · fsmonitor 끔 · 합칠 때 renormalize 끔
G=(git --no-replace-objects -c core.fsmonitor=false -c merge.renormalize=false -C "$proj")

# ── 새 작업 가지(0.3.4): origin/<기본 가지> 에서 새 가지를 만들어 옮긴다 — 지금 위치의 내용이 기본 가지에 다 들어 있을 때만 ──
#   네트워크는 쓰지 않는다(받아 오기는 Claude 가 — 로컬의 origin/<기본> 참조만 본다). 안전장치에는 예외가 없다(Claude 의 git switch 는 계속 막힘)
#   커밋 안 된 변경은 막지 않는다(새 위치와 부딪히면 git 이 스스로 거절). 기록 줄은 4번째 칸이 "-" 라 승인 상태 계산에 영향 없음
if [ "$mode" = "branch" ]; then
  nb_no() { say "$1 — 새 가지를 만들지 않았습니다(아무것도 바꾸지 않았습니다)."; exit 0; }
  [ -n "$bad" ] && nb_no "   예: /refactor:approve 새 가지  ·  이름을 붙이려면 /refactor:approve 새 가지 refactor/hotfix-1"
  if rl_done_confirmed "$dir"; then
    say "ℹ️ 이미 마무리되어 안전장치가 꺼져 있습니다 — 새 가지는 평소처럼 만들 수 있습니다(아무것도 바꾸지 않았습니다)."
    exit 0
  fi
  command -v git >/dev/null 2>&1 || nb_no "❓ git 을 찾지 못했습니다"
  gp=$("${G[@]}" rev-parse --git-path MERGE_HEAD --git-path rebase-merge --git-path rebase-apply --git-path CHERRY_PICK_HEAD \
       --git-path REVERT_HEAD --git-path BISECT_LOG 2>/dev/null) || nb_no "❓ 이 폴더는 git 저장소가 아니라(또는 git 이 저장소 설정을 읽지 못해) 새 가지를 만들 수 없습니다: $proj"
  while IFS= read -r x; do
    [ -n "$x" ] || continue
    case "$x" in /*|[A-Za-z]:*) ;; *) x="$proj/$x" ;; esac
    [ -e "$x" ] && nb_no "❓ 진행 중인 git 작업(합치기·rebase·cherry-pick·revert·bisect)이 있습니다 — 진행 중인 git 작업을 먼저 끝내세요"
  done <<EOF
$gp
EOF
  rl_origin_base "$proj" || nb_no "❓ origin 의 기본 가지를 찾지 못했습니다(origin/HEAD·origin/main·origin/master 참조 없음)"
  bname=$RL_BNAME; boid=$RL_BOID; bsh=${boid:0:7}
  "${G[@]}" cat-file -e "$boid:./docs/refactor/STATE.md" 2>/dev/null \
    || nb_no "⛔ 기본 가지(origin/$bname)에 리팩토링 기록이 없습니다(옮기면 안전장치가 꺼짐)"
  "${G[@]}" diff --quiet --no-ext-diff HEAD "$boid" -- docs/refactor/APPROVALS.log docs/refactor/approved 2>/dev/null \
    || nb_no "⛔ 기본 가지(origin/$bname)의 승인 기록이 지금 가지와 다릅니다"
  ob=$("${G[@]}" symbolic-ref -q --short HEAD 2>/dev/null)
  obs=${ob:-떨어진 HEAD}
  # 붙인 이름은 판정 전에 본다(판정 불가 문구의 터미널 명령에 그 이름을 쓰므로)
  nb=""
  if [ -n "$nbname" ]; then
    nb=$nbname
    if ! [[ $nb =~ ^[A-Za-z0-9_][A-Za-z0-9._/-]*$ ]] || ! "${G[@]}" check-ref-format --branch "$nb" >/dev/null 2>&1; then
      nb_no "❓ 가지 이름($nb)을 쓸 수 없습니다(영문·숫자·._/- 만, 첫 글자는 영문·숫자·_, git 가지 이름 규칙)"
    fi
    # 0.3.4 보완 F6: 참조 이름 꼴·기본 가지 이름은 거절(대소문자 그대로 비교)
    case "$nb" in
      refs/*|origin/*|HEAD|main|master|"$bname")
        nb_no "❓ 가지 이름($nb)을 쓸 수 없습니다(refs/·origin/ 으로 시작하는 이름과 HEAD·main·master·기본 가지 이름 $bname 은 새 작업 가지 이름으로 쓰지 않습니다)" ;;
    esac
  fi
  rl_merged_into "$proj" "$boid"; mrc=$?
  if [ "$mrc" = 1 ]; then
    say "⛔ 지금 가지($obs)의 내용이 아직 origin/$bname 에 다 들어 있지 않습니다 — PR 이 아직 안 합쳐졌거나, 합친 뒤 최신 내용을 안 받아 온 상태입니다. Claude 에게 '최신 내용 받아 와'라고 한 뒤 다시 입력해 주세요."
    say "   (새 가지를 만들지 않았습니다 — 아무것도 바꾸지 않았습니다.)"
    exit 0
  elif [ "$mrc" != 0 ]; then
    # 판정 불가(0.3.4 보완 F3): 까닭 + 사람이 터미널에서 만드는 길
    say "❓ 지금 가지($obs)의 내용이 origin/$bname 에 다 들어 있는지 판정하지 못했습니다: ${RL_MERGED_WHY:-까닭 모름}."
    say "   Claude 에게 '최신 내용 받아 와'라고 한 뒤 다시 입력해 주세요. 받아 온 뒤에도 같으면 PR 이 합쳐진 것을 확인하고 사람이 터미널에서: git switch -c ${nb:-refactor/$RL_TODAY} origin/$bname"
    say "   (새 가지를 만들지 않았습니다 — 아무것도 바꾸지 않았습니다.)"
    exit 0
  fi
  if [ -z "$nb" ]; then
    nb0="refactor/$RL_TODAY"
    have=$("${G[@]}" for-each-ref --format='%(refname)' "refs/heads/$nb0*" "refs/remotes/origin/$nb0*" 2>/dev/null)
    have="$RL_NL$have$RL_NL"
    nb=$nb0; i=1
    while case "$have" in *"${RL_NL}refs/heads/$nb$RL_NL"*|*"${RL_NL}refs/remotes/origin/$nb$RL_NL"*) true ;; *) false ;; esac; do
      i=$((i + 1))
      [ "$i" -gt 99 ] && nb_no "❓ 오늘 날짜의 가지 이름($nb0 ~ $nb0-99)이 모두 쓰이고 있습니다 — 이름을 붙여 다시: /refactor:approve 새 가지 <이름>"
      nb="$nb0-$i"
    done
  fi
  sw=$("${G[@]}" switch --no-track -c "$nb" "$boid" 2>&1); src=$?
  if [ "$src" != 0 ]; then
    e1=""
    while IFS= read -r x; do [ -n "${x//[[:space:]]/}" ] && { e1=$x; break; }; done <<EOF
$sw
EOF
    say "⛔ git 이 새 가지로 옮기지 못했습니다: ${e1:-(오류 문구 없음)}"
    say "   아무것도 바뀌지 않았습니다(지금 가지 $obs 그대로)."
    exit 0
  fi
  cur=$("${G[@]}" symbolic-ref -q --short HEAD 2>/dev/null)
  if [ "$cur" != "$nb" ] || [ ! -f "$state" ] || ! rl_log_intact "$dir"; then
    say "⚠️ 새 가지로 옮겼지만 확인이 맞지 않습니다(지금 가지: ${cur:-없음} · STATE.md $([ -f "$state" ] && echo 있음 || echo 없음) · 승인 기록 봉인 $(rl_log_intact "$dir" && echo 일치 || echo 다름)) — 기록에 줄을 남기지 않았습니다. git status 로 확인해 주세요."
    exit 0
  fi
  # 따라온 커밋 안 된 변경(새 기록 줄을 쓰기 전에 센다)
  dn=0; dshow=""
  while IFS= read -r x; do
    [ -n "$x" ] || continue
    dn=$((dn + 1)); [ "$dn" -le 5 ] && dshow="$dshow, ${x:3}"
  done <<EOF
$("${G[@]}" -c core.quotePath=false status --porcelain -- . 2>/dev/null)
EOF
  printf '%s KST | 새 가지 | %s <- origin/%s@%s | - | 사용자가 /refactor:approve 로 실행\n' "$now" "$nb" "$bname" "$bsh" >> "$log"
  rl_log_seal "$dir"
  if [ -n "$ob" ]; then oldw="지난 가지 $ob 은 그대로 남아 있음"; else oldw="지난 위치(떨어진 HEAD)는 커밋으로 남아 있음"; fi
  say "🌿 새 작업 가지: $nb (origin/$bname $bsh 에서 · $oldw)"
  if [ "$dn" -gt 0 ]; then
    dshow=${dshow#, }; [ "$dn" -gt 5 ] && dshow="$dshow …"
    say "   커밋 안 된 변경 ${dn}개가 그대로 따라왔습니다: $dshow"
  fi
  say "다음: /refactor:go"
  exit 0
fi

# ── PR 합치기(0.3.4): 지금 가지의 PR 을 gh 로 확인한 뒤 합친다 — 승인 모드 중 유일하게 네트워크를 쓴다 ──
#   안전장치의 gh pr merge 차단은 그대로(Claude 는 계속 못 합친다). gh 호출은 셋뿐: pr view(조회) · api compare(기본 가지에 새 커밋?) · pr merge
#   gh 로그인 정보는 다루지 않는다(gh 기본 로그인 그대로). --admin·--auto·--delete-branch 는 어떤 입력으로도 넘기지 않는다(인자는 번호·방식만 받음)
#   입력 훅 제한 30초(turn.sh 가 앞뒤로 하는 일·Windows 의 느린 프로세스 띄우기 몫을 남김): 조회 6 · 비교 5 · 합치기 8초,
#   받아 오기는 그때까지 10초 이하를 썼을 때만(6초). 최악 = 6+5+8(+TERM 을 무시하면 KILL 까지 1초씩) ≈ 22초 · 받아 오기 길 ≈ 11+6+1 = 18초
if [ "$mode" = "merge" ]; then
  mg_no() { say "$1"; say "   (합치지 않았습니다 — 아무것도 바꾸지 않았습니다.)"; exit 0; }
  MG_AUTH="   권한·저장소를 찾지 못함 오류라면: gh 로그인 계정이 이 저장소에 쓰기 권한이 있는지 사람이 확인해 주세요(gh auth status) — 다른 계정이면 사람이 터미널에서 바꾼 뒤 다시 입력"
  [ -n "$bad" ] && mg_no "   예: /refactor:approve 합치기 68 rebase  (PR 번호와 방식 rebase·squash·merge 만 받습니다)"
  if rl_done_confirmed "$dir"; then
    say "ℹ️ 이미 마무리되어 안전장치가 꺼져 있습니다 — 평소처럼 합칠 수 있습니다(아무것도 바꾸지 않았습니다)."
    exit 0
  fi
  t0=$SECONDS
  command -v git >/dev/null 2>&1 || mg_no "❓ git 을 찾지 못했습니다"
  br=$("${G[@]}" symbolic-ref -q --short HEAD 2>/dev/null); grc=$?
  [ "$grc" -gt 1 ] && mg_no "❓ 이 폴더는 git 저장소가 아니라(또는 git 이 저장소 설정을 읽지 못해) 합칠 수 없습니다: $proj"
  { [ "$grc" = 1 ] || [ -z "$br" ]; } && mg_no "❓ 지금 가지가 없습니다(특정 커밋에 떨어진 상태) — 작업 가지로 옮긴 뒤 다시 입력하세요"
  rl_origin_base "$proj" || mg_no "❓ origin 의 기본 가지를 찾지 못했습니다(origin/HEAD·origin/main·origin/master 참조 없음)"
  bname=$RL_BNAME
  [ "$br" = "$bname" ] && mg_no "⛔ 지금 가지가 기본 가지($bname)입니다 — 작업 가지의 PR 만 합칩니다"
  hoid=$("${G[@]}" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null) || mg_no "❓ 지금 커밋을 읽지 못했습니다"
  # 방식: 입력 → 없으면 PROFILE 의 "- PR 합치는 방식:" 칸(앞뒤 공백·백틱만 뗀 값이 rebase·squash·merge 중 하나와 정확히 같을 때만)
  if [ -z "$mth" ] && [ -f "$dir/PROFILE.md" ]; then
    while IFS= read -r x || [ -n "$x" ]; do
      x=${x%$'\r'}
      case "$x" in "- PR 합치는 방식:"*) ;; *) continue ;; esac
      v=${x#"- PR 합치는 방식:"}
      v=${v//\`/}
      v=${v#"${v%%[![:space:]]*}"}; v=${v%"${v##*[![:space:]]}"}
      upper_ascii "$v"
      case "$UPV" in REBASE) mth=rebase ;; SQUASH) mth=squash ;; MERGE) mth=merge ;; esac
      break
    done < "$dir/PROFILE.md"
  fi
  [ -z "$mth" ] && mg_no "❓ 합치는 방식을 모릅니다(docs/refactor/PROFILE.md 의 '- PR 합치는 방식:' 칸이 없거나 비어 있음) — 방식을 붙여 다시: /refactor:approve 합치기 rebase"
  command -v gh >/dev/null 2>&1 || mg_no "❓ gh(GitHub CLI)를 찾지 못했습니다 — 사람이 GitHub 화면이나 터미널에서 합쳐 주세요"
  mtmp=$(mktemp -d 2>/dev/null) || mtmp=$(mktemp -d -t rlmerge 2>/dev/null) || mtmp=""
  [ -n "$mtmp" ] || mg_no "⚠️ 임시 폴더를 만들지 못했습니다"
  trap 'rm -rf "$mtmp"' EXIT
  # gh 의 첫 오류 줄(200자까지) → GE. 제어 문자는 ? 로(0.3.4 보완 F10 — 결과 블록에 터미널 제어 글자가 그대로 실리지 않게)
  gh_err() {
    GE=""
    while IFS= read -r x; do x=${x%$'\r'}; [ -n "${x//[[:space:]]/}" ] && { GE=${x:0:200}; break; }; done < "$mtmp/e"
    GE=${GE//[[:cntrl:]]/?}
    [ -n "$GE" ] || GE="(오류 문구 없음)"
  }
  # gh 호출의 출력·오류는 $( ) 가 아니라 임시 파일로 받는다(0.3.4 보완 F7 — gh 감싸개가 띄운 자식이 출력 통로를 쥐고 남으면
  #   $( ) 는 시간 한도와 상관없이 그 자식이 끝날 때까지 기다린다. 파일이면 한도에서 바로 돌아온다)
  export GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 GIT_TERMINAL_PROMPT=0
  # 1) PR 조회 — 첫 줄 = 번호·상태·초안·포크·기본 가지·머리 가지·머리 커밋·합칠 수 있음, 그다음 줄마다 검사 하나(종류·status·conclusion·state·이름)
  JQV='([.number, .state, .isDraft, .isCrossRepository, .baseRefName, .headRefName, .headRefOid, .mergeable] | map(tostring) | join("\u001f")), ((.statusCheckRollup // [])[] | [(.__typename // "-"), (.status // "-"), (.conclusion // "-"), (.state // "-"), (.name // .context // "-")] | map(tostring) | join("\u001f"))'
  set -- pr view
  [ -n "$mprn" ] && set -- "$@" "$mprn"
  (cd "$proj" && rl_bounded 6 gh "$@" --json number,state,isDraft,isCrossRepository,baseRefName,headRefName,headRefOid,mergeable,statusCheckRollup --jq "$JQV") >"$mtmp/o" 2>"$mtmp/e"; prc=$?
  pv=$(< "$mtmp/o")
  if [ "$prc" != 0 ]; then
    case "$prc" in 124|142) mg_no "⛔ PR 조회가 6초 안에 끝나지 않았습니다 — 잠시 뒤 다시 입력하세요" ;; esac
    gh_err
    say "⛔ PR 을 조회하지 못했습니다: $GE"
    mg_no "$MG_AUTH"
  fi
  first=${pv%%"$RL_NL"*}; rest=""
  case "$pv" in *"$RL_NL"*) rest=${pv#*"$RL_NL"} ;; esac
  IFS="$US" read -r pn pst pdr pfk pbase phead poid pmg <<EOF
$first
EOF
  if ! [[ $pn =~ ^[0-9]+$ ]] || ! [[ $poid =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]; then
    mg_no "⛔ PR 정보를 읽지 못했습니다(gh 응답 형식이 예상과 다름)"
  fi
  [ "$pst" = OPEN ] || mg_no "⛔ PR #$pn 은 열려 있는 PR 이 아닙니다(상태: $pst)"
  [ "$pdr" = false ] || mg_no "⛔ PR #$pn 은 초안(draft)입니다 — 사람이 GitHub 화면에서 '준비됨'으로 바꾼 뒤 다시"
  [ "$pfk" = false ] || mg_no "⛔ PR #$pn 은 포크의 PR 입니다 — 사람이 GitHub 화면·터미널에서 합쳐 주세요"
  [ "$phead" = "$br" ] || mg_no "⛔ PR #$pn 은 다른 가지($phead)의 것입니다(지금 가지: $br)"
  [ "$poid" = "$hoid" ] || mg_no "⛔ PR #$pn 의 마지막 커밋(${poid:0:7})이 지금 커밋(${hoid:0:7})과 다릅니다 — 아직 안 올린 커밋이 있거나 원격과 다릅니다. 먼저 /refactor:approve 푸시"
  [ "$pbase" = "$bname" ] || mg_no "⛔ PR #$pn 은 기본 가지($bname)로 가는 PR 이 아닙니다(받는 가지: $pbase)"
  case "$pmg" in
    MERGEABLE) ;;
    CONFLICTING) mg_no "⛔ PR #$pn 에 충돌이 있습니다 — 충돌을 먼저 풀어야 합니다" ;;
    UNKNOWN) mg_no "⏳ GitHub 가 아직 PR #$pn 을 합칠 수 있는지 계산 중입니다 — 잠시 뒤 다시 입력하세요" ;;
    *) mg_no "⛔ PR #$pn 을 합칠 수 있는 상태가 아닙니다(mergeable: $pmg)" ;;
  esac
  # 2) 자동 검사: 0개 거절(D6) · 안 끝난 것 · 실패 · 성공(SUCCESS)이 하나도 없음(전부 NEUTRAL·SKIPPED)도 0개와 같이 거절
  cn=0; cok=0; cpend=""; cfail=""
  while IFS="$US" read -r ctype cstat cconc cstate cname; do
    [ -n "$ctype" ] || continue
    cn=$((cn + 1)); cname=${cname:0:80}; cname=${cname//[[:cntrl:]]/?}
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
  [ -n "$cfail" ] && mg_no "⛔ PR #$pn 의 자동 검사 실패(${cfail#, }) — 고친 뒤 다시"
  [ -n "$cpend" ] && mg_no "⏳ PR #$pn 의 자동 검사가 아직 도는 중입니다(${cpend#, }) — 끝난 뒤 다시 입력하세요"
  if [ "$cn" = 0 ] || [ "$cok" = 0 ]; then
    mg_no "⛔ PR #$pn 에 통과한 자동 검사가 없습니다 — 검사 없이는 여기서 합치지 않습니다. 사람이 GitHub 화면·터미널에서 합쳐 주세요"
  fi
  # 3) 기본 가지에 PR 이 모르는 새 커밋이 들어왔나(GitHub 쪽 기준 — 로컬 참조는 옛 것일 수 있다)
  (cd "$proj" && rl_bounded 5 gh api "repos/{owner}/{repo}/compare/$bname...$poid" --jq .behind_by) >"$mtmp/o" 2>"$mtmp/e"; crc=$?
  cb=$(< "$mtmp/o")
  if [ "$crc" != 0 ] || ! [[ $cb =~ ^[0-9]+$ ]]; then
    case "$crc" in 124|142) GE="5초 안에 끝나지 않음" ;; 0) GE="응답 형식이 예상과 다름" ;; *) gh_err ;; esac
    mg_no "⛔ 기본 가지($bname)와 PR 을 비교하지 못했습니다: $GE — 사람이 확인한 뒤 GitHub 화면·터미널에서"
  fi
  [ "$cb" = 0 ] || mg_no "⛔ 기본 가지($bname)에 새 커밋 ${cb}개가 들어와 있습니다 — 사람이 확인한 뒤 GitHub 화면·터미널에서"
  # 4) 합치기 — 확인한 머리 커밋일 때만(--match-head-commit). 그 밖의 옵션은 붙이지 않는다
  (cd "$proj" && rl_bounded 8 gh pr merge "$pn" "--$mth" --match-head-commit "$poid") >"$mtmp/o" 2>"$mtmp/e"; mrc=$?
  if [ "$mrc" != 0 ]; then
    case "$mrc" in
      124|142) say "⚠️ 합치기 요청이 8초 안에 끝나지 않았습니다 — 합쳐졌는지 알 수 없습니다. Claude 에게 'gh pr view $pn --json state,mergedAt' 로 확인해 달라고 하세요."
               say "   (기록에 줄을 남기지 않았습니다.)"; exit 0 ;;
    esac
    gh_err
    say "⛔ gh 가 합치기를 거절했습니다: $GE — 합쳐지지 않았습니다."
    say "$MG_AUTH"
    exit 0
  fi
  printf '%s KST | 합치기 | PR #%s %s -> %s (%s) @%s | - | 사용자가 /refactor:approve 로 실행\n' "$now" "$pn" "$br" "$bname" "$mth" "${poid:0:7}" >> "$log"
  rl_log_seal "$dir"
  say "✅ 합쳤습니다: PR #$pn ($br → $bname, $mth)"
  say "   ⚠️ 기본 가지에 합쳐지면 운영 배포가 시작될 수 있습니다 — 배포 확인을 Claude 에게 부탁하세요"
  # 바로 /refactor:approve 새 가지 를 칠 수 있게 기본 가지를 받아 온다(남은 시간이 있을 때만 · 실패해도 알림만)
  if [ $((SECONDS - t0)) -le 10 ]; then
    if rl_bounded 6 "${G[@]}" fetch -q origin "$bname" >/dev/null 2>&1; then say "   (origin/$bname 을 받아 왔습니다.)"
    else say "   (origin/$bname 을 받아 오지 못했습니다 — 새 가지 전에 Claude 에게 '최신 내용 받아 와'라고 하세요.)"
    fi
  else
    say "   (시간이 모자라 origin/$bname 을 받아 오지 않았습니다 — 새 가지 전에 Claude 에게 '최신 내용 받아 와'라고 하세요.)"
  fi
  say "다음 묶음: /refactor:approve 새 가지"
  exit 0
fi

# ── 기준선 허용(0.3.3): 승인됨·미완료·번호 하나·승인 줄 있음 · 카드의 "깨질 것으로 예상되는 기준선" 칸에 백틱 경로가 있는 단계만 ──
#   허용 파일 = (지금 파일의 ID 중 아직 대상인 것) ∪ (이번 ID) 한 줄. 실제로 썼을 때만 기록에 "허용" 줄(지문 칸 "-" — 승인 상태 계산은 이 줄을 건너뜀)
if [ "$mode" = "allow" ]; then
  if [ ! -f "$plan" ]; then say "❓ 계획서(REFACTOR_PLAN.md)가 아직 없습니다. /refactor:go 로 계획서 단계까지 진행하세요."; exit 0; fi
  cdir=$(mktemp -d 2>/dev/null) || cdir=$(mktemp -d -t rlcards 2>/dev/null) || cdir=""
  if [ -z "$cdir" ]; then say "⚠️ 임시 폴더를 만들지 못해 아무것도 바꾸지 않았습니다."; exit 0; fi
  trap 'rm -rf "$cdir"' EXIT
  recs=$(RL_CARDDIR=$cdir rl_cards "$plan" "$log")
  # 후보 카드(승인됨·미완료·번호 하나·승인 줄 있음)의 본문 파일로 기준선 경로를 한 번에 뽑는다(카드마다 awk 를 부르지 않는다)
  set --
  while IFS="$US" read -r kind_ n_ id t box done_ cnt k r h hv st; do
    [ "$kind_" = CARD ] && [ "$st" = approved ] && [ "$done_" != 1 ] && [ "${cnt:-1}" = 1 ] && [ "$box" != none ] && set -- "$@" "$cdir/c$n_"
  done <<EOF
$recs
EOF
  [ "$#" -gt 0 ] && BLP=$(rl_card_bl_paths -n "$@")
  elig=""; nmap=" "
  while IFS="$US" read -r kind_ n_ id t box done_ cnt k r h hv st; do
    [ "$kind_" = CARD ] || continue
    nmap="$nmap$id=$n_ "
    [ "$st" = approved ] && [ "$done_" != 1 ] && [ "${cnt:-1}" = 1 ] && [ "$box" != none ] || continue
    bl_of "$n_"
    case "$BLV" in ""|"?") ;; *) elig="$elig $id" ;; esac
  done <<EOF
$recs
EOF
  want=""   # 알아듣지 못한 입력은 위(인자 해석 뒤)에서 이미 한 번 알렸다
  if [ -z "$ids$phases" ]; then
    if [ -n "$bad" ]; then say "   아무것도 바꾸지 않았습니다. 예: /refactor:approve 허용 P1-1"; exit 0; fi
    want=$elig
    if [ -z "$want" ]; then say "ℹ️ 지금 승인돼 있고 기준선을 고치는 단계가 없습니다 — 허용 파일을 만들지 않았습니다."; exit 0; fi
  else
    for ph_ in $phases; do
      found=0
      while IFS="$US" read -r kind_ n_ id t box done_ cnt k r h hv st; do
        [ "$kind_" = CARD ] || continue
        case "$id" in "$ph_"-*) ;; *) continue ;; esac
        found=1
        case " $elig " in *" $id "*) case " $want " in *" $id "*) ;; *) want="$want $id" ;; esac ;; esac
      done <<EOF
$recs
EOF
      [ "$found" = 0 ] && say "❓ 계획서에 $ph_ 묶음의 단계가 없습니다."
    done
    for id in $ids; do
      found=0
      while IFS="$US" read -r kind_ n_ id_ t box done_ cnt k r h hv st; do
        [ "$kind_" = CARD ] && [ "$id_" = "$id" ] && { found=1; break; }
      done <<EOF
$recs
EOF
      if [ "$found" = 0 ]; then say "❓ 계획서에 없는 단계 번호: $id"; continue; fi
      if [ "${cnt:-1}" -gt 1 ]; then say "⛔ [$id] 같은 번호의 단계가 ${cnt}개 있어 어느 것인지 알 수 없습니다 — 허용하지 않았습니다."; continue; fi
      if [ "$box" = "none" ]; then say "❓ 승인 줄이 없는 단계: [$id] $t — 허용하지 않았습니다."; continue; fi
      if [ "$done_" = 1 ]; then say "ℹ️ 이미 완료된 단계라 허용이 필요 없습니다: [$id] $t"; continue; fi
      case "$st" in
        approved) ;;
        changed) say "🔁 승인 뒤 카드가 바뀐 단계라 허용하지 않았습니다: [$id] $t — 다시 승인(/refactor:approve $id)한 뒤 허용하세요"; continue ;;
        *) say "❓ 승인되지 않은 단계라 허용하지 않았습니다: [$id] $t — 먼저 /refactor:approve $id"; continue ;;
      esac
      bl_of "$n_"
      case "$BLV" in
        "") say "ℹ️ [$id] $t — 기준선을 바꾸지 않는 단계라 허용이 필요 없습니다."; continue ;;
        "?") say "⚠️ [$id] $t — '깨질 것으로 예상되는 기준선' 칸에 백틱 경로가 없어 허용하지 않았습니다 — 필요하면 계획서를 고치게 하세요."; continue ;;
      esac
      case " $want " in *" $id "*) ;; *) want="$want $id" ;; esac
    done
    if [ -z "$want" ]; then say "ℹ️ 허용할 단계가 없어 아무것도 바꾸지 않았습니다."; exit 0; fi
  fi
  if ! allow_write "$want" "$elig"; then say "⚠️ 허용 파일을 쓰지 못했습니다(아무것도 바꾸지 않았습니다)."; exit 0; fi
  new=$AW_NEW
  if [ "$AW_WROTE" = 0 ]; then
    say "ℹ️ 이미 허용돼 있습니다: $new (아무것도 바꾸지 않았습니다)"
  else
    say "🔓 기준선 허용: $new — 이 단계를 실행하는 동안 카드에 적힌 기준선만 고칠 수 있습니다(단계가 모두 끝나면 저절로 닫힘)"
  fi
  for x in $new; do
    nn=${nmap#*" $x="}; nn=${nn%% *}
    bl_of "$nn"
    say "   [$x] 고칠 기준선: $BLV"
  done
  allow_notes
  say "다음: /refactor:go"
  exit 0
fi

# ── 마무리(DONE) ─────────────────────────────────────────────────────────────
if [ "$special" = "done" ]; then
  waiting=""
  if [ -f "$plan" ]; then
    while IFS="$US" read -r kind_ n_ id t box done_ cnt k r h hv st; do
      [ "$kind_" = CARD ] && [ "$st" = approved ] && [ "$done_" != 1 ] && waiting="$waiting $id"
    done <<RECS_DONE
$(rl_cards "$plan" "$log")
RECS_DONE
  fi
  if [ -n "$waiting" ]; then
    say "❓ 아직 실행 대기(승인됨) 단계가 있습니다:$waiting — 먼저 /refactor:go 로 실행하거나 /refactor:approve 보류 <ID> 로 보류한 뒤 마무리하세요."
    exit 0
  fi
  printf '%s KST | 마무리 | PROJECT | - | 사용자가 /refactor:approve 로 실행\n' "$now" >> "$log"
  rl_log_seal "$dir"
  if [ -f "$state" ]; then
    tmp="$state.tmp.$$"
    awk -v U="$RL_TODAY" '
      NR == 1 && $0 ~ /^---/ { fm = 1; print; next }
      fm && $0 ~ /^---/ { fm = 0; print; next }
      fm && $0 ~ /^phase:/ { print "phase: DONE"; next }
      fm && $0 ~ /^gate:/ { print "gate: none"; next }
      fm && $0 ~ /^next:/ { print "next: \"한두 달 뒤 /refactor:go 다시 CHECKUP\""; next }
      fm && $0 ~ /^updated:/ { print "updated: " U; next }
      { print }' "$state" > "$tmp" && [ -s "$tmp" ] && mv "$tmp" "$state"
    if [ -e "$tmp" ]; then rm -f "$tmp"; fi
  fi
  say "✅ 리팩토링을 마무리했습니다(DONE). 이제 이 프로젝트의 안전장치가 모두 꺼집니다(비밀값·되돌릴 수 없는 명령 보호 포함)."
  say "   다시 켜고 점검하려면 /refactor:go 다시 CHECKUP (한두 달 뒤를 권합니다)"
  # 주기가 끝났으니 기준선 허용 파일은 지운다(새 계획에서 같은 번호가 다른 카드일 수 있다). 기록에는 줄을 더하지 않는다
  # (마무리 줄이 기록의 마지막 줄이어야 마무리가 인정된다). 마이그레이션 허용 파일은 알리기만, .allow-env(설정)는 그대로
  if [ -f "$dir/.allow-baseline-edit" ]; then
    rm -f "$dir/.allow-baseline-edit"
    [ -f "$dir/.allow-baseline-edit" ] || say "🔒 리팩토링이 끝나 기준선 허용 파일(.allow-baseline-edit)을 지웠습니다."
  fi
  [ -f "$dir/.allow-migration-edit" ] && say "⚠️ 마이그레이션 허용 파일(.allow-migration-edit)이 남아 있습니다 — 작업을 커밋했으면 터미널에서 rm \"$dir/.allow-migration-edit\" 로 지우세요(CLI 라면 입력창에 ! rm … 도 됨)."
  exit 0
fi

# ── 기준선 계획 ──────────────────────────────────────────────────────────────
if [ "$want_base" = 1 ]; then
  rl_base_state "$base" "$log"
  ph=$(sed -n -E 's/^phase:[[:space:]]*"?([A-Za-z_]+).*/\1/p' "$state" 2>/dev/null | head -n 1)
  case "$RL_STATE" in
    nofile) say "❓ 기준선 계획(BASELINE.md)이 아직 없습니다. /refactor:go 로 기준선 계획 단계까지 진행하세요." ;;
    nofield) say "❓ BASELINE.md에 줄 맨 앞의 '기준선 계획 승인: [ ]' 줄이 없습니다. /refactor:go 로 기준선 계획을 다시 만들게 하세요." ;;
    multi) say "⛔ BASELINE.md에 '기준선 계획 승인:' 줄이 여러 개라 어느 것인지 알 수 없어 승인하지 않았습니다. /refactor:go 로 한 줄만 남기게 하세요." ;;
    *)
      if [ "$mode" = "approve" ]; then
        if [ "$RL_STATE" = "approved" ]; then
          say "ℹ️ 기준선 계획은 이미 승인되어 있습니다(승인 기록과 계획 내용이 그대로임)."
        else
          [ "$RL_STATE" = "changed" ] && say "🔁 승인한 뒤 기준선 계획 내용이 바뀌어, 바뀐 계획으로 다시 승인합니다."
          printf '%s KST | 승인 | BASELINE | %s | 사용자가 /refactor:approve 로 실행\n' "$now" "$RL_HASH" >> "$log"
          mkdir -p "$dir/approved" && rl_base_text "$base" > "$dir/approved/BASELINE.md"
          rl_log_seal "$dir"
          rl_rewrite_base "$base" x
          say "✅ 기준선 계획을 승인했습니다. 이제 /refactor:go 를 실행하면 기준선 테스트를 만듭니다."
          say "   (기준선 작성 중에는 tests/baseline/ 아래 새 파일과 docs/refactor/ 만 만들고, 기존 코드는 고치지 않습니다.)"
          set_state_front -v N="/refactor:go 로 기준선 작성" -v U="$RL_TODAY"
        fi
      else
        if [ "$ph" != "BASELINE_PLAN" ] && [ "$RL_STATE" = "approved" ]; then
          say "ℹ️ 기준선 작성이 이미 시작돼(현재 단계: ${ph:-알 수 없음}) 기준선 승인은 취소하지 않았습니다."
        elif [ "$RL_STATE" = "approved" ] || [ "$RL_STATE" = "changed" ]; then
          printf '%s KST | 보류 | BASELINE | %s | 사용자가 /refactor:approve 로 실행\n' "$now" "$RL_HASH" >> "$log"
          rl_log_seal "$dir"
          rl_rewrite_base "$base" o
          say "⏸ 기준선 계획 승인을 취소했습니다."
          set_state_front -v N="기준선 계획 확인 후 /refactor:approve baseline" -v U="$RL_TODAY"
        else
          say "ℹ️ 기준선 계획은 승인된 적이 없습니다."
        fi
      fi ;;
  esac
fi

# ── 계획서 단계 ──────────────────────────────────────────────────────────────
if [ -n "$ids$phases" ] || [ "$want_base" = 0 ]; then
  if [ ! -f "$plan" ]; then
    [ -n "$ids$phases" ] && say "❓ 계획서(REFACTOR_PLAN.md)가 아직 없습니다. /refactor:go 로 계획서 단계까지 진행하세요."
  else
    # 카드는 한 번만 읽는다: 본문(c<순번>)·다시 쓴 뒤 본문(a<순번>)·지문(sums)을 임시 폴더 하나에 남겨
    # 승인 때 남길 카드 내용과 승인 뒤 현황을 여기서 얻는다(계획서를 두 번 읽지 않는다)
    cdir=""
    if [ "$rw" = 1 ]; then
      cdir=$(mktemp -d 2>/dev/null) || cdir=$(mktemp -d -t rlcards 2>/dev/null) || cdir=""
      [ -n "$cdir" ] && trap 'rm -rf "$cdir"' EXIT
    fi
    recs=$(RL_CARDDIR=$cdir RL_ALT=${cdir:+1} rl_cards "$plan" "$log")
    # 묶음(P1)을 단계 ID로 펼친다(완료된 단계는 건너뜀)
    targets=$ids
    for ph_ in $phases; do
      found=0
      while IFS="$US" read -r kind_ n_ id t box done_ cnt k r h hv st; do
        [ "$kind_" = "CARD" ] || continue
        case "$id" in "$ph_"-*) ;; *) continue ;; esac
        found=1
        [ "$done_" = 1 ] && continue
        case " $targets " in *" $id "*) ;; *) targets="$targets $id" ;; esac
      done <<EOF
$recs
EOF
      [ "$found" = 0 ] && say "❓ 계획서에 $ph_ 묶음의 단계가 없습니다."
    done

    # 승인 화면(0.3.3)·승인하면 자동 허용(0.3.4): 이번에 승인할 수 있는 카드의 "깨질 것으로 예상되는 기준선" 경로를 한 번에 뽑아 둔다.
    #   허용 파일이 있으면 이미 승인돼 있는 허용 대상 후보(미완료·번호 하나·승인 줄 있음)의 경로도 같이(파일에 남길 ID 를 가리려고 — awk 한 번)
    #   alt_pre = 승인 줄을 다시 쓴 뒤 본문의 지문(" <순번>=card=… ") — 이번에 승인하면 "승인됨"이 되는지(승인 줄 덧붙임이 없으면 됨) 미리 안다
    alt_pre=""
    if [ "$mode" = "approve" ] && [ -n "$cdir" ] && [ -n "$targets" ]; then
      set --
      while IFS="$US" read -r kind_ n_ id_ t box done_ cnt k r h hv st; do
        [ "$kind_" = CARD ] && [ "$done_" != 1 ] || continue
        if [ "$st" != approved ]; then
          case " $targets " in *" $id_ "*) set -- "$@" "$cdir/c$n_" ;; esac
        elif [ -f "$af" ] && [ "${cnt:-1}" = 1 ] && [ "$box" != none ]; then
          set -- "$@" "$cdir/c$n_"
        fi
      done <<EOF
$recs
EOF
      [ "$#" -gt 0 ] && BLP=$(rl_card_bl_paths -n "$@")
      if [ -f "$cdir/sums" ]; then
        while read -r s1_ s2_ s3_; do case "$s3_" in a[0-9]*) alt_pre="$alt_pre ${s3_#a}=card=$s1_.$s2_ " ;; esac; done < "$cdir/sums"
      fi
    fi

    acted=""; lines=""; aw_want=""
    for id in $targets; do
      found=0
      while IFS="$US" read -r kind_ n_ id_ t box done_ cnt k r h hv st; do
        [ "$kind_" = "CARD" ] && [ "$id_" = "$id" ] && { found=1; break; }
      done <<EOF
$recs
EOF
      if [ "$found" = 0 ]; then say "❓ 계획서에 없는 단계 번호: $id"; continue; fi
      if [ "${cnt:-1}" -gt 1 ]; then say "⛔ [$id] 같은 번호의 단계가 ${cnt}개 있어 어느 것인지 알 수 없습니다 — /refactor:go 로 계획서 번호를 고치게 한 뒤 다시 승인하세요."; continue; fi
      if [ "$box" = "none" ]; then say "❓ 승인 줄이 없는 단계: [$id] $t — 계획서 형식을 /refactor:go 로 고치게 하세요."; continue; fi
      if [ "$done_" = 1 ]; then say "ℹ️ 이미 완료된 단계라 바꾸지 않음: [$id] $t"; continue; fi
      if [ "$mode" = "approve" ]; then
        case "$st" in
          approved) say "ℹ️ 이미 승인됨: [$id] $t"; continue ;;
          changed) say "🔁 승인한 뒤 카드 내용이 바뀐 단계를 바뀐 내용으로 다시 승인: [$id] $t" ;;
        esac
        lines="$lines$now KST | 승인 | $id | $hv | 사용자가 /refactor:approve 로 실행"$'\n'
        acted="$acted $id"
        say "✅ 승인함: [$id] $t"
        [ -n "$k" ] && say "   종류: $k"
        [ -n "$r" ] && say "   위험도: $r"
        say "   👤 사람이 직접 할 일: ${h:-없음}"
        bl_of "$n_"
        case "$BLV" in
          "") ;;
          "?") say "   ⚠️ '깨질 것으로 예상되는 기준선' 칸에 백틱 경로가 없어 이 단계는 기준선을 고칠 수 없습니다 — 필요하면 계획서를 고치게 하세요" ;;
          *) # 0.3.4: 승인하면 그 단계의 기준선 허용이 자동으로 열린다(승인 줄 덧붙임으로 "승인 뒤 바뀜"이 되는 카드는 안 열림)
             #   🛠(동작이 바뀌는) 카드만 — 종류 칸에 🛠 가 있고 🔧 가 없을 때(0.3.4 보완 F8). 그 밖이면 열지 않고 ⚠️ 한 줄(수동 '허용 <ID>'는 그대로)
             case "$alt_pre" in *" $n_=$hv "*)
               case "$k" in
                 *🔧*) aw_kind=0 ;;
                 *🛠*) aw_kind=1 ;;
                 *) aw_kind=0 ;;
               esac
               if [ "$aw_kind" = 1 ]; then
                 say "   🔓 고칠 기준선: $BLV — 이 단계를 실행하는 동안 열립니다(닫기: /refactor:approve 허용 닫기)"
                 aw_want="$aw_want $id"
               else
                 say "   ⚠️ 🛠 카드가 아니라 기준선 허용을 자동으로 열지 않았습니다 — 계획서를 확인하고 필요하면 /refactor:approve 허용 $id"
               fi ;;
             esac ;;
        esac
      else
        case "$st" in
          approved|changed)
            lines="$lines$now KST | 보류 | $id | $hv | 사용자가 /refactor:approve 로 실행"$'\n'
            acted="$acted $id"
            say "⏸ 승인 취소함: [$id] $t" ;;
          *) say "ℹ️ 승인된 적 없음: [$id] $t" ;;
        esac
      fi
    done

    if [ -n "$acted" ]; then
      printf '%s' "$lines" >> "$log"
      rl_log_seal "$dir"
      # 승인한 카드의 내용을 남겨 둔다(나중에 카드가 바뀌면 무엇이 바뀌었는지 보여 주려고)
      if [ "$mode" = "approve" ] && { [ -d "$dir/approved" ] || mkdir -p "$dir/approved"; }; then
        for id in $acted; do
          ctext=""
          if [ -n "$cdir" ]; then   # 위에서 읽은 카드 본문 그대로(rl_card_text 와 같은 내용)
            while IFS="$US" read -r kind_ n_ id_ rest_; do
              [ "$kind_" = "CARD" ] && [ "$id_" = "$id" ] && { [ -f "$cdir/c$n_" ] && { IFS= read -r -d '' ctext < "$cdir/c$n_" || :; }; break; }
            done <<EOF
$recs
EOF
            printf '%s' "$ctext" > "$dir/approved/$id.md"
          else
            rl_card_text "$plan" "$id" > "$dir/approved/$id.md"
          fi
        done
      fi
      if [ "$mode" = "approve" ]; then rl_rewrite_plan "$plan" x "$acted"; else rl_rewrite_plan "$plan" o "$acted"; fi
    fi

    # 0.3.4 승인하면 기준선 허용 자동(이슈 #14-2 — 0.3.3 D3 "승인과 허용은 따로"를 뒤집음): 이번 호출에서 새로 승인된 카드 중
    #   기준선 칸에 백틱 경로가 있는 것만 '허용 <ID>'와 같은 루틴으로 더한다. 파일에 있던 ID 는 지금도 허용 대상인 것(승인됨·미완료·경로 있음)만 남긴다
    if [ -n "$aw_want" ]; then
      aw_elig=$aw_want
      if [ -f "$af" ]; then
        while IFS="$US" read -r kind_ n_ id_ t box done_ cnt k r h hv st; do
          [ "$kind_" = CARD ] && [ "$st" = approved ] && [ "$done_" != 1 ] && [ "${cnt:-1}" = 1 ] && [ "$box" != none ] || continue
          bl_of "$n_"
          case "$BLV" in ""|"?") ;; *) aw_elig="$aw_elig $id_" ;; esac
        done <<EOF
$recs
EOF
      fi
      if ! allow_write "$aw_want" "$aw_elig"; then
        say "⚠️ 기준선 허용 파일을 쓰지 못했습니다 — 승인은 됐습니다. 실행 전에 /refactor:approve 허용${aw_want}"
      else
        allow_notes
      fi
    fi
    # 0.3.4 보류: 허용 파일에 그 ID 가 있으면 뺀다(남는 ID 가 없으면 파일을 지운다 — 닫는 쪽이라 기록에는 줄을 남기지 않는다)
    if [ "$mode" = "hold" ] && [ -n "$acted" ] && [ -f "$af" ]; then
      ho=$(rl_allow_ids "$dir"); hn=""; hx=""
      for x in $ho; do
        [ "$x" = "?" ] && { hn="$ho"; hx=""; break; }
        case " $acted " in *" $x "*) hx="$hx $x" ;; *) hn="$hn $x" ;; esac
      done
      hn=${hn# }
      if [ -n "$hx" ]; then
        if [ -z "$hn" ]; then
          rm -f "$af"
          if [ -f "$af" ]; then say "⚠️ 기준선 허용 파일을 지우지 못했습니다 — 터미널에서 rm \"$af\""
          else say "🔒 보류한 단계가 기준선 허용에 있어 뺐습니다:$hx (남은 단계가 없어 허용 파일을 지움)"
          fi
        elif { printf '%s\n' "$hn" > "$af.tmp.$$" && mv -f "$af.tmp.$$" "$af"; }; then
          say "🔒 보류한 단계를 기준선 허용에서 뺐습니다:$hx (남은 허용: $hn)"
        else
          rm -f "$af.tmp.$$"; say "⚠️ 기준선 허용 파일에서$hx 을(를) 빼지 못했습니다 — /refactor:approve 허용 닫기 로 닫으세요"
        fi
      fi
    fi

    # 현황(기록 기준): 계획서를 다시 읽지 않고, 이번에 처리한 단계만 기록에 남긴 대로 바꿔 본다
    #   승인 → 체크 x, 기록의 지문(승인 줄 덧붙임 포함)이 다시 쓴 뒤 본문의 지문(a<순번>)과 같으면 승인됨, 다르면 바뀜
    #   보류 → 체크 칸 비움, 보류됨. 기록에는 이번 단계 줄만 더했으므로 다른 단계의 상태는 그대로다
    alt_sums=""; adj=$acted
    if [ -n "$acted" ] && [ -n "$cdir" ] && [ -f "$cdir/sums" ]; then
      while read -r s1_ s2_ s3_; do case "$s3_" in a[0-9]*) alt_sums="$alt_sums ${s3_#a}=card=$s1_.$s2_ " ;; esac; done < "$cdir/sums"
    elif [ -n "$acted" ]; then   # 임시 폴더를 못 만들었으면 예전처럼 다시 읽는다
      recs=$(rl_cards "$plan" "$log"); adj=""
    fi
    n_total=0; n_ap=0; n_done=0; ready=""; pending=""; changed=""; unlogged=""; dups=""; fence_warn=""
    while IFS="$US" read -r kind_ n_ id t box done_ cnt k r h hv st; do
      case "$kind_" in
        WARN) [ "$n_" = "fence" ] && fence_warn=$id ;;
        CARD)
          case " $adj " in *" $id "*)
            if [ "$mode" = "approve" ]; then
              box=x
              case "$alt_sums" in *" $n_=$hv "*) st=approved ;; *) st=changed ;; esac
            else
              box=o; st=held
            fi ;;
          esac
          if [ "${cnt:-1}" -gt 1 ]; then case " $dups " in *" $id "*) ;; *) dups="$dups $id" ;; esac; fi
          [ "$box" = "none" ] && continue
          n_total=$((n_total + 1))
          [ "$st" = "approved" ] && n_ap=$((n_ap + 1))
          [ "$done_" = 1 ] && { n_done=$((n_done + 1)); continue; }
          case "$st" in
            approved) [ "${cnt:-1}" -gt 1 ] || [ "$intact" = 0 ] || ready="$ready $id" ;;
            changed) changed="$changed $id" ;;
            *) pending="$pending $id"; [ "$box" = "x" ] && unlogged="$unlogged $id" ;;
          esac ;;
      esac
    done <<EOF
$recs
EOF
    say ""
    say "📋 계획서 현황(승인 기록 기준): 전체 ${n_total}단계 · 승인 ${n_ap} · 완료 ${n_done}"
    [ -n "$ready" ] && say "   ▶ 실행 대기(승인됨):$ready"
    [ -n "$changed" ] && say "   🔁 승인 뒤 카드가 바뀜(실행 안 함 — 다시 승인 필요):$changed"
    [ -n "$pending" ] && say "   ⏸ 승인 대기:$pending"
    [ -n "$unlogged" ] && say "   ⚠️ 체크 표시만 있고 승인 기록이 없음(실행 안 함 — 계획서를 손으로 고친 것일 수 있음):$unlogged"
    [ -n "$dups" ] && say "   ⚠️ 같은 번호의 단계가 여러 개:$dups — 계획서 번호를 고쳐야 실행할 수 있습니다."
    [ -n "$fence_warn" ] && say "   ⚠️ 닫히지 않은 코드 블록(\`\`\`)이 ${fence_warn}개 있어 무시했습니다 — 계획서 형식을 확인하세요."
    if [ -z "$ids$phases" ] && [ "$want_base" = 0 ]; then
      say ""
      say "사용법: /refactor:approve P0-1 P1-2   (단계 번호, 여러 개 가능)"
      say "        /refactor:approve P1          (P1 묶음 전체 — 완료된 단계는 건너뜀)"
      say "        /refactor:approve baseline     (기준선 계획 승인)"
      say "        /refactor:approve 보류 P1-2    (승인 취소 — 맨 앞에 '보류', 완료 전만)"
      say "        /refactor:approve 마무리        (실행 대기 단계가 없을 때 리팩토링 끝내기)"
      say "        /refactor:approve 확인          (승인 기록을 사람이 직접 고친 뒤 다시 봉인)"
      say "        /refactor:approve 허용 P1-1     (승인된 단계가 카드에 적힌 기준선을 고칠 수 있게 — 승인할 때 저절로 열림 · 닫은 뒤 다시 열 때 · 번호 없이 '허용'이면 해당 단계 전부)"
      say "        /refactor:approve 허용 닫기      (기준선 허용 닫기)"
      say "        /refactor:approve 푸시           (지금 작업 가지를 이번 차례에만 올려도 됨 — 기본 가지는 안 됨)"
      say "        /refactor:approve 합치기 68 rebase (PR 합치기 — 열림·검사 초록·기본 가지에 새 커밋 없음일 때만 · 방식은 rebase/squash/merge)"
      say "        /refactor:approve 새 가지        (합친 뒤 origin 의 기본 가지에서 새 작업 가지 만들기 — 이름을 붙이면 그 이름)"
    fi
    if [ -n "$acted" ] || [ "$n_total" != 0 ]; then
      first_ready=${ready# }; first_ready=${first_ready%% *}
      if [ -n "$acted" ]; then
        if [ -n "$first_ready" ]; then nxt="/refactor:go 로 승인된 단계 실행 (다음: $first_ready)"; else nxt="계획서 확인 후 /refactor:approve <단계ID>"; fi
        set_state_front -v A="$n_ap" -v D="$n_done" -v T="$n_total" -v N="$nxt" -v U="$RL_TODAY"
      elif [ "$rw" = 1 ]; then
        set_state_front -v A="$n_ap" -v D="$n_done" -v T="$n_total"
      fi
    fi
  fi
fi

if [ -f "$log" ] && { [ -n "${acted:-}" ] || [ "$want_base" = 1 ]; }; then
  say ""
  say "🧾 승인 기록: docs/refactor/APPROVALS.log (승인의 유일한 근거 — 사람만 고칩니다)"
fi
exit 0
