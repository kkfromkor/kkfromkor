#!/usr/bin/env python3
"""JP 카드리스트 HTML의 이름/텍스트/트리거를 raw json의 jp 필드로 병합.

사용법:
  python3 merge_opcg_jp_text.py st30_jp.html st30_en_raw.json
(raw json을 제자리에서 갱신한다. st29_en_raw.json의 jp 필드와 같은 형태.)
"""

from __future__ import annotations

import html as _html
import json
import re
import sys
from pathlib import Path

BLOCK_RE = re.compile(r'<dl class="modalCol" id="([^"]+)">(.*?)</dl>', re.S)
NAME_RE = re.compile(r'<div class="cardName">([^<]+)</div>')
TEXT_RE = re.compile(r'<div class="text"><h3>テキスト</h3>(.*?)</div>', re.S)
TRIGGER_RE = re.compile(r'<div class="trigger"><h3>トリガー</h3>(.*?)</div>', re.S)


def clean_text(fragment: str) -> str:
    fragment = re.sub(r'<br\s*/?>', '\n', fragment)
    fragment = re.sub(r'<[^>]+>', '', fragment)
    return _html.unescape(fragment).strip()


def main() -> None:
    jp_html = Path(sys.argv[1]).read_text(encoding="utf-8")
    raw_path = Path(sys.argv[2])
    data = json.loads(raw_path.read_text(encoding="utf-8"))

    jp_map: dict[str, dict] = {}
    for card_id, body in BLOCK_RE.findall(jp_html):
        base_id = card_id.split("_")[0]
        if base_id in jp_map:
            continue
        name = NAME_RE.search(body)
        text = TEXT_RE.search(body)
        trig = TRIGGER_RE.search(body)
        jp_map[base_id] = {
            "name": clean_text(name.group(1)) if name else "",
            "effect": clean_text(text.group(1)) if text else "",
            "trigger": clean_text(trig.group(1)) if trig else "",
        }

    missing = []
    for card in data["cards"]:
        jp = jp_map.get(card["id"])
        if jp:
            card["jp"] = jp
        else:
            missing.append(card["id"])
    raw_path.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"jp 병합 완료: {len(jp_map)}장 매칭, 누락 {missing or '없음'}")


if __name__ == "__main__":
    main()
