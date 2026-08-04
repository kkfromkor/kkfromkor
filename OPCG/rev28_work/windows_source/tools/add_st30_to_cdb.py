#!/usr/bin/env python3
"""ST-30 (스타트 덱 EX 루피 & 에이스) 17장을 cards-opcg.cdb에 추가.

- id: 880002541..880002557 (기본 카드만, 얼트 프린트는 이후 이미지와 함께)
- 인코딩 규칙 (기존 DB에서 역산, ST29 방식 그대로):
    type: 리더/캐릭터 33, 이벤트 65538
    race: 리더 1, 캐릭터 2, 이벤트 3
    attribute: 색 비트 (RED=1 GREEN=2 BLUE=4 PURPLE=8 BLACK=16 YELLOW=32)
    atk=파워, def=카운터 (없음 = -2), level=코스트(리더는 라이프)
    setcode: 특징 코드를 카드 표기 순서대로 16비트씩 LE 팩킹
- 실행 전 cdb_backups/ 아래에 백업을 만든다. 이미 ST30이 있으면 중단.

사용법: python3 tools/add_st30_to_cdb.py
"""

from __future__ import annotations

import datetime as _dt
import shutil
import sqlite3
from pathlib import Path

HERE = Path(__file__).resolve().parent
SRC_ROOT = HERE.parent
CDB = SRC_ROOT / "bin" / "release" / "expansions" / "cards-opcg.cdb"
BACKUP_DIR = SRC_ROOT / "cdb_backups"

T = {  # 특징 코드 (기존 DB 역산값)
    "임펠 다운": 112, "흰 수염 해적단": 169, "밀짚모자 일당": 40,
    "혁명군": 162, "사황": 62, "어인족": 92, "태양 해적단": 139,
    "거인족": 16, "흰 수염 해적단 산하": 170, "전 바로크 워크스": 122,
    "버기 해적단": 51,
}

RED, GREEN = 1, 2
LEADER, CHARACTER, EVENT = (33, 1), (33, 2), (65538, 3)  # (type, race)
NO = -2  # 파워/카운터 "-"


def setcode(*traits: str) -> int:
    value = 0
    for i, name in enumerate(traits):
        value |= T[name] << (16 * i)
    return value


