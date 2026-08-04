# -*- coding: utf-8 -*-
# OPCG 효과 상수 검색대 (유저 하달 2026-07-29 "어느 장소에서 어느 장소로
# 이동하나 이런 라벨 다 달아놓은 효과 상수 검색대").
#
# 용도: 세트 저작 전에 효과문 문형으로 기존 부품을 찾는다. 신규 op 자작은
#       여기서 무히트 + opcg_contract.lua op_alias 검토 후에만 허용.
# 사용:
#   python opcg_find_op.py 버리              # 라벨/문형/실사용 효과문 전문 검색
#   python opcg_find_op.py --move 트래시     # 이동 경로로 검색(출발/도착)
#   python opcg_find_op.py --op DRAW         # 단일 op 상세(별칭/선례 포함)
#   python opcg_find_op.py --audit           # 허용목록 대비 라벨 누락 검사(회귀용)
#   python opcg_find_op.py --rebuild         # 코퍼스 사용례 캐시 재수집
import io, os, re, sys, json, argparse

sys.stdout.reconfigure(encoding='utf-8')
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, 'bin', 'release', 'expansions', 'script')
CACHE = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'opcg_op_catalog_cache.json')

# ============================ 손라벨(정본) ============================
# kor: 한 줄 의미 / move: 이동 경로(출발→도착, 이동류만) / tags: 분류
# keys: 한국어 효과문 검색 키워드(원문 문형 조각)
A = {}  # 액션
def a(op, kor, move='', tags='', keys=''):
    A[op] = dict(kor=kor, move=move, tags=tags, keys=keys)

