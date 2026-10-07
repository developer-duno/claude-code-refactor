#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Vibe Refactor — 승인 스크립트 (/refactor:approve 전용)
#
# 사용자가 입력창에 /refactor:approve 를 치면 입력 훅(turn.sh)이 --from-hook 을 붙여 실행한다 — 승인은 여기서만 처리된다.
# 스킬의 ! 명령(훅보다 먼저 돈다)도 이 스크립트를 부르지만 --from-hook 이 없으므로 아무것도 바꾸지 않고 현황만 보여 준다.
# Claude가 직접 부르는 것은 안전장치 훅이 막는다. 사용자가 입력한 인자는 표준입력으로 받는다(셸 주입 방지).
#   $1 = 프로젝트 폴더, $2 = --from-hook (입력 훅이 부를 때만)
#   표준입력 = 인자 (예: "P0-1 P1-2" / "P1" / "baseline" / "보류 P1-2" / "확인" / "마무리" / "허용 P1-1" / "허용 닫기" / "푸시" /
#              "새 가지" / "새 가지 refactor/hotfix-1" / "합치기" / "합치기 68 rebase" / "B1"·"묶음 B1" / "보류 B1" /
#              "잠깐 멈춤"·"잠깐 멈춤 2시간"(0.4.2 — docs/refactor/.allow-pause) / "다시 시작" / 비움=현황)
# "B1"(0.4.0 묶음)은 계획서 카드의 "- **묶음**: B1 …" 칸으로 그 묶음의 안 끝난 카드를 펼쳐 카드마다 승인(기존 승인 루틴)하고, 그 앞에
#   "| 묶음 승인 | B1 | - | 카드 N개: … |" 한 줄을 남긴다(지문 칸 "-" — 승인 상태 계산은 이 줄을 건너뜀 · 이 카드 목록이 그 묶음의 정본).
#   STATE.md 앞머리 current_bundle 도 여기서만 쓴다(칸이 없으면 넣는다).
# "B1 자동 [rebase|squash|merge]"(0.4.0 자동 모드)는 묶음 승인 전에 PROFILE 의 자동 모드 칸·가지·방식을 확인하고(안 되면 ❓ — 아무것도 안 바꿈),
#   승인되면 허락 파일 docs/refactor/.turn-auto.B1(11줄 — 아래 자동 모드 절)과 기록 "| 자동 | B1 | - | <시각> <가지> <방식> |" 을 남긴다.
#   푸시·합치기·배포 확인·라이브 검증은 그다음 인자 없는 /refactor:go 차례에 Claude 가 scripts/refactor-auto.sh 로 한다
#   환경변수 REFACTOR_TURN_SID = 입력 훅이 넘기는 세션 ID("푸시"·"합치기"의 허락 파일 이름에 쓴다)
#   환경변수 REFACTOR_TRANSCRIPT_PATH = 입력 훅이 넘기는 대화 기록 파일 경로(0.3.7 — "합치기"가 .turn-mergetp.<세션ID> 에 적는다. 없으면 빈 값)
# "허용"(0.3.3)은 승인된 🛠 단계의 기준선 허용 파일(.allow-baseline-edit)에 단계 ID 를 적는다.
#   0.3.4 부터는 승인할 때도 🛠 카드의 기준선 칸에 백틱 경로가 있으면 같은 루틴으로 자동으로 적는다(보류하면 뺀다 · 🔧·종류 칸 없는 카드는 안 연다) — '허용'은 닫은 뒤 다시 열 때 쓴다.
# "새 가지"(0.3.4)는 지금 가지의 내용이 origin/<기본 가지> 에 다 들어 있을 때 거기서 새 작업 가지를 만들어 옮긴다(네트워크 없음).
# "합치기"(0.3.5)는 이번 차례에만 지금 가지의 PR 을 합쳐도 된다는 허락 파일(docs/refactor/.turn-merge.<세션ID>)만 만든다(네트워크 없음) —
#   gh 확인·합치기는 Claude 가 그 차례에 허락된 명령(scripts/refactor-merge.sh)으로 한다(0.3.4 는 여기서 gh 로 했으나 입력 훅 30초 안에 못 끝냈다).
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
# 0.4.0: 묶음 'B1'(bundles = 묶음 ID 들 · bkw = '묶음' 낱말 수 · bzero = 앞에 0 이 붙은 이름) · '자동'(BUNDLE_AUTO=1 — 자동 모드가 쓴다)
bundles=""; bkw=0; bzero=""; BUNDLE_AUTO=0
# 0.4.0 자동 모드 합치기 방식('B1 자동 squash' — 묶음 이름과 '자동' 뒤에서만 받는다): amth = 방식, amn = 방식 낱말 수
amth=""; amn=0
# 0.4.2 F5 '잠깐 멈춤 [N시간]'(mode=pause — pzw=1 은 '잠깐' 다음 '멈춤'을 기다림) · '다시 시작'(mode=resume — rsw=1 은 '다시' 다음 '시작'을 기다림)
#   pargs·pargn = 그 뒤에 붙은 낱말(멈춤은 'N시간' 하나만 · 다시 시작은 없음)
pzw=0; rsw=0; pargs=""; pargn=0
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
      elif [ "$BUNDLE_AUTO" = 1 ] && [ -n "$bundles" ] && [ "$up" = MERGE ]; then amth=merge; amn=$((amn + 1))
      else conflict="'$tok'은(는) 맨 앞에만 쓸 수 있습니다(예: /refactor:approve 합치기)"; fi ;;
    잠깐)
      if [ "$pos" = 1 ]; then pzw=1; else conflict="'$tok'은(는) 맨 앞에만 쓸 수 있습니다(예: /refactor:approve 잠깐 멈춤 2시간)"; fi ;;
    멈춤)
      if [ "$pos" = 2 ] && [ "$pzw" = 1 ]; then mode="pause"; pzw=0; else conflict="'$tok'은(는) '잠깐' 바로 뒤에만 쓸 수 있습니다(예: /refactor:approve 잠깐 멈춤 2시간)"; fi ;;
    잠깐멈춤)
      if [ "$pos" = 1 ]; then mode="pause"; else conflict="'$tok'은(는) 맨 앞에만 쓸 수 있습니다(예: /refactor:approve 잠깐 멈춤 2시간)"; fi ;;
    다시)
      if [ "$pos" = 1 ]; then rsw=1; else conflict="'$tok'은(는) 맨 앞에만 쓸 수 있습니다(예: /refactor:approve 다시 시작)"; fi ;;
    시작)
      if [ "$pos" = 2 ] && [ "$rsw" = 1 ]; then mode="resume"; rsw=0; else conflict="'$tok'은(는) '다시' 바로 뒤에만 쓸 수 있습니다(예: /refactor:approve 다시 시작)"; fi ;;
    다시시작)
      if [ "$pos" = 1 ]; then mode="resume"; else conflict="'$tok'은(는) 맨 앞에만 쓸 수 있습니다(예: /refactor:approve 다시 시작)"; fi ;;
    확인|CONFIRM|SEAL) special=confirm ;;
    마무리|DONE|FINISH|끝|완료) special=done ;;
    ALL|전체|모두) bad="$bad $tok(전체 승인은 지원하지 않음 — P0·P1 같은 Phase 전체나 단계 번호, B1 같은 묶음으로)" ;;
    묶음|BUNDLE) bkw=$((bkw + 1)) ;;
    자동|AUTO) BUNDLE_AUTO=1 ;;
    *)
      if [ "$mode" = "pause" ] || [ "$mode" = "resume" ]; then pargs="$pargs $tok"; pargn=$((pargn + 1))
      elif [[ $up =~ ^P[0-9]+-[0-9]+[A-Z]?$ ]]; then case " $ids " in *" $up "*) ;; *) ids="$ids $up" ;; esac
      elif [[ $up =~ ^P[0-9]+$ ]]; then phases="$phases $up"
      elif [ "$mode" = "branch" ]; then nbname=$tok; nbn=$((nbn + 1))   # 이름은 원문 그대로(대문자로 바꾸거나 .;()[] 를 지우기 전)
      elif [ "$mode" = "merge" ]; then
        case "$up" in
          REBASE|리베이스) mth=rebase; mmn=$((mmn + 1)) ;;
          SQUASH|스쿼시) mth=squash; mmn=$((mmn + 1)) ;;
          병합) mth=merge; mmn=$((mmn + 1)) ;;
          *) if [[ $up =~ ^#?[0-9]{1,7}$ ]]; then mprn=$((10#${up#\#})); mnn=$((mnn + 1)); else bad="$bad $tok"; fi ;;
        esac
      elif [ "$BUNDLE_AUTO" = 1 ] && [ -n "$bundles" ] && case "$up" in REBASE|리베이스|SQUASH|스쿼시|병합) true ;; *) false ;; esac; then
        case "$up" in REBASE|리베이스) amth=rebase ;; SQUASH|스쿼시) amth=squash ;; *) amth=merge ;; esac; amn=$((amn + 1))
      elif [[ $up =~ ^B0[0-9]+$ ]]; then bzero="$bzero $tok"
      elif [[ $up =~ ^B[0-9]+$ ]]; then case " $bundles " in *" $up "*) ;; *) bundles="$bundles $up" ;; esac
      else bad="$bad $tok"
      fi ;;
  esac
