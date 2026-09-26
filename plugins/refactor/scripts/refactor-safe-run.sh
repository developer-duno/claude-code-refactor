#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Vibe Refactor — 안전 실행기
#
# 리팩토링 중 테스트·빌드·앱을 실행할 때, 운영일 수 있는 설정값(DB 주소·API 키 등)을 가짜 값으로 바꿔서 실행한다.
#   bash <플러그인>/hooks/run.sh refactor-safe-run --check      무엇이 바뀌는지 이름만 보여 준다(값은 절대 출력하지 않음)
#   bash <플러그인>/hooks/run.sh refactor-safe-run -- <명령…>   가짜 값을 넣고 <명령>을 실행한다(종료 코드는 그대로)
#
# 원리: .env 파일을 읽는 도구들(dotenv, Next.js, Vite, python-dotenv, pydantic-settings, django-environ, Node --env-file,
#       Prisma 6 이하의 자동 로드·Prisma 7의 prisma.config.ts 속 dotenv/config)은 이미 셸에 있는 환경변수를 덮어쓰지 않는다.
#       그래서 같은 이름을 가짜 값으로 먼저 넣어 두면 앱은 가짜 값을 쓴다. DB 주소는 127.0.0.1:9(아무것도 없는 포트)로 바꿔
#       접속이 즉시 실패하게 한다.
# 판단: 이름과 값의 모양을 본다(값은 출력하지 않음). 비밀값·접속 주소로 보이는 것만 바꾸고, 테스트 키·로컬 주소·숫자·
#       짧은 설정값·파일 경로는 그대로 둔다. 사람이 개발용이라고 확인한 이름은 docs/refactor/.allow-env 에 한 줄씩 적으면
#       그대로 둔다(사람만 만드는 파일).
# 한계: 코드·설정 파일에 직접 적힌 키·주소, ~/.aws 같은 자격 증명 파일, 코드가 .env를 직접 읽거나 override 로 덮어쓰는 경우,
#       Cloudflare(wrangler)가 직접 읽는 .dev.vars·.env, docker compose 의 env_file, Supabase 함수의 supabase/functions/.env,
#       그리고 코드가 하는 실제 네트워크 요청(수집 대상 사이트 등)은 가려지지 않는다. --check 가 흔적을 찾아 알린다.
# ─────────────────────────────────────────────────────────────────────────────

# 이 스크립트는 LC_ALL 을 바꾸지 않는다(실행할 테스트의 출력이 달라지지 않게).

say() { printf '%s\n' "$*" >&2; }

# ── 프로젝트 폴더 찾기(.git 또는 docs/refactor 가 있는 가장 가까운 위 폴더) ─
root=$PWD
d=$PWD
while [ -n "$d" ] && [ "$d" != "/" ]; do
  if [ -e "$d/.git" ] || [ -d "$d/docs/refactor" ]; then root=$d; break; fi
  d=${d%/*}
done

heavy_dir() { [ -d "$1" ] || return 0; case "${1%/}" in */node_modules|*/.git|*/.next|*/.nuxt|*/.cache|*/.turbo|*/.vercel|*/dist|*/build|*/.venv|*/venv|*/__pycache__|*/vendor|*/target|*/coverage|*/.idea|*/.vscode) return 0 ;; esac; return 1; }

# ── 설정 파일 모으기(세 단계 아래까지, 숨김 폴더 포함, 큰 폴더 제외, 예시 파일 제외) ─
dirs=("$root")
for d1 in "$root"/*/ "$root"/.[!.]*/; do
  heavy_dir "$d1" && continue
  dirs+=("${d1%/}")
  for d2 in "$d1"*/ "$d1".[!.]*/; do
    heavy_dir "$d2" && continue
    dirs+=("${d2%/}")
    for d3 in "$d2"*/; do heavy_dir "$d3" && continue; dirs+=("${d3%/}"); done
  done
