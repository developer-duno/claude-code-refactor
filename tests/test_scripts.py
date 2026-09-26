#!/usr/bin/env python3
"""승인·현황·안전 실행기 스크립트 시험 (run.sh 경유).

실행:  python3 tests/test_scripts.py
옵션:  GUARD_BASH=/path/to/bash, GUARD_PATH_PREFIX=/dir  (test_guard.py 와 같음)
"""
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
RUN = (ROOT / "plugins/refactor/hooks/run.sh").as_posix()


def _default_bash():
    """Windows: PATH의 bash(WSL의 System32\\bash.exe일 수 있음) 대신 Git Bash 절대경로를 우선 찾는다."""
    if os.name != "nt":
        return "bash"
    for cand in [
        os.path.expandvars(r"%ProgramFiles%\Git\usr\bin\bash.exe"),
        os.path.expandvars(r"%ProgramFiles%\Git\bin\bash.exe"),
        os.path.expandvars(r"%LOCALAPPDATA%\Programs\Git\usr\bin\bash.exe"),
        os.path.expandvars(r"%LOCALAPPDATA%\Programs\Git\bin\bash.exe"),
    ]:
        if os.path.isfile(cand):
            return cand
    return "bash"


BASH = os.environ.get("GUARD_BASH") or _default_bash()
PATH_PREFIX = os.environ.get("GUARD_PATH_PREFIX", "")


def lf(path, text):
    """LF 줄바꿈으로 고정해 쓴다(Windows에서 write_text의 기본 CRLF 변환을 막는다)."""
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)

PLAN = """# 계획서

승인하면 `- **승인**: [x] 승인`으로 바뀝니다(설명 문장).

```
### [P9-9] 예시 카드(코드 블록 안)
- **승인**: [ ] 승인
```

~~~
### [P8-8] 물결 코드 블록 안
- **승인**: [ ] 승인
~~~

### [P1-1] 결제 금액 확인
- **종류**: 🔧 리팩토링
- **무엇을**: 토스 **승인** 요청 전에 금액을 서버에서 다시 계산
- **위험도**: 🟠 보통
- **👤 사람이 직접 할 일**: 결제사 테스트 키 발급
- **승인**: [ ] 승인
- **완료**: [ ] 완료

### [P1-2] 알림 문구 정리
- **종류**: 🔧 리팩토링
- **승인**: [ ] 승인
- **완료**: [ ] 완료

### [P1-3] 끝난 단계
- **승인**: [ ] 승인
- **완료**: [x] 완료

### [P2-1] 둘째 묶음
- **승인**: [ ] 승인
- **완료**: [ ] 완료
"""

BASELINE = """# 기준선

> 승인 방법: 사용자가 승인하면 아래 줄이 `기준선 계획 승인: [x]` 로 바뀝니다.

| ID | 무엇을 고정 |
|---|---|
| BL-001 | 배송비 계산 |

기준선 계획 승인: [ ]
껍데기 확인: 포함
"""

STATE = "---\nrefactor_state: 1\nphase: PLAN\ngate: G2-plan\nsteps_total: 0\nsteps_approved: 0\nsteps_done: 0\nnext: \"x\"\nupdated: 2026-09-01\n---\n"


def env():
    e = dict(os.environ)
    if PATH_PREFIX:
        e["PATH"] = PATH_PREFIX + os.pathsep + e["PATH"]
    return e


def sh(script, proj, stdin="", args=()):
    r = subprocess.run([BASH, str(RUN), script, str(proj), *args], input=stdin.encode("utf-8"),
                       capture_output=True, env=env(), timeout=60)
    return r.stdout.decode("utf-8", "replace") + r.stderr.decode("utf-8", "replace")


def approve(proj, args, sess="t", table=True, age=0):
    """사람이 /refactor:approve <인자> 를 입력한 것처럼: 입력 훅이 남기는 1회용 승인 표를 써 주고 승인 스크립트를 실행한다."""
    if table:
        lf(pathlib.Path(proj) / "docs/refactor" / f".turn.{sess}", f"approve {sess} {int(time.time()) - age}\n")
    return sh("refactor-approve", proj, args, args=("--session", sess))


def approve_rc(proj, args, sess="t", table=True, age=0):
    """approve() 와 같되 (출력, 종료 코드)를 돌려준다."""
    if table:
        lf(pathlib.Path(proj) / "docs/refactor" / f".turn.{sess}", f"approve {sess} {int(time.time()) - age}\n")
    r = subprocess.run([BASH, str(RUN), "refactor-approve", str(proj), "--session", sess], input=args.encode("utf-8"),
                       capture_output=True, env=env(), timeout=60)
    return r.stdout.decode("utf-8", "replace") + r.stderr.decode("utf-8", "replace"), r.returncode


def hook(name, proj, payload, extra_env=None):
    """훅(turn·post-check·session-start)을 CLAUDE_PROJECT_DIR=proj 로 실행 → (stdout, stderr, 종료 코드, 걸린 초)."""
    e = env()
    e["CLAUDE_PROJECT_DIR"] = str(proj)
    if extra_env:
        e.update(extra_env)
    data = payload if isinstance(payload, bytes) else json.dumps(payload, ensure_ascii=False).encode("utf-8")
    t0 = time.perf_counter()
    r = subprocess.run([BASH, str(RUN), name], input=data, capture_output=True, env=e, timeout=60)
    return r.stdout.decode("utf-8", "replace"), r.stderr.decode("utf-8", "replace"), r.returncode, time.perf_counter() - t0


def safe_run(proj, script, extra_env=None, check=False):
    """안전 실행기로 bash -c <script> 실행(또는 --check) → stdout+stderr(check) / stdout(실행)."""
    e = env()
    if extra_env:
        e.update(extra_env)
    argv = [BASH, str(RUN), "refactor-safe-run"] + (["--check"] if check else ["--", BASH, "-c", script])
    r = subprocess.run(argv, capture_output=True, env=e, cwd=str(proj), timeout=60)
    return r.stdout.decode("utf-8", "replace") + (r.stderr.decode("utf-8", "replace") if check else "")


