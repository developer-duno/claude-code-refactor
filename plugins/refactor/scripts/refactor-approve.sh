#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Vibe Refactor — 승인 스크립트 (/refactor:approve 전용)
#
# 사용자가 입력창에 /refactor:approve 를 치면 입력 훅(turn.sh)이 --from-hook 을 붙여 실행한다 — 승인은 여기서만 처리된다.
# 스킬의 ! 명령(훅보다 먼저 돈다)도 이 스크립트를 부르지만 --from-hook 이 없으므로 아무것도 바꾸지 않고 현황만 보여 준다.
# Claude가 직접 부르는 것은 안전장치 훅이 막는다. 사용자가 입력한 인자는 표준입력으로 받는다(셸 주입 방지).
#   $1 = 프로젝트 폴더, $2 = --from-hook (입력 훅이 부를 때만)
#   표준입력 = 인자 (예: "P0-1 P1-2" / "P1" / "baseline" / "보류 P1-2" / "확인" / "마무리" / 비움=현황)
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
eval "$(tr -d '\r' < "$lib")"
US=$RL_US
now=$(rl_now)

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
mode="approve"; want_base=0; ids=""; phases=""; bad=""; pos=0; conflict=""; special=""
for tok in $raw; do
  up=$(printf '%s' "$tok" | tr -d ';.()[]' | tr '[:lower:]' '[:upper:]')
  [ -z "$up" ] && continue
  pos=$((pos + 1))
  case "$up" in
    BASELINE|기준선|기준선계획) want_base=1 ;;
    HOLD|보류|취소|CANCEL|UNDO)
      if [ "$pos" = 1 ]; then mode="hold"; else conflict="'$tok'은(는) 맨 앞에만 쓸 수 있습니다"; fi ;;
    APPROVE|승인)
      if [ "$pos" != 1 ]; then conflict="'$tok'은(는) 맨 앞에만 쓸 수 있습니다"; fi ;;
    확인|CONFIRM|SEAL) special=confirm ;;
    마무리|DONE|FINISH|끝|완료) special=done ;;
    ALL|전체|모두) bad="$bad $tok(전체 승인은 지원하지 않음 — P0·P1 같은 묶음이나 단계 번호로)" ;;
    *)
      if [[ $up =~ ^P[0-9]+-[0-9]+[A-Z]?$ ]]; then case " $ids " in *" $up "*) ;; *) ids="$ids $up" ;; esac
      elif [[ $up =~ ^P[0-9]+$ ]]; then phases="$phases $up"
      else bad="$bad $tok"
      fi ;;
  esac
done

say "== /refactor:approve 결과 ($now KST) =="
if [ -n "$conflict" ]; then
  say "❓ $conflict — 아무것도 바꾸지 않았습니다."
  say "   승인: /refactor:approve P1-1 P1-2    ·    승인 취소: /refactor:approve 보류 P1-2"
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
  rm -f "$tmp"
}

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
  if [ -n "$ids$phases$special" ] || [ "$want_base" = 1 ]; then say "   (그래서 이번 요청은 처리하지 않았습니다.)"; exit 0; fi
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
    awk -v U="$(rl_today)" '
      NR == 1 && $0 ~ /^---/ { fm = 1; print; next }
      fm && $0 ~ /^---/ { fm = 0; print; next }
      fm && $0 ~ /^phase:/ { print "phase: DONE"; next }
      fm && $0 ~ /^gate:/ { print "gate: none"; next }
      fm && $0 ~ /^next:/ { print "next: \"한두 달 뒤 /refactor:go 다시 CHECKUP\""; next }
      fm && $0 ~ /^updated:/ { print "updated: " U; next }
      { print }' "$state" > "$tmp" && [ -s "$tmp" ] && mv "$tmp" "$state"
    rm -f "$tmp"
  fi
  say "✅ 리팩토링을 마무리했습니다(DONE). 이제 리팩토링 중에만 켜지는 안전장치(push·배포 차단, 기준선 보호, 안전 실행기 강제 등)가 꺼집니다."
  say "   비밀값·되돌릴 수 없는 명령 보호는 계속 켜져 있습니다. 다시 점검하려면 한두 달 뒤 /refactor:go 다시 CHECKUP"
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
          set_state_front -v N="/refactor:go 로 기준선 작성" -v U="$(rl_today)"
        fi
      else
        if [ "$ph" != "BASELINE_PLAN" ] && [ "$RL_STATE" = "approved" ]; then
          say "ℹ️ 기준선 작성이 이미 시작돼(현재 단계: ${ph:-알 수 없음}) 기준선 승인은 취소하지 않았습니다."
        elif [ "$RL_STATE" = "approved" ] || [ "$RL_STATE" = "changed" ]; then
          printf '%s KST | 보류 | BASELINE | %s | 사용자가 /refactor:approve 로 실행\n' "$now" "$RL_HASH" >> "$log"
          rl_log_seal "$dir"
          rl_rewrite_base "$base" o
          say "⏸ 기준선 계획 승인을 취소했습니다."
          set_state_front -v N="기준선 계획 확인 후 /refactor:approve baseline" -v U="$(rl_today)"
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
    recs=$(rl_cards "$plan" "$log")
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

    acted=""; lines=""
    for id in $targets; do
      rec=$(printf '%s\n' "$recs" | awk -F "$US" -v ID="$id" '$1 == "CARD" && $3 == ID && !f { print; f = 1 }')
      if [ -z "$rec" ]; then say "❓ 계획서에 없는 단계 번호: $id"; continue; fi
      IFS="$US" read -r kind_ n_ id_ t box done_ cnt k r h hv st <<EOF
$rec
EOF
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
      if [ "$mode" = "approve" ] && mkdir -p "$dir/approved"; then
        for id in $acted; do rl_card_text "$plan" "$id" > "$dir/approved/$id.md"; done
      fi
      if [ "$mode" = "approve" ]; then rl_rewrite_plan "$plan" x "$acted"; else rl_rewrite_plan "$plan" o "$acted"; fi
    fi

    # 현황(기록 기준으로 다시 읽음)
    recs=$(rl_cards "$plan" "$log")
    n_total=0; n_ap=0; n_done=0; ready=""; pending=""; changed=""; unlogged=""; dups=""; fence_warn=""
    while IFS="$US" read -r kind_ n_ id t box done_ cnt k r h hv st; do
      case "$kind_" in
        WARN) [ "$n_" = "fence" ] && fence_warn=$id ;;
        CARD)
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
    fi
    if [ -n "$acted" ] || [ "$n_total" != 0 ]; then
      first_ready=${ready# }; first_ready=${first_ready%% *}
      if [ -n "$acted" ]; then
        if [ -n "$first_ready" ]; then nxt="/refactor:go 로 승인된 단계 실행 (다음: $first_ready)"; else nxt="계획서 확인 후 /refactor:approve <단계ID>"; fi
        set_state_front -v A="$n_ap" -v D="$n_done" -v T="$n_total" -v N="$nxt" -v U="$(rl_today)"
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
