#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Vibe Refactor — 셸 명령 뒤 점검 (PostToolUse 훅, Bash·PowerShell·Monitor 뒤에만)
#
# 리팩토링 진행 중에, 이번 턴이 시작된 뒤 "이미 커밋된 기준선 테스트·마이그레이션 파일"이 새로 바뀌었으면
# Claude에게 즉시 알린다(42 → run.sh가 2로 바꿈 → Claude가 이 메시지를 받는다). 명령은 이미 실행됐으므로
# 되돌릴지는 사람이 정한다. 포맷터·스냅숏 갱신처럼 안전장치(PreToolUse)가 미리 못 알아본 경우를 잡는 그물이다.
# 턴이 시작될 때 이미 바뀌어 있던 파일(사용자의 작업)은 turn.sh가 docs/refactor/.turn-dirty 에 적어 두고, 여기서 뺀다.
# 같은 스냅숏의 승인 기록 지문과 지금 지문이 다르면(턴 중에 APPROVALS.log 가 바뀜) 따로 알린다.
# 기준선 작성 단계에서도 이미 커밋된 기준선 파일은 보호한다(새 기준선 파일은 커밋 전이라 대상이 아니다).
# ─────────────────────────────────────────────────────────────────────────────

LC_ALL=C
export LC_ALL
IFS= read -r -d '' _input || true

proj=${CLAUDE_PROJECT_DIR:-$PWD}
proj=${proj//"\\"//}
proj=${proj%/}
rdir="$proj/docs/refactor"
[ -f "$rdir/STATE.md" ] || exit 0

phase=""
re_phase='^phase:[[:space:]]*"?([A-Za-z_]+)'
while IFS= read -r line || [ -n "$line" ]; do
  if [[ $line =~ $re_phase ]]; then phase=${BASH_REMATCH[1]}; break; fi
done < "$rdir/STATE.md"
case "$phase" in "") exit 0 ;; esac

root=${REFACTOR_ROOT:-}
lib="$root/scripts/refactor-lib.sh"
[ -n "$root" ] && [ -f "$lib" ] || exit 0
eval "$(tr -d '\r' < "$lib")"
# 사용자가 마무리를 확인한 DONE이면 끝(AI가 STATE만 DONE으로 바꾼 것은 아직 진행 중으로 본다)
[ "$phase" = "DONE" ] && rl_done_confirmed "$rdir" && exit 0

cur=$(rl_protected_dirty "$proj" "$rdir")
snap=""
[ -f "$rdir/.turn-dirty" ] && snap=$(tr -d '\r' < "$rdir/.turn-dirty")
NL=$'\n'; TAB=$'\t'

# 1) 승인 기록(APPROVALS.log)이 이번 턴에 바뀌었나 — /refactor:approve 는 턴이 시작되기 전에 실행되므로 턴 중 변경은 비정상
log_alarm=""
case "$NL$snap" in
  *"${NL}APPROVALS$TAB"*)
    before=${snap#*APPROVALS"$TAB"}; before=${before%%"$NL"*}
    now_sum=$(rl_log_sum "$rdir/APPROVALS.log")
    [ "$before" != "$now_sum" ] && log_alarm=1 ;;
esac

# 2) 보호된 파일 중 턴 시작 때와 달라진 것
changed=""; n=0
while IFS= read -r l; do
  [ -z "$l" ] && continue
  case "$NL$snap$NL" in *"$NL$l$NL"*) continue ;; esac   # 턴 시작 때와 똑같은 상태면 사용자의 기존 작업
  n=$((n + 1)); [ "$n" -le 10 ] && changed="$changed    ${l%%"$TAB"*}$NL"
done <<EOF
$cur
EOF
[ -z "$changed" ] && [ -z "$log_alarm" ] && exit 0

{
  if [ -n "$log_alarm" ]; then
    printf '[refactor 안전장치] 이번 턴에 승인 기록(docs/refactor/APPROVALS.log)이 바뀌었습니다. 승인은 사용자가 /refactor:approve 로만 합니다.\n'
    printf '  → 즉시 멈추고 사용자에게 알리세요. 이번 턴에 더해진 승인 줄은 사람이 확인하기 전까지 믿지 않습니다(git diff docs/refactor/APPROVALS.log 로 보여 주기).\n'
  fi
  if [ -n "$changed" ]; then
    printf '[refactor 안전장치] 이번 턴에 보호된 파일(커밋된 기준선 테스트·마이그레이션)이 바뀌었습니다(방금 명령 때문일 수 있음):\n'
    printf '%s' "$changed"
    printf '  → 작업을 멈추고 사용자에게 알리세요. 무엇이 바뀌었는지 git diff <파일> 로 보여 주고, 되돌릴지는 사람이 정합니다.\n'
    printf '    (사용자가 일부러 바꾼 것이면 그대로 두면 됩니다. 기준선을 새 동작으로 바꾸는 단계라면 사람이 먼저 허용 파일을 만들어야 합니다.)\n'
  fi
} >&2
exit 42