done
# 0.4.2 F5: '잠깐 멈춤'은 'N시간'(1~12) 하나까지만, '다시 시작'은 단독으로(다른 것과 섞지 않음)
pzn=1
if [ -z "$conflict" ]; then
  if [ "$pzw" = 1 ]; then conflict="'잠깐'은 '잠깐 멈춤'으로만 씁니다(예: /refactor:approve 잠깐 멈춤 2시간)"
  elif [ "$rsw" = 1 ]; then conflict="'다시'는 '다시 시작'으로만 씁니다(예: /refactor:approve 다시 시작)"
  elif { [ "$mode" = "pause" ] || [ "$mode" = "resume" ]; } && { [ -n "$ids$phases$bundles$bzero" ] || [ "$want_base" = 1 ] || [ -n "$special" ] || [ "$bkw" -gt 0 ] || [ "$BUNDLE_AUTO" = 1 ]; }; then
    conflict="'잠깐 멈춤'·'다시 시작'은 다른 것과 섞지 않습니다(예: /refactor:approve 잠깐 멈춤 2시간 · /refactor:approve 다시 시작)"
  elif [ "$mode" = "resume" ] && [ "$pargn" -gt 0 ]; then conflict="'다시 시작' 뒤에는 아무것도 붙이지 않습니다"
  elif [ "$mode" = "pause" ] && [ "$pargn" -gt 0 ]; then
    pzt=${pargs# }; re_pzh='^([1-9]|1[0-2])시간$'
    if [ "$pargn" = 1 ] && [[ $pzt =~ $re_pzh ]]; then pzn=${BASH_REMATCH[1]}
    else conflict="'잠깐 멈춤' 뒤에는 시간 하나만 붙입니다(1시간~12시간 — 예: /refactor:approve 잠깐 멈춤 2시간 · 붙이지 않으면 1시간)"; fi
  fi
fi
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
  # 0.4.0 묶음 섞임 규칙(#17): 묶음은 단계 번호·Phase·허용·baseline·확인·마무리·푸시·새 가지·합치기와 섞지 않는다 · '자동'은 묶음 하나와만
  elif [ -n "$bzero" ]; then conflict="묶음 이름(${bzero# })은 앞에 0 을 붙이지 않습니다(예: /refactor:approve B1)"
  elif [ "$bkw" -gt 0 ] && [ -z "$bundles" ]; then conflict="'묶음' 뒤에는 묶음 이름을 붙입니다(예: /refactor:approve 묶음 B1 — 이름은 계획서 카드의 '묶음' 칸)"
  elif [ "$BUNDLE_AUTO" = 1 ] && [ -z "$bundles" ]; then conflict="'자동'은 묶음 이름과 함께 씁니다(예: /refactor:approve B1 자동)"
  elif [ -n "$bundles" ] && [ "$mode" = "allow" ]; then conflict="'허용'은 단계 번호하고만 함께 씁니다(묶음 이름과 섞지 않음 — 묶음을 승인하면 🛠 카드의 기준선 허용은 저절로 열립니다)"
  elif [ -n "$bundles" ] && [ -n "$ids$phases" ]; then conflict="묶음 이름(${bundles# })과 단계 번호(P1-1·P1)는 섞지 않습니다 — 따로 입력하세요"
  elif [ -n "$bundles" ] && { [ "$want_base" = 1 ] || [ -n "$special" ] || [ "$mode" = "push" ] || [ "$mode" = "branch" ] || [ "$mode" = "merge" ]; }; then conflict="묶음 이름은 baseline·확인·마무리·푸시·새 가지·합치기와 섞지 않습니다"
  elif [ "$BUNDLE_AUTO" = 1 ] && [ "${bundles# }" != "${bundles##* }" ]; then conflict="'자동'은 묶음 하나에만 씁니다(예: /refactor:approve B1 자동)"
  elif [ "$BUNDLE_AUTO" = 1 ] && [ "$mode" = "hold" ]; then conflict="'보류'와 '자동'은 함께 쓰지 않습니다(예: /refactor:approve 보류 B1)"
  elif [ "$amn" -gt 1 ]; then conflict="'자동' 뒤의 합치는 방식(rebase·squash·merge)은 하나만 붙입니다(예: /refactor:approve B1 자동 squash)"
  fi
fi

say "== /refactor:approve 결과 ($now KST) =="
if [ -n "$conflict" ]; then
  say "❓ $conflict — 아무것도 바꾸지 않았습니다."
  say "   승인: /refactor:approve P1-1 P1-2    ·    승인 취소: /refactor:approve 보류 P1-2"
  say "   묶음 승인: /refactor:approve B1    ·    묶음 승인 취소: /refactor:approve 보류 B1    ·    자동 모드: /refactor:approve B1 자동"
  say "   기준선 허용: /refactor:approve 허용 P1-1    ·    허용 닫기: /refactor:approve 허용 닫기    ·    올리기 허락: /refactor:approve 푸시"
  say "   PR 합치기: /refactor:approve 합치기 68 rebase    ·    합친 뒤 새 작업 가지: /refactor:approve 새 가지"
  say "   잠깐 멈춤: /refactor:approve 잠깐 멈춤 2시간    ·    다시 켜기: /refactor:approve 다시 시작"
  exit 0
fi
[ -n "$bad" ] && say "❓ 알아듣지 못한 입력:$bad"
if [ "$mode" = "approve" ]; then act_word="승인"; else act_word="보류"; fi
if [ -n "$special" ] && { [ -n "$ids$phases" ] || [ "$want_base" = 1 ] || [ "$mode" = "hold" ]; }; then
  say "❓ '확인'·'마무리'는 단독으로 입력하세요(예: /refactor:approve 확인). 아무것도 바꾸지 않았습니다."
  exit 0
fi
# 0.4.2 F5: 잠깐 멈춤 중에는 단계·묶음·보류·baseline·허용·푸시·합치기·자동·새 가지 입력을 받지 않는다
#   (현황 보기·마무리·다시 시작·확인·허용 닫기만 — 멈춤 판정은 안전장치와 같은 조건 rl_pause_state)
if [ "$rw" = 1 ] && [ -f "$dir/.allow-pause" ] && [ "$mode" != "pause" ] && [ "$mode" != "resume" ] && [ "$close" != 1 ] \
   && [ "$special" != "done" ] && [ "$special" != "confirm" ] && rl_pause_state "$dir"; then
  say "⏸ 잠깐 멈춤 중($(rl_hm "$RL_PUNTIL") 까지) — \`/refactor:approve 다시 시작\` 뒤에 다시 입력하세요(아무것도 바꾸지 않았습니다)."
  exit 0
fi

set_state_front() { # $1 awk 변수 이름=값들 — STATE.md 앞머리 칸 갱신
  # 0.4.0 B = current_bundle(지금 묶음) — 칸이 있으면 고치고, 없으면(0.4.0 전 STATE) 앞머리 끝(닫는 --- 앞)에 넣는다(#18). "-" 는 따옴표로
  [ -f "$state" ] || return 0
  local tmp="$state.tmp.$$"
  awk "$@" '
    function cb() { return "current_bundle: " (B == "-" ? "\"-\"" : B) }
    NR == 1 && $0 ~ /^---/ { fm = 1; print; next }
    fm && $0 ~ /^---/ { if (B != "" && !hb) print cb(); fm = 0; print; next }
    fm && B != "" && $0 ~ /^current_bundle:/ { print cb(); hb = 1; next }
    fm && A != "" && $0 ~ /^steps_approved:/ { print "steps_approved: " A; next }
    fm && D != "" && $0 ~ /^steps_done:/ { print "steps_done: " D; next }
    fm && T != "" && T > 0 && $0 ~ /^steps_total:/ { print "steps_total: " T; next }
    fm && N != "" && $0 ~ /^next:/ { print "next: \"" N "\""; next }
    fm && U != "" && $0 ~ /^updated:/ { print "updated: " U; next }
    { print }
  ' "$state" > "$tmp" && [ -s "$tmp" ] && mv "$tmp" "$state"
  if [ -e "$tmp" ]; then rm -f "$tmp"; fi
}
# STATE.md 앞머리에 current_bundle 칸이 있나(0.4.0 — 있으면 승인할 때마다 고쳐 둔다. 외부 명령 없이)
state_has_cb() {
  local l fm=0
  [ -f "$state" ] || return 1
  while IFS= read -r l || [ -n "$l" ]; do
    l=${l%$'\r'}
    if [ "$fm" = 0 ]; then case "$l" in ---*) fm=1; continue ;; *) return 1 ;; esac; fi
    case "$l" in ---*) return 1 ;; current_bundle:*) return 0 ;; esac
  done < "$state"
  return 1
}
# 지금 묶음(0.4.0 current_bundle) → CBV(B<숫자> 또는 "-"): 실행 순서(rl_ready_units)의 첫 줄의 묶음 — 첫 줄이 묶음 없는 카드면 "-".
#   $1 실행 대기 ID 들 · $2 그 rl_ready_units 출력 · $3 후보 ID 들(안 끝남·보류 아님). 실행 대기가 없으면 후보로 다음 묶음을 짐작한다
#   (묶음을 합친 뒤 다음 묶음을 아직 승인하기 전 — 새 가지 이름에 쓴다)
cur_bundle() {
  local u=$2
  CBV="-"
  if [ -z "${1// /}" ]; then
    [ -n "${3// /}" ] || return 0
    u=$(rl_ready_units "$plan" "$3")
  fi
  u=${u%%"$RL_NL"*}; u=${u%%"$US"*}
  [ -n "$u" ] && CBV=$u
  return 0
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

# ── 다시 시작(0.4.2 F5): 멈춤 파일을 지워 안전장치를 다시 켠다 — 켜는 쪽(안전한 방향)이라 봉인이 깨져 있어도 지운다 ──
#   기록 줄 "| 다시 시작 | - | - | - |" + 봉인은 봉인이 그대로일 때만(밖에서 바뀐 기록을 이 줄로 덮어 인정하지 않게) ·
#   마무리 확인 뒤면 줄을 남기지 않는다(마무리는 기록의 마지막 줄이어야 인정된다). 그다음 멈춤 중 바뀐 기준선·마이그레이션을 한 번 알린다
if [ "$mode" = "resume" ]; then
  pf="$dir/.allow-pause"
  if [ ! -f "$pf" ]; then say "ℹ️ 잠깐 멈춤 중이 아닙니다(.allow-pause 없음) — 안전장치는 켜져 있습니다(아무것도 바꾸지 않았습니다)."; exit 0; fi
  rl_pause_state "$dir"; phd=$RL_PHEAD
  rm -f "$pf"
  if [ -f "$pf" ]; then say "⚠️ 멈춤 파일(.allow-pause)을 지우지 못했습니다 — 터미널에서 rm \"$pf\""; exit 0; fi
  if rl_done_confirmed "$dir"; then
    :
  elif rl_log_intact "$dir"; then
    printf '%s KST | 다시 시작 | - | - | - | 사용자가 /refactor:approve 로 실행\n' "$now" >> "$log"
    rl_log_seal "$dir"
  else
    say "   (승인 기록이 봉인과 달라 기록에 '다시 시작' 줄을 남기지 않았습니다 — /refactor:approve 확인 먼저)"
  fi
  say "▶ 잠깐 멈춤을 끝냈습니다 — 안전장치가 다시 켜졌습니다. 이어 하려면 /refactor:go"
  rl_pause_changes "$proj" "$phd"
  rl_pause_branch "$proj" "$phd"
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
  if [ -n "$ids$phases$special$bundles" ] || [ "$want_base" = 1 ] || [ "$mode" = "allow" ] || [ "$mode" = "push" ] || [ "$mode" = "branch" ] || [ "$mode" = "merge" ] || [ "$mode" = "pause" ]; then say "   (그래서 이번 요청은 처리하지 않았습니다.)"; exit 0; fi
fi

# ── 잠깐 멈춤(0.4.2 F5 — /refactor:approve 잠깐 멈춤 [N시간], 사람만): 리팩토링 중 같은 폴더의 평소 작업을 N시간(기본 1 · 최대 12) 막지 않게 한다 ──
#   만들기 = docs/refactor/.allow-pause 1줄 "<만료 epoch> <N> <시작 HEAD 40자>" + 기록 "| 잠깐 멈춤 | - | - | until=<epoch> <N>시간 head=<7자> |" + 봉인.
#   안전장치(guard.sh)는 파일·기록이 맞고 만료 전일 때만 건너뛸 규칙 목록을 건너뛴다(승인 위조 방어·사람 전용 파일·비밀값·설정 보호는 그대로).
#   거절(아무것도 안 바꿈): 마무리 뒤 · 이미 멈춤 중 · 단계 실행 중(STATE current_step "(진행 중)") · 자동 모드·허락 진행 신호(.turn-auto·.turn-nextok·
#   .turn-merged·.turn-mergetp·.turn-merge·.turn-push — 남의 세션 것 포함) · 기준선 허용 열림 · git 커밋을 못 읽음 (봉인 깨짐·--from-hook 아님은 위에서)
if [ "$mode" = "pause" ]; then
  pz_no() { say "$1"; [ -n "${2:-}" ] && say "   $2"; say "   (아무것도 바꾸지 않았습니다 — 잠깐 멈춤을 켜지 않았습니다.)"; exit 0; }
  if rl_done_confirmed "$dir"; then say "ℹ️ 이미 마무리되어 안전장치가 꺼져 있습니다 — 잠깐 멈춤이 필요 없습니다(아무것도 바꾸지 않았습니다)."; exit 0; fi
  pnow=$(date +%s); RL_PNOW=$pnow
  if rl_pause_state "$dir"; then
    pz_no "ℹ️ 이미 잠깐 멈춤 중입니다($(rl_hm "$RL_PUNTIL") 까지 · 남은 $(( (RL_PUNTIL - pnow + 59) / 60 ))분)." "시간을 바꾸려면 /refactor:approve 다시 시작 → /refactor:approve 잠깐 멈춤 <N>시간"
  fi
  pcs=""; pfm=0
  if [ -f "$state" ]; then
    while IFS= read -r x || [ -n "$x" ]; do
      x=${x%$'\r'}
      if [ "$pfm" = 0 ]; then case "$x" in ---*) pfm=1; continue ;; *) break ;; esac; fi
      case "$x" in ---*) break ;; current_step:*) pcs=${x#current_step:}; break ;; esac
    done < "$state"
  fi
  case "$pcs" in *"(진행 중)"*)
    pcs=${pcs#"${pcs%%[![:space:]]*}"}
    pz_no "⛔ 단계를 실행하는 중입니다(STATE current_step: $pcs) — 단계 실행 중에는 잠깐 멈출 수 없습니다." "단계가 끝나 보고를 받은 뒤 다시 입력하세요" ;;
  esac
  set +f
  for x in "$dir"/.turn-auto.* "$dir"/.turn-nextok.* "$dir"/.turn-merged.* "$dir"/.turn-mergetp.* "$dir"/.turn-merge.* "$dir"/.turn-push.*; do
    [ -e "$x" ] || continue
    set -f
    # .turn-merged.* 는 사람 입력으로 안 지워진다(합친 뒤 읽기 단계가 끝나거나 하루 정리 때 — turn.sh) → 문구 따로
    case "${x##*/}" in .turn-merged.*)
      pz_no "⛔ 합친 뒤 확인 차례가 진행 중입니다(docs/refactor/${x##*/})." "합친 뒤 읽기 단계가 끝나거나 하루 정리 뒤에 다시 입력하세요" ;;
    esac
    pz_no "⛔ 자동 모드나 푸시·합치기 허락이 진행 중입니다(docs/refactor/${x##*/})." "그 차례가 끝난 뒤(아무 말이나 입력하면 허락이 끝납니다 — 다른 대화의 것이면 그 대화에서) 다시 입력하세요"
  done
  set -f
  [ -f "$af" ] && pz_no "⛔ 기준선 허용이 열려 있습니다(.allow-baseline-edit)." "먼저 /refactor:approve 허용 닫기 → 그다음 /refactor:approve 잠깐 멈춤"
  phd=$(git --no-replace-objects -c core.fsmonitor=false -C "$proj" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null)
  [[ $phd =~ ^[0-9a-f]{40}$ ]] || pz_no "❓ 지금 커밋을 읽지 못했습니다(git 저장소가 아니거나 커밋이 없음)." "잠깐 멈춤은 커밋이 있는 git 저장소에서만 씁니다"
  puntil=$((pnow + pzn * 3600)); pf="$dir/.allow-pause"
  if [ -d "$pf" ] || ! { printf '%s %s %s\n' "$puntil" "$pzn" "$phd" > "$pf.tmp.$$" && mv -f "$pf.tmp.$$" "$pf"; }; then
    rm -f "$pf.tmp.$$"; pz_no "⚠️ 멈춤 파일(.allow-pause)을 쓰지 못했습니다."
  fi
  if ! { printf '%s KST | 잠깐 멈춤 | - | - | until=%s %s시간 head=%s | 사용자가 /refactor:approve 로 실행\n' "$now" "$puntil" "$pzn" "${phd:0:7}" >> "$log"; } 2>/dev/null; then
    rm -f "$pf"; pz_no "⚠️ 승인 기록을 쓰지 못했습니다."
  fi
  rl_log_seal "$dir"
  say "⏸ 잠깐 멈춤: $(rl_hm "$puntil") 까지(${pzn}시간) — 이 폴더의 평소 작업(푸시·stash·가지 바꾸기·배포·포맷터·기준선·마이그레이션)을 안전장치가 막지 않습니다."
  say "   승인 위조 방어·사람 전용 파일(승인 기록·허용 파일)·비밀값 읽기·설정 파일 보호는 그대로입니다 · PR 합치기와 되돌릴 수 없는 지우기(DB 초기화·앱·릴리스·원격 가지 삭제)도 멈춤 중에 막힙니다 · 리팩토링(/refactor:go)은 멈춤이 끝난 뒤에."
  say "   일찍 끝내려면 /refactor:approve 다시 시작 · 시간이 지나면 저절로 다시 켜집니다(그때 멈춤 중 바뀐 기준선·마이그레이션을 한 번 알립니다)."
  exit 0