def project(plan=PLAN, baseline=BASELINE):
    d = pathlib.Path(tempfile.mkdtemp(prefix="scripttest-"))
    (d / "docs/refactor").mkdir(parents=True)
    lf((d / "docs/refactor/REFACTOR_PLAN.md"), plan)
    lf((d / "docs/refactor/BASELINE.md"), baseline)
    lf((d / "docs/refactor/STATE.md"), STATE)
    return d


def main():
    if hasattr(sys.stdout, "reconfigure"):   # Windows 콘솔(cp949)에서 실패 내용 출력이 인코딩 오류로 죽지 않게
        sys.stdout.reconfigure(errors="replace")
    fails, total = [], 0

    def check(label, cond, detail=""):
        nonlocal total
        total += 1
        if not cond:
            fails.append((label, detail[:600]))

    # 1) 승인: 문장 중간의 **승인** 은 건드리지 않고, 코드 블록 속 예시 카드는 무시, 기록에 지문을 남긴다
    d = project()
    out = approve(d, "P1-1")
    plan = (d / "docs/refactor/REFACTOR_PLAN.md").read_text(encoding="utf-8")
    log = (d / "docs/refactor/APPROVALS.log").read_text(encoding="utf-8")
    check("승인: 카드 설명 줄 보존", "- **무엇을**: 토스 **승인** 요청 전에 금액을 서버에서 다시 계산" in plan, plan)
    check("승인: 표준 승인 줄", plan.count("**승인**: [x] 승인 (") == 1, plan)
    check("승인: 기록에 지문", "| 승인 | P1-1 | card=" in log, log)
    check("승인: 사람 할 일 안내", "결제사 테스트 키 발급" in out, out)
    check("승인: 예시 카드 무시", "P9-9" not in out and "P8-8" not in out, out)
    st = sh("refactor-status", d)
    check("현황: 실행 대기에 P1-1", "▶ 실행 대기" in st and "[P1-1]" in st.split("▶ 실행 대기")[1].split("\n  ")[1], st)

    # 2) 승인 뒤 카드가 바뀌면 실행 대기에서 빠진다
    p = d / "docs/refactor/REFACTOR_PLAN.md"
    lf(p, p.read_text(encoding="utf-8").replace("다시 계산", "다시 계산하고 로그도 남김"))
    st = sh("refactor-status", d)
    check("현황: 카드 바뀜", "🔁 승인 뒤 카드 내용이 바뀜" in st and "▶ 실행 대기" not in st, st)
    out = approve(d, "P1-1")
    check("재승인", "다시 승인" in out and "▶ 실행 대기(승인됨): P1-1" in out, out)

    # 3) 계획서 글자만 바꾼 체크 표시는 승인이 아니다
    lf(p, p.read_text(encoding="utf-8").replace("### [P1-2] 알림 문구 정리\n- **종류**: 🔧 리팩토링\n- **승인**: [ ] 승인",
                                                      "### [P1-2] 알림 문구 정리\n- **종류**: 🔧 리팩토링\n- **승인**: [x] 승인"))
    st = sh("refactor-status", d)
    ready = st.split("▶ 실행 대기")[1].split("\n  ")[0] if "▶ 실행 대기" in st else ""
    check("현황: 기록 없는 체크 표시", "체크 표시만 있고 승인 기록이 없음" in st and "[P1-2]" not in ready, st)

    # 4) 묶음 승인은 완료 단계를 건너뛰고, '보류'가 중간에 섞이면 거절
    out = approve(d, "P1")
    check("묶음 승인", "승인함: [P1-2]" in out and "P1-3" not in out.split("📋")[0], out)
    before = (d / "docs/refactor/APPROVALS.log").read_text(encoding="utf-8")
    out = approve(d, "P1-1 보류 P1-2")
    check("보류 섞임 거절", "맨 앞에만" in out and before == (d / "docs/refactor/APPROVALS.log").read_text(encoding="utf-8"), out)
    out = approve(d, "보류 P1-2")
    st = sh("refactor-status", d)
    check("보류", "승인 취소함: [P1-2]" in out and "⏹ 보류" in st, out + st)
    # STATE 칸
    state = (d / "docs/refactor/STATE.md").read_text(encoding="utf-8")
    check("STATE 칸 갱신", "steps_approved: 1" in state and "steps_total: 4" in state and "steps_done: 1" in state, state)
    shutil.rmtree(d, ignore_errors=True)

    # 5) 같은 번호 카드는 승인 거절, 닫히지 않은 코드 블록은 경고만 하고 뒤 카드도 읽는다
    dup = PLAN + "\n### [P1-2] 번호가 겹친 카드\n- **승인**: [ ] 승인\n- **완료**: [ ] 완료\n"
    d = project(plan=dup.replace("### [P2-1] 둘째 묶음", "```\n미완성 코드 블록\n\n### [P2-1] 둘째 묶음"))
    out = approve(d, "P1-2 P2-1")
    check("같은 번호 거절", "같은 번호의 단계가 2개" in out and "| P1-2 |" not in (d / "docs/refactor/APPROVALS.log").read_text(encoding="utf-8"), out)
    check("닫히지 않은 코드 블록", "닫히지 않은 코드 블록" in out and "승인함: [P2-1]" in out, out)
    shutil.rmtree(d, ignore_errors=True)

    # 6) 기준선 계획: 설명 문장·표 속 글자는 승인 줄이 아니다. 승인은 기록으로, 계획이 바뀌면 다시 승인
    d = project()
    st = sh("refactor-status", d)
    check("기준선: 설명 문장은 승인 아님", "기준선 계획: 승인 대기" in st, st)
    out = approve(d, "baseline")
    base = (d / "docs/refactor/BASELINE.md").read_text(encoding="utf-8")
    check("기준선 승인", "기준선 계획을 승인했습니다" in out and "\n기준선 계획 승인: [x] (" in base
          and "`기준선 계획 승인: [x]` 로 바뀝니다" in base, out + base)
    check("기준선 기록", "| 승인 | BASELINE | plan=" in (d / "docs/refactor/APPROVALS.log").read_text(encoding="utf-8"))
    check("기준선 현황", "기준선 계획: 승인됨" in sh("refactor-status", d))
    bp = d / "docs/refactor/BASELINE.md"
    lf(bp, bp.read_text(encoding="utf-8").replace("| BL-001 | 배송비 계산 |", "| BL-001 | 배송비 계산 |\n| BL-002 | 결제 전체 |"))
    check("기준선 계획 바뀜", "승인 뒤 계획 내용이 바뀜" in sh("refactor-status", d))
    lf(bp, bp.read_text(encoding="utf-8") + "\n## 결과\n| BL-001 | 통과 |\n")
    out = approve(d, "baseline")
    lf(bp, bp.read_text(encoding="utf-8") + "| BL-002 | 통과 |\n")   # 승인 줄 아래 결과 추가는 괜찮다
    check("기준선: 승인 줄 아래 결과 추가", "기준선 계획: 승인됨" in sh("refactor-status", d))
    shutil.rmtree(d, ignore_errors=True)

    # 6-1) 기준선: 승인 줄 아래의 계획 내용(껍데기 확인 등)도 지문에 포함, '## 결과' 아래만 자유, 승인 줄이 둘이면 거절
    d = project()
    approve(d, "baseline")
    bp = d / "docs/refactor/BASELINE.md"
    lf(bp, bp.read_text(encoding="utf-8").replace("껍데기 확인: 포함", "껍데기 확인: 제외"))
    check("기준선: 승인 줄 아래 계획도 지문", "승인 뒤 계획 내용이 바뀜" in sh("refactor-status", d))
    approve(d, "baseline")
    lf(bp, bp.read_text(encoding="utf-8") + "\n## 결과\n| BL-001 | 통과 |\n")
    check("기준선: ## 결과 아래는 자유", "기준선 계획: 승인됨" in sh("refactor-status", d))
    shutil.rmtree(d, ignore_errors=True)
    d = project(baseline=BASELINE.replace("# 기준선\n", "# 기준선\n- 기준선 계획 승인: [ ] ← /refactor:approve baseline\n"))
    out = approve(d, "baseline")
    check("기준선: 승인 줄 둘이면 거절", "여러 개" in out and not (d / "docs/refactor/APPROVALS.log").exists(), out)
    shutil.rmtree(d, ignore_errors=True)

    # 6-2) 카드 지문 범위: #### 작은 제목 아래, 승인 줄에 덧붙인 글, 쌍점 없는 **승인** 줄도 카드 내용이다
    d = project()
    approve(d, "P1-1 P1-2")
    p = d / "docs/refactor/REFACTOR_PLAN.md"
    base_plan = p.read_text(encoding="utf-8")
    for label, old_t, new_t, cid in [
        ("#### 아래", "- **완료**: [ ] 완료\n\n### [P1-2]", "- **완료**: [ ] 완료\n\n#### 참고\n범위: src/** 전체\n\n### [P1-2]", "P1-1"),
        ("승인 줄 덧붙임", "### [P1-2] 알림 문구 정리\n- **종류**: 🔧 리팩토링\n- **승인**: [x] 승인 (", "### [P1-2] 알림 문구 정리\n- **종류**: 🔧 리팩토링\n- **승인**: [x] 승인 — 범위: src 전체 (", "P1-2"),
        ("쌍점 없는 승인 줄", "- **👤 사람이 직접 할 일**: 결제사 테스트 키 발급\n", "- **👤 사람이 직접 할 일**: 결제사 테스트 키 발급\n- **승인** 범위 추가: src/admin.ts\n", "P1-1"),
    ]:
        assert old_t in base_plan, label
        lf(p, base_plan.replace(old_t, new_t, 1))
        st = sh("refactor-status", d)
        check(f"카드 지문: {label}", "🔁 승인 뒤 카드 내용이 바뀜" in st and f"[{cid}]" in st.split("🔁")[1][:400], st)
    # 바뀐 줄 보여 주기(승인 때 남긴 카드 내용과 비교)
    check("바뀐 줄 표시", "+ 지금:" in st and "src/admin.ts" in st, st)
    check("승인 때 카드 내용 보관", (d / "docs/refactor/approved/P1-1.md").exists())
    # 쌍점 없는 '**승인** 버튼…' 설명 줄은 승인 스크립트가 덮어쓰지 않는다
    assert "### [P2-1] 둘째 묶음\n" in base_plan
    lf(p, base_plan.replace("### [P2-1] 둘째 묶음\n", "### [P2-1] 둘째 묶음\n- **승인** 버튼을 누르면 결제 창이 열림\n"))
    out = approve(d, "P2-1")
    txt = p.read_text(encoding="utf-8")
    check("설명 줄 보존", "- **승인** 버튼을 누르면 결제 창이 열림" in txt and "승인함: [P2-1]" in out
          and txt.split("### [P2-1]")[1].count("**승인**: [x] 승인 (") == 1, out + txt)
    shutil.rmtree(d, ignore_errors=True)

    # 7) CRLF 계획서도 같은 지문(줄 끝 \r 무시)
    d = project(plan=PLAN.replace("\n", "\r\n"))
    out = approve(d, "P1-1")
    raw = (d / "docs/refactor/REFACTOR_PLAN.md").read_bytes()
    check("CRLF 유지", b"\r\n- **\xec\x8a\xb9\xec\x9d\xb8**: [x]" in raw or "승인함: [P1-1]" in out, out)
    check("CRLF 승인 현황", "▶ 실행 대기" in sh("refactor-status", d))
    shutil.rmtree(d, ignore_errors=True)

    # 8) 안전 실행기: 이름만 출력하고, 실행할 때는 가짜 값을 넣는다(값은 출력하지 않음)
    d = pathlib.Path(tempfile.mkdtemp(prefix="saferun-"))
    subprocess.run(["git", "init", "-q", str(d)], check=True)
    lf((d / ".env"), "DATABASE_URL=postgres://u:FAKEPW@db.example.com:5432/app\nSTRIPE_SECRET_KEY=sk_live_FAKEFAKE\n"
                            "TOSS_CLIENT_KEY=test_ck_FAKE\nPORT=3000\nSHOP_NAME=꽃배달\n")
    r = subprocess.run([BASH, str(RUN), "refactor-safe-run", "--check"], capture_output=True, env=env(), cwd=str(d), timeout=60)
    out = r.stdout.decode() + r.stderr.decode()
    check("안전 실행기 --check 이름만", "DATABASE_URL" in out and "STRIPE_SECRET_KEY" in out and "FAKE" not in out and "example.com" not in out, out)
    r = subprocess.run([BASH, str(RUN), "refactor-safe-run", "--", BASH, "-c",
                        'printf "%s|%s|%s|%s" "$DATABASE_URL" "$STRIPE_SECRET_KEY" "$TOSS_CLIENT_KEY" "${PORT:-none}"'],
                       capture_output=True, env=env(), cwd=str(d), timeout=60)
    got = r.stdout.decode()
    check("안전 실행기 가짜 값", got == "postgresql://refactor:refactor@127.0.0.1:9/refactor|refactor-dummy||none", got + r.stderr.decode())
    shutil.rmtree(d, ignore_errors=True)

    # 8-1) 분류 보강: SSH_·GIT_ 토큰·NPM_TOKEN·도메인 값은 가리고, 버전·모델 이름·버킷 이름·허용 목록은 그대로. 키 조각은 이름으로도 안 찍음
    d = pathlib.Path(tempfile.mkdtemp(prefix="saferun2-"))
    subprocess.run(["git", "init", "-q", str(d)], check=True)
    (d / "docs/refactor").mkdir(parents=True)
    lf((d / "docs/refactor/.allow-env"), "DEV_SUPABASE_URL=devproj.supabase.co\n")
    (d / "pkg/api/config").mkdir(parents=True)
    lf((d / "pkg/api/config/.env"), "DEEP_SECRET_KEY=FAKEdeep\n")
    lf((d / ".env"), 
        "SSH_PASSWORD=FAKEpw123\nGIT_TOKEN=ghp_FAKEFAKEFAKE\nNPM_TOKEN=npm_FAKEFAKE\nBACKEND=api.myflowershop.co.kr\n"
        "DB_CONN=postgres://u:p@13.125.44.12:5432/prod?application_name=localhost\nAPP_VERSION=1.0.2\nOPENAI_MODEL=gpt-4.1-mini\n"
        "SUPABASE_BUCKET=photos\nDEV_SUPABASE_URL=https://devproj.supabase.co\n-----BEGIN PRIVATE KEY-----\n"
        "FAKEVALUE14abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ012345==\n-----END PRIVATE KEY-----\n")
    r = subprocess.run([BASH, str(RUN), "refactor-safe-run", "--check"], capture_output=True, env=env(), cwd=str(d), timeout=60)
    out = r.stdout.decode() + r.stderr.decode()
    bad = [w for w in ["FAKE", "13.125", "myflowershop", "ghp_", "abcdefghij", "prod"] if w in out]
    check("안전 실행기 --check 값 없음(허용한 이름의 호스트만 표시)", not bad and "DEV_SUPABASE_URL → devproj.supabase.co" in out, f"{bad} {out}")
    swap = out.split("가짜 값으로 바꿀 이름")[1].split("\n")[0] if "가짜 값으로 바꿀 이름" in out else ""
    keep = out.split("그대로 둘 이름")[1].split("\n")[0] if "그대로 둘 이름" in out else ""
    for n in ["SSH_PASSWORD", "GIT_TOKEN", "NPM_TOKEN", "BACKEND", "DB_CONN", "DEEP_SECRET_KEY"]:
        check(f"가림: {n}", n in swap, out)
    for n in ["APP_VERSION", "OPENAI_MODEL", "SUPABASE_BUCKET", "DEV_SUPABASE_URL"]:
        check(f"그대로: {n}", n in keep, out)
    r = subprocess.run([BASH, str(RUN), "refactor-safe-run", "--", BASH, "-c", "exit 3"], capture_output=True, env=env(), cwd=str(d), timeout=60)
    check("안전 실행기 종료 코드 그대로", r.returncode == 3, str(r.returncode))
    # 모듈 경로·로컬 호스트 목록은 그대로, 허용 목록의 호스트가 바뀌면 다시 가림
    lf((d / ".env"), "DJANGO_SETTINGS_MODULE=config.settings.local\nFLASK_APP=app.main\nALLOWED_HOSTS=localhost,127.0.0.1\n"
                            "API_BACKEND=api.myshop.co.kr\nDATABASE_URL=postgres://u:p@db.prodref.supabase.co:5432/postgres\n")
    lf((d / "docs/refactor/.allow-env"), "DATABASE_URL=db.devproj.supabase.co\n")
    r = subprocess.run([BASH, str(RUN), "refactor-safe-run", "--", BASH, "-c",
                        'printf "%s|%s|%s|%s|%s" "${DJANGO_SETTINGS_MODULE:-keep}" "${FLASK_APP:-keep}" "${ALLOWED_HOSTS:-keep}" "${API_BACKEND:-keep}" "${DATABASE_URL:-keep}"'],
                       capture_output=True, env=env(), cwd=str(d), timeout=60)
    check("모듈 경로·로컬 목록 그대로, 호스트 바뀐 허용 이름은 가림", r.stdout.decode() == "keep|keep|keep|127.0.0.1|postgresql://refactor:refactor@127.0.0.1:9/refactor", r.stdout.decode())
    # 이름만 적은 허용: 주소 값은 가리고(호스트를 함께 적어야 함), 키 값은 그대로
    lf((d / ".env"), "NEXT_PUBLIC_SUPABASE_URL=https://prodref.supabase.co\nSUPABASE_ANON_KEY=eyJFAKEFAKE.FAKE.FAKE\n")
    lf((d / "docs/refactor/.allow-env"), "NEXT_PUBLIC_SUPABASE_URL\nSUPABASE_ANON_KEY\n")
    r = subprocess.run([BASH, str(RUN), "refactor-safe-run", "--", BASH, "-c", 'printf "%s|%s" "${NEXT_PUBLIC_SUPABASE_URL:-keep}" "${SUPABASE_ANON_KEY:-keep}"'],
                       capture_output=True, env=env(), cwd=str(d), timeout=60)
    check("이름만 허용: 주소는 가림·키는 그대로", r.stdout.decode() == "http://127.0.0.1:9|keep", r.stdout.decode())
    shutil.rmtree(d, ignore_errors=True)

    # 9) 승인 기록 봉인: /refactor:approve 밖에서 기록이 바뀌면 실행 대기를 비우고, '확인' 뒤에 다시 인정
    d = project()
    approve(d, "P1-1")
    log = d / "docs/refactor/APPROVALS.log"
    with open(log, "a", encoding="utf-8") as fh:
        fh.write("2026-09-26 10:00 KST | 승인 | P1-2 | card=1.2 | 사용자가 /refactor:approve 로 실행\n")
    st = sh("refactor-status", d)
    check("봉인 깨짐: 실행 대기 비움", "⛔ 승인 기록" in st and "▶ 실행 대기" not in st, st)
    check("봉인 깨짐: 달라진 줄 표시", "+ 더해진 줄:" in st and "P1-2" in st, st)
    out = approve(d, "P1-2")
    check("봉인 깨짐: 승인 거절", "처리하지 않았습니다" in out, out)
    out = approve(d, "확인")
    st = sh("refactor-status", d)
    check("확인 뒤 다시 인정", "봉인했습니다" in out and "▶ 실행 대기" in st and "[P1-1]" in st, out + st)
    # 10) 마무리: 실행 대기가 있으면 거절, 없으면 DONE 기록 + STATE DONE
    out = approve(d, "마무리")
    check("마무리 거절(실행 대기 있음)", "아직 실행 대기" in out, out)
    approve(d, "보류 P1-1")
    out = approve(d, "마무리")
    state = (d / "docs/refactor/STATE.md").read_text(encoding="utf-8")
    check("마무리", "마무리했습니다" in out and "phase: DONE" in state and "| 마무리 | PROJECT |" in log.read_text(encoding="utf-8"), out + state)
    check("마무리 현황", "마무리됨(DONE, 사용자 확인)" in sh("refactor-status", d))
    shutil.rmtree(d, ignore_errors=True)

    # 10-1) 이전 버전 프로젝트(봉인 없는 기록): 따로 안내, 확인 한 번이면 끝
    d = project()
    lf((d / "docs/refactor/APPROVALS.log"), "2026-09-20 10:00 KST | 승인 | P1-1 P1-2 | 사용자가 /refactor:approve 로 실행\n")
    st = sh("refactor-status", d)
    check("봉인 없음 안내", "봉인이 없습니다" in st and "⛔" not in st, st)
    # 10-2) 현황표: 사용자 마무리 확인이 없는 DONE은 "완료"로 보이지 않는다
    lf((d / "docs/refactor/STATE.md"), STATE.replace("phase: PLAN", "phase: DONE"))
    r = subprocess.run([BASH, str(RUN), "refactor-board", str(d)], input=str(d).encode(), capture_output=True, env=env(), timeout=60)
    bout = r.stdout.decode()
    check("현황표: 마무리 확인 필요", "마무리 확인 필요" in bout and "✅ 완료" not in bout.split("상태 뜻")[0], bout)
    shutil.rmtree(d, ignore_errors=True)

    # 11) 기준선: 승인 줄보다 앞에 둔 '## 결과' 제목은 결과 구역이 아니다(계획이 지문에서 빠지지 않게)
    d = project(baseline=BASELINE.replace("# 기준선\n", "# 기준선\n\n## 결과\n(나중에 채움)\n"))
    approve(d, "baseline")
    bp = d / "docs/refactor/BASELINE.md"
    lf(bp, bp.read_text(encoding="utf-8").replace("배송비 계산", "배송비 계산과 결제 전체"))
    check("기준선: 앞쪽 결과 제목", "승인 뒤 계획 내용이 바뀜" in sh("refactor-status", d))
    shutil.rmtree(d, ignore_errors=True)

    # ── 0.2.1 회귀 케이스 ────────────────────────────────────────────────────
    PROD = "postgres://u:PRODPW@db.prodref.example.com:5432/app"
    DUMMY_PG = "postgresql://refactor:refactor@127.0.0.1:9/refactor"

    # 12) 안전 실행기: 같은 이름이 여러 출처에 있으면 하나라도 운영 모양이면 가짜 값(#1)
    d = pathlib.Path(tempfile.mkdtemp(prefix="saferun3-"))
    subprocess.run(["git", "init", "-q", str(d)], check=True)
    lf(d / ".env", "DATABASE_URL=postgres://u:p@localhost:5432/dev\n")
    lf(d / ".env.local", f"DATABASE_URL={PROD}\n")
    got = safe_run(d, 'printf %s "${DATABASE_URL:-keep}"')
    check("여러 출처: .env 로컬 + .env.local 운영 → 가짜 값", got == DUMMY_PG, got)
    out = safe_run(d, "", check=True)
    swap = out.split("가짜 값으로 바꿀 이름")[1].split("\n")[0] if "가짜 값으로 바꿀 이름" in out else ""
    keep = out.split("그대로 둘 이름")[1].split("\n")[0] if "그대로 둘 이름" in out else ""
    check("여러 출처: --check 목록 반영", "DATABASE_URL" in swap and "DATABASE_URL" not in keep and "PRODPW" not in out, out)
    (d / ".env.local").unlink()
    got = safe_run(d, 'printf %s "${DATABASE_URL:-keep}"', extra_env={"DATABASE_URL": PROD})
    check("여러 출처: .env 로컬 + 셸 운영 → 가짜 값", got == DUMMY_PG, got)
    got = safe_run(d, 'printf %s "${DATABASE_URL:-keep}"')
    check("여러 출처: 로컬만 → 그대로", got == "keep", got)
    (d / ".env").unlink()

    # 13) 셸 변수: 소문자 이름·값 모양·CLAUDE 예외 좁히기(#8), Windows 기본 변수·*_OPTS 예외(#24)
    got = safe_run(d, 'printf "%s|%s|%s|%s|%s" "$database_url" "$CLAUDE_API_KEY" "$CLAUDE_CODE_X" "$MYTHING" "$RANDHEX"', extra_env={
        "database_url": PROD, "CLAUDE_API_KEY": "sk-ant-FAKEFAKE", "CLAUDE_CODE_X": "https://keep.example.com/x",
        "MYTHING": "https://prod.example.com/x", "RANDHEX": "0123456789abcdef0123456789abcdef"})
    check("셸: 소문자·CLAUDE_API_KEY·값 모양은 가림, CLAUDE_CODE_* 는 그대로",
          got == f"{DUMMY_PG}|refactor-dummy|https://keep.example.com/x|http://127.0.0.1:9|refactor-dummy", got)
    got = safe_run(d, 'printf "%s|%s|%s|%s" "$NODE_OPTIONS" "$JAVA_OPTS" "$MSYSTEM_PREFIX" "$USERDOMAIN_ROAMINGPROFILE"', extra_env={
        "NODE_OPTIONS": "--require https://x.example.com/a.js", "JAVA_OPTS": "-Dx=https://y.example.com",
        "MSYSTEM_PREFIX": "https://z.example.com/mingw64", "USERDOMAIN_ROAMINGPROFILE": "https://w.example.com"})
    check("셸: NODE_OPTIONS·*_OPTS·Windows 기본 변수는 그대로",
          got == "--require https://x.example.com/a.js|-Dx=https://y.example.com|https://z.example.com/mingw64|https://w.example.com", got)

    # 14) 호스트 판정 빈틈(#8): 쉼표 목록의 모든 호스트, 경로·쿼리 먼저 자르기, 127. 은 IP, test_ 는 키 이름일 때만
    lf(d / ".env", "DATABASE_URL=postgres://u:p@localhost:5432,db.prodref.example.com:5432/app\n"
                   "API_URL=https://api.prodref.example.com/r?to=u@localhost\nAPI_HOST=127.evil.example.com\n"
                   "SMTP_HOST=test_mail\nTOSS_CLIENT_KEY=test_ck_FAKE\nREDIS_URL=redis://[::1]:6379\nHOSTS=localhost,127.0.0.1\n")
    got = safe_run(d, 'printf "%s|%s|%s|%s|%s|%s|%s" "${DATABASE_URL:-keep}" "${API_URL:-keep}" "${API_HOST:-keep}" "${SMTP_HOST:-keep}" "${TOSS_CLIENT_KEY:-keep}" "${REDIS_URL:-keep}" "${HOSTS:-keep}"')
    check("호스트 판정 빈틈", got == f"{DUMMY_PG}|http://127.0.0.1:9|127.0.0.1|127.0.0.1|keep|keep|keep", got)

    # 15) --check 는 어떤 경우에도 값을 출력하지 않는다: 허용한 키 이름은 (주소 아님)
    (d / "docs/refactor").mkdir(parents=True)
    lf(d / "docs/refactor/.allow-env", "OPENAI_API_KEY\nDEV_DB_URL=localhost\n")
    lf(d / ".env", "OPENAI_API_KEY=sk-FAKEsecret123\nDEV_DB_URL=postgres://u:PRODPW@localhost:5432/dev\n")
    out = safe_run(d, "", check=True)
    check("--check: 허용한 키 값 미출력", "OPENAI_API_KEY → (주소 아님)" in out and "FAKEsecret" not in out and "PRODPW" not in out
          and "DEV_DB_URL → localhost" in out, out)
    shutil.rmtree(d, ignore_errors=True)

    # 16) 승인 1회용 표(#4b): 표 없음·다른 세션·만료·재사용 → exit 3, 현황 보기는 표 없이
    d = project()
    out, rc = approve_rc(d, "P1-1", table=False)
    check("승인 표 없음 → exit 3", rc == 3 and "/refactor:approve 로 입력할 때만" in out and not (d / "docs/refactor/APPROVALS.log").exists(), f"{rc} {out}")
    lf(d / "docs/refactor/.turn.other", f"approve other {int(time.time())}\n")
    out, rc = approve_rc(d, "P1-1", table=False)
    check("승인 표: 다른 세션의 표 → exit 3", rc == 3, f"{rc} {out}")
    out, rc = approve_rc(d, "P1-1", age=700)
    check("승인 표: 10분 지남 → exit 3", rc == 3, f"{rc} {out}")
    lf(d / "docs/refactor/.turn.t", "go t\nready\n")
    out, rc = approve_rc(d, "", table=False)
    check("승인 표: 인자 없는 현황 보기는 표 없이", rc == 0 and "계획서 현황" in out, f"{rc} {out}")
    out, rc = approve_rc(d, "P1-1")
    check("승인 표: 쓰고 나면 지움(1회용)", rc == 0 and "승인함: [P1-1]" in out and not (d / "docs/refactor/.turn.t").exists(), f"{rc} {out}")
    out, rc = approve_rc(d, "보류 P1-1", table=False)
    check("승인 표: 재사용 불가", rc == 3, f"{rc} {out}")
    # 입력 훅이 표를 쓴다(사람이 친 /refactor:approve <인자>), 인자 없는 /refactor:approve 는 표를 쓰지 않는다
    hook("turn", d, {"session_id": "s9", "prompt": "/refactor:approve P1-2"})
    first = (d / "docs/refactor/.turn.s9").read_text(encoding="utf-8").split() if (d / "docs/refactor/.turn.s9").exists() else []
    check("turn.sh: 승인 표 쓰기", len(first) == 3 and first[:2] == ["approve", "s9"] and abs(int(first[2]) - time.time()) < 60, str(first))
    out = sh("refactor-approve", d, "P1-2", args=("--session", "s9"))
    check("turn.sh 표로 승인", "승인함: [P1-2]" in out, out)
    hook("turn", d, {"session_id": "s8", "prompt": "/refactor:approve"})
    check("turn.sh: 인자 없으면 표 없음", not (d / "docs/refactor/.turn.s8").exists())
    shutil.rmtree(d, ignore_errors=True)

    # 17) 세션별 표시 파일(#26): /refactor:go → .turn.<sid>·.turn-dirty.<sid>, 하루 지난 표시 파일은 지움
    d = project()
    old = d / "docs/refactor/.turn.stale"
    lf(old, "go stale\nready\n")
    two_days = time.time() - 2 * 86400
    os.utime(old, (two_days, two_days))
    hook("turn", d, {"session_id": "s1", "prompt": "/refactor:go"})
    t1 = d / "docs/refactor/.turn.s1"
    check("세션별 .turn", t1.exists() and t1.read_text(encoding="utf-8").startswith("go s1\nready")
          and (d / "docs/refactor/.turn-dirty.s1").exists() and not (d / "docs/refactor/.turn").exists())
    check("하루 지난 표시 파일 정리", not old.exists())
    hook("turn", d, {"session_id": "s2", "prompt": "/refactor:go"})
    check("두 세션 표시 공존", (d / "docs/refactor/.turn.s1").exists() and (d / "docs/refactor/.turn.s2").exists())
    shutil.rmtree(d, ignore_errors=True)

    # 18) 봉인 CRLF(#10): 기록이 CRLF 로 바뀌어도 ⛔ 아님, 옛 방식(원본 바이트) 봉인도 통과, .gitattributes 생성
    d = project()
    approve(d, "P1-1")
    lg = d / "docs/refactor/APPROVALS.log"
    lg.write_bytes(lg.read_bytes().replace(b"\n", b"\r\n"))
    st = sh("refactor-status", d)
    check("봉인: CRLF 로 바뀐 기록은 그대로", "⛔" not in st and "▶ 실행 대기" in st, st)
    ga = d / "docs/refactor/.gitattributes"
    check("봉인: .gitattributes", ga.exists() and ga.read_text(encoding="utf-8") == "* text eol=lf\n")
    legacy = subprocess.run([BASH, "-c", 'cksum < "$1" | awk \'{ print $1 "." $2 }\'', "x", lg.as_posix()], capture_output=True, env=env()).stdout
    (d / "docs/refactor/approved/.log-sum").write_bytes(legacy)
    st = sh("refactor-status", d)
    check("봉인: 옛 방식 봉인값도 통과", "⛔" not in st and "▶ 실행 대기" in st, st)
    with open(lg, "ab") as fh:
        fh.write("2026-09-26 10:00 KST | 승인 | P1-2 | card=1.2 | 사용자가 /refactor:approve 로 실행\r\n".encode("utf-8"))
    st = sh("refactor-status", d)
    check("봉인: CRLF 에서도 더한 줄은 잡음", "⛔" in st and st.count("+ 더해진 줄:") == 1, st)
    shutil.rmtree(d, ignore_errors=True)

    # 19) run.sh(#17): 없는 이름은 127 + 한 줄, 역슬래시 절대경로도 실행(Windows)
    r = subprocess.run([BASH, str(RUN), "no-such-script"], input=b"", capture_output=True, env=env(), timeout=60)
    check("run.sh: 없는 이름 127", r.returncode == 127 and "스크립트 없음: no-such-script" in r.stderr.decode("utf-8", "replace"), f"{r.returncode} {r.stderr!r}")
    r = subprocess.run([BASH, str(RUN), "../scripts/refactor-status"], input=b"", capture_output=True, env=env(), timeout=60)
    check("run.sh: 경로가 섞인 이름 127", r.returncode == 127, str(r.returncode))
    if os.name == "nt":
        d = project()
        r = subprocess.run([BASH, str(RUN).replace("/", "\\"), "refactor-status", str(d)], input=b"", capture_output=True, env=env(), timeout=60)
        check("run.sh: 역슬래시 경로", r.returncode == 0 and "진행 상황 요약칸" in r.stdout.decode("utf-8", "replace"), f"{r.returncode} {r.stderr!r}")
        shutil.rmtree(d, ignore_errors=True)
    tmpd = pathlib.Path(tempfile.mkdtemp(prefix="runsh2-"))
    shutil.copytree(ROOT / "plugins/refactor", tmpd / "refactor")
    (tmpd / "refactor/hooks/guard.sh").unlink()
    r = subprocess.run([BASH, (tmpd / "refactor/hooks/run.sh").as_posix(), "guard"], input=b"{}", capture_output=True, env=env(), timeout=60)
    check("run.sh: 훅 파일 없음 → 1(막지 않음)", r.returncode == 1, str(r.returncode))
    shutil.rmtree(tmpd, ignore_errors=True)

    # 20) 훅 조기 종료(#18): 보통 프로젝트에서는 입력을 (거의) 읽지 않고 끝난다(출력 0B·exit 0)
    #     시간 기준은 기계 부하에 흔들리므로, "입력 쪽을 닫지 않아도 끝나는가"로 판정한다(입력을 다 읽는 훅이면 여기서 멈춘다)
    d = pathlib.Path(tempfile.mkdtemp(prefix="plain-"))
    big = json.dumps({"session_id": "s1", "prompt": "x" * 1_000_000, "tool_response": "y"}).encode()
    e = env(); e["CLAUDE_PROJECT_DIR"] = str(d)
    for name in ["turn", "post-check", "session-start"]:
        so, se, rc, dt = hook(name, d, big)
        print(f"  성능 · 보통 프로젝트 {name} 1MB: {dt*1000:.0f}ms")
        p = subprocess.Popen([BASH, str(RUN), name], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=e)
        try:
            p.stdin.write(b'{"session_id":"s1","prompt":"' + b"x" * 8192)   # 닫지 않음(훅이 먼저 끝나면 쓰기가 실패해도 된다)
            p.stdin.flush()
        except OSError:
            pass
        try:
            p.wait(timeout=30)
            ended = True
        except subprocess.TimeoutExpired:
            p.kill(); p.wait(); ended = False
        o = p.stdout.read()
        try:
            p.stdin.close()
        except OSError:
            pass
        check(f"조기 종료: {name}", rc == 0 and so == "" and ended and p.returncode == 0 and o == b"", f"{rc} {dt:.2f}s ended={ended} {so!r} {se!r}")
    shutil.rmtree(d, ignore_errors=True)

    # 21) 보호 파일(#19): 한글 파일 이름을 그대로 알리고, 턴 시작 때 있던 사용자 변경이 사라지면 알린다
    d = project()
    (d / "tests/baseline").mkdir(parents=True)
    lf(d / "tests/baseline/한글 금액.test.ts", "a\n")
    lf(d / "tests/baseline/b.test.ts", "b\n")
    subprocess.run(["git", "init", "-q", str(d)], check=True)
    subprocess.run(["git", "-C", str(d), "-c", "user.email=t@example.com", "-c", "user.name=t", "add", "-A"], check=True, capture_output=True)
    subprocess.run(["git", "-C", str(d), "-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-qm", "i"], check=True, capture_output=True)
    lf(d / "tests/baseline/b.test.ts", "사용자가 고치던 중\n")
    hook("turn", d, {"session_id": "s1", "prompt": "/refactor:go"})
    lf(d / "tests/baseline/한글 금액.test.ts", "바뀜\n")
    _, se, rc, _ = hook("post-check", d, {"session_id": "s1", "tool_name": "Bash"})
    check("보호 파일: 한글 이름 그대로", rc == 2 and "한글 금액.test.ts" in se and "\\355" not in se and "b.test.ts" not in se, f"{rc} {se}")
    lf(d / "tests/baseline/한글 금액.test.ts", "a\n")
    lf(d / "tests/baseline/b.test.ts", "b\n")   # 사용자 작업이 되돌려짐
    _, se, rc, _ = hook("post-check", d, {"session_id": "s1", "tool_name": "Bash"})
    check("보호 파일: 사용자 변경이 사라짐도 알림", rc == 2 and "b.test.ts" in se and "사라졌" in se, f"{rc} {se}")
    _, se, rc, _ = hook("post-check", d, {"session_id": "other", "tool_name": "Bash"})
    check("보호 파일: 다른 세션은 자기 기준점만", rc == 0, f"{rc} {se}")
    shutil.rmtree(d, ignore_errors=True)
    # 큰 계획서의 카드 본문 읽기에서 awk 소음(print to standard output failed)이 나지 않는다(#25)
    #   (카드 목록이 파이프 버퍼보다 커야 드러나므로 3000장. 승인 전체를 돌리면 느려서 카드 본문 읽기만 직접 부른다)
    d = project(plan=PLAN + "".join(f"\n### [P5-{i}] 단계 {i}\n- **승인**: [ ] 승인\n- **완료**: [ ] 완료\n" for i in range(3000)))
    lib = (ROOT / "plugins/refactor/scripts/refactor-lib.sh").as_posix()
    r = subprocess.run([BASH, "-c", 'eval "$(tr -d \'\\r\' < "$1")"; rl_card_text "$2" P1-1', "x", lib,
                        (d / "docs/refactor/REFACTOR_PLAN.md").as_posix()], capture_output=True, env=env(), timeout=120)
    err = r.stderr.decode("utf-8", "replace")
    check("큰 계획서: awk 소음 없음", "결제 금액 확인" in r.stdout.decode("utf-8", "replace") and err == "", err[-300:])
    shutil.rmtree(d, ignore_errors=True)

    # 22) 다시 <단계>(#20): 승인 → /refactor:go 다시 → 같은 카드도 승인 대기
    d = project()
    approve(d, "P1-1")
    hook("turn", d, {"session_id": "s1", "prompt": "/refactor:go 다시 plan"})
    lines = (d / "docs/refactor/APPROVALS.log").read_text(encoding="utf-8").splitlines()
    check("재설정 줄", lines[-1].endswith(" KST | 재설정 | PLAN | 사용자가 /refactor:go 다시 로 입력"), lines[-1])
    st = sh("refactor-status", d)
    pend = st.split("⏸ 승인 대기:")[1] if "⏸ 승인 대기:" in st else ""
    check("재설정 뒤 옛 승인 무효", "▶ 실행 대기" not in st and "[P1-1]" in pend and "⛔" not in st, st)
    out = approve(d, "P1-1")
    check("재설정 뒤 다시 승인", "승인함: [P1-1]" in out and "▶ 실행 대기(승인됨): P1-1" in out, out)
    shutil.rmtree(d, ignore_errors=True)

    # 23) 현황표(#28): 실행 대기가 있으면 ▶(게이트가 G2-plan 이어도), 없고 승인 대기면 🙋
    d = project()
    def board_row():
        r = subprocess.run([BASH, str(RUN), "refactor-board", str(d)], input=str(d).encode(), capture_output=True, env=env(), timeout=60)
        return r.stdout.decode("utf-8", "replace").split("상태 뜻")[0]
    lf(d / "docs/refactor/STATE.md", STATE.replace("gate: G2-plan", "gate: none"))
    check("현황표: 승인 대기 → 🙋", "🙋 사장님 차례" in board_row())
    approve(d, "P1-1")
    lf(d / "docs/refactor/STATE.md", STATE)
    check("현황표: 실행 대기 → ▶", "▶ 다음 단계 가능" in board_row())
    shutil.rmtree(d, ignore_errors=True)

    for label, detail in fails:
        print(f"FAIL {label}\n      {detail}")
    print(f"\n{total - len(fails)}/{total} 통과 · bash={BASH}{' · PATH+' + PATH_PREFIX if PATH_PREFIX else ''}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