# --- 드로우/패 ---
a('DRAW', '카드를 N장 뽑는다', '덱 위→패', '이동 드로우', '뽑는다 뽑고 드로')
a('TRASH_HAND', '자신/지정의 패를 N장 버린다', '패→트래시', '이동 버리기', '버린다 버리고 버릴 수')
a('DRAW_TO_HAND_COUNT', '패가 N장이 되도록 뽑는다', '덱 위→패', '이동 드로우', '패가 N장이 되도록 뽑')
a('TRASH_HAND_TO_COUNT', '패가 N장이 되도록 버린다', '패→트래시', '이동 버리기', '패가 N장이 되도록 버린')
a('REDRAW_HAND', '패 전부를 덱에 되돌리고 다시 뽑는다', '패→덱→패', '이동 리셋', '패를 전부 덱으로 되돌리고 다시')
a('DRAW_EVENT_COUNT', '트래시의 이벤트 수만큼 뽑는다', '덱 위→패', '이동 드로우 가변', '이벤트 1장당 뽑')
a('DRAW_PER_COUNT', '필터 일치 캐릭터 1장당 N장 뽑는다(+동수 버리기 옵션)', '덱 위→패', '이동 드로우 가변', '1장당 카드를 1장 뽑 뽑은 수만큼')
a('RETURN_HAND_TO_DECK', '패의 카드를 덱 위/아래로 되돌린다(주체 지정 가능)', '패→덱', '이동 되돌리기', '패 N장을 덱 맨 아래에 놓는다 원하는 순서')
a('REVEAL_HAND', '패를 공개한다', '', '정보 공개', '패를 공개')
# --- 덱 조작 ---
a('MILL_DECK', '덱 위에서 N장을 트래시에 놓는다', '덱 위→트래시', '이동 밀', '덱 위에서 N장을 트래시에 놓는')
a('SEARCH_DECK_TOP', '덱 위 N장을 보고 필터 일치 카드를 패 등으로(잔여 덱아래/트래시)', '덱 위→패/트래시/라이프', '이동 서치', '덱 위에서 N장을 보고 공개하고 패에 넣는다 남은 카드를 원하는 순서대로')
a('LOOK_REORDER_DECK_TOP', '덱 위 N장을 보고 원하는 순서로 위/아래에 놓는다', '덱 위→덱 위/아래', '이동 정렬', '보고 원하는 순서대로 덱 맨 위나 아래')
a('LOOK_DECK_TOP', '덱 위 N장을 본다(공개)', '', '정보 공개', '덱 위에서 N장을 본다 확인')
a('REVEAL_DECK_TOP', '덱 위 N장을 공개(+조건 일치 시 on_match 후속)', '', '정보 공개 조건부', '덱 위에서 N장을 공개한다 공개한 카드가')
a('DECLARE_COST_REVEAL', '코스트를 선언하고 덱 위를 공개, 일치 시 후속', '', '정보 공개 조건부', '코스트를 선언 공개한 카드가 선언한')
a('SHUFFLE_DECK', '덱을 섞는다', '', '덱 조작', '덱을 섞는다')
# --- 필드 이탈/이동 ---
a('KO', '캐릭터를 KO한다', '필드→트래시', '이동 제거 KO', 'KO한다')
a('TRASH', '필드/지정 카드를 트래시에 놓는다(KO 아님)', '필드→트래시', '이동 제거', '트래시에 놓는다')
a('RETURN_TO_HAND', '필드의 카드를 주인의 패로 되돌린다', '필드→패', '이동 바운스', '주인의 패로 되돌린다')
a('RETURN_TO_DECK_BOTTOM', '필드의 카드를 주인의 덱 맨 아래에 놓는다', '필드→덱 아래', '이동 바운스', '주인의 덱 맨 아래에 놓는다')
a('RETURN_TRASH_TO_DECK_BOTTOM', '트래시의 카드를 덱 맨 아래로(상대 트래시 지정 가능)', '트래시→덱 아래', '이동 되돌리기', '트래시에서 카드 N장을 원하는 순서대로 덱 맨 아래')
a('RETURN_LIFE_TO_DECK', '라이프를 덱으로 되돌린다', '라이프→덱', '이동 라이프', '라이프를 덱으로')
a('ADD_FROM_TRASH', '트래시의 카드를 패에 넣는다', '트래시→패', '이동 회수', '트래시에서 카드 1장까지를 패에 넣는다')
a('ADD_SELF_TO_HAND', '이 카드를 (트래시 등 현 위치에서) 패에 넣는다', '자기→패', '이동 회수', '이 카드를 패에 넣는다 트래시에서')
# --- 등장 ---
a('PLAY_FROM_HAND', '패에서 캐릭터/스테이지를 등장시킨다', '패→필드', '이동 등장', '패에서 캐릭터 카드 1장까지를 등장시킨다')
a('PLAY_FROM_TRASH', '트래시에서 등장시킨다(LAST_TARGET로 후속 부여 가능)', '트래시→필드', '이동 등장 소생', '트래시에서 캐릭터 카드 1장까지를 등장시킨다')
a('PLAY_FROM_HAND_OR_TRASH', '패나 트래시에서 등장시킨다', '패/트래시→필드', '이동 등장', '패나 트래시에서 등장시킨다')
a('PLAY_FROM_DECK', '덱에서 찾아 등장시킨다', '덱→필드', '이동 등장', '덱에서 등장시킨다')
a('PLAY_FROM_DECK_TOP', '덱 위에서 등장시킨다', '덱 위→필드', '이동 등장', '덱 위에서 등장')
a('PLAY_FROM_LIFE_TOP', '라이프 위에서 등장시킨다', '라이프→필드', '이동 등장', '라이프 위에서 등장')
a('PLAY_SELF', '이 카드를 등장시킨다(트리거/트래시 등 현 위치에서)', '자기→필드', '이동 등장', '이 카드를 등장시킨다')
a('PLAY_DISTINCT_FROM_TRASH', '트래시에서 이름이 다른 카드들을 등장시킨다', '트래시→필드', '이동 등장 소생', '이름이 다른 캐릭터를 등장')
a('PLAY_TWO_FROM_TRASH_SPLIT_STATE', '트래시에서 2장 등장(액티브/레스트 분할)', '트래시→필드', '이동 등장 소생', '2장을 등장 1장은 레스트')
a('PLAY_OWN_CHARACTERS_RESTED', '자신의 캐릭터 등장을 레스트 상태로 강제(제약)', '', '제약 등장', '레스트 상태로 등장')
# --- 라이프 ---
a('ADD_LIFE_FROM_DECK_TOP', '덱 위에서 라이프 맨 위에 놓는다', '덱 위→라이프 위', '이동 라이프 회복', '덱 위에서 1장까지를 라이프 맨 위에')
a('ADD_LIFE_FROM_HAND', '패에서 라이프에 놓는다(faceup 지원)', '패→라이프', '이동 라이프', '패에서 라이프 위에 놓는다 앞면으로')
a('ADD_LIFE_FROM_TRASH', '트래시에서 라이프에 놓는다', '트래시→라이프', '이동 라이프', '트래시에서 라이프에')
a('ADD_LIFE_FROM_HAND_OR_TRASH', '패/트래시에서 라이프에 놓는다', '패/트래시→라이프', '이동 라이프', '패나 트래시에서 라이프')
a('ADD_TO_LIFE', '선택한 카드를 라이프에 놓는다', '선택→라이프', '이동 라이프', '라이프 위에 놓는다')
a('ADD_TO_OWNER_LIFE', '선택한 카드를 주인의 라이프에 놓는다', '선택→라이프', '이동 라이프', '주인의 라이프에')
a('TAKE_LIFE_TO_HAND', '라이프 위/아래에서 패에 넣는다(상대 라이프 지정 가능)', '라이프→패', '이동 라이프 번', '라이프 위에서 1장을 패에 넣는다 위나 아래에서')
a('TRASH_LIFE_TOP', '라이프 위에서 트래시에 놓는다', '라이프→트래시', '이동 라이프 번', '라이프 위에서 1장을 트래시에')
a('TRASH_LIFE_UNTIL', '라이프가 N장이 될 때까지 트래시에 놓는다', '라이프→트래시', '이동 라이프 번', '라이프가 N장이 되도록')
a('TRASH_FACEUP_LIFE_ALL', '앞면 라이프 전부를 트래시에 놓는다', '라이프→트래시', '이동 라이프', '앞면인 라이프를 전부')
a('SET_ALL_LIFE_FACE_DOWN', '라이프 전부를 뒷면으로 한다', '', '라이프 상태', '라이프를 전부 뒷면으로')
a('LOOK_REORDER_LIFE_TOP', '라이프 위 N장을 보고 재배열', '', '라이프 정렬', '라이프 위에서 보고 순서')
a('LOOK_REORDER_ALL_LIFE', '라이프 전부를 보고 재배열', '', '라이프 정렬', '라이프를 전부 보고 순서')
a('REORDER_ALL_LIFE_RETURN_ONE_TO_DECK', '라이프 전부 재배열+1장 덱으로', '라이프→덱', '라이프 정렬', '라이프를 보고 1장을 덱')
a('REVEAL_LIFE_TOP_FOR_POWER', '라이프 위를 공개하고 그 코스트×N만큼 자기 파워 수정', '', '정보 공개 스탯', '라이프 위에서 공개 코스트 1당 파워')
a('REPLACE_LIFE_TO_HAND', '라이프가 패로 가는 것을 대체한다', '', '대체 라이프', '라이프에 더하는 대신')
# --- 스탯 ---
a('MODIFY_POWER', '파워 ±N(기간부)', '', '스탯 파워', '파워 + 파워 -')
a('MODIFY_POWER_PER_COUNT', '개수(트래시/패/캐릭터/레스트둥)÷divisor×N 파워', '', '스탯 파워 가변', 'N장당 파워')
a('MODIFY_POWER_PER_OWN_DON', '대상별 부착 둥 수×N 파워', '', '스탯 파워 가변 둥', '부여된 두웅 1장당 파워')
a('MODIFY_POWER_SPLIT', '합계 N을 나눠서 파워 수정', '', '스탯 파워 분할', '나누어 파워')
a('DISCARD_HAND_FOR_POWER', '패에서 필터 카드 임의 매수 버리고 1장당 파워+N', '패→트래시', '스탯 파워 버리기', '원하는 만큼 버릴 수 있다 버린 카드 1장당 파워')
a('KO_OWN_ANY_FOR_POWER', '자신 카드 임의 매수 KO, 1장당 파워+N', '필드→트래시', '스탯 파워 제물', 'KO하고 1장당 파워')
a('RETURN_TRASH_ANY_FOR_POWER', '트래시 임의 매수 덱아래로, 1장당 파워+N', '트래시→덱 아래', '스탯 파워', '트래시에서 되돌리고 1장당')
a('RETURN_OWN_ANY_FOR_POWER', '자신 캐릭터 임의 매수 회수, 1장당 파워+N', '필드→패', '스탯 파워', '되돌리고 1장당 파워')
a('REST_DON_FOR_POWER', '둥 임의 매수 레스트, 1장당 파워+N', '', '스탯 파워 둥', '두웅을 레스트로 하고 1장당')
a('SET_POWER', '파워를 N으로 한다(최종)', '', '스탯 파워 고정', '파워가 0이 된다 파워를 N으로')
a('SET_BASE_POWER', '원래 파워를 N으로 한다', '', '스탯 파워 고정', '원래 파워를 N으로 원래 파워는 N이 된다')
a('SET_BASE_POWER_FROM_TARGET', '원래 파워를 대상 카드의 파워로 한다', '', '스탯 파워 복사', '와 같은 파워가 된다')
a('SWAP_BASE_POWER', '두 카드의 원래 파워를 맞바꾼다', '', '스탯 파워 교환', '파워를 맞바꾼')
a('MODIFY_COST', '코스트 ±N(기간부/상시)', '', '스탯 코스트', '코스트 + 코스트 -')
a('MODIFY_COST_PER_COUNT', '개수÷divisor×N 코스트', '', '스탯 코스트 가변', 'N장당 코스트')
a('MODIFY_HAND_COST', '패에 있는 동안 코스트 ±N', '', '스탯 코스트 패', '패의 이 카드는 코스트')
a('MODIFY_NEXT_PLAY_COST', '다음 등장 비용 ±N', '', '스탯 코스트', '다음에 등장시키는 비용')
a('SET_COST', '코스트를 N으로 한다', '', '스탯 코스트 고정', '코스트를 N으로')
a('MODIFY_COUNTER', '카운터 수치 ±N', '', '스탯 카운터', '카운터 +')
# --- 상태 ---
a('REST', '카드를 레스트로 한다', '', '상태 레스트', '레스트로 한다')
a('SET_ACTIVE', '카드를 액티브로 한다', '', '상태 액티브', '액티브로 한다')
a('REST_CARD_OR_DON', '카드(리더/캐릭터) 또는 두웅을 레스트로 한다', '', '상태 레스트 둥', '카드나 두웅 카드 1장까지를 레스트')
a('SET_ACTIVE_CARD_OR_DON', '카드 또는 두웅을 액티브로 한다', '', '상태 액티브 둥', '카드나 두웅을 액티브')
a('REST_DON', '자신의 둥 N장을 레스트로 한다', '', '상태 둥', '두웅 N장을 레스트로')
a('SET_DON_ACTIVE', '자신의 둥 N장을 액티브로 한다(schedule 지원)', '', '상태 둥', '두웅을 액티브로 한다')
# --- 둥!! ---
a('ADD_DON', '둥 덱에서 코스트 에리어로 추가(액티브/레스트)', '둥 덱→코스트 에리어', '둥 추가', '두웅 덱에서 두웅 N장까지를 추가')
a('RETURN_DON', '필드의 둥을 둥 덱으로 되돌린다(둥-N)', '필드→둥 덱', '둥 반환', '두웅-N 두웅 덱에 되돌')
a('GIVE_DON', '코스트 에리어의 둥을 리더/캐릭터에 부여(source=OWNER 지원)', '코스트 에리어→부착', '둥 부여', '레스트 상태인 두웅 1장까지를 붙인다 부여')
a('GIVE_OPPONENT_DON', '상대의 둥을 상대 캐릭터에 부여', '상대 코스트 에리어→상대 부착', '둥 부여 디버프', '상대의 레스트 상태인 두웅을 붙인다')
a('TRANSFER_ATTACHED_DON', '부착 둥을 다른 카드로 옮긴다', '부착→부착', '둥 이동', '두웅을 옮긴다')
a('RETURN_DON_TO_MATCH_OPPONENT', '상대와 같아질 때까지 둥 반환', '필드→둥 덱', '둥 반환', '상대와 같은 수가 되도록')
a('DON_PHASE_ATTACH_TO_LEADER', '둥 페이즈 배치 둥을 리더에 부여로 대체', '', '둥 룰', '두웅 페이즈에 리더에')
a('DON_DECK_SIZE', '룰: 둥 덱 크기를 N으로(에넬)', '', '둥 룰', '두웅 덱은 N장')
a('OPPONENT_MAY_RETURN_ACTIVE_DON_OR', '상대가 액티브 둥 반환 안 하면 otherwise 실행', '', '둥 선택강요', '되돌려도 된다 되돌리지 않은 경우')
# --- 키워드/이름/속성 ---
a('GAIN_KEYWORD', '키워드 부여(블로커/속공/더블어택/배니시/언블로커블)', '', '키워드', '블로커를 얻는다 속공을 얻는다 더블 어택')
a('GAIN_ATTRIBUTE', '속성 부여(참/타/사/특/지)', '', '키워드 속성', '속성 을 얻는다')
a('ADD_NAME_ALIAS', '카드명을 추가로 취급(룰)', '', '이름 룰', '카드명을 로도 취급')
# --- 제약/허가 ---
a('CANNOT_ATTACK', '어택할 수 없다', '', '제약 어택', '어택할 수 없다')
a('CANNOT_ATTACK_LEADER', '리더에게 어택할 수 없다', '', '제약 어택', '리더에게 어택할 수 없')
a('CANNOT_ATTACK_TARGETS', '특정 대상에게 어택 불가(공격자 셀렉터)', '', '제약 어택', '에게 어택할 수 없')
a('ALLOW_ATTACK_CHARACTER', '등장 턴에도 캐릭터에게 어택 가능(속공:캐릭터)', '', '허가 어택', '등장한 턴에 캐릭터에게 어택')
a('ALLOW_ATTACK_ACTIVE_CHARACTER', '액티브 캐릭터에게도 어택 가능', '', '허가 어택', '액티브 상태인 캐릭터에게도 어택')
a('CANNOT_BE_KO', 'KO되지 않는다(사유/횟수 한정 지원)', '', '제약 보호', 'KO되지 않는다')
a('CANNOT_BE_RESTED', '레스트되지 않는다(전면형은 어택도 불가 동반)', '', '제약 보호', '레스트로 할 수 없다 레스트가 되지 않는')
a('CANNOT_SET_ACTIVE', '리프레시에 액티브가 되지 않는다(schedule 지원)', '', '제약 액티브', '리프레시 페이즈에 액티브가 되지 않는다')
a('CANNOT_SET_ACTIVE_CARD_OR_DON', '카드/둥이 액티브가 되지 않는다', '', '제약 액티브 둥', '캐릭터 또는 두웅 액티브 되지 않는')
a('CANNOT_SET_DON_ACTIVE', '둥을 액티브로 할 수 없다(source=CHARACTER_EFFECT 한정 지원)', '', '제약 둥', '두웅을 액티브로 할 수 없')
a('CANNOT_LEAVE_FIELD', '필드를 벗어나지 않는다(사유 한정)', '', '제약 보호', '필드를 벗어나지 않는다')
a('CANNOT_PLAY', '등장시킬 수 없다', '', '제약 등장', '등장시킬 수 없다')
a('CANNOT_DRAW', '드로우할 수 없다', '', '제약 드로우', '뽑을 수 없다')
a('CANNOT_TAKE_LIFE_TO_HAND', '라이프를 패에 넣을 수 없다', '', '제약 라이프', '라이프를 패에 더할 수 없')
a('PREVENT_BLOCKER_ACTIVATION', '블로커 발동 불가', '', '제약 블로커', '블로커를 발동할 수 없')
a('NEGATE_EFFECTS', '효과를 무효로 한다(상주)', '', '무효', '효과를 무효')
a('NEGATE_TIMING_EFFECTS', '특정 타이밍 효과를 무효로 한다', '', '무효', '등장 시 효과를 무효')
a('REQUIRE_HAND_DISCARD_TO_ATTACK', '어택하려면 패를 버려야 한다', '', '제약 어택 세금', '어택할 때 패를 버리지 않으면')
# --- 대체 ---
a('REPLACE_KO', 'KO를 대체 비용/액션으로 무른다(사유: ANY/BATTLE/OPPONENT_EFFECT 등)', '', '대체 보호', 'KO될 경우 대신')
a('REPLACE_LEAVE_FIELD', '필드 이탈을 대체한다(reason=OPPONENT_ANY는 상대 배틀KO 포함)', '', '대체 보호', '필드를 벗어날 경우 대신')
a('REPLACE_REST', '레스트를 대체한다', '', '대체', '레스트가 되는 대신')
# --- 특수/제어 ---
a('WIN_GAME', '게임에서 승리한다(replacement_for=DECK_OUT 지원)', '', '특수 승리', '승리한다')
a('GAIN_EXTRA_TURN', '추가 턴을 얻는다', '', '특수', '추가 턴')
a('CHANGE_ATTACK_TARGET', '어택 대상을 변경한다', '', '특수 배틀', '어택 대상을 변경')
a('DEAL_DAMAGE', '리더에게 대미지(라이프 타격)', '라이프→패/트리거', '특수 대미지', '대미지를 준다')
a('ACTIVATE_CARD_EFFECT', '카드의 기재 효과를 발동(자기 재발동/패·트래시 소스)', '', '특수 발동', '효과를 발동한다 패에서 발동')
a('CHOOSE', '이하에서 1개를 고른다(라벨=cdb str9+)', '', '제어 선택', '이하에서 1개를 고른다')
a('OPPONENT_CHOOSES', '상대가 선택지를 고른다', '', '제어 선택', '상대는 이하에서')
a('IF', '직전 결과/조건부 후속(그렇게 했다면·~인 경우)', '', '제어 조건', '그 후 인 경우 했다면')
a('DECK_BUILD_RESTRICTION', '덱 구축 제한(룰)', '', '룰 덱', '덱에 넣을 수 있다 만')
a('ALLOW_UNLIMITED_DECK_COPIES', '동명 매수 제한 해제(룰)', '', '룰 덱', '몇 장이든 넣을 수')
a('DEFER_DECKOUT_TO_TURN_END', '덱 0장 패배를 턴 종료까지 유예(브룩)', '', '룰 덱아웃', '덱이 0장이어도 패배하지 않')
a('REVEAL_PLAY_SPLIT_FROM_HAND', '패에서 복수 공개 후 일부 등장/일부 잔류 분할 처리', '패→필드', '이동 등장 공개', '공개하고 그중 등장')
a('NATIVE_EFFECT', '예비 함수(Fable 5 전용·유저 의도 미해석 시만): 네이티브 효과 코드 직결. code="EFFECT_*"/"opcg.EFFECT_*"/숫자, 표준 duration. 구현이 까다로운 정도면 이것 말고 생짜 EDOPro lua 병기가 우선(오퍼스는 양쪽 다 금지)', '', '예비 네이티브 최후수단', '유희왕 예비 우겨')

