#!/usr/bin/env bash
# Vibe Refactor 실행기 — hooks/<이름>.sh 또는 scripts/<이름>.sh 를 실행한다. 사용: bash run.sh <이름> [인자...]
# - 역슬래시 경로(D:\...\run.sh)로 불러도 되게 먼저 / 로 바꾼다. 파일 어디에든 윈도우 줄바꿈(\r)이 섞여 있으면 \r을 지운 사본으로 실행한다.
# - 스크립트를 못 찾으면(이름이 틀림·파일 없음) 표준오류에 한 줄을 남기고 127로 끝낸다. 훅 이름(guard 등)이면 1(막지 않는 오류)로 끝낸다.
# - 훅(hooks/)만: 안전장치가 일부러 막을 때는 42로 끝나고 여기서 2(차단)로 바꾼다. 훅이 고장 나서 2로 끝나면(문법 오류 등)
#   1로 바꿔 모든 도구 호출이 막히는 사고를 막는다(1 = 막지 않는 오류). scripts/ 의 종료 코드는 그대로 돌려준다(안전 실행기 등).
# - REFACTOR_ROOT(플러그인 폴더)를 알려 준다. 아래 명령 줄 끝의 # 은 이 파일에 \r이 들어와도 주석이 되게 하려는 것이니 지우지 마세요.
s=${BASH_SOURCE[0]}; s=${s//\\//}; case "$s" in */*) d=${s%/*} ;; *) d=. ;; esac; REFACTOR_ROOT=${d%/hooks}; [ "$REFACTOR_ROOT" = "$d" ] && REFACTOR_ROOT="$d/.."; export REFACTOR_ROOT #
n=${1:-}; h=0; g=""; case "$n" in guard|turn|post-check|session-start) h=1 ;; esac; f=""; case "$n" in *[!A-Za-z0-9_-]*|"") ;; *) if [ -f "$d/$n.sh" ]; then f="$d/$n.sh"; h=1; elif [ -f "$d/../scripts/$n.sh" ]; then f="$d/../scripts/$n.sh"; fi ;; esac #
trap 'x=${r:-$?}; w=""; [ -z "$f" ] && w=" (파일 없음)"; case "$n" in *[!A-Za-z0-9_-]*|"") n="?" ;; esac; [ -n "$g" ] && bash "$d/run.sh" refactor-report --log run.sh "$n 판정 중 멈춤(신호 $g) → 재시도" </dev/null >/dev/null 2>&1; case "$n:$x$w" in refactor-report:*|refactor-safe-run:*) ;; *:s) bash "$d/run.sh" refactor-report --log run.sh "$n 판정 중 멈춤(신호 $v) → 차단" </dev/null >/dev/null 2>&1 ;; *:t) bash "$d/run.sh" refactor-report --log run.sh "$n 시간 초과(${T}초) → 차단" </dev/null >/dev/null 2>&1 ;; *:2|*:124|*:127|*" (파일 없음)") bash "$d/run.sh" refactor-report --log run.sh "$n exit $x$w" </dev/null >/dev/null 2>&1 ;; esac' EXIT # 하위 스크립트가 2(문법 오류 등)·124(시간 초과)·127(없음)로 끝나거나 파일이 없으면 문제 기록(problems.log)에 이름·실제 종료 코드만 한 줄 남긴다(guard 감시가 끊었으면 "guard 시간 초과(T초) → 차단". 없는 훅은 exit 1, 없는 스크립트는 exit 127 + "(파일 없음)"). guard 가 신호로 죽어 다시 판정했으면 "guard 판정 중 멈춤(신호 N) → 재시도", 다시도 죽어 막았으면 "→ 차단"
if [ -z "$f" ]; then printf '[refactor] 스크립트 없음: %s\n' "$n" >&2; [ "$h" = 1 ] && exit 1; exit 127; fi #
# - guard 빠른 길(0.3.0): 안전장치는 리팩토링 중에만 판정한다. CLAUDE_PROJECT_DIR(훅에 실리는 프로젝트 폴더)가 있는 폴더이고 그 아래에 docs/refactor 폴더가 없으면
#   표준입력을 읽지 않고 0 으로 끝낸다(감시·guard 를 띄우지 않음 — 평소 호출 = bash 1개). 경로는 guard 와 같이 역슬래시를 / 로 바꾸고 끝의 / 를 뗀다.
#   Claude Code 가 프로젝트 폴더를 알려 주지 않았거나(환경 변수 없음) 그 폴더를 열 수 없으면(판정 불가 = 켜짐 쪽) 빠른 길을 타지 않고, 기록 폴더가 있을 때와
#   같이 guard 가 판정한다(STATE·마무리 확인·go 표시). REFACTOR_GUARD_ALWAYS=1(정확히 1)이면 이 길을 건너뛴다(0.2.4 동작).
if [ "$n" = guard ] && [ "${REFACTOR_GUARD_ALWAYS:-}" != 1 ] && [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then q=${CLAUDE_PROJECT_DIR//\\//}; q=${q%/}; [ -d "$q" ] && [ ! -d "$q/docs/refactor" ] && exit 0; fi #
# - guard 감시: 시간 초과된 PreToolUse 훅은 도구 호출을 막지 않는다 → guard 가 T초(기본 25, REFACTOR_GUARD_LIMIT 로 1~25 사이로만 줄일 수 있음) 안에
#   안 끝나면 guard 를 죽이고 2(차단). 감시(>( … ))는 guard 만 쥔 파이프의 끝을 read -t 로 기다린다 — guard 가 끝나면 바로 끝나고(sleep·kill 없음),
#   T초가 지나면 guard 를 KILL 한다(bash 3.2 는 긴 확장 한 번 중에는 trap 을 못 돌린다). 배경 명령은 표준입력이 비워지므로 입력을 한 번 읽어 두고 파이프로 넘긴다(다시 판정할 때 같은 입력을 또 준다).
#   시간 초과 판정: bash 4 이상은 read -t 가 시간 초과면 128 넘는 코드를 낸다(끝남=1 과 구별). bash 3.2 는 둘 다 1 이라 경과 초로 보되
#   read 가 조금 일찍 돌아와도 놓치지 않게 1초 여유(T-1 이상, T=1 이면 여유 0 — 바로 끝난 guard 를 치지 않게). 한도 값은 로캘과 무관하게 1~25 를 나열.
#   감시는 파이프에 무엇이 쓰여도(guard·자식이 물려받은 fd 5 — 줄·글자·NUL) 손을 놓지 않는다: 남은 시간으로 되풀이해 읽고, 기다리는 것은
#   "파이프 닫힘(guard 끝)"과 "한도 경과" 둘뿐. 파이프에서 guard 번호를 받지 않고, 한도가 지나면 이 셸($$)에 USR1 을 보내 이 셸이 guard 를 KILL 한다.
shift; c=$(<"$f"); if [ "$n" = guard ]; then T=${REFACTOR_GUARD_LIMIT:-}; case "$T" in 1|2|3|4|5|6|7|8|9|10|11|12|13|14|15|16|17|18|19|20|21|22|23|24|25) ;; *) T=25 ;; esac #
  p=""; u=""; trap 'u=1; [ -n "$p" ] && kill -9 "$p" 2>/dev/null' USR1 #
  exec 5> >(exec >/dev/null 2>&1; s=$SECONDS; e=1; while :; do l=$((T - (SECONDS - s))); if [ "$l" -le 0 ]; then e=255; break; fi; read -r -d '' -t "$l" x; e=$?; [ "$e" = 0 ] || break; done; if [ "${BASH_VERSINFO[0]}" -ge 4 ]; then [ "$e" -gt 128 ]; else [ $((SECONDS - s)) -ge $((T > 1 ? T - 1 : T)) ]; fi && kill -USR1 $$); in=$(cat; printf x); in=${in%x}; k=0 #
  while :; do case "$c" in *$'\r'*) printf '%s' "$in" | bash <(printf '%s\n' "$c" | tr -d '\r') "$@" & ;; *) printf '%s' "$in" | bash "$f" "$@" & ;; esac; p=$!; wait "$p" 2>/dev/null; r=$? #
  if [ "$u" = 1 ] && [ "$r" -gt 128 ] && [ "$r" != 137 ]; then wait "$p" 2>/dev/null; r=$?; case "$r" in 0|1|2|42) ;; *) r=137 ;; esac; fi # USR1 이 wait 를 깨웠으면 KILL 된 guard 를 다시 거둔다(137). guard 가 그 순간 스스로 끝나 있었으면 상태를 못 찾을 수 있다(127·255) — 판정을 모르면 막는다(137)
  [ "$r" -gt 128 ] && [ "$r" != 137 ] && [ "$k" = 0 ] && [ "$u" != 1 ] && { k=1; g=$((r - 128)); continue; }; break; done; exec 5>&- # 0.4.2 W4: guard 가 신호로 죽으면(맥 bash 3.2 정규식 엔진 충돌 등 — 감시 KILL 137 제외) 같은 입력으로 한 번만 다시 판정한다. 감시(fd 5)는 두 번에 걸쳐 하나 — 한도 T초는 합계
  if [ "$r" = 137 ]; then printf '[refactor 안전장치] 판정이 너무 오래 걸려 막았습니다(%s초 초과) — 내용을 파일로 저장해 경로를 넘기거나, 명령을 나눠 주세요.\n  → 긴 지시문·SQL 은 파일로 저장해 경로를 넘기고, 긴 명령은 Write 도구로 스크립트 파일을 만들어 무엇을 하는지 사용자에게 보여 준 뒤 실행하세요.\n  (같은 결과를 내는 다른 명령으로 우회하지 말고, 무엇이 막혔는지 사용자에게 보고하세요. → 로 안내된 방법은 써도 됩니다.)\n' "$T" >&2; r=t; exit 2; fi #
  if [ "$r" -gt 128 ]; then v=$((r - 128)); printf '[refactor 안전장치] 판정 중 안전장치가 멈춰(신호 %s) 막았습니다 — 같은 명령을 한 번 더 시도하거나 명령을 나눠 주세요.\n  (같은 결과를 내는 다른 명령으로 우회하지 말고, 무엇이 막혔는지 사용자에게 보고하세요.)\n' "$v" >&2; r=s; exit 2; fi # 다시 판정해도 신호로 죽었으면 막는다(판정을 모르면 막음)
else case "$c" in *$'\r'*) bash <(printf '%s\n' "$c" | tr -d '\r') "$@" ;; *) bash "$f" "$@" ;; esac; r=$?; fi #
if [ "$h" = 1 ]; then [ "$r" = 42 ] && exit 2; [ "$r" = 2 ] && exit 1; fi; exit "$r" #
