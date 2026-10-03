#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Vibe Refactor — 여러 프로젝트 현황표 (/refactor:board, 읽기만 한다)
#
# 기준 폴더 아래 프로젝트들의 docs/refactor/STATE.md를 모아 급한 순서로 표를 만든다.
#   스킬에서: $1 = 지금 프로젝트 폴더, 표준입력 = 사용자가 준 폴더(없으면 자동)
#   터미널에서: bash refactor-board.sh ~/projects
# 기준 폴더를 안 주면: 지금 폴더가 리팩토링 중인 프로젝트면 그 상위 폴더를, 아니면 지금 폴더를 훑는다.
# ─────────────────────────────────────────────────────────────────────────────

LC_ALL=C
export LC_ALL

here=${1:-$PWD}
here=${here//"\\"//}
here=${here%/}
arg=""
if [ ! -t 0 ]; then IFS= read -r -d '' arg || true; fi
arg=${arg//$'\r'/}
arg=${arg//$'\n'/}
arg="${arg#"${arg%%[![:space:]]*}"}"
arg="${arg%"${arg##*[![:space:]]}"}"
case "$arg" in "~") arg=$HOME ;; "~/"*) arg="$HOME/${arg#\~/}" ;; esac

if [ -n "$arg" ]; then
  root=${arg//"\\"//}
  root=${root%/}
  case "$root" in /*|[A-Za-z]:/*) ;; *) root="$here/$root" ;; esac
elif [ -f "$here/docs/refactor/STATE.md" ]; then
  root=$(cd "$here/.." 2>/dev/null && pwd)
else
  root=$here
fi
if [ -z "$root" ] || [ ! -d "$root" ]; then
  echo "❓ 폴더를 찾을 수 없습니다: ${root:-$arg}"
  exit 0
fi

today=$(TZ=KST-9 date +%Y-%m-%d)
TAB=$(printf '\t')
rows=""
# DONE은 사용자가 /refactor:approve 마무리 로 확인했을 때만 "완료"로 본다(상태 명령·안전장치와 같은 기준)
lroot=${REFACTOR_ROOT:-}
[ -z "$lroot" ] && case "${BASH_SOURCE[0]}" in */*) lroot="${BASH_SOURCE[0]%/*}/.." ;; esac
have_lib=0
if [ -n "$lroot" ] && [ -f "$lroot/scripts/refactor-lib.sh" ]; then eval "$(tr -d '\r' < "$lroot/scripts/refactor-lib.sh")"; have_lib=1; fi

for st in "$root"/docs/refactor/STATE.md "$root"/*/docs/refactor/STATE.md "$root"/*/*/docs/refactor/STATE.md; do
  [ -f "$st" ] || continue
  pdir=${st%/docs/refactor/STATE.md}
  if [ "$pdir" = "$root" ]; then name="(기준 폴더)"; else name=${pdir#"$root"/}; fi
  allow=0; allow_steps=""
  for f in "$pdir"/docs/refactor/.allow-*; do
    [ -e "$f" ] || continue
    # 기준선 허용 파일에 단계 ID 가 적혀 있으면(0.3.2) 그 단계를 실행하는 동안만(0.3.3 — STATE.md current_step) 열린다(끝나면 저절로 닫힘) —
    # ⚠허용파일 대신 따로 표시. 빈(0바이트·공백만) 파일은 기준선 전부가 열려 저절로 안 닫힘(0.3.3)
    if [ "$have_lib" = 1 ] && [ "${f##*/}" = .allow-baseline-edit ]; then
      a=$(rl_allow_baseline "$pdir/docs/refactor"); a=${a%%$'\n'*}
      case "$a" in
        ALL) allow_steps="⚠허용파일 비어 있음(기준선 전부 열림·저절로 안 닫힘)"; continue ;;
        OPEN\ *) allow_steps="🔓단계 ${a#* } 실행 중 — 열림(끝나면 저절로 닫힘)"; continue ;;
        WAIT\ *) allow_steps="🔒허용파일 단계 ${a#* } 실행 중일 때만 열림(지금은 닫힘)"; continue ;;
        SHUT\ *) allow_steps="🔒허용파일 단계 ${a#* } 승인 대기·카드 바뀜(지금은 닫힘)"; continue ;;
        DONE\ *) allow_steps="✅허용파일 단계 모두 끝남(다음 입력 때 지워짐)"; continue ;;
        UNKNOWN\ *) allow_steps="⚠허용파일 단계 ${a#* } 계획서에 없음(오타?)"; continue ;;
      esac
    fi
    allow=1
  done
  doneok=0
  [ "$have_lib" = 1 ] && rl_done_confirmed "$pdir/docs/refactor" && doneok=1
  # 실행 대기(승인됨·미완료·번호 하나, 승인 기록이 봉인 그대로) / 승인 대기 단계가 있나 — 상태 명령과 같은 기준
  ready=0; pend=0
  if [ "$have_lib" = 1 ] && [ -f "$pdir/docs/refactor/REFACTOR_PLAN.md" ]; then
    intact=1; rl_log_intact "$pdir/docs/refactor" || { intact=0; pend=1; }
    while IFS="$RL_US" read -r kind_ n_ id t box done_ cnt k r h hv stt; do
      [ "$kind_" = CARD ] && [ "$box" != none ] && [ "$done_" != 1 ] || continue
      if [ "$stt" = approved ] && [ "${cnt:-1}" = 1 ] && [ "$intact" = 1 ]; then ready=1; else pend=1; fi
    done <<RECS
