# 하네스 기준선 (2026-07-13 새벽, 배틀 복원판 — lua만, 코어=1240복원판 dll)

`powershell -File tools\opcg_tests\run_all.ps1` — 결정적(2회 동일), ~39s.

## GREEN NET (9) — 이게 회귀 감시망. 하나라도 빨개지면 그건 그 변경 탓.

opcg_charlia_search / opcg_flip_life_headless / opcg_fullfield_push /
opcg_koshiro / opcg_life_reorder / opcg_roger_don_cap /
opcg_scripted_rps / opcg_stage_rest / **opcg_onko_draw (신규 합류)**

- **onko_draw 합류 경위 (07-13)**: 배틀 복원 후 PASS. 단 어제의 RED는 큐
  결함이 아니라 **하네스 조기탈출 아티팩트**였음 — KO MOVE를 보자마자 응답
  대기 중(status=1)인 [KO시] 발동 프롬프트를 안 받고 루프를 끊어 드로우가
  영영 안 보였던 것. KO 후 유예 구간(+80 스텝) + 자기효과 desc YES 응답을
  하네스에 추가해 교정. "하네스 어서션 함정" 사례 2호(1호: 순서 미검증).
  onko는 이제 블로커 프롬프트(NO)·카운터 프롬프트(NO)·KO 트래시·[KO시]
  드로우 해결까지 배틀 파이프라인 전 구간을 관통 검증한다.

## 무센티넬 "?" (2) — PASS/FAIL 문자열만 없을 뿐 실질 그린

- **opcg_runtime_log_repro**: 2556장 전 카드 로드, `errors=0 callback_failures=0`.
  = 사실상 "전 카드 로드 스모크"(스펙 §2-5 소원 이미 존재). 그린.
  ⚠ 단독 실행 시 `-Repo` 필수(누락하면 파라미터 프롬프트에 영원 대기).
- **opcg_don_negate**: `attack_negated=7000 status_disabled=true` = DON +2000이
  호스트 무효화를 뚫고 생존(OP09-097 CANNOT_DISABLE 설계대로). 정상.

## KNOWN RED (4) — 구 어택 경로 전제의 낡은 시나리오, 재캘리브레이션 대기

opcg_damage_ko / opcg_damage_trigger / opcg_midattack_law / opcg_midattack_play

- 전부 배틀 복원 **이전부터** 같은 이유로 FAIL(회귀 아님): 구 desc-1157
  기동 어택을 전제한 드라이버라 새 선언 경로(idle t=9 attackable 블록,
  onko가 쓰는 방식)를 모름. onko 하네스의 t=9 드라이버 + KO 유예 패턴을
  이식하면 살아날 후보들.
- 이식 시 주의: (1) 13/12 응답 정책 — 블로커/카운터(879999999 스트링)는 NO,
  검증 대상 카드 자기효과는 YES (2) KO/트리거 직후 조기탈출 금지.

## 규약
- 러너 판정 = 하네스 최종 센티넬 줄(`<NAME> PASS|FAIL`)만 신뢰. 윈도우 join
  스트레이 매칭 금지(초판 실수: damage_trigger를 PASS로 오독).
- forge류(리플레이 합성기)는 검증 대상 아니라 러너에서 제외.
- 하네스 .ps1은 ANSI(CP949) — **한글 주석 금지**(UTF-8 한글이 개행을 먹어
  코드가 주석에 흡수되는 컴파일 참사, 07-13 실증). 주석은 ASCII로.