done
files=()
for dd in "${dirs[@]}"; do
  for f in "$dd"/.env "$dd"/.env.* "$dd"/.env-* "$dd"/.env_* "$dd"/*.env "$dd"/.envrc "$dd"/.dev.vars "$dd"/.dev.vars.*; do
    [ -f "$f" ] || continue
    case "${f##*/}" in *.example|*.sample|*.template|*.dist) continue ;; esac
    files+=("$f")
  done
done

# 사람이 "개발용이라 그대로 둬도 된다"고 적은 이름(docs/refactor/.allow-env, 한 줄에 하나)
#   NAME=호스트  → 지금 값의 호스트가 적어 둔 호스트와 같을 때만 그대로 둔다(나중에 운영 주소로 바뀌면 다시 가린다)
#   NAME        → 주소가 아닌 값(키 등)만 그대로 둔다. 주소(URL·호스트) 값은 호스트를 함께 적어야 그대로 둔다
allowed=" "; allow_hosts=""
if [ -f "$root/docs/refactor/.allow-env" ]; then
  while IFS= read -r a || [ -n "$a" ]; do
    a=${a%$'\r'}; a=${a%%#*}; a=${a//[[:space:]]/}
    [ -z "$a" ] && continue
    case "$a" in *=*) allowed="$allowed${a%%=*} "; allow_hosts="$allow_hosts${a%%=*}=${a#*=}"$'\n' ;; *) allowed="$allowed$a " ;; esac
  done < "$root/docs/refactor/.allow-env"
fi
allowed_ok() { # $1 이름 $2 값 — 허용 목록에 있고(호스트를 적었으면) 호스트가 같은가
  case "$allowed" in *" $1 "*) ;; *) return 1 ;; esac
  local want line
  while IFS= read -r line; do [ "${line%%=*}" = "$1" ] && want=${line#*=}; done <<AH
$allow_hosts
AH
  if [ -z "${want:-}" ]; then
    # 이름만 적은 경우: 주소 모양의 값이면 호스트가 없으므로 허용하지 않는다
    is_address "$2" && return 1
    return 0
  fi
  # 호스트를 적은 경우: 값에 든 호스트가 모두(쉼표 목록 포함) 적어 둔 호스트와 같을 때만
  host_of "$2"
  [ -n "$HOSTS" ] || return 1
  local h
  for h in $HOSTS; do [ "$h" = "$want" ] || return 1; done
  return 0
}

