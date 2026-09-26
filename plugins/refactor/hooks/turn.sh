#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Vibe Refactor — 입력 기록 (UserPromptSubmit 훅)
#
# 표시 파일은 세션마다 따로 둔다: docs/refactor/.turn.<세션ID>, docs/refactor/.turn-dirty.<세션ID>
# (같은 프로젝트를 두 대화에서 열어도 서로의 표시를 덮어쓰지 않게). 하루 지난 표시 파일은 지운다.
#
# 1) 사용자가 /refactor:go 를 입력한 턴이면 .turn.<세션ID> 에 "go <세션ID>"를 적는다.
#    안전장치(guard.sh)는 이 표시가 있을 때만 "읽기 전용 단계에서는 docs/refactor 밖 수정 금지"와
#    "테스트·빌드는 안전 실행기로만" 규칙을 켠다 — 평소 개발 대화는 막지 않기 위해서다.
#    - 같은 세션에서 다른 슬래시 명령을 입력하면 표시를 지운다.
#    - 같은 세션에서 일반 문장을 입력하면: 리팩토링이 질문에 대한 답을 기다리던 중(gate: ask-user
#      또는 SETUP 단계)이면 표시를 유지하고(답을 받아 이어서 진행하므로), 아니면 지운다.
#    - 백그라운드 작업 완료 알림(<task-notification> 등, 사람이 친 것이 아닌 입력)은 무시한다.
#    - 단계 실행 뒤 보고를 기다리는 중(gate: G3-step)에도 같은 세션의 일반 문장이면 표시를 유지한다
#      (보고를 보고 "화면 확인하게 서버 켜 줘" 같은 후속 요청도 안전 실행기 규칙 안에서 하도록).
#    - 2줄에 "ready <이번에 실행해도 되는 단계들>"을 적는다(안전장치가 단계 실행 중 코드 수정을 허락할지 판단).
#    - "/refactor:go 다시 <단계>" 이면 승인 기록에 재설정 줄을 남긴다 → 그 앞의 승인은 모두 무효(다시 승인해야 실행).
# 2) 사용자가 /refactor:approve <인자> 를 입력한 턴이면 .turn.<세션ID> 에 "approve <세션ID> <epoch초>"를 적는다.
#    승인 스크립트는 이 표가 있고(같은 세션·10분 안) 사람이 입력한 턴일 때만 승인·취소·마무리·확인을 처리하고 표를 지운다(1회용).
# 3) 리팩토링 진행 중이면(또는 /refactor:go 턴이면) 턴이 시작될 때 "보호된 파일 중 이미 바뀌어 있던 것"과
#    승인 기록(APPROVALS.log)의 지문을 .turn-dirty.<세션ID> 에 적어 둔다. 셸 명령 뒤 점검(post-check.sh)은
#    이 목록에 없던 변경·이 목록에서 사라진 변경만 알리고, 턴 중에 승인 기록이 바뀌면 알린다.
# 4) docs/refactor/.gitignore 가 없으면 만들어 허용 파일(.allow-*)·.turn* 이 git에 올라가지 않게 한다.
# ─────────────────────────────────────────────────────────────────────────────

LC_ALL=C
export LC_ALL

proj=${CLAUDE_PROJECT_DIR:-$PWD}
proj=${proj//"\\"//}
proj=${proj%/}
rdir="$proj/docs/refactor"

# 입력은 앞 4KB 만 읽는다(세션 ID·입력 첫머리만 필요). 리팩토링 폴더가 없고 /refactor:go 도 아니면 바로 끝낸다
input=$(head -c 4096)
if [ ! -d "$rdir" ]; then
  case "$input" in *'/refactor:go'*) ;; *) exit 0 ;; esac
fi
re_s='"session_id"[[:space:]]*:[[:space:]]*"([^"]*)"'
if ! [[ $input =~ $re_s ]]; then input="$input$(cat)"; fi

prompt=""; sid=""
re_p='"prompt"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)'   # 닫는 따옴표는 없어도 된다(앞 4KB 에서 잘렸을 때)
[[ $input =~ $re_p ]] && prompt=${BASH_REMATCH[1]}
[[ $input =~ $re_s ]] && sid=${BASH_REMATCH[1]}
# 세션 ID 는 파일 이름에 쓰므로 모양을 확인한다. 이상하면 표시를 남기지 않는다
[[ $sid =~ ^[A-Za-z0-9_-]{1,128}$ ]] || exit 0

