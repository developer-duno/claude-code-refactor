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
#    승인 스크립트에는 REFACTOR_TURN_SID=<세션ID> 를 넘긴다("푸시"·"합치기"가 그 세션의 허락 파일 .turn-push.<세션ID>·.turn-merge.<세션ID> 를 만든다).
#    push·합치기 허락은 그 차례에만: 사람 입력마다(알림 입력은 빼고) 승인 처리보다 먼저 그 세션의 .turn-push.<세션ID>·.turn-merge.<세션ID> 를 지운다.
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

# 0.3.3: push 허락(/refactor:approve 푸시 가 만든 .turn-push.<세션ID>)은 그 차례에만 — 사람 입력마다 먼저 지운다
# (위에서 알림 입력은 이미 걸렀으므로 지우지 않는다. 이번 입력이 /refactor:approve 푸시 면 아래 승인 처리가 새로 만든다)
[ -f "$rdir/.turn-push.$sid" ] && rm -f "$rdir/.turn-push.$sid"
# 0.3.5: 합치기 허락(/refactor:approve 합치기 가 만든 .turn-merge.<세션ID>)도 그 차례에만 — 같은 자리에서 지운다
[ -f "$rdir/.turn-merge.$sid" ] && rm -f "$rdir/.turn-merge.$sid"
# 0.3.7: 합치기 허락과 함께 만든 대화 기록 경로 파일(.turn-mergetp.<세션ID>)도 같이 지운다(하루 정리 .turn* 글로브도 덮는다)
[ -f "$rdir/.turn-mergetp.$sid" ] && rm -f "$rdir/.turn-mergetp.$sid"
# 0.4.0 자동 모드 허락(/refactor:approve B<n> 자동 이 만든 .turn-auto.B<n>)은 인자 없는 /refactor:go 한 차례에만(§2-1 #2) — 그 밖의 사람 입력
#   (두 번째 go 는 아래 go 처리에서 · go 하나씩·go 묶음·go 다시·approve 보류·일반 문장 …)은 세션과 상관없이 모두 지운다. 이번 입력이
#   /refactor:approve B<n> 자동 이면 아래 승인 처리가 새로 만든다. 합친 뒤의 .turn-merged.* 는 지우지 않는다(하루 정리만 — 합친 뒤 읽기 단계는 끝까지)
re_go0='^[[:space:]]*/refactor:go([[:space:]]|\\[nrt])*$'
if ! [[ $prompt =~ $re_go0 ]]; then
  for af_ in "$rdir"/.turn-auto.*; do [ -e "$af_" ] && rm -f "$af_"; done
