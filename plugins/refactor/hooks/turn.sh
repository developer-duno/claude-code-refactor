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
# 2) 사용자가 /refactor:approve [인자] 를 입력한 턴이면 이 훅이 승인 스크립트(refactor-approve.sh --from-hook)를 실행하고
#    그 결과를 "[Vibe Refactor 승인 처리 결과 — 입력 훅]" 블록으로 이번 턴의 컨텍스트(stdout)에 넣는다.
#    스킬의 ! 명령은 이 훅보다 먼저 돌기 때문에 승인·취소·마무리·확인·baseline 은 스킬이 아니라 여기서 처리한다
#    (스킬 쪽 실행은 --from-hook 이 없어 현황만 보여 준다). 인자가 없으면 현황만(바꾸는 것 없음). 이 훅은 프롬프트를 막지 않는다(exit 0).
# 3) 리팩토링 진행 중이면(또는 /refactor:go 턴이면) 턴이 시작될 때 "보호된 파일 중 이미 바뀌어 있던 것"과
#    승인 기록(APPROVALS.log)의 지문을 .turn-dirty.<세션ID> 에 적어 둔다. 셸 명령 뒤 점검(post-check.sh)은
#    이 목록에 없던 변경·이 목록에서 사라진 변경만 알리고, 턴 중에 승인 기록이 바뀌면 알린다.
# 4) docs/refactor/.gitignore 가 없으면 만들어 허용 파일(.allow-*)·.turn* 이 git에 올라가지 않게 한다.
# ─────────────────────────────────────────────────────────────────────────────

LC_ALL=C
export LC_ALL
# 이 훅이 10초 넘게 걸려 끝났으면 문제 기록(problems.log)에 "turn | 느림 N초" 한 줄만 남긴다(명령·경로·입력 글 없이).
# 10초 안이면 아무 프로그램도 띄우지 않는다. if 로 감싸 종료 코드를 바꾸지 않는다
trap 'if [ "$SECONDS" -gt 10 ] && [ -n "${REFACTOR_ROOT:-}" ]; then bash "$REFACTOR_ROOT/hooks/run.sh" refactor-report --log turn "느림 ${SECONDS}초" </dev/null >/dev/null 2>&1; fi' EXIT

