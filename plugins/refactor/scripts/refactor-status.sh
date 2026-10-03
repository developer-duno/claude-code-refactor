#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Vibe Refactor — 현황 보기 (/refactor:status 전용, 읽기만 한다)
#   $1 = 프로젝트 폴더
# 항상 exit 0 — 실패하면 스킬 전체가 멈추므로, 문제는 메시지로 알린다.
# ─────────────────────────────────────────────────────────────────────────────

LC_ALL=C
export LC_ALL

proj=${1:-$PWD}
proj=${proj//"\\"//}
proj=${proj%/}
dir="$proj/docs/refactor"
state="$dir/STATE.md"
plan="$dir/REFACTOR_PLAN.md"
base="$dir/BASELINE.md"
today=$(TZ=KST-9 date +%Y-%m-%d)

if [ ! -f "$state" ]; then
  echo "NO_STATE"
  echo "이 프로젝트($proj)는 아직 리팩토링을 시작하지 않았습니다. 시작하려면 /refactor:go"
  exit 0
fi

echo "== 진행 상황 요약칸 (docs/refactor/STATE.md) =="
awk 'NR == 1 && /^---/ { fm = 1; next } fm && /^---/ { exit } fm { sub(/\r$/, ""); print "  " $0 }' "$state"

upd=$(sed -n -E 's/^updated:[[:space:]]*"?([0-9]{4}-[0-9]{2}-[0-9]{2}).*/\1/p' "$state" | head -n 1)
if [ -n "$upd" ]; then
  days=$(awk -v a="$upd" -v b="$today" '
    function dn(s,   t, y, m, d) { split(s, t, "-"); y = t[1] + 0; m = t[2] + 0; d = t[3] + 0; if (m <= 2) { y--; m += 12 }
      return 365 * y + int(y / 4) - int(y / 100) + int(y / 400) + int((153 * (m - 3) + 2) / 5) + d }
    BEGIN { print dn(b) - dn(a) }')
  echo "  (마지막 갱신: ${days}일 전)"
fi

echo
echo "== 최근 단계 기록 (최대 5줄) =="
awk '
  /^##+[ \t]*단계 기록/ { t = 1; next }
  t && /^#/ { t = 0 }
  t && /^\|/ && !/^\|[ \t:-]*-/ && !/날짜/ { sub(/\r$/, ""); rows[++n] = $0 }
  END { s = (n > 5) ? n - 4 : 1; for (i = s; i <= n; i++) print "  " rows[i]; if (n == 0) print "  (기록 없음)" }' "$state"

echo
echo "== 대기 중인 결정·질문 =="
awk '
  /^##+[ \t]*대기 중인 결정/ { t = 1; next }
  t && /^#/ { t = 0 }
  t && NF { sub(/\r$/, ""); if (++c <= 10) print "  " $0 }
  END { if (!c) print "  (없음)" }' "$state"

root=${REFACTOR_ROOT:-}
[ -z "$root" ] && case "${BASH_SOURCE[0]}" in */*) root="${BASH_SOURCE[0]%/*}/.." ;; esac
lib="$root/scripts/refactor-lib.sh"
if [ -n "$root" ] && [ -f "$lib" ]; then
  eval "$(tr -d '\r' < "$lib")"
  US=$RL_US
  log="$dir/APPROVALS.log"
  intact=1
  if ! rl_log_intact "$dir"; then
    intact=0
    echo
    chg=$(rl_log_changes "$dir")
    if [ "$chg" = "NOSEAL" ]; then
      echo "⏸ 승인 기록에 봉인이 없습니다(이전 버전에서 시작한 프로젝트) — 확인 전까지 어떤 단계도 실행하지 않는다."
      echo "   👤 사람이: docs/refactor/APPROVALS.log 를 한 번 훑어보고 /refactor:approve 확인 (한 번만 하면 됨)"
    else
      echo "⛔ 승인 기록(APPROVALS.log)이 /refactor:approve 밖에서 바뀌었습니다 — 확인 전까지 어떤 단계도 실행하지 않는다. 봉인 뒤 달라진 줄:"
      printf '%s\n' "$chg"
      echo "   👤 사람이: 직접 한 승인이 아니면 그 줄을 지운 뒤 /refactor:approve 확인"
    fi
  fi
  ph_now=$(sed -n -E 's/^phase:[[:space:]]*"?([A-Za-z_]+).*/\1/p' "$state" | head -n 1)
  if [ "$ph_now" = "DONE" ]; then
    if rl_done_confirmed "$dir"; then echo; echo "== 마무리됨(DONE, 사용자 확인) — 안전장치는 꺼져 있음 =="
    else echo; echo "⚠️ STATE는 DONE이지만 사용자의 마무리 확인(/refactor:approve 마무리)이 없어 안전장치가 켜져 있습니다. 끝내려면 사용자가 /refactor:approve 마무리"; fi
  fi
  if [ -f "$base" ]; then
    echo
    rl_base_state "$base" "$log"
    case "$RL_STATE" in
      approved) echo "== 기준선 계획: 승인됨 (승인 기록과 계획 내용이 일치) ==" ;;
      changed) echo "== 기준선 계획: 승인 뒤 계획 내용이 바뀜 → 기준선 작성 안 함. 사용자가 확인 후 /refactor:approve baseline 으로 다시 승인 =="
               rl_base_text "$base" | rl_show_diff "$dir/approved/BASELINE.md" ;;
      multi) echo "== 기준선 계획: '기준선 계획 승인:' 줄이 여러 개 — 승인할 수 없음(/refactor:go 로 한 줄만 남기게) ==" ;;
      held) echo "== 기준선 계획: 승인 취소됨 (/refactor:approve baseline 으로 다시 승인) ==" ;;
      nofield) echo "== 기준선 계획: 승인 줄 없음 (줄 맨 앞의 '기준선 계획 승인: [ ]' 필요) ==" ;;
      *) echo "== 기준선 계획: 승인 대기 (/refactor:approve baseline) =="
         [ "$RL_BOX" = "x" ] && echo "  ⚠️ BASELINE.md에 체크 표시는 있지만 승인 기록(APPROVALS.log)이 없습니다 — 승인으로 보지 않습니다." ;;
    esac
  fi
  if [ -f "$plan" ]; then
    echo
    echo "== 계획서 (docs/refactor/REFACTOR_PLAN.md) — 승인 근거: APPROVALS.log =="
    recs=$(rl_cards "$plan" "$log")
    n_total=0; n_ap=0; n_done=0; ready=""; changed=""; unlogged=""; pending=""; held=""; dups=""; nobox=""; fence_warn=""
    while IFS="$US" read -r kind_ n_ id t box done_ cnt k r h hv st; do
      case "$kind_" in
        WARN) [ "$n_" = "fence" ] && fence_warn=$id ;;
        CARD)
          line="     [$id] $t"
          if [ "${cnt:-1}" -gt 1 ]; then dups="$dups$line"$'\n'; continue; fi
          if [ "$box" = "none" ]; then nobox="$nobox$line"$'\n'; continue; fi
          n_total=$((n_total + 1))
          [ "$st" = "approved" ] && n_ap=$((n_ap + 1))
          if [ "$done_" = 1 ]; then n_done=$((n_done + 1)); continue; fi
          case "$st" in
            approved) if [ "$intact" = 1 ]; then ready="$ready$line"$'\n'; else sealed_off="${sealed_off:-}$line"$'\n'; fi ;;
            changed) changed="$changed$line"$'\n'; changed_ids="${changed_ids:-} $id" ;;
            held) held="$held$line"$'\n' ;;
            *) if [ "$box" = "x" ]; then unlogged="$unlogged$line"$'\n'; else pending="$pending$line"$'\n'; fi ;;
          esac ;;
      esac
    done <<RECS_END
