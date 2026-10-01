#!/usr/bin/env bash
# Vibe Refactor 실행기 — hooks/<이름>.sh 또는 scripts/<이름>.sh 를 실행한다. 사용: bash run.sh <이름> [인자...]
# - 역슬래시 경로(D:\...\run.sh)로 불러도 되게 먼저 / 로 바꾼다. 파일 어디에든 윈도우 줄바꿈(\r)이 섞여 있으면 \r을 지운 사본으로 실행한다.
# - 스크립트를 못 찾으면(이름이 틀림·파일 없음) 표준오류에 한 줄을 남기고 127로 끝낸다. 훅 이름(guard 등)이면 1(막지 않는 오류)로 끝낸다.
# - 훅(hooks/)만: 안전장치가 일부러 막을 때는 42로 끝나고 여기서 2(차단)로 바꾼다. 훅이 고장 나서 2로 끝나면(문법 오류 등)
#   1로 바꿔 모든 도구 호출이 막히는 사고를 막는다(1 = 막지 않는 오류). scripts/ 의 종료 코드는 그대로 돌려준다(안전 실행기 등).
# - REFACTOR_ROOT(플러그인 폴더)를 알려 준다. 아래 명령 줄 끝의 # 은 이 파일에 \r이 들어와도 주석이 되게 하려는 것이니 지우지 마세요.
s=${BASH_SOURCE[0]}; s=${s//\\//}; case "$s" in */*) d=${s%/*} ;; *) d=. ;; esac; REFACTOR_ROOT=${d%/hooks}; [ "$REFACTOR_ROOT" = "$d" ] && REFACTOR_ROOT="$d/.."; export REFACTOR_ROOT #
n=${1:-}; h=0; case "$n" in guard|turn|post-check|session-start) h=1 ;; esac; f=""; case "$n" in *[!A-Za-z0-9_-]*|"") ;; *) if [ -f "$d/$n.sh" ]; then f="$d/$n.sh"; h=1; elif [ -f "$d/../scripts/$n.sh" ]; then f="$d/../scripts/$n.sh"; fi ;; esac #
trap 'x=${r:-$?}; w=""; [ -z "$f" ] && w=" (파일 없음)"; case "$n" in *[!A-Za-z0-9_-]*|"") n="?" ;; esac; case "$n:$x$w" in refactor-report:*|refactor-safe-run:*) ;; *:t) bash "$d/run.sh" refactor-report --log run.sh "$n 시간 초과(${T}초) → 차단" </dev/null >/dev/null 2>&1 ;; *:2|*:124|*:127|*" (파일 없음)") bash "$d/run.sh" refactor-report --log run.sh "$n exit $x$w" </dev/null >/dev/null 2>&1 ;; esac' EXIT # 하위 스크립트가 2(문법 오류 등)·124(시간 초과)·127(없음)로 끝나거나 파일이 없으면 문제 기록(problems.log)에 이름·실제 종료 코드만 한 줄 남긴다(guard 감시가 끊었으면 "guard 시간 초과(T초) → 차단". 없는 훅은 exit 1, 없는 스크립트는 exit 127 + "(파일 없음)")
if [ -z "$f" ]; then printf '[refactor] 스크립트 없음: %s\n' "$n" >&2; [ "$h" = 1 ] && exit 1; exit 127; fi #
# - guard 감시: 시간 초과된 PreToolUse 훅은 도구 호출을 막지 않는다 → guard 가 T초(기본 25, REFACTOR_GUARD_LIMIT 로 1~25 사이로만 줄일 수 있음) 안에
#   안 끝나면 guard 를 죽이고 2(차단). 감시(>( … ))는 guard 만 쥔 파이프의 끝을 read -t 로 기다린다 — guard 가 끝나면 바로 끝나고(sleep·kill 없음),
#   T초가 지나면 guard 를 KILL 한다(bash 3.2 는 긴 확장 한 번 중에는 trap 을 못 돌린다). 배경 명령은 표준입력이 비워지므로 3 으로 넘긴다.
shift; c=$(<"$f"); if [ "$n" = guard ]; then T=${REFACTOR_GUARD_LIMIT:-}; case "$T" in [1-9]|1[0-9]|2[0-5]) ;; *) T=25 ;; esac; exec 5> >(exec >/dev/null 2>&1; read -r p; s=$SECONDS; read -r -t "$T" x; [ -n "$p" ] && [ $((SECONDS - s)) -ge "$T" ] && kill -9 "$p"); exec 3<&0 #
  case "$c" in *$'\r'*) bash <(printf '%s\n' "$c" | tr -d '\r') "$@" <&3 3<&- & ;; *) bash "$f" "$@" <&3 3<&- & ;; esac; p=$!; echo "$p" >&5; exec 5>&- 3<&-; wait "$p" 2>/dev/null; r=$? #
  if [ "$r" = 137 ]; then printf '[refactor 안전장치] 판정이 너무 오래 걸려 막았습니다(%s초 초과) — 내용을 파일로 저장해 경로를 넘기거나, 명령을 나눠 주세요.\n  (같은 결과를 내는 다른 명령으로 우회하지 말고, 무엇이 막혔는지 사용자에게 보고하세요. → 로 안내된 방법은 써도 됩니다.)\n' "$T" >&2; r=t; exit 2; fi #
else case "$c" in *$'\r'*) bash <(printf '%s\n' "$c" | tr -d '\r') "$@" ;; *) bash "$f" "$@" ;; esac; r=$?; fi #
if [ "$h" = 1 ]; then [ "$r" = 42 ] && exit 2; [ "$r" = 2 ] && exit 1; fi; exit "$r" #