fi

# ── 자동 모드(0.4.0 — /refactor:approve B1 자동 [방식]): 묶음 승인 전에 켤 수 있는지 먼저 본다(하나라도 안 되면 ❓ — 아무것도 안 바꿈) ──
#   PROFILE 의 자동 모드 칸(👤 사람이 적음): 운영 주소 · 배포 방식(기존 칸 — '수동'이면 합치기까지만 = merge-only) · 배포 끝 보는 법 · 판 표지 · 확인할 화면 표.
#   통과하면 묶음 승인 뒤(아래 계획서 단계) 기록 "| 자동 | B1 | - | <epoch> <가지> <방식> |" + 허락 파일 docs/refactor/.turn-auto.B1 을 만든다
auto_no() { say "❓ $1 — 자동 모드를 켜지 않았습니다(아무것도 바꾸지 않았습니다)."; [ -n "${2:-}" ] && say "   $2"; exit 0; }
# PROFILE 의 "- <칸 이름>:" 줄 값(앞뒤 공백 뗌 · 괄호로 시작하면 안내 글이라 빈 값) → PV
prof_val() {
  local x v
  PV=""
  [ -f "$dir/PROFILE.md" ] || return 0
  while IFS= read -r x || [ -n "$x" ]; do
    x=${x%$'\r'}
    case "$x" in "- $1:"*) ;; *) continue ;; esac
    v=${x#"- $1:"}
    v=${v#"${v%%[![:space:]]*}"}; v=${v%"${v##*[![:space:]]}"}
    case "$v" in "("*|"（"*) v="" ;; esac
    PV=$v
    return 0
  done < "$dir/PROFILE.md"
}
if [ "$BUNDLE_AUTO" = 1 ]; then
  if rl_done_confirmed "$dir"; then say "ℹ️ 이미 마무리되어 안전장치가 꺼져 있습니다 — 자동 모드는 리팩토링 중에만 씁니다(아무것도 바꾸지 않았습니다)."; exit 0; fi
  [ -z "$bad" ] || auto_no "알아듣지 못한 입력이 있습니다:$bad" "예: /refactor:approve${bundles} 자동 squash (방식은 묶음 이름과 '자동' 뒤에)"
  asid=${REFACTOR_TURN_SID:-}
  [[ $asid =~ ^[A-Za-z0-9_-]{1,128}$ ]] || auto_no "대화(세션) 정보를 받지 못했습니다" "입력창에 /refactor:approve${bundles} 자동 을 다시 쳐 주세요."
  command -v git >/dev/null 2>&1 || auto_no "git 을 찾지 못했습니다"
  command -v gh >/dev/null 2>&1 || auto_no "gh(GitHub CLI)를 찾지 못했습니다" "자동 모드는 gh 로 PR 을 만들고 합칩니다 — 묶음만 승인하려면 /refactor:approve${bundles}"
  abr=$(git -C "$proj" symbolic-ref -q --short HEAD 2>/dev/null); agrc=$?
  [ "$agrc" -gt 1 ] && auto_no "이 폴더는 git 저장소가 아니거나 git 이 저장소 설정을 읽지 못했습니다"
  { [ "$agrc" = 1 ] || [ -z "$abr" ]; } && auto_no "지금 가지가 없습니다(특정 커밋에 떨어진 상태)"
  { [[ $abr =~ ^[A-Za-z0-9._/-]+$ ]] && [[ $abr =~ ^[A-Za-z0-9_] ]]; } || auto_no "가지 이름($abr)에 영문·숫자·._/- 밖의 글자가 있거나 첫 글자가 - . / 입니다"
  rl_origin_base "$proj" || auto_no "origin 의 기본 가지를 찾지 못했습니다(origin/HEAD·origin/main·origin/master 참조 없음)"
  case "$abr" in main|master|"$RL_BNAME") auto_no "지금 가지($abr)가 기본 가지입니다 — 자동 모드는 작업 가지에서만 씁니다" ;; esac
  # 자동 모드 스크립트 명령의 두 경로(안전장치가 따옴표 안 $ ` " 를 받지 않는다 — 합치기 허락과 같은 확인)
  aroot=${REFACTOR_ROOT:-}; aroot=${aroot//"\\"//}; aroot=${aroot%/}
  case "$aroot$RL_TAB$proj" in *'"'*|*'$'*|*'`'*|*'\'*|*"$RL_NL"*|*$'\r'*) aroot="" ;; esac
  [ -n "$aroot" ] || auto_no "플러그인·프로젝트 폴더 경로에 특수 글자가 있어(또는 비어 있어) 자동 모드 명령을 만들 수 없습니다"
  [ -f "$dir/PROFILE.md" ] || auto_no "docs/refactor/PROFILE.md 가 없습니다"
  APF="docs/refactor/PROFILE.md 의 '자동 모드' 칸(👤 사람이 적음)을 채운 뒤 다시: /refactor:approve${bundles} 자동"
  # ⑦ 운영 주소: http(s) 주소 하나(백틱은 뗌 · 공백·따옴표·<>·; 없음) — 끝의 / 는 뗀다
  prof_val "운영 주소"; aurl=${PV//\`/}
  [ -n "$aurl" ] || auto_no "운영 주소가 비어 있습니다" "$APF"
  re_aurl='^https?://[A-Za-z0-9._~:/@%+=,!*-]+$'; re_apath='^/[A-Za-z0-9._~/@%+=,!*-]*$'
  [[ $aurl =~ $re_aurl ]] || auto_no "운영 주소($aurl)가 http(s) 주소 꼴이 아닙니다(공백·따옴표·?·# 없이)" "$APF"
  aurl=${aurl%/}
  # ⑫ 배포 방식(기존 칸 재사용): '수동'이 들어 있으면 합치기까지만(merge-only — 결정 라)
  prof_val "배포 방식"; amode=auto
  case "$PV" in *수동*) amode=merge-only ;; esac
  # ⑧ 배포 끝 보는 법: vercel / railway / cloudflare / netlify / github / 주소 표지(= 판 표지만 봄)
  prof_val "배포 끝 보는 법"; v=${PV//\`/}; upper_ascii "$v"; ahost=""
  case "$UPV" in
    VERCEL*) ahost=vercel ;; RAILWAY*) ahost=railway ;; CLOUDFLARE*|WRANGLER*) ahost=cloudflare ;; NETLIFY*) ahost=netlify ;;
    GITHUB*) ahost=github ;; "주소 표지"*|주소표지*|"판 표지"*) ahost=marker ;;
  esac
  if [ -z "$ahost" ]; then
    if [ -n "$v" ]; then auto_no "배포 끝 보는 법($v)을 알아듣지 못했습니다(vercel / railway / cloudflare / netlify / github / 주소 표지 중 하나)" "$APF"; fi
    [ "$amode" = merge-only ] || auto_no "배포 끝 보는 법이 비어 있습니다(배포가 끝났는지 볼 방법 — 배포를 사람이 하는 저장소면 '배포 방식' 칸에 수동)" "$APF"
    ahost=-
  fi
  # ⑨ 판 표지: 백틱 하나 = 경로(/ 로 시작 — 본문 첫 줄이 판 표지) · 백틱 둘 = 경로 + 그 앞 글자(본문에서 그 글자 바로 뒤부터 " ' < 공백 앞까지)
  #   → 한 줄 "<경로>→<앞 글자>". railway·cloudflare·netlify·주소 표지는 판 표지가 꼭 있어야 한다(#7 — sha 로 배포를 못 가림)
  prof_val "판 표지"; v=$PV; amark=""; ampath=""; ampre=""
  if [ -n "$v" ]; then
    case "$v" in *\`*\`*) ;; *) auto_no "판 표지($v)는 경로를 백틱으로 적습니다(예: \`/version.txt\`)" "$APF" ;; esac
    v=${v#*\`}; ampath=${v%%\`*}; v=${v#*\`}
    case "$v" in *\`*\`*) v=${v#*\`}; ampre=${v%%\`*} ;; esac
    [[ $ampath =~ $re_apath ]] || auto_no "판 표지의 경로($ampath)가 / 로 시작하는 주소 꼴이 아닙니다(공백·?·# 없이)" "$APF"
    case "$ampre" in *"→"*|*";"*) auto_no "판 표지의 앞 글자에 → 나 ; 를 쓸 수 없습니다" "$APF" ;; esac
    amark="$ampath→$ampre"
  fi
  case "$ahost" in railway|cloudflare|netlify|marker)
    [ "$amode" = merge-only ] || [ -n "$amark" ] || auto_no "배포 끝 보는 법이 $ahost 이면 판 표지가 꼭 있어야 합니다(새 배포인지 판 표지로만 알 수 있음)" "$APF" ;;
  esac
  # ⑩ 확인할 화면: "- 확인할 화면:" 줄 뒤의 표 | 경로 | 기대 글자 | (머리·구분 줄 빼고 1~5줄) → "경로→기대 글자;경로→기대 글자"
  ascr=""; an=0; ain=0
  while IFS= read -r x || [ -n "$x" ]; do
    x=${x%$'\r'}
    if [ "$ain" = 0 ]; then case "$x" in "- 확인할 화면:"*) ain=1 ;; esac; continue; fi
    # 표 앞의 빈 줄은 건너뛰고, 표가 아닌 글(다음 칸·다음 절)이 나오거나 표가 끝나면 그친다(다른 절의 표로 새지 않게)
    case "$x" in "|"*) ;; *[![:space:]]*) break ;; *) [ "$ain" = 2 ] && break; continue ;; esac
    ain=2
    c1=${x#|}; c2=${c1#*|}; c1=${c1%%|*}; c2=${c2%%|*}
    c1=${c1//\`/}; c1=${c1#"${c1%%[![:space:]]*}"}; c1=${c1%"${c1##*[![:space:]]}"}
    c2=${c2#"${c2%%[![:space:]]*}"}; c2=${c2%"${c2##*[![:space:]]}"}
    case "$c1" in 경로|"") continue ;; esac
    case "$c1" in -*|:-*) continue ;; esac
    [[ $c1 =~ $re_apath ]] || auto_no "확인할 화면의 경로($c1)가 / 로 시작하는 주소 꼴이 아닙니다(공백·?·# 없이)" "$APF"
    case "$c1" in */api/*|/api) auto_no "확인할 화면에 /api/ 주소($c1)는 넣지 않습니다(사람이 보는 화면만)" "$APF" ;; esac
    [ -n "$c2" ] || auto_no "확인할 화면 $c1 의 기대 글자가 비어 있습니다" "$APF"
    case "$c2" in *"→"*|*";"*) auto_no "확인할 화면 $c1 의 기대 글자에 → 나 ; 를 쓸 수 없습니다" "$APF" ;; esac
    an=$((an + 1)); ascr="$ascr;$c1→$c2"
  done < "$dir/PROFILE.md"
  [ "$an" -gt 0 ] || auto_no "확인할 화면이 비어 있습니다" "$APF"
  [ "$an" -le 5 ] || auto_no "확인할 화면이 ${an}줄입니다(5줄까지)" "$APF"
  ascr=${ascr#;}
  # ⑤ 합치는 방식: 입력 → PROFILE "- PR 합치는 방식:" 칸 → 없으면 ❓(#19)
  if [ -z "$amth" ]; then
    prof_val "PR 합치는 방식"; v=${PV//\`/}; upper_ascii "$v"
    case "$UPV" in REBASE) amth=rebase ;; SQUASH) amth=squash ;; MERGE) amth=merge ;; esac
  fi
  [ -n "$amth" ] || auto_no "합치는 방식을 모릅니다(PROFILE.md 의 '- PR 합치는 방식:' 칸이 없거나 비어 있음)" "방식을 붙여 다시: /refactor:approve${bundles} 자동 squash"
  atp=${REFACTOR_TRANSCRIPT_PATH:-}
  case "$atp" in *"$RL_NL"*|*$'\r'*) atp="" ;; esac
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
    say "   기본 가지 올리기는 사람이 터미널에서 · PR 합치기는 /refactor:approve 합치기 로 합니다."
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
  say "   기본 가지 올리기·강제 push 는 계속 막힙니다 · PR 합치기는 /refactor:approve 합치기 로."
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
  # 판정·이름 계산·옮기기·확인·기록·봉인은 lib rl_new_branch(0.4.0 — 자동 모드 verify 와 함께 씀 · 기록 끝 칸만 다름)
  rl_new_branch "$proj" "$nbname" "사용자가 /refactor:approve 로 실행" "$now"; nrc=$?
  printf '%s' "$RL_NBOUT"
  [ "$nrc" = 0 ] && say "다음: /refactor:go"
  exit 0
fi

# ── PR 합치기 허락(0.3.5): 이번 차례에만 지금 가지의 PR 을 합쳐도 된다는 표시 docs/refactor/.turn-merge.<세션ID> 를 만든다 ──
#   0.3.4 는 여기서 gh 로 확인·합치기까지 했으나 입력 훅 30초 안에 끝나지 못했다 → 이 모드는 로컬 확인 + 허락 파일 + 기록 한 줄만(네트워크 0 —
#   gh·fetch·mktemp·rl_bounded 를 부르지 않는다). 확인·합치기는 Claude 가 이번 차례에 허락 파일 3줄째 명령(scripts/refactor-merge.sh)으로 한다.
#   허락 파일 3줄(LF): "merge <가지> <PR번호|-> <rebase|squash|merge> <HEAD 커밋>" / 만든 시각(초) / 허락된 명령 글자 그대로
#     bash "<REFACTOR_ROOT>/hooks/run.sh" refactor-merge "<프로젝트 폴더>" <세션ID>   — 안전장치(guard)는 이 줄과 글자 그대로 같은 명령만 통과시킨다
#   입력 훅이 그 세션의 다음 사람 입력 때 지우고, 안전장치·합치기 스크립트는 30분이 지난 것을 무시한다
if [ "$mode" = "merge" ]; then
  mg_no() { say "$1"; say "   (아무것도 바꾸지 않았습니다 — 합치기 허락을 만들지 않았습니다)"; exit 0; }
  [ -n "$bad" ] && mg_no "   예: /refactor:approve 합치기 68 rebase  (PR 번호와 방식 rebase·squash·merge 만 받습니다)"
  if rl_done_confirmed "$dir"; then
    say "ℹ️ 이미 마무리되어 안전장치가 꺼져 있습니다 — 평소처럼 합칠 수 있습니다(아무것도 바꾸지 않았습니다)."
    exit 0
  fi
  msid=${REFACTOR_TURN_SID:-}
  [[ $msid =~ ^[A-Za-z0-9_-]{1,128}$ ]] || mg_no "⚠️ 대화(세션) 정보를 받지 못했습니다 — 입력창에 /refactor:approve 합치기 를 다시 쳐 주세요"
  command -v git >/dev/null 2>&1 || mg_no "❓ git 을 찾지 못했습니다"
  br=$("${G[@]}" symbolic-ref -q --short HEAD 2>/dev/null); grc=$?
  [ "$grc" -gt 1 ] && mg_no "❓ 이 폴더는 git 저장소가 아니라(또는 git 이 저장소 설정을 읽지 못해) 합칠 수 없습니다: $proj"
  { [ "$grc" = 1 ] || [ -z "$br" ]; } && mg_no "❓ 지금 가지가 없습니다(특정 커밋에 떨어진 상태) — 작업 가지로 옮긴 뒤 다시 입력하세요"
  rl_origin_base "$proj" || mg_no "❓ origin 의 기본 가지를 찾지 못했습니다(origin/HEAD·origin/main·origin/master 참조 없음)"
  bname=$RL_BNAME
  [ "$br" = "$bname" ] && mg_no "⛔ 지금 가지가 기본 가지($bname)입니다 — 작업 가지의 PR 만 합칩니다"
  # 안전장치·합치기 스크립트가 허락 파일 1줄을 읽는 꼴과 같게: 첫 글자는 영문·숫자·_, 나머지는 영문·숫자·._/-
  [[ $br =~ ^[A-Za-z0-9._/-]+$ ]] || mg_no "❓ 가지 이름($br)에 영문·숫자·._/- 밖의 글자가 있어 허락할 수 없습니다 — 사람이 GitHub 화면에서 합쳐 주세요"
  [[ $br =~ ^[A-Za-z0-9_] ]] || mg_no "❓ 이 가지 이름($br)은 허락할 수 없습니다(첫 글자가 - . / 임) — 사람이 GitHub 화면에서 합쳐 주세요"
  hoid=$("${G[@]}" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null) || mg_no "❓ 지금 커밋을 읽지 못했습니다"
  [[ $hoid =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || mg_no "❓ 지금 커밋을 읽지 못했습니다"
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
  # 허락된 명령의 두 경로(역슬래시는 / 로, 끝 / 뗌 — 프로젝트 폴더는 위에서 이미). 큰따옴표 한 쌍 안에 그대로 넣으므로 " $ ` \ 줄바꿈이 있으면 거절
  mroot=${REFACTOR_ROOT:-}; mroot=${mroot//"\\"//}; mroot=${mroot%/}
  case "$mroot$RL_TAB$proj" in *'"'*|*'$'*|*'`'*|*'\'*|*"$RL_NL"*|*$'\r'*) mroot="" ;; esac
  { [ -n "$mroot" ] && [ -n "$proj" ]; } || mg_no "❓ 플러그인·프로젝트 폴더 경로에 특수 글자가 있어(또는 비어 있어) 허락할 수 없습니다 — 사람이 GitHub 화면에서 합쳐 주세요"
  mcmd="bash \"$mroot/hooks/run.sh\" refactor-merge \"$proj\" $msid"
  mf="$dir/.turn-merge.$msid"
  if [ -d "$mf" ] || ! { printf 'merge %s %s %s %s\n%s\n%s\n' "$br" "${mprn:--}" "$mth" "$hoid" "$(date +%s)" "$mcmd" > "$mf.tmp.$$" && mv -f "$mf.tmp.$$" "$mf"; }; then
    rm -f "$mf.tmp.$$"; mg_no "⚠️ 합치기 허락 파일을 쓰지 못했습니다"
  fi
  # 기록 줄의 PR 칸: "PR #<번호>" 또는 "PR(지금 가지)" — 합치기 스크립트가 기록의 마지막 줄을 이 꼴로 대조한다(0.3.5 보완 F7①)
  if [ -n "$mprn" ]; then mprw="PR #$mprn"; mprs=" #$mprn"; else mprw="PR(지금 가지)"; mprs=""; fi
  # 기록을 못 쓰면 기록 없는 허락이 남지 않게 허락 파일을 지운다(F13)
  if ! { printf '%s KST | 합치기 | 허락 %s %s (%s) @%s | - | 사용자가 /refactor:approve 로 실행\n' "$now" "$br" "$mprw" "$mth" "${hoid:0:7}" >> "$log"; } 2>/dev/null; then
    rm -f "$mf"; mg_no "⚠️ 승인 기록을 쓰지 못해 합치기 허락을 만들지 않았습니다"
  fi
  rl_log_seal "$dir"
  # 0.3.7: 입력 훅이 넘긴 대화 기록 경로(REFACTOR_TRANSCRIPT_PATH = 훅 입력의 transcript_path)가 읽을 수 있는 파일이면 .turn-mergetp.<세션ID> 에
  #   경로·크기·허락 시각 세 줄 — 합치기 스크립트가 확인 도중 대화 기록에 사람 입력이 생기면 바로 멈춘다. 허락 파일 3줄은 그대로(안전장치·H8).
  #   경로가 없거나 파일이 아니면 만들지 않는다(감시 꺼짐 = 0.3.6 과 같은 동작). 입력 훅이 다음 사람 입력 때 허락과 함께 지운다
  #   2번째 줄 = 지금(허락하는 순간) 그 파일의 바이트 수(0.3.7 보완 F1) — 합치기 스크립트는 실행마다가 아니라 이 크기 뒤에 생긴 사람 입력을 본다
  #   (허락 뒤 첫 실행 전·되풀이 사이에 친 말도 잡힘). 이 허락을 친 입력 자신의 enqueue 줄은 보통 이 크기 안에 들지만(실측: 줄 시각이 몇 초 앞섬)
  #   3번째 줄 = 허락 시각 UTC 초 YYYY-MM-DDTHH:MM:SS(보완 G1 — 재검사 A2 #1): 대화 기록은 비동기로 늦게 쓰일 수 있어(공식 훅 문서) 그 줄이 크기 뒤에
  #   오면 합치기 스크립트가 사람 입력으로 보고 늘 멈춘다 → 줄의 "timestamp"(UTC) 가 이 초보다 뒤인 줄만 사람 입력으로 본다
  #   (0.4.0: 경로 확인·세 줄 쓰기는 lib rl_mergetp_write — 자동 모드 merge 단계와 같이 쓴다)
  mtp="$dir/.turn-mergetp.$msid"
  rl_mergetp_write "$mtp" "${REFACTOR_TRANSCRIPT_PATH:-}"
  # 30분 경고: 입력 감시를 켰으면(경로 파일을 만듦) 몇 초 안에 · 못 켰으면 0.3.6 문구(Esc 먼저 — 입력만 하면 최대 약 2분 뒤)
  if [ -f "$mtp" ]; then
    mwarn="멈추려면 아무 말이나 입력하세요 — 입력하면 몇 초 안에 허락이 끝납니다(대화 기록을 못 볼 때는 지금 도는 확인 한 번이 끝난 뒤, 최대 약 2분 뒤). Claude 가 실행 중이면 Esc 로도 멈춥니다."
  else
    mwarn="멈추려면 아무 말이나 입력하세요 — Claude 가 실행 중이면 먼저 Esc 를 누르세요(Esc 없이 입력만 하면 지금 도는 확인 한 번이 끝난 뒤, 최대 약 2분 뒤에 허락이 끝납니다)."
  fi
  say "✅ 합치기 허락: 작업 가지 $br 의 PR$mprs 을 $mth 방식으로 — 이번 차례에만(다음 입력부터 다시 막힘 · 30분 안) · 지금 커밋(${hoid:0:7})일 때만."
  say "   Claude 가 이번 차례에 Bash 도구로 아래 명령을 그대로 실행합니다(다른 것을 붙이지 않음):"
  say "   $mcmd"
  say "   스크립트가 확인한 뒤 합칩니다: 자동 검사가 모두 끝나 초록(도는 중이면 \"같은 명령을 다시\"가 나옵니다 — 끝날 때까지 되풀이) · 기본 가지에 새 커밋 없음 · PR 의 마지막 커밋 = 지금 커밋."
  say "   하나라도 어긋나면 합치지 않고 허락도 끝납니다(다시 하려면 /refactor:approve 합치기)."
  say "   ⚠️ 기본 가지에 합쳐지면 운영 배포가 시작될 수 있습니다."
  say "   ⚠️ 허락한 뒤 최대 30분 사이에는 사람이 보고 있지 않아도 조건이 맞으면 합쳐지고 운영 배포가 시작될 수 있습니다 — $mwarn"
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
      [ "$found" = 0 ] && say "❓ 계획서에 $ph_(Phase 전체)의 단계가 없습니다."
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
  # 0.4.2 F5: 잠깐 멈춤 파일도 지운다(다음 주기 /refactor:go 다시 때 남은 멈춤이 이어지지 않게 — 기록에는 줄을 더하지 않는다)
  #   지우기 전에 멈춤 중 바뀐 기준선·마이그레이션을 한 번 알린다(다시 시작·만료와 같게 — 사장님 S7-2)
  if [ -f "$dir/.allow-pause" ]; then
    rl_pause_state "$dir"
    rl_pause_changes "$proj" "$RL_PHEAD"
    rm -f "$dir/.allow-pause"
    [ -f "$dir/.allow-pause" ] || say "▶ 잠깐 멈춤 파일(.allow-pause)도 지웠습니다."
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
    [ -n "$ids$phases$bundles" ] && say "❓ 계획서(REFACTOR_PLAN.md)가 아직 없습니다. /refactor:go 로 계획서 단계까지 진행하세요."
  else
    # 카드는 한 번만 읽는다: 본문(c<순번>)·다시 쓴 뒤 본문(a<순번>)·지문(sums)을 임시 폴더 하나에 남겨
    # 승인 때 남길 카드 내용과 승인 뒤 현황을 여기서 얻는다(계획서를 두 번 읽지 않는다)
    cdir=""
    if [ "$rw" = 1 ]; then
      cdir=$(mktemp -d 2>/dev/null) || cdir=$(mktemp -d -t rlcards 2>/dev/null) || cdir=""
      [ -n "$cdir" ] && trap 'rm -rf "$cdir"' EXIT
    fi
    recs=$(RL_CARDDIR=$cdir RL_ALT=${cdir:+1} rl_cards "$plan" "$log")
    # Phase 전체(P1)를 단계 ID로 펼친다(완료된 단계는 건너뜀)
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
      [ "$found" = 0 ] && say "❓ 계획서에 $ph_(Phase 전체)의 단계가 없습니다."
    done
    # 0.4.0 묶음(B1)을 카드의 묶음 칸으로 펼친다(완료된 단계는 건너뜀). 묶음마다 먼저 확인해 하나라도 안 되면 그 묶음은 통째로 ❓(아무것도 안 바꿈):
    #   계획서에 그 묶음 카드가 없음 · 모두 완료 · 안 끝난 카드가 5장 초과(#17) · 같은 번호 카드 · 승인 줄 없는 카드.
    #   통과하면 기록 앞에 "| 묶음 승인 | B1 | - | 카드 N개: … |"(보류면 "묶음 보류") 한 줄 — 카드 줄은 아래 기존 루틴이 쓴다(이미 승인된 카드는 다시 안 씀)
    blines=""; bok=""
    if [ -n "$bundles" ]; then
      brecs=$(rl_card_bundles "$plan")
      for b_ in $bundles; do
        ball=0; bc=""; bn=0; bdesc=""; bwhy=""
        while IFS="$US" read -r bk_ bn_ bid_ bb_ bd_ bp_ bdn_; do
          [ "$bk_" = CB ] && [ "$bb_" = "$b_" ] || continue
          ball=$((ball + 1)); [ -z "$bdesc" ] && bdesc=$bd_
          [ "$bdn_" = 1 ] && continue
          case " $bc " in *" $bid_ "*) ;; *) bc="$bc $bid_"; bn=$((bn + 1)) ;; esac
        done <<EOF