$recs
RECS_END
    show_list() { # $1 제목 $2 목록(최대 8줄)
      [ -z "$2" ] && return 0
      local c
      echo "  $1"
      printf '%s' "$2" | head -n 8
      c=$(printf '%s' "$2" | grep -c .)
      [ "$c" -gt 8 ] && echo "     … 외 $((c - 8))개"
      return 0
    }
    echo "  전체 ${n_total}단계 · 승인 ${n_ap} · 완료 ${n_done}"
    show_list "▶ 실행 대기(승인됨 — 이 목록만 실행한다):" "$ready"
    show_list "⛔ 승인 기록 확인 전이라 실행하지 않음(승인 기록이 봉인과 다름):" "${sealed_off:-}"
    show_list "🔁 승인 뒤 카드 내용이 바뀜 — 실행하지 않음. 아래 바뀐 줄을 확인한 뒤 /refactor:approve <ID>로 다시 승인:" "$changed"
    shown=0
    for cid in ${changed_ids:-}; do
      shown=$((shown + 1)); [ "$shown" -gt 3 ] && break
      echo "     [$cid] 바뀐 줄:"
      rl_card_text "$plan" "$cid" | rl_show_diff "$dir/approved/$cid.md"
    done
    show_list "⚠️ 체크 표시만 있고 승인 기록이 없음 — 실행하지 않음(계획서를 손으로 고친 것일 수 있음. 실행하려면 /refactor:approve <ID>):" "$unlogged"
    show_list "⏸ 승인 대기:" "$pending"
    show_list "⏹ 보류(승인 취소됨):" "$held"
    show_list "⚠️ 같은 번호의 단계가 여러 개 — 실행하지 않음(계획서 번호를 고쳐야 함):" "$dups"
    show_list "❓ 승인 줄이 없는 단계 — 실행하지 않음(계획서 형식 확인):" "$nobox"
    [ -n "$fence_warn" ] && echo "  ⚠️ 닫히지 않은 코드 블록이 ${fence_warn}개 있어 무시했습니다 — 계획서 형식을 확인하세요."
  fi
