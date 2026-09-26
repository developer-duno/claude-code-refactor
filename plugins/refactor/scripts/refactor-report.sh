#!/usr/bin/env bash
# Vibe Refactor 문제 신고 — 진단 묶음을 만들고(--collect), 사용자가 동의한 뒤에만 GitHub 이슈로 보낸다(--send).
#   bash <플러그인>/hooks/run.sh refactor-report --collect <프로젝트> --data <데이터폴더>   (설명은 표준입력)
#        → <데이터폴더>/report-<YYYYMMDD-HHMM>.md 에 쓰고 화면에 그대로 보여 준다. 아무 데도 보내지 않는다. 항상 0으로 끝난다.
#   bash <플러그인>/hooks/run.sh refactor-report --send --data <데이터폴더> [--file report-….md] [--title <제목>]
#        → gh issue create 로 이슈를 만들고 주소를 보여 준다. gh 가 없거나 로그인이 안 됐거나 만들기에 실패하면
#          이슈 작성 링크와 묶음 파일 경로를 보여 주고 4로 끝난다.
#   bash <플러그인>/hooks/run.sh refactor-report --log <출처> <내용> [<세부>]
#        → 문제 기록(problems.log)에 한 줄 남긴다(훅·실행기가 부른다). 실패해도 조용히 0으로 끝난다.
# 묶음과 제목은 보내기 전에 비밀값 모양(KEY=값·토큰·주소 속 비밀번호)과 홈 폴더 경로를 가린다.

data_dir() { local d=${1:-${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/refactor}}; printf '%s' "${d//\\//}"; }
now() { TZ=KST-9 date "+$1"; }

# ── --log (실행기가 오류 때 부른다 — 무거운 준비보다 먼저, 프로그램을 적게 띄운다) ──
if [ "${1:-}" = "--log" ]; then
  {
    src=${2:-?}; msg=${3:-}; det=${4:-}
    msg=${msg//$'\n'/ }; det=${det%%$'\n'*}
    if [ -n "$det" ]; then LC_ALL=C.UTF-8; msg="$msg ${det:0:60}"; fi
    D=$(data_dir ""); L="$D/problems.log"
    [ -d "$D" ] || mkdir -p "$D"
    t=""; (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] >= 402 )) && TZ=KST-9 printf -v t '%(%Y-%m-%d %H:%M)T' -1; [ -n "$t" ] || t=$(now '%Y-%m-%d %H:%M')   # %(…)T 는 bash 4.2+ 에서만
    printf '%s | %s | %s\n' "$t" "$src" "$msg" >> "$L"
    sz=$(wc -c < "$L"); sz=${sz//[!0-9]/}
    if [ "${sz:-0}" -gt 204800 ]; then tail -c 102400 "$L" | tail -n +2 > "$L.tmp" && mv -f "$L.tmp" "$L"; fi
  } </dev/null >/dev/null 2>&1
  exit 0
fi