$brecs
EOF
        if [ "$ball" = 0 ]; then say "❓ 계획서에 $b_ 묶음이 없습니다(카드의 '- **묶음**: $b_ …' 칸을 찾지 못함 — 묶음을 만들려면 /refactor:go 묶음)."; continue; fi
        # 0.4.0 보완(검사 C#4): 'B1 자동' 은 묶음 카드가 모두 완료여도 묶음 승인 줄(카드 0개)을 남기고 자동 마감만 켠다(앞서 끝낸 카드의 커밋을 합치러)
        if [ "$bn" = 0 ] && ! { [ "$BUNDLE_AUTO" = 1 ] && [ "$mode" = "approve" ]; }; then say "ℹ️ $b_ 묶음의 단계가 모두 완료돼 승인할 것이 없습니다."; continue; fi
        if [ "$bn" -gt 5 ]; then say "❓ $b_ 묶음의 안 끝난 카드가 ${bn}장이라 승인하지 않았습니다(한 묶음은 5장까지 — /refactor:go 묶음 으로 나누게 하세요):$bc"; continue; fi
        for x in $bc; do
          while IFS="$US" read -r kind_ n_ id_ t box done_ cnt k r h hv st; do
            [ "$kind_" = CARD ] && [ "$id_" = "$x" ] || continue
            if [ "${cnt:-1}" -gt 1 ]; then bwhy="[$x] 같은 번호의 단계가 ${cnt}개"; elif [ "$box" = none ]; then bwhy="[$x] 승인 줄이 없음"; fi
            break
          done <<EOF
