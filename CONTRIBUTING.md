# 기여하기

## 개발 환경

- **Git Bash**(Windows) 또는 macOS/Linux 셸
- **Python** (`python tests/test_guard.py && python tests/test_scripts.py` 로 안전장치·스크립트 시험을 돌립니다. macOS 는 `python3`)
- **Claude Code** (`claude plugin validate --strict plugins/refactor` 로 매니페스트를 검증합니다)

## 브랜치·커밋 규칙

- `main` 은 보호돼 있어 직접 push 할 수 없습니다 — 가지(쓰기 권한이 없으면 포크)를 만들어 PR 로 합쳐 주세요.
- 커밋 제목은 한국어로 써도 됩니다 (예: `fix: guard.sh 의 역슬래시 경로 처리`).
- 커밋 메시지 마지막 줄에 서명을 남겨 주세요.

## 시험 추가 의무

**막는 규칙(안전장치)을 새로 추가하거나 고칠 때는 반드시 다음 두 가지를 테스트에 함께
추가하세요:**

1. **차단 케이스** — 그 규칙이 막아야 하는 입력 1개
2. **통과 대조군** — 비슷하지만 막히면 안 되는 입력 1개 (과잉 차단 방지)

STATE 없는 폴더에서 guard 를 손으로 부르면 늘 0 입니다(0.3.0부터 리팩토링 중에만 판정) — 재현할 때는 `REFACTOR_GUARD_ALWAYS=1` 을 주거나 `docs/refactor/STATE.md` 가 있는 폴더에서 부르세요.

## Pull Request

PR 을 올릴 때는 [PR 양식](.github/PULL_REQUEST_TEMPLATE.md)의 항목을 채워 주세요.

## 릴리스 (관리자)

새 판을 낼 때는 이 순서대로 합니다.

1. 판 번호 네 곳을 같이 올린다(스크립트 시험이 확인합니다): `plugins/refactor/.claude-plugin/plugin.json`·`.claude-plugin/marketplace.json`·`README.md` 배지·`.github/ISSUE_TEMPLATE/bug.yml` 의 `placeholder`. `plugins/refactor` 를 바꿨으면 판을 꼭 올립니다 — 판이 그대로면 이미 설치한 사람에게 전달되지 않습니다(공식 문서: `version` 은 바꿀 때까지 그 판에 고정).
2. 세 OS 시험 — PR 을 올리면 GitHub Actions(`.github/workflows/test.yml`)가 Ubuntu·Windows(Git Bash)·macOS(기본 bash 3.2)에서 `python tests/test_guard.py`·`python tests/test_scripts.py` 를 자동으로 돌립니다. 손으로 돌릴 때도 같은 두 명령입니다. macOS 기본 bash 로 CI 와 똑같이 돌리려면 훅이 안에서 다시 부르는 `bash` 도 3.2 여야 하므로 `mkdir -p /tmp/b32 && ln -sf /bin/bash /tmp/b32/bash` 뒤에 두 시험 앞에 `GUARD_BASH=/bin/bash GUARD_PATH_PREFIX=/tmp/b32` 를 붙입니다.
3. `README.md` §12(시험 수치)와 §13(변경점)을 갱신합니다.
4. `main` 은 보호돼 있습니다 — 가지를 만들어 PR 로 합칩니다. 세 OS(Ubuntu·Windows·macOS) 시험이 모두 초록이어야 합쳐집니다.
5. `gh release create v<판> --target <합친 커밋> --title v<판> --notes-file <변경점 발췌>` 로 릴리스를 만듭니다.
6. 설치본을 올립니다: `claude plugin marketplace update vibe-consulting` → `claude plugin update refactor@vibe-consulting` → 이미 열려 있는 세션은 `/reload-plugins`.
7. 설치본이 저장소와 같은지 확인합니다: `diff -rq plugins/refactor ~/.claude/plugins/cache/vibe-consulting/refactor/<판>` — `.in_use` 한 줄만 다르면 정상입니다.

---

## 관리자 할 일 (저장소를 처음 만들 때)

- [ ] 저장소 **Issues**·**Discussions** 켜기
- [ ] **Settings → Code security → Private vulnerability reporting** 켜기 ([설정 방법](https://docs.github.com/en/code-security/security-advisories/working-with-repository-security-advisories/configuring-private-vulnerability-reporting-for-a-repository)) — 이걸 켜야 [`SECURITY.md`](SECURITY.md)가 안내하는 "Report a vulnerability" 버튼이 보입니다.
- [ ] 라벨 `bug` / `제안` / `보안` 만들기
