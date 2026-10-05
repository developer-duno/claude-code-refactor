#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Vibe Refactor — 셸 명령 뒤 점검 (PostToolUse 훅, Bash·PowerShell·Monitor 뒤에만)
#
# 리팩토링 진행 중에, 이번 턴이 시작된 뒤 "이미 커밋된 기준선 테스트·마이그레이션 파일"이 새로 바뀌었으면
# Claude에게 즉시 알린다(42 → run.sh가 2로 바꿈 → Claude가 이 메시지를 받는다). 명령은 이미 실행됐으므로
# 되돌릴지는 사람이 정한다. 포맷터·스냅숏 갱신처럼 안전장치(PreToolUse)가 미리 못 알아본 경우를 잡는 그물이다.
# 턴이 시작될 때 이미 바뀌어 있던 파일(사용자의 작업)은 turn.sh가 docs/refactor/.turn-dirty.<세션ID> 에 적어 두고, 여기서 뺀다.
# 그 기준점에 있던 변경이 사라졌으면(사용자가 하던 작업이 되돌려짐) 그것도 알린다.
# 같은 스냅숏의 승인 기록 지문과 지금 지문이 다르면(턴 중에 APPROVALS.log 가 바뀜) 따로 알린다.
# 기준선 작성 단계에서도 이미 커밋된 기준선 파일은 보호한다(새 기준선 파일은 커밋 전이라 대상이 아니다).
# ─────────────────────────────────────────────────────────────────────────────

LC_ALL=C
export LC_ALL

proj=${CLAUDE_PROJECT_DIR:-$PWD}
proj=${proj//"\\"//}
proj=${proj%/}
rdir="$proj/docs/refactor"
# 리팩토링 중이 아니면 입력을 읽지 않고 바로 끝낸다(보통 프로젝트에서는 큰 도구 출력도 부담 없게)
[ -d "$rdir" ] && [ -f "$rdir/STATE.md" ] || exit 0

phase=""
re_phase='^phase:[[:space:]]*"?([A-Za-z_]+)'
while IFS= read -r line || [ -n "$line" ]; do
  if [[ $line =~ $re_phase ]]; then phase=${BASH_REMATCH[1]}; break; fi
done < "$rdir/STATE.md"
case "$phase" in "") exit 0 ;; esac

# 세션 ID(기준점 파일 이름)만 필요하므로 앞부분만 읽는다. 앞 4KB 에 없으면 나머지도 읽는다
re_s='"session_id"[[:space:]]*:[[:space:]]*"([^"]*)"'
input=$(head -c 4096)
if ! [[ $input =~ $re_s ]]; then input="$input$(cat)"; fi
sid=""
[[ $input =~ $re_s ]] && sid=${BASH_REMATCH[1]}
[[ $sid =~ ^[A-Za-z0-9_-]{1,128}$ ]] || sid=""

root=${REFACTOR_ROOT:-}
lib="$root/scripts/refactor-lib.sh"
[ -n "$root" ] && [ -f "$lib" ] || exit 0
eval "$(tr -d '\r' < "$lib")"
# 사용자가 마무리를 확인한 DONE이면 끝(AI가 STATE만 DONE으로 바꾼 것은 아직 진행 중으로 본다)
[ "$phase" = "DONE" ] && rl_done_confirmed "$rdir" && exit 0

cur=$(rl_protected_dirty "$proj" "$rdir")
snap=""
[ -n "$sid" ] && [ -f "$rdir/.turn-dirty.$sid" ] && snap=$(tr -d '\r' < "$rdir/.turn-dirty.$sid")
NL=$'\n'; TAB=$'\t'