$recs
EOF
          [ -n "$bwhy" ] && break
        done
        if [ -n "$bwhy" ]; then say "⛔ $b_ 묶음을 승인하지 않았습니다 — $bwhy. /refactor:go 로 계획서를 고치게 한 뒤 다시 승인하세요."; continue; fi
        if [ "$mode" = "approve" ]; then
          blines="$blines$now KST | 묶음 승인 | $b_ | - | 카드 ${bn}개:$bc"$'\n'
          if [ "$bn" = 0 ]; then say "📦 묶음 승인: [$b_${bdesc:+ $bdesc}] 카드 0개 — 묶음 카드가 모두 완료돼 자동 마감만 켭니다"
          else say "📦 묶음 승인: [$b_${bdesc:+ $bdesc}] 카드 ${bn}개:$bc"
          fi
        else
          blines="$blines$now KST | 묶음 보류 | $b_ | - | 카드 ${bn}개:$bc"$'\n'
          say "⏸ 묶음 승인 취소: [$b_${bdesc:+ $bdesc}] 카드 ${bn}개:$bc"
        fi
        bok="$bok $b_"
        for x in $bc; do case " $targets " in *" $x "*) ;; *) targets="$targets $x" ;; esac; done
      done
    fi

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
        elif [ "${cnt:-1}" = 1 ] && [ "$box" != none ]; then
          # 0.4.4 ①(b): 이번에 다시 승인하는 이미 승인된 카드는 허용 파일이 없어도 경로를 읽어 둔다(닫힌 허용 안내 🔒 용 — 읽기만)
          case " $targets " in *" $id_ "*) set -- "$@" "$cdir/c$n_" ;; esac
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
    ra_ids=""; [ "$mode" = "approve" ] && [ -f "$af" ] && ra_ids=$(rl_allow_ids "$dir")   # 0.4.4 ①(b) 🔒 안내용(읽기만)
    ra_pend=""   # 0.4.5: 빈 허용 파일일 때 다시 승인한 🛠 카드("ID=순번") — 이번 승인으로 좁혀져 닫히면 🔒 안내
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
          approved)
            say "ℹ️ 이미 승인됨: [$id] $t"
            # 0.4.4 ①(b): 다시 승인은 닫힌 허용을 다시 열지 않는다(0.3.4 v9) — 🛠 카드(🔧 없음)·기준선 경로 있음·허용 파일이 없거나
            #   파일의 ID 목록에 그 ID 가 없으면(빈 파일 = 전부 허용이면 안 띄움) 여는 명령만 한 줄 알린다. 허용 파일·기록·봉인은 안 바뀐다
            case "$k" in
              *🔧*) ;;
              *🛠*)
                bl_of "$n_"
                case "$BLV" in
                  ""|"?") ;;
                  *) ra_show=0
                     if [ ! -f "$af" ]; then ra_show=1
                     elif [ -n "$ra_ids" ]; then case " $ra_ids " in *" $id "*) ;; *) ra_show=1 ;; esac
                     else ra_pend="$ra_pend $id=$n_"   # 0.4.5: 빈 허용 파일(전부 허용) — 이번 승인으로 좁혀져 닫히면 아래에서 🔒
                     fi
                     [ "$ra_show" = 1 ] && say "   🔒 기준선 허용이 닫혀 있습니다(고칠 기준선: $BLV) — 이 단계가 기준선을 고쳐야 하면 /refactor:approve 허용 $id" ;;
                esac ;;
            esac
            continue ;;
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

    # 묶음 줄은 카드 줄 앞에(카드가 모두 이미 승인돼 있어 카드 줄이 없어도 묶음 승인 줄은 남긴다 — 그 묶음의 정본 카드 목록)
    if [ -n "$blines" ] && [ -z "$acted" ]; then
      printf '%s' "$blines" >> "$log"
      rl_log_seal "$dir"
    fi
    if [ -n "$acted" ]; then
      printf '%s%s' "$blines" "$lines" >> "$log"
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
        # 0.4.5: 빈 허용 파일(전부 허용)이 이번 승인으로 좁혀져 이미 승인된 단계의 허용이 닫혔으면 그 단계마다 여는 명령 한 줄(허용 파일·기록은 그대로)
        if [ "$AW_NARROWED" = 1 ] && [ "$AW_WROTE" = 1 ]; then
          for x in $ra_pend; do
            case " $AW_NEW " in *" ${x%%=*} "*) continue ;; esac
            bl_of "${x#*=}"
            say "   🔒 [${x%%=*}] 기준선 허용이 이번에 닫혔습니다(고칠 기준선: $BLV) — 이 단계가 기준선을 고쳐야 하면 /refactor:approve 허용 ${x%%=*}"
          done
        fi
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

    # 0.4.0 자동 모드: 묶음이 승인됐으면(위 묶음 확인을 통과 — 5장 초과·없는 묶음이면 여기 안 옴) 허락 파일 .turn-auto.<B> 11줄
    #   ① B-ID ② 만든 시각(초) ③ 세션 ID ④ 승인 때 가지 ⑤ 합치는 방식 ⑥ 대화 기록 경로(입력 훅의 transcript_path — 없으면 빈 줄)
    #   ⑦ 운영 주소 ⑧ 배포 끝 보는 법 ⑨ 판 표지("경로→앞 글자" · 없으면 빈 줄) ⑩ 확인할 화면("경로→기대 글자;…") ⑪ "go=" (첫 인자 없는 /refactor:go 때
    #   입력 훅이 시각을 채움) ⑫ merge-only(배포 방식이 수동일 때만). 파일을 쓴 뒤 기록 "| 자동 | B1 | - | <시각> <가지> <방식> |" — 기록을 못 쓰면 파일을 지운다
    if [ "$BUNDLE_AUTO" = 1 ] && [ "$mode" = approve ] && case " $bok " in *" ${bundles# } "*) true ;; *) false ;; esac; then
      ab=${bundles# }; aep=$(date +%s); aaf="$dir/.turn-auto.$ab"
      [ -f "$dir/.turn-autopre.$ab" ] && rm -f "$dir/.turn-autopre.$ab"
      if [ "$amode" = merge-only ]; then a12=$'\n'merge-only; else a12=""; fi
      if [ -d "$aaf" ] || ! { printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\ngo=%s\n' "$ab" "$aep" "$asid" "$abr" "$amth" "$atp" "$aurl" "$ahost" "$amark" "$ascr" "$a12" > "$aaf.tmp.$$" && mv -f "$aaf.tmp.$$" "$aaf"; }; then
        rm -f "$aaf.tmp.$$"; say "⚠️ 자동 모드 허락 파일을 쓰지 못했습니다 — 묶음 승인은 됐습니다. 자동 모드 없이 /refactor:go 로 실행하세요."
      elif ! { printf '%s KST | 자동 | %s | - | %s %s %s%s\n' "$now" "$ab" "$aep" "$abr" "$amth" "${a12:+ merge-only}" >> "$log"; } 2>/dev/null; then
        rm -f "$aaf"; say "⚠️ 승인 기록을 쓰지 못해 자동 모드를 켜지 않았습니다 — 묶음 승인은 됐습니다."
      else
        rl_log_seal "$dir"
        aend=$(TZ=KST-9 date -d "@$((aep + 7200))" '+%H:%M' 2>/dev/null || TZ=KST-9 date -r "$((aep + 7200))" '+%H:%M' 2>/dev/null)
        say "🤖 자동 모드 켬: [$ab${bdesc:+ $bdesc}] — 합치는 방식 $amth · 작업 가지 $abr · 승인 뒤 2시간 안${aend:+(~$aend KST)}"
        # 허락 파일로 복사한 PROFILE 값 넷(검사 A#11·C#8 — 사람이 승인 화면에서 확인)
        say "   운영 주소: $aurl"
        if [ "$ahost" = - ]; then say "   배포 끝 보는 법: 없음(배포는 사람이)"; else say "   배포 끝 보는 법: $ahost"; fi
        if [ -z "$amark" ]; then say "   판 표지: 없음"
        elif [ -n "$ampre" ]; then say "   판 표지: $ampath ('$ampre' 바로 뒤 글자)"
        else say "   판 표지: $ampath (첫 줄)"
        fi
        apl=""; arest=$ascr
        while [ -n "$arest" ]; do aone=${arest%%;*}; [ "$aone" = "$arest" ] && arest="" || arest=${arest#*;}; apl="$apl · ${aone%%"→"*}"; done
        say "   확인할 화면: ${an}개(${apl# · })"
        say "⚠️ 자동 모드: 이 묶음 카드가 다 끝나면 다음 /refactor:go 한 차례에서 Claude 가 푸시·PR·합치기·배포 확인·라이브 검증까지 혼자 합니다 — 기본 가지에 합쳐지면 운영 배포가 시작됩니다. 멈추려면 아무 말이나 입력하세요 — Esc 는 지금 도는 명령만 멈추고 자동 모드는 끄지 않습니다(그 뒤 한마디 입력하면 꺼집니다). 승인 뒤 2시간이 지나면 저절로 꺼집니다."
        [ "$amode" = merge-only ] && say "   배포 방식이 '수동'이라 합치기까지만 합니다 — 배포는 사람이 하고, 끝나면 Claude 에게 라이브 검증을 부탁하세요."
        say "   다음: /refactor:go (인자 없이 — 그 한 차례 안에서만 자동으로 마감합니다 · 그 밖의 입력을 하면 자동 모드가 꺼집니다)"
      fi
    elif [ "$BUNDLE_AUTO" = 1 ]; then
      say "   (묶음이 승인되지 않아 자동 모드도 켜지 않았습니다.)"
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
    n_total=0; n_ap=0; n_done=0; ready=""; pending=""; changed=""; unlogged=""; dups=""; fence_warn=""; cands=""; rtl=""
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
          # 다음 묶음 짐작(실행 대기가 없을 때 current_bundle)용 후보 = 안 끝남·보류 아님·번호 하나
          [ "$st" != held ] && [ "${cnt:-1}" = 1 ] && cands="$cands $id"
          case "$st" in
            approved) [ "${cnt:-1}" -gt 1 ] || [ "$intact" = 0 ] || { ready="$ready $id"; rtl="$rtl$id$RL_TAB$t$RL_NL"; } ;;
            changed) changed="$changed $id" ;;
            *) pending="$pending $id"; [ "$box" = "x" ] && unlogged="$unlogged $id" ;;
          esac ;;
      esac
    done <<EOF