# 슬래시 명령이 <command-name>/refactor:go</command-name><command-args>…</command-args> 모양으로 들어와도 알아본다
re_cmdname='<command-name>(/[^<]*)</command-name>'
re_cmdargs='<command-args>([^<]*)</command-args>'
if [[ $prompt =~ $re_cmdname ]]; then
  cname=${BASH_REMATCH[1]}; cargs=""
  [[ $prompt =~ $re_cmdargs ]] && cargs=${BASH_REMATCH[1]}
  prompt="$cname $cargs"
fi
# 사람이 친 입력이 아닌 것(<task-notification> 같은 알림)은 무시. 붙여 넣은 글(<pasted_content …>)은 사람 입력이다
re_sys='^([[:space:]]|\\[nrt])*<(task-notification|system-reminder|agent-message|cross-session-message|local-command-stdout)[[:space:]>]'
[[ $prompt =~ $re_sys ]] && exit 0

T="$rdir/.turn.$sid"
[ -d "$rdir" ] && {
  find "$rdir" -maxdepth 1 -name '.turn*' -mmin +1440 -delete 2>/dev/null
  # 0.2.0 이 남긴 세션 공용 .turn 이 이 세션 것이면 지운다(이제 .turn.<세션ID> 를 쓴다)
  if [ -f "$rdir/.turn" ]; then o_kind=""; o_sid=""; read -r o_kind o_sid < "$rdir/.turn"; [ "$o_sid" = "$sid" ] && rm -f "$rdir/.turn"; fi
}

phase=""
if [ -f "$rdir/STATE.md" ]; then
  re_phase='^phase:[[:space:]]*"?([A-Za-z_]+)'
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ $line =~ $re_phase ]]; then phase=${BASH_REMATCH[1]}; break; fi
  done < "$rdir/STATE.md"
fi

LIB_OK=0
load_lib() {
  local root=${REFACTOR_ROOT:-} lib
  [ "$LIB_OK" = 1 ] && return 0
  lib="$root/scripts/refactor-lib.sh"
  [ -n "$root" ] && [ -f "$lib" ] || return 1
  eval "$(tr -d '\r' < "$lib")"
  LIB_OK=1
}
snapshot() { # 보호된 파일의 지금 변경 목록 + 승인 기록 지문을 .turn-dirty.<세션ID> 에 적는다
  local D="$rdir/.turn-dirty.$sid"
  load_lib || return 0
  { rl_protected_dirty "$proj" "$rdir"; printf 'APPROVALS\t%s\n' "$(rl_log_sum "$rdir/APPROVALS.log")"; } > "$D.tmp.$$" 2>/dev/null \
    && mv "$D.tmp.$$" "$D"
  rm -f "$D.tmp.$$"
}
ready_ids() { # 지금 실행해도 되는 단계(승인 기록·지문 일치·미완료·번호 하나, 승인 기록이 봉인 그대로) → READY
  READY=""
  [ -f "$rdir/REFACTOR_PLAN.md" ] && load_lib || return 0
  rl_log_intact "$rdir" || return 0
  local kind_ n_ id t box done_ cnt k r h hv st
  while IFS="$RL_US" read -r kind_ n_ id t box done_ cnt k r h hv st; do
    [ "$kind_" = CARD ] && [ "$st" = approved ] && [ "$done_" != 1 ] && [ "${cnt:-1}" = 1 ] && [ "$box" != none ] && READY="$READY $id"
  done <<RDY
$(rl_cards "$rdir/REFACTOR_PLAN.md" "$rdir/APPROVALS.log")
RDY
}
reset_approvals() { # $1 단계 — "/refactor:go 다시" : 승인 기록에 재설정 줄(그 앞의 승인은 무효)
  local log="$rdir/APPROVALS.log" intact=0
  [ -f "$log" ] && load_lib || return 0
  rl_log_intact "$rdir" && intact=1
  printf '%s KST | 재설정 | %s | 사용자가 /refactor:go 다시 로 입력\n' "$(rl_now)" "$1" >> "$log"
  # 기록이 봉인 그대로였을 때만 다시 봉인한다(밖에서 바뀐 기록을 이 줄로 덮어 인정하지 않게)
  [ "$intact" = 1 ] && rl_log_seal "$rdir"
  # 계획서의 승인 체크 표시도 비운다(완료 전 단계만) — 다시 승인할 때까지 "승인 대기"로 보이게
  [ -f "$rdir/REFACTOR_PLAN.md" ] || return 0
  local kind_ n_ id t box done_ cnt k r h hv st ids=""
  while IFS="$RL_US" read -r kind_ n_ id t box done_ cnt k r h hv st; do
    [ "$kind_" = CARD ] && [ "$box" = x ] && [ "$done_" != 1 ] && ids="$ids $id"
  done <<RST
$(rl_cards "$rdir/REFACTOR_PLAN.md" "$log")
RST
  [ -n "$ids" ] && rl_rewrite_plan "$rdir/REFACTOR_PLAN.md" o "$ids"
  return 0
}