# ── 이름·값 분류 ─────────────────────────────────────────────────────────────
# 절대 건드리지 않는 이름(대소문자 구분: npm 이 넣는 npm_config_* 는 그대로, NPM_TOKEN 은 가린다)
is_untouchable() {
  case "$1" in
    PATH|HOME|USER|LOGNAME|SHELL|PWD|OLDPWD|TERM|TMPDIR|TEMP|TMP|LANG|LANGUAGE|TZ|NODE_ENV|PYTHONPATH|VIRTUAL_ENV|CI|SHLVL|HOSTNAME|DISPLAY|EDITOR|PAGER|PORT) return 0 ;;
    SSH_AUTH_SOCK|SSH_AGENT_PID|SSH_TTY|SSH_CONNECTION|SSH_CLIENT) return 0 ;;
    HTTP_PROXY|HTTPS_PROXY|NO_PROXY|ALL_PROXY|http_proxy|https_proxy|no_proxy|all_proxy) return 0 ;;
    GIT_DIR|GIT_WORK_TREE|GIT_EXEC_PATH|GIT_ASKPASS|GIT_EDITOR|GIT_PAGER|GIT_SSH|GIT_SSH_COMMAND|GIT_TERMINAL_PROMPT|GIT_CONFIG_COUNT|GIT_CONFIG_KEY_*|GIT_CONFIG_VALUE_*|GIT_CONFIG_PARAMETERS|GIT_AUTHOR_*|GIT_COMMITTER_*) return 0 ;;
    LC_*|XDG_*|GPG_*|npm_config_*|npm_lifecycle_*|npm_package_*|npm_node_execpath|npm_execpath|npm_command|REFACTOR_*|BASH*|COLOR*|TERM_*|ITERM*|VSCODE_*) return 0 ;;
    CLAUDE_CODE_*|CLAUDE_PROJECT_DIR|CLAUDE_PLUGIN_*|CLAUDECODE) return 0 ;;   # Claude Code 자체 변수만(CLAUDE_API_KEY 는 가린다)
    NODE_OPTIONS|*_OPTS|*_FLAGS) return 0 ;;
  esac
  # Windows·Git Bash(MSYS) 기본 변수(ProgramData·PSModulePath 처럼 대소문자가 섞여 들어온다)
  shopt -s nocasematch
  case "$1" in
    USERDOMAIN*|LOGONSERVER|MSYSTEM*|MINGW*|ORIGINAL_*|SSH_ASKPASS|COMPUTERNAME|SESSIONNAME|PROCESSOR_*|ALLUSERSPROFILE|APPDATA|LOCALAPPDATA|PROGRAM*|COMMONPROGRAM*|SYSTEMROOT|SYSTEMDRIVE|WINDIR|HOMEDRIVE|HOMEPATH|PSMODULEPATH)
      shopt -u nocasematch; return 0 ;;
  esac
  shopt -u nocasematch
  return 1
}
secret_name() { [[ $1 =~ (KEY|SECRET|TOKEN|PASSWORD|PASSWD|PASS$|PWD$|PRIVATE|CREDENTIAL|AUTH|COOKIE|SESSION|SIGNING|SALT|WEBHOOK|DSN|BEARER|JWT) ]]; }
endpoint_name() { [[ $1 =~ (URL|URI|HOST|ENDPOINT|DSN|ADDR|SERVER|DOMAIN|ORIGIN|BACKEND|TARGET|WEBSITE|DATABASE|_DB$|^DB_|REDIS|MONGO|POSTGRES|MYSQL|SMTP|PROXY) ]]; }
service_name() { [[ $1 =~ (SUPABASE|TOSS|KAKAO|ALIMTALK|SOLAPI|ALIGO|NAVER|OPENAI|ANTHROPIC|GEMINI|GOOGLE|STRIPE|PORTONE|IAMPORT|NICEPAY|INICIS|AWS_|FIREBASE|SENTRY|SLACK|TWILIO|SENDGRID|MAILGUN|RESEND|VERCEL|NETLIFY|CLOUDFLARE|GITHUB|DISCORD|TELEGRAM) ]]; }
# 값이 가리키는 호스트들 → HOSTS(공백 구분, 쉼표 목록이면 전부), HOSTV(첫 호스트). 값이 비면 둘 다 빈 값
#   쉼표로 먼저 나누고(postgres://u:p@h1:5432,h2:5432/db), 조각마다 경로·쿼리를 먼저 자른 뒤 사용자 정보(@ 앞)를 뗀다
#   (https://운영/redirect?to=u@localhost 가 localhost 로 읽히지 않게)
host_of() {
  local rest="$1," p
  HOSTV=""; HOSTS=""
  while [ -n "$rest" ]; do
    p=${rest%%,*}; rest=${rest#*,}
    p=${p//[[:space:]]/}
    case "$p" in *://*) p=${p#*://} ;; esac
    p=${p%%[/?#]*}; p=${p##*@}
    case "$p" in \[*\]*) p=${p%%\]*}; p="${p}]" ;; *:*:*) ;; *:*) p=${p%%:*} ;; esac
    [ -z "$p" ] && continue
    HOSTS="$HOSTS$p "; [ -z "$HOSTV" ] && HOSTV=$p
  done
}
local_host() {
  case "$1" in localhost|0.0.0.0|\[::1\]|::1|host.docker.internal) return 0 ;; esac
  [[ $1 =~ ^127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]
}
all_local() { # 값의 호스트가 하나 이상이고 모두 로컬인가(host_of 를 부른 뒤)
  local h
  [ -n "$HOSTS" ] || return 1
  for h in $HOSTS; do local_host "$h" || return 1; done
  return 0
}
is_address() { case "$1" in *://*) return 0 ;; esac; looks_domain "$1"; }   # 주소(URL·도메인·IP) 모양인가
# 이름이 목록에 없어도 값 모양만으로 비밀값·접속 주소로 보는가(셸 변수용)
shape_secret() {
  case "$1" in *://*|sk_live*|sk-*|rk_live*|ghp_*|github_pat_*|xoxa-*|xoxb-*|xoxp-*|AKIA*|eyJ*) return 0 ;; esac
  [[ $1 =~ [0-9A-Fa-f]{32,} ]] && return 0
  case "$1" in /*|*//*) return 1 ;; esac
  [[ $1 =~ ^[A-Za-z0-9+/_-]{32,}=*$ ]] && [[ $1 =~ [0-9] ]] && [[ $1 =~ [A-Za-z] ]]
}
looks_domain() { # 도메인·IP 모양인가(버전 번호·파일 이름 확장자·모델 이름은 제외)
  local re_num='^[0-9]+(\.[0-9]+)*(:[0-9]+)?(/.*)?$' re_ip='^[0-9]{1,3}(\.[0-9]{1,3}){3}(:[0-9]+)?(/.*)?$'
  local re_dom='^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.(com|net|org|io|co|kr|dev|app|ai|jp|cn|me|info|biz|xyz|cloud|site|online|tech|store|shop|us|uk|de|fr|in|edu|gov|so|sh|to|tv|ly|gg|link|page|pro|asia|eu|nz|au|ca|br|vn|th|id|sg|tw|hk|my|ph|es|it|nl|se|no|fi|dk|ch|at|be|pl|ru|ua|tr|il|za|mx|ar|cl|pe|world|work|live|space|website|run|build|click|kim|seoul|busan|xn--[a-z0-9-]+)(:[0-9]+)?(/.*)?$'
  local re_ext='\.(json|ya?ml|csv|tsv|png|jpe?g|gif|svg|webp|txt|md|html?|css|js|mjs|cjs|ts|tsx|py|log|db|sqlite3?|toml|ini|xml|pdf|zip|gz|env|lock|sh)$'
  if [[ $1 =~ $re_num ]]; then [[ $1 =~ $re_ip ]]; return; fi
  [[ $1 =~ $re_dom ]] || return 1
  [[ $1 =~ $re_ext ]] && return 1
  return 0
}
# 결과: CL=keep(그대로) 또는 가짜 값
classify() { # $1 이름 $2 값
  local n=$1 v=$2
  CL=keep
  [ -z "$v" ] && return 0
  is_untouchable "$n" && return 0
  allowed_ok "$n" "$v" && return 0
  shopt -s nocasematch
  # 로컬 주소(쉼표 목록이면 모든 호스트가 로컬일 때만: ALLOWED_HOSTS=localhost,127.0.0.1)
  host_of "$v"
  if all_local; then shopt -u nocasematch; return 0; fi
  # 파이썬 모듈 경로 같은 설정(DJANGO_SETTINGS_MODULE=config.settings.local, FLASK_APP=app.main)
  if [[ $n =~ (_MODULE|_APP|_SETTINGS|_CLASS|_BACKEND|_ENGINE|_PATH|_FILE|_DIR)$ ]] && ! [[ $v == *://* ]] && ! secret_name "$n" && ! looks_domain "$v"; then shopt -u nocasematch; return 0; fi
  case "$v" in sk_test_*|pk_test_*|rk_test_*|whsec_test*) shopt -u nocasematch; return 0 ;; esac
  # test_ 로 시작하는 값은 이름이 키(비밀값)이고 주소가 아닐 때만 테스트 키로 본다(TOSS_CLIENT_KEY=test_ck_…)
  if [[ $v == test_* ]] && secret_name "$n" && ! endpoint_name "$n" && ! is_address "$v"; then shopt -u nocasematch; return 0; fi
  if ! secret_name "$n"; then
    case "$v" in true|false|yes|no|on|off|0|1|none|null) shopt -u nocasematch; return 0 ;; esac
  fi
  local strong=0
  if secret_name "$n" || endpoint_name "$n"; then strong=1; fi
  case "$v" in *://*|sk_live*|sk-*|rk_live*|live_*|eyj*|akia*|ghp_*|github_pat_*|xox?-*|aiza*|sb_secret_*|whsec_*|-----begin*) strong=1 ;; esac
  looks_domain "$v" && strong=1
  if [ "$strong" = 0 ]; then
    # 서비스 이름(SUPABASE_BUCKET, KAKAO_TEMPLATE_CODE 등)이나 평범한 이름: 짧은 값·문장·경로는 설정값으로 보고 그대로
    if [ "${#v}" -lt 24 ] || [[ $v =~ [[:space:]] ]]; then shopt -u nocasematch; return 0; fi
    case "$v" in /*|./*|../*|"~/"*) shopt -u nocasematch; return 0 ;; esac
  fi
  case "$v" in
    postgres://*|postgresql://*|postgres+*://*|postgresql+*://*) CL="postgresql://refactor:refactor@127.0.0.1:9/refactor" ;;
    mysql://*|mysql+*://*|mariadb://*) CL="mysql://refactor:refactor@127.0.0.1:9/refactor" ;;
    mongodb://*|mongodb+srv://*) CL="mongodb://127.0.0.1:9/refactor" ;;
    redis://*|rediss://*) CL="redis://127.0.0.1:9" ;;
    amqp://*|amqps://*) CL="amqp://127.0.0.1:9" ;;
    *://*) CL="http://127.0.0.1:9" ;;
    \{*) CL="{}" ;;
    *)
      if [[ $v =~ ^[0-9]{1,5}$ ]] && ! secret_name "$n"; then CL=keep
      elif looks_domain "$v"; then case "$v" in */*) CL="http://127.0.0.1:9" ;; *) CL="127.0.0.1" ;; esac
      elif [[ $n =~ (HOST|ADDR|SERVER|DOMAIN)$ ]]; then CL="127.0.0.1"
      elif [[ $n =~ (URL|URI|ENDPOINT|ORIGIN|BACKEND)$ ]]; then CL="http://127.0.0.1:9"
      else CL="refactor-dummy"
      fi ;;
  esac
  shopt -u nocasematch
}