# 0.4.0 자동 모드 예외(§2-3 — 결정 가): 이번 턴에 더해진 기록 줄이 전부 "| - | 자동 B<n> 으로 실행" 꼴이고(자동 모드 스크립트의 푸시·합치기 줄)
#   그 B<n> 의 유효한 자동 허락(.turn-auto.B<n> 또는 .turn-merged.B<n> — 1줄 = B<n> · 2줄 = 만든 시각 0~7200초 안 · 3줄 = 이 세션 ID)이 있으면 0.
#   턴 시작 때 기록의 줄 수(.turn-dirty 의 APPROVALS_N)만큼의 앞부분 지문이 그때 지문과 같아야 한다(앞 줄을 고치거나 지운 것은 예외 아님)
auto_only_lines() {
  local n="" gi="" f b l1 l2 l3 x i br mt nw="" pre ln any=0 re_p re_m lb lbr lmt
  local -a L
  case "$NL$snap" in *"${NL}APPROVALS_N$TAB"*) n=${snap#*APPROVALS_N"$TAB"}; n=${n%%"$NL"*} ;; *) return 1 ;; esac
  [[ $n =~ ^[0-9]{1,9}$ ]] && [ -n "$sid" ] && [ -f "$rdir/APPROVALS.log" ] || return 1
  # 보안 검사(10-05): 허락마다 "B|가지|방식" 을 모은다 — .turn-auto 는 ⑪ go= 가 채워졌을 때만(자동 차례 시작) · ④ 가지 ⑤ 방식,
  #   .turn-merged 는 ⑫ 가지 · 방식은 셋 중 아무거나(합친 뒤에는 방식이 파일에 없음)
  for f in "$rdir"/.turn-auto.B* "$rdir"/.turn-merged.B*; do
    [ -f "$f" ] || continue
    b=${f##*.}
    [[ $b =~ ^B[0-9]{1,6}$ ]] || continue
    L=(); i=0
    while IFS= read -r x || [ -n "$x" ]; do L[i]=${x%$'\r'}; i=$((i + 1)); [ "$i" -ge 13 ] && break; done < "$f"
    l1=${L[0]:-}; l2=${L[1]:-}; l3=${L[2]:-}
    [ "$l1" = "$b" ] && [ "$l3" = "$sid" ] && [[ $l2 =~ ^[0-9]{1,12}$ ]] || continue
    [ -n "$nw" ] || nw=$(date +%s)
    [ $((nw - 10#$l2)) -ge 0 ] && [ $((nw - 10#$l2)) -le 7200 ] || continue
    case "$f" in
      */.turn-auto.*) [[ ${L[10]:-} =~ ^go=[0-9]{1,12}$ ]] || continue; br=${L[3]:-}; mt=${L[4]:-} ;;
      *) br=${L[11]:-}; mt="*" ;;
    esac
    [[ $br =~ ^[A-Za-z0-9_][A-Za-z0-9._/-]*$ ]] || continue
    case "$mt" in squash|rebase|merge|"*") ;; *) continue ;; esac
    gi="$gi|$b|$br|$mt|"
  done
  [ -n "$gi" ] || return 1
  pre=$(head -n "$n" "$rdir/APPROVALS.log" | tr -d '\r' | cksum)
  [ "$(rl_cksum_fmt "$pre")" = "$before" ] || return 1
  # 자동 스크립트가 쓰는 두 꼴만(동작 이름을 정해 둠 — 승인·마무리 같은 다른 동작 줄은 예외 아님)
  re_p='^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} KST [|] 푸시 [|] ([A-Za-z0-9_][A-Za-z0-9._/-]*) [|] - [|] 자동 (B[0-9]{1,6}) 으로 실행$'
  re_m='^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} KST [|] 합치기 [|] 허락 ([A-Za-z0-9_][A-Za-z0-9._/-]*) PR[(]지금 가지[)] [(](squash|rebase|merge)[)] @[0-9a-f]{7} [|] - [|] 자동 (B[0-9]{1,6}) 으로 실행$'
  while IFS= read -r ln || [ -n "$ln" ]; do
    ln=${ln%$'\r'}
    [ -z "${ln//[[:space:]]/}" ] && continue
    if [[ $ln =~ $re_p ]]; then lbr=${BASH_REMATCH[1]}; lmt=""; lb=${BASH_REMATCH[2]}
    elif [[ $ln =~ $re_m ]]; then lbr=${BASH_REMATCH[1]}; lmt=${BASH_REMATCH[2]}; lb=${BASH_REMATCH[3]}
    else return 1; fi
    if [ -z "$lmt" ]; then   # 푸시 줄: 그 묶음 허락의 가지와 같아야
      case "$gi" in *"|$lb|$lbr|"*) ;; *) return 1 ;; esac
    else                     # 합치기 줄: 가지와 방식이 허락과 같아야(합친 뒤 허락은 방식 아무거나)
      case "$gi" in *"|$lb|$lbr|$lmt|"*|*"|$lb|$lbr|*|"*) ;; *) return 1 ;; esac
    fi
    any=1
  done < <(tail -n +"$((n + 1))" "$rdir/APPROVALS.log")
  [ "$any" = 1 ]
}

