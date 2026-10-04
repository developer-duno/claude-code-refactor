#!/usr/bin/env python3
"""승인·현황·안전 실행기 스크립트 시험 (run.sh 경유).

실행:  python3 tests/test_scripts.py
옵션:  GUARD_BASH=/path/to/bash, GUARD_PATH_PREFIX=/dir  (test_guard.py 와 같음)
"""
import atexit
import json
import os
import re
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
        return shutil.which("bash") or "bash"   # 절대경로 — 시험이 PATH 를 바꿔도(gh 빼기) bash 를 찾게
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


def _git_tools_path():
    """Windows: Git Bash(bash.exe)를 직접 부르면 스크립트 안에서 다시 부르는 bash·awk 가 Windows PATH 의
    System32\\bash.exe(WSL)로 갈 수 있다 → Git 의 usr\\bin·mingw64\\bin 을 PATH 앞에 둔다(Claude Code 가 훅을 부르는 Git Bash 환경과 같게)."""
    if os.name != "nt" or not os.path.isabs(BASH):
        return ""
    p = pathlib.Path(BASH).parent
    git = p.parent.parent if (p.name.lower() == "bin" and p.parent.name.lower() == "usr") else p.parent
    return os.pathsep.join(str(d) for d in (git / "usr" / "bin", git / "mingw64" / "bin") if d.is_dir())


GIT_TOOLS = _git_tools_path()
# 문제 기록(problems.log)은 시험용 임시 폴더에(실제 ~/.claude/plugins/data/refactor 를 더럽히지 않게) — 모든 서브프로세스에 준다
TEST_DATA = tempfile.mkdtemp(prefix="scriptsdata-")
atexit.register(shutil.rmtree, TEST_DATA, True)

# 훅(guard·turn·post-check·session-start) 호출의 시간 한도(test_guard.py 와 같음) — 넘기면 실패로 세고 계속. 훅이 아닌 스크립트 호출은 90초 그대로.
HOOK_TIMEOUT = 30
HOOK_TIMEOUTS = []


def run_hook(argv, watch_ok=False, **kw):
    """watch_ok: 감시(run.sh 가 느린 guard 를 끊음) 자체를 시험하는 호출만 True. 그 밖의 호출이 감시에 끊기면
    종료 코드가 기대(2)와 같아도 "훅 시간 초과"로 센다 — 느린 컴퓨터에서 "막혀야 함" 시험이 감시 차단으로 조용히 초록이 되지 않게."""
    try:
        r = subprocess.run(argv, timeout=HOOK_TIMEOUT, **kw)
    except subprocess.TimeoutExpired:
        HOOK_TIMEOUTS.append(" ".join(str(a) for a in argv[1:]))
        return subprocess.CompletedProcess(argv, 124, b"", f"[시험] 훅이 {HOOK_TIMEOUT}초 안에 끝나지 않음".encode("utf-8"))
    if not watch_ok and "판정이 너무 오래 걸려".encode("utf-8") in (r.stderr or b""):
        HOOK_TIMEOUTS.append("감시 차단: " + " ".join(str(a) for a in argv[1:]))
    return r


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
    # 0.3.0: 이 파일에서 guard 를 부르는 시험(감시·훅 파일 없음·문제 기록)은 전부 STATE 없는 자리에서 돈다 → 스위치를 켜 옛 뜻을 유지한다
    # (물려받은 CLAUDE_PROJECT_DIR 가 있어도 run.sh 빠른 길로 새지 않게). 문 자체의 시험은 test_guard.py 의 check_gate_030.
    e = dict(os.environ, CLAUDE_PLUGIN_DATA=TEST_DATA, REFACTOR_GUARD_ALWAYS="1")
    for pre in (GIT_TOOLS, PATH_PREFIX):   # 나중에 붙인 것이 맨 앞 — PATH_PREFIX 가 가장 앞
        if pre:
            e["PATH"] = pre + os.pathsep + e["PATH"]
    return e


def sh(script, proj, stdin="", args=()):
    r = subprocess.run([BASH, str(RUN), script, str(proj), *args], input=stdin.encode("utf-8"),
                       capture_output=True, env=env(), timeout=90)
    return r.stdout.decode("utf-8", "replace") + r.stderr.decode("utf-8", "replace")


def approve(proj, args):
    """사람이 /refactor:approve <인자> 를 입력한 것처럼: 입력 훅(turn.sh)이 부르는 대로 --from-hook 을 붙여 승인 스크립트를 실행한다."""
    return sh("refactor-approve", proj, args, args=("--from-hook",))


def approve_rc(proj, args, from_hook=True):
    """approve() 와 같되 (출력, 종료 코드)를 돌려준다. from_hook=False 면 스킬의 ! 명령처럼 --from-hook 없이 부른다."""
    r = subprocess.run([BASH, str(RUN), "refactor-approve", str(proj), *(("--from-hook",) if from_hook else ())],
                       input=args.encode("utf-8"), capture_output=True, env=env(), timeout=90)
    return r.stdout.decode("utf-8", "replace") + r.stderr.decode("utf-8", "replace"), r.returncode


def rdir_files(proj):
    """docs/refactor 아래 파일 내용 전부(입력 훅의 표시 파일 .turn* 은 빼고) — '아무것도 바꾸지 않음' 확인용."""
    base = pathlib.Path(proj) / "docs/refactor"
    return {p.relative_to(base).as_posix(): p.read_bytes() for p in sorted(base.rglob("*"))
            if p.is_file() and not p.name.startswith(".turn")}


def hook(name, proj, payload, extra_env=None):
    """훅(turn·post-check·session-start)을 CLAUDE_PROJECT_DIR=proj 로 실행 → (stdout, stderr, 종료 코드, 걸린 초)."""
    e = env()
    e["CLAUDE_PROJECT_DIR"] = str(proj)
    if extra_env:
        e.update(extra_env)
    data = payload if isinstance(payload, bytes) else json.dumps(payload, ensure_ascii=False).encode("utf-8")
    t0 = time.perf_counter()
    r = run_hook([BASH, str(RUN), name], input=data, capture_output=True, env=e)
    return r.stdout.decode("utf-8", "replace"), r.stderr.decode("utf-8", "replace"), r.returncode, time.perf_counter() - t0


def safe_run(proj, script, extra_env=None, check=False):
    """안전 실행기로 bash -c <script> 실행(또는 --check) → stdout+stderr(check) / stdout(실행)."""
    e = env()
    if extra_env:
        e.update(extra_env)
    argv = [BASH, str(RUN), "refactor-safe-run"] + (["--check"] if check else ["--", BASH, "-c", script])
    r = subprocess.run(argv, capture_output=True, env=e, cwd=str(proj), timeout=90)
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
    r = subprocess.run([BASH, str(RUN), "refactor-safe-run", "--check"], capture_output=True, env=env(), cwd=str(d), timeout=90)
    out = r.stdout.decode() + r.stderr.decode()
    check("안전 실행기 --check 이름만", "DATABASE_URL" in out and "STRIPE_SECRET_KEY" in out and "FAKE" not in out and "example.com" not in out, out)
    r = subprocess.run([BASH, str(RUN), "refactor-safe-run", "--", BASH, "-c",
                        'printf "%s|%s|%s|%s" "$DATABASE_URL" "$STRIPE_SECRET_KEY" "$TOSS_CLIENT_KEY" "${PORT:-none}"'],
                       capture_output=True, env=env(), cwd=str(d), timeout=90)
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
    r = subprocess.run([BASH, str(RUN), "refactor-safe-run", "--check"], capture_output=True, env=env(), cwd=str(d), timeout=90)
    out = r.stdout.decode() + r.stderr.decode()
    bad = [w for w in ["FAKE", "13.125", "myflowershop", "ghp_", "abcdefghij", "prod"] if w in out]
    check("안전 실행기 --check 값 없음(허용한 이름의 호스트만 표시)", not bad and "DEV_SUPABASE_URL → devproj.supabase.co" in out, f"{bad} {out}")
    swap = out.split("가짜 값으로 바꿀 이름")[1].split("\n")[0] if "가짜 값으로 바꿀 이름" in out else ""
    keep = out.split("그대로 둘 이름")[1].split("\n")[0] if "그대로 둘 이름" in out else ""
    for n in ["SSH_PASSWORD", "GIT_TOKEN", "NPM_TOKEN", "BACKEND", "DB_CONN", "DEEP_SECRET_KEY"]:
        check(f"가림: {n}", n in swap, out)
    for n in ["APP_VERSION", "OPENAI_MODEL", "SUPABASE_BUCKET", "DEV_SUPABASE_URL"]:
        check(f"그대로: {n}", n in keep, out)
    r = subprocess.run([BASH, str(RUN), "refactor-safe-run", "--", BASH, "-c", "exit 3"], capture_output=True, env=env(), cwd=str(d), timeout=90)
    check("안전 실행기 종료 코드 그대로", r.returncode == 3, str(r.returncode))
    # 모듈 경로·로컬 호스트 목록은 그대로, 허용 목록의 호스트가 바뀌면 다시 가림
    lf((d / ".env"), "DJANGO_SETTINGS_MODULE=config.settings.local\nFLASK_APP=app.main\nALLOWED_HOSTS=localhost,127.0.0.1\n"
                            "API_BACKEND=api.myshop.co.kr\nDATABASE_URL=postgres://u:p@db.prodref.supabase.co:5432/postgres\n")
    lf((d / "docs/refactor/.allow-env"), "DATABASE_URL=db.devproj.supabase.co\n")
    r = subprocess.run([BASH, str(RUN), "refactor-safe-run", "--", BASH, "-c",
                        'printf "%s|%s|%s|%s|%s" "${DJANGO_SETTINGS_MODULE:-keep}" "${FLASK_APP:-keep}" "${ALLOWED_HOSTS:-keep}" "${API_BACKEND:-keep}" "${DATABASE_URL:-keep}"'],
                       capture_output=True, env=env(), cwd=str(d), timeout=90)
    check("모듈 경로·로컬 목록 그대로, 호스트 바뀐 허용 이름은 가림", r.stdout.decode() == "keep|keep|keep|127.0.0.1|postgresql://refactor:refactor@127.0.0.1:9/refactor", r.stdout.decode())
    # 이름만 적은 허용: 주소 값은 가리고(호스트를 함께 적어야 함), 키 값은 그대로
    lf((d / ".env"), "NEXT_PUBLIC_SUPABASE_URL=https://prodref.supabase.co\nSUPABASE_ANON_KEY=eyJFAKEFAKE.FAKE.FAKE\n")
    lf((d / "docs/refactor/.allow-env"), "NEXT_PUBLIC_SUPABASE_URL\nSUPABASE_ANON_KEY\n")
    r = subprocess.run([BASH, str(RUN), "refactor-safe-run", "--", BASH, "-c", 'printf "%s|%s" "${NEXT_PUBLIC_SUPABASE_URL:-keep}" "${SUPABASE_ANON_KEY:-keep}"'],
                       capture_output=True, env=env(), cwd=str(d), timeout=90)
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
    r = subprocess.run([BASH, str(RUN), "refactor-board", str(d)], input=str(d).encode(), capture_output=True, env=env(), timeout=90)
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

    # 16) 승인은 입력 훅이 처리한다(스킬의 ! 명령은 훅보다 먼저 돌아 현황만): 훅 → --from-hook, 그 밖은 아무것도 안 바꿈·exit 0
    HEAD_ = "[Vibe Refactor 승인 처리 결과 — 입력 훅]"
    TAIL_ = "(이 블록이 승인의 실제 결과입니다."
    def up(sess, prompt, proj):
        return hook("turn", proj, {"session_id": sess, "hook_event_name": "UserPromptSubmit", "prompt": prompt, "cwd": str(proj)})
    d = project()
    so, se, rc, _ = up("s1", "/refactor:approve P1-1", d)
    log = d / "docs/refactor/APPROVALS.log"
    check("훅 승인: 기록 생성·결과 블록", rc == 0 and log.exists() and "| 승인 | P1-1 | card=" in log.read_text(encoding="utf-8")
          and so.startswith(HEAD_ + "\n") and "승인함: [P1-1]" in so and so.rstrip().splitlines()[-1].startswith(TAIL_), f"{rc} {so} {se}")
    before = rdir_files(d)
    so, se, rc, _ = up("s1", "/refactor:approve", d)
    check("훅: 인자 없으면 현황만(변경 없음)", rc == 0 and HEAD_ in so and "계획서 현황" in so and "사용법:" in so and rdir_files(d) == before, f"{rc} {so}")
    so, _, rc, _ = up("s1", "<command-name>/refactor:approve</command-name><command-args>P1-2</command-args>", d)
    check("훅: <command-name> 모양도 처리", rc == 0 and "승인함: [P1-2]" in so, so)
    so, _, rc, _ = up("s1", "/refactor:approve 보류 P1-2", d)
    check("훅: 보류", rc == 0 and "승인 취소함: [P1-2]" in so and "| 보류 | P1-2 |" in log.read_text(encoding="utf-8"), so)
    so, _, rc, _ = up("s1", "/refactor:approve baseline", d)
    check("훅: baseline", rc == 0 and "기준선 계획을 승인했습니다" in so and "| 승인 | BASELINE |" in log.read_text(encoding="utf-8"), so)
    so, _, rc, _ = up("s1", "/refactor:approve 확인", d)
    check("훅: 확인", rc == 0 and "이미 봉인과 일치" in so, so)
    so, _, rc, _ = up("s1", "/refactor:approve 보류 P1-1", d)
    so, _, rc, _ = up("s1", "/refactor:approve 마무리", d)
    check("훅: 마무리", rc == 0 and "마무리했습니다(DONE)" in so and "phase: DONE" in (d / "docs/refactor/STATE.md").read_text(encoding="utf-8"), so)
    # go 표시가 있던 세션에서 /refactor:approve 를 치면 go 표시는 지운다(다른 슬래시 명령과 같음)
    lf(d / "docs/refactor/.turn.s1", "go s1\nready\n")
    up("s1", "/refactor:approve", d)
    check("훅: approve 턴은 go 표시를 지움", not (d / "docs/refactor/.turn.s1").exists())
    shutil.rmtree(d, ignore_errors=True)
    # 스크립트: --from-hook 없이(스킬의 ! 명령·그 밖) 인자가 있어도 아무것도 바꾸지 않고 exit 0, 있으면 바꾼다
    d = project()
    before = rdir_files(d)
    for a in ["P1-1", "보류 P1-1", "baseline", "마무리", "확인", "P1"]:
        out, rc = approve_rc(d, a, from_hook=False)
        check(f"훅 밖({a}): 변경 없음·exit 0·안내", rc == 0 and rdir_files(d) == before and "입력 훅이 합니다" in out, f"{rc} {out}")
    out, rc = approve_rc(d, "", from_hook=False)
    check("훅 밖(인자 없음): 현황만·exit 0", rc == 0 and "계획서 현황" in out and "입력 훅이 합니다" not in out and rdir_files(d) == before, f"{rc} {out}")
    out, rc = approve_rc(d, "P1-1")
    check("--from-hook: 변경됨", rc == 0 and "승인함: [P1-1]" in out and (d / "docs/refactor/APPROVALS.log").exists(), f"{rc} {out}")
    shutil.rmtree(d, ignore_errors=True)
    # 훅은 어떤 경우에도 exit 0: 기록 폴더 없음(만들지 않음), 승인 스크립트 고장
    d = pathlib.Path(tempfile.mkdtemp(prefix="noref-"))
    so, se, rc, _ = up("s1", "/refactor:approve P1-1", d)
    check("훅: 기록 폴더 없으면 안내만", rc == 0 and HEAD_ in so and "docs/refactor)이 없습니다" in so and not (d / "docs").exists(), f"{rc} {so} {se}")
    shutil.rmtree(d, ignore_errors=True)
    d = project()
    tmpd = pathlib.Path(tempfile.mkdtemp(prefix="runsh3-"))
    shutil.copytree(ROOT / "plugins/refactor", tmpd / "refactor")
    lf(tmpd / "refactor/scripts/refactor-approve.sh", "#!/usr/bin/env bash\necho broken >&2\nexit 5\n")
    e = env(); e["CLAUDE_PROJECT_DIR"] = str(d)
    pl = json.dumps({"session_id": "s1", "hook_event_name": "UserPromptSubmit", "prompt": "/refactor:approve P1-1", "cwd": str(d)}).encode()
    r = run_hook([BASH, (tmpd / "refactor/hooks/run.sh").as_posix(), "turn"], input=pl, capture_output=True, env=e)
    so = r.stdout.decode("utf-8", "replace")
    check("훅: 승인 스크립트가 실패해도 exit 0", r.returncode == 0 and HEAD_ in so and "broken" in so, f"{r.returncode} {so}")
    shutil.rmtree(tmpd, ignore_errors=True)
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
    # 정리는 하루에 한 번만(.turn-sweep 에 오늘 날짜): 같은 날 다시 입력하면 찾지 않고, 날짜가 바뀌면 다시 정리
    lf(old, "go stale\nready\n")
    os.utime(old, (two_days, two_days))
    hook("turn", d, {"session_id": "s1", "prompt": "/refactor:go"})
    check("정리는 하루 한 번(같은 날은 건너뜀)", old.exists())
    lf(d / "docs/refactor/.turn-sweep", "19990101\n")
    hook("turn", d, {"session_id": "s1", "prompt": "/refactor:go"})
    check("정리는 하루 한 번(날짜가 바뀌면 다시)", not old.exists())
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
    # 입력 훅(turn.sh)은 승인 기록 지문을 자체 판으로 잰다 — 라이브러리 rl_log_sum 과 같아야 post-check 가 헛경보를 내지 않는다
    libsh = (ROOT / "plugins/refactor/scripts/refactor-lib.sh").as_posix()
    def lib_sum():
        return subprocess.run([BASH, "-c", 'LC_ALL=C; export LC_ALL; eval "$(tr -d \'\\r\' < "$1")"; rl_log_sum "$2"', "x", libsh, lg.as_posix()],
                              capture_output=True, env=env(), timeout=90).stdout.decode().strip()
    hook("turn", d, {"session_id": "s1", "prompt": "/refactor:go"})
    tt = (d / "docs/refactor/.turn.s1").read_text(encoding="utf-8")
    dirty = (d / "docs/refactor/.turn-dirty.s1").read_text(encoding="utf-8")
    check("turn.sh: CRLF 기록도 실행 대기·지문이 라이브러리와 같음", "ready P1-1" in tt and f"APPROVALS\t{lib_sum()}\n" in dirty, f"{tt} {dirty}")
    ga = d / "docs/refactor/.gitattributes"
    check("봉인: .gitattributes", ga.exists() and ga.read_text(encoding="utf-8") == "* text eol=lf\n")
    legacy = subprocess.run([BASH, "-c", 'cksum < "$1" | awk \'{ print $1 "." $2 }\'', "x", lg.as_posix()], capture_output=True, env=env()).stdout
    (d / "docs/refactor/approved/.log-sum").write_bytes(legacy)
    st = sh("refactor-status", d)
    check("봉인: 옛 방식 봉인값도 통과", "⛔" not in st and "▶ 실행 대기" in st, st)
    hook("turn", d, {"session_id": "s1", "prompt": "/refactor:go"})
    check("turn.sh: 옛 방식 봉인값도 실행 대기", "ready P1-1" in (d / "docs/refactor/.turn.s1").read_text(encoding="utf-8"))
    with open(lg, "ab") as fh:
        fh.write("2026-09-26 10:00 KST | 승인 | P1-2 | card=1.2 | 사용자가 /refactor:approve 로 실행\r\n".encode("utf-8"))
    st = sh("refactor-status", d)
    check("봉인: CRLF 에서도 더한 줄은 잡음", "⛔" in st and st.count("+ 더해진 줄:") == 1, st)
    shutil.rmtree(d, ignore_errors=True)

    # 19) run.sh(#17): 없는 이름은 127 + 한 줄, 역슬래시 절대경로도 실행(Windows)
    r = subprocess.run([BASH, str(RUN), "no-such-script"], input=b"", capture_output=True, env=env(), timeout=90)
    check("run.sh: 없는 이름 127", r.returncode == 127 and "스크립트 없음: no-such-script" in r.stderr.decode("utf-8", "replace"), f"{r.returncode} {r.stderr!r}")
    r = subprocess.run([BASH, str(RUN), "../scripts/refactor-status"], input=b"", capture_output=True, env=env(), timeout=90)
    check("run.sh: 경로가 섞인 이름 127", r.returncode == 127, str(r.returncode))
    if os.name == "nt":
        d = project()
        r = subprocess.run([BASH, str(RUN).replace("/", "\\"), "refactor-status", str(d)], input=b"", capture_output=True, env=env(), timeout=90)
        check("run.sh: 역슬래시 경로", r.returncode == 0 and "진행 상황 요약칸" in r.stdout.decode("utf-8", "replace"), f"{r.returncode} {r.stderr!r}")
        shutil.rmtree(d, ignore_errors=True)
    tmpd = pathlib.Path(tempfile.mkdtemp(prefix="runsh2-"))
    shutil.copytree(ROOT / "plugins/refactor", tmpd / "refactor")
    (tmpd / "refactor/hooks/guard.sh").unlink()
    e1 = env()
    e1["CLAUDE_PLUGIN_DATA"] = str(tmpd / "d")
    r = run_hook([BASH, (tmpd / "refactor/hooks/run.sh").as_posix(), "guard"], input=b"{}", capture_output=True, env=e1)
    check("run.sh: 훅 파일 없음 → 1(막지 않음)", r.returncode == 1, str(r.returncode))
    pl1 = (tmpd / "d/problems.log").read_text(encoding="utf-8") if (tmpd / "d/problems.log").exists() else ""
    check("run.sh: 훅 파일 없음 기록은 실제 종료 코드(exit 1)", pl1.rstrip().endswith(" | run.sh | guard exit 1 (파일 없음)"), pl1)
    # 같은 호출을 스위치 없이 + 빈 프로젝트 폴더로(빠른 길 조건이 참) — "파일 없음"이 빠른 길보다 먼저라 0 이 아니라 1 + 기록 한 줄
    (tmpd / "p").mkdir()
    e2 = env()
    e2.pop("REFACTOR_GUARD_ALWAYS", None)
    e2["CLAUDE_PLUGIN_DATA"] = str(tmpd / "d2")
    e2["CLAUDE_PROJECT_DIR"] = str(tmpd / "p")
    r = run_hook([BASH, (tmpd / "refactor/hooks/run.sh").as_posix(), "guard"], input=b"{}", capture_output=True, env=e2)
    pl2 = (tmpd / "d2/problems.log").read_text(encoding="utf-8") if (tmpd / "d2/problems.log").exists() else ""
    check("run.sh: 훅 파일 없음 → 1(스위치 없음·빈 프로젝트 폴더 — 빠른 길보다 먼저)",
          r.returncode == 1 and pl2.rstrip().endswith(" | run.sh | guard exit 1 (파일 없음)"), f"{r.returncode} {pl2!r}")

    # 19-2) bash 3.2 호환(README 약속): bash 4 이상 전용 문법이 훅·스크립트에 없는지(버전 확인으로 감싼 줄은 제외)
    pats = [r"\bread\s[^;|\n]*-[a-zA-Z]*N\b", r"\bprintf\b[^|;\n]*%\(", r"EPOCHSECONDS|EPOCHREALTIME", r"&>>", r"\bglobstar\b|\blastpipe\b",
            r"\b(declare|local|typeset)\s+-[a-zA-Z]*n\b", r"\bwait\s+-n\b", r"\[\[?\s+-v\s", r"\$\{[a-zA-Z_][a-zA-Z0-9_]*[\^,]", r"\[-1\]",
            r"\{[0-9]+\.\.[0-9]+\.\.", r"(^|[\s;&|{(])(mapfile|readarray|coproc)\s", r"\b(declare|local|typeset)\s+-[a-zA-Z]*A",
            r"\bdeclare\s+-[a-zA-Z]*g", r"\bread\s[^;|\n]*-t\s*[0-9]*\.[0-9]", r"\$\{[a-zA-Z_]+@[QEPAa]\}",
            r"(^|\s);;?&(\s|$)", r"\|&\s", r"\bBASHPID\b|\bSRANDOM\b",
            # 치환(${x/…}·${x//…}) 안에 다시 치환 — bash 3.2 는 bad substitution(맥 CI 0.2.2). ${x/"${BASH_REMATCH[0]}"/…}·${x:-${y}} 같은 3.2 에서 되는 꼴은 걸리지 않게 안쪽도 치환일 때만
            r"\$\{[A-Za-z_][A-Za-z0-9_]*//?[^}]*\$\{[A-Za-z_][A-Za-z0-9_]*//?"]
    hits = []
    for f in sorted((ROOT / "plugins/refactor").glob("*/*.sh")):
        for i, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
            if "BASH_VERSINFO" in line:
                continue
            hits += [f"{f.name}:{i}: {p}" for p in pats if re.search(p, line)]
    check("bash 3.2: bash 4 전용 문법 0건", not hits, "\n".join(hits[:20]))
    shutil.rmtree(tmpd, ignore_errors=True)

    # 19-2b) hooks.json(0.2.3 A3): guard 제한은 감시 한도(25초)보다 넉넉히(45초 이상) — 감시가 끊기 전에 Claude Code 가 먼저 끊으면 통과다. 나머지 훅은 30초
    try:
        hj = json.loads((ROOT / "plugins/refactor/hooks/hooks.json").read_text(encoding="utf-8"))["hooks"]
        lims = {h["command"].rsplit(" ", 1)[-1]: h.get("timeout") for ev in hj.values() for m in ev for h in m["hooks"]}
        ok = (lims.get("guard") or 0) >= 45 and all(lims.get(k) == 30 for k in ("post-check", "turn", "session-start"))
    except Exception as ex:
        ok, lims = False, ex
    check("hooks.json: guard 제한 45초 이상·나머지 훅 30초", ok, str(lims))

    # 19-3) run.sh 감시(0.2.3 #13): 시간 초과된 PreToolUse 훅은 도구 호출을 막지 않는다(공식 문서) → guard 판정이 T초
    #       (기본 25, REFACTOR_GUARD_LIMIT 로 1~25 사이로만 줄일 수 있음)를 넘기면 run.sh 가 guard 를 죽이고 2(차단).
    #       "막혔다"는 종료 코드·문구로 판정하고 시간은 상한만 본다(느린 CI 에서 헛빨강이 나지 않게 넉넉히).
    TMSG = "[refactor 안전장치] 판정이 너무 오래 걸려 막았습니다({}초 초과) — 내용을 파일로 저장해 경로를 넘기거나, 명령을 나눠 주세요."
    tmpw = pathlib.Path(tempfile.mkdtemp(prefix="watch-"))
    shutil.copytree(ROOT / "plugins/refactor", tmpw / "refactor")
    wrun = (tmpw / "refactor/hooks/run.sh").as_posix()
    wdata = tmpw / "d"
    wdata.mkdir()
    # 가짜 guard: FAKE_BUSY 초 동안 bash 안에서만 돈다(자식 프로세스 없음 — 긴 확장 한 번에 갇힌 것과 같음), FAKE_CODE 로 끝난다
    lf(tmpw / "refactor/hooks/guard.sh", "#!/usr/bin/env bash\n"
       "IFS= read -r -d '' input || true\n"
       "printf '%s' \"$$\" > \"$CLAUDE_PLUGIN_DATA/fake.pid\"\n"
       "if [ -n \"${FAKE_ECHO:-}\" ]; then printf 'out:ok'; printf 'in:%s\\n' \"$input\" >&2; fi\n"
       "if [ -n \"${FAKE_PRE:-}\" ]; then eval \"$FAKE_PRE\"; fi\n"
       "s=$SECONDS; x=aaaaaaaaaa\n"
       "while [ $((SECONDS - s)) -lt \"${FAKE_BUSY:-0}\" ]; do y=${x//a/b}; done\n"
       "exit \"${FAKE_CODE:-0}\"\n")

    def wcall(limit=None, busy=0, code=0, echo=False, stdin=b'{"tool_name":"Bash","tool_input":{"command":"ls"}}', tmo=15, pre=None):
        e = env()
        e["CLAUDE_PLUGIN_DATA"] = str(wdata)
        e.pop("REFACTOR_GUARD_LIMIT", None)
        if limit is not None:
            e["REFACTOR_GUARD_LIMIT"] = limit
        e["FAKE_BUSY"], e["FAKE_CODE"] = str(busy), str(code)
        if echo:
            e["FAKE_ECHO"] = "1"
        if pre:
            e["FAKE_PRE"] = pre
        t0 = time.perf_counter()
        try:
            r = subprocess.run([BASH, wrun, "guard"], input=stdin, capture_output=True, env=e, timeout=tmo)
            return r.returncode, r.stdout.decode("utf-8", "replace"), r.stderr.decode("utf-8", "replace"), time.perf_counter() - t0
        except subprocess.TimeoutExpired:
            return "시간 초과", "", "", time.perf_counter() - t0

    def wlog():
        f = wdata / "problems.log"
        return f.read_text(encoding="utf-8").splitlines() if f.exists() else []

    def bash_count():
        """Windows: 살아 있는 bash.exe 수(tasklist). 세지 못하면 -1.
        Git Bash 의 ps 로 세던 판은 CI 에서 늘 0 이 나와 '전 0 = 후 0' 헛초록이었다 — 이 시험 자신(python)이 목록에 보이는지로 세기가 되는지 확인한다."""
        try:
            out = subprocess.run(["tasklist", "/FO", "CSV", "/NH"], capture_output=True, timeout=30).stdout.decode("mbcs", "replace").lower()
        except Exception:
            return -1
        if '"python' not in out:
            return -1
        return sum(1 for l in out.splitlines() if l.startswith('"bash.exe"'))

    def leftovers(before=None):
        """이 시험의 사본 플러그인 경로가 명령줄에 든 프로세스(감시용 셸·가짜 guard)가 남았는지.
        Windows 는 부르기 전 bash 프로세스 수(before)보다 늘었는지로 본다."""
        hits = []
        for _ in range(30):   # 끝나는 중인 프로세스에 3초까지 여유
            if os.name == "nt":
                n = bash_count()
                if before is None or before < 0 or n < 0:   # -1 = 세지 못한 것(헛초록 방지, 0.2.3 A4 F14)
                    return [f"bash 프로세스 수를 세지 못함(전 {before} · 후 {n})"]
                hits = [] if n <= before else [f"bash 프로세스 {before} → {n}"]
            else:
                ps = subprocess.run(["ps", "-axo", "pid=,args="], capture_output=True).stdout.decode("utf-8", "replace")
                hits = [l.strip() for l in ps.splitlines() if str(tmpw) in l]
            if not hits:
                return []
            time.sleep(0.1)
        return hits

    def pid_alive():
        if os.name == "nt":   # 가짜 guard 가 적은 번호는 MSYS 번호 — 시험이 쓰는 bash 로 확인
            pid = (wdata / "fake.pid").read_text().strip() if (wdata / "fake.pid").exists() else ""
            return pid.isdigit() and subprocess.run([BASH, "-c", f"kill -0 {pid}"], capture_output=True, env=env()).returncode == 0
        try:
            os.kill(int((wdata / "fake.pid").read_text()), 0)
            return True
        except (OSError, ValueError):
            return False

    # (가) 느린 guard + 한도 2초 → 10초 안에 2(차단) + 문구 + 기록 한 줄, guard·감시가 남지 않음
    n0 = len(wlog())
    nb = bash_count() if os.name == "nt" else None
    rc, so, se, dt = wcall(limit="2", busy=999)
    lines = se.splitlines()
    check("감시: 한도 2초 → 차단(2)", rc == 2 and dt < 10, f"{rc} {dt:.1f}s {se[-300:]}")
    check("감시: 첫 줄 문구(2초)", bool(lines) and lines[0] == TMSG.format(2), se[:400])
    check("감시: 둘째 줄 안내(→)", len(lines) >= 3 and lines[1] == "  → 긴 지시문·SQL 은 파일로 저장해 경로를 넘기고, 긴 명령은 Write 도구로 스크립트 파일을 만들어 무엇을 하는지 사용자에게 보여 준 뒤 실행하세요.", se[:600])
    check("감시: 끝 줄 우회 금지 안내", bool(lines) and lines[-1].startswith("  (같은 결과를 내는 다른 명령으로 우회하지 말고"), se[-300:])
    new = wlog()[n0:]
    check("감시: 문제 기록 한 줄(명령·값 없음)", len(new) == 1 and new[0].endswith(" | run.sh | guard 시간 초과(2초) → 차단"), "\n".join(new))
    check("감시: 시간 초과 뒤 guard 죽음", not pid_alive())
    left = leftovers(nb)
    check("감시: 시간 초과 뒤 남은 프로세스 0", not left, "\n".join(left))

    # (가-2) 감시 파이프(fd 5 — guard 와 그 자식이 물려받는다)에 무엇을 써도 감시가 손을 놓지 않는다(0.2.3 A4 F11)
    #   한 줄 · 줄바꿈 없는 글자 · NUL 글자 · 자식 프로세스가 쓰기 — 넷 다 한도 2초에 막혀야 한다
    for label, pre in [("한 줄", "echo x >&5"), ("줄바꿈 없는 글자", "printf x >&5"), ("NUL 글자", "printf '\\0' >&5"),
                       ("자식이 한 줄", "bash -c 'echo hook >&5'")]:
        rc, so, se, dt = wcall(limit="2", busy=30, pre=pre)
        check(f"감시: 감시 파이프에 {label}을 써도 차단", rc == 2 and dt < 10 and se.splitlines()[:1] == [TMSG.format(2)], f"{rc} {dt:.1f}s {se[:200]}")

    # (가-3) guard 가 끝나는 순간에 감시 신호(USR1)가 겹쳐도 "차단"이 "통과"로 바뀌지 않는다(0.2.3 재검사 R3 🔴1).
    #   다시 거둘 때 상태를 못 찾으면(127·255) 판정을 모르는 것이므로 막는다. 차단(42)은 늘 2, 통과(0)는 0 또는 2(막는 쪽)만 나와야 한다.
    #   가짜 guard 가 실행기에 신호를 보내자마자 끝난다(신호 뒤에 일을 더 하면 강제 종료가 먼저 닿아 경합이 생기지 않는다)
    got42 = [wcall(limit="2", pre="kill -USR1 $PPID & exit 42")[0] for _ in range(20)]
    check("감시: 끝나는 순간 신호가 겹쳐도 차단(42)은 늘 2", got42 == [2] * 20, str(got42))
    got0 = [wcall(limit="2", pre="kill -USR1 $PPID & exit 0")[0] for _ in range(10)]
    check("감시: 끝나는 순간 신호가 겹친 통과(0)는 0 또는 2", all(c in (0, 2) for c in got0), str(got0))

    # (다) A2: 1~25 정수만 받는다 — 0·26·글자·빈 값·전각 숫자는 25(3초 걸리는 guard 를 막지 않음), 26 은 25 로 취급(늘릴 수 없음 — 26~29 를 받는 변이를 잡게 26)
    for lim in ["0", "26", "x", "", "\uff12"]:
        rc, so, se, dt = wcall(limit=lim, busy=3)
        check(f"감시: 한도 {lim!r} → 25초(3초 판정은 그대로)", rc == 0 and se == "", f"{rc} {dt:.1f}s {se[:300]}")
    rc, so, se, dt = wcall(limit="26", busy=999, tmo=45)
    check("감시: 한도 26 → 25초에 차단", rc == 2 and 20 < dt < 40 and se.splitlines()[:1] == [TMSG.format(25)], f"{rc} {dt:.1f}s {se[:300]}")

    # (다) A5·A6: 빨리 끝나는 호출 — 표준입력·표준출력·표준오류 전달, 종료 코드 변환(42→2, 2→1, 그 외 그대로), 한도를 기다리지 않고 바로 돌아옴
    stdin = json.dumps({"tool_name": "Bash", "tool_input": {"command": "echo 가나다"}}, ensure_ascii=False).encode("utf-8")
    n1 = len(wlog())
    nb = bash_count() if os.name == "nt" else None
    for code, want in [(0, 0), (42, 2), (2, 1), (7, 7)]:
        rc, so, se, dt = wcall(code=code, echo=True, stdin=stdin)
        check(f"감시: 정상 경로 종료 코드 {code}→{want}·입출력 그대로·바로 돌아옴", rc == want and so == "out:ok"
              and se == "in:" + stdin.decode("utf-8") + "\n" and dt < 5, f"{rc} {dt:.2f}s {so!r} {se[:300]!r}")
    # 한도 1(시간 여유 0): 바로 끝나는 guard 는 죽지 않는다(여러 번)
    got = [wcall(limit="1", code=0)[0] for _ in range(5)]
    check("감시: 한도 1 에서도 빨리 끝나는 guard 는 통과", got == [0] * 5, str(got))
    left = leftovers(nb)
    check("감시: 정상 종료 뒤 남은 프로세스 0", not left, "\n".join(left))
    check("감시: 정상 경로는 문제 기록 없음", not any("시간 초과" in l for l in wlog()[n1:]), "\n".join(wlog()[n1:]))
    shutil.rmtree(tmpw, ignore_errors=True)

    # (나) 실제 guard: 홀수 따옴표 2,000줄 지시문(마지막 줄에 비밀값 파일 읽기 지시) → 30초 안에 2(판정이 끝나든 감시가 끊든 막힌다)
    d = project()
    e = env()
    e["CLAUDE_PROJECT_DIR"] = str(d)
    e.pop("REFACTOR_GUARD_LIMIT", None)
    pl = json.dumps({"session_id": "s1", "tool_name": "Agent", "cwd": str(d),
                     "tool_input": {"description": "t", "prompt": "$ echo it's\n" * 1999 + "$ cat .env\n"}}).encode()
    t0 = time.perf_counter()
    try:
        r = subprocess.run([BASH, RUN, "guard"], input=pl, capture_output=True, env=e, timeout=30)
        rc = r.returncode
    except subprocess.TimeoutExpired:
        rc = "시간 초과"
    dt = time.perf_counter() - t0
    print(f"  성능 · 홀수 따옴표 2,000줄 지시문(실제 guard): {dt*1000:.0f}ms")
    check("감시: 실제 guard 홀수 따옴표 2,000줄 → 30초 안에 차단", rc == 2, f"{rc} {dt:.1f}s")
    shutil.rmtree(d, ignore_errors=True)

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
    r = subprocess.run([BASH, "-c", 'LC_ALL=C; export LC_ALL; eval "$(tr -d \'\\r\' < "$1")"; rl_card_text "$2" P1-1', "x", lib,
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
        r = subprocess.run([BASH, str(RUN), "refactor-board", str(d)], input=str(d).encode(), capture_output=True, env=env(), timeout=90)
        return r.stdout.decode("utf-8", "replace").split("상태 뜻")[0]
    lf(d / "docs/refactor/STATE.md", STATE.replace("gate: G2-plan", "gate: none"))
    check("현황표: 승인 대기 → 🙋", "🙋 사장님 차례" in board_row())
    approve(d, "P1-1")
    lf(d / "docs/refactor/STATE.md", STATE)
    check("현황표: 실행 대기 → ▶", "▶ 다음 단계 가능" in board_row())
    shutil.rmtree(d, ignore_errors=True)

    # 24) 문제 신고(/refactor:report): 묶음 가리기 · 보내지 않음 · 동의 뒤 gh 호출 · gh 없음 · 문제 기록
    tmpr = pathlib.Path(tempfile.mkdtemp(prefix="reporttest-"))
    data = tmpr / "data"
    fakebin = tmpr / "bin"
    fakebin.mkdir()
    ghlog = tmpr / "gh.log"
    lf(fakebin / "gh", '#!/usr/bin/env bash\nprintf \'%s\\n\' "$*" >> "$FAKE_GH_LOG"\n'
       '[ "$1 $2" = "auth status" ] && exit "${FAKE_GH_AUTH:-0}"\n'
       '[ "$1 $2" = "issue create" ] && echo "https://github.com/owner/repo/issues/7"\nexit 0\n')
    os.chmod(fakebin / "gh", 0o755)
    plug = tmpr / "plug"
    shutil.copytree(ROOT / "plugins/refactor", plug / "refactor")
    pj = plug / "refactor/.claude-plugin/plugin.json"
    lf(pj, pj.read_text(encoding="utf-8").replace("https://github.com/developer-duno/claude-code-refactor", "https://github.com/owner/repo"))
    prun = (plug / "refactor/hooks/run.sh").as_posix()

    def no_gh_path(path):
        """gh 가 없는 컴퓨터처럼: gh(.exe) 가 든 PATH 폴더는 gh 만 뺀 임시 링크 폴더로 바꾼다
        (리눅스는 /usr/bin 에 gh·bash·git·python3 이 같이 있어 폴더를 통째로 빼면 bash 도 사라진다).
        링크를 못 만드는 컴퓨터(Windows 기본 — 권한 없음)는 기존 방식대로 그 폴더를 PATH 에서 뺀다."""
        out = []
        for i, p in enumerate(path.split(os.pathsep)):
            if not (os.path.exists(os.path.join(p, "gh")) or os.path.exists(os.path.join(p, "gh.exe"))):
                out.append(p)
                continue
            q = tmpr / f"nogh{i}"
            try:
                if not q.exists():
                    q.mkdir()
                    for name in os.listdir(p):
                        if name not in ("gh", "gh.exe"):
                            os.symlink(os.path.join(p, name), q / name)
                out.append(str(q))
            except OSError:
                shutil.rmtree(q, ignore_errors=True)
        return os.pathsep.join(out)

    def rep(args, stdin="", path_prefix=None, path_filter=False, extra=None):
        e = env()
        e["CLAUDE_PLUGIN_DATA"] = str(data)
        e["FAKE_GH_LOG"] = str(ghlog)
        e["GH_CONFIG_DIR"] = str(tmpr / "nogh-config")   # 진짜 gh 가 남아 있어도 로그인 없는 상태로 — 실제 GitHub 호출 0
        e.pop("GH_TOKEN", None); e.pop("GITHUB_TOKEN", None)   # 환경변수 토큰으로도 로그인되지 않게
        if path_prefix:
            e["PATH"] = str(path_prefix) + os.pathsep + e["PATH"]
        if path_filter:
            e["PATH"] = no_gh_path(e["PATH"])
        if extra:
            e.update(extra)
        r = subprocess.run([BASH, prun, "refactor-report", *args], input=stdin.encode("utf-8"),
                           capture_output=True, env=e, timeout=120)
        return r.stdout.decode("utf-8", "replace") + r.stderr.decode("utf-8", "replace"), r.returncode

    # 가짜 비밀값(시험용 자리표시자 — 실행 중에 조각을 이어 붙여 만든다)
    fk = "FAKE" + "TESTVALUE" + "0000"
    fakes = {
        "kv": "PAY_SECRET_KEY=" + fk + "kv",
        "url": "postgres://admin:" + fk + "pw@db.example.test/x",
        "gh": "gh" + "p_" + fk + "gh",
        "slack": "xo" + "xb-" + fk + "sl",
        "aws": "AK" + "IA" + fk + "AW",
        "jwt": "ey" + "J" + fk + "jw",
        "home": "C:\\Users\\" + "fakeperson" + "\\proj",
        "google": "AI" + "za" + "Sy" + fk + "gg",   # 0.2.1 V M4: Google API 키·Bearer 토큰·Supabase·Stripe 웹훅·제한 키
        "bearer": "Authorization: Bear" + "er " + fk + "br",
        "sb": "sb_" + "secret_" + fk + "sb",
        "whsec": "wh" + "sec_" + fk + "wh",
        "rk": "rk_" + "live_" + fk + "rk",
        # D5c L-c: 앞에 _·글자가 붙은 것, 접두어 더
        "sb2": "MY_" + "sb_" + "secret_" + fk + "s2", "wh2": "prefix" + "wh" + "sec_" + fk + "w2", "skt": "sk_" + "test_" + fk + "st",
        "ghs": "gh" + "s_" + fk + "gs", "glpat": "glp" + "at-" + fk + "gl", "npm": "np" + "m_" + fk + "np", "sg": "S" + "G." + fk + ".sg",
    }
    data.mkdir()
    lf(data / "problems.log", "2026-09-26 10:00 | run.sh | x exit 2 " + fakes["kv"] + "\n")
    desc = "결제가 안 돼요 " + " ".join(fakes.values())
    out, rc = rep(["--collect", str(tmpr), "--data", str(data)], desc, path_prefix=fakebin)
    files = sorted(data.glob("report-*.md"))
    body = files[-1].read_text(encoding="utf-8") if files else ""
    leaked = [s[max(0, s.find(fk) - 30):s.find(fk) + 30] for s in (out, body) if fk in s] + [s for s in (out, body) if "fakeperson" in s][:1]
    check("신고: 묶음 가리기(화면·파일에 가짜 비밀값 0)", rc == 0 and files and not leaked and "****" in body and "<홈>" in body, f"{rc} {leaked} {out[-800:]}")
    try:   # plugin.json 이 깨져도 시험 전체가 죽지 않고 이 check 만 실패하게
        ver = json.loads(pj.read_text(encoding="utf-8"))["version"]
    except Exception as e:
        ver = f"<plugin.json 읽기 실패: {e}>"
    check("신고: 묶음 내용(버전·상태·설명)", f"플러그인 버전: {ver}" in out and "결제가 안 돼요" in out and "아직 아무 데도 보내지 않았습니다" in out, out[-800:])
    check("신고: 묶음은 폴더 이름만", tmpr.as_posix() not in out and str(tmpr) not in out and f"폴더 이름: {tmpr.name}" in out, out[:600])
    check("신고: --collect 는 gh 를 부르지 않음", not ghlog.exists(), ghlog.read_text(encoding="utf-8") if ghlog.exists() else "")

    out, rc = rep(["--send", "--data", str(data), "--title", "결제 오류"], path_prefix=fakebin)
    calls = ghlog.read_text(encoding="utf-8") if ghlog.exists() else ""
    check("신고: --send 가 gh 를 정확한 인자로", rc == 0 and "issues/7" in out and "issue create --repo owner/repo --title [refactor] 결제 오류 --body-file " in calls
          and "--label bug" in calls, f"{rc} {out} {calls}")
    sent = (data / ".send-body.md").read_text(encoding="utf-8") if (data / ".send-body.md").exists() else ""
    check("신고: 보낸 본문도 가려짐", "플러그인 버전" in sent and fk not in sent, sent[-400:])

    out, rc = rep(["--send", "--data", str(data), "--title", "결제 오류"], path_filter=True)
    check("신고: gh 없음 → exit 4 + 링크", rc == 4 and "gh(GitHub CLI)가 없어" in out and "https://github.com/owner/repo/issues/new?template=bug.yml&title=%5Brefactor%5D%20" in out
          and "묶음 파일:" in out, f"{rc} {out}")
    out, rc = rep(["--send", "--data", str(data)], path_prefix=fakebin, extra={"FAKE_GH_AUTH": "1"})
    check("신고: gh 로그인 안 됨 → exit 4", rc == 4 and "issues/new?template=bug.yml" in out, f"{rc} {out}")
    out, rc = rep(["--send", "--data", str(data), "--file", ".env"], path_prefix=fakebin)
    check("신고: 묶음이 아닌 파일은 보내지 않음", rc == 3, f"{rc} {out}")

    # 문제 기록: 실행기(문법 오류 스크립트) · 안전장치 차단 — 이름·종료 코드·규칙 설명만
    lf(plug / "refactor/scripts/zz-bad.sh", "if then\n")
    e = env()
    e["CLAUDE_PLUGIN_DATA"] = str(tmpr / "d2")
    r = subprocess.run([BASH, prun, "zz-bad"], capture_output=True, env=e, timeout=90)
    plog = (tmpr / "d2/problems.log").read_text(encoding="utf-8") if (tmpr / "d2/problems.log").exists() else ""
    check("문제 기록: 문법 오류 스크립트", r.returncode == 2 and plog.count("\n") == 1 and plog.rstrip().endswith(" | run.sh | zz-bad exit 2"), f"{r.returncode} {plog}")
    gp = tmpr / "gproj"
    gp.mkdir()
    e["CLAUDE_PROJECT_DIR"] = str(gp)
    pl = json.dumps({"session_id": "s1", "tool_name": "Bash", "tool_input": {"command": "cat .env.production"}}).encode()
    r = run_hook([BASH, prun, "guard"], input=pl, capture_output=True, env=e)
    plog = (tmpr / "d2/problems.log").read_text(encoding="utf-8")
    last = plog.rstrip().splitlines()[-1]
    check("문제 기록: 안전장치 차단(명령은 적지 않음)", r.returncode == 2 and " | guard | 차단: " in last and "cat " not in last
          and len(last.split("차단: ", 1)[1]) <= 60, last)
    # 기록이 200KB 를 넘으면 최근 절반만(안전장치 줄의 정리 부분을 가끔이 아니라 바로 실행해 확인)
    gline = next((l for l in (ROOT / "plugins/refactor/hooks/guard.sh").read_text(encoding="utf-8").splitlines() if "problems.log" in l and "printf" in l), "")
    lf(tmpr / "d2/problems.log", "".join(f"2026-09-01 10:00 | guard | 차단: 채움 {i:06d} {'가' * 20}\n" for i in range(4000)))
    r = subprocess.run([BASH, "-c", "NL=$'\\n'; BS='\\\\'; SL=/; f() { " + gline.split("   # ")[0].replace("(( RANDOM % 64 ))", "false") + "\n}; f 규칙설명"],
                       capture_output=True, env=e, timeout=90)
    sz = (tmpr / "d2/problems.log").stat().st_size
    tail = (tmpr / "d2/problems.log").read_text(encoding="utf-8").splitlines()
    check("문제 기록: 200KB 넘으면 최근 절반", 90000 < sz <= 102400 and tail[-1].endswith("차단: 규칙설명") and tail[0].startswith("2026-09-01"), f"{sz} {tail[:1]} {tail[-1:]}")
    shutil.rmtree(tmpr, ignore_errors=True)

    # 25) 판 번호 일치: plugin.json · marketplace.json · README 배지 · bug.yml placeholder 가 모두 같은 판
    try:
        pv = json.loads((ROOT / "plugins/refactor/.claude-plugin/plugin.json").read_text(encoding="utf-8"))["version"]
        mk = json.loads((ROOT / ".claude-plugin/marketplace.json").read_text(encoding="utf-8"))
        mv = next((p.get("version") for p in mk.get("plugins", []) if p.get("name") == "refactor"), None)
        rd = (ROOT / "README.md").read_text(encoding="utf-8")
        rm = re.search(r"version-([0-9.]+)-blue", rd)
        rv = rm.group(1) if rm else None
        by = (ROOT / ".github/ISSUE_TEMPLATE/bug.yml").read_text(encoding="utf-8")
        bm = re.search(r'placeholder:\s*"([0-9.]+)"', by)
        bv = bm.group(1) if bm else None
        check("판 번호 일치: plugin/marketplace/README/bug.yml",
              pv is not None and pv == mv == rv == bv,
              f"plugin.json={pv} marketplace.json={mv} README={rv} bug.yml={bv}")
    except Exception as e:
        check("판 번호 일치: plugin/marketplace/README/bug.yml", False, f"예외: {e}")

    check_allow_steps_032(check)
    check_allow_current_033(check)
    check_baseline_committed_035(check)
    check_approve_allow_033(check)
    check_approve_push_033(check)
    check_approve_newbranch_034(check)
    check_newbranch_fix_034(check)
    check_approve_autoallow_034(check)
    check_protected_new_034(check)
    check_merge_grant_035(check)
    check_merge_script_035(check)
    check_merge_s11_035(check)
    check_lib_lc_all_033(check)
    check_commit_docs_033(check)
    check_docs_034(check)
    check_docs_fix_034(check)
    check_docs_035(check)

    check(f"훅 시간 초과({HOOK_TIMEOUT}초) 0건", not HOOK_TIMEOUTS, " / ".join(HOOK_TIMEOUTS))

    for label, detail in fails:
        print(f"FAIL {label}\n      {detail}")
    print(f"\n{total - len(fails)}/{total} 통과 · bash={BASH}{' · PATH+' + PATH_PREFIX if PATH_PREFIX else ''}")
    return 1 if fails else 0


PLAN_032 = """# 계획서

### [P1-1] 금액 계산
- **종류**: 🛠 개선
- **깨질 것으로 예상되는 기준선**: `tests/baseline/money.test.ts` 중 "금액" 항목
- **승인**: [ ] 승인
- **완료**: [ ] 완료

### [P1-2] 주문 주소
- **종류**: 🛠 개선
- **깨질 것으로 예상되는 기준선**: `./tests/baseline/golden/d.json` 의 주문 항목
- **승인**: [ ] 승인
- **완료**: [ ] 완료

### [P1-3] 아직 승인 안 함
- **종류**: 🛠 개선
- **깨질 것으로 예상되는 기준선**: 없음
- **승인**: [ ] 승인
- **완료**: [ ] 완료
"""


def check_allow_steps_032(check):
    """0.3.2 #10: rl_allow_baseline 출력 · 턴 끝 알림(rl_protected_dirty)은 열린 단계 카드에 적힌 기준선만 뺀다(11) ·
    적힌 단계가 모두 끝나면 turn.sh 가 허용 파일을 지우고 post-check 가 한 번 알린다(3) · 현황(status·board) 문구."""
    lib = (ROOT / "plugins/refactor/scripts/refactor-lib.sh").as_posix()
    g = lambda d, *a: subprocess.run(["git", "-C", str(d), "-c", "user.email=t@example.com", "-c", "user.name=t", *a], check=True, capture_output=True)

    def libcall(d, expr):
        # 플러그인 진입점(guard·turn·post-check·approve·status·board)과 같이 LC_ALL=C 로 — macOS 의 UTF-8 인식 awk 가 카드 지문을
        # 다르게 재어 승인 상태를 못 알아보던 것(0.3.2 PR #12 CI macOS 6건 실패)
        r = subprocess.run([BASH, "-c", 'LC_ALL=C; export LC_ALL; eval "$(tr -d \'\\r\' < "$1")"; P=$2; R=$2/docs/refactor; ' + expr, "x", lib, d.as_posix()],
                           capture_output=True, env=env(), timeout=90)
        return r.stdout.decode("utf-8", "replace").replace("\r", ""), r.stderr.decode("utf-8", "replace")

    def allow(d, data):
        (d / "docs/refactor/.allow-baseline-edit").write_bytes(data if isinstance(data, bytes) else data.encode("utf-8"))

    def mk():
        d = project(plan=PLAN_032)
        # 0.3.3: 허용은 STATE.md current_step 에 적힌 단계만 열린다 — 0.3.2 시험의 뜻(적힌 단계 둘 다 실행 중)을 살린다
        lf(d / "docs/refactor/STATE.md", STATE.replace("updated:", 'current_step: "P1-1 P1-2 (진행 중)"\nupdated:'))
        (d / "tests/baseline/golden").mkdir(parents=True)
        for f in ("money.test.ts", "other.test.ts", "golden/d.json"):
            lf(d / "tests/baseline" / f, "x\n")
        subprocess.run(["git", "init", "-q", str(d)], check=True)
        g(d, "add", "-A"); g(d, "commit", "-qm", "i")
        approve(d, "P1-1 P1-2")
        return d

    d = mk()
    try:
        # rl_allow_baseline 출력 꼴
        allow(d, "p1-1 P1-2 # 이번 묶음\n")
        out, err = libcall(d, 'rl_allow_baseline "$R"')
        check("0.3.2 출력: OPEN + 카드 경로(./ 뗌)", out == "OPEN P1-1 P1-2\ntests/baseline/money.test.ts\ntests/baseline/golden/d.json\n", repr(out) + err)
        allow(d, "P1-3\n")
        out, _ = libcall(d, 'rl_allow_baseline "$R"')
        check("0.3.2 출력: 승인 안 된 단계 → SHUT", out == "SHUT P1-3\n", repr(out))
        allow(d, "P9-9\n")
        out, _ = libcall(d, 'rl_allow_baseline "$R"')
        check("0.3.2 출력: 계획서와 맞는 카드 없음(오타) → UNKNOWN", out == "UNKNOWN P9-9\n", repr(out))
        allow(d, " \n\r\n")
        out, _ = libcall(d, 'rl_allow_baseline "$R"')
        check("0.3.2 출력: 공백만 → ALL", out == "ALL\n", repr(out))
        for title, data in [("주석만", "# P1-1\n"), ("별표", "*\n"), ("한글만", "전부\n")]:
            allow(d, data)
            out, _ = libcall(d, 'rl_allow_baseline "$R"')
            check(f"0.3.2 출력(W2b c2): {title} → UNKNOWN ?", out == "UNKNOWN ?\n", repr(out))
        allow(d, "P1-1\n")
        out, _ = libcall(d, 'rl_allow_baseline "$R" approved')
        check("0.3.2 출력: approved 꼴(열린 단계도 경로)", out == "OPEN P1-1\ntests/baseline/money.test.ts\n", repr(out))
        (d / "docs/refactor/.allow-baseline-edit").unlink()
        out, _ = libcall(d, 'rl_allow_baseline "$R"')
        check("0.3.2 출력: 파일 없음 → NONE", out == "NONE\n", repr(out))

        # 11 rl_protected_dirty: 열린 단계 카드의 파일(끝 경로 맞춤 포함)만 빼고 나머지 기준선 변경은 보고
        for f in ("money.test.ts", "other.test.ts", "golden/d.json"):
            lf(d / "tests/baseline" / f, "바뀜\n")
        dirty = lambda: libcall(d, 'rl_protected_dirty "$P" "$R" | cut -f1')[0]
        out = dirty()
        check("0.3.2 11 허용 파일 없음 → 셋 다 보고", all(f in out for f in ("money.test.ts", "other.test.ts", "golden/d.json")), out)
        allow(d, "P1-1\n")
        out = dirty()
        check("0.3.2 11 P1-1 열림 → money 만 빠짐", "money.test.ts" not in out and "other.test.ts" in out and "golden/d.json" in out, out)
        allow(d, "P1-1 P1-2\n")
        out = dirty()
        check("0.3.2 11 P1-1·P1-2 열림 → other 만 보고(./ 붙은 카드 경로)", "other.test.ts" in out and "money.test.ts" not in out and "golden/d.json" not in out, out)
        allow(d, "P9-9\n")
        out = dirty()
        check("0.3.2 11 열린 단계 없음 → 셋 다 보고", all(f in out for f in ("money.test.ts", "other.test.ts", "golden/d.json")), out)
        allow(d, "")
        check("0.3.2 11 빈 파일 → 기준선 전부 빠짐", dirty() == "", dirty())
        # post-check 도 같은 눈으로: 턴 시작 뒤 열린 단계 밖 기준선이 바뀌면 알림
        for f in ("money.test.ts", "other.test.ts", "golden/d.json"):
            lf(d / "tests/baseline" / f, "x\n")
        allow(d, "P1-1\n")
        hook("turn", d, {"session_id": "s1", "prompt": "이어서 고쳐 줘"})
        lf(d / "tests/baseline/money.test.ts", "새 동작\n")
        _, se, rc, _ = hook("post-check", d, {"session_id": "s1", "tool_name": "Bash"})
        check("0.3.2 11 post-check: 카드에 적힌 파일 변경은 조용", rc == 0, f"{rc} {se}")
        lf(d / "tests/baseline/other.test.ts", "몰래\n")
        _, se, rc, _ = hook("post-check", d, {"session_id": "s1", "tool_name": "Bash"})
        check("0.3.2 11 post-check: 카드 밖 기준선 변경은 알림", rc == 2 and "other.test.ts" in se and "money.test.ts" not in se, f"{rc} {se}")
        lf(d / "tests/baseline/money.test.ts", "x\n"); lf(d / "tests/baseline/other.test.ts", "x\n")

        # 현황 문구: 단계 ID 가 적혀 있으면 "지우세요" 대신 "단계 … 동안 열림", 빈 파일이면 예전 문구
        # (0.3.3 G6 으로 문구가 바뀜: "동안 열림" → "실행 중 — 열림" · 빈 파일은 예전 범용 문구 대신 전용 경고)
        st = sh("refactor-status", d)
        check("0.3.2 현황: 단계 동안 열림", "단계 P1-1 실행 중 — 열림(끝나면 저절로 닫힘)" in st and "허용 파일이 남아 있음" not in st, st[-400:])
        bd = sh("refactor-board", d, str(d))
        check("0.3.2 현황표: 🔓단계 표시", "🔓단계 P1-1 실행 중 — 열림" in bd and "⚠허용파일" not in bd, bd[-400:])
        allow(d, "")
        st = sh("refactor-status", d)
        check("0.3.2 현황: 빈 파일은 예전 문구", "⚠️ 빈 기준선 허용 파일 — 기준선 전부가 열려 있고 저절로 닫히지 않습니다." in st and "실행 중 — 열림" not in st, st[-400:])
        bd = sh("refactor-board", d, str(d))
        check("0.3.2 현황표: 빈 파일은 ⚠허용파일", "⚠허용파일" in bd, bd[-400:])
        # W2b c5: 상태별 문구(SHUT·UNKNOWN — DONE 은 아래 3 에서)
        allow(d, "P1-3\n")
        st, bd = sh("refactor-status", d), sh("refactor-board", d, str(d))
        check("0.3.2 현황(c5): SHUT 문구", "🔒 허용 파일의 단계 P1-3 가 승인 대기·카드 바뀜 — 지금은 닫힘." in st and "동안 열림" not in st
              and "🔒허용파일 단계 P1-3" in bd, st[-300:] + bd[-300:])
        allow(d, "P9-9\n")
        st, bd = sh("refactor-status", d), sh("refactor-board", d, str(d))
        check("0.3.2 현황(c5): UNKNOWN 문구", "⚠️ 허용 파일의 단계 P9-9 가 계획서에 없음(오타?) — 고치거나 지우세요" in st and "동안 열림" not in st
              and "⚠허용파일 단계 P9-9 계획서에 없음" in bd, st[-300:] + bd[-300:])
        allow(d, "")

        # 3 저절로 닫힘: 빈 파일·아직 안 끝난 단계는 지우지 않는다
        hook("turn", d, {"session_id": "s1", "prompt": "이어서"})
        check("0.3.2 3 빈 파일은 지우지 않음", (d / "docs/refactor/.allow-baseline-edit").exists())
        allow(d, "P1-1 P1-3\n")
        hook("turn", d, {"session_id": "s1", "prompt": "이어서"})
        check("0.3.2 3 안 끝난 단계가 있으면 지우지 않음", (d / "docs/refactor/.allow-baseline-edit").exists())
        # P1-1 완료 → P1-1 만 적힌 허용 파일은 다음 입력 때 지워지고, 그 턴의 셸 명령 뒤 한 번 알린다
        pp = d / "docs/refactor/REFACTOR_PLAN.md"
        t = pp.read_text(encoding="utf-8")
        i = t.index("### [P1-1]")
        lf(pp, t[:i] + t[i:].replace("- **완료**: [ ] 완료", "- **완료**: [x] 완료 (2026-10-03)", 1))
        allow(d, "P1-1\n")
        st, bd = sh("refactor-status", d), sh("refactor-board", d, str(d))
        check("0.3.2 현황(c5): DONE 문구", "✅ 허용 파일의 단계가 모두 끝남 — 다음 입력 때 지워짐." in st and "✅허용파일 단계 모두 끝남" in bd, st[-300:] + bd[-300:])
        hook("turn", d, {"session_id": "s1", "prompt": "/refactor:go"})
        check("0.3.2 3 끝난 단계의 허용 파일은 지움", not (d / "docs/refactor/.allow-baseline-edit").exists())
        _, se, rc, _ = hook("post-check", d, {"session_id": "s1", "tool_name": "Bash"})
        check("0.3.2 3 post-check 한 번 알림(c6 계속하라는 말)", rc == 2 and "허용 파일(.allow-baseline-edit)의 단계(P1-1)가 모두 끝나 지웠습니다." in se
              and "하던 일을 계속하세요" in se, f"{rc} {se}")
        _, se, rc, _ = hook("post-check", d, {"session_id": "s1", "tool_name": "Bash"})
        check("0.3.2 3 알림은 한 번만", rc == 0, f"{rc} {se}")
        # 오타만 적힌 파일(계획서 카드와 맞는 ID 0 = UNKNOWN)은 지우지도 알리지도 않는다
        allow(d, "P9-9\n")
        hook("turn", d, {"session_id": "s1", "prompt": "이어서"})
        _, se, rc, _ = hook("post-check", d, {"session_id": "s1", "tool_name": "Bash"})
        check("0.3.2 3 오타만 → 파일 남음·알림 없음",
              (d / "docs/refactor/.allow-baseline-edit").exists() and rc == 0 and "지웠습니다" not in se, f"{rc} {se}")
        # 맞는 카드가 끝났고 나머지는 계획서에 없음 → DONE(지움) · 셸 명령 없이 끝난 턴의 알림 표시는 다음 입력 때 사라진다
        allow(d, "P1-1 P9-9\n")
        out, _ = libcall(d, 'rl_allow_baseline "$R"')
        check("0.3.2 출력: 끝난 카드 + 계획서에 없는 ID → DONE", out == "DONE P1-1 P9-9\n", repr(out))
        hook("turn", d, {"session_id": "s1", "prompt": "이어서"})
        gone = not (d / "docs/refactor/.allow-baseline-edit").exists() and (d / "docs/refactor/.turn-allowgone.s1").exists()
        hook("turn", d, {"session_id": "s1", "prompt": "이어서"})
        check("0.3.2 3 끝난 카드 + 없는 ID → 지움, 지난 알림 표시는 다음 입력에 사라짐",
              gone and not (d / "docs/refactor/.turn-allowgone.s1").exists(), str(sorted(p.name for p in (d / "docs/refactor").iterdir())))
    finally:
        shutil.rmtree(d, ignore_errors=True)

    def done(d, cid):
        pp = d / "docs/refactor/REFACTOR_PLAN.md"
        t = pp.read_text(encoding="utf-8")
        i = t.index(f"### [{cid}]")
        lf(pp, t[:i] + t[i:].replace("- **완료**: [ ] 완료", "- **완료**: [x] 완료 (2026-10-03)", 1))

    # W2b c1: 같은 턴에 카드 파일을 고친 뒤 완료 표시를 해도 post-check 가 헛경보하지 않는다(허용 파일이 남아 있는 동안)
    for ids, files in [("P1-1", ["money.test.ts"]), ("P1-1 P1-2", ["money.test.ts", "golden/d.json"])]:
        d = mk()
        try:
            allow(d, ids + "\n")
            hook("turn", d, {"session_id": "s1", "prompt": "/refactor:go"})
            for f in files:
                lf(d / "tests/baseline" / f, "새 동작\n")
            _, se, rc, _ = hook("post-check", d, {"session_id": "s1", "tool_name": "Bash"})
            r1 = rc
            for cid in ids.split():
                done(d, cid)
            _, se, rc, _ = hook("post-check", d, {"session_id": "s1", "tool_name": "Bash"})
            check(f"0.3.2 c1 [{ids}] 카드 파일 고친 뒤 완료 표시 → post-check 조용", r1 == 0 and rc == 0, f"{r1} {rc} {se}")
        finally:
            shutil.rmtree(d, ignore_errors=True)

    # W2b c3: 프로젝트가 저장소 하위 폴더(모노레포)여도 카드 경로(프로젝트 기준)와 맞춘다
    root = pathlib.Path(tempfile.mkdtemp(prefix="scripttest-mono-"))
    try:
        d = root / "apps/web"
        (d / "docs/refactor").mkdir(parents=True)
        lf(d / "docs/refactor/REFACTOR_PLAN.md", PLAN_032)
        lf(d / "docs/refactor/BASELINE.md", BASELINE)
        lf(d / "docs/refactor/STATE.md", STATE)
        (d / "tests/baseline/golden").mkdir(parents=True)
        for f in ("money.test.ts", "other.test.ts", "golden/d.json"):
            lf(d / "tests/baseline" / f, "x\n")
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        g(root, "add", "-A"); g(root, "commit", "-qm", "i")
        approve(d, "P1-1 P1-2")
        allow(d, "P1-1\n")
        for f in ("money.test.ts", "other.test.ts"):
            lf(d / "tests/baseline" / f, "바뀜\n")
        out, err = libcall(d, 'rl_protected_dirty "$P" "$R" | cut -f1')
        check("0.3.2 c3 모노레포: 카드 파일만 빠짐", "apps/web/tests/baseline/other.test.ts" in out and "money.test.ts" not in out, out + err)
    finally:
        shutil.rmtree(root, ignore_errors=True)

    # 보완 d3: 같은 꼬리의 다른 폴더(x/tests/baseline/money.test.ts)는 카드 경로(tests/baseline/money.test.ts)와 다른 파일 — 끝 맞춤으로 빼면 안 된다
    d = mk()
    try:
        (d / "x/tests/baseline").mkdir(parents=True)
        lf(d / "x/tests/baseline/money.test.ts", "x\n")
        g(d, "add", "-A"); g(d, "commit", "-qm", "x")
        allow(d, "P1-1\n")
        lf(d / "x/tests/baseline/money.test.ts", "바뀜\n")
        lf(d / "tests/baseline/money.test.ts", "바뀜\n")
        out, err = libcall(d, 'rl_protected_dirty "$P" "$R" | cut -f1')
        lines = [ln.split()[-1] for ln in out.split("\n") if ln.strip()]   # 줄 꼴 " M <경로>" 의 경로만
        check("0.3.2 d3 같은 꼬리 다른 폴더는 보고에 남음(카드 파일만 빠짐)",
              "x/tests/baseline/money.test.ts" in lines and "tests/baseline/money.test.ts" not in lines, out + err)
    finally:
        shutil.rmtree(d, ignore_errors=True)


def check_allow_current_033(check):
    """0.3.3: 기준선 허용은 지금 실행 중인 단계(STATE.md current_step)만 · 도우미 rl_allow_ids / rl_card_bl_paths(c6)."""
    lib = (ROOT / "plugins/refactor/scripts/refactor-lib.sh").as_posix()

    def libcall(d, expr):
        # check_allow_steps_032 와 같은 꼴 — LC_ALL=C 를 먼저(맥의 awk 가 지문을 다르게 잰다)
        r = subprocess.run([BASH, "-c", 'LC_ALL=C; export LC_ALL; eval "$(tr -d \'\\r\' < "$1")"; P=$2; R=$2/docs/refactor; ' + expr, "x", lib, d.as_posix()],
                           capture_output=True, env=env(), timeout=90)
        return r.stdout.decode("utf-8", "replace").replace("\r", ""), r.stderr.decode("utf-8", "replace")

    def allow(d, data):
        (d / "docs/refactor/.allow-baseline-edit").write_bytes(data if isinstance(data, bytes) else data.encode("utf-8"))

    # c6 도우미 rl_allow_ids: 0.3.2 의 ID 뽑기와 같은 결과
    d = project(plan=PLAN_032)
    try:
        out, err = libcall(d, 'rl_allow_ids "$R"')
        check("0.3.3 c6 rl_allow_ids: 파일 없음 → 빈 출력", out == "", repr(out) + err)
        for title, data, want in [
            ("대소문자·주석", "p1-2  P1-1 # 메모\n", "P1-2 P1-1\n"),
            ("중복 제거", "P1-1 p1-1\nP1-1\n", "P1-1\n"),
            ("쉼표·줄바꿈 구분", "P1-1,P1-2\nP1-3\n", "P1-1 P1-2 P1-3\n"),
            ("UTF-8 BOM", b"\xef\xbb\xbfP1-1\r\n", "P1-1\n"),
            ("UTF-16(NUL·BOM)", "P1-1 P1-2\r\n".encode("utf-16"), "P1-1 P1-2\n"),
            ("주석만 → ?", "# P1-1\n", "?\n"),
            ("한글만 → ?", "전부\n", "?\n"),
            ("공백만 → 빈 출력", " \n\r\n", ""),
            ("0바이트 → 빈 출력", "", ""),
        ]:
            allow(d, data)
            out, err = libcall(d, 'rl_allow_ids "$R"')
            check(f"0.3.3 c6 rl_allow_ids: {title}", out == want, repr(out) + err)

        # c6 도우미 rl_card_bl_paths: 기본(전체 중복 제거) / -n(파일마다 · ? · 없음)
        cd = d / "cards"
        cd.mkdir()
        lf(cd / "c3", "### [P1-1] 가\n- **깨질 것으로 예상되는 기준선**: `tests/baseline/a.test.ts` 와 `.\\tests\\baseline\\b.json`\n"
                      "  `tests/baseline/a.test.ts` 다시\n- **승인**: [ ] 승인\n`tests/baseline/밖.ts`\n")
        lf(cd / "c4", "### [P1-2] 나\n- **깨질 것으로 예상되는 기준선**: ` ./tests/baseline/a.test.ts `\n### 다음\n`tests/baseline/z.ts`\n")
        lf(cd / "c5", "### [P1-3] 다\n- **깨질 것으로 예상되는 기준선**: tests/baseline 의 금액 항목\n- **승인**: [ ] 승인\n")
        lf(cd / "c6", "### [P1-4] 라\n- **깨질 것으로 예상되는 기준선**:\n  금액 테스트 일부\n- **승인**: [ ] 승인\n")
        lf(cd / "c7", "### [P1-5] 마\n- **깨질 것으로 예상되는 기준선**: 없음 (기준선 그대로)\n- **승인**: [ ] 승인\n")
        lf(cd / "c8", "### [P1-6] 바\n- **종류**: 🛠 개선\n- **승인**: [ ] 승인\n")
        lf(cd / "c9", "### [P1-7] 사\n- **깨질 것으로 예상되는 기준선**:\n- **승인**: [ ] 승인\n")
        out, err = libcall(d, 'rl_card_bl_paths "$P/cards/c3" "$P/cards/c4" "$P/cards/c5" "$P/cards/c7"')
        check("0.3.3 c6 rl_card_bl_paths 기본: 전체 중복 제거·\\ → /·./ 뗌·칸 밖 무시",
              out == "tests/baseline/a.test.ts\ntests/baseline/b.json\n", repr(out) + err)
        out, err = libcall(d, 'rl_card_bl_paths -n "$P/cards/c3" "$P/cards/c4" "$P/cards/c5" "$P/cards/c6" "$P/cards/c7" "$P/cards/c8" "$P/cards/c9"')
        check("0.3.3 c6 rl_card_bl_paths -n: 파일마다 · 백틱 0 은 ? · 없음·칸 없음·빈 칸은 줄 없음",
              out == "c3\ttests/baseline/a.test.ts\nc3\ttests/baseline/b.json\nc4\ttests/baseline/a.test.ts\nc5\t?\nc6\t?\n", repr(out) + err)
        out, err = libcall(d, 'rl_card_bl_paths -n "$P/cards/c5"')
        check("0.3.3 c6 rl_card_bl_paths -n: 파일 하나·마지막 파일의 ?", out == "c5\t?\n", repr(out) + err)
        out, err = libcall(d, 'rl_card_bl_paths; rl_card_bl_paths -n; echo "rc=$?"')
        check("0.3.3 c6 rl_card_bl_paths: 파일 없이 부르면 빈 출력", out == "rc=0\n", repr(out) + err)
    finally:
        shutil.rmtree(d, ignore_errors=True)

    # c1~c4 rl_allow_baseline: 허용 파일의 열린 단계 중 STATE.md 앞머리 current_step 에 적힌 단계만 OPEN, 없으면 WAIT
    g = lambda d, *a: subprocess.run(["git", "-C", str(d), "-c", "user.email=t@example.com", "-c", "user.name=t", *a], check=True, capture_output=True)
    head = STATE.rstrip("\n").rsplit("---", 1)[0]   # 앞머리 끝 --- 앞까지

    def state(d, cs=None, crlf=False, body="", raw=None):
        t = raw if raw is not None else head + (f"current_step: {cs}\n" if cs is not None else "") + "---\n" + body
        (d / "docs/refactor/STATE.md").write_bytes((t.replace("\n", "\r\n") if crlf else t).encode("utf-8"))

    M, G = "tests/baseline/money.test.ts\n", "tests/baseline/golden/d.json\n"
    d = project(plan=PLAN_032)
    try:
        (d / "tests/baseline/golden").mkdir(parents=True)
        for f in ("money.test.ts", "other.test.ts", "golden/d.json"):
            lf(d / "tests/baseline" / f, "x\n")
        subprocess.run(["git", "init", "-q", str(d)], check=True)
        g(d, "add", "-A"); g(d, "commit", "-qm", "i")
        approve(d, "P1-1 P1-2")
        allow(d, "P1-1 P1-2\n")
        ab = lambda: libcall(d, 'rl_allow_baseline "$R"')
        state(d, '"P1-1 (진행 중)"')
        out, err = ab()
        check("0.3.3 c1 실행 중 단계만: OPEN P1-1 + P1-1 경로만", out == "OPEN P1-1\n" + M, repr(out) + err)
        state(d, '"P1-2 (진행 중)"')
        out, err = ab()
        check("0.3.3 c1 실행 중 단계만: OPEN P1-2 + P1-2 경로만", out == "OPEN P1-2\n" + G, repr(out) + err)
        for title, kw in [("current_step \"-\"", dict(cs='"-"')), ("허용 밖 단계 P1-9", dict(cs='"P1-9 (진행 중)"')),
                          ("P1-10(앞부분만 같음)", dict(cs='"P1-10 (진행 중)"')), ("값 빈 칸", dict(cs='')),
                          ("앞머리에 current_step 없음", dict()), ("본문에만 current_step", dict(body='\ncurrent_step: "P1-1"\n')),
                          ("앞머리 없음", dict(raw='current_step: "P1-1"\n')), ("앞머리 안 닫힘", dict(raw='---\nphase: EXECUTE\n'))]:
            state(d, **kw)
            out, err = ab()
            check(f"0.3.3 c2·c3 WAIT: {title}", out == "WAIT P1-1 P1-2\n", repr(out) + err)
        (d / "docs/refactor/STATE.md").unlink()
        out, err = ab()
        check("0.3.3 c2 WAIT: STATE.md 없음", out == "WAIT P1-1 P1-2\n", repr(out) + err)
        for title, kw, want in [("묶음 P1-1~P1-2", dict(cs='"P1-1~P1-2 (묶음)"'), "OPEN P1-1 P1-2\n" + M + G),
                                ("따옴표 없음·소문자", dict(cs='p1-1 (진행 중)'), "OPEN P1-1\n" + M),
                                ("CRLF", dict(cs='"P1-1 (진행 중)"', crlf=True), "OPEN P1-1\n" + M),
                                ("값 앞뒤 공백", dict(cs='   "P1-1 (진행 중)"   '), "OPEN P1-1\n" + M),
                                ("쉼표 구분", dict(cs='P1-2,P1-1'), "OPEN P1-1 P1-2\n" + M + G),
                                ("첫 줄 BOM", dict(raw="﻿" + head + 'current_step: "P1-2"\n---\n'), "OPEN P1-2\n" + G)]:
            state(d, **kw)
            out, err = ab()
            check(f"0.3.3 c3 열림: {title}", out == want, repr(out) + err)
        # 허용 파일에 없는 단계가 실행 중이면 그 단계는 열리지 않는다(허용 파일 ∩ 열린 단계 ∩ current_step)
        allow(d, "P1-2\n")
        state(d, '"P1-1 (진행 중)"')
        out, err = ab()
        check("0.3.3 c2 허용 파일 밖 단계가 실행 중 → WAIT P1-2", out == "WAIT P1-2\n", repr(out) + err)
        # 다른 상태는 그대로(SHUT·UNKNOWN·ALL·NONE)
        for data, want in [("P1-3\n", "SHUT P1-3\n"), ("P9-9\n", "UNKNOWN P9-9\n"), (" \n", "ALL\n")]:
            allow(d, data)
            out, err = ab()
            check(f"0.3.3 c2 다른 상태 그대로: {data.strip() or '공백'}", out == want, repr(out) + err)

        # c4 approved 꼴 · rl_protected_dirty: 경로는 0.3.2 와 같다(승인된 카드 전부), 상태 줄만 새 규칙
        allow(d, "P1-1 P1-2\n")
        state(d, '"-"')
        out, err = libcall(d, 'rl_allow_baseline "$R" approved')
        check("0.3.3 c4 approved 꼴: WAIT 여도 승인된 카드 경로 전부", out == "WAIT P1-1 P1-2\n" + M + G, repr(out) + err)
        state(d, '"P1-1 (진행 중)"')
        out, err = libcall(d, 'rl_allow_baseline "$R" approved')
        check("0.3.3 c4 approved 꼴: OPEN P1-1 이어도 경로는 좁히지 않음", out == "OPEN P1-1\n" + M + G, repr(out) + err)
        for f in ("money.test.ts", "other.test.ts", "golden/d.json"):
            lf(d / "tests/baseline" / f, "바뀜\n")
        for cs in ('"-"', '"P1-1 (진행 중)"'):
            state(d, cs)
            out, err = libcall(d, 'rl_protected_dirty "$P" "$R" | cut -f1')
            check(f"0.3.3 c4 rl_protected_dirty({cs}): 0.3.2 와 같이 other 만 보고",
                  "other.test.ts" in out and "money.test.ts" not in out and "golden/d.json" not in out, out + err)
        for f in ("money.test.ts", "other.test.ts", "golden/d.json"):
            lf(d / "tests/baseline" / f, "x\n")

        # d2 현황(status·board) 문구: WAIT · OPEN · 빈 파일(0바이트·공백만 = ALL)
        allow(d, "P1-1 P1-2\n")
        state(d, '"-"')
        st, bd = sh("refactor-status", d), sh("refactor-board", d, str(d))
        check("0.3.3 d2 현황 WAIT 문구", "🔒 기준선 허용: 단계 P1-1 P1-2 — 그 단계를 실행하는 동안만 열림(지금은 닫힘)." in st
              and "실행 중 — 열림" not in st and "허용 파일이 남아 있음" not in st, st[-400:])
        check("0.3.3 d2 현황표 WAIT 표시", "🔒허용파일 단계 P1-1 P1-2 실행 중일 때만 열림(지금은 닫힘)" in bd and "⚠허용파일" not in bd, bd[-400:])
        state(d, '"P1-2 (진행 중)"')
        st, bd = sh("refactor-status", d), sh("refactor-board", d, str(d))
        check("0.3.3 d2 현황 OPEN 문구(실행 중 단계만)", "🔓 기준선 허용 파일(.allow-baseline-edit): 단계 P1-2 실행 중 — 열림(끝나면 저절로 닫힘)." in st, st[-400:])
        check("0.3.3 d2 현황표 OPEN 표시", "🔓단계 P1-2 실행 중 — 열림(끝나면 저절로 닫힘)" in bd, bd[-400:])
        for title, data in [("0바이트", ""), ("공백만", " \n\r\n")]:
            allow(d, data)
            st, bd = sh("refactor-status", d), sh("refactor-board", d, str(d))
            check(f"0.3.3 d2 현황 빈 파일({title}) 전용 경고",
                  "⚠️ 빈 기준선 허용 파일 — 기준선 전부가 열려 있고 저절로 닫히지 않습니다. 단계 목록으로 바꾸기: /refactor:approve 허용 <ID> · 닫기: /refactor:approve 허용 닫기" in st
                  and "허용 파일이 남아 있음" not in st, st[-400:])
            check(f"0.3.3 d2 현황표 빈 파일({title}) 표시", "⚠허용파일 비어 있음(기준선 전부 열림·저절로 안 닫힘)" in bd, bd[-400:])
        # 다른 허용 파일(.allow-migration-edit)은 예전 범용 문구 그대로
        (d / "docs/refactor/.allow-baseline-edit").unlink()
        lf(d / "docs/refactor/.allow-migration-edit", "")
        st = sh("refactor-status", d)
        check("0.3.3 d2 현황 마이그레이션 허용 파일은 예전 문구", "허용 파일이 남아 있음: .allow-migration-edit" in st and "빈 기준선" not in st, st[-400:])
    finally:
        shutil.rmtree(d, ignore_errors=True)

    # f1(검사 보완 F1): current_step 의 같은 묶음 숫자 범위 "P1-1~P1-5" 는 사이 단계까지 펼친다(묶음 다름·끝이 숫자 아님·거꾸로·99칸 넘음은 안 펼침)
    plan5 = "# 계획서\n" + "".join(
        f"\n### [P1-{i}] 단계 {i}\n- **종류**: 🛠 개선\n- **깨질 것으로 예상되는 기준선**: `tests/baseline/s{i}.test.ts`\n- **승인**: [ ] 승인\n- **완료**: [ ] 완료\n"
        for i in range(1, 6))
    d = project(plan=plan5)
    try:
        (d / "tests/baseline").mkdir(parents=True)
        for i in range(1, 6):
            lf(d / f"tests/baseline/s{i}.test.ts", "x\n")
        subprocess.run(["git", "init", "-q", str(d)], check=True)
        g(d, "add", "-A"); g(d, "commit", "-qm", "i")
        approve(d, "P1-1 P1-2 P1-3 P1-4 P1-5")
        allow(d, "P1-1 P1-2 P1-3 P1-4 P1-5\n")
        state(d, '"P1-1~P1-5 (코드 커밋 완료 · 기준선 갱신 대기)"')
        out, err = libcall(d, 'rl_allow_baseline "$R"')
        check("0.3.3 f1 범위 P1-1~P1-5 → 5장 열림 + 경로 5개",
              out == "OPEN P1-1 P1-2 P1-3 P1-4 P1-5\n" + "".join(f"tests/baseline/s{i}.test.ts\n" for i in range(1, 6)), repr(out) + err)
        for title, cs, want in [("물결 앞뒤 공백 P1-2 ~ P1-4", '"P1-2 ~ P1-4"', "OPEN P1-2 P1-3 P1-4"),
                                ("소문자 p1-1~p1-3", '"p1-1~p1-3"', "OPEN P1-1 P1-2 P1-3"),
                                ("범위 + 낱말 P1-1~P1-2, P1-5", '"P1-1~P1-2, P1-5 (진행 중)"', "OPEN P1-1 P1-2 P1-5"),
                                ("묶음 다름 P1-1~P2-3 → 안 펼침", '"P1-1~P2-3"', "OPEN P1-1"),
                                ("거꾸로 P1-3~P1-1 → 안 펼침", '"P1-3~P1-1"', "OPEN P1-1 P1-3"),
                                ("끝이 숫자 아님 P1-1~P1-3A → 안 펼침", '"P1-1~P1-3A"', "OPEN P1-1"),
                                ("99칸 넘음 P1-1~P1-200 → 안 펼침", '"P1-1~P1-200"', "OPEN P1-1"),
                                ("끝 없음 P1-1~", '"P1-1~"', "OPEN P1-1"),
                                ("앞 없음 ~P1-3", '"~P1-3"', "OPEN P1-3"),
                                ("범위 밖만 P1-6~P1-9 → WAIT", '"P1-6~P1-9"', "WAIT P1-1 P1-2 P1-3 P1-4 P1-5")]:
            state(d, cs)
            out, err = libcall(d, 'rl_allow_baseline "$R" | head -n 1')
            check(f"0.3.3 f1 {title}", out == want + "\n", repr(out) + err)
        # K6①: 99칸 경계 — P1-1~P1-100(차 99) 은 펼침, P1-1~P1-101(차 100) 은 안 펼침
        for cs, want in [('"P1-1~P1-100"', "OPEN P1-1 P1-2 P1-3 P1-4 P1-5"), ('"P1-1~P1-101"', "OPEN P1-1")]:
            state(d, cs)
            out, err = libcall(d, 'rl_allow_baseline "$R" | head -n 1')
            check(f"0.3.3 K6① 범위 경계 {cs}", out == want + "\n", repr(out) + err)
        # K6②: 앞자리 0(P1-08~P1-10)은 8진수로 읽지 않는다 — 표준오류 0바이트 + 열린 단계와 안 맞아 WAIT
        state(d, '"P1-08~P1-10"')
        out, err = libcall(d, 'rl_allow_baseline "$R"')
        check("0.3.3 K6② P1-08~P1-10 → 오류 없이 WAIT", out == "WAIT P1-1 P1-2 P1-3 P1-4 P1-5\n" and err == "", repr(out) + repr(err))
        allow(d, "P1-1 P1-3\n")
        state(d, '"P1-1~P1-3"')
        out, err = libcall(d, 'rl_allow_baseline "$R"')
        check("0.3.3 f1 허용 P1-1 P1-3 + 범위 P1-1~P1-3 → 허용 파일에 있는 것만",
              out == "OPEN P1-1 P1-3\ntests/baseline/s1.test.ts\ntests/baseline/s3.test.ts\n", repr(out) + err)
    finally:
        shutil.rmtree(d, ignore_errors=True)


PLAN_033 = """# 계획서

### [P1-1] 금액 계산
- **종류**: 🛠 개선
- **깨질 것으로 예상되는 기준선**: `tests/baseline/money.test.ts` 중 "금액" 항목
- **승인**: [ ] 승인
- **완료**: [ ] 완료

### [P1-2] 주문 주소
- **종류**: 🛠 개선
- **깨질 것으로 예상되는 기준선**: `./tests/baseline/golden/d.json`
- **승인**: [ ] 승인
- **완료**: [ ] 완료

### [P1-3] 아직 승인 안 함
- **종류**: 🛠 개선
- **깨질 것으로 예상되는 기준선**: `tests/baseline/x.test.ts`
- **승인**: [ ] 승인
- **완료**: [ ] 완료

### [P1-4] 기준선 안 바꿈
- **종류**: 🔧 리팩토링
- **깨질 것으로 예상되는 기준선**: 없음
- **승인**: [ ] 승인
- **완료**: [ ] 완료

### [P1-5] 경로를 안 적음
- **종류**: 🛠 개선
- **깨질 것으로 예상되는 기준선**: 금액 테스트 일부
- **승인**: [ ] 승인
- **완료**: [ ] 완료

### [P1-6] 끝난 단계
- **종류**: 🛠 개선
- **깨질 것으로 예상되는 기준선**: `tests/baseline/done.test.ts`
- **승인**: [ ] 승인
- **완료**: [ ] 완료

### [P2-1] 같은 번호
- **깨질 것으로 예상되는 기준선**: `tests/baseline/a.ts`
- **승인**: [ ] 승인
- **완료**: [ ] 완료

### [P2-1] 같은 번호 둘째
- **깨질 것으로 예상되는 기준선**: `tests/baseline/b.ts`
- **승인**: [ ] 승인
- **완료**: [ ] 완료
"""


def _lib033(d, expr, extra_env=None):
    """lib 를 직접 불러 expr 실행(LC_ALL=C 먼저 — 맥의 awk). P=프로젝트 R=docs/refactor"""
    lib = (ROOT / "plugins/refactor/scripts/refactor-lib.sh").as_posix()
    e = env()
    if extra_env:
        e.update(extra_env)
    r = subprocess.run([BASH, "-c", 'LC_ALL=C; export LC_ALL; eval "$(tr -d \'\\r\' < "$1")"; P=$2; R=$2/docs/refactor; ' + expr, "x", lib, d.as_posix()],
                       capture_output=True, env=e, timeout=90)
    return r.stdout.decode("utf-8", "replace").replace("\r", ""), r.stderr.decode("utf-8", "replace")


def _log033(d):
    p = d / "docs/refactor/APPROVALS.log"
    return p.read_text(encoding="utf-8") if p.exists() else ""


def _done033(d, cid):
    pp = d / "docs/refactor/REFACTOR_PLAN.md"
    t = pp.read_text(encoding="utf-8")
    i = t.index(f"### [{cid}]")
    lf(pp, t[:i] + t[i:].replace("- **완료**: [ ] 완료", "- **완료**: [x] 완료 (2026-10-03)", 1))


def check_approve_allow_033(check):
    """0.3.3 A: /refactor:approve 허용 …(A1~A4 · a1~a9) · 승인 화면의 고칠 기준선 안내(A5 · b1) · 마무리·다시 때 허용 파일 정리(A6·A7 · d1) ·
    허용·푸시 줄이 승인 상태 계산에 영향 없음(a10)."""
    af = lambda d: d / "docs/refactor/.allow-baseline-edit"
    ab = lambda d: af(d).read_bytes() if af(d).exists() else None   # 허용 파일 내용(없으면 None — 빨강일 때 예외로 죽지 않게)
    intact = lambda d: _lib033(d, 'rl_log_intact "$R" && echo yes')[0] == "yes\n"
    done_ok = lambda d: _lib033(d, 'rl_done_confirmed "$R" && echo yes')[0] == "yes\n"

    def states(d, log="$R/APPROVALS.log"):
        out, _ = _lib033(d, f'rl_cards "$R/REFACTOR_PLAN.md" "{log}"')
        return out

    def mk(close=True):
        # 0.3.4: 승인하면 기준선 허용이 저절로 열린다(§9) → 허용·허용 닫기 명령 자체를 시험하려고 승인 직후 한 번 닫는다(기록의 자동 허용 줄 1개는 남음)
        d = project(plan=PLAN_033)
        out = approve(d, "P1-1 P1-2 P1-4 P1-5 P1-6")
        _done033(d, "P1-6")
        if close:
            approve(d, "허용 닫기")
        return d, out

    def sec(out, cid):   # 승인 화면에서 그 카드의 줄들
        key = f"승인함: [{cid}]"
        return out.split(key, 1)[1].split("✅ 승인함")[0].split("📋")[0] if key in out else ""

    # b1 승인 화면: 경로 있는 카드 → 🔓 / "없음" → 줄 없음 / 글만 있고 백틱 0 → ⚠️ · (0.3.4 §9) 경로 있는 카드만 허용이 저절로 열림
    d, out = mk(close=False)
    try:
        W_OPEN = " — 이 단계를 실행하는 동안 열립니다(닫기: /refactor:approve 허용 닫기)"
        check("0.3.3 b1 승인 화면: 경로 있는 카드 → 🔓 줄",
              "   🔓 고칠 기준선: `tests/baseline/money.test.ts`" + W_OPEN in sec(out, "P1-1")
              and "🔓 고칠 기준선: `tests/baseline/golden/d.json`" + W_OPEN in sec(out, "P1-2"), out)
        check("0.3.3 b1 승인 화면: '없음' 카드 → 줄 없음", sec(out, "P1-4") != "" and "🔓" not in sec(out, "P1-4") and "⚠️" not in sec(out, "P1-4"), out)
        check("0.3.3 b1 승인 화면: 백틱 경로 0 → ⚠️ 줄",
              "   ⚠️ '깨질 것으로 예상되는 기준선' 칸에 백틱 경로가 없어 이 단계는 기준선을 고칠 수 없습니다 — 필요하면 계획서를 고치게 하세요" in sec(out, "P1-5")
              and "🔓" not in sec(out, "P1-5"), out)
        check("0.3.3 b1 승인하면 경로 있는 카드만 허용이 열림(0.3.4 §9 — 예전: 열지 않음)", ab(d) == b"P1-1 P1-2 P1-6\n"
              and _log033(d).count(" | 허용 | ") == 1 and _log033(d).endswith(" | 허용 | P1-1 P1-2 P1-6 | - | 사용자가 /refactor:approve 로 실행\n"), _log033(d)[-300:])
        approve(d, "허용 닫기")   # 아래 a1~ 은 허용 명령 자체를 본다(mk() 기본과 같게)

        # a1 허용 P1-1
        before = states(d)
        out = approve(d, "허용 P1-1")
        lt = _log033(d)
        check("0.3.3 a1 허용 P1-1: 파일 'P1-1\\n'", af(d).exists() and ab(d) == b"P1-1\n", out)
        check("0.3.3 a1 기록에 허용 줄 1개(+ 승인 때 자동 허용 줄 1개)", lt.count(" | 허용 | ") == 2 and lt.endswith(" KST | 허용 | P1-1 | - | 사용자가 /refactor:approve 로 실행\n"), lt[-300:])
        check("0.3.3 a1 봉인 일치", intact(d))
        check("0.3.3 a1 승인 상태 그대로", states(d) == before, states(d) + "\n---\n" + before)
        check("0.3.3 a1 출력", "🔓 기준선 허용: P1-1 — 이 단계를 실행하는 동안 카드에 적힌 기준선만 고칠 수 있습니다(단계가 모두 끝나면 저절로 닫힘)" in out
              and "   [P1-1] 고칠 기준선: `tests/baseline/money.test.ts`" in out and "다음: /refactor:go" in out, out)
        # a3 이미 있는 ID 에 더함
        out = approve(d, "허용 P1-2")
        check("0.3.3 a3 'P1-1' 에 허용 P1-2 → 'P1-1 P1-2'", ab(d) == b"P1-1 P1-2\n" and _log033(d).count(" | 허용 | ") == 3
              and _log033(d).endswith(" | 허용 | P1-1 P1-2 | - | 사용자가 /refactor:approve 로 실행\n") and intact(d), out)
        snap = rdir_files(d)
        out = approve(d, "허용 P1-2")
        check("0.3.3 a3 이미 허용된 것을 다시 → 아무것도 안 바뀜", rdir_files(d) == snap and "이미 허용돼 있습니다: P1-1 P1-2" in out, out)
        # a4 빈 파일(전부 허용)에서 좁힘
        af(d).write_bytes(b"")
        out = approve(d, "허용 P1-1")
        check("0.3.3 a4 빈 파일 → 'P1-1' 로 좁혀짐 + 알림", ab(d) == b"P1-1\n" and "이 단계들로 좁혔습니다" in out, out)
        # 지금 대상이 아닌 ID(승인 안 됨)는 빼고 알림
        af(d).write_bytes(b"P1-3 p1-1 # memo\n")
        out = approve(d, "허용 P1-2")
        check("0.3.3 a3 대상이 아닌 옛 ID 는 빠짐", ab(d) == b"P1-1 P1-2\n" and "허용 파일에 있던 P1-3 은(는) 지금 허용 대상이 아니라 뺐습니다" in out, out)

        # a6 닫기: ID 파일 / 빈 파일 / 없음 — 기록 줄 수 그대로
        n0 = _log033(d).count("\n")
        out = approve(d, "허용 닫기")
        check("0.3.3 a6 허용 닫기(ID 파일) → 지워짐", not af(d).exists() and "기준선 허용을 닫았습니다" in out, out)
        af(d).write_bytes(b"")
        out = approve(d, "ALLOW close")
        check("0.3.3 a6 ALLOW close(빈 파일) → 지워짐", not af(d).exists() and "기준선 허용을 닫았습니다" in out, out)
        out = approve(d, "허용 닫기")
        check("0.3.3 a6 허용 닫기(없음) → 이미 닫혀", not af(d).exists() and "이미 닫혀 있습니다" in out, out)
        check("0.3.3 a6 닫기는 기록에 줄을 남기지 않음", _log033(d).count("\n") == n0 and intact(d), _log033(d)[-300:])

        # a7 섞어 쓰기 거절(아무것도 안 바뀜)
        af(d).write_bytes(b"P1-1\n")
        for args in ["P1-1 허용", "허용 baseline", "허용 마무리", "허용 확인", "허용 닫기 P1-1", "닫기", "닫기 허용", "허용 보류 P1-1",
                     "보류 허용 P1-1", "허용 허용 P1-1", "허용 닫기 닫기", "P1-1 닫기"]:
            snap = rdir_files(d)
            out = approve(d, args)
            check(f"0.3.3 a7 거절: {args!r}", rdir_files(d) == snap and "아무것도 바꾸지 않았습니다" in out, out)

        # a8 같은 결과 다른 철자
        for args, want in [("allow p1-1", b"P1-1\n"), ("ALLOW P1-1", b"P1-1\n"), ("Allow P1-1", b"P1-1\n"), ("  허용   p1-1  ", b"P1-1\n"),
                           ("허용 P1-1,P1-2", b"P1-1 P1-2\n"), ("허용\nP1-1\nP1-2", b"P1-1 P1-2\n"), ("허용 P1-1 P1-1", b"P1-1\n"),
                           ("허용 P1", b"P1-1 P1-2\n"), ("허용 P1-2 P1-1", b"P1-2 P1-1\n")]:
            af(d).unlink(missing_ok=True)
            out = approve(d, args)
            got = ab(d) if af(d).exists() else None
            check(f"0.3.3 a8 {args!r} → {want!r}", got == want and intact(d), f"{got!r} {out}")
        # a9 ID 없이 '허용' → 대상 조건을 만족하는 카드 전부(P1-6 완료·P1-4 없음·P1-5 백틱 0·P1-3 미승인·P2-1 같은 번호는 빠짐)
        af(d).unlink(missing_ok=True)
        out = approve(d, "허용")
        check("0.3.3 a9 '허용'(ID 없음) → 대상 전부", af(d).exists() and ab(d) == b"P1-1 P1-2\n", out)
        # 승인 뒤 카드가 바뀐 단계는 대상이 아님(파일에 있던 그 ID 도 빠짐)
        pp = d / "docs/refactor/REFACTOR_PLAN.md"
        lf(pp, pp.read_text(encoding="utf-8").replace("### [P1-2] 주문 주소", "### [P1-2] 주문 주소 바뀜"))
        snap = rdir_files(d)
        out = approve(d, "허용 P1-2")
        check("0.3.3 a2 카드 바뀐 단계 → 거절", rdir_files(d) == snap and "승인 뒤 카드가 바뀐 단계라 허용하지 않았습니다: [P1-2]" in out, out)
        out = approve(d, "허용 P1-1")
        check("0.3.3 a2 카드 바뀐 단계는 다음 쓰기 때 빠짐", ab(d) == b"P1-1\n" and "P1-2 은(는) 지금 허용 대상이 아니라 뺐습니다" in out, out)
    finally:
        shutil.rmtree(d, ignore_errors=True)

    # a2 대상이 아닌 ID: 파일 안 생김 · 기록 안 바뀜 · 까닭 문구 각각
    d, _ = mk()
    try:
        for args, msg in [("허용 P1-3", "승인되지 않은 단계라 허용하지 않았습니다: [P1-3]"),
                          ("허용 P9-9", "계획서에 없는 단계 번호: P9-9"),
                          ("허용 P1-6", "이미 완료된 단계라 허용이 필요 없습니다: [P1-6]"),
                          ("허용 P1-4", "[P1-4] 기준선 안 바꿈 — 기준선을 바꾸지 않는 단계라 허용이 필요 없습니다"),
                          ("허용 P1-5", "[P1-5] 경로를 안 적음 — '깨질 것으로 예상되는 기준선' 칸에 백틱 경로가 없어 허용하지 않았습니다"),
                          ("허용 P2-1", "[P2-1] 같은 번호의 단계가 2개"),
                          ("허용 P3", "계획서에 P3 묶음의 단계가 없습니다"),
                          ("허용 엉뚱", "알아듣지 못한 입력: 엉뚱")]:
            snap = rdir_files(d)
            out = approve(d, args)
            check(f"0.3.3 a2 {args!r} → 안 바뀜 + 까닭", not af(d).exists() and rdir_files(d) == snap and msg in out, out)
        # A3 H9 알아듣지 못한 입력은 한 번만 알린다(ID 없음·ID 있음 둘 다)
        for args in ("허용 엉뚱", "허용 엉뚱 P1-1"):
            out = approve(d, args)
            check(f"0.3.3 A3 H9 {args!r} → '알아듣지 못한 입력' 한 번", out.count("알아듣지 못한 입력") == 1, out)
        af(d).unlink(missing_ok=True)
        out = approve(d, "허용 P1-1 P1-3")
        check("0.3.3 a2 섞이면 대상만 적고 나머지는 까닭", ab(d) == b"P1-1\n" and "승인되지 않은 단계라 허용하지 않았습니다: [P1-3]" in out, out)
        af(d).unlink(missing_ok=True)

        # a5 --from-hook 없음 · 봉인 깨짐 → 아무것도 안 바뀜
        snap = rdir_files(d)
        out, rc = approve_rc(d, "허용 P1-1", from_hook=False)
        check("0.3.3 a5 --from-hook 없음 → 안 바뀜", rc == 0 and rdir_files(d) == snap and not af(d).exists(), out)
        lg = d / "docs/refactor/APPROVALS.log"
        lg.write_bytes(lg.read_bytes() + "2026-10-03 10:00 KST | 승인 | P1-3 | card=1.2 | 손으로\n".encode("utf-8"))
        snap = rdir_files(d)
        out = approve(d, "허용 P1-1")
        check("0.3.3 a5 봉인 깨짐 → 안 바뀜", rdir_files(d) == snap and not af(d).exists() and "처리하지 않았습니다" in out, out)
        out = approve(d, "허용")
        check("0.3.3 a5 봉인 깨짐 + '허용'(ID 없음) → 안 바뀜", rdir_files(d) == snap and not af(d).exists(), out)
        af(d).write_bytes(b"P1-1\n")
        out = approve(d, "허용 닫기")
        check("0.3.3 a6 봉인이 깨져 있어도 닫기는 됨(안전한 쪽)", not af(d).exists() and lg.read_bytes() == snap["APPROVALS.log"], out)
    finally:
        shutil.rmtree(d, ignore_errors=True)

    # a9 대상 0개: 파일 안 만들고 까닭
    d = project(plan=PLAN_033)
    try:
        for title in ("승인 기록 없음", "기준선 안 바꾸는 단계만 승인"):
            if title != "승인 기록 없음":
                approve(d, "P1-4")
            snap = rdir_files(d)
            out = approve(d, "허용")
            check(f"0.3.3 a9 '허용' 대상 0개({title}) → 안 만듦", not af(d).exists() and rdir_files(d) == snap
                  and "지금 승인돼 있고 기준선을 고치는 단계가 없습니다" in out, out)
    finally:
        shutil.rmtree(d, ignore_errors=True)

    # a10 허용·푸시 줄이 든 기록으로 계산한 승인 상태 = 그 줄이 없을 때와 같음(0.3.2 의 읽기 규칙 그대로)
    d, _ = mk()
    try:
        approve(d, "보류 P1-5")
        approve(d, "허용 P1-1")
        lg = d / "docs/refactor/APPROVALS.log"
        lg.write_bytes(lg.read_bytes() + "2026-10-03 11:00 KST | 푸시 | feat/x | - | 사용자가 /refactor:approve 로 실행\n".encode("utf-8"))
        lines = lg.read_text(encoding="utf-8").splitlines(keepends=True)
        lf(d / "docs/refactor/log-filtered", "".join(l for l in lines if " | 허용 | " not in l and " | 푸시 | " not in l))
        full, filt = states(d), states(d, "$R/log-filtered")
        check("0.3.3 a10 허용·푸시 줄은 승인 상태 계산에 영향 없음", full == filt and "\x1fapproved" in full and "\x1fheld" in full
              and len(lines) - (d / "docs/refactor/log-filtered").read_text(encoding="utf-8").count("\n") == 3, full + "\n---\n" + filt)
    finally:
        shutil.rmtree(d, ignore_errors=True)

    # d1 마무리: 허용 파일(ID·빈 파일)을 지우고 알림 · 기록 마지막 줄 = 마무리 · 마이그레이션 허용 파일은 남기고 알림 · .allow-env 는 그대로
    d = project(plan=PLAN_033)
    try:
        approve(d, "P1-1")
        approve(d, "허용 P1-1")
        _done033(d, "P1-1")
        (d / "docs/refactor/.allow-migration-edit").write_bytes(b"")
        lf(d / "docs/refactor/.allow-env", "DATABASE_URL=db.dev.example\n")
        out = approve(d, "마무리")
        last = _log033(d).splitlines()[-1]
        check("0.3.3 d1 마무리 → 허용 파일 지움 + 알림", not af(d).exists() and "🔒 리팩토링이 끝나 기준선 허용 파일(.allow-baseline-edit)을 지웠습니다." in out, out)
        check("0.3.3 d1 마무리 줄이 기록의 마지막 줄 · 마무리 인정", last.endswith(" KST | 마무리 | PROJECT | - | 사용자가 /refactor:approve 로 실행") and done_ok(d), last)
        check("0.3.3 d1 마이그레이션 허용 파일은 남기고 알림", (d / "docs/refactor/.allow-migration-edit").exists()
              and "마이그레이션 허용 파일(.allow-migration-edit)이 남아 있습니다" in out, out)
        check("0.3.3 d1 .allow-env 는 건드리지도 알리지도 않음", (d / "docs/refactor/.allow-env").exists() and ".allow-env" not in out, out)
        # 마무리 뒤: 허용은 대상이 없어 안 씀, 닫기는 기록에 줄을 남기지 않음 → 마무리 인정 그대로
        n0 = _log033(d).count("\n")
        approve(d, "허용 P1-1")
        af(d).write_bytes(b"P1-1\n")
        approve(d, "허용 닫기")
        check("0.3.3 d1 마무리 뒤 허용·닫기 → 기록 그대로, 마무리 인정 그대로", _log033(d).count("\n") == n0 and done_ok(d) and not af(d).exists(), _log033(d)[-300:])
    finally:
        shutil.rmtree(d, ignore_errors=True)
    d = project(plan=PLAN_033)
    try:
        af(d).write_bytes(b"")
        out = approve(d, "마무리")
        check("0.3.3 d1 마무리 → 빈 허용 파일도 지움", not af(d).exists() and "기준선 허용 파일(.allow-baseline-edit)을 지웠습니다" in out
              and "마이그레이션" not in out and done_ok(d), out)
    finally:
        shutil.rmtree(d, ignore_errors=True)

    # d1 /refactor:go 다시 → 허용 파일 지움 + 표준출력 한 줄(재설정 줄을 남길 때)
    d = project(plan=PLAN_033)
    try:
        approve(d, "P1-1")
        approve(d, "허용 P1-1")
        line = "[Vibe Refactor] 승인이 재설정되어 지난 기준선 허용 파일(.allow-baseline-edit)을 지웠습니다."
        so, se, rc, _ = hook("turn", d, {"session_id": "s1", "prompt": "/refactor:go 다시 plan"})
        check("0.3.3 d1 go 다시 → 허용 파일 지움 + 한 줄", rc == 0 and not af(d).exists() and line in so.splitlines(), so + se)
        af(d).write_bytes(b"")
        so, se, rc, _ = hook("turn", d, {"session_id": "s1", "prompt": "/refactor:go 다시 plan"})
        check("0.3.3 d1 go 다시 → 빈 허용 파일도 지움", rc == 0 and not af(d).exists() and line in so, so + se)
        so, se, rc, _ = hook("turn", d, {"session_id": "s1", "prompt": "/refactor:go 다시 plan"})
        check("0.3.3 d1 go 다시(허용 파일 없음) → 알림 없음", rc == 0 and "기준선 허용 파일" not in so and "마이그레이션 허용 파일" not in so, so)
        # A3 H8 다시 때 마이그레이션 허용 파일은 지우지 않고 한 줄 알림
        (d / "docs/refactor/.allow-migration-edit").write_bytes(b"")
        so, se, rc, _ = hook("turn", d, {"session_id": "s1", "prompt": "/refactor:go 다시 plan"})
        check("0.3.3 A3 H8 go 다시 → 마이그레이션 허용 파일은 남기고 한 줄",
              rc == 0 and (d / "docs/refactor/.allow-migration-edit").exists()
              and "[Vibe Refactor] 마이그레이션 허용 파일(.allow-migration-edit)이 남아 있습니다 — 필요 없으면 사람이 지웁니다." in so.splitlines(), so + se)
        (d / "docs/refactor/.allow-migration-edit").unlink()
        af(d).write_bytes(b"P1-1\n")
        so, se, rc, _ = hook("turn", d, {"session_id": "s1", "prompt": "/refactor:go"})
        check("0.3.3 d1 그냥 go 는 허용 파일을 지우지 않음", af(d).exists() and "기준선 허용 파일" not in so, so)
    finally:
        shutil.rmtree(d, ignore_errors=True)


def check_approve_push_033(check):
    """0.3.3 A: /refactor:approve 푸시(A8 · p6·p7) · 입력 훅이 허락을 그 차례에만 두는 것(A9 · p8)."""
    g = lambda d, *a: subprocess.run(["git", "-C", str(d), "-c", "user.email=t@example.com", "-c", "user.name=t", *a],
                                     check=True, capture_output=True)
    pf = lambda d, sid="s1": d / "docs/refactor" / f".turn-push.{sid}"

    def ap(d, args, sid="s1", from_hook=True):
        e = env()
        e["GIT_CEILING_DIRECTORIES"] = str(d.parent)   # 임시 폴더 위가 우연히 git 저장소여도 "저장소 아님" 시험이 흔들리지 않게
        e.pop("REFACTOR_TURN_SID", None)
        if sid is not None:
            e["REFACTOR_TURN_SID"] = sid
        r = subprocess.run([BASH, str(RUN), "refactor-approve", str(d), *(("--from-hook",) if from_hook else ())],
                           input=args.encode("utf-8"), capture_output=True, env=e, timeout=90)
        return r.stdout.decode("utf-8", "replace") + r.stderr.decode("utf-8", "replace")

    def mkgit(branch="feat/x"):
        d = project(plan=PLAN_033)
        subprocess.run(["git", "init", "-q", str(d)], check=True)
        g(d, "symbolic-ref", "HEAD", "refs/heads/main")
        g(d, "add", "-A"); g(d, "commit", "-qm", "i")
        bare = pathlib.Path(tempfile.mkdtemp(prefix="scripttest-origin-"))
        subprocess.run(["git", "init", "-q", "--bare", str(bare)], check=True)
        g(d, "remote", "add", "origin", str(bare))
        g(d, "push", "-q", "origin", "main")
        if branch:
            g(d, "checkout", "-q", "-b", branch)
        return d, bare

    intact = lambda d: _lib033(d, 'rl_log_intact "$R" && echo yes')[0] == "yes\n"
    done_ok = lambda d: _lib033(d, 'rl_done_confirmed "$R" && echo yes')[0] == "yes\n"

    # p7 작업 가지 위 푸시·push·PUSH → .turn-push.<세션ID> 2줄 · 기록 1줄 · 봉인 일치
    d, bare = mkgit()
    try:
        for args in ("푸시", "push", "PUSH", " 푸시 "):
            n0 = _log033(d).count("\n")
            out = ap(d, args)
            lines = pf(d).read_text(encoding="utf-8").split("\n") if pf(d).exists() else []
            ok_file = len(lines) == 3 and lines[0] == "push feat/x" and lines[1].isdigit() and abs(int(lines[1]) - time.time()) < 600 and lines[2] == ""
            check(f"0.3.3 p7 {args!r} → 허락 파일 2줄", ok_file, f"{lines!r} {out}")
            check(f"0.3.3 p7 {args!r} → 기록 1줄 · 봉인 일치", _log033(d).count("\n") == n0 + 1
                  and _log033(d).endswith(" KST | 푸시 | feat/x | - | 사용자가 /refactor:approve 로 실행\n") and intact(d), _log033(d)[-300:])
            check(f"0.3.3 p7 {args!r} → 출력", "✅ push 허락: 작업 가지 feat/x 를 이번 차례에만 올릴 수 있습니다(다음 입력부터 다시 막힘 · 30분 안). "
                  "올리는 명령: git push -u origin feat/x" in out, out)
            pf(d).unlink(missing_ok=True)
        out = ap(d, "푸시", sid="other-sid_2")
        check("0.3.3 p7 세션 ID 가 파일 이름에", pf(d, "other-sid_2").exists() and not pf(d).exists(), out)
        pf(d, "other-sid_2").unlink(missing_ok=True)

        # A3 H3 허락 화면에 올라갈 것: 원격 origin 에 없는 커밋(최근 것부터 최대 5줄) · 커밋 안 된 변경(docs/refactor 는 빼고 셈)
        def commits_shown(o):
            tail = o.split("올라갈 커밋", 1)[1] if "올라갈 커밋" in o else ""
            return [ln.strip() for ln in tail.split("\n")[1:] if ln.startswith("     ") and ln.strip()]
        g(d, "add", "-A"); g(d, "commit", "-qm", "기록")   # 위에서 쌓인 승인 기록 줄을 커밋
        g(d, "push", "-q", "origin", "feat/x")              # 지금까지는 원격에 있음 → 새 커밋 0개
        out = ap(d, "푸시")
        check("0.3.3 A3 H3 새 커밋 0개 → '올릴 새 커밋이 없습니다'", "   (올릴 새 커밋이 없습니다)" in out and "올라갈 커밋" not in out
              and "커밋 안 된 변경" not in out, out)
        for i in (1, 2):
            g(d, "commit", "--allow-empty", "-qm", f"P1-{i} 단계 {i}")
        out = ap(d, "푸시")
        shown = commits_shown(out)
        check("0.3.3 A3 H3 새 커밋 2개 → 머리 줄 + 최근 것부터 2줄", "   올라갈 커밋 2개:" in out and len(shown) == 2
              and shown[0].endswith("P1-2 단계 2") and shown[1].endswith("P1-1 단계 1") and "올릴 새 커밋이 없습니다" not in out, out)
        for i in range(3, 8):
            g(d, "commit", "--allow-empty", "-qm", f"P1-{i} 단계 {i}")
        lf(d / "src.txt", "커밋 안 함\n")
        lf(d / "PLAN-note.md", "커밋 안 함\n")
        out = ap(d, "푸시")
        shown = commits_shown(out)
        check("0.3.3 A3 H3 새 커밋 7개 → 머리 줄 7 + 5줄만(최근 것부터)", "   올라갈 커밋 7개:" in out and len(shown) == 5
              and shown[0].endswith("P1-7 단계 7") and shown[4].endswith("P1-3 단계 3"), out)
        check("0.3.3 A3 H3 커밋 안 된 변경 2개 → 경고(docs/refactor 의 기록 변경은 세지 않음)",
              "   ⚠️ 커밋 안 된 변경 2개는 올라가지 않습니다." in out, out)
        (d / "src.txt").unlink(); (d / "PLAN-note.md").unlink()
        out = ap(d, "푸시")
        check("0.3.3 A3 H3 기록(docs/refactor)만 바뀜 → 경고 없음", "커밋 안 된 변경" not in out and "   올라갈 커밋 7개:" in out, out)
        pf(d).unlink(missing_ok=True)

        # A4 L3 허락 전에 안전장치와 같은 저장소 설정을 본다 — 허락 파일·기록 안 바뀜 · 주소 값은 출력하지 않음
        W_CFG = "푸시 허락으로는 올릴 수 없는 저장소 설정입니다("
        for title, setup, undo, why in [
            ("remote.origin.push 있음", ("config", "remote.origin.push", "refs/heads/feat/x:refs/heads/main"), ("config", "--unset", "remote.origin.push"), "remote.origin.push"),
            ("push.default=upstream", ("config", "push.default", "upstream"), ("config", "--unset", "push.default"), "push.default 가 upstream"),
            # git 은 push.default 값의 대소문자를 가린다 — 'Tracking' 이면 git 명령이 모두 설정 오류(128)로 멈추므로 승인 스크립트는 git 단계에서 거절한다
            ("push.default=Tracking(대문자 — git 설정 오류)", ("config", "push.default", "Tracking"), ("config", "--unset", "push.default"), None),
            ("push.default=tracking", ("config", "push.default", "tracking"), ("config", "--unset", "push.default"), "push.default 가 tracking"),
            ("origin 주소 없음", ("remote", "remove", "origin"), ("remote", "add", "origin", str(bare)), "origin 원격 주소가 없음"),
        ]:
            g(d, *setup)
            snap = _log033(d)
            out = ap(d, "푸시")
            check(f"0.3.3 A4 L3 {title} → 거절 · 허락 파일·기록 안 바뀜 · 주소 안 보임",
                  (W_CFG in out and why in out if why else "push 허락을 만들지 않았습니다" in out)
                  and not pf(d).exists() and _log033(d) == snap and str(bare) not in out, out)
            g(d, *undo)
        g(d, "config", "push.default", "simple")
        out = ap(d, "푸시")
        check("0.3.3 A4 L3 push.default=simple → 허락", pf(d).exists() and W_CFG not in out and "✅ push 허락" in out, out)
        g(d, "config", "--unset", "push.default")
        pf(d).unlink(missing_ok=True)

        # p6 거절: 파일 안 생김 + 까닭 · 기록 안 바뀜
        def refused(title, args, msg, sid="s1", from_hook=True):
            snap = _log033(d)
            out = ap(d, args, sid=sid, from_hook=from_hook)
            check(f"0.3.3 p6 {title} → 안 만듦 + 까닭", not any(p.name.startswith(".turn-push") for p in (d / "docs/refactor").iterdir())
                  and _log033(d) == snap and msg in out, out)

        refused("--from-hook 없음", "푸시", "아무것도 바꾸지 않았습니다", from_hook=False)
        refused("푸시 P1-1(섞음)", "푸시 P1-1", "'푸시'는 단독으로 입력하세요")
        refused("P1-1 푸시(섞음)", "P1-1 푸시", "단독으로만 쓸 수 있습니다")
        refused("허용 푸시(섞음)", "허용 푸시", "단독으로만 쓸 수 있습니다")
        refused("세션 ID 없음", "푸시", "세션) 정보를 받지 못해", sid=None)
        refused("세션 ID 꼴이 이상함", "푸시", "세션) 정보를 받지 못해", sid="../x")
        g(d, "checkout", "-q", "-b", "feat+x")
        refused("가지 이름에 허용 밖 글자", "푸시", "글자가 있어 push 허락을 만들지 않았습니다")
        # 첫 글자 조건(안전장치가 허락 파일을 읽는 꼴 ^push [A-Za-z0-9_][A-Za-z0-9._/-]*$ 와 같게): '-x' 는 거절, '_x' 는 통과
        # ('.x' 는 git 이 가지로 만들지 못해 시험 불가 — symbolic-ref 가 거부. '-x' 는 symbolic-ref 로 만들 수 있다)
        g(d, "symbolic-ref", "HEAD", "refs/heads/-x")
        refused("가지 이름 첫 글자가 -", "푸시", "이 가지 이름(-x)은 허락할 수 없습니다")
        g(d, "symbolic-ref", "HEAD", "refs/heads/_x")
        out = ap(d, "푸시")
        lines = pf(d).read_text(encoding="utf-8").split("\n") if pf(d).exists() else []
        check("0.3.3 p7 가지 이름 첫 글자가 _ → 허락", lines[:1] == ["push _x"], f"{lines!r} {out}")
        pf(d).unlink(missing_ok=True)
        g(d, "checkout", "-q", "main")
        refused("기본 가지 main", "푸시", "기본 가지는 올리지 않습니다 — 작업 가지에서")
        g(d, "checkout", "-q", "-b", "master")
        refused("기본 가지 master", "push", "기본 가지는 올리지 않습니다 — 작업 가지에서")
        g(d, "checkout", "-q", "-b", "develop")
        g(d, "push", "-q", "origin", "develop")
        g(d, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/develop")
        refused("origin/HEAD 가 가리키는 가지", "PUSH", "기본 가지는 올리지 않습니다 — 작업 가지에서")
        g(d, "checkout", "-q", "--detach")
        refused("떨어진 HEAD", "푸시", "지금 가지가 없습니다")
        g(d, "checkout", "-q", "feat/x")
        lg = d / "docs/refactor/APPROVALS.log"
        keep = lg.read_bytes()
        lg.write_bytes(keep + "2026-10-03 10:00 KST | 승인 | P1-3 | card=1.2 | 손으로\n".encode("utf-8"))
        refused("봉인 깨짐", "푸시", "처리하지 않았습니다")
        lg.write_bytes(keep)
        out = ap(d, "마무리")
        check("0.3.3 p6 준비: 마무리", done_ok(d), out)
        refused("마무리 확인 뒤", "푸시", "이미 마무리되어 안전장치가 꺼져 있습니다 — 허락 없이 올릴 수 있습니다")
        check("0.3.3 p6 마무리 확인 뒤 푸시 → 마무리 인정 그대로", done_ok(d))
    finally:
        shutil.rmtree(d, ignore_errors=True)
        shutil.rmtree(bare, ignore_errors=True)
    d = project(plan=PLAN_033)
    try:
        snap = _log033(d)
        out = ap(d, "푸시")
        check("0.3.3 p6 git 저장소 아님 → 안 만듦 + 까닭", not pf(d).exists() and _log033(d) == snap and "git 저장소가 아니라" in out, out)
    finally:
        shutil.rmtree(d, ignore_errors=True)

    # p8 입력 훅: 허락은 그 세션의 다음 사람 입력 때 지움 · 알림 입력·다른 세션은 그대로 · 승인 스크립트에 세션 ID 를 넘김
    d, bare = mkgit()
    try:
        mkp = lambda: hook("turn", d, {"session_id": "s1", "prompt": "/refactor:approve 푸시"})
        so, se, rc, _ = mkp()
        check("0.3.3 p8 입력 훅의 /refactor:approve 푸시 → 허락 파일", rc == 0 and pf(d).exists() and "✅ push 허락" in so, so + se)
        hook("turn", d, {"session_id": "s1", "prompt": "고마워, 계속해 줘"})
        check("0.3.3 p8 다음 사람 입력(보통 문장) → 지워짐", not pf(d).exists())
        mkp()
        hook("turn", d, {"session_id": "s1", "prompt": "/refactor:status"})
        check("0.3.3 p8 다음 사람 입력(다른 슬래시 명령) → 지워짐", not pf(d).exists())
        mkp()
        hook("turn", d, {"session_id": "s1", "prompt": "<task-notification>\n<task-id>x</task-id>\n</task-notification>"})
        check("0.3.3 p8 알림 입력 → 그대로", pf(d).exists())
        hook("turn", d, {"session_id": "s2", "prompt": "안녕"})
        check("0.3.3 p8 다른 세션의 입력 → 그대로", pf(d).exists())
        n0 = _log033(d).count("\n")
        mkp()
        so, se, rc, _ = mkp()
        check("0.3.3 p8 /refactor:approve 푸시 두 번 연달아 → 두 번째 뒤에도 있음", pf(d).exists() and "✅ push 허락" in so
              and pf(d).read_text(encoding="utf-8").startswith("push feat/x\n") and _log033(d).count("\n") == n0 + 2, so + se)
        so, se, rc, _ = hook("turn", d, {"session_id": "s1", "prompt": "/refactor:approve"})
        check("0.3.3 p8 /refactor:approve(현황) 입력도 사람 입력 → 지워짐", not pf(d).exists(), so)
    finally:
        shutil.rmtree(d, ignore_errors=True)
        shutil.rmtree(bare, ignore_errors=True)


def check_lib_lc_all_033(check):
    """0.3.3 e1: 시험 파일(tests/*.py)에서 lib 를 bash -c 로 직접 읽어 들이는 명령 문자열은 LC_ALL=C 를 앞에(맥의 UTF-8 awk 가 지문을 다르게 잰다)."""
    pat = re.compile(r"ev" r"al\s+\\?\"\$\(\s*(?:tr|cat)\b")
    # lib 를 읽는 줄 = 위 꼴 + 같은 줄에 lib 함수(rl_…)나 lib 변수 — 안전장치 시험의 입력 문자열(x.md 를 읽어 실행하는 꼴 등)은 대상이 아니다
    uses_lib = re.compile(r"\brl_[a-z_]+|\blib(?:sh)?\b")

    def offenders(text):
        bad, seen = [], 0
        for i, line in enumerate(text.splitlines(), 1):
            m = pat.search(line)
            if m and uses_lib.search(line):
                seen += 1
                if "LC_ALL=C" not in line[:m.start()]:
                    bad.append(i)
        return bad, seen

    found, seen = {}, 0
    for f in sorted((ROOT / "tests").glob("*.py")):
        b, s = offenders(f.read_text(encoding="utf-8"))
        seen += s
        if b:
            found[f.name] = b
    check("0.3.3 e1 시험 파일의 lib 직접 읽기는 모두 LC_ALL=C 를 앞에", not found and seen >= 4, f"{found} seen={seen}")
    fake = "    r = subprocess.run([BASH, \"-c\", '" + "ev" + "al \"$(tr -d \\'\\\\r\\' < \"$1\")\"; rl_card_text \"$2\" P1-1', \"x\", lib])"
    check("0.3.3 e1 LC_ALL=C 를 뺀 가짜 문자열은 잡힘", offenders(fake) == ([1], 1), repr(offenders(fake)))
    fake2 = "    x = 'P=1; " + "ev" + "al \"$(cat \"$1\")\"; LC_ALL=C; rl_x'"
    check("0.3.3 e1 LC_ALL=C 가 뒤에만 있으면 잡힘", offenders(fake2) == ([1], 1), repr(offenders(fake2)))
    good = "    x = 'LC_ALL=C; export LC_ALL; " + "ev" + "al \"$(tr -d \\'\\\\r\\' < \"$1\")\"; rl_x'"
    check("0.3.3 e1 LC_ALL=C 가 앞에 있으면 통과", offenders(good) == ([], 1), repr(offenders(good)))
    other = "    (B, bash(_MD_RESET + \"" + "ev" + "al \\\"$(cat x.md)\\\"\")),"
    check("0.3.3 e1 lib 를 읽지 않는 안전장치 시험 입력(x.md 를 읽어 실행)은 대상 아님", offenders(other) == ([], 0), repr(offenders(other)))


def _today_kst034():
    import datetime
    return (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=9)).strftime("%Y-%m-%d")


def _git034(d, *a, check_rc=True):
    r = subprocess.run(["git", "-C", str(d), "-c", "user.email=t@example.com", "-c", "user.name=t", *a],
                       capture_output=True, env=dict(os.environ, GIT_CEILING_DIRECTORIES=str(pathlib.Path(d).parent)))
    if check_rc and r.returncode != 0:
        raise RuntimeError(f"git {a}: {r.stderr.decode('utf-8', 'replace')}")
    return r.stdout.decode("utf-8", "replace").strip()


def _ap034(d, args, from_hook=True, extra_env=None, path=None):
    """입력 훅이 부르는 것처럼(--from-hook) 승인 스크립트 실행 → (출력, 걸린 초). 임시 폴더 위가 우연히 git 저장소여도 흔들리지 않게 GIT_CEILING_DIRECTORIES."""
    e = env()
    e["GIT_CEILING_DIRECTORIES"] = str(pathlib.Path(d).parent)
    e["REFACTOR_TURN_SID"] = "s1"
    if extra_env:
        e.update(extra_env)
    if path is not None:
        e["PATH"] = path
    t0 = time.perf_counter()
    r = subprocess.run([BASH, str(RUN), "refactor-approve", str(d), *(("--from-hook",) if from_hook else ())],
                       input=args.encode("utf-8"), capture_output=True, env=e, timeout=90)
    return r.stdout.decode("utf-8", "replace") + r.stderr.decode("utf-8", "replace"), time.perf_counter() - t0


PLAN_035 = """# 계획서

### [P1-1] 금액 계산
- **종류**: 🛠 개선
- **깨질 것으로 예상되는 기준선**: `tests/baseline/money.test.ts`
- **승인**: [ ] 승인
- **완료**: [ ] 완료

### [P1-2] 주문 주소
- **종류**: 🛠 개선
- **깨질 것으로 예상되는 기준선**: `tests/baseline/golden/d.json`
- **승인**: [ ] 승인
- **완료**: [ ] 완료

### [P1-3] 금액 표시
- **종류**: 🛠 개선
- **깨질 것으로 예상되는 기준선**: `./tests/baseline/money.test.ts` 의 표시 항목
- **승인**: [ ] 승인
- **완료**: [ ] 완료
"""


def check_baseline_committed_035(check):
    """0.3.5 #1(설계서 §7 · 보완 §14 F3): 허용 파일이 남아 있는 동안에도, 완료 카드에만 속한 기준선 경로는 그 경로를 적은 완료 카드
    전부가 이미 커밋됐고(제목이 "refactor: <ID> " 인 커밋이 있음 — 경로 무관) 그 경로를 마지막으로 바꾼 커밋의 제목이 그 카드 중 하나의 것이면
    (보완 3바퀴 R2 — 둘 다) 턴 끝 알림(post-check)에서 빼지 않는다 — B1~B9 · R2 · 하위 폴더 · git 호출 수."""
    files = ("money.test.ts", "other.test.ts", "golden/d.json")
    M = "tests/baseline/money.test.ts"

    def setup(d):
        lf(d / "docs/refactor/STATE.md", STATE.replace("updated:", 'current_step: "P1-2 (진행 중)"\nupdated:'))
        (d / "tests/baseline/golden").mkdir(parents=True)
        for f in files:
            lf(d / "tests/baseline" / f, "x\n")

    def mk(ids):
        d = project(plan=PLAN_035)
        setup(d)
        _git034(d, "init", "-q")
        _git034(d, "add", "--", "docs/refactor/REFACTOR_PLAN.md", "docs/refactor/BASELINE.md", "docs/refactor/STATE.md",
                *("tests/baseline/" + f for f in files))
        _git034(d, "commit", "-qm", "i")
        approve(d, "P1-1 P1-2 P1-3")
        (d / "docs/refactor/.allow-baseline-edit").write_bytes((ids + "\n").encode("utf-8"))
        return d

    def pc(d):
        _, se, rc, _ = hook("post-check", d, {"session_id": "s1", "tool_name": "Bash"})
        return rc, se

    def flow(ids, subject, again=True):
        """턴 시작 → A(P1-1) 기준선 고침 → A 완료 표시 → (subject 가 있으면) 그 제목으로 커밋 → 다시 고침 → post-check 결과들"""
        d = mk(ids)
        try:
            hook("turn", d, {"session_id": "s1", "prompt": "/refactor:go"})
            lf(d / M, "v1\n")
            r_open = pc(d)
            _done033(d, "P1-1")
            r_done = pc(d)
            r_commit = None
            if subject is not None:
                _git034(d, "add", "--", M)
                _git034(d, "commit", "-qm", subject)
                r_commit = pc(d)
            if again:
                lf(d / M, "v2\n")
            return r_open, r_done, r_commit, pc(d)
        finally:
            shutil.rmtree(d, ignore_errors=True)

    # B1 · B2: 커밋 전에는 지금과 같이 조용(열린 카드 · 완료 표시만 한 카드)
    r_open, r_done, _, r_last = flow("P1-1 P1-2", None, again=False)
    check("0.3.5 B1 카드 A 열림 · A 기준선 고침 → 조용", r_open[0] == 0, f"{r_open}")
    check("0.3.5 B2 A 완료 표시 · 커밋 전 · 경로 바뀐 채 → 조용", r_done[0] == 0 and r_last[0] == 0, f"{r_done} {r_last}")
    # B3: A 완료 + "refactor: P1-1 …" 로 커밋 · 그 뒤 다시 바뀜 · 허용 파일에 열린 카드 P1-2 가 남음 → 알림
    r_open, r_done, r_commit, r_last = flow("P1-1 P1-2", "refactor: P1-1 금액 계산")
    check("0.3.5 B3 커밋 전까지는 조용(B1·B2 꼴 그대로)", r_open[0] == 0 and r_done[0] == 0 and r_commit[0] == 0, f"{r_open} {r_done} {r_commit}")
    check("0.3.5 B3 커밋된 앞 단계 기준선을 다시 바꿈 → post-check 알림(새로 생긴 보호 파일 변경)",
          r_last[0] == 2 and "보호된 파일(커밋된 기준선 테스트·마이그레이션)이 바뀌었습니다" in r_last[1] and M in r_last[1], f"{r_last}")
    # B4: 그 경로가 열려 있는 다른 승인 카드(P1-3)의 기준선 칸에도 있음 → 조용
    r = flow("P1-1 P1-3", "refactor: P1-1 금액 계산")
    check("0.3.5 B4 다른 열린 카드(P1-3)에도 적힌 경로 → 조용", r[3][0] == 0, f"{r}")
    # B5: 사람이 다른 제목으로 커밋(알려진 한계 — 지금과 같이 조용) · 제목 경계(P1-11 은 P1-1 이 아님)
    for title, subject in [("사람이 다른 제목으로 커밋", "기준선 손봄"), ("제목 경계 refactor: P1-11", "refactor: P1-11 다른 단계"),
                           ("빈칸 없는 refactor:P1-1", "refactor:P1-1 금액")]:
        r = flow("P1-1 P1-2", subject)
        check(f"0.3.5 B5 {title} → 조용(커밋 안 된 것으로 봄)", r[3][0] == 0, f"{r}")

    # B6 · B7(보완 F3): 같은 기준선 경로를 적은 두 카드 — P1-1 완료·커밋됨, P1-3 완료·커밋 전(허용 파일에 열린 카드 P1-2 남음)
    #   → 그 경로의 완료 카드 전부가 자기 커밋을 가졌을 때만 알림. git log 는 완료 카드 ID 마다 1회
    d = mk("P1-1 P1-2 P1-3")
    tr = d.parent / (d.name + "-trace.txt")
    try:
        def logs_b6():
            tr.unlink(missing_ok=True)
            out, err = _lib033(d, 'rl_protected_dirty "$P" "$R" | cut -f1', {"GIT_TRACE": str(tr), "GIT_CEILING_DIRECTORIES": str(d.parent)})
            t = tr.read_text(encoding="utf-8", errors="replace") if tr.exists() else ""
            return out, err, len(re.findall(r"\bgit log -1\b", t))
        hook("turn", d, {"session_id": "s1", "prompt": "/refactor:go"})
        lf(d / M, "P1-1 이 고침\n")
        _done033(d, "P1-1")
        _git034(d, "add", "--", M)
        _git034(d, "commit", "-qm", "refactor: P1-1 금액 계산")
        lf(d / M, "P1-3 이 고침\n")
        r_open = pc(d)
        _done033(d, "P1-3")
        r_done = pc(d)
        _git034(d, "add", "--", M)
        r_add = pc(d)
        out6, err6, n6 = logs_b6()
        check("0.3.5 B6 같은 경로 P1-1(커밋됨)·P1-3(완료·커밋 전) — 열림·완료 표시 직후·git add 뒤 모두 조용",
              r_open[0] == 0 and r_done[0] == 0 and r_add[0] == 0, f"{r_open} {r_done} {r_add}")
        check("0.3.5 B6 git log 는 완료 카드 ID 마다(2회) · 목록 비어 있음", n6 == 2 and out6 == "", f"n={n6} {out6!r} {err6}")
        _git034(d, "commit", "-qm", "refactor: P1-3 금액 표시")
        r_commit = pc(d)
        lf(d / M, "다시 고침\n")
        r_last = pc(d)
        out7, err7, n7 = logs_b6()
        check("0.3.5 B7 P1-3 도 커밋 → 조용 · 그 뒤 그 경로를 다시 바꿈 → post-check 알림",
              r_commit[0] == 0 and r_last[0] == 2 and "보호된 파일(커밋된 기준선 테스트·마이그레이션)이 바뀌었습니다" in r_last[1] and M in r_last[1],
              f"{r_commit} {r_last}")
        check("0.3.5 B7 git log 3회(완료 카드 ID 마다 + 경로 1회) · 목록에 남음", n7 == 3 and out7 == " M " + M + "\n", f"n={n7} {out7!r} {err7}")
    finally:
        tr.unlink(missing_ok=True)
        shutil.rmtree(d, ignore_errors=True)

    # B8 알려진 한계(1차와 같음 · 보완 3바퀴 R2): P1-1 완료·커밋됐지만 그 커밋이 기준선 파일을 안 건드림 → 뒤에 셸로 그 파일을 바꿔도 조용.
    #   까닭: "그 경로를 마지막으로 바꾼 커밋의 제목이 완료 카드의 것"(②)이 함께 맞아야 알린다 — ① 만으로 알리면 되돌린 옛 커밋·지난 묶음의
    #   같은 ID 커밋 때문에 커밋 전에도 헛알림이 났다(재검사 A2·C2 🟠 — 아래 R2 시험). 헛알림을 없애는 쪽을 골랐다
    d = mk("P1-1 P1-2")
    try:
        hook("turn", d, {"session_id": "s1", "prompt": "/refactor:go"})
        _done033(d, "P1-1")
        lf(d / "money.ts", "고침\n")
        _git034(d, "add", "--", "money.ts")
        _git034(d, "commit", "-qm", "refactor: P1-1 금액 계산")
        r_commit = pc(d)
        lf(d / M, "셸로 바꿈\n")
        r_last = pc(d)
        check("0.3.5 B8 알려진 한계: 앞 단계 커밋이 기준선 파일을 안 건드림 → 뒤에 그 파일을 바꿔도 조용(그 경로의 마지막 커밋이 카드 커밋이 아님)",
              r_commit[0] == 0 and r_last[0] == 0, f"{r_commit} {r_last}")
    finally:
        shutil.rmtree(d, ignore_errors=True)

    # R2(보완 3바퀴 · 재검사 A2·C2 🟠): 같은 카드 ID 의 옛 커밋이 기록에 있어도 커밋 전에는 조용
    #   ⓐ README 의 되돌리는 법: 옛 "refactor: P1-1" 커밋 → git revert → P1-1 다시 실행: 기준선 고침 → 완료 표시 → (커밋 전) git add
    #   ⓑ 같은 ID 옛 커밋(그 파일 안 건드림 — 지난 묶음) + B2 꼴(완료 표시 · 커밋 전 · 경로 바뀐 채)
    for name, revert in (("ⓐ 옛 커밋 revert 뒤 다시 실행", True), ("ⓑ 같은 ID 옛 커밋(그 파일 안 건드림)", False)):
        d = mk("P1-1 P1-2")
        try:
            hook("turn", d, {"session_id": "s1", "prompt": "/refactor:go"})
            lf(d / "z.txt", "old\n")
            _git034(d, "add", "--", "z.txt")
            _git034(d, "commit", "-qm", "refactor: P1-1 지난 번 실행")
            if revert:
                _git034(d, "revert", "--no-edit", "HEAD")
            lf(d / M, "P1-1 이 다시 고침\n")
            r_open = pc(d)
            _done033(d, "P1-1")
            r_done = pc(d)
            _git034(d, "add", "--", M)
            r_add = pc(d)
            check(f"0.3.5 R2 {name} → 열림·완료 표시 직후·git add 뒤 모두 조용",
                  r_open[0] == 0 and r_done[0] == 0 and r_add[0] == 0, f"{r_open} {r_done} {r_add}")
            _git034(d, "commit", "-qm", "refactor: P1-1 다시 실행")
            r_commit = pc(d)
            lf(d / M, "다음 단계가 셸로 바꿈\n")
            r_last = pc(d)
            check(f"0.3.5 R2 {name} → 이번 커밋 뒤 다시 바뀌면 알림(B3 그대로)",
                  r_commit[0] == 0 and r_last[0] == 2 and M in r_last[1], f"{r_commit} {r_last}")
        finally:
            shutil.rmtree(d, ignore_errors=True)

    # git 호출 수: 완료 카드에만 속한 경로가 변경 목록에 없으면 git log 를 부르지 않는다 · 있으면 완료 카드 ID 마다 1회(커밋 전이면 거기서 멈춤)
    #   + 전부 커밋됐을 때만 경로 1회
    d = mk("P1-1 P1-2")
    try:
        tr = d.parent / (d.name + "-trace.txt")

        def logs(expr="rl_protected_dirty \"$P\" \"$R\" | cut -f1"):
            tr.unlink(missing_ok=True)
            out, err = _lib033(d, expr, {"GIT_TRACE": str(tr), "GIT_CEILING_DIRECTORIES": str(d.parent)})
            t = tr.read_text(encoding="utf-8", errors="replace") if tr.exists() else ""
            return out, err, len(re.findall(r"\bgit log -1\b", t))
        lf(d / M, "v1\n"); lf(d / "tests/baseline/golden/d.json", "v1\n")
        out, err, n = logs()
        check("0.3.5 git 호출: 열린 카드 경로만 바뀜 → git log 0회 · 목록 비어 있음", n == 0 and out == "", f"n={n} {out!r} {err}")
        _done033(d, "P1-1")
        out, err, n = logs()
        check("0.3.5 git 호출: 완료 카드 경로(커밋 전) → git log 1회 · 목록에서 빠짐", n == 1 and out == "", f"n={n} {out!r} {err}")
        _git034(d, "add", "--", M)
        _git034(d, "commit", "-qm", "refactor: P1-1 금액 계산")
        lf(d / M, "v2\n")
        out, err, n = logs()
        check("0.3.5 git 호출: 커밋된 완료 카드 경로 → git log 2회(카드 커밋 + 경로) · 목록에 남음", n == 2 and out == " M " + M + "\n", f"n={n} {out!r} {err}")
        out, err = _lib033(d, 'rl_allow_baseline "$R" split')
        check("0.3.5 rl_allow_baseline split 꼴: O<TAB>경로 / D<TAB>ID<TAB>경로",
              out == "OPEN P1-2\nD\tP1-1\t" + M + "\nO\ttests/baseline/golden/d.json\n", repr(out) + err)
        out, err = _lib033(d, 'rl_allow_baseline "$R" approved')
        check("0.3.5 rl_allow_baseline approved 꼴은 그대로(완료 카드 포함 경로 전부)",
              out == "OPEN P1-2\n" + M + "\ntests/baseline/golden/d.json\n", repr(out) + err)
    finally:
        tr.unlink(missing_ok=True)
        shutil.rmtree(d, ignore_errors=True)

    # 하위 폴더 프로젝트(저장소 apps/web): 접두를 떼고 카드 경로와 맞추고, git log 는 저장소 기준 경로로 찾는다
    root = pathlib.Path(tempfile.mkdtemp(prefix="scripttest-mono035-"))
    try:
        d = root / "apps/web"
        (d / "docs/refactor").mkdir(parents=True)
        lf(d / "docs/refactor/REFACTOR_PLAN.md", PLAN_035)
        lf(d / "docs/refactor/BASELINE.md", BASELINE)
        setup(d)
        _git034(root, "init", "-q")
        _git034(root, "add", "--", *("apps/web/tests/baseline/" + f for f in files), "apps/web/docs/refactor/REFACTOR_PLAN.md")
        _git034(root, "commit", "-qm", "i")
        approve(d, "P1-1 P1-2 P1-3")
        (d / "docs/refactor/.allow-baseline-edit").write_bytes(b"P1-1 P1-2\n")
        lf(d / M, "v1\n")
        _done033(d, "P1-1")
        dirty = lambda: _lib033(d, 'rl_protected_dirty "$P" "$R" | cut -f1', {"GIT_CEILING_DIRECTORIES": str(root.parent)})
        out1, err1 = dirty()
        _git034(root, "add", "--", "apps/web/" + M)
        _git034(root, "commit", "-qm", "refactor: P1-1 금액 계산")
        lf(d / M, "v2\n")
        out2, err2 = dirty()
        check("0.3.5 하위 폴더: 커밋 전 조용 · 커밋 뒤 다시 바뀌면 저장소 기준 경로로 보고",
              out1 == "" and out2 == " M apps/web/" + M + "\n", f"{out1!r} {out2!r} {err1}{err2}")
        # B9(보완 F3): 하위 폴더에서 B6 → B7 — 같은 경로를 적은 P1-3 도 완료(커밋 전)면 조용, P1-3 커밋 뒤 다시 바뀌면 보고
        (d / "docs/refactor/.allow-baseline-edit").write_bytes(b"P1-1 P1-2 P1-3\n")
        _done033(d, "P1-3")
        _git034(root, "add", "--", "apps/web/" + M)
        out3, err3 = dirty()
        _git034(root, "commit", "-qm", "refactor: P1-3 금액 표시")
        lf(d / M, "v3\n")
        out4, err4 = dirty()
        check("0.3.5 B9 하위 폴더: P1-3 완료·커밋 전(git add) 조용 · P1-3 커밋 뒤 다시 바뀌면 저장소 기준 경로로 보고",
              out3 == "" and out4 == " M apps/web/" + M + "\n", f"{out3!r} {out4!r} {err3}{err4}")
    finally:
        shutil.rmtree(root, ignore_errors=True)


def check_approve_newbranch_034(check):
    """0.3.4 §2: /refactor:approve 새 가지(n1~n13·n15·n16) — 임시 저장소 + 로컬 origin 참조(네트워크 0)."""
    g = _git034
    today = _today_kst034()
    intact = lambda d: _lib033(d, 'rl_log_intact "$R" && echo yes')[0] == "yes\n"
    states = lambda d: _lib033(d, 'rl_cards "$R/REFACTOR_PLAN.md" "$R/APPROVALS.log"')[0]
    cur = lambda d: g(d, "branch", "--show-current")
    W_R8 = "의 내용이 아직 origin/"
    W_NO = "새 가지를 만들지 않았습니다"

    def mk(ignore_log=False):
        """main 에 승인 1개(P1-1) 커밋 → origin/main = 그 커밋 → feat/x 에서 커밋 하나(b.txt)."""
        d = project(plan=PLAN_033)
        g(d, "init", "-q"); g(d, "symbolic-ref", "HEAD", "refs/heads/main")
        # origin 원격 설정(주소는 없는 로컬 경로 — 받아 오지 않으므로 네트워크 0). 설정이 있어야 참조 이름 시작점이 upstream 을 만든다(변이 ⑥)
        g(d, "remote", "add", "origin", str(d.parent / "no-such-origin.git"))
        if ignore_log:
            lf(d / ".gitignore", "*.log\n")
        lf(d / "a.txt", "a\n")
        approve(d, "P1-1")
        g(d, "add", "-A"); g(d, "commit", "-qm", "i")
        g(d, "update-ref", "refs/remotes/origin/main", "HEAD")
        g(d, "checkout", "-q", "-b", "feat/x")
        lf(d / "b.txt", "b\n"); g(d, "add", "-A"); g(d, "commit", "-qm", "b")
        return d

    def merged(d, how="rebase"):
        """origin/main 에 지금 HEAD 의 내용을 합친 커밋을 만든다(rebase·스쿼시 = 트리 같고 조상 아님 / merge = 병합 커밋, 조상)."""
        tree = g(d, "rev-parse", "HEAD^{tree}")
        base = g(d, "rev-parse", "refs/remotes/origin/main")
        if how == "merge":
            c = g(d, "commit-tree", tree, "-p", base, "-p", "HEAD", "-m", "Merge PR")
        else:
            c = g(d, "commit-tree", tree, "-p", base, "-m", "rebased")
        g(d, "update-ref", "refs/remotes/origin/main", c)
        return c

    def extra_on_base(d, name="other.txt"):
        """origin/main 에 다른 파일 커밋을 하나 더 얹는다(작업 폴더는 그대로)."""
        base = g(d, "rev-parse", "refs/remotes/origin/main")
        blob = subprocess.run(["git", "-C", str(d), "hash-object", "-w", "--stdin"], input=b"o\n", capture_output=True).stdout.decode().strip()
        idx = d / ".git" / "tmpidx"
        e = dict(os.environ, GIT_INDEX_FILE=str(idx))
        subprocess.run(["git", "-C", str(d), "read-tree", base], env=e, check=True)
        subprocess.run(["git", "-C", str(d), "update-index", "--add", "--cacheinfo", f"100644,{blob},{name}"], env=e, check=True)
        tree = subprocess.run(["git", "-C", str(d), "write-tree"], env=e, capture_output=True, check=True).stdout.decode().strip()
        idx.unlink()
        c = g(d, "commit-tree", tree, "-p", base, "-m", "다른 커밋")
        g(d, "update-ref", "refs/remotes/origin/main", c)
        return c

    def made(title, d, out, name, base, before_states, n0):
        lt = _log033(d)
        check(f"0.3.4 {title} → 새 가지 {name}", cur(d) == name and g(d, "rev-parse", "HEAD") == base, f"{cur(d)} {out}")
        check(f"0.3.4 {title} → upstream 없음(--no-track)", g(d, "config", f"branch.{name}.merge", check_rc=False) == "", out)
        check(f"0.3.4 {title} → 기록 1줄 · 봉인 일치", lt.count("\n") == n0 + 1
              and lt.endswith(f" KST | 새 가지 | {name} <- origin/main@{base[:7]} | - | 사용자가 /refactor:approve 로 실행\n") and intact(d), lt[-300:])
        check(f"0.3.4 {title} → 승인 상태 그대로", states(d) == before_states, states(d) + "\n---\n" + before_states)
        check(f"0.3.4 {title} → 출력", f"🌿 새 작업 가지: {name} (origin/main {base[:7]} 에서 · 지난 가지 " in out and "다음: /refactor:go" in out, out)

    def unchanged(title, d, args, msg, **kw):
        h0, b0, snap = g(d, "rev-parse", "HEAD"), cur(d), rdir_files(d)
        out, _ = _ap034(d, args, **kw)
        check(f"0.3.4 {title} → 안 바뀜 + 까닭", g(d, "rev-parse", "HEAD") == h0 and cur(d) == b0 and rdir_files(d) == snap and msg in out, out)
        return out

    # n1 rebase 로 합쳐짐(트리 같음·조상 아님) / n2 스쿼시 · 병합 커밋 · 기본 가지에 다른 커밋이 더 있음
    for title, how, extra in [("n1 rebase 합침", "rebase", False), ("n2 스쿼시 합침", "squash", False),
                              ("n2 병합 커밋(조상)", "merge", False), ("n2 기본 가지에 다른 커밋 더", "rebase", True)]:
        d = mk()
        try:
            if how == "squash":
                lf(d / "c.txt", "c\n"); g(d, "add", "-A"); g(d, "commit", "-qm", "c")
            merged(d, how)
            base = extra_on_base(d) if extra else g(d, "rev-parse", "refs/remotes/origin/main")
            st0, n0 = states(d), _log033(d).count("\n")
            out, _ = _ap034(d, "새 가지")
            made(title, d, out, f"refactor/{today}", base, st0, n0)
            check(f"0.3.4 {title} → 지난 가지 그대로", g(d, "rev-parse", "--verify", "-q", "refs/heads/feat/x", check_rc=False) != "", out)
        finally:
            shutil.rmtree(d, ignore_errors=True)

    # n3 안 합쳐진 커밋 · n4 origin/main 이 옛 것(받아 오기 전) → R8
    d = mk()
    try:
        unchanged("n4 origin/main 이 옛 것(R8)", d, "새 가지", W_R8)
        merged(d)
        lf(d / "e.txt", "e\n"); g(d, "add", "-A"); g(d, "commit", "-qm", "합치고 더 한 커밋")
        out = unchanged("n3 안 합쳐진 커밋(R8)", d, "새 가지", W_R8)
        check("0.3.4 n3 R8 문구 전체", "⛔ 지금 가지(feat/x)의 내용이 아직 origin/main 에 다 들어 있지 않습니다 — PR 이 아직 안 합쳐졌거나, 합친 뒤 최신 내용을 안 받아 온 상태입니다. "
              "Claude 에게 '최신 내용 받아 와'라고 한 뒤 다시 입력해 주세요." in out, out)
    finally:
        shutil.rmtree(d, ignore_errors=True)
    # 합치기 드라이버 설정이 있으면 merge-tree 를 부르지 않는다(판정 불가) — 0.3.4 보완 F3 로 바뀜: 예전엔 "조상일 때만"이라
    #   rebase 합침(트리 같음)도 R8 거절이었으나, 이제 트리 같음·git cherry 는 드라이버와 상관없이 먼저 본다.
    #   그래서 스쿼시 합침 + 기본 가지에 다른 파일 커밋(트리 다름 · cherry 는 '+')으로 merge-tree 까지 가게 한다
    d = mk()
    try:
        lf(d / "c.txt", "c\n"); g(d, "add", "-A"); g(d, "commit", "-qm", "c")
        merged(d, "squash")
        extra_on_base(d)
        g(d, "config", "merge.ours.driver", "true")
        unchanged("n3 합치기 드라이버 설정 → merge-tree 안 부름(판정 불가)", d, "새 가지", "판정하지 못했습니다: 이 저장소에 합치기 드라이버")
        g(d, "config", "--unset", "merge.ours.driver")
        out, _ = _ap034(d, "새 가지")
        check("0.3.4 n3 드라이버 설정을 지우면 → 만들어짐", cur(d) == f"refactor/{today}", out)
    finally:
        shutil.rmtree(d, ignore_errors=True)
    d = mk()
    try:
        merged(d)
        g(d, "config", "merge.ours.driver", "true")
        out, _ = _ap034(d, "새 가지")
        check("0.3.4 n3 드라이버 설정이 있어도 트리가 같으면(rebase 합침) → 만들어짐(F3 ②)", cur(d) == f"refactor/{today}", out)
    finally:
        shutil.rmtree(d, ignore_errors=True)

    # n5 R6 기본 가지에 STATE 없음 · R7 승인 기록 다름 / n16 기본 가지 쪽 봉인 사본만 다름(잔치 꼴)
    for title, path, msg in [("n5 R6 기본 가지에 STATE 없음", "docs/refactor/STATE.md", "에 리팩토링 기록이 없습니다(옮기면 안전장치가 꺼짐)"),
                             ("n5 R7 승인 기록 다름", "docs/refactor/APPROVALS.log", "의 승인 기록이 지금 가지와 다릅니다"),
                             ("n16 R7 봉인 사본(.log-sum)만 다름", "docs/refactor/approved/.log-sum", "의 승인 기록이 지금 가지와 다릅니다")]:
        d = mk(ignore_log=title.startswith("n16"))
        try:
            merged(d)
            base = g(d, "rev-parse", "refs/remotes/origin/main")
            e = dict(os.environ, GIT_INDEX_FILE=str(d / ".git" / "tmpidx"))
            subprocess.run(["git", "-C", str(d), "read-tree", base], env=e, check=True)
            if "STATE" in path:
                subprocess.run(["git", "-C", str(d), "update-index", "--force-remove", path], env=e, check=True)
            else:
                blob = subprocess.run(["git", "-C", str(d), "hash-object", "-w", "--stdin"], input=b"x\n", capture_output=True).stdout.decode().strip()
                subprocess.run(["git", "-C", str(d), "update-index", "--add", "--cacheinfo", f"100644,{blob},{path}"], env=e, check=True)
            tree = subprocess.run(["git", "-C", str(d), "write-tree"], env=e, capture_output=True, check=True).stdout.decode().strip()
            (d / ".git" / "tmpidx").unlink()
            g(d, "update-ref", "refs/remotes/origin/main", g(d, "commit-tree", tree, "-p", base, "-m", "다름"))
            unchanged(title, d, "새 가지", msg)
        finally:
            shutil.rmtree(d, ignore_errors=True)

    # n6 같은 날 이름이 이미 있음(로컬 / 원격만 / 둘 다) · n7 이름 줌 · 나쁜 이름 · 이름 둘
    d = mk()
    try:
        merged(d)
        base = g(d, "rev-parse", "refs/remotes/origin/main")
        g(d, "branch", f"refactor/{today}", base)
        st0, n0 = states(d), _log033(d).count("\n")
        out, _ = _ap034(d, "새 가지")
        made("n6 로컬에 같은 이름", d, out, f"refactor/{today}-2", base, st0, n0)
        g(d, "checkout", "-q", "feat/x")
        g(d, "branch", "-q", "-D", f"refactor/{today}", f"refactor/{today}-2")
        g(d, "update-ref", f"refs/remotes/origin/refactor/{today}", base)
        out, _ = _ap034(d, "새 가지")
        check("0.3.4 n6 원격에만 같은 이름 → -2", cur(d) == f"refactor/{today}-2", out)
        g(d, "checkout", "-q", "feat/x")
        out, _ = _ap034(d, "새 가지")
        check("0.3.4 n6 원격·로컬-2 둘 다 → -3", cur(d) == f"refactor/{today}-3", out)
        g(d, "checkout", "-q", "feat/x")
        out, _ = _ap034(d, "새 가지 feat/y")
        check("0.3.4 n7 '새 가지 feat/y' → 그 이름", cur(d) == "feat/y" and g(d, "rev-parse", "HEAD") == base
              and _log033(d).endswith(f" | 새 가지 | feat/y <- origin/main@{base[:7]} | - | 사용자가 /refactor:approve 로 실행\n"), out)
        g(d, "checkout", "-q", "feat/x")
        out, _ = _ap034(d, "새 가지 Feat/Y.2")
        check("0.3.4 n7 이름은 원문 그대로(대문자·마침표 유지)", cur(d) == "Feat/Y.2", out)
        g(d, "checkout", "-q", "feat/x")
        for args in ("새 가지 -x", "새 가지 a..b", "새 가지 a b", "새 가지 feat/x;", "새 가지 a.lock", "새 가지 x/", "새 가지 a~1", "새 가지 @{-1}",
                     "새 가지 feat/x", "새 가지 refactor/한글"):
            msg = "가지 이름을 하나만" if args == "새 가지 a b" else ("already exists" if args == "새 가지 feat/x" else "을 쓸 수 없습니다")
            unchanged(f"n7 {args!r} → 거절", d, args, msg)
    finally:
        shutil.rmtree(d, ignore_errors=True)

    # n8 커밋 안 된 변경: 기록 파일만 → 따라옴 + 알림 / 새 위치와 부딪히는 파일(R10) → 안 바뀜 + git 오류 줄
    d = mk()
    try:
        merged(d)
        extra_on_base(d, "a.txt")   # 기본 가지가 a.txt 를 바꿈
        lf(d / "a.txt", "로컬에서 고침\n")
        out = unchanged("n8 부딪히는 변경(R10)", d, "새 가지", "git 이 새 가지로 옮기지 못했습니다: error:")
        check("0.3.4 n8 R10 '아무것도 바뀌지 않았습니다'", "아무것도 바뀌지 않았습니다(지금 가지 feat/x 그대로)" in out, out)
        g(d, "checkout", "-q", "--", "a.txt")
        st = d / "docs/refactor/STATE.md"
        lf(st, st.read_text(encoding="utf-8") + "메모\n")
        out, _ = _ap034(d, "새 가지")
        check("0.3.4 n8 기록 파일만 바뀜 → 따라옴 + 알림", cur(d) == f"refactor/{today}" and st.read_text(encoding="utf-8").endswith("메모\n")
              and "   커밋 안 된 변경 1개가 그대로 따라왔습니다: docs/refactor/STATE.md" in out, out)
    finally:
        shutil.rmtree(d, ignore_errors=True)

    # n9 --from-hook 없음 · 봉인 깨짐 · 마무리 확인 뒤(R1·R2)
    d = mk()
    try:
        merged(d)
        unchanged("n9 --from-hook 없음", d, "새 가지", "아무것도 바꾸지 않았습니다", from_hook=False)
        lg = d / "docs/refactor/APPROVALS.log"
        keep = lg.read_bytes()
        lg.write_bytes(keep + "2026-10-03 10:00 KST | 승인 | P1-3 | card=1.2 | 손으로\n".encode("utf-8"))
        unchanged("n9 봉인 깨짐", d, "새 가지", "처리하지 않았습니다")
        lg.write_bytes(keep)
        approve(d, "보류 P1-1")
        approve(d, "마무리")
        done_ok = _lib033(d, 'rl_done_confirmed "$R" && echo yes')[0] == "yes\n"
        g(d, "add", "-A"); g(d, "commit", "-qm", "마무리"); merged(d)
        unchanged("n9 마무리 확인 뒤(R2)", d, "새 가지", "이미 마무리되어 안전장치가 꺼져 있습니다 — 새 가지는 평소처럼 만들 수 있습니다")
        check("0.3.4 n9 마무리 인정 그대로", done_ok and _lib033(d, 'rl_done_confirmed "$R" && echo yes')[0] == "yes\n")
    finally:
        shutil.rmtree(d, ignore_errors=True)

    # n10 진행 중인 합치기(R4) · origin 없음(R5) · git 저장소 아님(R3)
    d = mk()
    try:
        merged(d)
        for f in ("MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG"):
            (d / ".git" / f).write_text(g(d, "rev-parse", "HEAD") + "\n")
            unchanged(f"n10 진행 중({f})(R4)", d, "새 가지", "진행 중인 git 작업을 먼저 끝내세요")
            (d / ".git" / f).unlink()
        (d / ".git" / "rebase-merge").mkdir()
        unchanged("n10 진행 중(rebase-merge)(R4)", d, "새 가지", "진행 중인 git 작업을 먼저 끝내세요")
        (d / ".git" / "rebase-merge").rmdir()
        g(d, "update-ref", "-d", "refs/remotes/origin/main")
        unchanged("n10 origin 없음(R5)", d, "새 가지", "origin 의 기본 가지를 찾지 못했습니다")
    finally:
        shutil.rmtree(d, ignore_errors=True)
    d = project(plan=PLAN_033)
    try:
        snap = rdir_files(d)
        out, _ = _ap034(d, "새 가지")
        check("0.3.4 n10 git 저장소 아님(R3) → 안 바뀜", rdir_files(d) == snap and "git 저장소가 아니라" in out and W_NO in out, out)
    finally:
        shutil.rmtree(d, ignore_errors=True)

    # n11 기본 가지 위에서(로컬 main 이 origin/main 뒤) · 떨어진 HEAD(내용은 합쳐짐)
    d = mk()
    try:
        merged(d)
        base = g(d, "rev-parse", "refs/remotes/origin/main")
        g(d, "checkout", "-q", "main")
        st0, n0 = states(d), _log033(d).count("\n")
        out, _ = _ap034(d, "새 가지")
        made("n11 로컬 main(뒤처짐) 위에서", d, out, f"refactor/{today}", base, st0, n0)
        g(d, "checkout", "-q", "--detach", "feat/x")
        out, _ = _ap034(d, "새 가지")
        check("0.3.4 n11 떨어진 HEAD → 새 가지", cur(d) == f"refactor/{today}-2" and g(d, "rev-parse", "HEAD") == base
              and "지난 위치(떨어진 HEAD)는 커밋으로 남아 있음" in out, out)
    finally:
        shutil.rmtree(d, ignore_errors=True)

    # n12 같은 결과 다른 철자(앞 다섯 = 만들어짐) / 섞임(뒤 셋 + 그 밖 = 거절)
    d = mk()
    try:
        merged(d)
        base = g(d, "rev-parse", "refs/remotes/origin/main")
        for i, args in enumerate(["새가지", "NEWBRANCH", "new branch", "새  가지", "새 가지.", "New Branch", "\n새\n가지\n", "새 가지,"], 1):
            g(d, "checkout", "-q", "feat/x")
            for b in g(d, "for-each-ref", "--format=%(refname:short)", "refs/heads/refactor/").split():
                g(d, "branch", "-q", "-D", b)
            out, _ = _ap034(d, args)
            check(f"0.3.4 n12 {args!r} → 만들어짐", cur(d) == f"refactor/{today}" and g(d, "rev-parse", "HEAD") == base, out)
        g(d, "checkout", "-q", "feat/x")
        for args in ("가지 새", "P1-1 새 가지", "새 가지 푸시", "새 가지 P1-1", "새 가지 baseline", "새 가지 확인", "새 가지 마무리", "새 가지 보류",
                     "새 가지 허용", "보류 새 가지", "허용 새 가지", "새", "NEW P1-1", "가지", "새 새 가지", "새 가지 가지", "새 가지 합치기", "새 가지 all"):
            unchanged(f"n12 {args!r} → 거절", d, args, "아무것도 바꾸지 않았습니다")
    finally:
        shutil.rmtree(d, ignore_errors=True)

    # n13 origin/HEAD 가 origin/develop 을 가리킴 → develop 기준(origin/main 은 안 합쳐진 옛 것이어도)
    d = mk()
    try:
        old = g(d, "rev-parse", "refs/remotes/origin/main")
        merged(d)
        dev = g(d, "rev-parse", "refs/remotes/origin/main")
        g(d, "update-ref", "refs/remotes/origin/develop", dev)
        g(d, "update-ref", "refs/remotes/origin/main", old)
        g(d, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/develop")
        out, _ = _ap034(d, "새 가지")
        check("0.3.4 n13 origin/HEAD → develop 기준으로 생성", cur(d) == f"refactor/{today}" and g(d, "rev-parse", "HEAD") == dev
              and f"(origin/develop {dev[:7]} 에서" in out and f"<- origin/develop@{dev[:7]} |" in _log033(d), out)
    finally:
        shutil.rmtree(d, ignore_errors=True)

    # n15 잔치 꼴: APPROVALS.log 가 git 무시(*.log) + 봉인 사본만 추적 · 커밋 안 된 새 승인 줄(봉인 사본 수정됨)이 있는 채
    d = mk(ignore_log=True)
    try:
        check("0.3.4 n15 준비: APPROVALS.log 는 git 무시 · 봉인 사본은 추적",
              g(d, "ls-files", "docs/refactor/APPROVALS.log") == "" and g(d, "ls-files", "docs/refactor/approved/.log-sum") != "")
        merged(d)
        base = g(d, "rev-parse", "refs/remotes/origin/main")
        approve(d, "P1-2")
        check("0.3.4 n15 준비: 봉인 사본이 커밋 안 된 채 바뀜", "docs/refactor/approved/.log-sum" in g(d, "status", "--porcelain"))
        st0, n0 = states(d), _log033(d).count("\n")
        out, _ = _ap034(d, "새 가지")
        made("n15 잔치 꼴(기록 git 무시)", d, out, f"refactor/{today}", base, st0, n0)
    finally:
        shutil.rmtree(d, ignore_errors=True)


def check_newbranch_fix_034(check):
    """0.3.4 보완 F3(f3: R8 판정 순서 ①조상 ②트리 같음 ③git cherry ④merge-tree · 반환 0/1/2 · 판정 불가 문구)·F6(이름 거절)."""
    g = _git034
    today = _today_kst034()
    cur = lambda d: g(d, "branch", "--show-current")
    W_R8 = "의 내용이 아직 origin/main 에 다 들어 있지 않습니다"
    W_UNK = "의 내용이 origin/main 에 다 들어 있는지 판정하지 못했습니다: "
    W_TERM = f"받아 온 뒤에도 같으면 PR 이 합쳐진 것을 확인하고 사람이 터미널에서: git switch -c refactor/{today} origin/main"
    TEN = "".join(f"{i}\n" for i in range(1, 11))
    made_dirs = []

    def mk():
        d = project(plan=PLAN_033)
        g(d, "init", "-q"); g(d, "symbolic-ref", "HEAD", "refs/heads/main")
        g(d, "remote", "add", "origin", str(d.parent / "no-such-origin.git"))
        lf(d / "a.txt", TEN)
        approve(d, "P1-1")
        g(d, "add", "-A"); g(d, "commit", "-qm", "i")
        g(d, "update-ref", "refs/remotes/origin/main", "HEAD")
        g(d, "checkout", "-q", "-b", "feat/x")
        lf(d / "a.txt", TEN.replace("3\n", "X\n")); g(d, "add", "-A"); g(d, "commit", "-qm", "b")
        return d

    def on_base(d, files, parent=None, msg="기본 가지 커밋"):
        """origin/main(또는 parent) 위에 files({경로: 내용 | None=지움})를 바꾼 커밋 → origin/main 으로."""
        base = parent or g(d, "rev-parse", "refs/remotes/origin/main")
        idx = d / ".git" / "tmpidx"
        e = dict(os.environ, GIT_INDEX_FILE=str(idx))
        subprocess.run(["git", "-C", str(d), "read-tree", base], env=e, check=True)
        for path, data in files.items():
            if data is None:
                subprocess.run(["git", "-C", str(d), "update-index", "--force-remove", path], env=e, check=True)
                continue
            blob = subprocess.run(["git", "-C", str(d), "hash-object", "-w", "--stdin"], input=data.encode("utf-8"), capture_output=True).stdout.decode().strip()
            subprocess.run(["git", "-C", str(d), "update-index", "--add", "--cacheinfo", f"100644,{blob},{path}"], env=e, check=True)
        tree = subprocess.run(["git", "-C", str(d), "write-tree"], env=e, capture_output=True, check=True).stdout.decode().strip()
        idx.unlink()
        c = g(d, "commit-tree", tree, "-p", base, "-m", msg)
        g(d, "update-ref", "refs/remotes/origin/main", c)
        return c

    def rebase_merged(d):
        """feat/x 의 커밋 하나하나를 같은 변경으로 origin/main 에 다시 얹는다(rebase 합침 — 커밋 번호만 다름)."""
        for c in g(d, "rev-list", "--reverse", "refs/remotes/origin/main..HEAD").split():
            tree = g(d, "rev-parse", f"{c}^{{tree}}")
            base = g(d, "rev-parse", "refs/remotes/origin/main")
            # 그 커밋의 변경만 기본 가지에 적용(여기서는 기본 가지 = 커밋의 부모와 같은 내용이라 트리를 그대로 쓴다)
            g(d, "update-ref", "refs/remotes/origin/main", g(d, "commit-tree", tree, "-p", base, "-m", "rebased"))

    def squash_merged(d):
        tree = g(d, "rev-parse", "HEAD^{tree}")
        base = g(d, "rev-parse", "refs/remotes/origin/main")
        g(d, "update-ref", "refs/remotes/origin/main", g(d, "commit-tree", tree, "-p", base, "-m", "squashed"))

    def unchanged(title, d, args, msg, path=None):
        h0, b0, snap = g(d, "rev-parse", "HEAD"), cur(d), rdir_files(d)
        out, _ = _ap034(d, args, path=path)
        check(f"0.3.4 {title} → 안 바뀜 + 까닭", g(d, "rev-parse", "HEAD") == h0 and cur(d) == b0 and rdir_files(d) == snap and msg in out, out)
        return out

    def created(title, d, out, name=None):
        check(f"0.3.4 {title} → 만들어짐", cur(d) == (name or f"refactor/{today}")
              and g(d, "rev-parse", "HEAD") == g(d, "rev-parse", "refs/remotes/origin/main"), out)

    # merge-tree 를 못 쓰는 git(옛 git 흉내): merge-tree 에만 129, 나머지는 진짜 git
    real_git = shutil.which("git")
    fg = pathlib.Path(tempfile.mkdtemp(prefix="oldgit-"))
    made_dirs.append(fg)
    (fg / "git").write_bytes(("#!/usr/bin/env bash\nfor a in \"$@\"; do [ \"$a\" = merge-tree ] && { echo 'usage: git merge-tree <base-tree> <branch1> <branch2>' >&2; exit 129; }; done\n"
                              f"exec \"{pathlib.Path(real_git).as_posix()}\" \"$@\"\n").encode("utf-8"))
    os.chmod(fg / "git", 0o755)
    old_path = str(fg) + os.pathsep + env()["PATH"]

    try:
        # f3-1 rebase 합침 + 그 뒤 기본 가지가 같은 줄을 고침 → 만들어짐(③ cherry — 예전엔 merge-tree 충돌로 R8)
        d = mk(); made_dirs.append(d)
        rebase_merged(d)
        on_base(d, {"a.txt": TEN.replace("3\n", "Y\n")}, msg="hotfix 같은 줄")
        out, _ = _ap034(d, "새 가지")
        created("f3 rebase 합침 + 기본 가지가 같은 줄 고침", d, out)

        # f3-2 스쿼시 합침(커밋 둘 → 하나) + 같은 줄 고침 → 거절 · 판정 불가 문구(겹침) · 터미널 대안
        d = mk(); made_dirs.append(d)
        lf(d / "c.txt", "c\n"); g(d, "add", "-A"); g(d, "commit", "-qm", "c")
        squash_merged(d)
        on_base(d, {"a.txt": TEN.replace("3\n", "Y\n")}, msg="hotfix 같은 줄")
        out = unchanged("f3 스쿼시 합침 + 같은 줄 고침", d, "새 가지", W_UNK + "합친 뒤 기본 가지에서 같은 곳이 다시 바뀌어")
        check("0.3.4 f3 판정 불가 문구: 받아 오기 + 터미널 대안 · ⛔ 아님", W_TERM in out and "Claude 에게 '최신 내용 받아 와'라고 한 뒤 다시 입력해 주세요." in out
              and "❓ 지금 가지(feat/x)" in out and W_R8 not in out, out)
        out = unchanged("f3 판정 불가 + 이름 붙임 → 터미널 대안에 그 이름", d, "새 가지 feat/hot-1", "git switch -c feat/hot-1 origin/main")

        # f3-3 merge-tree 를 못 쓰는 git + rebase 합침(+ 기본 가지에 다른 파일 커밋) → 만들어짐(cherry 길)
        d = mk(); made_dirs.append(d)
        lf(d / "c.txt", "c\n"); g(d, "add", "-A"); g(d, "commit", "-qm", "c")
        rebase_merged(d)
        on_base(d, {"other.txt": "o\n"})
        out, _ = _ap034(d, "새 가지", path=old_path)
        created("f3 옛 git + rebase 합침", d, out)

        # f3-4 같은 옛 git + 스쿼시 합침 + 기본 가지에 다른 파일 커밋 → 판정 불가(옛 git 문구) / 진짜 git 이면 만들어짐
        d = mk(); made_dirs.append(d)
        lf(d / "c.txt", "c\n"); g(d, "add", "-A"); g(d, "commit", "-qm", "c")
        squash_merged(d)
        on_base(d, {"other.txt": "o\n"})
        unchanged("f3 옛 git + 스쿼시 합침 + 다른 파일 커밋", d, "새 가지", W_UNK + "이 PC 의 git 이 내용 비교(git merge-tree --write-tree", path=old_path)
        out, _ = _ap034(d, "새 가지")
        created("f3 같은 상태 + git 2.38 이상(merge-tree) → ④", d, out)

        # 재검사 R: 판정 불가 문구의 터미널 명령에는 글자 검사를 지난 기본 가지 이름만 — origin/HEAD 가 '$'·';' 가 든 이름을 가리키면 명령을 싣지 않는다
        d = mk(); made_dirs.append(d)
        lf(d / "c.txt", "c\n"); g(d, "add", "-A"); g(d, "commit", "-qm", "c")
        squash_merged(d)
        on_base(d, {"other.txt": "o\n"})
        weird = "w$(id);x"
        g(d, "update-ref", f"refs/remotes/origin/{weird}", g(d, "rev-parse", "refs/remotes/origin/main"))
        g(d, "symbolic-ref", "refs/remotes/origin/HEAD", f"refs/remotes/origin/{weird}")
        out, _ = _ap034(d, "새 가지", path=old_path)
        check("0.3.4 R: 이상한 기본 가지 이름 → 판정 불가 문구에 터미널 명령을 싣지 않음",
              "판정하지 못했습니다" in out and "git switch -c" not in out and "명령을 적지 않았습니다" in out, out)

        # f3-5 반대 방향: rebase 합침 뒤 가지에 기본 가지에 없는 커밋 1개('+') → 거절(코드 1 문구 · 판정 불가 아님)
        d = mk(); made_dirs.append(d)
        rebase_merged(d)
        lf(d / "e.txt", "e\n"); g(d, "add", "-A"); g(d, "commit", "-qm", "합치고 더 한 커밋")
        cherry = g(d, "cherry", "refs/remotes/origin/main", "HEAD")
        check("0.3.4 f3 반대 준비: cherry 에 '-' 와 '+' 가 섞임", "- " in cherry and "+ " in cherry, cherry)
        out = unchanged("f3 반대: 안 합쳐진 커밋 1개(+)", d, "새 가지", W_R8)
        check("0.3.4 f3 반대: 판정 불가 문구가 아님", W_UNK not in out, out)

        # f3-6 반대 방향: 가지에 변경을 담은 병합 커밋(병합할 때 e.txt 를 더함) — 병합 아닌 커밋은 다 기본 가지에 같은 변경으로 들어감
        #      → cherry 는 전부 '-' 이지만 병합 커밋이 있으므로 cherry 길을 타지 않고 거절
        d = mk(); made_dirs.append(d)
        g(d, "checkout", "-q", "-b", "side", "main")
        lf(d / "s.txt", "s\n"); g(d, "add", "-A"); g(d, "commit", "-qm", "s")
        g(d, "checkout", "-q", "feat/x")
        g(d, "merge", "-q", "--no-ff", "--no-commit", "side")
        lf(d / "e.txt", "병합 때 몰래 더함\n"); g(d, "add", "-A"); g(d, "commit", "-qm", "Merge side")
        b1 = on_base(d, {"a.txt": TEN.replace("3\n", "X\n")}, msg="b 다시")
        on_base(d, {"s.txt": "s\n"}, parent=b1, msg="s 다시")
        cherry = g(d, "cherry", "refs/remotes/origin/main", "HEAD")
        check("0.3.4 f3 반대 준비: 병합 커밋 말고는 cherry 가 전부 '-'", cherry != "" and all(l.startswith("- ") for l in cherry.splitlines()), cherry)
        out = unchanged("f3 반대: 변경을 담은 병합 커밋", d, "새 가지", W_R8)
        check("0.3.4 f3 반대: 병합 커밋 → 판정 불가 아님(merge-tree 로 '다름')", W_UNK not in out, out)
        # 같은 상태 + 옛 git → cherry 길을 안 타므로 판정 불가(만들지 않음)
        unchanged("f3 반대: 병합 커밋 + 옛 git → 판정 불가", d, "새 가지", W_UNK, path=old_path)

        # F6 이름 거절(cases-034 approve_새가지_거절 17꼴 + 참조 이름 꼴·기본 가지 이름) · 반대 방향(비슷하지만 다른 이름은 받음)
        d = mk(); made_dirs.append(d)
        rebase_merged(d)
        for args in ("가지 새", "P1-1 새 가지", "새 가지 푸시", "새 가지 a b", "새 가지 -x", "새 가지 a..b", "새 가지 .hidden", "새 가지 a/",
                     "새 가지 a@{1}", "새 가지 HEAD", "새 가지 main", "새 가지 refs/heads/x", "새 가지 '$(id)'", "새 가지 `id`", "새 가지 a;b",
                     "새 가지 허용", "새 합치기", "새 가지 origin/x", "새 가지 master", "새 가지 refs/x", "새 가지 origin/main",
                     "새 가지 Main", "새 가지 MASTER", "새 가지 head", "새 가지 Refs/x", "새 가지 Origin/x"):
            unchanged(f"F6 {args!r} → 거절", d, args, "아무것도 바꾸지 않았습니다")
        out = unchanged("F6 'refs/heads/x' 문구", d, "새 가지 refs/heads/x", "가지 이름(refs/heads/x)을 쓸 수 없습니다(refs/·origin/ 으로 시작하는 이름과 HEAD·main·master·기본 가지 이름 main 은")
        check("0.3.4 F6 refs/heads/x 가지가 안 생김", g(d, "for-each-ref", "refs/heads/refs/") == "", out)
        for name in ("mainline", "feat/main", "refs-x", "origin-x", "HEADS"):
            g(d, "checkout", "-q", "feat/x")
            out, _ = _ap034(d, f"새 가지 {name}")
            created(f"F6 반대: '{name}'(비슷하지만 다른 이름)", d, out, name)
        # 기본 가지가 develop 이면 develop 도 거절(main 도 계속 거절)
        g(d, "checkout", "-q", "feat/x")
        g(d, "update-ref", "refs/remotes/origin/develop", g(d, "rev-parse", "refs/remotes/origin/main"))
        g(d, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/develop")
        unchanged("F6 기본 가지 이름 develop", d, "새 가지 develop", "기본 가지 이름 develop 은")
        unchanged("F6 기본 가지 이름 대소문자만 다름(Develop)", d, "새 가지 Develop", "기본 가지 이름 develop 은")
        unchanged("F6 기본 가지가 develop 이어도 main", d, "새 가지 main", "을 쓸 수 없습니다")
    finally:
        for m in made_dirs:
            shutil.rmtree(m, ignore_errors=True)


def check_approve_autoallow_034(check):
    """0.3.4 §9: 승인하면 기준선 허용 자동(v1~v9) · 보류하면 뺌 · 승인 화면의 🔓 줄."""
    af = lambda d: d / "docs/refactor/.allow-baseline-edit"
    ab = lambda d: af(d).read_bytes() if af(d).exists() else None
    intact = lambda d: _lib033(d, 'rl_log_intact "$R" && echo yes')[0] == "yes\n"
    allow_lines = lambda d: [l for l in _log033(d).splitlines() if " | 허용 | " in l]
    W_OPEN = " — 이 단계를 실행하는 동안 열립니다(닫기: /refactor:approve 허용 닫기)"

    # v1 경로 있는 카드 승인 → 허용 파일에 그 ID · 기록에 승인 줄 바로 다음 허용 줄 · 봉인 일치 · 승인 화면 🔓 줄
    d = project(plan=PLAN_033)
    try:
        out = approve(d, "P1-1")
        ls = _log033(d).splitlines()
        check("0.3.4 v1 승인 → 허용 파일 'P1-1'", ab(d) == b"P1-1\n", out)
        check("0.3.4 v1 기록: 승인 줄 다음 허용 줄", len(ls) == 2 and " | 승인 | P1-1 | card=" in ls[0]
              and ls[1].endswith(" KST | 허용 | P1-1 | - | 사용자가 /refactor:approve 로 실행"), _log033(d))
        check("0.3.4 v1 봉인 일치", intact(d))
        check("0.3.4 v1 승인 화면 🔓 줄", "   🔓 고칠 기준선: `tests/baseline/money.test.ts`" + W_OPEN in out
              and "실행 전에 /refactor:approve 허용" not in out, out)
        st = _lib033(d, 'rl_allow_baseline "$R"')[0]
        check("0.3.4 v1 열린 허용은 실행 중 단계에서만(0.3.3 규칙 그대로 — current_step 없음 = WAIT)", st.startswith("WAIT P1-1"), st)
        # v9 이미 승인된 카드를 다시 승인(변화 없음) → 허용 줄을 또 쓰지 않음(닫은 뒤에도 다시 열지 않음)
        approve(d, "허용 닫기")
        n0 = _log033(d).count("\n")
        out = approve(d, "P1-1")
        check("0.3.4 v9 다시 승인(이미 승인됨) → 허용 줄·파일 없음", "이미 승인됨: [P1-1]" in out and not af(d).exists()
              and _log033(d).count("\n") == n0 and "🔓" not in out, out)
    finally:
        shutil.rmtree(d, ignore_errors=True)

    # v2 경로 "없음" 카드만 · 글만 있고 백틱 0 카드만 → 허용 파일 안 생김 · 허용 줄 없음
    for ids in ("P1-4", "P1-5", "P1-4 P1-5"):
        d = project(plan=PLAN_033)
        try:
            out = approve(d, ids)
            check(f"0.3.4 v2 {ids!r} 승인 → 허용 안 생김", not af(d).exists() and not allow_lines(d) and "🔓" not in out
                  and f"승인함: [{ids.split()[0]}]" in out, out)
        finally:
            shutil.rmtree(d, ignore_errors=True)

    # v3 섞어서 승인 → 경로 있는 ID 만(같은 번호 카드·미승인 카드는 빠짐)
    d = project(plan=PLAN_033)
    try:
        out = approve(d, "P1-4 P1-1 P1-5 P1-2 P2-1")
        check("0.3.4 v3 섞어서 승인 → 'P1-1 P1-2'", ab(d) == b"P1-1 P1-2\n" and len(allow_lines(d)) == 1
              and allow_lines(d)[0].endswith(" | 허용 | P1-1 P1-2 | - | 사용자가 /refactor:approve 로 실행") and intact(d), out)
        check("0.3.4 v3 허용 줄은 승인 줄들 뒤(마지막 줄)", _log033(d).splitlines()[-1] == allow_lines(d)[0], _log033(d))
    finally:
        shutil.rmtree(d, ignore_errors=True)

    # v4 기존 허용 P1-1 + P1-2 승인 → 'P1-1 P1-2' · 파일에 있던 대상 아닌 ID 는 빠지고 알림
    d = project(plan=PLAN_033)
    try:
        approve(d, "P1-1")
        out = approve(d, "P1-2")
        check("0.3.4 v4 'P1-1' + P1-2 승인 → 'P1-1 P1-2'", ab(d) == b"P1-1 P1-2\n" and len(allow_lines(d)) == 2
              and allow_lines(d)[1].endswith(" | 허용 | P1-1 P1-2 | - | 사용자가 /refactor:approve 로 실행") and intact(d), out)
        af(d).write_bytes(b"P1-3 P1-1 # memo\n")   # P1-3 = 미승인(대상 아님)
        out = approve(d, "P1-6")
        check("0.3.4 v4 대상 아닌 옛 ID 는 빠짐 + 알림", ab(d) == b"P1-1 P1-6\n"
              and "허용 파일에 있던 P1-3 은(는) 지금 허용 대상이 아니라 뺐습니다" in out, out)
    finally:
        shutil.rmtree(d, ignore_errors=True)

    # v5 빈 파일(기준선 전부 허용) + 승인 → 그 단계로 좁혀짐 + 알림
    d = project(plan=PLAN_033)
    try:
        af(d).write_bytes(b"")
        out = approve(d, "P1-1")
        check("0.3.4 v5 빈 파일 + 승인 → 'P1-1' 로 좁혀짐 + 알림", ab(d) == b"P1-1\n" and "이 단계들로 좁혔습니다" in out, out)
        af(d).write_bytes(b"")
        out = approve(d, "P1-4")
        check("0.3.4 v5 빈 파일 + 경로 없는 카드 승인 → 그대로(빈 파일)", ab(d) == b"" and "좁혔습니다" not in out, out)
    finally:
        shutil.rmtree(d, ignore_errors=True)

    # v6 보류 → 허용에서 빠짐 · 마지막이면 파일 삭제 · 보류는 기록에 허용 줄을 남기지 않음
    d = project(plan=PLAN_033)
    try:
        approve(d, "P1-1 P1-2 P1-4")
        n_allow = len(allow_lines(d))
        out = approve(d, "보류 P1-2")
        check("0.3.4 v6 보류 P1-2 → 'P1-1'", ab(d) == b"P1-1\n" and "보류한 단계를 기준선 허용에서 뺐습니다: P1-2 (남은 허용: P1-1)" in out
              and len(allow_lines(d)) == n_allow and intact(d), out)
        out = approve(d, "보류 P1-4")
        check("0.3.4 v6 허용에 없는 단계 보류 → 허용 파일 그대로", ab(d) == b"P1-1\n" and "기준선 허용" not in out, out)
        out = approve(d, "HOLD p1-1")
        check("0.3.4 v6 마지막 ID 보류 → 파일 삭제", not af(d).exists() and "남은 단계가 없어 허용 파일을 지움" in out
              and len(allow_lines(d)) == n_allow and intact(d), out)
        approve(d, "P1-1")
        af(d).write_bytes(b"")
        out = approve(d, "보류 P1-1")
        check("0.3.4 v6 빈 파일(전부 허용)은 보류해도 그대로", ab(d) == b"" and "기준선 허용" not in out, out)
    finally:
        shutil.rmtree(d, ignore_errors=True)

    # v7 허용 닫기 뒤 다른 카드 승인 → 그 카드만 열림 · 이어서 '허용 P1-2'(0.3.3 명령)로 더하기
    d = project(plan=PLAN_033)
    try:
        approve(d, "P1-2")
        approve(d, "허용 닫기")
        out = approve(d, "P1-1")
        check("0.3.4 v7 닫은 뒤 P1-1 승인 → 'P1-1' 만(닫았던 P1-2 는 안 열림)", ab(d) == b"P1-1\n", out)
        out = approve(d, "허용 P1-2")
        check("0.3.4 v7 이어서 '허용 P1-2' → 'P1-1 P1-2'", ab(d) == b"P1-1 P1-2\n" and "🔓 기준선 허용: P1-1 P1-2" in out
              and allow_lines(d)[-1].endswith(" | 허용 | P1-1 P1-2 | - | 사용자가 /refactor:approve 로 실행") and intact(d), out)
    finally:
        shutil.rmtree(d, ignore_errors=True)

    # v8 봉인 깨짐 · --from-hook 없음 → 승인도 허용도 안 됨
    d = project(plan=PLAN_033)
    try:
        snap = rdir_files(d)
        out, rc = approve_rc(d, "P1-1", from_hook=False)
        check("0.3.4 v8 --from-hook 없음 → 승인·허용 안 됨", rc == 0 and rdir_files(d) == snap and not af(d).exists(), out)
        approve(d, "P1-4")
        lg = d / "docs/refactor/APPROVALS.log"
        lg.write_bytes(lg.read_bytes() + "2026-10-03 10:00 KST | 승인 | P1-3 | card=1.2 | 손으로\n".encode("utf-8"))
        snap = rdir_files(d)
        out = approve(d, "P1-1")
        check("0.3.4 v8 봉인 깨짐 → 승인·허용 안 됨", rdir_files(d) == snap and not af(d).exists() and "처리하지 않았습니다" in out, out)
    finally:
        shutil.rmtree(d, ignore_errors=True)

    # 승인 줄에 덧붙인 글이 있어 승인 뒤 "카드 바뀜"이 되는 카드 → 🔓 줄 없음 · 허용 안 열림
    d = project(plan=PLAN_033.replace("### [P1-1] 금액 계산\n- **종류**: 🛠 개선\n- **깨질 것으로 예상되는 기준선**: `tests/baseline/money.test.ts` 중 \"금액\" 항목\n- **승인**: [ ] 승인",
                                      "### [P1-1] 금액 계산\n- **종류**: 🛠 개선\n- **깨질 것으로 예상되는 기준선**: `tests/baseline/money.test.ts` 중 \"금액\" 항목\n- **승인**: [ ] 승인 (메모)"))
    try:
        out = approve(d, "P1-1")
        check("0.3.4 승인 뒤 바뀜이 되는 카드 → 허용 안 열림", not af(d).exists() and "🔓" not in out and "승인 뒤 카드가 바뀜" in out, out)
    finally:
        shutil.rmtree(d, ignore_errors=True)

    # v10(0.3.4 보완 F8) 자동으로 여는 것은 🛠 카드만: 🔧 카드(경로 있음)·종류 칸 없는 카드·둘 다 적힌 카드 → 안 열림 + ⚠️ 줄 /
    #     🛠️(변형 선택자 붙음) → 열림 / 수동 '허용 <ID>'는 그대로(🔧 카드도 0.3.3 처럼 받음)
    W_NOAUTO = "   ⚠️ 🛠 카드가 아니라 기준선 허용을 자동으로 열지 않았습니다 — 계획서를 확인하고 필요하면 /refactor:approve 허용 "
    card = lambda cid, kind: (f"\n### [{cid}] 카드 {cid}\n" + (f"- **종류**: {kind}\n" if kind is not None else "")
                              + f"- **깨질 것으로 예상되는 기준선**: `tests/baseline/{cid}.test.ts`\n- **승인**: [ ] 승인\n- **완료**: [ ] 완료\n")
    plan10 = ("# 계획서\n" + card("P1-1", "🔧 리팩토링") + card("P1-2", None) + card("P1-3", "🔧 리팩토링 / 🛠 개선(바뀌는 동작: 전 → 후)")
              + card("P1-4", "🛠️ 개선(금액 반올림 → 버림)") + card("P1-5", "🛠 개선"))
    for cid, name in (("P1-1", "🔧 카드"), ("P1-2", "종류 칸 없는 카드"), ("P1-3", "🔧·🛠 둘 다 적힌 카드(틀 그대로)")):
        d = project(plan=plan10)
        try:
            out = approve(d, cid)
            check(f"0.3.4 v10 {name} 승인 → 허용 안 생김 · ⚠️ 줄", not af(d).exists() and not allow_lines(d) and "🔓" not in out
                  and W_NOAUTO + cid in out and f"승인함: [{cid}]" in out, out)
        finally:
            shutil.rmtree(d, ignore_errors=True)
    d = project(plan=plan10)
    try:
        out = approve(d, "P1-4 P1-1 P1-5")
        check("0.3.4 v10 섞어서 승인 → 🛠 카드(P1-4 변형 선택자·P1-5)만 열림", ab(d) == b"P1-4 P1-5\n" and W_NOAUTO + "P1-1" in out
              and out.count("🔓 고칠 기준선") == 2 and intact(d), out)
        out = approve(d, "허용 P1-1")
        check("0.3.4 v10 수동 '허용 P1-1'(🔧 카드)은 그대로 받음", ab(d) == b"P1-4 P1-5 P1-1\n" and "🔓 기준선 허용:" in out, out)
    finally:
        shutil.rmtree(d, ignore_errors=True)


def check_protected_new_034(check):
    """0.3.4 보완 F1(f1): 턴 끝 알림(post-check)은 HEAD 에 없는 새 파일을 git add 해도 조용하다(기준선 단계의 새 기준선 ·
    단계 실행의 새 마이그레이션 · AM · git add -N). 반대 방향: 이미 커밋된 기준선·마이그레이션을 고치거나(' M'·'M ') 지우거나(' D'·'D ')
    이름을 바꾸면(git mv) 알림이 그대로 나온다."""
    g = _git034
    pc = lambda d: hook("post-check", d, {"session_id": "s1", "tool_name": "Bash"})

    def mk(phase):
        d = project(plan=PLAN_033)
        lf(d / "docs/refactor/STATE.md", STATE.replace("phase: PLAN", f"phase: {phase}").replace("gate: G2-plan", "gate: none"))
        (d / "tests/baseline").mkdir(parents=True)
        lf(d / "tests/baseline/old.test.ts", "x\n")
        (d / "supabase/migrations").mkdir(parents=True)
        lf(d / "supabase/migrations/001_a.sql", "a\n")
        g(d, "init", "-q"); g(d, "add", "-A"); g(d, "commit", "-qm", "i")
        if phase == "BASELINE":
            out = approve(d, "baseline")
            check("0.3.4 f1 준비: 기준선 계획 승인", "기준선 계획 승인: [x]" in (d / "docs/refactor/BASELINE.md").read_text(encoding="utf-8"), out)
        hook("turn", d, {"session_id": "s1", "prompt": "/refactor:go"})
        return d

    # 기준선 단계: 새 기준선 파일 → add → 0 · 올린 뒤 또 고침(AM) → 0 · 커밋 → 0 · git add -N(둘째 칸만 A) → 0
    d = mk("BASELINE")
    try:
        lf(d / "tests/baseline/new.test.ts", "n\n")
        g(d, "add", "--", "tests/baseline/new.test.ts")
        _, se, rc, _ = pc(d)
        check("0.3.4 f1 BASELINE 새 기준선 파일 git add('A ') → post-check 조용", rc == 0 and se == "", f"{rc} {se}")
        lf(d / "tests/baseline/new.test.ts", "n2\n")
        st = g(d, "status", "--porcelain", "--", "tests/baseline/new.test.ts")
        _, se, rc, _ = pc(d)
        check("0.3.4 f1 BASELINE 올린 뒤 또 고침('AM') → 조용", st.startswith("AM") and rc == 0, f"{st!r} {rc} {se}")
        g(d, "add", "--", "tests/baseline/new.test.ts"); g(d, "commit", "-qm", "test: 기준선 테스트 추가")
        _, se, rc, _ = pc(d)
        check("0.3.4 f1 BASELINE 커밋 뒤 → 조용", rc == 0, f"{rc} {se}")
        lf(d / "tests/baseline/n2.test.ts", "n\n")
        g(d, "add", "-N", "--", "tests/baseline/n2.test.ts")
        st = g(d, "status", "--porcelain", "--", "tests/baseline/n2.test.ts")
        _, se, rc, _ = pc(d)
        # (_git034 는 출력 앞뒤 공백을 떼므로 ' A x' 가 'A x' 로 온다 — 올린 꼴 'A  x' 와는 공백 수로 갈린다)
        check("0.3.4 f1 BASELINE git add -N(' A') → 조용", st == "A tests/baseline/n2.test.ts" and rc == 0, f"{st!r} {rc} {se}")
        # 반대 방향: 방금 커밋한 기준선(이제 커밋된 파일)을 고치면 알림
        lf(d / "tests/baseline/new.test.ts", "몰래\n")
        _, se, rc, _ = pc(d)
        check("0.3.4 f1 반대: 커밋된 기준선 고침(' M') → 알림", rc == 2 and " M tests/baseline/new.test.ts" in se and "n2.test.ts" not in se, f"{rc} {se}")
    finally:
        shutil.rmtree(d, ignore_errors=True)

    # 단계 실행: 새 마이그레이션 → add → 0 / 반대 방향: 커밋된 기준선·마이그레이션 고침·지움·이름 바꾸기 → 알림
    d = mk("EXECUTE")
    try:
        lf(d / "supabase/migrations/002_new.sql", "n\n")
        g(d, "add", "--", "supabase/migrations/002_new.sql")
        _, se, rc, _ = pc(d)
        check("0.3.4 f1 EXECUTE 새 마이그레이션 git add('A ') → 조용", rc == 0 and se == "", f"{rc} {se}")
        cases = [
            ("기준선 고침(' M')", " M tests/baseline/old.test.ts", lambda: lf(d / "tests/baseline/old.test.ts", "y\n"),
             lambda: g(d, "checkout", "-q", "--", "tests/baseline/old.test.ts")),
            ("기준선 고쳐 올림('M ')", "M  tests/baseline/old.test.ts",
             lambda: (lf(d / "tests/baseline/old.test.ts", "y\n"), g(d, "add", "--", "tests/baseline/old.test.ts")),
             lambda: (g(d, "reset", "-q", "--", "tests/baseline/old.test.ts"), g(d, "checkout", "-q", "--", "tests/baseline/old.test.ts"))),
            ("기준선 지움(' D')", " D tests/baseline/old.test.ts", lambda: (d / "tests/baseline/old.test.ts").unlink(),
             lambda: g(d, "checkout", "-q", "--", "tests/baseline/old.test.ts")),
            ("기준선 git rm('D ')", "D  tests/baseline/old.test.ts", lambda: g(d, "rm", "-q", "--", "tests/baseline/old.test.ts"),
             lambda: (g(d, "reset", "-q", "--", "tests/baseline/old.test.ts"), g(d, "checkout", "-q", "--", "tests/baseline/old.test.ts"))),
            ("기준선 git mv('R ')", "R  tests/baseline/moved.test.ts",
             lambda: g(d, "mv", "tests/baseline/old.test.ts", "tests/baseline/moved.test.ts"),
             lambda: g(d, "mv", "tests/baseline/moved.test.ts", "tests/baseline/old.test.ts")),
            ("마이그레이션 고침(' M')", " M supabase/migrations/001_a.sql", lambda: lf(d / "supabase/migrations/001_a.sql", "b\n"),
             lambda: g(d, "checkout", "-q", "--", "supabase/migrations/001_a.sql")),
            ("마이그레이션 git mv('R ')", "R  supabase/migrations/001_b.sql",
             lambda: g(d, "mv", "supabase/migrations/001_a.sql", "supabase/migrations/001_b.sql"),
             lambda: g(d, "mv", "supabase/migrations/001_b.sql", "supabase/migrations/001_a.sql")),
        ]
        for name, want, do, undo in cases:
            do()
            _, se, rc, _ = pc(d)
            check(f"0.3.4 f1 반대: 커밋된 {name} → 알림 그대로", rc == 2 and want in se and "002_new.sql" not in se, f"{rc} {se}")
            undo()
            _, se, rc, _ = pc(d)
            check(f"0.3.4 f1 반대: {name} 되돌린 뒤 → 조용", rc == 0, f"{rc} {se}")
    finally:
        shutil.rmtree(d, ignore_errors=True)

    # 재검사 R: 합치기 충돌로 같은 기준선 파일이 양쪽에서 더해진 꼴('AA' — HEAD 에 파일이 있음)은 새 파일 예외가 아니다 → 알림
    d = mk("EXECUTE")
    try:
        cur = g(d, "rev-parse", "--abbrev-ref", "HEAD")
        g(d, "checkout", "-q", "-b", "side")
        lf(d / "tests/baseline/aa.test.ts", "s\n"); g(d, "add", "--", "tests/baseline/aa.test.ts"); g(d, "commit", "-qm", "s")
        g(d, "checkout", "-q", cur)
        lf(d / "tests/baseline/aa.test.ts", "m\n"); g(d, "add", "--", "tests/baseline/aa.test.ts"); g(d, "commit", "-qm", "m")
        hook("turn", d, {"session_id": "s1", "prompt": "/refactor:go"})
        g(d, "merge", "-q", "side", check_rc=False)
        st = g(d, "status", "--porcelain", "--", "tests/baseline/aa.test.ts")
        _, se, rc, _ = pc(d)
        check("0.3.4 R 반대: 합치기 충돌('AA') 기준선 → 알림 그대로", st.startswith("AA") and rc == 2 and "AA tests/baseline/aa.test.ts" in se, f"{st!r} {rc} {se}")
        g(d, "merge", "--abort", check_rc=False)
    finally:
        shutil.rmtree(d, ignore_errors=True)


# 합치기 시험의 가짜 gh: 받은 인자(한 호출 한 줄)를 calls, 작업 폴더를 cwds 에 적고, 미리 정한 출력·종료 코드를 낸다.
# 응답은 같은 폴더의 <종류>.out / .err / .rc / .sleep(있으면 그 초만큼 잠 — exec 라 시간 한도가 바로 끊는다). 종류 = view · compare · merge · other
# .kid(0.3.4 보완 F7): 출력 통로를 물려받은 자식(그 초만큼 잠)을 남기고, 자기는 오래 자다가 TERM 에 죽는다(자식을 띄우는 gh 감싸개 꼴)
# 0.3.5: 종류별 호출 횟수(<종류>.n) — <종류>.then 에 적힌 번째 호출부터는 .out2 를 낸다(되풀이 조회 중 초록으로 바뀜).
#        FAKE_GH_GRANT(허락 파일 경로)가 있으면 합치기 호출 때 그 파일이 아직 있었는지 merge.grant 에 yes/no 로 적는다.
# 0.3.5 보완: <종류>.seqn = k 면 n 번째 호출은 .out.<min(n,k)> 를 낸다(호출마다 다른 응답 — F2 초록 두 번 연속) ·
#        <종류>.rmgrant / .regrant = n 이면 n 번째 호출 때 허락 파일을 지운다 / 2줄(시각)을 1 늘려 바꿔 쓴다(사람이 새로 입력한 꼴 — F9) ·
#        <종류>.delay = 그 초만큼 잔 뒤 평소대로 응답(F6).
# gh 로그인 정보는 다루지 않는다(환경 변수를 읽거나 적지 않음). 실제 GitHub 호출 0.
_FAKE_GH = """#!/usr/bin/env bash
d=${BASH_SOURCE[0]%/*}
printf '%s\\n' "$*" >> "$d/calls"
# 작업 폴더: Windows Git Bash 면 pwd -W 로 C:/… 꼴(MSYS 의 /tmp/… 꼴은 파이썬이 못 연다 — 0.3.4 보완 F5), 다른 OS 는 pwd -W 가 없어 그냥 pwd
printf '%s\\n' "$(pwd -W 2>/dev/null || pwd)" >> "$d/cwds"
case "$1 $2" in
  "pr view") k=view ;;
  "pr merge") k=merge ;;
  "api "*) k=compare ;;
  *) k=other ;;
esac
n=0; [ -f "$d/$k.n" ] && n=$(cat "$d/$k.n"); n=$((n + 1)); printf '%s\\n' "$n" > "$d/$k.n"
if [ "$k" = merge ] && [ -n "${FAKE_GH_GRANT:-}" ]; then if [ -e "$FAKE_GH_GRANT" ]; then echo yes; else echo no; fi >> "$d/merge.grant"; fi
o=out; [ -f "$d/$k.then" ] && [ "$n" -ge "$(cat "$d/$k.then")" ] && o=out2
if [ -f "$d/$k.seqn" ]; then m=$n; [ "$m" -gt "$(cat "$d/$k.seqn")" ] && m=$(cat "$d/$k.seqn"); o=out.$m; fi
if [ -n "${FAKE_GH_GRANT:-}" ] && [ -f "$d/$k.rmgrant" ] && [ "$n" = "$(cat "$d/$k.rmgrant")" ]; then rm -f "$FAKE_GH_GRANT"; fi
if [ -n "${FAKE_GH_GRANT:-}" ] && [ -f "$d/$k.regrant" ] && [ "$n" = "$(cat "$d/$k.regrant")" ]; then
  { sed -n 1p "$FAKE_GH_GRANT"; echo $(( $(sed -n 2p "$FAKE_GH_GRANT") + 1 )); sed -n 3p "$FAKE_GH_GRANT"; } > "$d/regrant.tmp" && mv -f "$d/regrant.tmp" "$FAKE_GH_GRANT"
fi
[ -f "$d/$k.delay" ] && sleep "$(cat "$d/$k.delay")"
[ -f "$d/$k.sleep" ] && exec sleep "$(cat "$d/$k.sleep")"
[ -f "$d/$k.stubborn" ] && { trap '' ALRM TERM; exec sleep "$(cat "$d/$k.stubborn")"; }
[ -f "$d/$k.kid" ] && { sleep "$(cat "$d/$k.kid")" & exec sleep 40; }
[ -f "$d/$k.err" ] && cat "$d/$k.err" >&2
[ -f "$d/$k.$o" ] && cat "$d/$k.$o"
exit "$(cat "$d/$k.rc" 2>/dev/null || echo 0)"
"""
_MG_JSON = "number,state,isDraft,isCrossRepository,baseRefName,headRefName,headRefOid,mergeable,statusCheckRollup"
_MG_AUTH = "gh 로그인 계정이 이 저장소에 쓰기 권한이 있는지 사람이 확인"
_MG_REF = "   (합치지 않았습니다 — 허락은 끝났습니다. 다시 하려면 사용자가 /refactor:approve 합치기)"
_MG_AGAIN = re.compile(r"   \(허락은 그대로입니다 — 약 \d+분 남음\. 같은 명령을 그대로 다시 실행하세요\.\)")
_MG_PLUG = (ROOT / "plugins/refactor").as_posix()
_MG_SCRIPT = (ROOT / "plugins/refactor/scripts/refactor-merge.sh").as_posix()
_MG_APPROVE = (ROOT / "plugins/refactor/scripts/refactor-approve.sh").as_posix()
# 시험용으로 줄인 한도(실제 초를 오래 기다리지 않게 — 스크립트 머리 주석의 줄이기 전용 환경 변수).
#   0.3.5 보완 F2: 초록 두 번 연속을 확인하려면 창이 있어야 한다 → 창은 기본값(20) · 간격 0. 도는 중을 창 없이 보는 시험은 _MG_W0 를 더한다
_MG_FAST = dict(REFACTOR_MERGE_VIEW_LIMIT="3", REFACTOR_MERGE_CMP_LIMIT="3", REFACTOR_MERGE_MERGE_LIMIT="3", REFACTOR_MERGE_FETCH_LIMIT="3",
                REFACTOR_MERGE_WINDOW="20", REFACTOR_MERGE_INTERVAL="0")
_MG_W0 = {"REFACTOR_MERGE_WINDOW": "0"}


def _same034(a, b):
    """같은 폴더인가 — 경로를 못 열면(다른 OS 꼴 경로 등) 예외 대신 거짓(0.3.4 보완 F5: Windows CI 에서 시험 전체가 멈췄음)."""
    try:
        return os.path.samefile(a, b)
    except (OSError, ValueError):
        return False


def _jqv034(pr):
    """합치기 스크립트의 pr view --jq 식(JQV)이 내는 글자를 파이썬으로 흉내(가짜 gh 는 jq 를 못 돌린다): 첫 줄 = PR 칸 8개, 그다음 검사마다 한 줄 — 칸 구분 \\x1f."""
    def s(v):
        return "true" if v is True else "false" if v is False else str(v)
    alt = lambda *vs: next((v for v in vs if v not in (None, False)), "-")
    rows = ["\x1f".join(s(pr[k]) for k in ("number", "state", "isDraft", "isCrossRepository", "baseRefName", "headRefName", "headRefOid", "mergeable"))]
    for c in pr.get("statusCheckRollup") or []:
        rows.append("\x1f".join(s(v) for v in (alt(c.get("__typename")), alt(c.get("status")), alt(c.get("conclusion")),
                                                 alt(c.get("state")), alt(c.get("name"), c.get("context")))))
    return "".join(r + "\n" for r in rows)


def _path_without_gh(path, names=("gh",)):
    """PATH 에서 names(기본 gh)를 뺀 것: 그 이름이 든 폴더는 그것만 뺀 바로가기 폴더로 바꾼다(그 폴더의 git·awk 등은 그대로 쓰게). 만든 임시 폴더 목록도 돌려준다."""
    drop = {n.lower() for n in names} | {n.lower() + ".exe" for n in names}
    out, made = [], []
    for p in path.split(os.pathsep):
        if not p:
            continue
        if not any(os.path.isfile(os.path.join(p, n)) for n in drop):
            out.append(p)
            continue
        m = tempfile.mkdtemp(prefix="nogh-")
        made.append(m)
        try:
            for n in os.listdir(p):
                if n.lower() in drop:
                    continue
                try:
                    os.symlink(os.path.join(p, n), os.path.join(m, n))
                except OSError:
                    pass
        except OSError:
            pass
        out.append(m)
    return os.pathsep.join(out), made


def _fake035(made, head=None, pr=None, pr2=None, view_then=None, view_raw=None, view_rc=0, view_err="", view_sleep=None, view_stubborn=None,
             view_kid=None, behind="0", cmp_rc=0, cmp_err="", cmp_sleep=None, merge_rc=0, merge_err="", merge_sleep=None,
             view_seq=None, view_rmgrant=None, view_regrant=None, view_delay=None, **prk):
    """가짜 gh 폴더를 만든다. pr 칸은 기본값(전부 맞음 — 머리 커밋 = head) 위에 pr·prk 로 덮어쓴다.
    view_then = n 이면 n 번째 조회부터 pr2(기본값 위에 덮어씀)를 낸다. view_raw = 조회 출력 글자 그대로.
    view_seq = [칸 dict, …] 면 n 번째 조회는 n 번째 것(넘으면 마지막 것 — 기본값 위에 덮어씀) · view_rmgrant / view_regrant = n 번째 조회 때
    허락 파일을 지움 / 바꿔 씀 · view_delay = 조회마다 그 초만큼 늦게 응답."""
    fg = pathlib.Path(tempfile.mkdtemp(prefix="fakegh-"))
    made.append(str(fg))
    (fg / "gh").write_bytes(_FAKE_GH.encode("utf-8"))
    os.chmod(fg / "gh", 0o755)
    base = dict(number=68, state="OPEN", isDraft=False, isCrossRepository=False, baseRefName="main", headRefName="feat/x",
                headRefOid=head or "0" * 40, mergeable="MERGEABLE",
                statusCheckRollup=[{"__typename": "CheckRun", "name": "test", "status": "COMPLETED", "conclusion": "SUCCESS"}])
    p = dict(base); p.update(pr or {}); p.update(prk)
    (fg / "view.out").write_bytes((view_raw if view_raw is not None else _jqv034(p)).encode("utf-8"))
    if view_then:
        p2 = dict(base); p2.update(pr2 or {})
        (fg / "view.out2").write_bytes(_jqv034(p2).encode("utf-8"))
        (fg / "view.then").write_text(str(view_then))
    if view_seq:
        for i, sp in enumerate(view_seq, 1):
            ps = dict(base); ps.update(sp)
            (fg / f"view.out.{i}").write_bytes(_jqv034(ps).encode("utf-8"))
        (fg / "view.seqn").write_text(str(len(view_seq)))
    for k, rc, err in (("view", view_rc, view_err), ("compare", cmp_rc, cmp_err), ("merge", merge_rc, merge_err)):
        (fg / f"{k}.rc").write_text(str(rc))
        if err:
            (fg / f"{k}.err").write_bytes((err + "\n").encode("utf-8"))
    (fg / "compare.out").write_bytes((behind + "\n").encode("utf-8"))
    (fg / "merge.out").write_bytes(b"")
    (fg / "other.rc").write_text("1")
    for k, v in (("view.sleep", view_sleep), ("view.stubborn", view_stubborn), ("view.kid", view_kid),
                 ("compare.sleep", cmp_sleep), ("merge.sleep", merge_sleep),
                 ("view.rmgrant", view_rmgrant), ("view.regrant", view_regrant), ("view.delay", view_delay)):
        if v:
            (fg / k).write_text(str(v))
    return fg


def _calls035(fg):
    c = pathlib.Path(fg) / "calls"
    return c.read_text(encoding="utf-8").splitlines() if c.exists() else []


def _kinds035(c):
    """가짜 gh 호출 목록 → (조회, 비교, 합치기) 횟수"""
    return (sum(1 for x in c if x.startswith("pr view")), sum(1 for x in c if x.startswith("api ")),
            sum(1 for x in c if x.startswith("pr merge")))


def _gf035(d, sid="s1"):
    return pathlib.Path(d) / "docs/refactor" / f".turn-merge.{sid}"


def _mk035(approve_first=True, origin=None):
    """main(승인 P1-1 이 커밋됨) → origin/main = 그 커밋 → feat/x 에서 커밋 하나. origin 주소는 없는 로컬 경로(받아 오기는 실패 — 네트워크 0).
    origin = 맨 저장소 경로면 그리로 main 을 올려 둔다(받아 오기 성공 길 — 로컬 경로라 네트워크 0)."""
    g = _git034
    d = project(plan=PLAN_033)
    g(d, "init", "-q"); g(d, "symbolic-ref", "HEAD", "refs/heads/main")
    g(d, "remote", "add", "origin", str(origin or (d.parent / "no-such-origin.git")))
    lf(d / "a.txt", "a\n")
    if approve_first:
        approve(d, "P1-1")
    g(d, "add", "--", "a.txt", "docs"); g(d, "commit", "-qm", "i")
    if origin:
        g(d, "push", "-q", "origin", "main")
        g(d, "fetch", "-q", "origin")
    else:
        g(d, "update-ref", "refs/remotes/origin/main", "HEAD")
    g(d, "checkout", "-q", "-b", "feat/x")
    lf(d / "b.txt", "b\n"); g(d, "add", "--", "b.txt"); g(d, "commit", "-qm", "b")
    return d


def _grant035(d, args="합치기 68 rebase", sid="s1", made=None):
    """사람이 /refactor:approve <args> 를 친 것처럼 승인 스크립트(입력 훅 꼴)로 허락 파일을 만든다 — PATH 맨 앞에 호출되면 안 되는 가짜 gh."""
    fg = _fake035(made if made is not None else [])
    out, _ = _ap034(d, args, extra_env={"REFACTOR_TURN_SID": sid}, path=str(fg) + os.pathsep + env()["PATH"])
    return out, fg


def _set_grant035(d, sid="s1", ago=None, line1=None, line3=None, crlf=False):
    """허락 파일의 칸을 바꿔 쓴다(ago = 만든 시각을 지금보다 몇 초 앞으로)."""
    p = _gf035(d, sid)
    if not p.is_file():   # 앞 시험이 허락을 지운 경우(빨강) — 예외로 묶음 전체가 멈추지 않게 그냥 둔다(다음 check 가 실패로 센다)
        return
    ln = p.read_text(encoding="utf-8").split("\n")
    if ago is not None:
        ln[1] = str(int(time.time()) - ago)
    if line1 is not None:
        ln[0] = line1
    if line3 is not None:
        ln[2] = line3
    p.write_bytes(("\r\n" if crlf else "\n").join(ln).encode("utf-8"))


def _mg035(d, sid="s1", path=None, extra_env=None, argv=None, fg=None, direct=False):
    """Claude 가 허락된 명령을 실행하는 것처럼 run.sh refactor-merge <프로젝트> <세션ID> → (출력, 종료 코드, 걸린 초).
    한도는 줄인 값(_MG_FAST). fg = 가짜 gh 폴더(PATH 맨 앞). direct = run.sh 없이 스크립트를 바로(REFACTOR_ROOT 는 extra_env 로)."""
    e = env()
    e["GIT_CEILING_DIRECTORIES"] = str(pathlib.Path(d).parent)
    e.pop("REFACTOR_ROOT", None)
    e.update(_MG_FAST)
    e["FAKE_GH_GRANT"] = _gf035(d, sid).as_posix()
    if fg is not None:
        e["PATH"] = str(fg) + os.pathsep + e["PATH"]
    if path is not None:
        e["PATH"] = path
    if extra_env:
        e.update(extra_env)
    args = [str(d), sid] if argv is None else argv
    cmd = [BASH, _MG_SCRIPT, *args] if direct else [BASH, str(RUN), "refactor-merge", *args]
    t0 = time.perf_counter()
    r = subprocess.run(cmd, capture_output=True, env=e, timeout=90)
    return r.stdout.decode("utf-8", "replace") + r.stderr.decode("utf-8", "replace"), r.returncode, time.perf_counter() - t0


def _seal_bytes035(d):
    """승인 기록·봉인·턴 스냅숏의 바이트(I5 — 합치기 스크립트는 이것을 건드리지 않는다)"""
    r = pathlib.Path(d) / "docs/refactor"
    out = {}
    for p in [r / "APPROVALS.log", r / "approved/.log-sum", r / "approved/.log-copy", r / ".gitattributes", *sorted(r.glob(".turn-dirty.*"))]:
        out[p.name] = p.read_bytes() if p.exists() else None
    return out


def check_merge_grant_035(check):
    """0.3.5 §3: /refactor:approve 합치기 = 허락 파일 3줄 + 기록 한 줄만(H1~H11 — 가짜 gh 호출 0) · §6 T1 입력 훅이 다음 사람 입력에 지움."""
    g = _git034
    intact = lambda d: _lib033(d, 'rl_log_intact "$R" && echo yes')[0] == "yes\n"
    made = []
    fgs = []
    TAIL = "합치기 허락을 만들지 않았습니다"

    def ap(d, args, sid="s1", from_hook=True, path=None):
        fg = _fake035(made)
        fgs.append(fg)
        out, _ = _ap034(d, args, from_hook=from_hook, extra_env={"REFACTOR_TURN_SID": sid},
                        path=path if path is not None else str(fg) + os.pathsep + env()["PATH"])
        return out

    def projp(d):
        return str(d).replace("\\", "/").rstrip("/")

    def mcmd(d, sid="s1"):
        return f'bash "{_MG_PLUG}/hooks/run.sh" refactor-merge "{projp(d)}" {sid}'

    def granted(name, d, args, br, pr, mth, sid="s1", prw=None):
        """허락: 파일 3줄이 §2 꼴 그대로 · 기록 1줄 + 봉인 · H10 문구 전체"""
        _gf035(d, sid).unlink(missing_ok=True)
        hoid = g(d, "rev-parse", "HEAD")
        n0 = _log033(d).count("\n")
        out = ap(d, args, sid=sid)
        raw = _gf035(d, sid).read_bytes() if _gf035(d, sid).exists() else b""
        ln = raw.decode("utf-8").split("\n")
        ok = (b"\r" not in raw and len(ln) == 4 and ln[3] == "" and ln[0] == f"merge {br} {pr} {mth} {hoid}" and ln[1].isdigit()
              and abs(int(ln[1]) - time.time()) < 600 and ln[2] == mcmd(d, sid))
        check(f"0.3.5 H8 '{args}' → 허락 파일 3줄(§2 꼴)", ok, f"{ln!r}\n{out}")
        prw = prw or (f"PR #{pr}" if pr != "-" else "PR(지금 가지)")   # 0.3.5 보완 F7①: 번호 없으면 "PR(지금 가지)"
        lt = _log033(d)
        check(f"0.3.5 H9 '{args}' → 기록 1줄 · 봉인 일치", lt.count("\n") == n0 + 1
              and lt.endswith(f" KST | 합치기 | 허락 {br} {prw} ({mth}) @{hoid[:7]} | - | 사용자가 /refactor:approve 로 실행\n") and intact(d), lt[-300:])
        prs = f" #{pr}" if pr != "-" else ""
        want = "\n".join([
            f"✅ 합치기 허락: 작업 가지 {br} 의 PR{prs} 을 {mth} 방식으로 — 이번 차례에만(다음 입력부터 다시 막힘 · 30분 안) · 지금 커밋({hoid[:7]})일 때만.",
            "   Claude 가 이번 차례에 Bash 도구로 아래 명령을 그대로 실행합니다(다른 것을 붙이지 않음):",
            "   " + mcmd(d, sid),
            "   스크립트가 확인한 뒤 합칩니다: 자동 검사가 모두 끝나 초록(도는 중이면 \"같은 명령을 다시\"가 나옵니다 — 끝날 때까지 되풀이) · 기본 가지에 새 커밋 없음 · PR 의 마지막 커밋 = 지금 커밋.",
            "   하나라도 어긋나면 합치지 않고 허락도 끝납니다(다시 하려면 /refactor:approve 합치기).",
            "   ⚠️ 기본 가지에 합쳐지면 운영 배포가 시작될 수 있습니다.",
            "   ⚠️ 허락한 뒤 최대 30분 사이에는 사람이 보고 있지 않아도 조건이 맞으면 합쳐지고 운영 배포가 시작될 수 있습니다 — 멈추려면 아무 말이나 입력하세요(다음 입력에 허락이 끝납니다 · Claude 가 실행 중이면 Esc 로 멈춘 뒤).",
        ])
        check(f"0.3.5 H10 '{args}' → 결과 문구", want + "\n" in out, out)
        return out

    def refused(name, d, args, want, sid="s1", tail=True, **kw):
        """거절: 허락 파일 없음 · 기록 그대로 · 까닭 문구(· 꼬리)"""
        for p in (d / "docs/refactor").glob(".turn-merge.*"):
            if p.is_file():
                p.unlink()
        before = _log033(d)
        out = ap(d, args, sid=sid, **kw)
        ok = (want in out and not [p for p in (d / "docs/refactor").glob(".turn-merge.*") if p.is_file()]
              and _log033(d) == before and "✅ 합치기 허락" not in out)
        if tail:
            ok = ok and TAIL in out
        check(f"0.3.5 {name} → 허락 안 만듦", ok, out)
        return out

    d = _mk035()
    try:
        # H8~H10 같은 결과 다른 입력(번호 없음 · 순서 · # · 한글 방식 · 대소문자 · 공백 둘 · 끝 마침표 · 앞 0)
        for args, pr, mth in (("합치기 68 rebase", "68", "rebase"), ("합치기 rebase", "-", "rebase"), ("합치기 rebase 68", "68", "rebase"),
                              ("MERGE #68 스쿼시", "68", "squash"), ("merge 68 병합", "68", "merge"), ("merge 68 merge", "68", "merge"),
                              ("합치기  68  Rebase.", "68", "rebase"), ("합치기 리베이스", "-", "rebase"), ("합치기 0068 squash", "68", "squash")):
            granted("", d, args, "feat/x", pr, mth)
        # H5 PROFILE 방식 · 입력이 PROFILE 보다 먼저
        for line, mth in (("- PR 합치는 방식: squash", "squash"), ("- PR 합치는 방식: `Rebase`  ", "rebase"), ("- PR 합치는 방식: MERGE\r", "merge")):
            lf(d / "docs/refactor/PROFILE.md", "# 프로젝트\n" + line + "\n")
            granted("", d, "합치기", "feat/x", "-", mth)
        granted("", d, "합치기 68 rebase", "feat/x", "68", "rebase")
        (d / "docs/refactor/PROFILE.md").unlink()
        refused("H5 방식 없음 + PROFILE 없음", d, "합치기 68", "방식을 붙여 다시: /refactor:approve 합치기 rebase")
        for name, line in (("템플릿 문장 그대로", "- PR 합치는 방식: (처음 합칠 때 Claude 가 묻고 rebase / squash / merge 중 하나만 적음)"),
                           ("낱말 둘", "- PR 합치는 방식: rebase squash"), ("빈 값", "- PR 합치는 방식:"), ("빈 백틱", "- PR 합치는 방식: ``")):
            lf(d / "docs/refactor/PROFILE.md", "# 프로젝트\n" + line + "\n")
            refused(f"H5 PROFILE {name}", d, "합치기 68", "방식을 붙여 다시")
        (d / "docs/refactor/PROFILE.md").unlink()

        # H1 같은 결과 다른 철자(섞임 — 공통 문구) · 넘기면 안 되는 옵션(알아듣지 못한 입력)
        refused("H1 '합치기68'(한 낱말 — 합치기 모드 아님)", d, "합치기68", "❓ 알아듣지 못한 입력: 합치기68", tail=False)
        for args in ("합치기 68 rebase squash", "합치기 68 69", "68 합치기", "합치기 푸시", "합치기 P1-1", "합치기 baseline",
                     "합치기 68 rebase 확인", "보류 합치기", "합치기 새 가지"):
            refused(f"H1 '{args}'", d, args, "아무것도 바꾸지 않았습니다", tail=False)
        for args in ("합치기 68 --admin", "합치기 68 --auto", "합치기 68 --delete-branch", "합치기 68 -d", "합치기 68 rebase --admin",
                     "합치기 --squash 68", "합치기 68 rebase -- --admin", "합치기 68 rebase; rm -rf x"):
            refused(f"H1 '{args}'(알아듣지 못한 입력)", d, args, "알아듣지 못한 입력")
        # H3 세션 ID
        refused("H3 세션 ID 없음", d, "합치기 68 rebase", "⚠️ 대화(세션) 정보를 받지 못했습니다", sid="")
        refused("H3 세션 ID 꼴이 이상함", d, "합치기 68 rebase", "⚠️ 대화(세션) 정보를 받지 못했습니다", sid="../x")
        refused("H3 세션 ID 129자", d, "합치기 68 rebase", "⚠️ 대화(세션) 정보를 받지 못했습니다", sid="a" * 129)
        out = granted("", d, "합치기 68 rebase", "feat/x", "68", "rebase", sid="Ab_9-z")
        _gf035(d, "Ab_9-z").unlink(missing_ok=True)
        # H4 가지
        g(d, "checkout", "-q", "main")
        refused("H4 기본 가지 위", d, "합치기 68 rebase", "지금 가지가 기본 가지(main)입니다")
        g(d, "checkout", "-q", "--detach", "feat/x")
        refused("H4 떨어진 HEAD", d, "합치기 68 rebase", "지금 가지가 없습니다")
        g(d, "checkout", "-q", "-b", "feat+x")
        refused("H4 가지 이름에 허용 밖 글자", d, "합치기 68 rebase", "❓ 가지 이름(feat+x)에 영문·숫자·._/- 밖의 글자가 있어 허락할 수 없습니다 — 사람이 GitHub 화면에서 합쳐 주세요")
        g(d, "symbolic-ref", "HEAD", "refs/heads/-x")
        refused("H4 가지 이름 첫 글자 -", d, "합치기 68 rebase", "❓ 이 가지 이름(-x)은 허락할 수 없습니다(첫 글자가 - . / 임) — 사람이 GitHub 화면에서 합쳐 주세요")
        g(d, "update-ref", "refs/heads/_x", "feat/x")
        g(d, "symbolic-ref", "HEAD", "refs/heads/_x")
        granted("", d, "합치기 squash", "_x", "-", "squash")
        g(d, "checkout", "-q", "feat/x")
        g(d, "update-ref", "-d", "refs/remotes/origin/main")
        refused("H4 origin 기본 가지 없음", d, "합치기 68 rebase", "origin 의 기본 가지를 찾지 못했습니다")
        g(d, "update-ref", "refs/remotes/origin/main", "main")
        # H6 gh 없음
        nogh, m2 = _path_without_gh(env()["PATH"])
        made.extend(m2)
        refused("H6 gh 없음", d, "합치기 68 rebase", "gh(GitHub CLI)를 찾지 못했습니다", path=nogh)
        # H8 허락 파일 자리에 폴더 → 못 씀
        (d / "docs/refactor/.turn-merge.s1").mkdir()
        before = _log033(d)
        out = ap(d, "합치기 68 rebase")
        check("0.3.5 H8 허락 파일 자리가 폴더 → '쓰지 못했습니다' · 기록 그대로", "⚠️ 합치기 허락 파일을 쓰지 못했습니다" in out and TAIL in out
              and _log033(d) == before and not any((d / "docs/refactor/.turn-merge.s1").iterdir()), out)
        shutil.rmtree(d / "docs/refactor/.turn-merge.s1")
        # H9 기록을 못 씀(기록 자리에 폴더) → 허락 파일 지움 · 거절(0.3.5 보완 F13)
        logp = d / "docs/refactor/APPROVALS.log"
        keep = logp.read_bytes()
        logp.unlink()
        logp.mkdir()
        try:
            out = ap(d, "합치기 68 rebase")
            check("0.3.5 F13 승인 기록을 못 씀 → 허락 파일 없음 · '승인 기록을 쓰지 못해'",
                  "⚠️ 승인 기록을 쓰지 못해 합치기 허락을 만들지 않았습니다" in out and TAIL in out and "✅ 합치기 허락" not in out
                  and not [p for p in (d / "docs/refactor").glob(".turn-merge.*")], out)
        finally:
            shutil.rmtree(logp, ignore_errors=True)
            logp.write_bytes(keep)
        # F14 푸시 모드의 안내 두 줄: PR 합치기는 /refactor:approve 합치기 로(옛 "사람이 터미널에서 / 계속 막힙니다" 없음)
        g(d, "checkout", "-q", "main")
        out = ap(d, "푸시")
        check("0.3.5 F14 기본 가지에서 푸시 → '기본 가지 올리기는 사람이 터미널에서 · PR 합치기는 /refactor:approve 합치기 로 합니다.'",
              "   기본 가지 올리기는 사람이 터미널에서 · PR 합치기는 /refactor:approve 합치기 로 합니다.\n" in out
              and "PR 합치기는 사람이 터미널에서" not in out, out)
        g(d, "checkout", "-q", "feat/x")
        out = ap(d, "푸시")
        check("0.3.5 F14 작업 가지 푸시 허락 → '기본 가지 올리기·강제 push 는 계속 막힙니다 · PR 합치기는 /refactor:approve 합치기 로.'",
              "✅ push 허락" in out and "   기본 가지 올리기·강제 push 는 계속 막힙니다 · PR 합치기는 /refactor:approve 합치기 로.\n" in out
              and "PR 합치기는 계속 막힙니다" not in out, out)
        for p in (d / "docs/refactor").glob(".turn-push.*"):
            p.unlink()
        # --from-hook 없음 → 아무것도 안 바뀜 · 봉인 깨짐 → 처리 안 함
        before = rdir_files(d)
        out = ap(d, "합치기 68 rebase", from_hook=False)
        check("0.3.5 H --from-hook 없음 → 안 바뀜", rdir_files(d) == before and not _gf035(d).exists() and "✅" not in out, out)
        logp = d / "docs/refactor/APPROVALS.log"
        keep = logp.read_bytes()
        logp.write_bytes(keep + "2026-10-04 09:00 KST | 승인 | P1-9 | card=x | 손으로\n".encode("utf-8"))
        refused("H 봉인 깨짐", d, "합치기 68 rebase", "처리하지 않았습니다", tail=False)
        logp.write_bytes(keep)
        # H7 특수 글자 경로(프로젝트 폴더) — 반대 방향: 공백·괄호·작은따옴표는 허락(큰따옴표 한 쌍 안에서 그대로)
        cases = [("$", True), ("`", True), (" (사본) '1'", False)]
        if os.name != "nt":
            cases.append(('"', True))
        for ch, bad in cases:
            nd = d.parent / (d.name + "-x" + ch + "y")
            d.rename(nd)
            try:
                if bad:
                    refused(f"H7 프로젝트 폴더에 {ch!r}", nd, "합치기 68 rebase", "❓ 플러그인·프로젝트 폴더 경로에 특수 글자가 있어")
                else:
                    granted("", nd, "합치기 68 rebase", "feat/x", "68", "rebase")
                    _gf035(nd).unlink(missing_ok=True)
            finally:
                nd.rename(d)
        # H7 플러그인 경로(REFACTOR_ROOT) — 승인 스크립트를 run.sh 없이 바로(REFACTOR_ROOT 를 시험이 정함)
        for name, root in (("비어 있음", None), ("$ 들어감", "plug$x"), ("백틱 들어감", "plug`x")):
            e = env()
            e["GIT_CEILING_DIRECTORIES"] = str(d.parent)
            e["REFACTOR_TURN_SID"] = "s1"
            fg = _fake035(made)
            fgs.append(fg)
            e["PATH"] = str(fg) + os.pathsep + e["PATH"]
            e.pop("REFACTOR_ROOT", None)
            if root:
                rt = pathlib.Path(tempfile.mkdtemp(prefix="mgroot-")) / root
                made.append(str(rt.parent))
                (rt / "scripts").mkdir(parents=True)
                shutil.copy(ROOT / "plugins/refactor/scripts/refactor-lib.sh", rt / "scripts/refactor-lib.sh")
                e["REFACTOR_ROOT"] = rt.as_posix()
            before = _log033(d)
            r = subprocess.run([BASH, _MG_APPROVE, str(d), "--from-hook"], input="합치기 68 rebase".encode("utf-8"), capture_output=True, env=e, timeout=90)
            out = r.stdout.decode("utf-8", "replace") + r.stderr.decode("utf-8", "replace")
            check(f"0.3.5 H7 플러그인 경로 {name} → 허락 안 만듦", "❓ 플러그인·프로젝트 폴더 경로에 특수 글자가 있어" in out and TAIL in out
                  and not _gf035(d).exists() and _log033(d) == before, out)
        # H2 마무리 확인 뒤 → 안내만
        d2 = _mk035(approve_first=False)
        made.append(str(d2))
        approve(d2, "마무리")
        before = _log033(d2)
        out = ap(d2, "합치기 68 rebase")
        check("0.3.5 H2 마무리 뒤 → 평소처럼 합칠 수 있음 안내 · 허락·기록 그대로", "평소처럼 합칠 수 있습니다" in out and not _gf035(d2).exists()
              and _log033(d2) == before, out)
        # H4 git 저장소 아님
        nd = project(plan=PLAN_033)
        made.append(str(nd))
        approve(nd, "P1-1")
        refused("H4 git 저장소 아님", nd, "합치기 68 rebase", "git 저장소가 아니라")
        # H11 이 묶음의 어떤 입력에서도 gh 호출 0
        allc = [x for fg in fgs for x in _calls035(fg)]
        check(f"0.3.5 H11 입력 훅의 합치기 모드는 gh 를 부르지 않음({len(fgs)}번 실행)", allc == [] and len(fgs) >= 50, "\n".join(allc))
    finally:
        shutil.rmtree(d, ignore_errors=True)
        for m in made:
            shutil.rmtree(m, ignore_errors=True)

    # T1 입력 훅: 허락은 그 세션의 다음 사람 입력 때 지움 · 알림 입력·다른 세션은 그대로 · 결과 블록에 허락 문구
    made = []
    d = _mk035()
    try:
        fg = _fake035(made)
        pe = {"PATH": str(fg) + os.pathsep + env()["PATH"]}
        mkp = lambda: hook("turn", d, {"session_id": "s1", "prompt": "/refactor:approve 합치기 68 rebase"}, extra_env=pe)
        so, se, rc, _ = mkp()
        ln = _gf035(d).read_text(encoding="utf-8").split("\n") if _gf035(d).exists() else []
        check("0.3.5 T1 입력 훅의 /refactor:approve 합치기 → 허락 파일 · 결과 블록", rc == 0 and len(ln) == 4 and ln[2] == mcmd(d)
              and "[Vibe Refactor 승인 처리 결과 — 입력 훅]" in so and "✅ 합치기 허락: 작업 가지 feat/x 의 PR #68 을 rebase 방식으로" in so, so + se)
        so, se, rc, _ = hook("turn", d, {"session_id": "s1", "prompt": "<command-name>/refactor:approve</command-name><command-args>합치기 squash</command-args>"}, extra_env=pe)
        ln = _gf035(d).read_text(encoding="utf-8").split("\n") if _gf035(d).exists() else []
        check("0.3.5 T1 슬래시 명령 꼴 입력 → 새 허락(방식 squash · 번호 없음)", ln[:1] and ln[0].startswith("merge feat/x - squash "), so + se)
        hook("turn", d, {"session_id": "s1", "prompt": "고마워, 계속해 줘"})
        check("0.3.5 T1 다음 사람 입력(보통 문장) → 지워짐", not _gf035(d).exists())
        mkp()
        hook("turn", d, {"session_id": "s1", "prompt": "/refactor:status"})
        check("0.3.5 T1 다음 사람 입력(다른 슬래시 명령) → 지워짐", not _gf035(d).exists())
        mkp()
        hook("turn", d, {"session_id": "s1", "prompt": "<task-notification>\n<task-id>x</task-id>\n</task-notification>"})
        check("0.3.5 T1 알림 입력 → 그대로", _gf035(d).exists())
        hook("turn", d, {"session_id": "s1", "prompt": "<system-reminder>x</system-reminder>"})
        check("0.3.5 T1 알림 입력(system-reminder) → 그대로", _gf035(d).exists())
        hook("turn", d, {"session_id": "s2", "prompt": "안녕"})
        check("0.3.5 T1 다른 세션의 입력 → 그대로", _gf035(d).exists())
        so, se, rc, _ = hook("turn", d, {"session_id": "s1", "prompt": "/refactor:approve"}, extra_env=pe)
        check("0.3.5 T1 /refactor:approve(현황)도 사람 입력 → 지워짐", not _gf035(d).exists(), so)
        mkp()
        hook("turn", d, {"session_id": "s1", "prompt": "/refactor:approve 푸시"}, extra_env=pe)
        check("0.3.5 T1 /refactor:approve 푸시 → 합치기 허락은 지워짐", not _gf035(d).exists())
        check("0.3.5 T1 입력 훅의 합치기 허락도 gh 호출 0", _calls035(fg) == [], "\n".join(_calls035(fg)))
    finally:
        shutil.rmtree(d, ignore_errors=True)
        for m in made:
            shutil.rmtree(m, ignore_errors=True)


def check_merge_script_035(check):
    """0.3.5 §4: scripts/refactor-merge.sh S0~S20(S11 은 check_merge_s11_035) — 줄마다 문구 머리 · 종료 코드 · 허락 남음/지움 · 가짜 gh 호출 횟수.
    덧붙여 승인 기록·봉인 바이트 그대로(I5 — 모든 실행 앞뒤) · 합치기 인자 정확히 · 되풀이 조회 · 검사 0개 120초 · 0.3.4 g1~g14 짝."""
    g = _git034
    intact = lambda d: _lib033(d, 'rl_log_intact "$R" && echo yes')[0] == "yes\n"
    made = []
    all_calls = []

    def case(name, d, fg, head, rc, kept, n=None, tail=None, sid="s1", **kw):
        """n = (조회, 비교, 합치기) 횟수. tail = 'ref'(거절 꼬리) · 'again'(다시 안내) · None"""
        seal = _seal_bytes035(d)
        out, r, secs = _mg035(d, sid=sid, fg=fg, **kw)
        c = _calls035(fg) if fg is not None else []
        all_calls.extend(c)
        ok = head in out and r == rc and _gf035(d, sid).exists() == kept and _seal_bytes035(d) == seal
        if n is not None:
            ok = ok and _kinds035(c) == n
        if tail == "ref":
            ok = ok and _MG_REF in out
        elif tail == "again":
            ok = ok and bool(_MG_AGAIN.search(out))
        check(f"0.3.5 {name}", ok, f"rc={r} 허락={'있음' if _gf035(d, sid).exists() else '없음'} 호출={_kinds035(c)} {secs:.1f}초\n{out}\n--- 호출:\n" + "\n".join(c))
        return out, c, secs

    def fresh(args="합치기 68 rebase", sid="s1"):
        _grant035(d, args, sid=sid, made=made)
        return _gf035(d, sid).exists()

    CR = lambda n, st="COMPLETED", co="SUCCESS": {"__typename": "CheckRun", "name": n, "status": st, "conclusion": co}
    SC = lambda n, s: {"__typename": "StatusContext", "context": n, "state": s}
    PEND = [CR("a"), CR("build", "IN_PROGRESS", None)]
    d = _mk035()
    try:
        hoid = g(d, "rev-parse", "HEAD")
        F = lambda **kw: _fake035(made, head=hoid, **kw)
        st0 = _lib033(d, 'rl_cards "$R/REFACTOR_PLAN.md" "$R/APPROVALS.log"')[0]

        # S17 전부 통과 — 허락 3줄째 명령 글자 그대로를 셸로(Claude 가 Bash 도구로 그대로 치는 것)
        check("0.3.5 S17 준비: 허락", fresh())
        line3 = _gf035(d).read_text(encoding="utf-8").split("\n")[2]
        fg = F()
        seal = _seal_bytes035(d)
        e = env(); e.pop("REFACTOR_ROOT", None); e.update(_MG_FAST)
        e["PATH"] = str(fg) + os.pathsep + e["PATH"]; e["GIT_CEILING_DIRECTORIES"] = str(d.parent); e["FAKE_GH_GRANT"] = _gf035(d).as_posix()
        r = subprocess.run([BASH, "-c", line3], capture_output=True, env=e, timeout=90)
        out = r.stdout.decode("utf-8", "replace") + r.stderr.decode("utf-8", "replace")
        c = _calls035(fg)
        all_calls.extend(c)
        check("0.3.5 S17 허락된 명령 그대로 → 0 · 허락 지움", r.returncode == 0 and not _gf035(d).exists(), f"{r.returncode}\n{out}")
        check("0.3.5 S17 gh 호출: 조회(번호·칸·--jq) 두 번(초록 두 번 연속 — F2) · 비교 · 합치기",
              len(c) == 4 and c[0].startswith(f"pr view 68 --json {_MG_JSON} --jq ") and c[1] == c[0]
              and c[2] == f"api repos/{{owner}}/{{repo}}/compare/main...{hoid} --jq .behind_by", "\n".join(c))
        check("0.3.5 S17 합치기 인자 = pr merge 68 --rebase --match-head-commit <PR 머리> 정확히", c[3:] == [f"pr merge 68 --rebase --match-head-commit {hoid}"], "\n".join(c))
        mg = (fg / "merge.grant").read_text(encoding="utf-8").split() if (fg / "merge.grant").exists() else []
        check("0.3.5 S17 합치기 호출 때 허락은 이미 지워져 있음", mg == ["no"], repr(mg))
        cw = (fg / "cwds").read_text(encoding="utf-8").splitlines()
        check("0.3.5 S17 gh 는 프로젝트 폴더에서 불림", len(cw) == 4 and all(_same034(x, d) for x in cw), "\n".join(cw))
        check("0.3.5 S17 출력: 합침 · 배포 경고 · 받아 오기 실패 알림(S20) · 다음 묶음",
              "✅ 합쳤습니다: PR #68 (feat/x → main, rebase)" in out
              and "   ⚠️ 기본 가지에 합쳐지면 운영 배포가 시작될 수 있습니다 — 배포 확인을 Claude 에게 부탁하세요" in out
              and "   (origin/main 을 받아 오지 못했습니다 — 새 가지 전에 Claude 에게 '최신 내용 받아 와'라고 하세요.)" in out
              and out.rstrip("\n").endswith("다음 묶음: /refactor:approve 새 가지"), out)
        check("0.3.5 S17 I5 승인 기록·봉인 바이트 그대로 · 승인 상태 그대로 · 가지 그대로", _seal_bytes035(d) == seal and intact(d)
              and _lib033(d, 'rl_cards "$R/REFACTOR_PLAN.md" "$R/APPROVALS.log"')[0] == st0 and g(d, "branch", "--show-current") == "feat/x")
        # S17 방식·번호 없음(gh 가 지금 가지의 PR 을 찾음 — 응답의 번호로 합침)
        for args, vw, mm in (("합치기 squash", f"pr view --json {_MG_JSON} --jq ", "pr merge 68 --squash"),
                             ("합치기 68 병합", f"pr view 68 --json {_MG_JSON} --jq ", "pr merge 68 --merge"),
                             ("합치기 7 rebase", f"pr view 7 --json {_MG_JSON} --jq ", "pr merge 7 --rebase")):
            fresh(args)
            fg = F(number=int(mm.split()[2]))
            out, c, _ = case(f"S17 '{args}' → {mm}", d, fg, "✅ 합쳤습니다", 0, False, n=(2, 1, 1))
            check(f"0.3.5 S17 '{args}' 조회·합치기 인자", c[:1] and c[0].startswith(vw) and c[3:] == [f"{mm} --match-head-commit {hoid}"], "\n".join(c))
        # S17 NEUTRAL·SKIPPED 섞인 초록 → 합침(0.3.4 g5)
        fresh()
        case("S17 NEUTRAL·SKIPPED 섞인 초록 → 합침", d, F(statusCheckRollup=[CR("a", co="NEUTRAL"), CR("b", co="SKIPPED"), CR("c"), SC("ci/y", "SUCCESS")]),
             "✅ 합쳤습니다", 0, False, n=(2, 1, 1))

        # S0 인자 꼴 · lib 없음 → 허락 그대로 · gh 호출 0
        fresh()
        for name, argv in (("인자 없음", []), ("인자 하나", [str(d)]), ("인자 셋", [str(d), "s1", "x"]), ("세션 ID 꼴 아님", [str(d), "../x"]),
                           ("세션 ID 빈 값", [str(d), ""]), ("폴더 없음", [str(d / "nope"), "s1"])):
            case(f"S0 {name} → 쓰는 법 · 1 · 허락 그대로", d, F(), "❓ 쓰는 법: ", 1, True, n=(0, 0, 0), argv=argv)
        emp = pathlib.Path(tempfile.mkdtemp(prefix="mgnolib-"))
        made.append(str(emp))
        case("S0 lib 없음 → 쓰는 법 · 1 · 허락 그대로", d, F(), "❓ 쓰는 법: ", 1, True, n=(0, 0, 0), direct=True, extra_env={"REFACTOR_ROOT": emp.as_posix()})
        out, _, _ = case("S0 run.sh 없이 바로(REFACTOR_ROOT 없음 → 스크립트 위치로 lib) → 정상 진행", d, F(), "✅ 합쳤습니다", 0, False, n=(2, 1, 1), direct=True)

        # S2 허락 없음·꼴 틀림·시각 밖 · 다른 세션
        _gf035(d).unlink(missing_ok=True)
        case("S2 허락 파일 없음 → 거절 · gh 호출 0", d, F(), "⛔ 합치기 허락이 없거나 끝났습니다 — 사용자가 /refactor:approve 합치기 를 입력해야 합니다", 1, False, n=(0, 0, 0), tail="ref")
        for name, kw in (("방식 글자 틀림", dict(line1=f"merge feat/x 68 fast {hoid}")), ("커밋 39자", dict(line1=f"merge feat/x 68 rebase {hoid[:39]}")),
                         ("커밋 대문자", dict(line1=f"merge feat/x 68 rebase {hoid.upper()}")), ("번호 8자리", dict(line1=f"merge feat/x 12345678 rebase {hoid}")),
                         ("번호 글자", dict(line1=f"merge feat/x abc rebase {hoid}")), ("가지 첫 글자 -", dict(line1=f"merge -x 68 rebase {hoid}")),
                         ("끝 공백", dict(line1=f"merge feat/x 68 rebase {hoid} ")), ("앞 낱말 push", dict(line1=f"push feat/x 68 rebase {hoid}")),
                         ("1801초 지남", dict(ago=1801)), ("시각이 미래(100초 뒤)", dict(ago=-100)),
                         ("3줄이 bash \" 로 시작 안 함", dict(line3="sh x refactor-merge y s1")), ("3줄에 refactor-merge 없음", dict(line3='bash "x/hooks/run.sh" refactor-status "y" s1'))):
            fresh()
            _set_grant035(d, **kw)
            case(f"S2 허락 {name} → 거절 · 허락 지움 · gh 호출 0", d, F(), "⛔ 합치기 허락이 없거나 끝났습니다", 1, False, n=(0, 0, 0), tail="ref")
        fresh()
        _set_grant035(d, ago=1790)
        case("S2 허락 1790초 전(30분 안) → 합침", d, F(), "✅ 합쳤습니다", 0, False, n=(2, 1, 1))
        fresh()
        _set_grant035(d, crlf=True)
        case("S2 허락 파일이 CRLF 줄 끝 → 합침", d, F(), "✅ 합쳤습니다", 0, False, n=(2, 1, 1))
        # F7① 승인 기록 대조: 기록의 마지막 비지 않은 줄이 이 허락의 줄이어야 한다(Claude 는 기록을 못 씀 — 허락 파일만 만들어 둔 것은 걸린다)
        W_LOG = "⛔ 합치기 허락이 승인 기록과 맞지 않습니다 — 사용자가 /refactor:approve 합치기 를 다시 입력해야 합니다"
        logp = d / "docs/refactor/APPROVALS.log"
        reseal = lambda: _lib033(d, 'rl_log_seal "$R"')   # 시험이 기록을 바꾼 뒤 봉인을 맞춘다(S3 가 먼저 걸리지 않게)
        hl = lambda pw, br="feat/x", mth="rebase", oid=None: f"2026-10-04 21:00 KST | 합치기 | 허락 {br} {pw} ({mth}) @{(oid or hoid)[:7]} | - | 사용자가 /refactor:approve 로 실행\n"
        for name, extra, ok in (("허락 뒤 다른 줄(허용 줄)이 마지막", "2026-10-04 21:01 KST | 허용 | P1-1 | - | 사용자가 /refactor:approve 로 실행\n", False),
                                ("다른 가지의 허락 줄이 마지막", hl("PR #68", br="feat/y"), False),
                                ("다른 번호의 허락 줄", hl("PR #69"), False),
                                ("다른 방식의 허락 줄", hl("PR #68", mth="squash"), False),
                                ("다른 커밋의 허락 줄", hl("PR #68", oid="abcdef0" + "0" * 33), False),
                                ("번호 없는 꼴(PR(지금 가지))인데 허락은 번호 있음", hl("PR(지금 가지)"), False),
                                ("옛 꼴 '#68'(PR 낱말 없음)", hl("#68"), False),
                                ("같은 허락 줄이 한 번 더", hl("PR #68"), True),
                                ("같은 허락 줄 + 빈 줄·CRLF 꼬리", hl("PR #68").replace("\n", "\r\n") + "\r\n  \n", True)):
            fresh()
            keep = logp.read_bytes()
            logp.write_bytes(keep + extra.encode("utf-8"))
            reseal()
            if ok:
                case(f"F7① 기록 대조 {name} → 합침", d, F(), "✅ 합쳤습니다", 0, False, n=(2, 1, 1))
            else:
                case(f"F7① 기록 대조 {name} → 거절 · gh 호출 0", d, F(), W_LOG, 1, False, n=(0, 0, 0), tail="ref")
            logp.write_bytes(keep)
            reseal()
        fresh()
        keep = logp.read_bytes()
        logp.unlink()
        reseal()
        case("F7① 기록 파일 없음 → 거절", d, F(), W_LOG, 1, False, n=(0, 0, 0), tail="ref")
        logp.write_bytes(keep)
        reseal()
        # 손으로 만든 허락 파일(입력 훅 없이 — 그 허락의 기록 줄 없음: 기록 마지막 줄은 '68 rebase' 허락) → 거절
        for name, l1 in (("방식만 다름(squash)", f"merge feat/x 68 squash {hoid}"), ("번호 없음", f"merge feat/x - rebase {hoid}"),
                         ("번호만 다름(7)", f"merge feat/x 7 rebase {hoid}")):
            lf(_gf035(d), f"{l1}\n{int(time.time())}\nbash \"x\" refactor-merge \"y\" s1\n")
            case(f"F7① 허락 파일만 있고 그 기록 줄 없음(손으로 만듦 · {name}) → 거절", d, F(), W_LOG, 1, False, n=(0, 0, 0), tail="ref")
        fresh("합치기 squash")
        case("F7① 번호 없는 허락 · 기록 'PR(지금 가지)' → 합침", d, F(), "✅ 합쳤습니다", 0, False, n=(2, 1, 1))
        fresh("합치기 squash")
        keep = logp.read_bytes()
        logp.write_bytes(keep + hl("PR 지금 가지의 PR", mth="squash").encode("utf-8"))
        reseal()
        case("F7① 번호 없는 허락 · 기록이 옛 꼴 'PR 지금 가지의 PR' → 거절", d, F(), W_LOG, 1, False, n=(0, 0, 0), tail="ref")
        logp.write_bytes(keep)
        reseal()
        fresh(sid="s2")
        case("S2 다른 세션(s2)의 허락은 s1 이 못 씀", d, F(), "⛔ 합치기 허락이 없거나 끝났습니다", 1, False, n=(0, 0, 0), tail="ref")
        check("0.3.5 S2 다른 세션(s2)의 허락 파일은 그대로", _gf035(d, "s2").exists())
        _gf035(d, "s2").unlink()

        # S3 봉인 깨짐
        fresh()
        logp = d / "docs/refactor/APPROVALS.log"
        keep = logp.read_bytes()
        logp.write_bytes(keep + "2026-10-04 09:00 KST | 승인 | P1-9 | card=x | 손으로\n".encode("utf-8"))
        case("S3 봉인 깨짐 → 거절 · 허락 지움 · gh 호출 0", d, F(), "⛔ 승인 기록이 봉인과 다릅니다 — /refactor:approve 확인 먼저", 1, False, n=(0, 0, 0), tail="ref")
        logp.write_bytes(keep)

        # S4 허락한 뒤 가지·커밋이 달라짐
        fresh()
        g(d, "commit", "--allow-empty", "-qm", "c2")
        h2 = g(d, "rev-parse", "HEAD")
        case("S4 허락 뒤 새 커밋 → 거절", d, F(), f"⛔ 허락한 뒤 가지·커밋이 달라졌습니다(허락: feat/x@{hoid[:7]} · 지금: feat/x@{h2[:7]})", 1, False, n=(0, 0, 0), tail="ref")
        # F8 위험 장면: 허락 뒤 새 커밋 h2 를 PR 에도 올림(PR 머리 = 지금 = h2 — 조회만 보면 다 맞음) → 허락한 커밋이 아니므로 거절 · 합치기 0
        g(d, "update-ref", "refs/heads/feat/x", hoid)
        fresh()
        g(d, "commit", "--allow-empty", "-qm", "c2")
        h2 = g(d, "rev-parse", "HEAD")
        fg = _fake035(made, head=h2)
        case("F8 S4 허락 뒤 새 커밋 h2 + PR 머리 h2 → 거절 · 합치기 0", d, fg, f"(허락: feat/x@{hoid[:7]} · 지금: feat/x@{h2[:7]})", 1, False, n=(0, 0, 0), tail="ref")
        check("0.3.5 F8 합치기 호출 0", not [x for x in _calls035(fg) if x.startswith("pr merge")], "\n".join(_calls035(fg)))
        g(d, "update-ref", "refs/heads/feat/x", hoid)
        fresh()
        g(d, "checkout", "-q", "-b", "feat/y")
        case("S4 허락 뒤 다른 가지 → 거절", d, F(), f"(허락: feat/x@{hoid[:7]} · 지금: feat/y@{hoid[:7]})", 1, False, n=(0, 0, 0), tail="ref")
        g(d, "checkout", "-q", "feat/x")
        fresh()
        g(d, "checkout", "-q", "--detach")
        case("S4 허락 뒤 떨어진 HEAD → 거절", d, F(), "⛔ 허락한 뒤 가지·커밋이 달라졌습니다", 1, False, n=(0, 0, 0), tail="ref")
        g(d, "checkout", "-q", "feat/x")

        # S5 기본 가지 못 찾음 · 지금 가지 = 기본 가지 · gh 없음
        fresh()
        g(d, "update-ref", "-d", "refs/remotes/origin/main")
        case("S5 origin 기본 가지 없음 → 거절", d, F(), "❓ origin 의 기본 가지를 찾지 못했습니다", 1, False, n=(0, 0, 0), tail="ref")
        g(d, "update-ref", "refs/remotes/origin/main", "main")
        fresh()
        nogh, m2 = _path_without_gh(env()["PATH"])
        made.extend(m2)
        case("S5 gh 없음 → 거절", d, None, "❓ gh(GitHub CLI)를 찾지 못했습니다", 1, False, tail="ref", path=nogh)
        g(d, "checkout", "-q", "main")
        moid = g(d, "rev-parse", "HEAD")
        lf(_gf035(d), f"merge main - rebase {moid}\n{int(time.time())}\nbash \"x\" refactor-merge \"y\" s1\n")
        keep = logp.read_bytes()   # 손으로 만든 허락이라 기록 줄도 손으로(F7① 대조를 지나 S5 에 닿게)
        logp.write_bytes(keep + hl("PR(지금 가지)", br="main", oid=moid).encode("utf-8"))
        reseal()
        case("S5 지금 가지 = 기본 가지(손으로 만든 허락) → 거절", d, F(), "⛔ 지금 가지가 기본 가지(main)입니다 — 작업 가지의 PR 만 합칩니다", 1, False, n=(0, 0, 0), tail="ref")
        logp.write_bytes(keep)
        reseal()
        g(d, "checkout", "-q", "feat/x")

        # S1 마무리 확인 뒤 → 안내만 · 허락 그대로 · 0
        d2 = _mk035(approve_first=False)
        made.append(str(d2))
        _grant035(d2, made=made)
        approve(d2, "마무리")
        fg = _fake035(made, head=g(d2, "rev-parse", "HEAD"))
        case("S1 마무리 뒤 → 안내 · 0 · 허락 그대로 · gh 호출 0", d2, fg, "ℹ️ 이미 마무리되어 안전장치가 꺼져 있습니다 — 평소처럼 합칠 수 있습니다", 0, True, n=(0, 0, 0))

        # S6 조회 실패(gh 오류 · 시간 초과) → 다시 실행(3) · 허락 유지 — 0.3.4 g13·g9·g9b·g9c
        # F10 다시 해도 같은 오류(저장소·PR 없음·권한·로그인)는 거절(1) + 계정 안내 · 그 밖(연결 끊김 등)은 3
        for name, err in (("저장소 못 찾음", "GraphQL: Could not resolve to a Repository with the name 'o/r'. (repository)"),
                          ("PR 없음", "no pull requests found for branch \"feat/x\""),
                          ("HTTP 404", "HTTP 404: Not Found (https://api.github.com/graphql)"),
                          ("HTTP 403 소문자", "http 403: forbidden"),
                          ("HTTP 401", "HTTP 401: Bad credentials"),
                          ("열린 PR 없음", "No open pull requests found"),
                          ("로그인 필요(대문자 AUTH)", "To get started with GitHub CLI, please run:  gh AUTH login"),
                          ("PR 번호 없음", "GraphQL: Could not resolve to a PullRequest with the number of 68. (repository.pullRequest)"),
                          ("not found 대소문자 섞임", "release Not Found")):
            fresh()
            out, _, _ = case(f"F10 S6 조회 영구 오류({name}) → 거절 · 허락 지움", d, F(view_rc=1, view_err=err), f"⛔ PR 을 조회하지 못했습니다: {err}", 1, False,
                             n=(1, 0, 0), tail="ref")
            check(f"0.3.5 F10 S6 {name} → 계정 안내 줄", _MG_AUTH in out and "⚠️ PR 을 조회하지 못했습니다" not in out, out)
        fresh()
        for name, err in (("연결 끊김", "read tcp 10.0.0.2:5000->140.82.112.6:443: read: connection reset by peer"),
                          ("시간 초과 문구", "Post \"https://api.github.com/graphql\": net/http: TLS handshake timeout"),
                          ("HTTP 502", "HTTP 502: Bad Gateway"), ("HTTP 500", "HTTP 500: Internal Server Error"),
                          # 보완 3바퀴 R3(재검사 A2 🟡): 요청 한도(403 이어도)·주소 찾기 실패(DNS)는 기다리면 풀림 → 3
                          ("요청 한도 403", "HTTP 403: API rate limit exceeded for user ID 1234."),
                          ("2차 요청 한도", "HTTP 403: You have exceeded a secondary rate limit. Please wait a few minutes before you try again."),
                          ("요청 한도 대문자", "HTTP 403: API RATE LIMIT exceeded"),
                          ("주소 찾기 실패(DNS)", "error connecting to api.github.com: Could not resolve host: api.github.com")):
            out, _, _ = case(f"F10 S6 조회 일시 오류({name}) → 3 · 허락 유지", d, F(view_rc=1, view_err=err), f"⚠️ PR 을 조회하지 못했습니다: {err}", 3, True,
                             n=(1, 0, 0), tail="again")
            check(f"0.3.5 F10 S6 {name} → 계정 안내 없음", _MG_AUTH not in out, out)
        out, _, secs = case("S6 조회 시간 초과(한도 3초) → 3 · 허락 유지", d, F(view_sleep=40), "⚠️ PR 을 조회하지 못했습니다: 3초 안에 끝나지 않음", 3, True, n=(1, 0, 0), tail="again")
        check("0.3.5 S6 조회 시간 초과 → 2~7초 안", 2 <= secs < 7, f"{secs:.1f}")
        fg = F(view_stubborn=40)
        nott, m3 = _path_without_gh(str(fg) + os.pathsep + env()["PATH"], names=("timeout", "perl"))
        made.extend(m3)
        out, _, secs = case("S6 timeout·perl 없음 + gh 가 ALRM·TERM 무시 → 3", d, fg, "3초 안에 끝나지 않음", 3, True, n=(1, 0, 0), tail="again", path=nott)
        check("0.3.5 S6 TERM 무시 → 1초 뒤 KILL · 3~8초", 3 <= secs < 8, f"{secs:.1f}")
        out, _, secs = case("S6 자식이 출력 통로를 쥔 채 남음 → 3", d, F(view_kid=12), "3초 안에 끝나지 않음", 3, True, n=(1, 0, 0), tail="again")
        check("0.3.5 S6 자식이 통로를 쥠 → 한도+3초 안", 2 <= secs < 7, f"{secs:.1f}")
        out, _, _ = case("S6 gh 오류에 제어 문자 → ? 로", d, F(view_rc=1, view_err="boom\x1b[2J\x1b]0;x\x07 end"), "PR 을 조회하지 못했습니다: boom?[2J?]0;x? end", 3, True, n=(1, 0, 0))
        check("0.3.5 S6 결과에 ESC·BEL 0", "\x1b" not in out and "\x07" not in out, repr(out))
        case("S6 오류 문구 없음", d, F(view_rc=1), "PR 을 조회하지 못했습니다: (오류 문구 없음)", 3, True, n=(1, 0, 0))

        # S7 응답 형식이 다름
        case("S7 조회 응답 형식이 다름 → 거절", d, F(view_raw="hello\n"), "⛔ PR 정보를 읽지 못했습니다(gh 응답 형식이 예상과 다름)", 1, False, n=(1, 0, 0), tail="ref")
        fresh()
        case("S7 머리 커밋 글자 아님 → 거절", d, F(headRefOid="zz"), "⛔ PR 정보를 읽지 못했습니다", 1, False, n=(1, 0, 0), tail="ref")

        # S8 이미 합쳐짐
        fresh()
        case("S8 MERGED(지금 가지 · 머리 = 지금 커밋) → 안내 · 0 · 허락 지움", d, F(state="MERGED"), "ℹ️ PR #68 은 이미 합쳐져 있습니다 — 다음 묶음: /refactor:approve 새 가지", 0, False, n=(1, 0, 0))
        # F1 MERGED 가 넓음: 합친 뒤 새 커밋(옛 머리) · 번호를 잘못 줘 다른 가지의 합쳐진 PR → 합친 것이 아니므로 거절(1) · 합치기 0
        hpar = g(d, "rev-parse", "HEAD~1")
        fresh("합치기 rebase")
        out, _, _ = case("F1 S8 번호 없이 · 가지의 옛 PR MERGED(옛 머리) → 거절 · 허락 지움 · 합치기 0", d, F(state="MERGED", headRefOid=hpar),
                         f"⛔ PR #68 은 이미 합쳐진 PR 입니다(feat/x@{hpar[:7]}) — 지금 커밋({hoid[:7]})은 새 PR 이 필요합니다(gh pr create) · 다른 PR 이면 번호를 확인하세요",
                         1, False, n=(1, 0, 0), tail="ref")
        check("0.3.5 F1 옛 머리 MERGED → '이미 합쳐져 있습니다'(0) 아님", "ℹ️" not in out, out)
        fresh("합치기 67 rebase")
        case("F1 S8 '합치기 67' · 다른 가지의 합쳐진 PR → 거절", d, F(number=67, state="MERGED", headRefName="feat/old"),
             f"⛔ PR #67 은 이미 합쳐진 PR 입니다(feat/old@{hoid[:7]}) — 지금 커밋({hoid[:7]})은 새 PR 이 필요합니다", 1, False, n=(1, 0, 0), tail="ref")
        fresh("합치기 67 rebase")
        case("F1 S8 다른 가지 · 다른 머리의 합쳐진 PR → 거절", d, F(number=67, state="MERGED", headRefName="feat/old", headRefOid="2" * 40),
             f"⛔ PR #67 은 이미 합쳐진 PR 입니다(feat/old@2222222)", 1, False, n=(1, 0, 0), tail="ref")

        # S9 닫힘·초안·포크·다른 가지·받는 가지·충돌·그 밖 mergeable — 0.3.4 g4
        for name, kw, want in (("닫힘", dict(state="CLOSED"), "⛔ PR #68 은 열려 있는 PR 이 아닙니다(상태: CLOSED)"),
                               ("초안", dict(isDraft=True), "⛔ PR #68 은 초안(draft)입니다"),
                               ("포크", dict(isCrossRepository=True), "⛔ PR #68 은 포크의 PR 입니다"),
                               ("다른 가지", dict(headRefName="feat/y"), "⛔ PR #68 은 다른 가지(feat/y)의 것입니다(지금 가지: feat/x)"),
                               ("받는 가지 develop", dict(baseRefName="develop"), "⛔ PR #68 은 기본 가지(main)로 가는 PR 이 아닙니다(받는 가지: develop)"),
                               ("충돌", dict(mergeable="CONFLICTING"), "⛔ PR #68 에 충돌이 있습니다"),
                               ("mergeable 그 밖 값", dict(mergeable="BLOCKED"), "⛔ PR #68 을 합칠 수 있는 상태가 아닙니다(mergeable: BLOCKED)")):
            fresh()
            case(f"S9 {name} → 거절", d, F(**kw), want, 1, False, n=(1, 0, 0), tail="ref")

        # S10 GitHub 계산 중 → 창 끝 3 / 같은 호출 안에서 풀리면 합침
        fresh()
        case("S10 계산 중(창 0) → 3 · 허락 유지 · 조회 1번", d, F(mergeable="UNKNOWN"), "⏳ GitHub 가 아직 계산 중입니다", 3, True, n=(1, 0, 0), tail="again",
             extra_env=_MG_W0)
        case("S10 계산 중 → 2번째 조회에 풀림(창 5초) → 3번째 확인 조회 뒤 같은 호출에서 합침", d, F(mergeable="UNKNOWN", view_then=2), "✅ 합쳤습니다", 0, False,
             n=(3, 1, 1), extra_env={"REFACTOR_MERGE_WINDOW": "5"})

        # S12 검사 실패 — 0.3.4 g5 · F10
        for name, rollup, want in (("하나 실패", [CR("a"), CR("lint", co="FAILURE")], "⛔ PR #68 의 자동 검사 실패(lint) — 고친 뒤 다시"),
                                   ("상태 항목 FAILURE", [CR("a"), SC("ci/x", "FAILURE")], "자동 검사 실패(ci/x)"),
                                   ("상태 항목 ERROR", [CR("a"), SC("ci/x", "ERROR")], "자동 검사 실패(ci/x)"),
                                   ("CANCELLED", [CR("a"), CR("t", co="CANCELLED")], "자동 검사 실패(t)"),
                                   ("알 수 없는 종류", [CR("a"), {"__typename": "Weird", "name": "w"}], "자동 검사 실패(w(알 수 없는 검사 종류 Weird))"),
                                   ("실패와 도는 중이 같이", [CR("lint", co="FAILURE"), CR("b", "QUEUED", None)], "자동 검사 실패(lint)"),
                                   ("이름에 제어 문자", [CR("a"), CR("a\x1b[31mred\x07", co="FAILURE")], "자동 검사 실패(a?[31mred?)")):
            fresh()
            out, _, _ = case(f"S12 {name} → 거절", d, F(statusCheckRollup=rollup), want, 1, False, n=(1, 0, 0), tail="ref")
        check("0.3.5 S12 검사 이름 → 결과에 ESC·BEL 0", "\x1b" not in out and "\x07" not in out, repr(out))

        # S13 검사 도는 중 → 창 끝 3 / 같은 호출 안에서 초록이면 합침 / 창 안에서 되풀이
        fresh()
        for name, rollup, want in (("CheckRun IN_PROGRESS", PEND, "⏳ PR #68 의 자동 검사가 아직 도는 중입니다(build)"),
                                   ("상태 항목 PENDING", [CR("a"), SC("ci/x", "PENDING")], "아직 도는 중입니다(ci/x)"),
                                   ("상태 항목 EXPECTED", [CR("a"), SC("ci/z", "EXPECTED")], "아직 도는 중입니다(ci/z)"),
                                   ("QUEUED 둘", [CR("p", "QUEUED", None), CR("q", "QUEUED", None)], "아직 도는 중입니다(p, q)")):
            case(f"S13 {name}(창 0) → 3 · 허락 유지", d, F(statusCheckRollup=rollup), want, 3, True, n=(1, 0, 0), tail="again", extra_env=_MG_W0)
        case("S13 도는 중 → 3번째 조회에 초록(창 5초) → 4번째 확인 조회 뒤 같은 호출에서 합침", d, F(statusCheckRollup=PEND, view_then=3), "✅ 합쳤습니다", 0, False,
             n=(4, 1, 1), extra_env={"REFACTOR_MERGE_WINDOW": "5"})
        fresh()
        # F5: 창 5초 · 간격 1초(초 경계에 기대지 않게 — 첫 판단이 1초를 넘겨도 다시 조회할 여유가 있음)
        out, c, secs = case("S13 계속 도는 중(창 5초 · 간격 1초) → 되풀이 뒤 3", d, F(statusCheckRollup=PEND), "아직 도는 중입니다(build)", 3, True, tail="again",
                            extra_env={"REFACTOR_MERGE_WINDOW": "5", "REFACTOR_MERGE_INTERVAL": "1"})
        check("0.3.5 S13 창 안에서 조회 2번 이상 · 비교·합치기 0", _kinds035(c)[0] >= 2 and _kinds035(c)[1:] == (0, 0) and secs < 10, f"{_kinds035(c)} {secs:.1f}")

        # S14 검사 0개: 허락 만든 지 120초 안 → 3 · 그 뒤 → 1 / 성공 0 → 1 — 0.3.4 g5 D6 · g14
        fresh()
        case("S14 검사 0개 · 허락 방금 → 3(아직 등록 안 됨)", d, F(statusCheckRollup=[]), "⏳ 자동 검사가 아직 등록되지 않았습니다", 3, True, n=(1, 0, 0), tail="again",
             extra_env=_MG_W0)
        _set_grant035(d, ago=200)
        case("S14 검사 0개 · 허락 200초 전 → 거절", d, F(statusCheckRollup=[]), "⛔ PR #68 에 통과한 자동 검사가 없습니다", 1, False, n=(1, 0, 0), tail="ref")
        fresh()
        _set_grant035(d, ago=30)
        case("S14 검사 0개 · 120초를 20초로 줄임 · 허락 30초 전 → 거절", d, F(statusCheckRollup=[]), "통과한 자동 검사가 없습니다", 1, False, n=(1, 0, 0), tail="ref",
             extra_env={"REFACTOR_MERGE_NOCHECK_GRACE": "20"})
        fresh()
        _set_grant035(d, ago=30)
        case("S14 줄이기 전용: 120초를 999 로 늘리려 하면 무시(허락 30초 전 → 3)", d, F(statusCheckRollup=[]), "⏳ 자동 검사가 아직 등록되지 않았습니다", 3, True,
             n=(1, 0, 0), extra_env={"REFACTOR_MERGE_NOCHECK_GRACE": "999", **_MG_W0})
        case("S14 검사 0개 → 2번째 조회에 초록(창 5초) → 3번째 확인 조회 뒤 합침", d, F(statusCheckRollup=[], view_then=2), "✅ 합쳤습니다", 0, False, n=(3, 1, 1),
             extra_env={"REFACTOR_MERGE_WINDOW": "5"})
        # F6 "크면 무시"가 실제로 가르는 시험: 허락 200초 전 + 999(무시 → 120 적용) → 거절. 999 를 받아들이면 3 이 된다
        fresh()
        _set_grant035(d, ago=200)
        case("F6 S14 120초를 999 로 늘리려 함 · 허락 200초 전 → 무시되어 120 적용 → 거절", d, F(statusCheckRollup=[]), "⛔ PR #68 에 통과한 자동 검사가 없습니다", 1, False,
             n=(1, 0, 0), tail="ref", extra_env={"REFACTOR_MERGE_NOCHECK_GRACE": "999", **_MG_W0})
        # F6 한도 변수 하나(조회 한도): 2초 늦게 답하는 gh — 999 는 무시(기본 15초 적용)되어 정상 진행 · 1 로 줄이면 시간 초과(3)
        fresh()
        out, _, secs = case("F6 조회 한도 999(무시 → 15초) · gh 2초 늦음 → 시간 초과 아님 · 합침", d, F(view_delay=2), "✅ 합쳤습니다", 0, False, n=(2, 1, 1),
                            extra_env={"REFACTOR_MERGE_VIEW_LIMIT": "999"})
        check("0.3.5 F6 조회 한도 999 → '끝나지 않음' 없음", "끝나지 않음" not in out, out)
        fresh()
        case("F6 조회 한도 1 · gh 2초 늦음 → 시간 초과 · 3", d, F(view_delay=2), "⚠️ PR 을 조회하지 못했습니다: 1초 안에 끝나지 않음", 3, True, n=(1, 0, 0), tail="again",
             extra_env={"REFACTOR_MERGE_VIEW_LIMIT": "1"})

        # F2 초록 두 번 연속: 처음 본 초록은 확인 조회 한 번 더 — ⓐ 검사 이름 집합 ⓑ 전부 초록 ⓒ PR 머리가 같을 때만 합침
        L, T = CR("lint"), CR("test")
        fresh()
        out, c, _ = case("F2 ① 1회차 [lint ✅] → 2회차 [lint ✅, test QUEUED] → 합치기 0 · 되풀이 뒤 3", d,
                         F(view_seq=[dict(statusCheckRollup=[L]), dict(statusCheckRollup=[L, CR("test", "QUEUED", None)])]),
                         "⏳ PR #68 의 자동 검사가 아직 도는 중입니다(test)", 3, True, tail="again",
                         extra_env={"REFACTOR_MERGE_WINDOW": "5", "REFACTOR_MERGE_INTERVAL": "1"})
        check("0.3.5 F2 ① 조회 2번 이상 · 비교·합치기 0", _kinds035(c)[0] >= 2 and _kinds035(c)[1:] == (0, 0), str(_kinds035(c)))
        out, c, _ = case("F2 ② 1회차·2회차 둘 다 [lint ✅, test ✅] → 합치기 1 · 조회 정확히 2", d, F(view_seq=[dict(statusCheckRollup=[L, T]), dict(statusCheckRollup=[T, L])]),
                         "✅ 합쳤습니다", 0, False, n=(2, 1, 1))
        fresh()
        grow = [dict(statusCheckRollup=[L] + [CR(f"job{j}") for j in range(i)]) for i in range(12)]
        out, c, _ = case("F2 ③ 조회마다 초록 검사가 하나씩 늘어남 → 합치기 0 · 창 끝 3 '검사 목록이 바뀌었습니다'", d, F(view_seq=grow),
                         "⏳ 검사 목록이 바뀌었습니다 — 다시 확인합니다", 3, True, tail="again", extra_env={"REFACTOR_MERGE_WINDOW": "5", "REFACTOR_MERGE_INTERVAL": "1"})
        check("0.3.5 F2 ③ 조회 2번 이상 · 비교·합치기 0", _kinds035(c)[0] >= 2 and _kinds035(c)[1:] == (0, 0), str(_kinds035(c)))
        case("F2 ③b 2회차에 검사 하나 추가(전부 초록) → 그 조회에선 안 합침 · 3회차 같음 → 합침(조회 3)", d,
             F(view_seq=[dict(statusCheckRollup=[L]), dict(statusCheckRollup=[L, T])]), "✅ 합쳤습니다", 0, False, n=(3, 1, 1))
        fresh()
        case("F2 ④ 2회차에 PR 머리 커밋이 다름 → S11 거절 · 합치기 0", d, F(view_seq=[dict(), dict(headRefOid="1" * 40)]),
             "⛔ PR #68 에 이 컴퓨터에 없는 커밋이 있습니다", 1, False, n=(2, 0, 0), tail="ref")
        fresh()
        case("F2 창 0 · 처음 본 초록 → 합치지 않고 3 '한 번 더 확인하려고'", d, F(), "⏳ 자동 검사가 모두 초록입니다 — 한 번 더 확인하려고 같은 명령을 다시 실행합니다", 3, True,
             n=(1, 0, 0), tail="again", extra_env=_MG_W0)
        case("F2 ⑤ 다시 실행하면 이번 호출에서 다시 두 번 조회 → 합침", d, F(), "✅ 합쳤습니다", 0, False, n=(2, 1, 1))
        # 보완 3바퀴 R1(재검사 A2·C2 🟠): 조회가 매번 창보다 길어도(창 2초 · 간격 1초 · 조회 3초) 처음 본 초록 다음의 확인 조회 1번은 창 확인을
        #   면제 → 한 호출에서 합침. 그 확인 조회가 다시 기다림(도는 중)이면 창 규칙 그대로 → 3
        SLOW = {"REFACTOR_MERGE_WINDOW": "2", "REFACTOR_MERGE_INTERVAL": "1", "REFACTOR_MERGE_VIEW_LIMIT": "5"}
        fresh()
        case("R1 느린 조회(3초 > 창 2초 · 간격 1초) → 창 면제 확인 조회 1번 → 같은 호출에서 합침(조회 2)", d, F(view_delay=3), "✅ 합쳤습니다", 0, False,
             n=(2, 1, 1), extra_env=SLOW)
        fresh()
        case("R1 느린 조회 · 확인 조회가 도는 중 → 창 규칙(창 밖) → 3 · 조회 2", d, F(view_delay=3, view_seq=[dict(), dict(statusCheckRollup=PEND)]),
             "⏳ PR #68 의 자동 검사가 아직 도는 중입니다(build)", 3, True, n=(2, 0, 0), tail="again", extra_env=SLOW)
        fresh()
        case("F2 2회차에 검사 실패 → 거절", d, F(view_seq=[dict(statusCheckRollup=[L, T]), dict(statusCheckRollup=[L, CR("test", co="FAILURE")])]),
             "⛔ PR #68 의 자동 검사 실패(test)", 1, False, n=(2, 0, 0), tail="ref")
        fresh()
        case("F2 2회차에 GitHub 계산 중 → 3회차 초록 · 4회차 같음 → 합침", d,
             F(view_seq=[dict(), dict(mergeable="UNKNOWN"), dict(), dict()]), "✅ 합쳤습니다", 0, False, n=(4, 1, 1))
        for name, rollup in (("전부 SKIPPED(g14)", [CR("a", co="SKIPPED"), CR("b", co="SKIPPED")]), ("NEUTRAL 만", [CR("a", co="NEUTRAL")])):
            fresh()
            case(f"S14 {name} → 거절", d, F(statusCheckRollup=rollup), "통과한 자동 검사가 없습니다", 1, False, n=(1, 0, 0), tail="ref")

        # S15 비교 실패 → 3 · S16 기본 가지에 새 커밋 → 거절 — 0.3.4 g6 · F10
        fresh()
        case("S15 비교 호출 실패 → 3 · 허락 유지", d, F(cmp_rc=1, cmp_err="HTTP 404: Not Found"), "⚠️ 기본 가지와 PR 을 비교하지 못했습니다: HTTP 404: Not Found", 3, True,
             n=(2, 1, 0), tail="again")
        case("S15 비교 응답이 숫자 아님 → 3", d, F(behind="null"), "⚠️ 기본 가지와 PR 을 비교하지 못했습니다: 응답 형식이 예상과 다름", 3, True, n=(2, 1, 0), tail="again")
        case("S15 비교 시간 초과(한도 3초) → 3", d, F(cmp_sleep=40), "⚠️ 기본 가지와 PR 을 비교하지 못했습니다: 3초 안에 끝나지 않음", 3, True, n=(2, 1, 0), tail="again")
        out, _, _ = case("S15 비교 오류에 제어 문자 → ? 로", d, F(cmp_rc=1, cmp_err="HTTP\x1b[31m 500"), "비교하지 못했습니다: HTTP?[31m 500", 3, True, n=(2, 1, 0))
        check("0.3.5 S15 결과에 ESC 0", "\x1b" not in out, repr(out))
        case("S16 behind_by 2 → 거절", d, F(behind="2"),
             "⛔ 기본 가지(main)에 새 커밋 2개가 들어와 있습니다 — GitHub PR 화면의 Update branch(또는 사람이 확인) → 검사가 다시 초록 → Claude 에게 \"작업 가지 최신 내용 받아 와\" → 다시 /refactor:approve 합치기",
             1, False, n=(2, 1, 0), tail="ref")

        # S18 합치기 시간 초과 · S19 gh 가 거절 — 0.3.4 g7 · F10
        fresh()
        fg = F(merge_sleep=40)
        out, _, secs = case("S18 합치기 시간 초과(한도 3초) → 1 · 허락 지움", d, fg,
                            "⚠️ 합치기 요청이 3초 안에 끝나지 않았습니다 — 합쳐졌는지 알 수 없습니다. gh pr view 68 --json state,mergedAt 로 확인하세요", 1, False, n=(2, 1, 1))
        check("0.3.5 S18 '합치지 않았습니다'라고 하지 않음 · 합치기 때 허락 이미 없음", "합치지 않았습니다" not in out and "✅" not in out
              and (fg / "merge.grant").read_text(encoding="utf-8").split() == ["no"], out)
        fresh()
        fg = F(merge_rc=1, merge_err="GraphQL: Base branch was modified. Review and try the merge again. (mergePullRequest)")
        out, c, _ = case("S19 gh 가 합치기 거절 → 1 · 허락 지움", d, fg, "⛔ gh 가 합치기를 거절했습니다: GraphQL: Base branch was modified. Review and try the merge again. (mergePullRequest) — 합쳐지지 않았습니다",
                         1, False, n=(2, 1, 1), tail="ref")
        check("0.3.5 S19 계정 확인 안내 · 실패한 합치기 인자 · 허락 먼저 지움", _MG_AUTH in out and c[3:] == [f"pr merge 68 --rebase --match-head-commit {hoid}"]
              and (fg / "merge.grant").read_text(encoding="utf-8").split() == ["no"], out)
        fresh()
        out, _, _ = case("S19 합치기 오류에 제어 문자 → ? 로", d, F(merge_rc=1, merge_err="no\x1b[1m way"), "합치기를 거절했습니다: no?[1m way", 1, False, n=(2, 1, 1))
        check("0.3.5 S19 결과에 ESC 0", "\x1b" not in out, repr(out))

        # F9 되풀이 조회 사이에 사람이 새로 입력(입력 훅이 허락을 지움 / 새 허락으로 바꿈) → 합치기 직전 다시 읽어 거절(1) · 합치기 0
        W_GONE = "⛔ 허락이 사라졌거나 바뀌었습니다(사용자가 새로 입력함) — 합치지 않았습니다"
        fresh()
        fg = F(view_rmgrant=1)
        out, _, _ = case("F9 1회차 조회 때 허락이 지워짐 → 거절 · 합치기 0", d, fg, W_GONE, 1, False, n=(2, 1, 0), tail="ref")
        check("0.3.5 R4 F9 사라짐 → 거절 꼬리 그대로 · '새 허락은 그대로' 없음", "새 허락은 그대로" not in out, out)
        fresh()
        before = _gf035(d).read_text(encoding="utf-8").split("\n")
        fg = F(view_regrant=2)
        out, _, _ = case("F9 2회차 조회 때 허락이 새 것으로 바뀜 → 거절 · 합치기 0 · 새 허락은 그대로 둠", d, fg, W_GONE, 1, True, n=(2, 1, 0))
        # 보완 3바퀴 R4(재검사 A2 🟢): 바뀐 경우는 새 허락이 남으므로 꼬리가 "새 허락은 그대로" — 거절 꼬리("허락은 끝났습니다")가 아님
        check("0.3.5 R4 F9 바뀜 → 꼬리 '새 허락은 그대로입니다 — 같은 명령을 그대로 다시 실행하세요.' · 거절 꼬리 없음",
              "   (새 허락은 그대로입니다 — 같은 명령을 그대로 다시 실행하세요.)" in out and _MG_REF not in out and "허락은 끝났습니다" not in out, out)
        after = _gf035(d).read_text(encoding="utf-8").split("\n") if _gf035(d).exists() else []
        check("0.3.5 F9 바뀐 허락(사람이 새로 만든 것)은 지우지 않음 · 2줄만 다름", after[:1] == before[:1] and after[2:] == before[2:] and after[1:2] != before[1:2],
              f"{before!r}\n{after!r}")
        _gf035(d).unlink(missing_ok=True)

        # 모든 실행에서 gh 가 받은 인자 어디에도 --admin·--auto·--delete-branch·-d 없음 · auth 하위명령 0(0.3.4 g11·g13)
        check("0.3.5 S17 gh 인자 어디에도 --admin·--auto·--delete-branch·-d 없음",
              all_calls and not [x for x in all_calls for o in ("--admin", "--auto", "--delete-branch", "-d") if o in x.split()], "\n".join(all_calls))
        check("0.3.5 S 모든 실행에서 auth 하위명령 호출 0", not [x for x in all_calls if x.split()[:1] == ["auth"]], "\n".join(all_calls))
    finally:
        shutil.rmtree(d, ignore_errors=True)
        for m in made:
            shutil.rmtree(m, ignore_errors=True)

    # S20 받아 오기: 진짜 로컬 맨 저장소(네트워크 0)면 받아 옴 · 시간을 다 썼으면 안 받음
    made = []
    bare = pathlib.Path(tempfile.mkdtemp(prefix="scripttest-origin-"))
    made.append(str(bare))
    subprocess.run(["git", "init", "-q", "--bare", str(bare)], check=True)
    d = _mk035(origin=bare)
    made.append(str(d))
    try:
        hoid = g(d, "rev-parse", "HEAD")
        _grant035(d, made=made)
        o0 = g(d, "rev-parse", "refs/remotes/origin/main")
        g(d, "push", "-q", str(bare), "feat/x:main")   # 원격 main 이 앞으로 감(합친 꼴) — 받아 오면 origin/main 이 바뀐다
        out, rc, _ = _mg035(d, fg=_fake035(made, head=hoid))
        check("0.3.5 S20 받아 오기 성공 → 알림 · origin/main 갱신 · 0", rc == 0 and "   (origin/main 을 받아 왔습니다.)" in out
              and g(d, "rev-parse", "refs/remotes/origin/main") == hoid != o0 and out.rstrip("\n").endswith("다음 묶음: /refactor:approve 새 가지"), out)
        _grant035(d, made=made)
        out, rc, _ = _mg035(d, fg=_fake035(made, head=hoid, merge_sleep=2), extra_env={"REFACTOR_MERGE_FETCH_BUDGET": "1"})
        check("0.3.5 S20 시간을 다 썼으면(한도 1초로 줄임) 안 받아 옴 · 0", rc == 0 and "   (시간이 모자라 origin/main 을 받아 오지 않았습니다" in out
              and "받아 왔습니다" not in out, out)
    finally:
        for m in made:
            shutil.rmtree(m, ignore_errors=True)


def check_merge_s11_035(check):
    """0.3.5 §4 S11(#21): PR 머리(P) ≠ 지금 커밋(H)을 진짜 임시 저장소의 로컬 객체로 넷으로 가름(받아 오지 않음) ·
    I5 통합: 턴 스냅숏 뒤 허락(입력 훅) → 스크립트 → post-check 가 조용."""
    g = _git034
    made = []
    d = _mk035()
    try:
        h = g(d, "rev-parse", "HEAD")
        hp = g(d, "rev-parse", "HEAD~1")
        tree = g(d, "rev-parse", "HEAD^{tree}")
        p_ahead = g(d, "commit-tree", tree, "-p", h, "-m", "pr 쪽 새 커밋")        # P 가 H 뒤에 하나 더(H 가 P 의 조상)
        p_div = g(d, "commit-tree", tree, "-p", hp, "-m", "갈라진 커밋")           # H~1 에서 갈라짐
        W_BEHIND = "⛔ PR #68 에 이 컴퓨터에 없는 커밋이 있습니다(GitHub 의 Update branch·다른 사람의 push) — Claude 에게 \"작업 가지 최신 내용 받아 와\"라고 한 뒤 다시 /refactor:approve 합치기"
        for name, p, want in (("a 로컬에 없음", "1" * 40, W_BEHIND),
                              ("b 내가 뒤(H 가 P 의 조상)", p_ahead, W_BEHIND),
                              ("c 내가 앞(P 가 H 의 조상)", hp, f"⛔ 아직 안 올린 커밋이 있습니다(PR 의 마지막 커밋 {hp[:7]} · 지금 {h[:7]}) — 먼저 /refactor:approve 푸시, 그다음 다시 /refactor:approve 합치기"),
                              ("d 갈라짐", p_div, "⛔ PR 의 마지막 커밋과 지금 커밋이 갈라져 있습니다 — 사람이 확인해 주세요")):
            _grant035(d, made=made)
            fg = _fake035(made, head=p)
            seal = _seal_bytes035(d)
            out, rc, _ = _mg035(d, fg=fg)
            c = _calls035(fg)
            check(f"0.3.5 S11 {name} → 거절 · 허락 지움 · 조회 1번만(받아 오기·비교·합치기 0)", want in out and _MG_REF in out and rc == 1
                  and not _gf035(d).exists() and _kinds035(c) == (1, 0, 0) and _seal_bytes035(d) == seal, f"{rc}\n{out}\n" + "\n".join(c))
        check("0.3.5 S11 받아 오지 않음(origin/main 그대로 · 원격 참조 늘지 않음)", g(d, "for-each-ref", "--format=%(refname)", "refs/remotes") == "refs/remotes/origin/main")
    finally:
        shutil.rmtree(d, ignore_errors=True)
        for m in made:
            shutil.rmtree(m, ignore_errors=True)

    # I5 통합: 보통 입력(턴 스냅숏) → /refactor:approve 합치기(입력 훅이 허락 + 기록 + 스냅숏) → 스크립트(거절 한 번 + 합침 한 번) → post-check 조용
    made = []
    d = _mk035()
    try:
        h = g(d, "rev-parse", "HEAD")
        fg0 = _fake035(made)
        pe = {"PATH": str(fg0) + os.pathsep + env()["PATH"]}
        hook("turn", d, {"session_id": "s1", "prompt": "안녕"})
        so, se, rc, _ = hook("turn", d, {"session_id": "s1", "prompt": "/refactor:approve 합치기 68 rebase"}, extra_env=pe)
        check("0.3.5 I5 준비: 입력 훅 허락 · 턴 스냅숏 있음", _gf035(d).exists() and (d / "docs/refactor/.turn-dirty.s1").exists(), so + se)
        seal = _seal_bytes035(d)
        out, rc, _ = _mg035(d, fg=_fake035(made, head=h, mergeable="UNKNOWN"), extra_env=_MG_W0)
        _, se, prc, _ = hook("post-check", d, {"session_id": "s1", "tool_name": "Bash"})
        check("0.3.5 I5 다시 실행(3) 뒤 기록·봉인·스냅숏 바이트 그대로 · post-check 조용", rc == 3 and _seal_bytes035(d) == seal and prc == 0 and se.strip() == "", f"{rc} {prc}\n{out}\n{se}")
        out, rc, _ = _mg035(d, fg=_fake035(made, head=h))
        _, se, prc, _ = hook("post-check", d, {"session_id": "s1", "tool_name": "Bash"})
        check("0.3.5 I5 합친 뒤 기록·봉인·스냅숏 바이트 그대로 · post-check 조용", rc == 0 and "✅ 합쳤습니다" in out and _seal_bytes035(d) == seal
              and prc == 0 and se.strip() == "", f"{rc} {prc}\n{out}\n{se}")
        hook("turn", d, {"session_id": "s1", "prompt": "/refactor:approve 합치기 68 rebase"}, extra_env=pe)
        seal = _seal_bytes035(d)
        out, rc, _ = _mg035(d, fg=_fake035(made, head=h, behind="3"))
        _, se, prc, _ = hook("post-check", d, {"session_id": "s1", "tool_name": "Bash"})
        check("0.3.5 I5 거절(1) 뒤 기록·봉인·스냅숏 바이트 그대로 · post-check 조용", rc == 1 and _seal_bytes035(d) == seal and prc == 0 and se.strip() == "",
              f"{rc} {prc}\n{out}\n{se}")
        check("0.3.5 I5 입력 훅은 gh 호출 0", _calls035(fg0) == [], "\n".join(_calls035(fg0)))
    finally:
        shutil.rmtree(d, ignore_errors=True)
        for m in made:
            shutil.rmtree(m, ignore_errors=True)


def check_commit_docs_033(check):
    """0.3.3 A2 C9: 단계 커밋은 Claude 가(7-execute 규칙 4·순서 5-1) · 사람 명령은 그 터미널에 맞게(go/SKILL.md 의 wsl -d 문단) — 지침 글자 검사."""
    sk = ROOT / "plugins/refactor/skills/go"
    ex = (sk / "phases/7-execute.md").read_text(encoding="utf-8")
    check("0.3.3 A2 7-execute: 'commit·push' 금지 문구 없음·규칙 4 는 push·merge·deploy",
          "commit·push" not in ex and "**하지 않는 것**: push·merge·deploy" in ex, ex[:0])
    i = ex.find("5-1. **커밋**")
    j = ex.find("6. **보고하고 다음 단계로 가거나 멈춘다.**", i)
    step = ex[i:j] if i >= 0 and j > i else ""
    need = ["refactor-safe-run -- git commit", "git add --", "git diff --cached --stat", "--no-verify",
            "`git add -A`·`git add .`·`git commit -a` 는 쓰지 않는다", "⚠️ 부분 완료·⛔ 중단·❓ 검증 불가면 커밋하지 않고"]
    check("0.3.3 A2 7-execute 5-1 커밋 절차: 안전 실행기·이름 지정 add·--cached --stat·조건",
          step != "" and all(n in step for n in need), str([n for n in need if n not in step]) + step[:300])
    check("0.3.3 A2 7-execute: 사람에게 'git add -A && git commit' 명령을 주지 않음", "git add -A &&" not in ex, "")
    gs = (sk / "SKILL.md").read_text(encoding="utf-8")
    # A3 H1: 늘 실리는 규칙(세션 시작 훅 · go 스킬 원칙 3)에 "커밋은 사람이"가 남지 않는다
    ss = (ROOT / "plugins/refactor/hooks/session-start.sh").read_text(encoding="utf-8")
    check("0.3.3 A3 H1 session-start.sh: 옛 '커밋·푸시·배포·운영 DB는 사람이' 0 · 새 규칙 있음",
          "커밋·푸시·배포·운영 DB는 사람이" not in ss
          and "푸시·PR 합치기는 사용자가 입력창 명령으로 한다(작업 가지 push 는 사용자가 /refactor:approve 푸시 로 허락한 차례에만 · 합치기는 /refactor:approve 합치기 · 합친 뒤 새 작업 가지는 /refactor:approve 새 가지) · 배포·운영 DB는 사람이 한다 · 기준선 커밋과 단계 커밋은 /refactor:go 가 그 파일만 한다" in ss, "")
    check("0.3.3 A3 H1 go/SKILL.md 원칙 3: 옛 'commit·push·merge는 사람이' 0 · 새 문장 있음",
          "commit·push·merge는 사람이" not in gs and "커밋 명령 초안만 준다" not in gs
          and "push·merge는 사람이 한다. 커밋은 두 곳에서만, 그 파일만 한다: 기준선 커밋은 5-baseline 2부 순서 5-1 대로, 단계 커밋은 7-execute 순서 5-1 대로." in gs, "")
    # A3 H2·H7·H10: 되돌리기 문장 · 허용 대기 뒤 묻지 않고 이어 가기 · PROFILE 의 터미널 칸
    # A4 L1(A3 H2 를 대신함): revert 는 마지막 단계만 깨끗 — 앞 단계는 기록 파일이 겹쳐 "코드만 되돌려" 부탁 · 다시 실행 대기가 되면 보류
    sev = next((l for l in ex.splitlines() if l.startswith("- ⑦")), "")
    check("0.3.3 A4 L1 7-execute ⑦: 마지막 단계 revert(+보류) · 앞 단계는 '코드만 되돌려' 부탁",
          all(n in sev for n in ("**마지막 단계**", "git revert --no-edit <해시>", "/refactor:approve 보류 <ID>", "**앞 단계**", "코드만 되돌려"))
          and "이 단계만 되돌리는 새 커밋" not in ex and "아직 올리지 않았으면 새 되돌림 커밋" not in ex, sev[:300])
    check("0.3.3 A4 L1 7-execute 기록: 되돌리는 법 칸에 커밋 찾는 법", "git log --grep \"^refactor: <ID> \"" in ex, "")
    check("0.3.3 A3 H7 7-execute: 기준선 허용 대기로 멈춘 단계는 묻지 않고 이어 감",
          "`기준선 허용 대기: <ID…>`" in ex and "기준선 허용을 기다리며 멈춘 경우" in ex, "")
    prof = (sk / "templates/PROFILE.md").read_text(encoding="utf-8")
    check("0.3.3 A3 H10 PROFILE 서식에 사람 터미널 칸 · go/SKILL.md 가 그 칸을 가리킴",
          "- 사람이 명령을 치는 터미널:" in prof and "\"사람이 명령을 치는 터미널\" 칸" in gs, "")
    para = next((l for l in gs.splitlines() if "wsl -d" in l), "")
    check("0.3.3 A2 go/SKILL.md: 사람 명령 wsl -d 문단(WSL 감지·한 번 묻기·절대경로·입력창 명령 먼저)",
          all(n in para for n in ("WSL_DISTRO_NAME", "/proc/version", "PROFILE.md", "wsl -d <배포판 이름> --cd <프로젝트 절대경로> -- <명령>", "절대경로", "/refactor:approve 푸시")),
          para[:400])
    # A4 L2: wsl 틀에는 작업 폴더(--cd)가 있고, Windows 꼴(wsl -d …) 명령 예시는 && 로 잇지 않는다 · WSL1 의 Microsoft 도 판정
    wins = [m for f in (sk / "SKILL.md", sk / "phases/0-setup.md", sk / "phases/7-execute.md", ROOT / "README.md")
            for m in re.findall(r"`(wsl -d [^`]*)`", f.read_text(encoding="utf-8"))]
    check("0.3.3 A4 L2 Windows 꼴 명령: 모두 --cd 있음 · && 없음",
          len(wins) >= 3 and all("--cd" in w and "&&" not in w for w in wins), repr(wins))
    check("0.3.3 A4 L2 go/SKILL.md: 명령마다 한 줄 · WSL1 Microsoft 판정 · :117 예시에 && 없음",
          "**명령마다 한 줄**" in para and "WSL1 은 `Microsoft`" in para
          and "`git add -A && git commit" not in gs, para[:300])
    st = (sk / "phases/0-setup.md").read_text(encoding="utf-8")
    check("0.3.3 A4 L4 0-setup: WSL 이면 터미널 질문 · PROFILE 칸에 적고 다시 묻지 않음",
          "어느 터미널에서 치시나요" in st and "\"사람이 명령을 치는 터미널\" 칸" in st and "다시 묻지 않는다" in st, "")



def check_docs_fix_034(check):
    """0.3.4 보완(검사 1차) 문서: F2 계정 문장 · F3 approve SKILL 6 · F8 🛠 만 · F9 ①②③④ · F12 멈춤 조건 ⓗ — 지침 글자 검사."""
    sk = ROOT / "plugins/refactor/skills/go"
    bl = (sk / "phases/5-baseline.md").read_text(encoding="utf-8")
    ex = (sk / "phases/7-execute.md").read_text(encoding="utf-8")
    gs = (sk / "SKILL.md").read_text(encoding="utf-8")
    ap = (ROOT / "plugins/refactor/skills/approve/SKILL.md").read_text(encoding="utf-8")
    rd = (ROOT / "README.md").read_text(encoding="utf-8")
    # F2 README: 뺀 '계정 고르기' 문장 없음 · gh 로그인 정보는 다루지 않음
    check("0.3.4 F2 README: 옛 계정 고르기 문장('토큰을 이 확인') 없음 · 로그인 정보 안 다룸 안내",
          "토큰을 이 확인" not in rd and "gh 로그인 정보는 다루지 않습니다 — 지금 gh 계정에 그 저장소 쓰기 권한이 있어야 합니다" in rd, "")
    # F9③ README §13: gcloud 조회가 풀린다는 틀린 문장 없음(코드는 계속 막음)
    check("0.3.4 F9③ README: 'gcloud deploy releases list' 풀림 문장 없음", "gcloud deploy releases list" not in rd, "")
    # F9① 5-baseline 5-1 머리(이미 커밋됐으면 6 으로) · 실패 표시 · go/SKILL ask-user 줄
    i = bl.find("5-1. **커밋**")
    j = bl.find("\n6. STATE:", i)
    c51 = bl[i:j] if i >= 0 and j > i else ""
    check("0.3.4 F9① 5-baseline 5-1: 이미 커밋돼 있으면 건너뛰고 6 · 실패 표시 '기준선 커밋 실패: <까닭>'",
          "이미 다 커밋돼 있으면" in c51 and "커밋을 건너뛰고 6 으로 간다" in c51 and "`기준선 커밋 실패: <까닭>`" in c51
          and c51.find("이미 다 커밋돼 있으면") < c51.find("이름을 하나씩 적는다"), c51[:300])
    ask = next((l for l in gs.splitlines() if l.lstrip().startswith("- `ask-user`:")), "")
    check("0.3.4 F9① go/SKILL ask-user: '기준선 커밋 실패' 표시면 다시 묻지 않고 5-1 부터",
          "`기준선 커밋 실패: …`" in ask and "다시 묻지 않고" in ask and "5-1(커밋)부터" in ask, ask)
    # F9② 7-execute ⑦: 묶음 첫 단계 커밋의 승인 기록 단서 · README 같은 단서
    r7 = next((l for l in ex.splitlines() if l.startswith("- ⑦ 되돌리는 법")), "")
    check("0.3.4 F9② 7-execute ⑦: 묶음 첫 단계 커밋엔 승인 기록 — revert 대신 '코드만 되돌려 줘'",
          "**묶음의 첫 단계**" in r7 and "승인이 풀리거나 봉인이 어긋난다" in r7 and "첫 단계도 \"<ID> 단계 코드만 되돌려 줘\"로" in r7, r7[:200])
    check("0.3.4 F9② README 사용 순서: 첫 단계 커밋 revert 단서", "묶음의 첫 단계 커밋에는 승인 기록도 들어 있어" in rd, "")
    # F9④ README §6-4 한계 두 줄
    a = rd.find("### 6-4. 한계")
    b = rd.find("\n## 7.", a)
    lim = rd[a:b] if a >= 0 and b > a else ""
    check("0.3.4 F9④ README §6-4: 새 가지는 받아 둔 origin 참조를 믿음 · 🔧 카드는 자동 허용 안 함",
          "새 가지는 이 PC 에 받아 둔 `origin/<기본 가지>` 를 믿습니다" in lim and "🔧 카드나 종류 칸이 없는 카드는" in lim, "")
    # F8 README·approve SKILL: 자동으로 여는 것은 🛠 카드만
    check("0.3.4 F8 README §6-3·§13 · approve SKILL: 저절로 열리는 것은 🛠 카드",
          rd.count("🛠 카드의 \"깨질 것으로 예상되는 기준선\" 칸에 파일이 백틱으로 적힌 단계는") == 2
          and "⚠️ 🛠 카드가 아니라 기준선 허용을 자동으로 열지 않았습니다" in ap, "")
    # F3 approve SKILL 6: 받아 온 뒤엔 늘 다시 입력(git log·diff 로 짐작 안 함) · 판정 불가면 터미널 대안
    s6 = ap[ap.find("6. **새 가지 결과**"):ap.find("7. **합치기 결과**")]
    check("0.3.4 F3 approve SKILL 6: 받아 온 뒤 늘 다시 입력 · log/diff 짐작 없음 · 판정 불가면 사람 터미널 꼴로 대안",
          "받아 온 뒤에는 늘" in s6 and "짐작하지 않는다" in s6 and "git log --oneline HEAD --not" not in s6
          and "판정하지 못했다" in s6 and "`git switch -c <이름> origin/<기본 가지>`" in s6 and "**사람의 터미널 꼴로**" in s6, s6[:300])
    # F12 멈춤 조건 ⓗ: 7-execute 표 · README 사용 순서·§13
    h = next((l for l in ex.splitlines() if l.startswith("| ⓗ |")), "")
    check("0.3.4 F12 7-execute ⓗ: 👤 사람 확인 필요·위험도 🔴 카드 뒤 멈춤",
          "\"👤 사람 확인 필요\"" in h and "위험도가 🔴" in h and "`/refactor:go` 로 계속" in h and "멈춤 조건 ⓐ~ⓗ 중" in ex, h)
    check("0.3.4 F12 README: 멈추는 일에 '👤 사람 확인 필요'·위험도 🔴 카드(사용 순서·§13)",
          rd.count("\"👤 사람 확인 필요\"·위험도 🔴 인 카드") == 2, "")


def check_docs_034(check):
    """0.3.4 문서: 이어서 실행(멈춤 조건) · 기준선 커밋도 Claude · 리다이렉트 든 사람 명령 · 자동 허용 · 새 가지·합치기 안내 — 지침 글자 검사."""
    sk = ROOT / "plugins/refactor/skills/go"
    bl = (sk / "phases/5-baseline.md").read_text(encoding="utf-8")
    ex = (sk / "phases/7-execute.md").read_text(encoding="utf-8")
    gs = (sk / "SKILL.md").read_text(encoding="utf-8")
    st = (sk / "phases/0-setup.md").read_text(encoding="utf-8")
    prof = (sk / "templates/PROFILE.md").read_text(encoding="utf-8")
    ap = (ROOT / "plugins/refactor/skills/approve/SKILL.md").read_text(encoding="utf-8")
    rd = (ROOT / "README.md").read_text(encoding="utf-8")
    ss = (ROOT / "plugins/refactor/hooks/session-start.sh").read_text(encoding="utf-8")

    # §3 기준선 커밋: 5-1(BASELINE 인 채로 커밋) 다음에 6(PLAN·gate none·결과 보고 후 멈춤) · 옛 "커밋해 달라" 문장 없음
    p2 = bl[bl.find("## 2부"):]
    i = p2.find("5-1. **커밋**")
    j = p2.find("\n6. STATE:", i)
    k = p2.find("\n> 참고:", j)
    c51 = p2[i:j] if i >= 0 and j > i else ""
    s6 = p2[j:k] if j > i and k > j else ""
    need51 = ["`phase: BASELINE` 인 채로", "`git add -- <파일들>`", "`git diff --cached --stat`",
              "refactor-safe-run -- git commit -m \"test: 기준선 테스트 추가\"", "`--no-verify`", "`git check-ignore -v <파일>`",
              "다시 시도하지 않는다", "`phase: BASELINE` 에 둔 채"]
    check("0.3.4 D2 5-baseline 5-1: Claude 가 BASELINE 인 채로 이름 지정 커밋(안전 실행기·--cached --stat·무시 파일 제외·실패 시 멈춤)",
          c51 != "" and all(n in c51 for n in need51), str([n for n in need51 if n not in c51]) + c51[:200])
    check("0.3.4 D2 5-baseline 6: PLAN·gate none·결과 보고 후 멈춤 · 옛 '지금 커밋해 달라고'·'git add -A' 없음 · 옛 판 프로젝트 안내 남김",
          s6 != "" and "`phase: PLAN`, `gate: none`" in s6 and "**결과를 보고하고 멈춘다**" in s6
          and "커밋해 달라" not in p2 and "git add -A &&" not in bl and "옛 판에서 \"기준선 커밋\" 대기로 멈춘 프로젝트" in s6,
          s6[:300])
    rows = {l.split("|")[1].strip(): l for l in gs.splitlines() if l.startswith("| ") and l.count("|") >= 6}
    check("0.3.4 D2 단계표 BASELINE 줄: Claude 가 기준선 커밋 → 결과 보고 후 멈춤 · 옛 '사람이 기준선 커밋' 없음",
          "Claude 가 기준선 커밋 → ⏸ 결과 보고 후 멈춤" in rows.get("BASELINE", "") and "사람이 기준선 커밋" not in gs,
          rows.get("BASELINE", ""))
    check("0.3.4 D1 단계표 EXECUTE 줄: 차례로 이어서 · 멈춤 조건 · 하나씩",
          all(n in rows.get("EXECUTE", "") for n in ("승인된 단계를 차례로 이어서", "멈춤 조건", "`하나씩`")),
          rows.get("EXECUTE", ""))
    check("0.3.4 D2 원칙 3·사람 명령: 기준선 커밋도 직접 · 옛 '(기준선 커밋은 사람이)' 없음",
          "(기준선 커밋은 사람이)" not in gs and "기준선 커밋과 단계 커밋은 사람에게 부탁하지 않고" in gs, "")

    # §8 이어서 실행: 7-execute 의 멈춤 조건 표(ⓐ~ⓗ 하나도 빠짐없이 — ⓗ 는 0.3.4 보완 F12·D7) · 하나씩 · STATE 적는 법 · 묶음 요약
    a = ex.find("## 0-2. 이어서 실행과 멈춤 조건")
    b = ex.find("\n## 1.", a)
    sec = ex[a:b] if a >= 0 and b > a else ""
    marks = ["| ⓐ |", "| ⓑ |", "| ⓒ |", "| ⓓ |", "| ⓔ |", "| ⓕ |", "| ⓖ |", "| ⓗ |"]
    check("0.3.4 D1 7-execute 0-2: 멈춤 조건 표 ⓐ~ⓗ 여덟 줄",
          sec != "" and all(sec.count(m) == 1 for m in marks), str([m for m in marks if sec.count(m) != 1]))
    needs = ["`/refactor:go 하나씩`", "묻지 않고", "`current_step: \"<ID> (완료)\"`", "`gate: G3-step`",
             "`current_step: \"<다음 ID> (진행 중)\"`", "| 단계 | 상태 | 커밋 |", "승인된 단계를 모두 끝냄",
             "`git status --porcelain -- . ':!docs/refactor'`", "`refactor:reviewer`", "\"그 단계를 실행하는 동안만 열림(지금은 닫힘)\"은"]
    check("0.3.4 D1 7-execute 0-2: 하나씩·STATE·묶음 요약·커밋 뒤 확인·검사·허용 닫힘 판정",
          all(n in sec for n in needs), str([n for n in needs if n not in sec]))
    check("0.3.4 D1 7-execute 제목·목표: '하나만'·'한 단계 실행' 없음 · 하나씩 차례로",
          "**하나만**" not in ex and "승인된 한 단계 실행" not in ex and "**하나씩 차례로**" in ex.splitlines()[2], ex[:200])
    check("0.3.4 D1 7-execute 0: 차례 시작 때의 실행 대기 목록만",
          "이번 차례를 **시작할 때**" in ex and "이 목록에 없던 단계를 더하지 않는다" in ex, "")
    s36 = next((l for l in ex.splitlines() if l.startswith("6. **보고")), "")
    check("0.3.4 D1 7-execute 순서 6: 멈춤 조건을 보고 다음 단계로 · 아니면 묶음 요약 후 멈춤",
          "「0-2」의 멈춤 조건" in s36 and "다음 단계의 1.(시작 전 확인)로 간다" in s36 and "묶음 요약을 보고하고 멈춘다" in s36, s36)
    check("0.3.4 D1 go/SKILL: 하나씩·이어서 실행 설명 · G3-step 이어서 · 멈추는 때에 멈춤 조건",
          "단계 실행에서는 승인된 단계 하나만 실행하고 멈춘다" in gs and "하나씩 차례로 이어서 한다" in gs
          and "남은 실행 대기 단계를 이어서 실행한다" in gs and "「0-2」의 멈춤 조건(ⓐ~ⓗ)" in gs, "")

    # §9 자동 허용: 멈추고 부탁하는 것은 닫혀 있을 때만 · PowerShell 대안은 Windows 경로일 때만
    r2 = next((l for l in ex.splitlines() if "🛠에서 예상된 기준선을 새 동작으로 바꿔야 하면" in l), "")
    check("0.3.4 D4 7-execute 규칙 2: 승인할 때 자동으로 열림 · 닫혀 있을 때만 부탁 · Set-Content 는 Windows 꼴 경로일 때만",
          "**승인할 때 허용이 자동으로 열린다**" in r2 and "**닫혀 있을 때만**" in r2 and "`기준선 허용 대기: <ID…>`" in r2
          and "Windows 꼴(`C:\\…`·`C:/…`)일 때만" in r2 and r2.find("Set-Content") > r2.find("PowerShell 꼴"), r2[:300])
    check("0.3.4 D4 approve SKILL·README: 옛 '승인과 허용은 따로다/따로입니다 — 승인만으로는' 없음 · 승인과 함께 열림 안내",
          "승인과 허용은 따로다" not in ap and "승인과 허용은 따로입니다 — 승인만으로는" not in rd
          and "**승인과 함께 열렸다**" in ap and "**승인할 때 허용이 저절로 열립니다**" in rd, "")

    # §4 사람 명령: 리다이렉트·파이프 든 명령은 wsl -d 꼴로 바꾸지 않음 · wsl -d 예시엔 리다이렉트·파이프 글자 없음
    new_line = next((l for l in gs.splitlines() if l.startswith("- **리다이렉트(")), "")
    check("0.3.4 D3 go/SKILL 사람에게 주는 명령: 리다이렉트·파이프 줄(Ubuntu 터미널에서 · bash 꼴 그대로)",
          all(n in new_line for n in ("`>`·`>>`", "`|`", "**Ubuntu 터미널에서**", "bash 꼴 그대로")), new_line[:300])
    wins = [m for f in (sk / "SKILL.md", sk / "phases/0-setup.md", sk / "phases/7-execute.md", ROOT / "README.md")
            for m in re.findall(r"`(wsl -d [^`]*)`", f.read_text(encoding="utf-8"))]
    bad = [w for w in wins if re.search(r"[>|]", re.sub(r"<[^<>]*>", "", w))]
    check("0.3.4 D3 Windows 꼴(wsl -d) 예시: 리다이렉트·파이프 글자 없음", len(wins) >= 3 and not bad, repr(bad or wins))
    check("0.3.4 D3 0-setup Q4·README .allow-env: 리다이렉트 줄을 가리킴(Ubuntu 터미널에서)",
          "「사람에게 주는 명령」의 리다이렉트 줄대로" in st and "**Ubuntu 터미널에서** 그대로 치세요" in rd, "")
    # 변이 대조: 리다이렉트를 wsl -d 로 감싼 예시를 넣으면 위 판정이 잡는다
    bad_demo = "`wsl -d Ubuntu --cd /home/me/shop -- printf 'x' >> a`"
    check("0.3.4 D3 대조: wsl -d 예시에 >> 가 들면 잡힘",
          bool(re.search(r"[>|]", re.sub(r"<[^<>]*>", "", re.findall(r"`(wsl -d [^`]*)`", bad_demo)[0]))), "")

    # §2-5·§10-5 새 가지·합치기: approve SKILL · PROFILE 칸 · go/SKILL · 7-execute ⑩ · session-start · README
    hint = next((l for l in ap.splitlines() if l.startswith("argument-hint:")), "")
    check("0.3.4 D5 approve SKILL argument-hint: 합치기·새 가지",
          "합치기 [번호] [rebase|squash|merge]" in hint and "새 가지 [이름]" in hint, hint)
    needs_ap = ["**이번 턴에** `git fetch origin` 을 한 번 실행한다", "`/refactor:approve 새 가지` 를 다시 입력해 주세요",
                "`gh pr view <번호> --json state,mergedAt`", "운영 배포가 시작될 수 있다", "읽기 명령만",
                "6의 `git fetch origin`"]
    check("0.3.4 D5 approve SKILL 할 일: 받아 오기 뒤 다시 입력 · 결과 없으면 PR 상태 읽기 · 배포 경고·읽기 명령만",
          all(n in ap for n in needs_ap), str([n for n in needs_ap if n not in ap]))
    pl = next((l for l in prof.splitlines() if l.startswith("- PR 합치는 방식:")), None)
    check("0.3.4 D5 PROFILE 서식: 'PR 합치는 방식' 칸 · 서식 그대로는 방식 낱말 하나로 읽히지 않음",
          pl is not None and re.fullmatch(r"\s*(rebase|squash|merge)\s*", pl.split(":", 1)[1]) is None, repr(pl))
    check("0.3.4 D5 go/SKILL: 처음 합칠 때 방식을 묻고 PROFILE 칸에 · 새 주기 가지는 새 가지 명령",
          "\"PR 합치는 방식\" 칸" in gs and "다시 묻지 않는다" in gs.split("**PR 합치기 방식**", 1)[-1]
          and gs.count("`/refactor:approve 새 가지`") >= 2, "")
    s10 = ex[ex.find("- ⑩"):]
    flow = ["`/refactor:approve 푸시`", "`gh pr create`", "`/refactor:approve 합치기`", "배포 확인", "`/refactor:approve 새 가지`"]
    pos = [s10.find(n) for n in flow]
    check("0.3.4 D5 7-execute ⑩: 푸시 → PR → 합치기 → 배포 확인 → 새 가지 순서",
          all(x >= 0 for x in pos) and pos == sorted(pos), repr(pos))
    check("0.3.4 D5 session-start 규칙: 합치기·새 가지는 입력창 명령 · 배포·운영 DB 는 사람",
          "합치기는 /refactor:approve 합치기" in ss and "새 작업 가지는 /refactor:approve 새 가지" in ss and "배포·운영 DB는 사람이 한다" in ss, "")
    cmd_row = next((l for l in rd.splitlines() if l.startswith("| `/refactor:approve` |")), "")
    check("0.3.4 D5 README 명령 표: 합치기·새 가지",
          "`합치기`" in cmd_row and "`새 가지`" in cmd_row, cmd_row[:200])
    check("0.3.4 D5 README §6-3: 합치기·새 가지 문단",
          "**PR 합치기 — `/refactor:approve 합치기`**" in rd and "**새 작업 가지 — `/refactor:approve 새 가지`**" in rd, "")

    # §5·§6 README 한계·변경점·판 번호
    check("0.3.4 D6 README 한계: 옛 '사람이 터미널에서 옮겨야'·'set-url 막지 않습니다' 없음 · 새 한계(주석 속 작은따옴표·원격 설정·허락 push·합치기)",
          "사람이 터미널에서 옮겨야 합니다(원격만으로는 안 됩니다)" not in rd
          and "원격 주소를 바꾸는 것은 막지 않습니다" not in rd
          and "`#` 주석 안에 짝 없는 작은따옴표" in rd and "원격 저장소·올리기 설정" in rd
          and "프로젝트 안의 다른 저장소(중첩 저장소·서브모듈·워크트리)" in rd and "포크에서 온 PR" in rd, "")
    i13 = rd.find("### 0.3.4 (")
    j13 = rd.find("### 0.3.3 (", i13)
    ch = rd[i13:j13] if i13 >= 0 and j13 > i13 else ""
    check("0.3.4 D6 README 변경점: 0.3.4 절 · 이슈 #14 · 뒤집은 결정 · 0.3.3 절보다 앞",
          ch != "" and "#14" in ch and "\"승인과 허용은 따로\" 결정을" in ch and "> **0.3.4에서 달라진 점**" in rd, ch[:200])
    pr = (ROOT / "plugins/refactor/README.md").read_text(encoding="utf-8")
    check("0.3.4 D7 플러그인 README 한 줄 요약: 이어서 실행 · 합치기·새 가지",
          "차례로 이어서 실행" in pr and "(`합치기`)" in pr and "(`새 가지`)" in pr, "")


def check_docs_035(check):
    """0.3.5 문서(설계서 §9 D1~D6 · §8 C1·C2·C4): approve SKILL 합치기 새 흐름 · README 합치기 절·배포 되돌리는 길 ·
    판 요약·변경점 · CI 두 시험 동시에(검사 이름·한도 그대로) — 지침 글자 검사."""
    ap = (ROOT / "plugins/refactor/skills/approve/SKILL.md").read_text(encoding="utf-8")
    rd = (ROOT / "README.md").read_text(encoding="utf-8")
    pr = (ROOT / "plugins/refactor/README.md").read_text(encoding="utf-8")
    ex = (ROOT / "plugins/refactor/skills/go/phases/7-execute.md").read_text(encoding="utf-8")
    yml = (ROOT / ".github/workflows/test.yml").read_text(encoding="utf-8")

    # D1 머리: allowed-tools 에 합치기 스크립트(그 차례에만 묻지 않음 — 진짜 관문은 guard) · description 새 흐름
    at = next((l for l in ap.splitlines() if l.startswith("allowed-tools:")), "")
    check("0.3.5 D1 approve SKILL allowed-tools: refactor-approve 그대로 + refactor-merge 추가",
          at.split() == ["allowed-tools:", "Bash(bash", "*run.sh*refactor-approve*)", "Bash(bash", "*run.sh*refactor-merge*)"], at)
    desc = next((l for l in ap.splitlines() if l.startswith("description:")), "")
    check("0.3.5 D1 approve SKILL description: 합치기는 허락 → 그 턴에 Claude 가 플러그인 스크립트로 확인 뒤 합침",
          "PR 합치기를 그 차례에만 허락하고(합치기 — 그 턴에 Claude 가 플러그인 스크립트로" in desc
          and "자동 검사가 초록인 PR 을 합치고(합치기)" not in desc, desc)
    # D1 7절: 그대로 실행 · 되풀이 · 같은 실패 3번이면 멈춤 · 거절은 다시 실행 안 함 · 막히면 다시 입력 · 알 수 없음은 PR 상태 읽기
    s7 = ap[ap.find("7. **합치기 결과**"):ap.find("\n8. ")]
    need7 = ["`✅ 합치기 허락:`", "**이번 턴에**", "Bash 도구로 **그대로** 실행한다(다른 것을 붙이지 않는다",
             "**같은 명령을 다시 실행한다** — 자동 검사가 끝날 때까지 되풀이한다",
             "**같은 ⚠️ 가 3번 이어지면 멈추고**", "`⛔`·`❓` 거절이면", "**다시 실행하지 않는다**(허락이 끝났다)",
             "**안전장치(`[refactor 안전장치]`)에 막혔으면**", "\"`/refactor:approve 합치기` 를 다시 입력해 주세요\"",
             "**\"합쳐졌는지 알 수 없습니다\"**", "`gh pr view <번호> --json state,mergedAt`",
             "\"기본 가지에 합쳐지면 운영 배포가 시작될 수 있다\"는 경고를 줄이지 말고", "읽기 명령만"]
    check("0.3.5 D1 approve SKILL 7: 허락 명령 그대로 실행·되풀이·3번 멈춤·거절은 다시 안 함·막히면 다시 입력·알 수 없음은 PR 상태",
          s7 != "" and all(n in s7 for n in need7), str([n for n in need7 if n not in s7]) + s7[:200])
    check("0.3.5 D1 approve SKILL 7: 옛 '결과 블록이 없으면(입력 훅이 시간 안에 끝나지 못함)' 줄 없음",
          "입력 훅이 시간 안에 끝나지 못함" not in ap and "gh pr view --json number,state,mergedAt" not in ap, "")
    s9 = next((l for l in ap.splitlines() if l.startswith("9. ")), "")
    check("0.3.5 D1 approve SKILL 9: 예외 목록에 '7의 합치기 명령'",
          "7의 합치기 명령" in s9 and "6의 `git fetch origin`" in s9, s9)

    # 보완(설계서 §14) — SKILL: F4 30분 경고(H10 문장 그대로) · F9 배경 실행 금지 · F11 모든 ⚠️ 3번 · F14 문구 통일
    h10 = ("⚠️ 허락한 뒤 최대 30분 사이에는 사람이 보고 있지 않아도 조건이 맞으면 합쳐지고 운영 배포가 시작될 수 있습니다 — "
           "멈추려면 아무 말이나 입력하세요(다음 입력에 허락이 끝납니다 · Claude 가 실행 중이면 Esc 로 멈춘 뒤).")
    check("0.3.5 F4 approve SKILL 7: 허락 결과의 30분 경고를 H10 문장 그대로 전함(멈추려면 아무 말이나 입력 · Esc)",
          f"`{h10}`" in s7 and "30분 경고를 줄이지 말고 그대로 전한다" in s7, s7[:300])
    check("0.3.5 F9 approve SKILL 7: 합치기 명령은 배경 실행 금지 — 전경에서 결과를 받음",
          "**배경 실행(`run_in_background`)으로 돌리지 않는다** — 전경에서 결과를 받는다" in s7, "")
    check("0.3.5 F11 approve SKILL 7: '같은 ⚠️ 가 3번' — 모든 ⚠️(임시 폴더 실패 포함) · 옛 '조회·비교 실패가 3번' 없음",
          "(조회·비교 실패뿐 아니라 임시 폴더 실패 등 모든 ⚠️)" in s7 and "조회·비교 실패가 3번" not in ap, "")
    s5 = next((l for l in ap.splitlines() if l.startswith("5. **push 허락**")), "")
    check("0.3.5 F14 approve SKILL 5: 'PR 을 만들었으면 … /refactor:approve 합치기'(검사는 스크립트가 기다림) · 옛 '초록이 된 뒤' 없음",
          "(PR 을 만들었으면 사용자가 입력창에 `/refactor:approve 합치기` — 자동 검사는 스크립트가 기다린다)" in s5
          and "초록이 된 뒤" not in ap, s5[-200:])
    check("0.3.5 F14 approve SKILL 7: ℹ️ 마무리 뒤 = 합친 것이 아님(평소처럼 합칠 수 있다)",
          "`ℹ️ 이미 마무리되어 안전장치가 꺼져 있습니다`면 **합친 것이 아니다** — 리팩토링이 마무리되어 평소처럼 합칠 수 있다는 뜻이다. 합쳤다고 전하지 말고" in s7, "")
    check("0.3.5 F14 approve SKILL 7: 막혔을 때 안내에 '아래 꼴 그대로 한 번만 다시 실행'이 있으면 그 꼴 그대로 한 번만 · 그 밖은 다시 입력",
          "안내에 \"아래 꼴 그대로 한 번만 다시 실행\"이 있으면 명령을 고치지 말고 안내에 적힌 꼴 그대로 **한 번만** 다시 실행한다" in s7
          and "그 밖(30분이 지남·허락 없음 등)이면 명령을 고쳐 다시 시도하지 말고" in s7, "")
    # 보완 3바퀴 R5(재검사 C2 🟡): F1 거절 뒤 길 = 먼저 푸시 → 새 PR → '새 커밋 N개' 거절이면 Update branch → 다시 합치기 · 번호 확인
    check("0.3.5 F14·R5 approve SKILL 7: 이미 합쳐진 PR 거절(F1) = 푸시 → 새 PR → Update branch → 다시 합치기 · 번호 확인 · 승인 기록 불일치(F7)·허락 사라짐(F9) = 다시 입력",
          "`⛔ PR #… 은 이미 합쳐진 PR 입니다`면 합쳤다고 전하지 않는다. 이미 합쳐진 PR 이면 — 합친 뒤 올린 새 커밋이 있다는 뜻이다: "
          "먼저 `/refactor:approve 푸시` → 새 PR(`gh pr create`) → 기본 가지에 합친 커밋이 있어 '새 커밋 N개' 거절이 나오면 "
          "GitHub PR 화면의 Update branch → 다시 `/refactor:approve 합치기`. 번호를 잘못 줬으면 번호 확인." in s7
          and "새 PR 을 만들거나" not in s7
          and "`⛔ 합치기 허락이 승인 기록과 맞지 않습니다`·`⛔ 허락이 사라졌거나 바뀌었습니다`(끝 줄이 \"허락은 끝났습니다\")면 사용자에게 `/refactor:approve 합치기` 를 다시 입력해 달라고 한다" in s7
          and "끝 줄이 \"새 허락은 그대로입니다\"면 사용자가 방금 새로 허락한 것이니, 이번 차례의 새 결과 블록에 적힌 명령을 그대로 한 번 실행한다" in s7, "")

    # D5 배포가 깨졌을 때 세 갈래(approve SKILL 7 · README §6-3) · "전부 막는다"고 쓰지 않음(heroku·netlify rollback 은 규칙에 없음)
    d5 = ["이전 배포로", "Revert 버튼으로 되돌리는 PR", "사람이 GitHub 화면에서 합", "지금 작업 가지의 PR 만 받",
          "`vercel rollback`·`wrangler rollback`·`railway redeploy` 등)", "안전장치가 막"]
    a = rd.find("**PR 합치기 — `/refactor:approve 합치기`**")
    b = rd.find("**새 작업 가지 — `/refactor:approve 새 가지`**", a)
    mg = rd[a:b] if a >= 0 and b > a else ""
    check("0.3.5 D5 approve SKILL 7: 배포가 깨졌을 때 ①이전 배포 ②Revert PR 은 사람이 ③Claude 의 되돌리기 명령은 막힘",
          all(n in s7 for n in d5) and "읽기 확인만" in s7, str([n for n in d5 if n not in s7]))
    check("0.3.5 D5 README §6-3: 합친 뒤 배포가 깨졌을 때 세 갈래",
          "**합친 뒤 배포가 깨졌을 때**" in mg and all(n in mg for n in d5) and "읽기 확인만" in mg, str([n for n in d5 if n not in mg]))
    check("0.3.5 D5 '전부 막는다' 류 단정 없음(approve SKILL·README)",
          not re.search(r"(전부|모두|모든)[^。\n]{0,20}(되돌리기|rollback)[^\n]{0,20}막", ap + rd), "")

    # D2 README §6-3 합치기 절: 허락만 · 기다렸다 합침 · 그 차례·30분·허락한 커밋 · 30분 사이 배포 경고 · 기록에 안 남음 · 네트워크 막히면 3번 · 옛 '입력 훅의 30초' 없음
    need2 = ["**합치기를 허락만**", "입력 훅은 인터넷에 닿지 않습니다", "**검사가 끝날 때까지 기다렸다가**",
             "허락은 **그 차례에만**", "**30분 안**", "**허락한 그 커밋(지금 커밋)일 때만**", "허락도 끝납니다",
             "그 커밋이 허락한 커밋과 같음", "승인 기록(`APPROVALS.log`)에 남지 않습니다", "정본은 GitHub",
             "같은 실패가 3번 이어지면 Claude 가 멈춥니다", "gh 로그인 정보는 다루지 않습니다"]
    check("0.3.5 D2 README §6-3 합치기 절: 새 흐름(허락만·기다림·그 차례·30분·허락 커밋·기록 안 남음·3번 멈춤)",
          mg != "" and all(n in mg for n in need2), str([n for n in need2 if n not in mg]))
    check("0.3.5 D2 README §6-3: '허락한 뒤 최대 30분 사이 … 배포가 시작될 수 있습니다' 경고",
          re.search(r"허락한 뒤 최대 30분 사이[^\n]*배포가 시작될 수 있습니다", mg) is not None, mg[:200])
    check("0.3.5 F4 README §6-3: 30분 경고가 H10 과 같은 뜻 — 보고 있지 않아도 · 멈추려면 아무 말이나 입력(다음 입력에 허락 끝 · Esc)",
          "**허락한 뒤 최대 30분 사이에는 사람이 보고 있지 않아도 조건이 맞으면 합쳐지고 운영 배포가 시작될 수 있습니다 — "
          "멈추려면 아무 말이나 입력하세요(다음 입력에 허락이 끝납니다 · Claude 가 실행 중이면 Esc 로 멈춘 뒤).**" in mg, "")
    check("0.3.5 F2 README §6-3: 초록 두 번 연속(10초 간격·같은 검사 목록) 확인 뒤 합침 · 보호 규칙 켜 두기(비공개 무료는 못 켬)",
          "자동 검사가 **두 번 연속** 초록인지(10초 간격 · 같은 검사 목록 · 같은 PR 커밋) 확인한 뒤 합칩니다" in mg
          and "보호 규칙(필수 검사)을 켤 수 있는 저장소면 켜 두세요 — 그래야 GitHub 이 한 번 더 막습니다(비공개 무료 저장소는 보호 규칙을 못 켭니다)" in mg, "")
    check("0.3.5 D2 README §6-3: 옛 '입력 훅의 30초'·'치면 바로 입력 훅이 gh 로' 없음",
          "입력 훅의 30초" not in mg and "치면 바로 입력 훅이 `gh`로" not in rd, "")

    # D3 README 판 요약 줄 · §6-4 한계 · §13 0.3.5 절(0.3.4 절보다 앞 · 알려진 한계)
    i4 = rd.find("> **0.3.4에서 달라진 점**")
    i5 = rd.find("> **0.3.5에서 달라진 점**")
    line5 = rd[i5:rd.find("\n", i5)] if i5 >= 0 else ""
    check("0.3.5 D3 README '0.3.5에서 달라진 점' 줄: 0.3.4 줄 다음 · 허락만·기다렸다 합침",
          0 <= i4 < i5 and "허락만" in line5 and "기다렸다 합칩니다" in line5, line5)
    a = rd.find("### 6-4. 한계")
    b = rd.find("\n## 7.", a)
    lim = rd[a:b] if a >= 0 and b > a else ""
    lm = next((l for l in lim.splitlines() if l.startswith("- `/refactor:approve 합치기`는")), "")
    check("0.3.5 D3 README §6-4 합치기 한계: 30분 사이 합쳐질 수 있음·기록에 안 남음·gh 네트워크 막히면 사람이",
          "최대 30분 사이" in lm and "승인 기록에 남지 않습니다" in lm and "`gh`의 네트워크를 막으면" in lm and "포크에서 온 PR" in lm, lm)
    # 보완 3바퀴 R6(재검사 C2 🟢): 한계 절의 30분 문장 끝에 §6-3 과 같은 글자의 "멈추려면 아무 말이나 입력" 안내
    check("0.3.5 R6 README §6-4 합치기 한계: 30분 문장 끝에 '멈추려면 아무 말이나 입력하세요(… Esc 로 멈춘 뒤).'(§6-3 과 같은 글자)",
          "최대 30분 사이 사람이 안 보고 있을 때 합쳐질 수 있습니다 — 멈추려면 아무 말이나 입력하세요(다음 입력에 허락이 끝납니다 · "
          "Claude 가 실행 중이면 Esc 로 멈춘 뒤)." in lm, lm)
    i13 = rd.find("### 0.3.5 (")
    j13 = rd.find("### 0.3.4 (", i13)
    ch = rd[i13:j13] if i13 >= 0 and j13 > i13 else ""
    need13 = ["**합치기는 허락만, 합치는 것은 그 차례의 Claude**", "**PR 쪽과 내 커밋이 다를 때 안내 넷**",
              "**이미 커밋된 앞 단계 기준선을 다시 바꾸면 알림**", "`gh api`로 PR 을 합치는 꼴", "인터프리터로 플러그인 폴더의 파일을 쓰는 꼴",
              "**CI 두 시험을 동시에**", "**합친 뒤 배포가 깨졌을 때 갈 길**", "**알려진 한계**", "`/refactor:go 다시`",
              "`heroku rollback`·`netlify rollback`은 안전장치 규칙에 없습니다"]
    check("0.3.5 D3 README §13: 0.3.5 절이 0.3.4 절 앞 · 합치기 새 흐름·#21·#1·X1·X2·CI·#20·알려진 한계",
          ch != "" and all(n in ch for n in need13), str([n for n in need13 if n not in ch]))

    # D4 플러그인 README · 7-execute ⑩
    check("0.3.5 D4 플러그인 README: 'PR 합치기 허락(`합치기`)'", "PR 합치기 허락(`합치기`)" in pr, "")
    s10 = ex[ex.find("- ⑩"):]
    check("0.3.5 D4 7-execute ⑩: 합치기는 허락만 — 그 턴에 Claude 가 검사 초록을 기다렸다 합침 · 옛 '초록이 되면 입력창에' 없음",
          "`/refactor:approve 합치기`(허락만 — 그 턴에 Claude 가 허락된 명령으로 자동 검사가 초록이 되기를 기다렸다 합친다)" in s10
          and "PR 의 자동 검사가 초록이 되면 입력창에 `/refactor:approve 합치기`" not in ex, s10[:300])

    # C4 README §12: 시험 수 줄(:400 — 메인 몫) 바로 다음 줄에 CI 동시 실행 안내
    lines = rd.splitlines()
    k = next((n for n, l in enumerate(lines) if "동시에 여러 개를 돌리지 마세요" in l), -1)
    check("0.3.5 C4 README §12: 시험 수 줄 다음에 'CI 는 두 시험을 한 잡 안에서 동시에' 한 줄",
          k >= 0 and k + 1 < len(lines) and lines[k + 1] == "- CI 는 두 시험을 한 잡 안에서 동시에 돌립니다(로컬 PC 에서는 위 안내대로 하나씩).",
          lines[k + 1] if 0 <= k < len(lines) - 1 else "")

    # C1·C2 test.yml: 잡 하나 · 검사 이름·한도·매트릭스 그대로 · 두 시험을 한 단계에서 동시에(각자 로그 · 둘 다 기다림 · 하나라도 실패면 실패) · always() 로그 단계
    ylines = yml.splitlines()
    jobs = ylines[ylines.index("jobs:") + 1:] if "jobs:" in ylines else []
    check("0.3.5 C1 test.yml: 잡은 test 하나 · 검사 이름 'test (${{ matrix.os }})' · timeout-minutes: 30 그대로",
          [l for l in jobs if re.fullmatch(r"  [A-Za-z0-9_-]+:\s*", l)] == ["  test:"]
          and "    name: test (${{ matrix.os }})" in ylines and "    timeout-minutes: 30" in ylines, "")
    check("0.3.5 C1 test.yml: 매트릭스 칸 그대로(ubuntu-latest·windows-latest·macos-latest·미리보기)",
          all(n in yml for n in ("- { os: ubuntu-latest, image: ubuntu-24.04, preview: false }",
                                  "- { os: windows-latest, image: windows-latest, preview: false }",
                                  "- { os: macos-latest, image: macos-latest, preview: false }",
                                  "- { os: ubuntu-26.04 미리보기, image: ubuntu-26.04, preview: true }")), "")

    def step(name):
        i = next((n for n, l in enumerate(ylines) if l.strip() == f"- name: {name}"), -1)
        if i < 0:
            return ""
        j = next((n for n in range(i + 1, len(ylines)) if ylines[n].strip().startswith("- name:")
                  or ylines[n].strip().startswith("- uses:") or ylines[n].lstrip().startswith("# ")), len(ylines))
        return "\n".join(ylines[i:j])
    both = step("test_guard · test_scripts (동시에)")
    check("0.3.5 C1 test.yml: 한 단계에서 두 시험을 동시에(bash · 각자 로그 · & · 둘 다 wait · 하나라도 실패면 실패)",
          both != "" and "        shell: bash" in both
          and re.search(r'^\s*python -u tests/test_guard\.py > "\$RUNNER_TEMP/test_guard\.log" 2>&1 &$', both, re.M) is not None
          and re.search(r'^\s*python -u tests/test_scripts\.py > "\$RUNNER_TEMP/test_scripts\.log" 2>&1 &$', both, re.M) is not None
          and 'wait "$pid_guard"' in both and 'wait "$pid_scripts"' in both
          and both.rstrip().endswith('[ "$rc_guard" -eq 0 ] && [ "$rc_scripts" -eq 0 ]'), both)
    check("0.3.5 C1 test.yml: 옛 차례 실행 단계(run: python tests/test_guard.py) 없음 · 두 시험은 그 한 단계에서만",
          "run: python tests/test_guard.py" not in yml and "run: python tests/test_scripts.py" not in yml
          and yml.count("tests/test_guard.py") == 1 and yml.count("tests/test_scripts.py") == 1, "")
    check("0.3.5 F12 test.yml: 시험 단계 한도 timeout-minutes: 27(잡 30분보다 먼저) · 두 python 모두 -u(로그 버퍼 없이)",
          "        timeout-minutes: 27" in both.splitlines() and both.count("python -u tests/") == 2
          and not re.search(r"^\s*python (?!-u )", both, re.M), both)
    logs = step("시험 로그")
    after = both != "" and logs != "" and ylines.index(logs.splitlines()[0]) > ylines.index(both.splitlines()[0])
    check("0.3.5 C2 test.yml: 시험 단계 뒤 로그 단계 — if: always() · ::group:: 묶음 · 맨 끝에 'N/N 통과' 줄",
          after and "        if: always()" in logs and 'echo "::group::$n"' in logs and 'echo "::endgroup::"' in logs
          and "grep -E '^[0-9]+/[0-9]+ 통과'" in logs, logs)


if __name__ == "__main__":
    sys.exit(main())
