# 기여하기

## 개발 환경

- **Git Bash**(Windows) 또는 macOS/Linux 셸
- **Python** (`python tests/test_guard.py && python tests/test_scripts.py` 로 안전장치·스크립트 시험을 돌립니다)
- **Claude Code** (`claude plugin validate --strict plugins/refactor` 로 매니페스트를 검증합니다)

## 브랜치·커밋 규칙

- 커밋 제목은 한국어로 써도 됩니다 (예: `fix: guard.sh 의 역슬래시 경로 처리`).
- 커밋 메시지 마지막 줄에 서명을 남겨 주세요.

## 시험 추가 의무

**막는 규칙(안전장치)을 새로 추가하거나 고칠 때는 반드시 다음 두 가지를 테스트에 함께
추가하세요:**

1. **차단 케이스** — 그 규칙이 막아야 하는 입력 1개
2. **통과 대조군** — 비슷하지만 막히면 안 되는 입력 1개 (과잉 차단 방지)

## Pull Request

PR 을 올릴 때는 [PR 양식](.github/PULL_REQUEST_TEMPLATE.md)의 항목을 채워 주세요.

---

## 관리자 할 일 (저장소를 처음 만들 때)

- [ ] 저장소 **Issues**·**Discussions** 켜기
- [ ] **Settings → Code security → Private vulnerability reporting** 켜기 ([설정 방법](https://docs.github.com/en/code-security/security-advisories/working-with-repository-security-advisories/configuring-private-vulnerability-reporting-for-a-repository)) — 이걸 켜야 [`SECURITY.md`](SECURITY.md)가 안내하는 "Report a vulnerability" 버튼이 보입니다.
- [ ] 라벨 `bug` / `제안` / `보안` 만들기
