#!/usr/bin/env python3
"""Contract for the published RMX1901 and Lineage sepolicy pins."""

from __future__ import annotations

import os
import re
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HALIUM_ROOT = Path(os.environ.get("HALIUM_ROOT", "/home/lknife/android/rmx1901-halium11"))
MANIFEST = ROOT / "manifests/halium11-rmx1901.xml"
PROVENANCE = ROOT / "artifacts/product-audit/halium-sepolicy-api30-provenance.md"
FULL_SHA = re.compile(r"[0-9a-f]{40}")
EXPECTED = {
    "device/realme/RMX1901": (
        "Lcryolite/device_realme_RMX1901",
        "629a71f00b2f8d1d9a4ce3fb232203b17bc55e5e",
    ),
    "device/lineage/sepolicy": (
        "Lcryolite/android_device_lineage_sepolicy",
        "04ab50816e0ab9ae7ed5aa094c70e276e1175479",
    ),
}


root = ET.parse(MANIFEST).getroot()
projects = [node.attrib for node in root.findall("project")]
removals = [node.attrib.get("path") for node in root.findall("remove-project")]
for path, (name, revision) in EXPECTED.items():
    matches = [project for project in projects if project.get("path") == path]
    if len(matches) != 1:
        raise SystemExit(f"manifest must pin {path} exactly once")
    project = matches[0]
    if project.get("name") != name or project.get("remote") != "github":
        raise SystemExit(f"{path}: wrong published GitHub repository")
    if project.get("revision") != revision or FULL_SHA.fullmatch(revision) is None:
        raise SystemExit(f"{path}: revision is not the audited full SHA")

if removals.count("device/lineage/sepolicy") != 1:
    raise SystemExit("manifest must remove the upstream Lineage sepolicy project once")

if not PROVENANCE.is_file():
    raise SystemExit("Halium sepolicy provenance record is missing")
evidence = PROVENANCE.read_text(encoding="utf-8")
for path, (name, revision) in EXPECTED.items():
    for token in (path, name, revision):
        if token not in evidence:
            raise SystemExit(f"provenance does not record {token}")
for token in (
    "sepolicy_neverallows",
    "vendor_sepolicy.cil",
    "3d6fa41ac6640aba36ec0b68231a1ed08818860da42a9d50763007ed053e58da",
    "56ef5527371482b3488f7d96a5550f32f49f946115f91b250dfd5e391c947812",
    "6bf32b71de2047964a6abf38dbad8f27cf56fa35e712e8e172508d2274f267a0",
):
    if token not in evidence:
        raise SystemExit(f"provenance omits verification token {token}")

if HALIUM_ROOT.is_dir():
    for path, (_, revision) in EXPECTED.items():
        repo = HALIUM_ROOT / path
        actual = subprocess.check_output(
            ["git", "-C", str(repo), "rev-parse", "HEAD"], text=True
        ).strip()
        if actual != revision:
            raise SystemExit(f"{path}: local checkout {actual} != manifest {revision}")

print("Halium API30 sepolicy publication pin contract passed")