re_go='^[[:space:]]*/refactor:go([[:space:]]|\\[nrt]|$)'
re_again='^[[:space:]]*/refactor:go([[:space:]]|\\[nrt])+다시(([[:space:]]|\\[nrt])+([A-Za-z_]+))?'
re_approve='^[[:space:]]*/refactor:approve([[:space:]]|\\[nrt])+([^[:space:]\\]|\\[^nrt])'
re_slash='^[[:space:]]*/'
if [[ $prompt =~ $re_go ]]; then
  mkdir -p "$rdir" 2>/dev/null || exit 0
  if [ -f "$rdir/.gitignore" ]; then
    has_turn=0
    while IFS= read -r line || [ -n "$line" ]; do [ "${line%$'\r'}" = ".turn*" ] && has_turn=1; done < "$rdir/.gitignore"
    [ "$has_turn" = 1 ] || printf '.turn*\n' >> "$rdir/.gitignore"
  else
    printf '.allow-*\n.turn*\n*.tmp.*\n' > "$rdir/.gitignore"
  fi
  if [[ $prompt =~ $re_again ]]; then
    step=${BASH_REMATCH[4]}
    step=$(printf '%s' "${step:--}" | tr '[:lower:]' '[:upper:]')
    reset_approvals "$step"
  fi
  ready_ids
  printf 'go %s\nready%s\n' "$sid" "$READY" > "$T"
  snapshot
  exit 0
fi

if [ -d "$rdir" ] && [[ $prompt =~ $re_approve ]]; then
  printf 'approve %s %s\n' "$sid" "$(date +%s)" > "$T"
  case "$phase" in "") ;; *) snapshot ;; esac
  exit 0
fi

case "$phase" in
  "") ;;
  DONE) load_lib && ! rl_done_confirmed "$rdir" && snapshot ;;   # 사람이 마무리를 확인하기 전의 DONE은 아직 진행 중
  *) snapshot ;;
esac

[ -f "$T" ] || exit 0
t_kind=""; t_sid=""
read -r t_kind t_sid < "$T"
[ "$t_sid" = "$sid" ] || exit 0          # 다른 세션의 표시는 그대로 둔다

# 다른 슬래시 명령, 또는 쓰이지 않고 남은 승인 표는 지운다
if [[ $prompt =~ $re_slash ]] || [ "$t_kind" != go ]; then
  rm -f "$T"
  exit 0
fi

# 일반 문장: 질문에 답하는 중이면 유지
waiting=0
if [ -f "$rdir/STATE.md" ]; then
  re_gate='^gate:[[:space:]]*"?(ask-user|G3-step)'
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ $line =~ $re_gate ]]; then waiting=1; break; fi
  done < "$rdir/STATE.md"
fi
[ "$phase" = "SETUP" ] && waiting=1
if [ "$waiting" = 1 ]; then
  # 표시는 유지하되, 실행해도 되는 단계 목록은 지금 기준으로 다시 적는다(그사이 완료된 단계로 코드를 계속 고치지 않게)
  ready_ids
  printf 'go %s\nready%s\n' "$sid" "$READY" > "$T"
else
  rm -f "$T"
fi
exit 0