$recs
EOF
    # 0.4.0 실행 대기를 묶음 단위·실행 순서로(/refactor:status 와 같은 꼴) — 실행 대기 카드에 묶음 칸이 하나도 없으면 옛 꼴 한 줄
    units=""; [ -n "$ready" ] && units=$(rl_ready_units "$plan" "$ready")
    say ""
    say "📋 계획서 현황(승인 기록 기준): 전체 ${n_total}단계 · 승인 ${n_ap} · 완료 ${n_done}"
    if [ -n "$units" ]; then
      while IFS="$US" read -r ub_ ud_ ui_; do
        [ -n "$ui_" ] || continue
        if [ -n "$ub_" ]; then
          un_=0; for x in $ui_; do un_=$((un_ + 1)); done
          say "   ▶ 실행 대기: [$ub_${ud_:+ $ud_}] $ui_ ($un_)"
        else
          tl_=${rtl#*"$ui_$RL_TAB"}; tl_=${tl_%%"$RL_NL"*}
          say "   ▶ 실행 대기: [$ui_] $tl_"
        fi
      done <<EOF
$units
EOF
    elif [ -n "$ready" ]; then
      say "   ▶ 실행 대기(승인됨):$ready"
    fi
    [ -n "$changed" ] && say "   🔁 승인 뒤 카드가 바뀜(실행 안 함 — 다시 승인 필요):$changed"
    [ -n "$pending" ] && say "   ⏸ 승인 대기:$pending"
    [ -n "$unlogged" ] && say "   ⚠️ 체크 표시만 있고 승인 기록이 없음(실행 안 함 — 계획서를 손으로 고친 것일 수 있음):$unlogged"
    [ -n "$dups" ] && say "   ⚠️ 같은 번호의 단계가 여러 개:$dups — 계획서 번호를 고쳐야 실행할 수 있습니다."
    [ -n "$fence_warn" ] && say "   ⚠️ 닫히지 않은 코드 블록(\`\`\`)이 ${fence_warn}개 있어 무시했습니다 — 계획서 형식을 확인하세요."
    if [ -z "$ids$phases$bundles" ] && [ "$want_base" = 0 ]; then
      say ""
      say "사용법: /refactor:approve P0-1 P1-2   (단계 번호, 여러 개 가능)"
      say "        /refactor:approve P1          (P1 Phase 전체 — 완료된 단계는 건너뜀)"
      say "        /refactor:approve B1          (B1 묶음 — 카드의 '묶음' 칸이 B1 인 안 끝난 카드 전부, 5장까지 · '묶음 B1' 도 같음)"
      say "        /refactor:approve 보류 B1      (묶음 승인 취소)"
      say "        /refactor:approve B1 자동 [squash] (묶음 승인 + 자동 모드 — 다음 /refactor:go 한 차례에서 Claude 가 푸시·PR·합치기·배포 확인·라이브 검증까지 · 2시간 안)"
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
    if [ -n "$acted$blines" ] || [ "$n_total" != 0 ]; then
      first_ready=${ready# }; first_ready=${first_ready%% *}
      if [ -n "$units" ]; then first_ready=${units%%"$RL_NL"*}; first_ready=${first_ready##*"$US"}; first_ready=${first_ready%% *}; fi
      # 0.4.0 current_bundle(#18): 묶음을 승인·보류했거나 STATE 에 이미 그 칸이 있을 때만 쓴다(옛 계획서의 STATE 는 그대로)
      cbw=""
      if [ "$rw" = 1 ] && { [ -n "$bok" ] || state_has_cb; }; then cur_bundle "$ready" "$units" "$cands"; cbw=$CBV; fi
      if [ -n "$acted$blines" ]; then
        if [ -n "$first_ready" ]; then nxt="/refactor:go 로 승인된 단계 실행 (다음: $first_ready)"; else nxt="계획서 확인 후 /refactor:approve <단계ID>"; fi
        set_state_front -v A="$n_ap" -v D="$n_done" -v T="$n_total" -v N="$nxt" -v U="$RL_TODAY" -v B="$cbw"
      elif [ "$rw" = 1 ]; then
        set_state_front -v A="$n_ap" -v D="$n_done" -v T="$n_total" -v B="$cbw"
      fi
    fi
  fi
fi

if [ -f "$log" ] && { [ -n "${acted:-}" ] || [ "$want_base" = 1 ]; }; then
  say ""
  say "🧾 승인 기록: docs/refactor/APPROVALS.log (승인의 유일한 근거 — 사람만 고칩니다)"
fi
exit 0