C = {}  # 코스트
def c(op, kor, move='', keys=''):
    C[op] = dict(kor=kor, move=move, tags='코스트', keys=keys)
c('TRASH_HAND', '패 N장을 버린다', '패→트래시', '버리고 버릴 수 있다:')
c('REST_DON', '둥 N장을 레스트로', '', '두웅 N장을 레스트로 하고')
c('RETURN_DON', '둥 N장을 둥 덱으로(둥-N)', '필드→둥 덱', '두웅-N:')
c('REST_SELF', '이 카드를 레스트로', '', '이 카드를 레스트로 하고')
c('TRASH_SELF', '이 카드를 트래시에', '필드→트래시', '이 캐릭터를 트래시에 놓고')
c('RETURN_SELF_TO_HAND', '이 카드를 패로', '필드→패', '이 카드를 패로 되돌리고')
c('RETURN_SELF_TO_DECK_BOTTOM', '이 카드를 덱 아래로', '필드→덱 아래', '이 카드를 덱 맨 아래로')
c('REST_OWN_CARD', '자신의 카드 N장을 레스트로(kinds 무지정=리더/캐릭터/스테이지/액티브 둥 전부)', '', '자신의 카드 N장을 레스트로 할 수')
c('TRASH_OWN_CARD', '자신의 카드를 트래시에', '필드→트래시', '자신의 캐릭터 1장을 트래시에 놓고')
c('KO_OWN_CARD', '자신의 카드를 KO', '필드→트래시', '자신의 캐릭터를 KO하고')
c('RETURN_OWN_CARD_TO_HAND', '자신의 카드를 주인의 패로', '필드→패', '캐릭터 1장을 주인의 패로 되돌릴 수')
c('RETURN_OWN_CARD_TO_DECK_BOTTOM', '자신의 카드를 덱 아래로', '필드→덱 아래', '캐릭터 1장을 덱 맨 아래에 놓을 수')
c('MILL_DECK', '덱 위 N장을 트래시에', '덱 위→트래시', '덱 위에서 N장을 트래시에 놓을 수')
c('TRASH_LIFE_TOP', '라이프 위를 트래시에', '라이프→트래시', '라이프 위에서 1장을 트래시에')
c('TAKE_LIFE_TO_HAND', '라이프를 패에(위/아래)', '라이프→패', '라이프 위에서 1장을 패에 넣고')
c('FLIP_LIFE_TOP', '라이프 위를 앞면/뒷면으로(faceup)', '', '라이프 위에서 1장을 앞면으로 뒷면으로')
c('RETURN_TRASH_TO_DECK_BOTTOM', '트래시 N장을 덱 아래로', '트래시→덱 아래', '트래시에서 카드 N장을 덱 맨 아래')
c('RETURN_HAND_TO_DECK', '패를 덱으로', '패→덱', '패 N장을 덱으로')
c('RETURN_ATTACHED_DON', '부착 둥을 코스트 에리어로', '부착→코스트 에리어', '부여된 두웅을 되돌리')
c('GIVE_DON', '둥을 부여(액티브/레스트 지정)', '코스트 에리어→부착', '두웅 1장을 부여할 수 있다:')
c('GIVE_OPPONENT_DON', '상대 둥을 상대 캐릭터에 부여', '상대 코스트 에리어→상대 부착', '상대의 레스트 상태인 두웅 1장을 부여할 수')
c('MODIFY_OWN_POWER', '자신 카드 파워를 ±N(액티브 리더 -5000류)', '', '리더를 이번 턴 동안 파워 - 할 수 있다:')
c('ADD_OWN_CARD_TO_LIFE', '자신의 카드를 라이프에', '선택→라이프', '라이프 위에 놓고')
c('ADD_OPPONENT_CARD_TO_LIFE', '상대 카드를 라이프에', '선택→라이프', '상대의 카드를 라이프')
c('REVEAL_HAND', '패를 공개', '', '패를 공개하고')
c('PLAY_FROM_HAND', '패에서 등장(비용으로)', '패→필드', '등장시키고')
c('TRASH_CHARACTER_OR_HAND', '캐릭터 또는 패를 트래시에', '필드/패→트래시', '캐릭터나 패')
c('TRASH_FIELD_OR_HAND', '필드 카드 또는 패를 트래시에', '필드/패→트래시', '필드의 카드나 패')
c('ALTERNATIVE_COST', '복수 비용 중 택일', '', '또는 로 지불')

