#!/usr/bin/env bash
# Vibe Refactor — SessionStart 훅
# 새 대화·/clear·자동 요약 뒤에, 리팩토링이 진행 중인 프로젝트면 현재 상태와 규칙을 Claude에게 알려 준다.
# (이 스크립트의 출력은 Claude의 대화 맥락에 추가된다. STATE.md가 없으면 아무것도 출력하지 않는다.)

LC_ALL=C
export LC_ALL

proj=${CLAUDE_PROJECT_DIR:-$PWD}
proj=${proj//"\\"//}
proj=${proj%/}
state="$proj/docs/refactor/STATE.md"
# 리팩토링 중이 아니면 입력을 읽지 않고 바로 끝낸다(입력 내용은 쓰지 않는다)
[ -d "$proj/docs/refactor" ] && [ -f "$state" ] || exit 0
IFS= read -r -d '' _input || true

# STATE.md 맨 위 --- 사이의 요약 칸(최대 20줄)
front=""
n=0
inside=0
while IFS= read -r line || [ -n "$line" ]; do
  line=${line%$'\r'}
  n=$((n + 1))
  if [ "$n" -eq 1 ]; then
    [ "$line" = "---" ] && inside=1 && continue
    break
  fi
  [ "$line" = "---" ] && break
  [ "$inside" = 1 ] && front="$front  $line"$'\n'
  [ "$n" -gt 21 ] && break
done < "$state"

phase=$(printf '%s' "$front" | sed -n -E 's/^[[:space:]]*phase:[[:space:]]*"?([A-Za-z_]+).*/\1/p' | head -n 1)

lib_ok=0   # refactor-lib.sh 를 이미 읽었으면 1(0.4.4 — 시작마다 한 번만 읽는다)
if [ "$phase" = "DONE" ]; then
  lib="${REFACTOR_ROOT:-}/scripts/refactor-lib.sh"
  if [ -n "${REFACTOR_ROOT:-}" ] && [ -f "$lib" ] && { eval "$(tr -d '\r' < "$lib")"; lib_ok=1; rl_done_confirmed "$proj/docs/refactor"; }; then
    printf '[Vibe Refactor] 이 프로젝트의 리팩토링은 완료(DONE) 상태입니다. 다시 점검하려면 사용자가 /refactor:go 다시 CHECKUP 을 실행합니다. 안전장치는 꺼져 있습니다.\n'
    exit 0
  fi
  printf '[Vibe Refactor] STATE는 DONE이지만 사용자의 마무리 확인(/refactor:approve 마무리)이 없어 안전장치가 켜져 있습니다. 끝내려면 사용자가 /refactor:approve 마무리 를 입력합니다.\n'
fi

printf '[Vibe Refactor] 이 프로젝트는 리팩토링이 진행 중입니다 (docs/refactor/STATE.md).\n'
printf '%s' "$front"
printf '규칙: 승인은 사용자가 /refactor:approve 로만 한다(근거는 APPROVALS.log — 계획서 체크 표시가 아님) · 푸시·PR 합치기는 사용자가 입력창 명령으로 한다(작업 가지 push 는 사용자가 /refactor:approve 푸시 로 허락한 차례에만 · 합치기는 /refactor:approve 합치기 · 합친 뒤 새 작업 가지는 /refactor:approve 새 가지) · 배포·운영 DB는 사람이 한다 · 기준선 커밋과 단계 커밋은 /refactor:go 가 그 파일만 한다 · 테스트·빌드는 안전 실행기(refactor-safe-run)로 한다 · 비밀값은 출력하지 않는다 · [refactor 안전장치] 차단은 우회하지 말고 보고한다.\n'
printf '이어서 하려면 사용자가 /refactor:go, 현황만 보려면 /refactor:status 를 실행한다. 사용자가 이어서 하자고 하면 이 명령을 안내한다.\n'

# 0.4.2 F5 잠깐 멈춤 중(안전장치와 같은 조건)이면 한 줄. 멈춤 파일(.allow-pause)은 아래 "허용 파일이 남아 있음" 알림에서 뺀다(사람이 다시 시작·만료로 지움)
#   0.4.4: lib 는 멈춤 파일·기준선 허용 파일 중 하나라도 있을 때 한 번만 읽는다(위 DONE 분기에서 읽었으면 다시 안 읽음)
if [ "$lib_ok" = 0 ] && [ -n "${REFACTOR_ROOT:-}" ] && [ -f "$REFACTOR_ROOT/scripts/refactor-lib.sh" ] \
  && { [ -f "$proj/docs/refactor/.allow-pause" ] || [ -f "$proj/docs/refactor/.allow-baseline-edit" ]; }; then
  eval "$(tr -d '\r' < "$REFACTOR_ROOT/scripts/refactor-lib.sh")"
  lib_ok=1
fi
if [ -f "$proj/docs/refactor/.allow-pause" ] && [ "$lib_ok" = 1 ]; then
  rl_pause_state "$proj/docs/refactor" && printf '⏸ 잠깐 멈춤 중 — %s 에 안전장치가 다시 켜집니다(일찍 끝내려면 사용자가 /refactor:approve 다시 시작 · 그 전에는 /refactor:go 로 이어 가지 않는다).\n' "$(rl_hm "$RL_PUNTIL")"
fi
for f in "$proj"/docs/refactor/.allow-*; do
  [ -e "$f" ] || continue
  [ "${f##*/}" = .allow-pause ] && continue
  # 0.4.4 ①(a): 기준선 허용 파일에 단계 ID 가 적혀 있으면 그 단계가 끝날 때 저절로 지워진다(turn.sh) — 상태로 갈라 "지우라"고 하지 않는다
  #   (현황 refactor-status.sh 의 같은 case 꼴). 빈 파일(ALL)·계획서에 없는 ID(UNKNOWN)·그 밖은 저절로 안 지워지니 지금 문구 그대로
  if [ "${f##*/}" = .allow-baseline-edit ] && [ "$lib_ok" = 1 ]; then
    a=$(rl_allow_baseline "$proj/docs/refactor"); a=${a%%$'\n'*}
    case "$a" in
      OPEN\ *|WAIT\ *|SHUT\ *)
        printf '[주의] 기준선 허용 파일(docs/refactor/.allow-baseline-edit)에 적힌 단계(%s) 중 아직 안 끝난 단계가 있습니다 — 단계가 모두 끝나면 저절로 지워지니 지우지 마세요(사용자에게 지우라고 하지 않는다).\n' "$(rl_allow_ids "$proj/docs/refactor")"
        continue ;;
      DONE\ *)
        printf '[안내] 기준선 허용 파일(docs/refactor/.allow-baseline-edit)의 단계가 모두 끝나 다음 입력 때 저절로 지워집니다(지우지 않아도 됩니다).\n'
        continue ;;
    esac
  fi
  printf '[주의] 허용 파일이 남아 있습니다: docs/refactor/%s — 그 작업이 끝났고 커밋했다면 사용자에게 지우라고 알려 주세요(터미널에서 rm "%s" — CLI 라면 입력창에 ! rm "…" 도 됨).\n' "${f##*/}" "$f"
done
exit 0
