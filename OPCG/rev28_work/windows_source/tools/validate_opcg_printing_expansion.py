#!/usr/bin/env python3
import hashlib
import json
import sqlite3
import sys
from pathlib import Path


if len(sys.argv) != 2:
    raise SystemExit("usage: validate_opcg_printing_expansion.py <repo-root>")

root = Path(sys.argv[1])
expansions = root / "bin" / "release" / "expansions"
scripts = expansions / "script"
pics = root / "bin" / "release" / "pics"
cdb = expansions / "cards-opcg.cdb"
backup = expansions / "cards-opcg.pre-printing-expansion-20260703.cdb"
manifest_path = root / "opcg_data" / "opcg_printing_cdb_map.json"
report_path = root / "opcg_data" / "opcg_printing_expansion_report.json"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest().upper()


manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
entries = manifest["entries"]
assert len(entries) == 2556
variants = [entry for entry in entries if entry["alias"]]
assert len(variants) == 551
assert len({entry["cdb_id"] for entry in entries}) == 2556
assert {entry["cdb_id"] for entry in variants} == set(range(881000000, 881000551))

connection = sqlite3.connect(cdb)
try:
    assert connection.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
    datas = {
        row[0]: row for row in connection.execute("SELECT * FROM datas")
    }
    texts = {
        row[0]: row for row in connection.execute("SELECT * FROM texts")
    }
finally:
    connection.close()

assert len(datas) == 2559
assert len(texts) == 2559
assert sum(row[2] != 0 for row in datas.values()) == 551

missing_wrappers = []
bad_wrappers = []
missing_images = []
bad_images = []
bad_rows = []

for entry in variants:
    code = entry["cdb_id"]
    base = entry["alias"]
    row = datas[code]
    base_row = datas[base]
    if row[2] != base or row[3:] != base_row[3:]:
        bad_rows.append(code)
    text = texts[code]
    if text[3] != entry["printing_id"] or text[4] != entry["rules_id"]:
        bad_rows.append(code)

    wrapper = scripts / f"c{code}.lua"
    if not wrapper.is_file():
        missing_wrappers.append(code)
    else:
        source = wrapper.read_text(encoding="utf-8")
        if (
            f'Duel.LoadScript("c{base}.lua", false)' not in source
            or "initial_effect(c)" in source
        ):
            bad_wrappers.append(code)

    source_image = pics / entry["source_image"]
    image = pics / entry["image_file"]
    if not source_image.is_file() or not image.is_file():
        missing_images.append(code)
    elif sha256(source_image) != sha256(image):
        bad_images.append(code)

bootstrap = (scripts / "opcg_bootstrap.lua").read_text(encoding="utf-8")
assert bootstrap.count('Duel.LoadScript("opcg_printing_alias.lua", true)') == 1
alias_source = (scripts / "opcg_printing_alias.lua").read_text(encoding="utf-8")
for entry in variants:
    assert f"[{entry['cdb_id']}]={entry['alias']}" in alias_source

assert not missing_wrappers, missing_wrappers[:10]
assert not bad_wrappers, bad_wrappers[:10]
assert not missing_images, missing_images[:10]
assert not bad_images, bad_images[:10]
assert not bad_rows, bad_rows[:10]
assert backup.is_file()
assert report_path.is_file()

result = {
    "cdb_rows": len(datas),
    "printing_rows": len(entries),
    "canonical_rows": len(entries) - len(variants),
    "alias_rows": len(variants),
    "wrapper_scripts": len(list(scripts.glob("c881*.lua"))),
    "numeric_variant_images": len(list(pics.glob("881*.jpg"))),
    "source_variant_images": len(
        [path for path in pics.glob("880*_p*.jpg") if path.is_file()]
    ),
    "cdb_sha256": sha256(cdb),
    "backup_cdb_sha256": sha256(backup),
    "manifest_sha256": sha256(manifest_path),
}
print(json.dumps(result, ensure_ascii=True, indent=2))