else
  echo
  echo "⚠️ 승인 도구 파일(refactor-lib.sh)을 찾지 못해 승인 현황을 계산하지 못했습니다. 플러그인을 다시 설치하세요. (이 상태에서는 어떤 단계도 실행하지 않는다)"
fi

allow=""; allow_msg=""
for f in "$dir"/.allow-*; do
  [ -e "$f" ] || continue
  # 기준선 허용 파일에 단계 ID 가 적혀 있으면(0.3.2) 그 단계를 실행하는 동안만(0.3.3 — STATE.md current_step) 열리고 끝나면 저절로 닫힌다 —
  # 상태별로 알린다. 빈(0바이트·공백만) 파일은 기준선 전부가 열려 저절로 안 닫히므로 따로 경고(0.3.3)
  if [ "${f##*/}" = .allow-baseline-edit ] && command -v rl_allow_baseline >/dev/null 2>&1; then
    a=$(rl_allow_baseline "$dir"); a=${a%%$'\n'*}
    case "$a" in
      ALL) allow_msg="⚠️ 빈 기준선 허용 파일 — 기준선 전부가 열려 있고 저절로 닫히지 않습니다. 단계 목록으로 바꾸기: /refactor:approve 허용 <ID> · 닫기: /refactor:approve 허용 닫기"; continue ;;
      OPEN\ *) allow_msg="🔓 기준선 허용 파일(.allow-baseline-edit): 단계 ${a#* } 실행 중 — 열림(끝나면 저절로 닫힘)."; continue ;;
      WAIT\ *) allow_msg="🔒 기준선 허용: 단계 ${a#* } — 그 단계를 실행하는 동안만 열림(지금은 닫힘)."; continue ;;
      SHUT\ *) allow_msg="🔒 허용 파일의 단계 ${a#* } 가 승인 대기·카드 바뀜 — 지금은 닫힘."; continue ;;
      DONE\ *) allow_msg="✅ 허용 파일의 단계가 모두 끝남 — 다음 입력 때 지워짐."; continue ;;
      UNKNOWN\ *) allow_msg="⚠️ 허용 파일의 단계 ${a#* } 가 계획서에 없음(오타?) — 고치거나 지우세요(터미널에서 rm \"$f\")."; continue ;;
    esac
  fi
  allow="$allow ${f##*/}"
done
if [ -n "$allow_msg" ]; then
  echo
  echo "$allow_msg"
fi
if [ -n "$allow" ]; then
  echo
  echo "⚠️ 허용 파일이 남아 있음:$allow — 해당 작업이 끝나고 커밋했으면 지우세요(터미널에서 rm \"$dir/<파일>\" — CLI 라면 입력창에 ! rm \"…\" 도 됨)."
fi

if [ -f "$dir/APPROVALS.log" ]; then
  echo
  echo "== 최근 승인 기록 (APPROVALS.log) =="
  tail -n 3 "$dir/APPROVALS.log" | sed 's/^/  /'
fi

if command -v git >/dev/null 2>&1 && git -C "$proj" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  br=$(git -C "$proj" rev-parse --abbrev-ref HEAD 2>/dev/null)
  dirty=$(git -C "$proj" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  echo
  echo "== git == 브랜치: ${br:-?} · 커밋 안 된 변경: ${dirty}개"
fi
exit 0
