#!/usr/bin/env python3
"""Published-source and evidence contract for the RMX1901 API30 DPM closure."""

from __future__ import annotations

import os
import hashlib
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path


PORT = Path(__file__).resolve().parents[1]
ROOT = Path(os.environ.get("HALIUM_ROOT", "/home/lknife/android/rmx1901-halium11"))
DEVICE_COMMIT = "629a71f00b2f8d1d9a4ce3fb232203b17bc55e5e"
VENDOR_COMMIT = "1de6c5364d6ac44ae205276bc43c425a6ee946e5"
CANDIDATE_COMMIT = "f97fae29e34e28c7f06c47802d168e2cf81216ef"
REPLACEMENT_HASHES = {
    "7ed535a997d679dc32406969f708f2ea2430c46b17927f96ecd1f63fb3138c52",
    "2d1f9e8ab7dcf0a386ac9aeb6a4678a7230fce6699ecb7e5c10c8c5159b531d5",
    "7870d098b618a166e62bc0b081c6ede6c375a0d8e47059b1f6099111bdb3aed2",
    "587eee086464f3c6cb0559a3b34721bfcf278aa66bfeb0d608a2590ac8de0d1a",
    "f160ade4076c305bfedf67ae7fcffe532c284238940a6af0cda66bc3680c5693",
}
BUILD_LOGS = {
    "dpm-api30-focused.log": "9e5aa0cb6bd4a6efc167f0a4890494da349920ddf161d40166204e29686a22bb",
    "dpm-api30-nothing.log": "70c69a03496af895632a4967c060cd5338124773bb04bec46ef55673fe05263d",
}

manifest = ET.parse(PORT / "manifests/halium11-rmx1901.xml").getroot()
projects = {project.get("path"): project for project in manifest.findall("project")}
expected = {
    "device/realme/RMX1901": ("Lcryolite/device_realme_RMX1901", DEVICE_COMMIT),
    "vendor/realme/RMX1901": ("Lcryolite/1vendor_realme_RMX1901", VENDOR_COMMIT),
}
for path, (name, revision) in expected.items():
    project = projects.get(path)
    if project is None:
        raise SystemExit(f"manifest lost DPM closure source {path}")
    if project.get("name") != name or project.get("remote") != "github":
        raise SystemExit(f"manifest has wrong DPM closure source identity for {path}")
    if project.get("revision") != revision:
        raise SystemExit(f"manifest does not pin tested DPM closure source {path}")

verifier = ROOT / "device/realme/RMX1901/tests/verify-dpm-api30-cohort.sh"
if not verifier.is_file() or not os.access(verifier, os.X_OK):
    raise SystemExit("pinned device tree has no executable DPM closure verifier")
subprocess.run([str(verifier)], cwd=verifier.parents[1], check=True)

for name, expected_hash in BUILD_LOGS.items():
    log = PORT / "artifacts/product-audit/logs" / name
    if not log.is_file():
        raise SystemExit(f"DPM build evidence is missing {name}")
    actual_hash = hashlib.sha256(log.read_bytes()).hexdigest()
    if actual_hash != expected_hash:
        raise SystemExit(f"DPM build evidence hash changed: {name}: {actual_hash}")
    text = log.read_text(errors="replace")
    if "build completed successfully" not in text:
        raise SystemExit(f"DPM build evidence has no success marker: {name}")
focused_log = (PORT / "artifacts/product-audit/logs/dpm-api30-focused.log").read_text(
    errors="replace"
)
for module in (
    "dpmd",
    "dpmQmiMgr",
    "libdpmframework",
    "libdiag_system",
    "com.qualcomm.qti.dpm.api@1.0",
    "vendor.qti.diaghal@1.0",
):
    if module not in focused_log:
        raise SystemExit(f"focused DPM build log is missing {module}")
if focused_log.count("Check prebuilt ELF binary") < 6:
    raise SystemExit("focused DPM build log lost real ELF checker actions")

provenance = (PORT / "artifacts/product-audit/dpm-api30-closure.md").read_text()
for fact in {
    DEVICE_COMMIT,
    VENDOR_COMMIT,
    CANDIDATE_COMMIT,
    "5 replacements",
    "9 byte-identical keeps",
    "missing0",
    "no 32-bit import",
    "IMS remains unresolved",
    "9e5aa0cb6bd4a6efc167f0a4890494da349920ddf161d40166204e29686a22bb",
    "70c69a03496af895632a4967c060cd5338124773bb04bec46ef55673fe05263d",
    *REPLACEMENT_HASHES,
}:
    if fact not in provenance:
        raise SystemExit(f"DPM closure provenance is missing {fact}")

print("Published DPM API30 closure contract passed")
