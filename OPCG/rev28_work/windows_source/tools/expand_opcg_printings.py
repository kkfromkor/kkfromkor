#!/usr/bin/env python3
"""Expand a 2,005-rule OPCG database into 2,556 visible printings.

The original rule card keeps its 880xxxxxx id. Every additional printing gets
an id in the 881000000 range, aliases the rule card in datas, uses a tiny Lua
wrapper that invokes the canonical script, and receives a numeric image copy.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import tempfile


VARIANT_ID_START = 881_000_000
SYSTEM_IDS = {879_999_997, 879_999_998, 879_999_999}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest().upper()


def fetch_rows(connection: sqlite3.Connection, table: str) -> dict[int, tuple]:
    return {int(row[0]): row for row in connection.execute(f"SELECT * FROM {table}")}


def variant_source_name(script_id: int, printing_id: str, counters: dict[str, int]) -> str:
    match = re.search(r"_P(\d+)(?:@.*)?$", printing_id, re.IGNORECASE)
    if not match:
        raise ValueError(f"non-primary printing has no _P suffix: {printing_id}")
    stem = f"{script_id}_p{int(match.group(1))}"
    counters[stem] = counters.get(stem, 0) + 1
    if counters[stem] > 1:
        stem += f"_{counters[stem]}"
    return stem + ".jpg"


def printing_desc(base_desc: str, printing: dict) -> str:
    lines = (base_desc or "").splitlines()
    header = f"[{printing['printing_id']}]"
    if lines and re.fullmatch(r"\[[^\]]+\]", lines[0]):
        lines[0] = header
    else:
        lines.insert(0, header)
    details = [
        str(printing.get("rarity") or "").strip(),
        str(printing.get("illustration_type") or "").strip(),
        str(printing.get("series") or "").strip(),
    ]
    detail_line = "Printing: " + " | ".join(value for value in details if value)
    if detail_line != "Printing: ":
        lines.extend(["", detail_line])
    return "\n".join(lines)


def printing_text_row(base: tuple, code: int, rules_id: str, printing: dict) -> tuple:
    row = list(base)
    row[0] = code
    row[2] = printing_desc(str(row[2] or ""), printing)
    row[3] = printing["printing_id"]  # str1: visible card/printing number
    row[4] = rules_id                 # str2: canonical rules id
    row[16] = printing["printing_id"]  # str14: this exact printing
    row[17] = str(printing.get("rarity") or "")
    series = str(printing.get("series") or "")
    illustration = str(printing.get("illustration_type") or "")
    row[18] = " | ".join(value for value in (series, illustration) if value)
    return tuple(row)


def wrapper_source(code: int, base_code: int, printing_id: str) -> str:
    return (
        f"-- AUTO-GENERATED PRINTING ALIAS: {printing_id} -> {base_code}\n"
        f'Duel.LoadScript("c{base_code}.lua", false)\n'
    )


def alias_module_source(entries: list[dict]) -> str:
    lines = [
        "-- AUTO-GENERATED OPCG printing-to-rules aliases.",
        "opcg = opcg or {}",
        "opcg.printing_alias = {",
    ]
    for entry in entries:
        if entry["alias"]:
            lines.append(f"\t[{entry['cdb_id']}]={entry['alias']}, -- {entry['printing_id']}")
    lines.extend(
        [
            "}",
            "",
            "if opcg.card_meta then",
            "\tfor printing_code, base_code in pairs(opcg.printing_alias) do",
            "\t\topcg.card_meta[printing_code] = opcg.card_meta[base_code]",
            "\tend",
            "end",
            "",
            "function opcg.GetBasePrintingCode(code)",
            "\treturn opcg.printing_alias[code] or code",
            "end",
            "",
            "return opcg.printing_alias",
            "",
        ]
    )
    return "\n".join(lines)


def patched_bootstrap_source(source: str) -> str:
    load_line = 'Duel.LoadScript("opcg_printing_alias.lua", true)'
    if load_line in source:
        return source
    anchor = 'Duel.LoadScript("opcg_card_meta.lua", true)'
    if source.count(anchor) != 1:
        raise ValueError(f"bootstrap card-meta anchor count is {source.count(anchor)}, expected 1")
    return source.replace(anchor, anchor + "\n" + load_line)


def build_expansion(root: Path, output: Path, copy_images: bool) -> dict:
    ir_path = root / "opcg_data" / "opcg_ir.json"
    source_cdb = root / "bin" / "release" / "expansions" / "cards-opcg.cdb"
    source_scripts = root / "bin" / "release" / "expansions" / "script"
    source_pics = root / "bin" / "release" / "pics"
    source_bootstrap = source_scripts / "opcg_bootstrap.lua"

    ir = json.loads(ir_path.read_text(encoding="utf-8"))
    if len(ir) != 2005:
        raise ValueError(f"expected 2005 rule cards, found {len(ir)}")
    printing_count = sum(len(card.get("printings") or []) for card in ir)
    if printing_count != 2556:
        raise ValueError(f"expected 2556 printings, found {printing_count}")

    output.mkdir(parents=True, exist_ok=True)
    output_scripts = output / "script"
    output_pics = output / "pics"
    output_scripts.mkdir(exist_ok=True)
    if copy_images:
        output_pics.mkdir(exist_ok=True)
    output_cdb = output / "cards-opcg.cdb"
    shutil.copy2(source_cdb, output_cdb)

    connection = sqlite3.connect(output_cdb)
    try:
        connection.execute("PRAGMA foreign_keys=ON")
        datas = fetch_rows(connection, "datas")
        texts = fetch_rows(connection, "texts")
        rule_ids = {int(card["script_id"]) for card in ir}
        if len(rule_ids) != 2005:
            raise ValueError("script ids are not unique")
        if not rule_ids.issubset(datas) or not rule_ids.issubset(texts):
            raise ValueError("CDB is missing one or more canonical script rows")
        if any(VARIANT_ID_START <= key < VARIANT_ID_START + 100_000 for key in datas):
            raise ValueError("variant id range is already occupied")

        base_datas_before = {key: datas[key] for key in rule_ids | SYSTEM_IDS}
        base_texts_before = {key: texts[key] for key in rule_ids | SYSTEM_IDS}
        mapping = []
        wrappers = []
        variant_code = VARIANT_ID_START

        for card in ir:
            base_code = int(card["script_id"])
            rules_id = str(card["rules_id"])
            printings = card.get("printings") or []
            if not printings:
                raise ValueError(f"card {base_code} has no printing")
            base_image = source_pics / f"{base_code}.jpg"
            if not base_image.is_file():
                raise FileNotFoundError(base_image)
            mapping.append(
                {
                    "cdb_id": base_code,
                    "alias": 0,
                    "script_id": base_code,
                    "rules_id": rules_id,
                    "printing_id": printings[0]["printing_id"],
                    "source_image": base_image.name,
                    "image_file": base_image.name,
                    "rarity": printings[0].get("rarity"),
                    "series": printings[0].get("series"),
                    "illustration_type": printings[0].get("illustration_type"),
                }
            )

            suffix_counters: dict[str, int] = {}
            for printing in printings[1:]:
                source_image_name = variant_source_name(
                    base_code, str(printing["printing_id"]), suffix_counters
                )
                source_image = source_pics / source_image_name
                if not source_image.is_file():
                    raise FileNotFoundError(source_image)
                image_file = f"{variant_code}.jpg"

                base_data = list(datas[base_code])
                base_data[0] = variant_code
                base_data[2] = base_code
                connection.execute(
                    "INSERT INTO datas VALUES (?,?,?,?,?,?,?,?,?,?,?)", tuple(base_data)
                )
                text_row = printing_text_row(
                    texts[base_code], variant_code, rules_id, printing
                )
                connection.execute(
                    "INSERT INTO texts VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    text_row,
                )

                wrapper = output_scripts / f"c{variant_code}.lua"
                wrapper.write_text(
                    wrapper_source(variant_code, base_code, str(printing["printing_id"])),
                    encoding="utf-8",
                    newline="\n",
                )
                wrappers.append(wrapper)
                if copy_images:
                    shutil.copy2(source_image, output_pics / image_file)
                mapping.append(
                    {
                        "cdb_id": variant_code,
                        "alias": base_code,
                        "script_id": base_code,
                        "rules_id": rules_id,
                        "printing_id": printing["printing_id"],
                        "source_image": source_image_name,
                        "image_file": image_file,
                        "rarity": printing.get("rarity"),
                        "series": printing.get("series"),
                        "illustration_type": printing.get("illustration_type"),
                    }
                )
                variant_code += 1

        connection.commit()
        integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
        if integrity != "ok":
            raise ValueError(f"SQLite integrity check failed: {integrity}")
        expanded_datas = fetch_rows(connection, "datas")
        expanded_texts = fetch_rows(connection, "texts")
        if len(expanded_datas) != 2559 or len(expanded_texts) != 2559:
            raise ValueError(
                f"expanded row count mismatch: datas={len(expanded_datas)} "
                f"texts={len(expanded_texts)}"
            )
        aliases = [row for row in expanded_datas.values() if row[2] != 0]
        if len(aliases) != 551:
            raise ValueError(f"expected 551 alias rows, found {len(aliases)}")
        for key, row in base_datas_before.items():
            if expanded_datas[key] != row:
                raise ValueError(f"base datas row changed: {key}")
        for key, row in base_texts_before.items():
            if expanded_texts[key] != row:
                raise ValueError(f"base texts row changed: {key}")
    finally:
        connection.close()

    (output_scripts / "opcg_printing_alias.lua").write_text(
        alias_module_source(mapping), encoding="utf-8", newline="\n"
    )
    bootstrap = patched_bootstrap_source(source_bootstrap.read_text(encoding="utf-8"))
    (output_scripts / "opcg_bootstrap.lua").write_text(
        bootstrap, encoding="utf-8", newline="\n"
    )
    manifest = {
        "schema_version": 1,
        "id_policy": {
            "canonical_rule_cards": "880000000..880002004",
            "additional_printings": "881000000..881000550",
            "system_cards": sorted(SYSTEM_IDS),
        },
        "counts": {
            "rule_cards": len(ir),
            "printings": len(mapping),
            "additional_printings": len(mapping) - len(ir),
            "cdb_rows_with_system_cards": len(mapping) + len(SYSTEM_IDS),
            "wrapper_scripts": len(wrappers),
        },
        "entries": mapping,
    }
    manifest_path = output / "opcg_printing_cdb_map.json"
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    report = {
        "source_root": str(root),
        "source_cdb_sha256": sha256(source_cdb),
        "expanded_cdb_sha256": sha256(output_cdb),
        "expanded_cdb_size": output_cdb.stat().st_size,
        "counts": manifest["counts"],
        "image_copies_materialized": copy_images,
    }
    (output / "opcg_printing_expansion_report.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    return report


def deploy(root: Path, built: Path) -> None:
    target_expansions = root / "bin" / "release" / "expansions"
    target_scripts = target_expansions / "script"
    target_pics = root / "bin" / "release" / "pics"
    target_data = root / "opcg_data"
    target_cdb = target_expansions / "cards-opcg.cdb"
    target_bootstrap = target_scripts / "opcg_bootstrap.lua"
    backup_cdb = target_expansions / "cards-opcg.pre-printing-expansion-20260703.cdb"
    backup_bootstrap = target_scripts / "opcg_bootstrap.pre-printing-expansion-20260703.lua"

    if not backup_cdb.exists():
        shutil.copy2(target_cdb, backup_cdb)
    if not backup_bootstrap.exists():
        shutil.copy2(target_bootstrap, backup_bootstrap)

    temporary_cdb = target_expansions / "cards-opcg.cdb.printing-expansion.tmp"
    shutil.copy2(built / "cards-opcg.cdb", temporary_cdb)
    os.replace(temporary_cdb, target_cdb)

    for wrapper in (built / "script").glob("c881*.lua"):
        destination = target_scripts / wrapper.name
        if destination.exists() and sha256(destination) != sha256(wrapper):
            raise FileExistsError(f"conflicting wrapper: {destination}")
        shutil.copy2(wrapper, destination)
    shutil.copy2(
        built / "script" / "opcg_printing_alias.lua",
        target_scripts / "opcg_printing_alias.lua",
    )
    shutil.copy2(built / "script" / "opcg_bootstrap.lua", target_bootstrap)

    manifest = json.loads(
        (built / "opcg_printing_cdb_map.json").read_text(encoding="utf-8")
    )
    for entry in manifest["entries"]:
        if not entry["alias"]:
            continue
        source = target_pics / entry["source_image"]
        destination = target_pics / entry["image_file"]
        if destination.exists() and sha256(destination) != sha256(source):
            raise FileExistsError(f"conflicting image: {destination}")
        shutil.copy2(source, destination)

    shutil.copy2(
        built / "opcg_printing_cdb_map.json",
        target_data / "opcg_printing_cdb_map.json",
    )
    shutil.copy2(
        built / "opcg_printing_expansion_report.json",
        target_data / "opcg_printing_expansion_report.json",
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--copy-images", action="store_true")
    parser.add_argument("--deploy", action="store_true")
    arguments = parser.parse_args()

    root = arguments.root.resolve()
    output = arguments.output.resolve()
    if output.exists():
        shutil.rmtree(output)
    report = build_expansion(root, output, arguments.copy_images)
    if arguments.deploy:
        deploy(root, output)
    print(json.dumps(report, ensure_ascii=True, indent=2))


if __name__ == "__main__":
    main()