$(rl_cards "$pdir/docs/refactor/REFACTOR_PLAN.md" "$pdir/docs/refactor/APPROVALS.log")
RECS
  fi
  row=$(awk -v NAME="$name" -v TODAY="$today" -v ALLOW="$allow" -v STEPS="$allow_steps" -v DONEOK="$doneok" -v READY="$ready" -v PEND="$pend" '
    function dn(s,   t, y, m, d) { split(s, t, "-"); y = t[1] + 0; m = t[2] + 0; d = t[3] + 0; if (m <= 2) { y--; m += 12 }
      return 365 * y + int(y / 4) - int(y / 100) + int(y / 400) + int((153 * (m - 3) + 2) / 5) + d }
    function val(s) { sub(/^[^:]*:[ \t]*/, "", s); sub(/\r$/, "", s); gsub(/^"|"$/, "", s); gsub(/\|/, "/", s); return s }
    NR == 1 && /^---/ { fm = 1; next }
    fm && /^---/ { exit }
    fm { key = $0; sub(/:.*/, "", key); v[key] = val($0) }
    END {
      ph = v["phase"]; g = v["gate"]; red = v["red_open"] + 0
      days = (v["updated"] ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) ? dn(TODAY) - dn(substr(v["updated"], 1, 10)) : -1
      if (ph == "DONE" && DONEOK == 1) { rank = 4; st = "✅ 완료" }
      else if (ph == "DONE") { rank = 1; st = "🙋 마무리 확인 필요(/refactor:approve 마무리)" }
      else if (red > 0) { rank = 0; st = "🔴 급한 구멍" }
      else if (READY == 1) { rank = 2; st = "▶ 다음 단계 가능" }
      else if (PEND == 1 || g == "G1-baseline" || g == "G2-plan" || g == "ask-user" || g == "G3-step") { rank = 1; st = "🙋 사장님 차례" }
      else { rank = 3; st = "⏳ 진행 중" }
      flag = ""
      if (days > 14 && !(ph == "DONE" && DONEOK == 1)) flag = flag " ⏰" days "일 멈춤"
      if (ALLOW == 1) flag = flag " ⚠허용파일"
      if (STEPS != "") flag = flag " " STEPS
      plan = (v["steps_total"] + 0 > 0) ? (v["steps_done"] + 0) "/" (v["steps_approved"] + 0) "/" (v["steps_total"] + 0) : "-"
      when = (days < 0) ? "?" : (days == 0 ? "오늘" : days "일 전")
      printf "%d\t%d\t| %s | %s%s | %s | %s | %s | %s | %s | %s | %s |\n", rank, (days < 0 ? 0 : days), NAME, st, flag, (ph == "" ? "?" : ph), (g == "" ? "-" : g), red, plan, (v["readiness"] == "" ? "-" : v["readiness"]), v["next"], when
    }' "$st")
  [ -n "$row" ] && rows="$rows$row"$'\n'
done

echo "== 리팩토링 현황표 — 기준 폴더: $root ($today KST) =="
if [ -z "$rows" ]; then
  echo "(이 폴더 아래에서 docs/refactor/STATE.md를 찾지 못했습니다. 프로젝트들이 모여 있는 상위 폴더를 알려 주세요. 예: /refactor:board ~/projects)"
else
  echo "| 프로젝트 | 상태 | 단계 | 대기 | 🔴 | 계획(완료/승인/전체) | 준비도 | 다음 할 일 | 마지막 갱신 |"
  echo "|---|---|---|---|---|---|---|---|---|"
  printf '%s' "$rows" | sort -t "$TAB" -k1,1n -k2,2nr | cut -f3-
  echo
  echo "상태 뜻: 🔴 급한 구멍 있음 · 🙋 사장님 승인·답변 차례 · ▶ 승인된 다음 단계 실행 가능 · ⏳ 진행 중 · ✅ 완료 · ⏰ 14일 넘게 멈춤"
fi

idle=""
for d in "$root"/*/; do
  d=${d%/}
  [ -d "$d/.git" ] || continue
  [ -f "$d/docs/refactor/STATE.md" ] && continue
  idle="$idle ${d##*/}"
done
[ -n "$idle" ] && { echo; echo "아직 시작 안 한 프로젝트(git 폴더):$idle"; }
exit 0
