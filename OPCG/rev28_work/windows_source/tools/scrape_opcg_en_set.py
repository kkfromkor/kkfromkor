#!/usr/bin/env python3
"""공식 EN 카드리스트 HTML에서 세트 raw json을 뽑는 도구.

st29_en_raw.json과 같은 스키마로 출력한다.
사용법:
  python3 scrape_opcg_en_set.py st30_en.html --series-id 569030 --out st30_en_raw.json
입력 HTML은 https://en.onepiece-cardgame.com/cardlist/?series=<id> 페이지 저장본.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import html as _html
import json
import re
from pathlib import Path

BLOCK_RE = re.compile(r'<dl class="modalCol" id="([^"]+)">(.*?)</dl>', re.S)
INFO_RE = re.compile(r'<div class="infoCol">\s*<span>([^<]+)</span>\s*\|\s*<span>([^<]+)</span>\s*\|\s*<span>([^<]+)</span>', re.S)
NAME_RE = re.compile(r'<div class="cardName">([^<]+)</div>')
FIELD_RES = {
    "cost": re.compile(r'<div class="cost"><h3>(?:Cost|Life)</h3>([^<]*)</div>'),
    "power": re.compile(r'<div class="power"><h3>Power</h3>([^<]*)</div>'),
    "counter": re.compile(r'<div class="counter"><h3>Counter</h3>([^<]*)</div>'),
    "color": re.compile(r'<div class="color"><h3>Color</h3>([^<]*)</div>'),
    "block": re.compile(r'<div class="block"><h3>Block[^<]*(?:<br[^>]*>)?[^<]*</h3>([^<]*)</div>'),
    "type": re.compile(r'<div class="feature"><h3>Type</h3>([^<]*)</div>'),
}
ATTR_RE = re.compile(r'<div class="attribute">.*?<i>([^<]*)</i>', re.S)
TEXT_RE = re.compile(r'<div class="text"><h3>Effect</h3>(.*?)</div>', re.S)
TRIGGER_RE = re.compile(r'<div class="trigger"><h3>Trigger</h3>(.*?)</div>', re.S)
SET_NAME_RE = re.compile(r'<div class="getInfo"><h3>Card Set\(s\)</h3>([^<]*)</div>')


def clean_text(fragment: str) -> str:
    fragment = re.sub(r'<br\s*/?>', '\n', fragment)
    fragment = re.sub(r'<[^>]+>', '', fragment)
    return _html.unescape(fragment).strip()


def parse(html_text: str, series_id: int, source: str) -> dict:
    cards: dict[str, dict] = {}
    alt_p1: list[str] = []
    set_name = ""
    for card_id, body in BLOCK_RE.findall(html_text):
        base_id = card_id.split("_")[0]
        if base_id in cards:
            # 같은 번호가 다시 나오면 얼트 프린트(P1)
            if base_id not in alt_p1:
                alt_p1.append(base_id)
            continue
        info = INFO_RE.search(body)
        name = NAME_RE.search(body)
        card = {
            "id": base_id,
            "rarity": clean_text(info.group(2)) if info else "",
            "category": clean_text(info.group(3)) if info else "",
            "name": clean_text(name.group(1)) if name else "",
        }
        for key, rx in FIELD_RES.items():
            m = rx.search(body)
            card[key] = clean_text(m.group(1)) if m else ""
        m = ATTR_RE.search(body)
        card["attribute"] = clean_text(m.group(1)) if m else ""
        m = TEXT_RE.search(body)
        card["effect"] = clean_text(m.group(1)) if m else ""
        m = TRIGGER_RE.search(body)
        card["trigger"] = clean_text(m.group(1)) if m else ""
        if not set_name:
            m = SET_NAME_RE.search(body)
            if m:
                set_name = clean_text(m.group(1))
        cards[base_id] = card
    ordered = [cards[k] for k in sorted(cards)]
    return {
        "source": source,
        "scraped": _dt.date.today().isoformat(),
        "set": set_name,
        "series_id": series_id,
        "unique_cards": len(ordered),
        "alt_prints_p1": sorted(alt_p1),
        "cards": ordered,
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("html", type=Path)
    ap.add_argument("--series-id", type=int, required=True)
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()
    source = f"https://en.onepiece-cardgame.com/cardlist/?series={args.series_id}"
    data = parse(args.html.read_text(encoding="utf-8"), args.series_id, source)
    args.out.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"{data['set']}: {data['unique_cards']}장, 얼트 {len(data['alt_prints_p1'])}장 -> {args.out}")


if __name__ == "__main__":
    main()