fi
# 0.4.0 보완(검사 C#1): 자동 마감이 끝날 때 남긴 끝 표시(.turn-autoend.B<n> — 그 차례의 셸 명령 뒤 점검이 자동 줄을 알리지 않게만 씀)는
#   사람 입력이면(인자 없는 go 포함 · 알림 입력은 위에서 걸러 같은 차례) 모두 지운다 — 이 입력의 스냅숏이 그 줄까지 담으므로 더 필요 없다
for af_ in "$rdir"/.turn-autoend.*; do [ -e "$af_" ] && rm -f "$af_"; done
# 0.4.0 자동 모드 합친 뒤 사람 입력 없음 표시(.turn-nextok.B<n> — merge 단계가 씀 · verify 가 있을 때만 다음 묶음의 새 가지를 만든다)는
#   사람 입력이면(어떤 입력이든 — 인자 없는 go 포함) 모두 지운다(합친 뒤 사람이 끼어들었으면 새 가지는 사람이 /refactor:approve 새 가지 로)
for af_ in "$rdir"/.turn-nextok.*; do [ -e "$af_" ] && rm -f "$af_"; done

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
  # 0.3.7: 훅 입력의 transcript_path(대화 기록 파일 — 공식 공통 입력 칸)를 REFACTOR_TRANSCRIPT_PATH 로 넘긴다(합치기 허락이 경로를 적어 두고
  #   합치기 스크립트가 확인 도중 사람 입력을 알아챈다). 닫는 따옴표까지 읽혀야 쓰고, \\ → \ · \/ → / 밖의 이스케이프가 있으면 빈 값
  a_tp=""
  re_tp='"transcript_path"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)"'
  if [[ $input =~ $re_tp ]]; then
    a_bs='\'; a_sl='/'; a_one=$'\001'
    a_tp=${BASH_REMATCH[1]}; a_tp=${a_tp//"$a_bs$a_bs"/$a_one}; a_tp=${a_tp//"$a_bs$a_sl"/$a_sl}
    case "$a_tp" in *"$a_bs"*) a_tp="" ;; esac
    a_tp=${a_tp//"$a_one"/$a_bs}
  fi
  if [ -n "${REFACTOR_ROOT:-}" ] && [ -f "$REFACTOR_ROOT/hooks/run.sh" ]; then
    a_out=$(printf '%s' "$a_args" | REFACTOR_TURN_SID=$sid REFACTOR_TRANSCRIPT_PATH=$a_tp bash "$REFACTOR_ROOT/hooks/run.sh" refactor-approve "$proj" --from-hook 2>&1)
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
  # 0.4.0: 승인 기록의 줄 수(줄바꿈 수)도 적는다 — 턴 중에 더해진 줄이 자동 모드 꼴뿐이면 셸 명령 뒤 점검(post-check)이 알리지 않는다(§2-3)
  local c_="" x_ ln_=0
  if [ -f "$rdir/APPROVALS.log" ]; then IFS= read -r -d '' c_ < "$rdir/APPROVALS.log"; x_=${c_//[!$'\n']/}; ln_=${#x_}; fi
  { rl_protected_dirty "$proj" "$rdir"; printf 'APPROVALS\t%s\nAPPROVALS_N\t%s\n' "$SUMV" "$ln_"; } > "$D.tmp.$$" 2>/dev/null \
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
  # 0.3.3: 승인이 재설정되면 지난 기준선 허용 파일도 지운다(새 계획에서 같은 번호가 다른 카드일 수 있다) — 이번 턴의 컨텍스트(stdout)에 한 줄
  if [ -f "$rdir/.allow-baseline-edit" ]; then
    rm -f "$rdir/.allow-baseline-edit"
    [ -f "$rdir/.allow-baseline-edit" ] || printf '%s\n' "[Vibe Refactor] 승인이 재설정되어 지난 기준선 허용 파일(.allow-baseline-edit)을 지웠습니다."
  fi
  # 마이그레이션 허용 파일은 지우지 않고 알리기만(사람이 만들고 사람이 지운다)
  [ -f "$rdir/.allow-migration-edit" ] && printf '%s\n' "[Vibe Refactor] 마이그레이션 허용 파일(.allow-migration-edit)이 남아 있습니다 — 필요 없으면 사람이 지웁니다."
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

# 0.4.0 자동 모드: 인자 없는 /refactor:go 이면 이 세션의 자동 허락(.turn-auto.B<n> — 3줄 = 세션 ID)의 11줄 "go=" 에 지금 시각(초)을 채운다(차례 시작).
#   이미 채워져 있으면 두 번째 go 라 지운다(자동은 한 차례만). 다른 세션의 것·꼴이 다른 것은 그대로 둔다(자동 모드 스크립트가 거절한다).
#   채웠으면 이번 턴 컨텍스트(stdout)에 자동 마감 명령 꼴을 한 번 알린다(7-execute 「8. 자동 마감」)
auto_go() {
  local af_ n_ l_ ep_ b_="" body_ l3_ l11_ r_
  for af_ in "$rdir"/.turn-auto.B*; do
    [ -f "$af_" ] || continue
    n_=0; body_=""; l3_=""; l11_=""
    while IFS= read -r l_ || [ -n "$l_" ]; do
      l_=${l_%$'\r'}; n_=$((n_ + 1))
      [ "$n_" = 3 ] && l3_=$l_
      [ "$n_" = 11 ] && l11_=$l_
      body_="$body_$l_"$'\n'
    done < "$af_"
    [ "$l3_" = "$sid" ] || continue
    case "$l11_" in
      go=) ;;
      go=[0-9]*) rm -f "$af_"; continue ;;
      *) continue ;;
    esac
    ep_=""; (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] >= 402 )) && printf -v ep_ '%(%s)T' -1
    [ -n "$ep_" ] || ep_=$(date +%s)
    # 11줄째만 바꿔 쓴다(임시 파일 → mv — 안전장치가 반쯤 쓴 파일을 읽지 않게)
    n_=0; r_=""
    while IFS= read -r l_; do n_=$((n_ + 1)); [ "$n_" = 11 ] && l_="go=$ep_"; r_="$r_$l_"$'\n'; done <<AGO
$body_
AGO
    r_=${r_%$'\n'}
    printf '%s' "$r_" > "$af_.tmp.$$" 2>/dev/null && mv -f "$af_.tmp.$$" "$af_" 2>/dev/null || { rm -f "$af_.tmp.$$"; continue; }
    b_=${af_##*/.turn-auto.}
  done
  [ -n "$b_" ] || return 0
  local rt=${REFACTOR_ROOT:-}
  rt=${rt//"\\"//}; rt=${rt%/}
  printf '%s\n' "[Vibe Refactor 자동 모드] $b_ 자동 모드가 이번 /refactor:go 한 차례에서 켜졌습니다 — 묶음 카드가 모두 끝나면 phases/7-execute.md 「8. 자동 마감」 대로" \
    "  단계 이름만 바꿔 한 줄 그대로 실행합니다(다른 명령·래퍼와 섞지 않음): bash \"$rt/hooks/run.sh\" refactor-auto <단계> \"$proj\" $b_ $sid"
}

re_go='^[[:space:]]*/refactor:go([[:space:]]|\\[nrt]|$)'
re_again='^[[:space:]]*/refactor:go([[:space:]]|\\[nrt])+다시(([[:space:]]|\\[nrt])+([A-Za-z_]+))?'
re_bundle='^[[:space:]]*/refactor:go([[:space:]]|\\[nrt])+묶음(([[:space:]]|\\[nrt])|$)'
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
  [[ $prompt =~ $re_go0 ]] && auto_go
  # 0.4.0 "/refactor:go 묶음"(진행 중 계획서에 묶음·우선 칸만 덧붙이는 차례 — 6-plan 「묶기만」): 실행 대기를 비워 코드 수정을 막고(ready 빈 칸 →
  #   안전장치가 단계 실행의 코드 수정을 막음) 자동 모드 허락 파일(.turn-auto.*)을 지운다(#16 — 이 차례에 자동 마감이 돌지 않게)
  if [[ $prompt =~ $re_bundle ]]; then
    for af_ in "$rdir"/.turn-auto.*; do [ -e "$af_" ] && rm -f "$af_"; done
    mark ""
    snapshot
    exit 0
  fi
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