names=(); dummies=(); kept=(); from_shell=(); skipped=0
swap_set=" "; keep_set=" "; file_set=" "
# 같은 이름이 여러 곳(.env 여러 파일·셸)에 있으면 값마다 따로 판정한다. 하나라도 운영 모양이면 가짜 값,
# 모든 출처가 그대로 둘 값일 때만 그대로 둔다(.env=로컬 + .env.local=운영 이면 가짜 값).
add_name() { # $1 이름 $2 값 $3 출처(file/shell)
  local n=$1 k
  [ "$3" = file ] && file_set="$file_set$n "
  classify "$n" "$2"
  case "$swap_set" in *" $n "*)   # 이미 가짜 값으로 바꾸기로 함
    if [ "$3" = shell ]; then case " ${from_shell[*]:-} " in *" $n "*) ;; *) from_shell+=("$n") ;; esac; fi
    return 0 ;;
  esac
  if [ "$CL" = keep ]; then
    case "$keep_set" in *" $n "*) ;; *) kept+=("$n"); keep_set="$keep_set$n " ;; esac
    return 0
  fi
  case "$keep_set" in *" $n "*)   # 앞 출처에서 그대로 두기로 했던 이름 → 목록에서 뺀다
    local rest=() ; for k in "${kept[@]}"; do [ "$k" = "$n" ] || rest+=("$k"); done
    kept=("${rest[@]}"); keep_set=${keep_set/ $n / } ;;
  esac
  names+=("$n"); dummies+=("$CL"); swap_set="$swap_set$n "
  [ "$3" = shell ] && from_shell+=("$n")
  return 0
}