# 1) 승인 기록(APPROVALS.log)이 이번 턴에 바뀌었나 — /refactor:approve 는 턴이 시작되기 전에 실행되므로 턴 중 변경은 비정상
#    (0.4.0: 자동 모드 스크립트가 더한 줄뿐이면 예외 — 위 auto_only_lines)
log_alarm=""
case "$NL$snap" in
  *"${NL}APPROVALS$TAB"*)
    before=${snap#*APPROVALS"$TAB"}; before=${before%%"$NL"*}
    now_sum=$(rl_log_sum "$rdir/APPROVALS.log")
    if [ "$before" != "$now_sum" ]; then log_alarm=1; auto_only_lines && log_alarm=""; fi ;;
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
# 3) 턴 시작 때 바뀌어 있던 파일이 지금은 목록에서 사라짐(사용자가 하던 작업이 되돌려졌을 수 있음)
reverted=""; m=0
while IFS= read -r l; do
  [ -z "$l" ] && continue
  case "$l" in APPROVALS"$TAB"*|APPROVALS_N"$TAB"*) continue ;; esac
  p=${l%%"$TAB"*}
  case "$NL$cur$NL" in *"$NL$l$NL"*) continue ;; esac   # 그대로
  case "$NL$cur" in *"$NL$p$TAB"*) continue ;; esac       # 같은 파일을 또 바꿈 → 2)에서 이미 알림
  m=$((m + 1)); [ "$m" -le 10 ] && reverted="$reverted    $p$NL"
done <<EOF
$snap
EOF
# 4) 이번 입력 때 turn.sh 가 기준선 허용 파일을 지웠으면(적힌 단계가 모두 끝남, 0.3.2 #10) 한 번만 알린다
allow_gone=""
if [ -n "$sid" ] && [ -f "$rdir/.turn-allowgone.$sid" ]; then
  allow_gone=$(tr -d '\r\n' < "$rdir/.turn-allowgone.$sid"); [ -n "$allow_gone" ] || allow_gone="?"
  rm -f "$rdir/.turn-allowgone.$sid"
fi
[ -z "$changed" ] && [ -z "$log_alarm" ] && [ -z "$reverted" ] && [ -z "$allow_gone" ] && exit 0

{
  if [ -n "$allow_gone" ]; then
    printf '[refactor 안전장치] 허용 파일(.allow-baseline-edit)의 단계(%s)가 모두 끝나 지웠습니다. → 알림일 뿐이니 하던 일을 계속하세요.\n' "$allow_gone"
  fi
  if [ -n "$log_alarm" ]; then
    printf '[refactor 안전장치] 이번 턴에 승인 기록(docs/refactor/APPROVALS.log)이 바뀌었습니다. 승인은 사용자가 /refactor:approve 로만 합니다.\n'
    printf '  → 즉시 멈추고 사용자에게 알리세요. 이번 턴에 더해진 승인 줄은 사람이 확인하기 전까지 믿지 않습니다(git diff docs/refactor/APPROVALS.log 로 보여 주기).\n'
  fi
  if [ -n "$changed" ]; then
    printf '[refactor 안전장치] 이번 턴에 보호된 파일(커밋된 기준선 테스트·마이그레이션)이 바뀌었습니다(방금 명령 때문일 수 있음):\n'
    printf '%s' "$changed"
    printf '  → 작업을 멈추고 사용자에게 알리세요. 무엇이 바뀌었는지 git diff <파일> 로 보여 주고, 되돌릴지는 사람이 정합니다.\n'
    printf '    (사용자가 일부러 바꾼 것이면 그대로 두면 됩니다. 기준선을 새 동작으로 바꾸는 단계라면 사람이 먼저 허용 파일에 그 단계 ID 를 적어야 하고, 카드에 적힌 기준선만 고칩니다.)\n'
  fi
  if [ -n "$reverted" ]; then
    printf '[refactor 안전장치] 이번 턴이 시작될 때 사용자가 고치던 보호된 파일(기준선 테스트·마이그레이션)의 변경이 사라졌습니다(방금 명령이 되돌렸을 수 있음):\n'
    printf '%s' "$reverted"
    printf '  → 작업을 멈추고 사용자에게 알리세요. 사용자의 작업이 사라졌을 수 있습니다(되돌릴지·복구할지는 사람이 정합니다).\n'
  fi
} >&2
exit 42
