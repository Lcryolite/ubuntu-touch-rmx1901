#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="$repo_root/manifests/halium11-rmx1901.xml"
published_pins="$repo_root/artifacts/product-audit/halium-published-pins.tsv"
: "${HALIUM_ROOT:=/home/lknife/android/rmx1901-halium11}"

python3 - "$manifest" "$published_pins" "$HALIUM_ROOT" <<'PY'
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

manifest = ET.parse(sys.argv[1]).getroot()
pins_file = Path(sys.argv[2])
halium_root = Path(sys.argv[3])
projects = {project.attrib["path"]: project.attrib for project in manifest.findall("project")}
halium_boot = projects.get("halium/halium-boot")

pin_lines = [line for line in pins_file.read_text().splitlines() if line]
pin_header = pin_lines[0].removeprefix("# ").split("\t")
published_pins = {
    row["path"]: row
    for row in (
        dict(zip(pin_header, line.split("\t"), strict=True))
        for line in pin_lines[1:]
    )
}

if halium_boot is None:
    raise SystemExit("manifest does not provide the halium-boot build component")
if halium_boot.get("name") != "Lcryolite/halium-boot":
    raise SystemExit("halium-boot manifest project does not use the published port repository")
revision = halium_boot.get("revision", "")
if re.fullmatch(r"[0-9a-f]{40}", revision) is None:
    raise SystemExit("halium-boot manifest revision is not a full commit SHA")

for path, project in projects.items():
    expected = project.get("revision", "")
    if re.fullmatch(r"[0-9a-f]{40}", expected) is None:
        raise SystemExit(f"manifest revision is not a full commit SHA: {path}")
    checkout = halium_root / path
    if not checkout.is_dir():
        raise SystemExit(f"manifest checkout is missing: {path}")
    actual = subprocess.check_output(
        ["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True
    ).strip()
    if actual != expected:
        pin = published_pins.get(path)
        is_audited_publication_rewrite = (
            path in {"frameworks/base", "system/core"}
            and pin is not None
            and pin["published_head"] == expected
            and pin["original_head"] == actual
        )
        if is_audited_publication_rewrite:
            continue
        raise SystemExit(
            f"manifest revision does not match checkout: {path}: {expected} != {actual}"
        )
PY

python3 - "$repo_root/artifacts/supply-chain" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
release = json.loads((root / "halium-initrd-arm64.release.json").read_text())
provenance = json.loads((root / "halium-initrd-arm64.provenance.json").read_text())
expected = {
    "id": 9577925,
    "tag_name": "continuous",
    "target_commitish": "a2c1bb1a68b4ca312749dc5859feddf124a5946f",
    "created_at": "2018-02-07T18:19:03Z",
    "published_at": "2018-02-07T18:27:55Z",
}
for field, value in expected.items():
    if release.get(field) != value:
        raise SystemExit(f"official release snapshot has wrong {field}: {release.get(field)!r}")
provenance_fields = {
    "release_id": "id",
    "release_tag": "tag_name",
    "release_target_commitish": "target_commitish",
    "release_created_at": "created_at",
    "release_published_at": "published_at",
}
for minimized_field, api_field in provenance_fields.items():
    if provenance.get(minimized_field) != release.get(api_field):
        raise SystemExit(
            f"minimized provenance {minimized_field} differs from release API snapshot"
        )
PY

echo "Halium source contract tests passed"