re_kv='^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$'
re_odd='[a-z].*[A-Z]|[A-Z].*[a-z]'
for f in "${files[@]}"; do
  cont=""; pem=0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    if [ "$pem" = 1 ]; then case "$line" in *-----END*) pem=0 ;; esac; continue; fi   # 따옴표 없는 여러 줄 키는 건너뜀
    if [ -n "$cont" ]; then   # 여러 줄에 걸친 따옴표 값은 닫는 따옴표까지 건너뛴다
      case "$line" in *"$cont") cont="" ;; esac
      continue
    fi
    case "$line" in -----BEGIN*) pem=1; continue ;; esac
    [[ $line =~ $re_kv ]] || continue
    n=${BASH_REMATCH[2]}; v=${BASH_REMATCH[3]}
    # 이름답지 않은 줄(키 조각 등)은 건너뛴다 — 이름으로도 출력하지 않는다
    if [ "${#n}" -gt 40 ] && [[ $n =~ $re_odd ]]; then skipped=$((skipped + 1)); continue; fi
    v=${v#"${v%%[![:space:]]*}"}
    case "$v" in
      \"*) v=${v#\"}; case "$v" in *\"*) v=${v%%\"*} ;; *) cont='"' ;; esac ;;
      \'*) v=${v#\'}; case "$v" in *\'*) v=${v%%\'*} ;; *) cont="'" ;; esac ;;
      *) v=${v%%[[:space:]]#*}; v=${v%"${v##*[![:space:]]}"} ;;
    esac
    add_name "$n" "$v" file
  done < "$f"
done
# 셸에 이미 들어 있는 비밀값·접속 주소 변수도 가린다(사용자 PC 설정의 운영 키 등)
#   이름은 대소문자를 가리지 않고 보고(database_url), 이름이 목록에 없어도 값 모양(주소·키 접두·긴 16진/base64)이면 판정한다.
#   .env 에 같은 이름이 있으면 셸 값도 따로 판정한다.
while IFS= read -r n; do
  [ -z "$n" ] && continue
  is_untouchable "$n" && continue
  v=${!n}
  hit=0
  case "$file_set" in *" $n "*) hit=1 ;; esac
  if [ "$hit" = 0 ]; then
    shopt -s nocasematch
    if secret_name "$n" || service_name "$n" || endpoint_name "$n"; then hit=1; fi
    shopt -u nocasematch
  fi
  [ "$hit" = 0 ] && shape_secret "$v" && hit=1
  [ "$hit" = 1 ] && add_name "$n" "$v" shell
