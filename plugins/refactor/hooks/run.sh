#!/usr/bin/env bash
# Vibe Refactor 실행기 — hooks/<이름>.sh 또는 scripts/<이름>.sh 를 실행한다. 사용: bash run.sh <이름> [인자...]
# - 역슬래시 경로(D:\...\run.sh)로 불러도 되게 먼저 / 로 바꾼다. 파일 어디에든 윈도우 줄바꿈(\r)이 섞여 있으면 \r을 지운 사본으로 실행한다.
# - 스크립트를 못 찾으면(이름이 틀림·파일 없음) 표준오류에 한 줄을 남기고 127로 끝낸다. 훅 이름(guard 등)이면 1(막지 않는 오류)로 끝낸다.
# - 훅(hooks/)만: 안전장치가 일부러 막을 때는 42로 끝나고 여기서 2(차단)로 바꾼다. 훅이 고장 나서 2로 끝나면(문법 오류 등)
#   1로 바꿔 모든 도구 호출이 막히는 사고를 막는다(1 = 막지 않는 오류). scripts/ 의 종료 코드는 그대로 돌려준다(안전 실행기 등).
# - REFACTOR_ROOT(플러그인 폴더)를 알려 준다. 아래 명령 줄 끝의 # 은 이 파일에 \r이 들어와도 주석이 되게 하려는 것이니 지우지 마세요.
s=${BASH_SOURCE[0]}; s=${s//\\//}; case "$s" in */*) d=${s%/*} ;; *) d=. ;; esac; REFACTOR_ROOT=${d%/hooks}; [ "$REFACTOR_ROOT" = "$d" ] && REFACTOR_ROOT="$d/.."; export REFACTOR_ROOT #
n=${1:-}; h=0; case "$n" in guard|turn|post-check|session-start) h=1 ;; esac; f=""; case "$n" in *[!A-Za-z0-9_-]*|"") ;; *) if [ -f "$d/$n.sh" ]; then f="$d/$n.sh"; h=1; elif [ -f "$d/../scripts/$n.sh" ]; then f="$d/../scripts/$n.sh"; fi ;; esac #
trap 'x=${r:-$?}; w=""; [ -z "$f" ] && w=" (파일 없음)"; case "$n" in *[!A-Za-z0-9_-]*|"") n="?" ;; esac; case "$n:$x$w" in refactor-report:*|refactor-safe-run:*) ;; *:2|*:124|*:127|*" (파일 없음)") bash "$d/run.sh" refactor-report --log run.sh "$n exit $x$w" </dev/null >/dev/null 2>&1 ;; esac' EXIT # 하위 스크립트가 2(문법 오류 등)·124(시간 초과)·127(없음)로 끝나거나 파일이 없으면 문제 기록(problems.log)에 이름·실제 종료 코드만 한 줄 남긴다(없는 훅은 exit 1, 없는 스크립트는 exit 127 + "(파일 없음)")
if [ -z "$f" ]; then printf '[refactor] 스크립트 없음: %s\n' "$n" >&2; [ "$h" = 1 ] && exit 1; exit 127; fi #
shift; c=$(<"$f"); case "$c" in *$'\r'*) bash <(printf '%s\n' "$c" | tr -d '\r') "$@" ;; *) bash "$f" "$@" ;; esac; r=$?; if [ "$h" = 1 ]; then [ "$r" = 42 ] && exit 2; [ "$r" = 2 ] && exit 1; fi; exit "$r" #
