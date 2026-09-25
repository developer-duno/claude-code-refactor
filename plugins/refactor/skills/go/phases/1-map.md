# 1단계: 코드 지도 (MAP)

목표: 처음 보는 사람이 5분 만에 전체 그림을 잡는 지도를 `docs/refactor/PROJECT_MAP.md`에 만든다. 뒤의 모든 단계가 이 지도를 입력으로 쓴다.

## 방법
- 파일이 100개 미만이면 네가 직접 한다. 그보다 크면 `refactor:auditor` 1명에게 맡긴다.
  - 보조 AI에게 줄 것: 점검표 `${CLAUDE_SKILL_DIR}/checklists/map.md` 전체 경로, PROFILE.md 요약, "결과 6,000자 이내".
- 결과를 받으면 비밀값이 섞이지 않았는지 확인하고 `docs/refactor/PROJECT_MAP.md`로 저장한다.
- 기존 문서(README·설계 문서·AI 규칙 파일)는 정답으로 믿지 않는다. 코드로 먼저 그린 뒤 다른 점만 "문서와 다른 점"에 적는다.

## STATE 갱신 후 자동으로 2단계(건강검진)로 넘어간다.