done <<EOF
$(compgen -e)
EOF

join_names() { local out="" x; for x in "$@"; do out="${out:+$out, }$x"; done; printf '%s' "$out"; }

# ── --check: 이름만 보고서 ──────────────────────────────────────────────────
if [ "${1:-}" = "--check" ]; then
  {
    echo "== 안전 실행기 점검 (값은 출력하지 않습니다) =="
    echo "프로젝트 폴더: $root"
    if [ "${#files[@]}" -eq 0 ]; then echo "설정 파일(.env 등): 없음"
    else
      printf '설정 파일: '; first=1
      for f in "${files[@]}"; do [ "$first" = 1 ] || printf ', '; printf '%s' "${f#"$root"/}"; first=0; done; echo
    fi
    echo "가짜 값으로 바꿀 이름 (${#names[@]}개): $(join_names "${names[@]}")"
    [ "${#from_shell[@]}" -gt 0 ] && echo "  └ 그중 셸 환경에 이미 있던 이름: $(join_names "${from_shell[@]}")"
    echo "그대로 둘 이름 (${#kept[@]}개 — 빈 값·로컬 주소·테스트 키·숫자·짧은 설정값·경로·사람이 허용한 이름): $(join_names "${kept[@]}")"
    [ "$skipped" -gt 0 ] && echo "(이름 모양이 아닌 줄 ${skipped}개는 건너뜀 — 여러 줄 키 조각일 수 있음)"
    if [ "$allowed" != " " ]; then
      echo "사람이 개발용이라고 허용한 이름(docs/refactor/.allow-env) — 지금 값의 호스트(개발용인지 확인하세요):"
      for f in "${files[@]}"; do
        while IFS= read -r line || [ -n "$line" ]; do
          line=${line%$'\r'}
          [[ $line =~ $re_kv ]] || continue
          n=${BASH_REMATCH[2]}; v=${BASH_REMATCH[3]}; v=${v#\"}; v=${v#\'}; v=${v%%[\"\' ]*}
          case "$allowed" in *" $n "*)
            # 값은 어떤 경우에도 출력하지 않는다: 주소 모양(:// 또는 도메인·IP)일 때만 호스트를 보여 준다
            hv=""
            if is_address "$v"; then host_of "$v"; hv=${HOSTS% }; hv=${hv// /, }; fi
            if allowed_ok "$n" "$v"; then echo "   $n → ${hv:-(주소 아님)}"
            else
              case "$allow_hosts" in *"$n="*) echo "   $n → ${hv:-(주소 아님)}  ⚠️ 적어 둔 호스트와 달라 가짜 값으로 바꿈" ;;
                *) echo "   $n → ${hv:-(주소 아님)}  ⚠️ 주소 값은 호스트를 함께 적어야 그대로 둡니다: $n=${hv%%,*}" ;; esac
            fi ;;
          esac
        done < "$f"
      done
      case "$allow_hosts" in "") echo "   (이름=호스트 로 적어 두면, 나중에 값이 운영 주소로 바뀌었을 때 자동으로 다시 가립니다)" ;; esac
    fi
    # 가짜 값이 무시될 수 있는 코드 흔적(파일 이름만) — 파일마다 프로그램을 띄우지 않게 한 번에 검사
    hits=$(find "$root" \( -name node_modules -o -name .git -o -name .next -o -name dist -o -name build -o -name .venv -o -name venv -o -name vendor -o -name coverage \) -prune -o -type f \( -name '*.js' -o -name '*.mjs' -o -name '*.cjs' -o -name '*.ts' -o -name '*.tsx' -o -name '*.py' \) -print 2>/dev/null | head -n 5000 \
      | tr '\n' '\000' | xargs -0 grep -lE 'override[[:space:]]*[:=][[:space:]]*(true|True)|dotenv_values|readFileSync\([^)]*\.env|open\([^)]*\.env|DOTENV_CONFIG_OVERRIDE' 2>/dev/null | head -n 10)
    if [ -n "$hits" ]; then
      echo "⚠️ 코드가 .env를 직접 읽거나 덮어쓰는 흔적 — 이 파일들에서는 가짜 값이 무시될 수 있습니다(실행 전 사람 확인):"
      printf '%s\n' "$hits" | sed "s#^$root/#   - #"
    fi
    for f in "${files[@]}"; do case "${f##*/}" in .dev.vars*) echo "⚠️ ${f#"$root"/}: Cloudflare(wrangler)가 직접 읽어 가짜 값이 적용되지 않습니다." ;; esac; done
    for dd in "${dirs[@]}"; do
      for f in "$dd"/wrangler.toml "$dd"/wrangler.json "$dd"/wrangler.jsonc; do
        [ -f "$f" ] && echo "⚠️ ${f#"$root"/}: Cloudflare(wrangler)는 같은 폴더의 .dev.vars·.env 를 직접 읽습니다 — 가짜 값이 적용되지 않으니 개발용 값인지 사람이 확인하세요." && break
      done
      [ -f "$dd/supabase/functions/.env" ] && { sp="$dd/supabase/functions/.env"; echo "⚠️ ${sp#"$root"/}: Supabase 함수가 직접 읽어 가짜 값이 적용되지 않습니다."; }
      for f in "$dd"/docker-compose.yml "$dd"/docker-compose.yaml "$dd"/docker-compose.*.yml "$dd"/docker-compose.*.yaml "$dd"/compose.yml "$dd"/compose.yaml "$dd"/compose.*.yml "$dd"/compose.*.yaml; do
        [ -f "$f" ] && echo "⚠️ ${f#"$root"/}: docker compose 의 env_file 은 가짜 값이 적용되지 않습니다 — 컨테이너로 테스트하면 사람이 설정을 확인하세요." && break
      done
    done
    others=""
    for dd in "${dirs[@]}"; do
      for f in "$dd"/secrets.toml "$dd"/config.ini "$dd"/settings.ini "$dd"/token.json "$dd"/token.pickle "$dd"/credentials.json "$dd"/client_secret*.json "$dd"/*service*account*.json "$dd"/application_default_credentials.json "$dd"/storage_state.json; do
        [ -f "$f" ] && others="$others ${f#"$root"/}"
      done
    done
    [ -n "$others" ] && echo "⚠️ .env 가 아닌 설정·자격 증명 파일(값은 가려지지 않음 — 코드가 직접 읽음):$others"
    echo "알아 둘 것: 코드에 직접 적힌 키·주소와 실제 네트워크 요청(수집 대상 사이트 등)은 가려지지 않습니다."
    echo "권장: 👤 개발용 DB·테스트 키를 따로 두세요. 개발용으로 확인한 이름은 사람이 docs/refactor/.allow-env 에 한 줄씩 적으면 그대로 둡니다."
  } >&2
  exit 0
fi

if [ "${1:-}" != "--" ] || [ "$#" -lt 2 ]; then
  say "사용법: bash <플러그인>/hooks/run.sh refactor-safe-run -- <명령…>   ·   점검: … refactor-safe-run --check"
  exit 64
fi
shift

i=0
while [ "$i" -lt "${#names[@]}" ]; do
  export "${names[$i]}=${dummies[$i]}"
  i=$((i + 1))
done
export REFACTOR_SAFE_RUN=1
kept_allowed=""
for n in $allowed; do case " ${names[*]:-} " in *" $n "*) ;; *) kept_allowed="$kept_allowed $n" ;; esac; done
[ -n "$kept_allowed" ] && say "[refactor 안전 실행] 사람이 개발용으로 허용해 그대로 둔 이름(docs/refactor/.allow-env):$kept_allowed"
if [ "${#names[@]}" -gt 0 ]; then
  shown=("${names[@]:0:12}")
  more=""; [ "${#names[@]}" -gt 12 ] && more=" 외 $(( ${#names[@]} - 12 ))개"
  say "[refactor 안전 실행] 운영일 수 있는 설정 ${#names[@]}개를 가짜 값으로 바꿔 실행합니다(값은 출력하지 않음): $(join_names "${shown[@]}")$more"
else
  say "[refactor 안전 실행] 가짜 값으로 바꿀 설정이 없습니다(설정 파일·비밀값 이름의 환경변수 없음)."
fi
case " $* " in *" build"*|*":build"*|*" export "*) say "[refactor 안전 실행] 이 빌드 결과(.next·dist 등)에는 가짜 값이 들어 있습니다 — 배포에 쓰지 말고, 배포 전에는 평소 방법으로 다시 빌드하세요." ;; esac
exec "$@"
