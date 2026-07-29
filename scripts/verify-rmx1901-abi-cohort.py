#!/usr/bin/env python3
"""Verify fail-closed RMX1901 service-specific Android ABI cohort manifests."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
from typing import Any

SCHEMA = "rmx1901-hardware-cohorts-v1"
FEATURES = {"wifi", "bluetooth", "audio", "camera", "dsp"}
REQUIRED = {
    "feature",
    "source_release",
    "source_path",
    "sha256",
    "elf_class",
    "machine",
    "soname",
    "needed",
    "runtime_destination",
    "consumer",
}
HEX64 = re.compile(r"^[0-9a-f]{64}$")
UUID_SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._@+-]*$")
NEEDED_RE = re.compile(r"\(NEEDED\).*\[([^]]+)]")
SONAME_RE = re.compile(r"\(SONAME\).*\[([^]]+)]")
SYMBOL_RE = re.compile(r"^\s*\d+:\s+[0-9a-fA-F]+\s+\d+\s+\S+\s+\S+\s+\S+\s+(\S+)\s+(.+)$")
FORBIDDEN_DESTINATION_PREFIXES = (
    "/android/",
    "/system/",
    "/vendor/",
    "/odm/",
    "/compat/vendor-compat/",
)
FORBIDDEN_BASENAMES_OUTSIDE_COHORT = {
    "libbinder.so",
    "libhidlbase.so",
    "libui.so",
    "libgui.so",
    "libvndksupport.so",
}


class VerificationError(Exception):
    pass


def fail(message: str) -> None:
    raise VerificationError(message)


def run_readelf(readelf: str, *args: str, path: Path) -> str:
    try:
        result = subprocess.run(
            [readelf, *args, str(path)],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        fail(f"readelf failed for {path}: {exc}")
    if result.returncode != 0:
        fail(f"readelf rejected {path}: {result.stderr.strip()}")
    return result.stdout


def elf_metadata(readelf: str, path: Path) -> dict[str, Any]:
    with path.open("rb") as stream:
        magic = stream.read(4)
    if magic != b"\x7fELF":
        return {
            "elf_class": "not-elf",
            "machine": "not-elf",
            "soname": None,
            "needed": [],
            "defined_symbols": set(),
        }
    header = run_readelf(readelf, "-hW", path=path)
    dynamic = run_readelf(readelf, "-dW", path=path)
    symbols = run_readelf(readelf, "-Ws", path=path)
    elf_class = ""
    machine = ""
    for line in header.splitlines():
        key, _, value = line.partition(":")
        if key.strip() == "Class":
            elf_class = value.strip()
        elif key.strip() == "Machine":
            raw = value.strip()
            machine = "AArch64" if raw == "AArch64" else "ARM" if raw == "ARM" else raw
    needed = sorted({match.group(1) for line in dynamic.splitlines() if (match := NEEDED_RE.search(line))})
    sonames = [match.group(1) for line in dynamic.splitlines() if (match := SONAME_RE.search(line))]
    if len(set(sonames)) > 1:
        fail(f"multiple SONAME values in {path}")
    defined: set[str] = set()
    for line in symbols.splitlines():
        match = SYMBOL_RE.match(line)
        if not match:
            continue
        index, name = match.groups()
        if index != "UND":
            defined.add(name.split("@", 1)[0])
    return {
        "elf_class": elf_class,
        "machine": machine,
        "soname": sonames[0] if sonames else None,
        "needed": needed,
        "defined_symbols": defined,
    }


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def load_manifest(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        fail(f"cannot load manifest: {exc}")
    if not isinstance(value, dict):
        fail("manifest root must be an object")
    return value


def safe_source(root: Path, source_path: str) -> Path:
    pure = PurePosixPath(source_path)
    if not pure.is_absolute() or ".." in pure.parts or source_path.endswith("/"):
        fail(f"unsafe source_path: {source_path}")
    candidate = root.joinpath(*pure.parts[1:])
    try:
        resolved_root = root.resolve(strict=True)
        resolved = candidate.resolve(strict=True)
    except OSError as exc:
        fail(f"missing source payload {source_path}: {exc}")
    if resolved_root not in resolved.parents:
        fail(f"source payload escapes source root: {source_path}")
    if not resolved.is_file() or candidate.is_symlink():
        fail(f"source payload must be a regular non-symlink file: {source_path}")
    return resolved


def validate_destination(entry: dict[str, Any]) -> None:
    destination = entry["runtime_destination"]
    feature = entry["feature"]
    if not isinstance(destination, str):
        fail("runtime_destination must be a string")
    pure = PurePosixPath(destination)
    prefix = PurePosixPath("/userdata/rmx1901-hw") / feature
    if not pure.is_absolute() or ".." in pure.parts or pure == prefix or prefix not in pure.parents:
        fail(f"runtime_destination is outside the service cohort: {destination}")
    if destination.startswith(FORBIDDEN_DESTINATION_PREFIXES):
        fail(f"forbidden global runtime destination: {destination}")
    basename = pure.name
    if basename in FORBIDDEN_BASENAMES_OUTSIDE_COHORT and prefix not in pure.parents:
        fail(f"forbidden shared ABI replacement: {destination}")


def validate_manifest(manifest_path: Path, readelf: str, allow_incomplete: bool) -> dict[str, Any]:
    manifest = load_manifest(manifest_path)
    if manifest.get("schema") != SCHEMA:
        fail(f"schema must be {SCHEMA}")
    if manifest.get("complete") is not True and not allow_incomplete:
        fail("manifest is not marked complete")
    roots_raw = manifest.get("source_roots")
    entries = manifest.get("entries")
    allowed_raw = manifest.get("allowed_system_libraries", [])
    if not isinstance(roots_raw, dict) or not roots_raw:
        fail("source_roots must be a non-empty object")
    if not isinstance(entries, list) or not entries:
        fail("entries must be a non-empty array")
    allowed_by_feature: dict[str, set[str]] = {}
    if isinstance(allowed_raw, list):
        if allowed_raw != sorted(set(allowed_raw)) or not all(isinstance(x, str) and x for x in allowed_raw):
            fail("allowed_system_libraries must be sorted and unique")
        allowed_by_feature = {feature: set(allowed_raw) for feature in FEATURES}
    elif isinstance(allowed_raw, dict) and set(allowed_raw) == FEATURES:
        for feature, values in allowed_raw.items():
            if not isinstance(values, list) or values != sorted(set(values)) or not all(isinstance(x, str) and x for x in values):
                fail(f"allowed_system_libraries.{feature} must be a sorted unique string array")
            allowed_by_feature[feature] = set(values)
    else:
        fail("allowed_system_libraries must be a sorted array or an object keyed by every feature")
    base = manifest_path.resolve().parent.parent
    roots: dict[str, Path] = {}
    for release, raw_root in roots_raw.items():
        if not isinstance(release, str) or not UUID_SAFE_NAME.fullmatch(release):
            fail(f"unsafe source release key: {release!r}")
        if not isinstance(raw_root, str):
            fail(f"source root for {release} must be a string")
        root = Path(raw_root)
        if not root.is_absolute():
            root = base / root
        roots[release] = root

    seen_destinations: set[str] = set()
    seen_sources: set[tuple[str, str]] = set()
    verified: list[dict[str, Any]] = []
    for index, raw in enumerate(entries):
        if not isinstance(raw, dict):
            fail(f"entry {index} must be an object")
        missing = sorted(REQUIRED - raw.keys())
        if missing:
            fail(f"entry {index} missing fields: {', '.join(missing)}")
        feature = raw["feature"]
        release = raw["source_release"]
        source_path = raw["source_path"]
        if feature not in FEATURES:
            fail(f"entry {index} has invalid feature: {feature}")
        if release not in roots:
            fail(f"entry {index} references unknown source release: {release}")
        if not isinstance(source_path, str):
            fail(f"entry {index} source_path must be a string")
        if not isinstance(raw["consumer"], str) or not raw["consumer"].strip():
            fail(f"entry {index} consumer must be non-empty")
        if not isinstance(raw["sha256"], str) or not HEX64.fullmatch(raw["sha256"]):
            fail(f"entry {index} has invalid sha256")
        if not isinstance(raw["needed"], list) or raw["needed"] != sorted(set(raw["needed"])):
            fail(f"entry {index} needed must be sorted and unique")
        if not all(isinstance(item, str) and item for item in raw["needed"]):
            fail(f"entry {index} has invalid needed value")
        shared_with = raw.get("shared_with", [])
        if not isinstance(shared_with, list) or shared_with != sorted(set(shared_with)) or any(item not in FEATURES for item in shared_with):
            fail(f"entry {index} shared_with must be sorted, unique features")
        required_symbols = raw.get("required_symbols", [])
        if not isinstance(required_symbols, list) or required_symbols != sorted(set(required_symbols)) or not all(isinstance(x, str) and x for x in required_symbols):
            fail(f"entry {index} required_symbols must be sorted and unique")
        validate_destination(raw)
        destination = raw["runtime_destination"]
        source_key = (release, source_path)
        if destination in seen_destinations:
            fail(f"duplicate runtime_destination: {destination}")
        if source_key in seen_sources:
            fail(f"duplicate source payload: {release}:{source_path}")
        seen_destinations.add(destination)
        seen_sources.add(source_key)
        path = safe_source(roots[release], source_path)
        actual_hash = sha256(path)
        if actual_hash != raw["sha256"]:
            fail(f"sha256 mismatch for {release}:{source_path}: {actual_hash}")
        metadata = elf_metadata(readelf, path)
        for field in ("elf_class", "machine", "soname", "needed"):
            if raw[field] != metadata[field]:
                fail(f"{field} mismatch for {release}:{source_path}: expected {raw[field]!r}, got {metadata[field]!r}")
        if metadata["elf_class"] not in {"ELF32", "ELF64", "not-elf"}:
            fail(f"unsupported ELF class for {source_path}: {metadata['elf_class']}")
        if metadata["machine"] not in {"AArch64", "ARM", "not-elf"}:
            fail(f"unsupported ELF machine for {source_path}: {metadata['machine']}")
        if metadata["elf_class"] == "not-elf" and (raw["machine"] != "not-elf" or raw["soname"] is not None or raw["needed"]):
            fail(f"non-ELF metadata is inconsistent for {source_path}")
        verified.append({"entry": raw, "path": path, "metadata": metadata})

    providers: dict[tuple[str, str], list[dict[str, Any]]] = {}
    for item in verified:
        raw = item["entry"]
        if raw["elf_class"] == "not-elf":
            continue
        names = {PurePosixPath(raw["source_path"]).name}
        if raw["soname"]:
            names.add(raw["soname"])
        for name in names:
            providers.setdefault((raw["elf_class"], name), []).append(item)

    for item in verified:
        raw = item["entry"]
        direct_providers: list[dict[str, Any]] = []
        for needed in raw["needed"]:
            if needed in allowed_by_feature[raw["feature"]]:
                continue
            matches = providers.get((raw["elf_class"], needed), [])
            same_feature = [match for match in matches if match["entry"]["feature"] == raw["feature"]]
            if same_feature:
                matches = same_feature
            if not matches:
                fail(f"unresolved DT_NEEDED {needed} for {raw['source_path']}")
            hashes = {match["entry"]["sha256"] for match in matches}
            if len(hashes) != 1:
                fail(f"ambiguous providers for {needed} used by {raw['source_path']}")
            provider = matches[0]
            provider_entry = provider["entry"]
            if provider_entry["feature"] != raw["feature"] and raw["feature"] not in provider_entry.get("shared_with", []):
                fail(f"undeclared cross-cohort provider {needed}: {provider_entry['feature']} -> {raw['feature']}")
            direct_providers.append(provider)
        for symbol in raw.get("required_symbols", []):
            if not any(symbol in provider["metadata"]["defined_symbols"] for provider in direct_providers):
                fail(f"required symbol {symbol} has no direct cohort provider for {raw['source_path']}")

    return {
        "schema": SCHEMA,
        "manifest": str(manifest_path.resolve()),
        "complete": manifest.get("complete") is True,
        "entries": len(verified),
        "features": sorted({item["entry"]["feature"] for item in verified}),
        "sha256": sha256(manifest_path),
        "status": "pass",
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--readelf", default=os.environ.get("READELF", "readelf"))
    parser.add_argument("--allow-incomplete", action="store_true")
    parser.add_argument("--json-output", type=Path)
    args = parser.parse_args()
    try:
        report = validate_manifest(args.manifest, args.readelf, args.allow_incomplete)
    except VerificationError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    encoded = json.dumps(report, sort_keys=True, indent=2) + "\n"
    if args.json_output:
        args.json_output.write_text(encoded, encoding="utf-8")
    sys.stdout.write(encoded)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
