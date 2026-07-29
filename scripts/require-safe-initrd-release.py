#!/usr/bin/env python3
"""Fail closed until the reviewed RMX1901 initrd has an immutable release."""
import json
import pathlib
import re
import sys

repo_root = pathlib.Path(__file__).resolve().parents[1]
data = json.loads((repo_root / "safe-initrd-release.json").read_text(encoding="utf-8"))

if data.get("schema") != "rmx1901-safe-initrd-release-v1":
    raise SystemExit("error: invalid RMX1901 safe-initrd release metadata")
if data.get("production_status") != "released" or data.get("release_immutable") is not True:
    raise SystemExit("error: immutable RMX1901 safe-initrd release/provenance is required")
repository = "Lcryolite/initramfs-tools-halium-rmx1901"
if data.get("repository") != repository:
    raise SystemExit("error: unexpected RMX1901 safe-initrd repository")
if not re.fullmatch(r"[0-9a-f]{40}", data.get("source_commit", "")):
    raise SystemExit("error: invalid RMX1901 safe-initrd source commit")
if not re.fullmatch(r"[0-9a-f]{64}", data.get("sha256", "")):
    raise SystemExit("error: invalid RMX1901 safe-initrd SHA-256")
if data["sha256"] in {
    "ac74c1124cc5cab7b9b42c9a06ca8ff5e14fc2d6e0d7237deb42da8a6788ceca",
    "b3582e99c21eab2dd2912fc2e1c8c128d9c03fab7147452569d0b2da6bf44e6a",
}:
    raise SystemExit("error: legacy RMX1901 initrd input is forbidden")
if not re.fullmatch(
    rf"https://api\.github\.com/repos/{re.escape(repository)}/releases/[1-9][0-9]*",
    data.get("release_api_url", ""),
):
    raise SystemExit("error: invalid immutable RMX1901 release API URL")
if not re.fullmatch(
    rf"https://api\.github\.com/repos/{re.escape(repository)}/releases/assets/[1-9][0-9]*",
    data.get("asset_api_url", ""),
):
    raise SystemExit("error: invalid immutable RMX1901 asset API URL")

print(data["asset_api_url"])
print(data["sha256"])
print(data["source_commit"])