# 조건(이름 자기설명형 — 짧은 라벨 + 문형 키)
K = {}
def k(op, kor, keys=''):
    K[op] = dict(kor=kor, tags='조건', keys=keys)
k('LIFE_LTE', '자신 라이프 N 이하', '라이프가 N장 이하')
k('LIFE_GTE', '자신 라이프 N 이상', '라이프가 N장 이상')
k('LIFE_EQ', '자신 라이프 N', '라이프가 0장인')
k('LIFE_LT_OPPONENT', '라이프가 상대보다 적다', '라이프 매수가 상대보다 적은')
k('LIFE_LTE_OPPONENT', '라이프가 상대 이하', '라이프 매수가 상대 이하')
k('LIFE_TOTAL_LTE', '서로 라이프 합계 N 이하', '라이프 합계가 N장 이하')
k('LIFE_TOTAL_GTE', '서로 라이프 합계 N 이상', '합계 N장 이상')
k('ANY_LIFE_EQ', '어느 한쪽 라이프가 N', '어느 한쪽의 라이프')
k('LIFE_HAND_TOTAL_LTE', '라이프+패 합계 N 이하', '라이프와 패의 합계')
k('HAND_LTE', '패 N장 이하', '패가 N장 이하')
k('HAND_GTE', '패 N장 이상(상대 지정 가능)', '패가 N장 이상')
k('HAND_BEHIND_BY_GTE', '패가 상대보다 N장 이상 적다', '패가 상대보다 적')
k('DECK_LTE', '덱 N장 이하', '덱이 N장 이하')
k('DECK_GTE', '덱 N장 이상', '덱이 N장 이상')
k('DECK_EQ', '덱 N장(0=덱 소진)', '덱이 0장인')
k('TRASH_GTE', '트래시 N장 이상(filter 지원)', '트래시가 N장 이상 트래시에 이벤트가')
k('LEADER_HAS_TRAIT', '리더가 특징 보유', '리더가 특징을 가진')
k('LEADER_HAS_TRAIT_ANY', '리더가 특징 중 하나 보유', '이나 특징을 가진')
k('LEADER_TRAIT_CONTAINS', '리더 특징에 문자열 포함(海軍/CP류)', '을 포함한 특징')
k('LEADER_NAME_IS', '리더 이름 일치', '리더가 「」인 경우')
k('LEADER_NAME_IS_ANY', '리더 이름이 목록 중 하나', '리더가 「」나 「」인')
k('LEADER_IS_MULTICOLOR', '리더가 다색', '리더가 2색')
k('LEADER_HAS_ATTRIBUTE', '리더 속성 일치', '속성을 가진 리더')
k('LEADER_HAS_COLOR', '리더 색 일치', '색 리더')
k('LEADER_STATE_IS', '리더 상태(액티브/레스트)', '리더가 레스트')
k('LEADER_POWER_LTE', '리더 파워 N 이하', '리더가 파워 0 이하')
k('LEADER_POWER_GTE', '리더 파워 N 이상', '리더가 파워 이상')
k('CHARACTER_EXISTS', '필터 일치 캐릭터 존재(이름/파워 등)', '가 있는 경우')
k('CHARACTER_NAME_ABSENT', '이름 캐릭터 부재', '가 없는 경우')
k('OTHER_CHARACTER_NAME_ABSENT', '자기 외 동명 부재(킹/오즈)', '다른 「」가 없는')
k('CHARACTER_COUNT_GTE', '필터 캐릭터 N장 이상(player=ANY 무주어)', '캐릭터가 N장 이상 있는')
k('CHARACTER_COUNT_LTE', '캐릭터 N장 이하', '캐릭터가 N장 이하')
k('CHARACTER_COUNT_LT', '캐릭터 N장 미만(부재 조건에 count=1)', '있지 않은 경우 없는 경우')
k('CHARACTER_COUNT_BEHIND_BY_GTE', '내 캐릭터가 상대보다 N 이상 적다', '캐릭터가 상대보다 적은')
k('ONLY_CHARACTERS_MATCH', '자신 캐릭터가 전부 필터 일치', '캐릭터뿐인')
k('ALL_OWN_CHARACTERS_HAVE_TRAIT', '자신 캐릭터 전원이 특징 보유(0장=성립)', '특징을 가진 캐릭터뿐인')
k('OPPONENT_GIVEN_DON_EXISTS', '상대에게 부여 둥 존재', '상대의 부여된 두웅이 있는')
k('YOUR_TURN', '자신의 턴', '자신의 턴 동안')
k('OPPONENT_TURN', '상대의 턴', '상대의 턴 동안')
k('OPPONENT_LIFE_LEFT_THIS_TURN', '이번 턴 상대 라이프가 벗어남(P-120)', '상대의 라이프가 벗어난 턴')
k('PERSONAL_TURN_GTE', '자신의 제N턴 이후(에넬)', '제2턴 이후')
k('SELF_PLAYED_THIS_TURN', '이 카드가 등장한 턴', '등장한 턴인 경우')
k('SELF_STATE_IS', '자기 상태(액티브/레스트)', '이 캐릭터가 레스트')
k('SELF_POWER_GTE', '자기 파워 N 이상', '이 캐릭터의 파워가 이상')
k('SELF_BATTLED_OPPONENT_CHARACTER_THIS_TURN', '이번 턴 상대 캐릭터와 배틀함', '배틀한 경우')
k('FIELD_DON_GTE', '자신 필드 둥 N 이상', '두웅이 N장 이상')
k('FIELD_DON_LTE', '자신 필드 둥 N 이하(에넬 축)', '두웅이 N장 이하')
k('FIELD_DON_EQ', '자신 필드 둥 N', '두웅이 N장인')
k('ANY_FIELD_DON_EQ', '어느 쪽이든 필드 둥 N', '')
k('FIELD_DON_EQ_OR_GTE', '둥 N 또는 이상', '')
k('FIELD_DON_LTE_OPPONENT', '내 둥이 상대 이하', '두웅이 상대 이하')
k('FIELD_DON_LT_OPPONENT', '내 둥이 상대 미만', '두웅이 상대보다 적')
k('FIELD_DON_BEHIND_BY_GTE', '내 둥이 상대보다 N 이상 적다', '두웅이 N장 이상 적')
k('ACTIVE_DON_GTE', '액티브 둥 N 이상', '액티브 두웅이')
k('ACTIVE_DON_LTE', '액티브 둥 N 이하', '')
k('RESTED_DON_GTE', '레스트 둥 N 이상', '레스트 두웅이')
k('ALL_DON_RESTED', '둥 전부 레스트', '두웅이 전부 레스트')
k('ATTACHED_DON_GTE', '자기 부착 둥 N 이상(둥×N 표기)', '두웅 N장 이상 부여')
k('RESTED_CARD_COUNT_GTE', '레스트 카드 N 이상', '레스트 상태인 카드가')
k('OPPONENT_RESTED_CARD_COUNT_GTE', '상대 레스트 카드 N 이상', '상대의 레스트가')
k('FACEUP_LIFE_EXISTS', '앞면 라이프 존재', '앞면인 라이프가')
k('EVENT_COUNT_GTE', '이벤트 수 N 이상', '이벤트가 N장 이상')
k('EVENT_ACTIVATED_THIS_TURN', '이번 턴 이벤트 발동함(cost_gte)', '이벤트를 발동했을 경우')
k('LIFE_TRIGGER_ACTIVATED', '이번 턴 트리거 발동됨', '트리거가 발동')
k('EVENT_CAUSED_BY_OWN_EFFECT', '(이벤트 문맥) 자기 효과가 원인', '')
k('EVENT_SOURCE_TRAIT_CONTAINS', '(이벤트 문맥) 발생원 특징', '')
k('EVENT_TARGET_BASE_COST_LTE', '(이벤트 문맥) 대상 원래 코스트 이하', '')
k('EVENT_TARGET_BASE_COST_GTE_OR_EFFECT_PLAY', '(이벤트 문맥) 대상 코스트 이상/효과 등장', '')
k('EVENT_TARGET_BASE_POWER_GTE', '(이벤트 문맥) 대상 원래 파워 이상', '')
k('EVENT_DAMAGE_OR_TARGET_BASE_POWER_GTE', '(이벤트 문맥) 대미지 또는 파워 이상', '')
k('EVENT_TARGET_HAS_ATTRIBUTE', '(이벤트 문맥) 대상 속성', '')
k('EVENT_TARGET_TRAIT_CONTAINS', '(이벤트 문맥) 대상 특징', '')
k('BATTLE_ATTACKER_HAS_ATTRIBUTE', '(배틀 문맥) 공격자 속성', '속성 의 어택')
k('LAST_TARGET_MATCHES', '직전 대상이 필터 일치', '')
k('LAST_ACTION_SUCCEEDED', '직전 액션 성공(했다면)', '그렇게 했다면 버렸다면 등장시켰을 경우')
k('SOURCE_EFFECT_DRAW_UNUSED_THIS_TURN', '이번 턴 이 효과 드로 미사용', '')
k('OWN_CHARACTERS_COST_SUM_GTE', '자신 캐릭터 코스트 합계 N 이상', '코스트 합계가')
k('TRASH_CONTAINS_NAMES', '트래시에 지정 이름들 존재', '트래시에 「」가 있는')
k('LEADER_OR_CHARACTER_EXISTS', '필터 일치 리더/캐릭터 존재', '리더나 캐릭터가 있는 경우')

