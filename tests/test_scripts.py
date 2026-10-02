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
        return subprocess.run([BASH, "-c", 'eval "$(tr -d \'\\r\' < "$1")"; rl_log_sum "$2"', "x", libsh, lg.as_posix()],
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

    check(f"훅 시간 초과({HOOK_TIMEOUT}초) 0건", not HOOK_TIMEOUTS, " / ".join(HOOK_TIMEOUTS))

    for label, detail in fails:
        print(f"FAIL {label}\n      {detail}")
    print(f"\n{total - len(fails)}/{total} 통과 · bash={BASH}{' · PATH+' + PATH_PREFIX if PATH_PREFIX else ''}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
