# 3단계: 정밀검사 (DEEP)

목표: 건강검진에서 🔴·🟠이 나온 영역과, 프로필상 꼭 봐야 하는 영역만 깊게 본다. 결과는 `docs/refactor/audit/<점검표 이름>.md`에 남긴다.

## 1. 무엇을 돌릴지 정한다
건강검진 항목 → 점검표 대응:

| 건강검진 항목 | 점검표 (`${CLAUDE_SKILL_DIR}/checklists/`) |
|---|---|
| A1 | deep-access.md |
| A2 | deep-input.md |
| A3, C3 | deep-secrets.md |
| A4 | deep-payment.md |
| A5 | deep-privacy-logs.md |
| A6 | deep-compliance.md |
| A7, B7 | deep-pipeline.md |
| B1, B2, B3 | deep-reliability.md |
| B4, B5, B6 | deep-data-safety.md |
| C1, C2, C4, C5, C7 | deep-maintainability.md |
| D1, D2, D4 | deep-web-surface.md |
| C6, D3 | deep-performance.md |

- 🔴 또는 🟠인 항목의 점검표는 돌린다.
- PROFILE.md의 점검 범위 스위치가 켜진 점검표(결제·수집·필수 표시·접근 권한)는 신호등과 상관없이 돌린다.
- 🟢·—만 있는 영역은 돌리지 않는다(비용과 시간 절약). 무엇을 왜 건너뛰었는지 STATE 메모에 한 줄 남긴다.

## 2. 보조 AI를 동시에 (한 메시지에서 최대 6명, 넘으면 두 번에 나눔)
- `refactor:auditor` — 각자에게: 점검표의 실제 전체 경로, AUDIT_REPORT의 해당 행, PROFILE.md 요약, AUDIT_REPORT의 "셸 검사 결과"(비밀값·git 기록 점검표에는 꼭), "결과 4,000자 이내, 점검표의 출력 형식 그대로".

## 3. 저장·반영
- 각 결과를 확인(🔴는 파일:줄 직접 확인)한 뒤 `docs/refactor/audit/<점검표 이름>.md`로 저장한다.
- AUDIT_REPORT.md의 정밀검사 목록에 결과 파일 경로를 적고, 정밀검사로 신호등이 바뀐 항목은 근거와 함께 반영한다.
- 각 점검표 결과의 "계획서 후보"는 6단계(계획서)의 재료다. 지우지 않는다.

## 4. STATE 갱신 후 자동으로 4단계(반박 검증)로 넘어간다.