HAND = {'action': A, 'cost': C, 'condition': K}

# ============================ 코퍼스 캐시 ============================
def read_allowlists():
    t = io.open(os.path.join(SCRIPT, 'opcg_contract.lua'), encoding='utf-8').read()
    out = {}
    for kind, var in [('action', 'known_action'), ('cost', 'known_cost'), ('condition', 'known_condition')]:
        i = t.find('local %s = {' % var)
        j = t.find('\n}', i)
        out[kind] = sorted(set(re.findall(r'([A-Z][A-Z0-9_]+)=true', t[i:j])))
    m = re.search(r'local op_alias = \{(.*?)\n\}', t, re.S)
    aliases = dict(re.findall(r'([A-Z][A-Z0-9_]+)\s*=\s*"([A-Z0-9_]+)"', m.group(1))) if m else {}
    return out, aliases

def build_cache():
    usage = {}
    for fn in sorted(os.listdir(SCRIPT)):
        if not (fn.startswith('c88') and fn.endswith('.lua')):
            continue
        t = io.open(os.path.join(SCRIPT, fn), encoding='utf-8').read()
        for m in re.finditer(r'op=\[\[([A-Z0-9_]+)\]\]', t):
            op = m.group(1)
            u = usage.setdefault(op, {'count': 0, 'cards': [], 'texts': []})
            u['count'] += 1
            if len(u['cards']) < 3 and fn not in u['cards']:
                u['cards'].append(fn)
                s = re.search(r'source_text=\[\[([^\]]+)\]\]', t[m.start():m.start() + 2500])
                if s:
                    txt = s.group(1)[:110]
                    if txt not in u['texts']:
                        u['texts'].append(txt)
    json.dump(usage, io.open(CACHE, 'w', encoding='utf-8'), ensure_ascii=False, indent=0)
    return usage

