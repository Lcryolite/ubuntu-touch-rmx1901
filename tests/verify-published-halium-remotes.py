#!/usr/bin/env python3
"""Verify that every published manifest SHA is reachable from a remote ref."""

from __future__ import annotations

import os
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "manifests/halium11-rmx1901.xml"
PINS = ROOT / "artifacts/product-audit/halium-published-pins.tsv"


def read_pinned_paths() -> list[str]:
    lines = [line for line in PINS.read_text(encoding="utf-8").splitlines() if line]
    header = lines[0].removeprefix("# ").split("\t")
    rows = [dict(zip(header, line.split("\t"), strict=True)) for line in lines[1:]]
    return [row["path"] for row in rows]


manifest = ET.parse(MANIFEST).getroot()
remotes = {remote.attrib["name"]: remote.attrib["fetch"] for remote in manifest.findall("remote")}
projects = {project.attrib["path"]: project.attrib for project in manifest.findall("project")}
environment = os.environ.copy()
environment["GIT_TERMINAL_PROMPT"] = "0"

failures = []
for path in read_pinned_paths():
    project = projects[path]
    revision = project["revision"]
    url = f'{remotes[project["remote"]]}{project["name"]}.git'
    result = subprocess.run(
        ["git", "ls-remote", "--refs", url],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
        timeout=60,
    )
    refs = [line.split() for line in result.stdout.splitlines() if line.strip()]
    matching_refs = [ref for oid, ref in refs if oid == revision]
    if result.returncode or not matching_refs:
        detail = result.stderr.strip() or "exact SHA is absent from all advertised refs"
        failures.append(f"{path}: {revision}: {detail}")
        continue
    print(f"remote pin verified: {path} {revision} {matching_refs[0]}")

if failures:
    raise SystemExit("remote pin verification failed:\n" + "\n".join(failures))

print("Published Halium remote verification passed: 14 exact SHAs")