proj=${CLAUDE_PROJECT_DIR:-$PWD}
proj=${proj//"\\"//}
proj=${proj%/}
rdir="$proj/docs/refactor"

# 입력은 앞 4KB 만 읽는다(세션 ID·입력 첫머리만 필요). 리팩토링 폴더가 없고 /refactor:go·/refactor:approve 도 아니면 바로 끝낸다
# (외부 명령 대신 bash 내장 read 로 — 이 훅은 매 입력마다 돌고, 바쁜 PC 에서는 외부 명령 한 번이 0.3초 넘게 걸린다)
input=""
IFS= read -r -d '' -n 4096 input || :   # -N(bash 4.1+) 대신 -d '' -n: NUL 이 없는 JSON 이면 같게 앞 4KB 를 읽는다(bash 3.2 호환)
if [ ! -d "$rdir" ]; then
  case "$input" in *'/refactor:go'*|*'/refactor:approve'*) ;; *) exit 0 ;; esac
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
# 정리(하루 지난 표시 파일·0.2.0 의 세션 공용 .turn)는 외부 프로그램(find·date·rm)을 띄우므로 표시 처리(go 턴의 닫힌 표시 쓰기,
# 그 밖 입력의 지움·유지·ready ?)를 끝낸 뒤에 한 번만 한다 — 정리 도중 끊겨도 표시는 이미 이번 입력에 맞다.
# 대상 폴더는 이 입력이 들어온 때 이미 있던 기록 폴더만(지금과 같음)
had_rdir=0; [ -d "$rdir" ] && had_rdir=1
swept_once=0
sweep() {
  [ "$swept_once" = 0 ] && [ "$had_rdir" = 1 ] || return 0
  swept_once=1
  # 하루 지난 표시 파일 정리는 하루에 한 번만(오늘 날짜를 .turn-sweep 에 적어 두고 날짜가 바뀌었을 때만 find)
  today=""; (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] >= 402 )) && printf -v today '%(%Y%m%d)T' -1   # %(…)T 는 bash 4.2+ 에서만
  [ -n "$today" ] || today=$(date +%Y%m%d)
  swept=""
  [ -f "$rdir/.turn-sweep" ] && read -r swept < "$rdir/.turn-sweep"
  if [ "$swept" != "$today" ]; then
    find "$rdir" -maxdepth 1 -name '.turn*' -mmin +1440 -delete 2>/dev/null
    printf '%s\n' "$today" > "$rdir/.turn-sweep" 2>/dev/null
  fi
  # 0.2.0 이 남긴 세션 공용 .turn 이 이 세션 것이면 지운다(이제 .turn.<세션ID> 를 쓴다)
  if [ -f "$rdir/.turn" ]; then o_kind=""; o_sid=""; read -r o_kind o_sid < "$rdir/.turn"; [ "$o_sid" = "$sid" ] && rm -f "$rdir/.turn"; fi
  allow_done
  return 0
}
# 0.3.2 #10: 기준선 허용 파일에 적힌 단계가 모두 끝났으면(또는 계획서에 없으면) 지우고, .turn-allowgone.<세션ID> 에 그 단계들을 적어
# 이번 턴의 셸 명령 뒤 점검(post-check.sh)이 한 번 알리게 한다. 빈 파일(예전처럼 전부 허용)은 지우지 않는다(사람이 지운다).
# 지난 입력의 알림 표시가 남아 있으면(셸 명령 없이 끝난 턴) 먼저 지운다 — 늦게 알리지 않게
allow_done() {
  local a
  [ -f "$rdir/.turn-allowgone.$sid" ] && rm -f "$rdir/.turn-allowgone.$sid"
  [ -s "$rdir/.allow-baseline-edit" ] && load_lib || return 0
  a=$(rl_allow_baseline "$rdir")
  case "$a" in
    "DONE "*) rm -f "$rdir/.allow-baseline-edit" && printf '%s\n' "${a#DONE }" > "$rdir/.turn-allowgone.$sid" 2>/dev/null ;;
  esac
  return 0
}

# /refactor:approve [인자] — 승인 처리는 이 훅이 한다(스킬의 ! 명령이 훅보다 먼저 돌기 때문). 결과는 stdout(이번 턴 컨텍스트)으로.
# 처리 뒤에는 아래로 이어져 .turn-dirty 스냅숏(처리 뒤 승인 기록 지문)과 go 표시 지우기(다른 슬래시 명령)를 그대로 한다.
re_approve='^[[:space:]]*/refactor:approve(([[:space:]]|\\[nrt])+(.*))?$'
if [[ $prompt =~ $re_approve ]]; then
  a_args=${BASH_REMATCH[3]}
  # JSON 문자열 속 이스케이프를 되돌린다(\n·\r·\t 는 칸 나눔, \" → ", \\ → \)
  a_args=${a_args//\\n/ }; a_args=${a_args//\\r/ }; a_args=${a_args//\\t/ }
  a_args=${a_args//\\\"/\"}; a_args=${a_args//\\\\/\\}
  if [ -n "${REFACTOR_ROOT:-}" ] && [ -f "$REFACTOR_ROOT/hooks/run.sh" ]; then
    a_out=$(printf '%s' "$a_args" | bash "$REFACTOR_ROOT/hooks/run.sh" refactor-approve "$proj" --from-hook 2>&1)
  else
    a_out="⚠️ 승인 스크립트를 찾지 못해 아무것도 바꾸지 않았습니다(REFACTOR_ROOT 없음). 플러그인을 다시 설치해 주세요."
  fi
  printf '%s\n%s\n%s\n' "[Vibe Refactor 승인 처리 결과 — 입력 훅]" "$a_out" \
    "(이 블록이 승인의 실제 결과입니다. 스킬이 먼저 보여 준 현황은 처리 전 상태일 수 있습니다.)"
  [ -d "$rdir" ] || exit 0
fi

phase=""
if [ -f "$rdir/STATE.md" ]; then
  re_phase='^phase:[[:space:]]*"?([A-Za-z_]+)'
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ $line =~ $re_phase ]]; then phase=${BASH_REMATCH[1]}; break; fi
  done < "$rdir/STATE.md"