def load_cache():
    if not os.path.exists(CACHE):
        return build_cache()
    return json.load(io.open(CACHE, encoding='utf-8'))

# ============================ 검색/감사 ============================
def entry_blob(kind, op, lab, usage):
    u = usage.get(op, {})
    return ' '.join([op, lab.get('kor', ''), lab.get('move', ''), lab.get('tags', ''),
                     lab.get('keys', '')] + u.get('texts', []))

def show(kind, op, lab, usage, aliases):
    u = usage.get(op, {'count': 0, 'cards': [], 'texts': []})
    als = sorted(a0 for a0, canon in aliases.items() if canon == op)
    print('■ %s [%s]  사용 %d회%s' % (op, kind, u['count'],
          ('  별칭: ' + '/'.join(als)) if als else ''))
    if lab.get('kor'):
        print('   뜻: %s' % lab['kor'])
    if lab.get('move'):
        print('   이동: %s' % lab['move'])
    if lab.get('tags'):
        print('   분류: %s' % lab['tags'])
    for i, tx in enumerate(u.get('texts', [])[:2]):
        print('   선례%d(%s): %s' % (i + 1, u['cards'][i] if i < len(u['cards']) else '?', tx))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('query', nargs='*')
    ap.add_argument('--move')
    ap.add_argument('--op')
    ap.add_argument('--audit', action='store_true')
    ap.add_argument('--rebuild', action='store_true')
    args = ap.parse_args()

    lists, aliases = read_allowlists()
    usage = build_cache() if args.rebuild else load_cache()

    if args.audit:
        missing = []
        for kind in ('action', 'cost', 'condition'):
            for op in lists[kind]:
                if op not in HAND[kind]:
                    missing.append((kind, op))
        for kind, op in missing:
            print('LABEL MISSING: %s %s' % (kind, op))
        print('audit: 허용목록 %d종 중 라벨 누락 %d' % (sum(len(v) for v in lists.values()), len(missing)))
        sys.exit(1 if missing else 0)

    if args.op:
        op = aliases.get(args.op, args.op)
        found = False
        for kind in ('action', 'cost', 'condition'):
            if op in lists[kind]:
                show(kind, op, HAND[kind].get(op, {}), usage, aliases)
                found = True
        if not found:
            print('미등록 op:', args.op)
        return

    needles = args.query
    hits = []
    for kind in ('action', 'cost', 'condition'):
        for op in lists[kind]:
            lab = HAND[kind].get(op, {})
            blob = entry_blob(kind, op, lab, usage)
            if args.move and args.move not in lab.get('move', ''):
                continue
            if needles and not all(n in blob for n in needles):
                continue
            if args.move or needles:
                hits.append((kind, op, lab))
    if not (needles or args.move):
        print('사용법: 키워드(들) / --move 장소 / --op 이름 / --audit / --rebuild')
        return
    if not hits:
        print('무히트 — 신규 op를 자작하기 전에 유의어(버리/폐기/보내 등)로 재검색하고,')
        print('그래도 없으면 opcg_contract.lua op_alias 별칭 등록을 먼저 검토할 것.')
        print('[모델 게이트] Fable 5: 생짜 EDOPro lua 병기 우선, NATIVE_EFFECT는 의도')
        print('미해석 시만. 오퍼스: 여기서 멈추고 해당 카드를 보류 목록으로 이관.')
        return
    for kind, op, lab in hits:
        show(kind, op, lab, usage, aliases)
        print()

if __name__ == '__main__':
    main()