REFACTOR_ROOT=${REFACTOR_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)}
DEFAULT_SLUG="developer-duno/claude-code-refactor"
tmo() { local s=$1; shift; if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"; else "$@"; fi; }

# 글자 수로 자른다(한글이 바이트 중간에서 잘리지 않게). UTF-8 로캘이 없으면 바이트로 자르고 깨진 끝 글자를 버린다.
cut_chars() { # $1 글자 수 $2 문자열
  local LC_ALL l x
  for l in C.UTF-8 en_US.UTF-8; do
    LC_ALL=$l; x="가나"; if [ "${#x}" = 2 ]; then printf '%s' "${2:0:$1}"; return; fi
  done 2>/dev/null
  LC_ALL=C; x=${2:0:$(($1 * 3))}
  if command -v iconv >/dev/null 2>&1; then printf '%s' "$x" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null; else printf '%s' "$x"; fi
}

# ── 가리기 ──────────────────────────────────────────────────────────────────
SECRET_WORDS='[Kk][Ee][Yy]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Tt][Oo][Kk][Ee][Nn]|[Pp][Aa][Ss][Ss]|[Pp][Rr][Ii][Vv][Aa][Tt][Ee]|[Cc][Rr][Ee][Dd][Ee][Nn][Tt][Ii][Aa][Ll]|[Dd][Ss][Nn]'   # 대소문자 무시(BSD sed 에는 I 플래그가 없다)
N='[A-Za-z0-9_.-]'
SED_REDACT="
s#(${N}*(${SECRET_WORDS})${N}*[\"']?[[:space:]]*[=:][[:space:]]*)(\"[^\"]*\"|'[^']*'|[^[:space:]\"',;]+)#\\1****#g
s#://[^/@[:space:]]+@#://****@#g
s#(^|[^A-Za-z0-9_])(sk_live|sk-|ghp_|github_pat_|xox[abp]-|AKIA|eyJ|sb_secret_|whsec_|rk_live_)[A-Za-z0-9_./+=-]{6,}#\\1****#g
s#AIza[0-9A-Za-z_-]{20,}#****#g
s#([Bb][Ee][Aa][Rr][Ee][Rr][[:space:]]+)[A-Za-z0-9._~+/=-]{8,}#\\1****#g
s#((/[A-Za-z])|[A-Za-z]:)?[\\\\/]Users[\\\\/][^\\\\/[:space:]\"']+#<홈>#g
s#/home/[^/[:space:]\"']+#<홈>#g
"
redact() { # 표준입력 → 가린 결과. $1 이 있으면 그 경로 글자 그대로도 <프로젝트>로 바꾼다
  local s p=${1:-}
  s=$(cat; printf x); s=${s%x}
  if [ -n "$p" ] && [ "${#p}" -gt 3 ]; then s=${s//"$p"/<프로젝트>}; s=${s//"${p//\//\\}"/<프로젝트>}; fi
  if [ -n "${HOME:-}" ] && [ "${#HOME}" -gt 3 ]; then s=${s//"$HOME"/<홈>}; fi
  printf '%s' "$s" | sed -E "$SED_REDACT"
}

mode=""; proj=""; data=""; file=""; title=""
while [ $# -gt 0 ]; do
  case "$1" in
    --collect) mode=collect; proj=${2:-}; shift ;;
    --send) mode=send ;;
    --data) data=${2:-}; shift ;;
    --file) file=${2:-}; shift ;;
    --title) title=${2:-}; shift ;;
    *) ;;
  esac
  [ $# -gt 0 ] && shift
done
data=$(data_dir "$data")

slug() {
  local s=""
  [ -f "$REFACTOR_ROOT/.claude-plugin/plugin.json" ] && s=$(tr -d '\r' < "$REFACTOR_ROOT/.claude-plugin/plugin.json" | grep -Eo 'github\.com[/:][A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' | head -n 1)
  s=${s#github.com?}; s=${s%.git}
  case "$s" in */*) printf '%s' "$s" ;; *) printf '%s' "$DEFAULT_SLUG" ;; esac
}

# ── --collect ───────────────────────────────────────────────────────────────
if [ "$mode" = "collect" ]; then
  desc=""
  [ -t 0 ] || desc=$(head -c 4000 | tr -d '\r')
  desc=$(printf '%s' "$desc" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$')
  pj="$REFACTOR_ROOT/.claude-plugin/plugin.json"; ver="모름"
  [ -f "$pj" ] && ver=$(tr -d '\r' < "$pj" | grep -Eo '"version"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n 1 | sed -E 's/.*"([^"]*)"$/\1/')
  rootp=${REFACTOR_ROOT//\\//}
  case "$rootp" in */.claude/plugins/*) where="마켓플레이스 설치(.claude/plugins 캐시)" ;; *) where="--plugin-dir 로 불러옴(개발용 폴더)" ;; esac
  cc=$(tmo 10 claude --version </dev/null 2>/dev/null | head -n 1); [ -n "$cc" ] || cc="모름"
  os=$(uname -srm 2>/dev/null); [ -n "${MSYSTEM:-}" ] && os="$os (MSYSTEM=$MSYSTEM)"
  gv=$(git --version 2>/dev/null | head -n 1); gv=${gv#git version }
  pv=""
  for p in python3 python; do
    pv=$(tmo 10 "$p" --version </dev/null 2>&1 | head -n 1); case "$pv" in "Python "[0-9]*) pv=${pv#Python }; break ;; *) pv="" ;; esac
  done
  pdir=${proj:-$PWD}; pdir=${pdir//\\//}; pdir=${pdir%/}; pname=${pdir##*/}
  st="시작 전(STATE.md 없음)"
  if [ -f "$pdir/docs/refactor/STATE.md" ]; then
    ph=$(tr -d '\r' < "$pdir/docs/refactor/STATE.md" | grep -m1 '^phase:' | sed -E 's/^phase:[[:space:]]*//; s/[^A-Za-z0-9_-]//g')
    ga=$(tr -d '\r' < "$pdir/docs/refactor/STATE.md" | grep -m1 '^gate:' | sed -E 's/^gate:[[:space:]]*//; s/[^A-Za-z0-9_-]//g')
    st="phase=${ph:-?} · gate=${ga:-?}"
  fi
  plog="(기록 없음)"
  [ -s "$data/problems.log" ] && plog=$(tail -n 30 "$data/problems.log" | tr -d '\r')
  raw="# Vibe Refactor 문제 신고

- 만든 때: $(now '%Y-%m-%d %H:%M') KST

## 환경
- 플러그인 버전: ${ver:-모름}
- 설치 위치: $where
- Claude Code: $cc
- OS: ${os:-모름}
- bash: ${BASH_VERSION:-모름} · git: ${gv:-모름} · python: ${pv:-모름}

## 프로젝트
- 폴더 이름: ${pname:-모름}
- 리팩토링 상태: $st

## 최근 문제 기록 (problems.log 마지막 30줄)
\`\`\`
$plog
\`\`\`

## 사용자 설명
${desc:-(설명 없음)}
"
  out=$(printf '%s' "$raw" | redact "$pdir")
  f="$data/report-$(now '%Y%m%d-%H%M').md"
  if mkdir -p "$data" 2>/dev/null && printf '%s\n' "$out" > "$f" 2>/dev/null; then saved="저장한 파일: $f"; else saved="⚠️ 파일로 저장하지 못했습니다(데이터 폴더에 쓸 수 없음)."; fi
  printf '%s\n\n---\n' "$out"
  printf '%s\n보낼 곳: https://github.com/%s/issues (공개 이슈)\n이 내용은 아직 아무 데도 보내지 않았습니다.\n' "$saved" "$(slug)" | redact "$pdir"
  exit 0
fi

# ── --send ──────────────────────────────────────────────────────────────────
if [ "$mode" = "send" ]; then
  if [ -n "$file" ]; then
    f=${file//\\//}
    case "${f##*/}" in report-*.md) ;; *) echo "[refactor] 보낼 수 있는 파일은 /refactor:report 가 만든 묶음(report-….md)뿐입니다." >&2; exit 3 ;; esac
    case "$f" in */*) ;; *) f="$data/$f" ;; esac
  else
    f=""; for c in "$data"/report-*.md; do [ -f "$c" ] && f=$c; done
  fi
  if [ -z "$f" ] || [ ! -f "$f" ]; then echo "[refactor] 보낼 묶음이 없습니다 — 먼저 /refactor:report 로 묶음을 만드세요." >&2; exit 3; fi
  s=$(slug)
  body="$data/.send-body.md"
  redact < "$f" > "$body" 2>/dev/null || body=$f
  t=${title//$'\n'/ }; [ -n "$t" ] || t="문제 신고"
  t=$(printf '%s' "[refactor] $(cut_chars 80 "$t")" | redact)
  fallback() {
    local enc="" i c LC_ALL=C
    for ((i = 0; i < ${#t}; i++)); do c=${t:i:1}; case "$c" in [A-Za-z0-9._~-]) enc+=$c ;; *) enc+=$(printf '%%%02X' "'$c") ;; esac; done
    echo "이슈 작성 링크(제목만 채워져 있습니다 — 묶음 파일 내용을 본문에 붙여 넣어 주세요):"
    echo "https://github.com/$s/issues/new?template=bug.yml&title=$enc"
    echo "묶음 파일: $f"
    exit 4
  }
  if ! command -v gh >/dev/null 2>&1; then echo "gh(GitHub CLI)가 없어 이슈를 직접 만들지 않았습니다."; fallback; fi
  if ! tmo 20 gh auth status </dev/null >/dev/null 2>&1; then echo "gh 에 로그인돼 있지 않아 이슈를 직접 만들지 않았습니다(gh auth login 뒤 다시 할 수 있습니다)."; fallback; fi
  res=$(tmo 60 gh issue create --repo "$s" --title "$t" --body-file "$body" --label bug </dev/null 2>&1); rc=$?
  url=$(printf '%s\n' "$res" | grep -Eo 'https://github\.com/[^[:space:]]+/issues/[0-9]+' | tail -n 1)
  if [ "$rc" = 0 ] && [ -n "$url" ]; then echo "이슈를 만들었습니다: $url"; exit 0; fi
  echo "이슈 만들기에 실패했습니다(gh 종료 코드 $rc): $(printf '%s' "$res" | head -n 1 | redact)"
  fallback
fi

echo "사용법: … refactor-report --collect <프로젝트> --data <데이터폴더>   ·   … refactor-report --send --data <데이터폴더> [--file report-….md] [--title <제목>]" >&2
exit 64