fi

LIB_OK=0
load_lib() {
  local root=${REFACTOR_ROOT:-} lib src=""
  [ "$LIB_OK" = 1 ] && return 0
  lib="$root/scripts/refactor-lib.sh"
  [ -n "$root" ] && [ -f "$lib" ] || return 1
  IFS= read -r -d '' src < "$lib"   # 파일 끝에서 1 을 돌려주는 것이 정상(외부 명령 없이 읽는다)
  eval "${src//$'\r'/}"
  # 아래 둘은 라이브러리의 rl_log_sum·rl_log_intact 와 같은 값을 내되, 한 턴에 한 번만 재고 외부 명령을 줄인 판이다
  # (post-check.sh 는 라이브러리의 rl_log_sum 으로 다시 재어 이 값과 비교하므로 결과가 한 글자도 달라서는 안 된다)
  rl_log_sum() { log_sum "$1"; printf '%s\n' "$SUMV"; }
  rl_log_intact() {
    local want="" raw
    [ -f "$1/APPROVALS.log" ] || return 0
    [ -f "$1/approved/.log-sum" ] || return 1
    IFS= read -r -d '' want < "$1/approved/.log-sum"
    want=${want//[$'\r\n']/}
    log_sum "$1/APPROVALS.log"; [ "$SUMV" = "$want" ] && return 0
    raw=$(cksum < "$1/APPROVALS.log"); [ "${raw%% *}.${raw#* }" = "$want" ]   # 0.2.0 방식(원본 바이트) 봉인값
  }
  LIB_OK=1
}
SUMF=""; SUMV=""
log_sum() { # $1 파일 → SUMV = 줄 끝 \r 을 뺀 내용의 "CRC.길이"(없으면 none). 같은 파일은 한 번만 잰다(기록을 쓰면 SUMF 를 비운다)
  local c="" s
  [ "$1" = "$SUMF" ] && return 0
  SUMF=$1
  if [ ! -f "$1" ]; then SUMV=none; return 0; fi
  # \r 이 없으면 cksum 한 번. \r 이 있거나 NUL 이 섞여 끝까지 못 읽었으면(read 가 0) 라이브러리처럼 tr 을 거친다
  if IFS= read -r -d '' c < "$1" || [[ $c == *$'\r'* ]]; then s=$(tr -d '\r' < "$1" | cksum); else s=$(cksum < "$1"); fi
  SUMV="${s%% *}.${s#* }"
}
snapshot() { # 보호된 파일의 지금 변경 목록 + 승인 기록 지문을 .turn-dirty.<세션ID> 에 적는다
  local D="$rdir/.turn-dirty.$sid"
  load_lib || return 0
  log_sum "$rdir/APPROVALS.log"
  { rl_protected_dirty "$proj" "$rdir"; printf 'APPROVALS\t%s\n' "$SUMV"; } > "$D.tmp.$$" 2>/dev/null \
    && mv "$D.tmp.$$" "$D" || rm -f "$D.tmp.$$"
}
ready_ids() { # 지금 실행해도 되는 단계(승인 기록·지문 일치·미완료·번호 하나, 승인 기록이 봉인 그대로) → READY
  READY=""
  # 승인 기록이 없으면 승인된 단계도 없다(계획서를 읽지 않고 끝)
  [ -f "$rdir/REFACTOR_PLAN.md" ] && [ -f "$rdir/APPROVALS.log" ] && load_lib || return 0
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
  SUMF=""   # 기록이 바뀌었으니 지문을 다시 잰다
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
mark() { # go 표시(1줄 "go <세션ID>", 2줄 "ready$1")를 임시 파일 "$T.<번호>"(.turn* — 무시·하루 청소 대상)에 쓰고 mv 로 바꿔 넣는다
  # (> 로 바로 쓰면 잘라 놓은 빈 파일을 guard 가 읽어 표시가 없는 것처럼 볼 수 있다). $1 = " <단계들>" 또는 " ?"(아직 모름)
  printf 'go %s\nready%s\n' "$sid" "$1" > "$T.$$" 2>/dev/null && mv -f "$T.$$" "$T" 2>/dev/null || rm -f "$T.$$"
}

re_go='^[[:space:]]*/refactor:go([[:space:]]|\\[nrt]|$)'
re_again='^[[:space:]]*/refactor:go([[:space:]]|\\[nrt])+다시(([[:space:]]|\\[nrt])+([A-Za-z_]+))?'
re_slash='^[[:space:]]*/'
if [[ $prompt =~ $re_go ]]; then
  [ -d "$rdir" ] || mkdir -p "$rdir" 2>/dev/null || exit 0
  # 느린 계산(승인 재설정·실행 대기 계산·snapshot)과 정리 전에 닫힌 표시(ready ? = 실행 대기를 아직 모름)를 먼저 둔다 — 그 뒤
  # Claude Code 가 시간 초과로 이 훅을 끊어도 표시가 남아 읽기 전용 울타리·안전 실행기 규칙은 켜지고, 단계 실행(EXECUTE)의
  # 코드 수정은 막힌다(guard 가 "입력 처리가 늦어…"와 /refactor:go 재입력을 안내). 계산이 끝나면 진짜 목록으로 바꿔 쓴다
  mark " ?"
  if [ -f "$rdir/.gitignore" ]; then
    has_turn=0
    while IFS= read -r line || [ -n "$line" ]; do [ "${line%$'\r'}" = ".turn*" ] && has_turn=1; done < "$rdir/.gitignore"
    [ "$has_turn" = 1 ] || printf '.turn*\n' >> "$rdir/.gitignore"
  else
    printf '.allow-*\n.turn*\n*.tmp.*\n' > "$rdir/.gitignore"
  fi
  sweep
  if [[ $prompt =~ $re_again ]]; then
    step=${BASH_REMATCH[4]}
    step=$(printf '%s' "${step:--}" | tr '[:lower:]' '[:upper:]')
    reset_approvals "$step"
  fi
  ready_ids
  mark "$READY"
  snapshot
  exit 0
fi

# 표시 처리를 snapshot(git 을 부른다)보다 먼저 한다 — snapshot 이 느려 도중에 끊겨도 지울 표시는 이미 지워져 있고
# 낡은 실행 대기 목록이 남지 않는다. snapshot 은 지금처럼 표시와 상관없이 맨 끝에서 돈다
if [ -f "$T" ]; then
  t_kind=""; t_sid=""
  read -r t_kind t_sid < "$T"
  if [ "$t_sid" = "$sid" ]; then          # 다른 세션의 표시는 그대로 둔다
    # 다른 슬래시 명령(/refactor:approve 포함), 또는 go 가 아닌 옛 표시(이전 버전의 승인 표 등)는 지운다
    if [[ $prompt =~ $re_slash ]] || [ "$t_kind" != go ]; then
      rm -f "$T"
    else
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
        # 표시는 유지하되, 실행해도 되는 단계 목록은 지금 기준으로 다시 적는다(그사이 완료된 단계로 코드를 계속 고치지 않게).
        # 다시 계산하는 도중 끊기면 낡은 목록 대신 "아직 모름"이 남게 먼저 닫아 둔다
        mark " ?"
        sweep
        ready_ids
        mark "$READY"
      else
        rm -f "$T"
      fi
    fi
  fi
fi
sweep

case "$phase" in
  "") ;;
  DONE) load_lib && ! rl_done_confirmed "$rdir" && snapshot ;;   # 사람이 마무리를 확인하기 전의 DONE은 아직 진행 중
  *) snapshot ;;
esac
exit 0