# (번호, 이름, (type,race), attr색, atk, def, level, setcode, 효과본문[없으면 빈문자])
CARDS = [
    ("ST30-001", "루피 & 에이스", LEADER, RED | GREEN, 6000, NO, 4,
     setcode("임펠 다운", "흰 수염 해적단", "밀짚모자 일당"),
     "자신의 원래 파워 7000 이상인 캐릭터가 있을 경우, 이 리더의 파워 -2000.\n"
     "【상대의 턴 동안】 자신의 「포트거스 D. 에이스」와 「몽키 D. 루피」 전부는 파워 +3000."),

    ("ST30-002", "이나즈마", CHARACTER, RED, 2000, 1000, 1,
     setcode("임펠 다운", "혁명군"),
     "【등장 시】 자신의 덱 위에서 5장을 보고, 파워 6000인 캐릭터 카드 1장까지를 공개하고 패에 넣는다. "
     "그 후, 남은 카드를 원하는 순서대로 덱 맨 아래에 놓는다."),

    ("ST30-003", "에드워드 뉴게이트", CHARACTER, RED, 6000, 1000, 8,
     setcode("사황", "흰 수염 해적단"),
     "【자신의 턴 동안】 자신의 원래 파워 6000인 캐릭터 전부는 파워 +1000."),

    ("ST30-004", "엠포리오 이반코프", CHARACTER, RED, 2000, 1000, 1,
     setcode("임펠 다운", "혁명군"),
     "【등장 시】 자신의 패에서 파워 6000인 캐릭터 카드 2장을 공개할 수 있다: "
     "카드를 3장 뽑고, 자신의 패 2장을 버린다."),

    ("ST30-005", "조즈", CHARACTER, RED, 6000, 2000, 5,
     setcode("흰 수염 해적단"), ""),

    ("ST30-006", "징베", CHARACTER, RED, 6000, 1000, 5,
     setcode("어인족", "임펠 다운", "태양 해적단"),
     "【등장 시】 자신의 패에서 파워 6000인 캐릭터 카드 1장을 버릴 수 있다: 카드를 2장 뽑는다."),

    ("ST30-007", "포트거스 D. 에이스", CHARACTER, RED, 6000, NO, 4,
     setcode("흰 수염 해적단"),
     "【등장 시】 자신의 두웅!! 1장을 레스트로 할 수 있다: 이 캐릭터는 이번 턴 동안 【속공】을 얻는다."
     "(이 카드는 등장한 턴에 어택할 수 있다)\n"
     "【어택 시】 상대 캐릭터 1장까지는 이번 턴 동안 파워 -1000."),

    ("ST30-008", "마르코", CHARACTER, RED, 6000, 1000, 5,
     setcode("흰 수염 해적단"),
     "【블로커】(상대의 어택 후, 이 카드를 레스트로 하여 어택 대상을 이 카드로 변경할 수 있다.)\n"
     "【KO 시】 자신의 패에서 파워 6000인 캐릭터 카드 1장을 버릴 수 있다: "
     "이 캐릭터 카드를 트래시에서 레스트 상태로 등장시킨다."),

    ("ST30-009", "리틀 오즈 Jr.", CHARACTER, RED, 2000, 1000, 1,
     setcode("거인족", "흰 수염 해적단 산하"),
     "자신의 원래 파워 6000인 캐릭터가 상대의 효과로 필드에서 벗어날 경우, "
     "대신 이 캐릭터를 트래시에 놓고 카드를 1장 뽑을 수 있다."),

    ("ST30-010", "크로커다일", CHARACTER, GREEN, 6000, 1000, 6,
     setcode("임펠 다운", "전 바로크 워크스"),
     "【블로커】(상대의 어택 후, 이 카드를 레스트로 하여 어택 대상을 이 카드로 변경할 수 있다.)\n"
     "【등장 시】 상대의 레스트 상태인 캐릭터 1장까지는 다음 상대의 리프레시 페이즈에 액티브가 되지 않는다."),

    ("ST30-011", "버기", CHARACTER, GREEN, 1000, 1000, 2,
     setcode("임펠 다운", "버기 해적단"),
     "자신의 원래 파워 6000인 캐릭터가 상대의 효과로 필드에서 벗어날 경우, "
     "대신 이 캐릭터를 레스트로 할 수 있다.\n"
     "【블로커】(상대의 어택 후, 이 카드를 레스트로 하여 어택 대상을 이 카드로 변경할 수 있다.)"),

    ("ST30-012", "몽키 D. 루피", CHARACTER, GREEN, 6000, NO, 4,
     setcode("임펠 다운", "밀짚모자 일당"),
     "【등장 시】 자신의 두웅!! 1장을 레스트로 할 수 있다: 이 캐릭터는 이번 턴 동안 【속공】을 얻는다."
     "(이 카드는 등장한 턴에 어택할 수 있다)\n"
     "【어택 시】 상대의 【블로커】를 가진 캐릭터 1장까지를 레스트로 한다."),

    ("ST30-013", "Mr.2 봉쿠레(벤담)", CHARACTER, GREEN, 6000, 1000, 4,
     setcode("임펠 다운", "전 바로크 워크스"), ""),

    ("ST30-014", "Mr.3 (갤디노)", CHARACTER, GREEN, 3000, 2000, 2,
     setcode("임펠 다운", "전 바로크 워크스"),
     "【기동: 메인】 이 캐릭터를 레스트로 할 수 있다: 자신의 원래 파워 6000인 캐릭터 2장까지에 "
     "레스트 상태인 두웅!!을 2장씩까지 붙인다."),

    ("ST30-015", "이 시대의 이름을 '흰수염'이라 한다!!", EVENT, RED, NO, NO, 1,
     setcode("흰 수염 해적단"),
     "【카운터】 자신의 원래 파워 6000인 캐릭터가 2장 이상 있을 경우, "
     "자신의 리더나 캐릭터 1장까지는 이번 배틀 동안 파워 +4000.\n"
     "【트리거】 상대의 파워 6000 이하인 캐릭터 1장까지를 KO한다."),

    ("ST30-016", "아직 싸울 수 있냐 루피!? 당연하지!!!", EVENT, RED, NO, NO, 1,
     setcode("흰 수염 해적단", "밀짚모자 일당"),
     "【카운터】 자신의 리더나 캐릭터 1장까지는 이번 배틀 동안 파워 +3000. "
     "그 후, 자신의 원래 파워 6000인 캐릭터 「포트거스 D. 에이스」와 「몽키 D. 루피」가 있을 경우, "
     "카드를 1장 뽑는다."),

    ("ST30-017", "그리고 큰일나 버리는 거야!!", EVENT, RED, NO, NO, 1,
     setcode("흰 수염 해적단"),
     "【메인】 자신의 덱 위에서 5장을 보고, 파워 6000인 캐릭터 카드 1장까지를 공개하고 패에 넣는다. "
     "그 후, 남은 카드를 원하는 순서대로 덱 맨 아래에 놓는다.\n"
     "【트리거】 이 카드의 【메인】 효과를 발동한다."),
]

START_ID = 880002541


def main() -> None:
    db = sqlite3.connect(CDB)
    cur = db.cursor()
    if cur.execute("SELECT COUNT(*) FROM texts WHERE desc LIKE '[ST30-%'").fetchone()[0]:
        raise SystemExit("이미 ST30 항목이 있습니다. 중단.")
    max_id = cur.execute("SELECT MAX(id) FROM datas WHERE id < 881000000").fetchone()[0]
    if max_id >= START_ID:
        raise SystemExit(f"시작 id 충돌: 현재 최대 {max_id}, 시작 예정 {START_ID}. 중단.")

    stamp = _dt.datetime.now().strftime("%Y%m%d_%H%M%S")
    backup = BACKUP_DIR / f"st30_backup_{stamp}"
    backup.mkdir(parents=True, exist_ok=True)
    shutil.copy2(CDB, backup / CDB.name)
    print(f"백업: {backup / CDB.name}")

    for offset, card in enumerate(CARDS):
        code, name, (ctype, race), attr, atk, dfn, level, sc, body = card
        cid = START_ID + offset
        desc = f"[{code}]" + (f"\n\n{body}" if body else "")
        cur.execute(
            "INSERT INTO datas (id, ot, alias, setcode, type, atk, def, level, race, attribute, category) "
            "VALUES (?, 0, 0, ?, ?, ?, ?, ?, ?, ?, 0)",
            (cid, sc, ctype, atk, dfn, level, race, attr),
        )
        cur.execute(
            "INSERT INTO texts (id, name, desc, str1, str2, str3, str4, str5, str6, str7, str8, "
            "str9, str10, str11, str12, str13, str14, str15, str16) "
            "VALUES (?, ?, ?, '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '')",
            (cid, name, desc),
        )
        print(f"  {cid} {code} {name}")
    db.commit()
    total = cur.execute("SELECT COUNT(*) FROM datas").fetchone()[0]
    print(f"완료: 17장 추가, 총 {total}장")


if __name__ == "__main__":
    main()
