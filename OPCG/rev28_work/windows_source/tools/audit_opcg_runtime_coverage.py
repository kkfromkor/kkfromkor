from __future__ import annotations

import argparse
import collections
import json
import pathlib
import re


def table_entries(source: str, table: str, next_table: str | None) -> set[str]:
    start = source.index(f"local {table} = {{")
    end = source.index(f"local {next_table} = {{", start) if next_table else source.index("\n}", start)
    return set(re.findall(r"\b([A-Z][A-Z0-9_]*)\s*=\s*true\b", source[start:end]))


parser = argparse.ArgumentParser(description="Audit OPCG IR operations against opcg_core.lua support tables.")
repo_default = pathlib.Path(__file__).resolve().parents[1]
parser.add_argument("--repo", type=pathlib.Path, default=repo_default)
parser.add_argument("--ir", type=pathlib.Path)
args = parser.parse_args()

repo = args.repo.resolve()
script_root = repo / "bin" / "release" / "expansions" / "script"
ir_path = (args.ir or (repo / "opcg_data" / "opcg_ir.json")).resolve()

core = (script_root / "opcg_core.lua").read_text(encoding="utf-8")
supported = {
    "actions": table_entries(core, "ACTION", "NATIVE_TIMING"),
    "conditions": table_entries(core, "CONDITION", "COST"),
    "costs": table_entries(core, "COST", "ACTION"),
}
supported_timings = table_entries(core, "NATIVE_TIMING", None)

frequency = {section: collections.Counter() for section in supported}
cards_by_op = {section: collections.defaultdict(set) for section in supported}
timing_frequency: collections.Counter[str] = collections.Counter()
cards_by_timing: dict[str, set[str]] = collections.defaultdict(set)


def record(section: str, item: dict, card_id: str) -> None:
    op = item.get("op")
    if op:
        frequency[section][op] += 1
        cards_by_op[section][op].add(card_id)
    if section != "actions":
        return
    for nested in item.get("actions", []):
        record("actions", nested, card_id)
    for option in item.get("options", []):
        for nested in option:
            record("actions", nested, card_id)
    for conditions in item.get("option_conditions", []):
        for condition in conditions:
            record("conditions", condition, card_id)
    for condition in item.get("conditions", []):
        record("conditions", condition, card_id)


cards = json.loads(ir_path.read_text(encoding="utf-8"))
for card in cards:
    card_id = str(card["script_id"])
    for effect in card.get("abilities", []):
        for timing in effect.get("timings", []):
            timing_frequency[timing] += 1
            cards_by_timing[timing].add(card_id)
        for section in ("conditions", "costs", "actions"):
            for item in effect.get(section, []):
                record(section, item, card_id)

print(f"card_scripts={len(cards)}")
for section in ("conditions", "costs", "actions"):
    missing = sorted(set(frequency[section]) - supported[section])
    affected = set().union(*(cards_by_op[section][op] for op in missing)) if missing else set()
    print(
        f"{section}: used={len(frequency[section])} supported={len(supported[section])} "
        f"unsupported={len(missing)} affected_cards={len(affected)}"
    )
    for op in missing:
        print(f"  {op}: occurrences={frequency[section][op]} cards={len(cards_by_op[section][op])}")

missing_timings = sorted(set(timing_frequency) - supported_timings)
affected = set().union(*(cards_by_timing[timing] for timing in missing_timings)) if missing_timings else set()
print(
    f"timings: used={len(timing_frequency)} supported={len(supported_timings)} "
    f"unsupported={len(missing_timings)} affected_cards={len(affected)}"
)
for timing in missing_timings:
    print(f"  {timing}: occurrences={timing_frequency[timing]} cards={len(cards_by_timing[timing])}")
