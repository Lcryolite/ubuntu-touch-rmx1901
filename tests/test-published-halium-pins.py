#!/usr/bin/env python3
"""Static contract for published Halium platform repositories."""

from __future__ import annotations

import hashlib
import re
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "manifests/halium11-rmx1901.xml"
LOCK = ROOT / "artifacts/product-audit/halium-patchset.lock.tsv"
PINS = ROOT / "artifacts/product-audit/halium-published-pins.tsv"
EVIDENCE = ROOT / "artifacts/product-audit/system-core-filter"
BASE_EVIDENCE = ROOT / "artifacts/product-audit/frameworks-base-snapshot"
FULL_SHA = re.compile(r"[0-9a-f]{40}")
PATCHSET_SHA = "0b07bd1d2f0a8468b2b101bddfc9c4cba14edde0"

EXPECTED = {
    "art": ("Lcryolite/android_art", "70edec040ae3fcee67de5f497614f7110a195fb3"),
    "bionic": ("Lcryolite/android_bionic", "f0abd0b66ae263d4b12018a285c5c447e1150d48"),
    "build/make": ("Lcryolite/android_build", "7a4350d43dacffa104d0e870d49748d4ef5c77da"),
    "build/soong": ("Lcryolite/android_build_soong", "a1d78590189fe5c8edd6c0c690b983d0acc8dbf7"),
    "external/e2fsprogs": ("Lcryolite/android_external_e2fsprogs", "c03900b3f7247981f4f0e768cfd5bdf288964143"),
    "frameworks/av": ("Lcryolite/android_frameworks_av", "d386f41c90b53de58db814f3afdce48acae649af"),
    "frameworks/base": ("Lcryolite/android_frameworks_base", "d46b623b60d9dcf1496b0e131433d92f09853c89"),
    "frameworks/native": ("Lcryolite/android_frameworks_native", "3804c142675cdc6fb3c7dbfc3df907433881bfcf"),
    "hardware/libhardware": ("Lcryolite/android_hardware_libhardware", "9ac5435fac5e2a607909f73813bb9693896af0f4"),
    "system/core": ("Lcryolite/android_system_core", "2aedd07dfd2c6321b87b37d3ec3911f9d626c155"),
    "system/hwservicemanager": ("Lcryolite/android_system_hwservicemanager", "9160d7ccf6cbf82bf217fb439dbb477cc6dd0c5b"),
    "system/libhwbinder": ("Lcryolite/android_system_libhwbinder", "e161180057bc9f838f0219d85feadc09b7a97ed0"),
    "system/linkerconfig": ("Lcryolite/android_system_linkerconfig", "37321b97a57bf25bb6691c9489949b72ed7cbfd1"),
    "system/vold": ("Lcryolite/android_system_vold", "48a323c23fd3d722005ac01390df09e5a47d536c"),
}
EXPECTED_GROUPS = {
    "art": "pdk",
    "bionic": "pdk",
    "build/make": "pdk",
    "build/soong": "pdk,tradefed",
    "external/e2fsprogs": "pdk",
    "frameworks/av": "pdk",
    "frameworks/base": "pdk-cw-fs,pdk-fs",
    "frameworks/native": "pdk",
    "hardware/libhardware": "pdk",
    "system/core": "pdk",
    "system/hwservicemanager": "pdk",
    "system/libhwbinder": "pdk",
    "system/linkerconfig": "pdk",
    "system/vold": "pdk",
}
SYSTEM_CORE_ORIGINAL = "0e5b3ab86ac24f358e11f5369ecc73dde56f70a9"
SYSTEM_CORE_TREE = "bd57f1e43379a75c56761a1f68d77e3ecd875ff0"
FRAMEWORKS_BASE_ORIGINAL = "d2d1d34403aa92a1f2a31364f2bae12ea72679c2"
FRAMEWORKS_BASE_ORIGINAL_BASE = "557ec5dffbd8464d054931f890c1b51a0b76039b"
FRAMEWORKS_BASE_SNAPSHOT = "04ad6f9475a33c97779ecd1e0569baf15c510083"
FRAMEWORKS_BASE_BASE_TREE = "d2383c3ec04ee8c088d63c798931308862e0b4d9"
FRAMEWORKS_BASE_FINAL_TREE = "7961e45d94b8859066be3f1f03b4f95bf10d93e3"
FRAMEWORKS_BASE_PATCH_ID = "281195f81060e3b8fbd6d7e1359c4b3df66a5370"
REMOVED_BLOB = "70352dbb7a51e338096bb1305ea63641a39200cd"
COMMIT_MAP_SHA256 = "590393e700361626c8192de6e59d817c88be372e23bf56751607ca0dc537d073"
PROVENANCE_SHA256 = "3269c3ac6a0bacc677203c1ceba7bc1b4f5557bd96a1285bd2a5e5f3a6cc99c6"
PATCH_IDS = [
    "9f867452d9ef057d2ef172e1b4e3c4bb57e559c5",
    "ad7fbde94428b72501e20227d79d32792536fd83",
    "ab3bce7eff7d9f83bd2fe1bc96562cc7a477324e",
    "2efe38a741855f0a80d544c46c7e52d3f83e1453",
    "618837181320d2478167c6c009141a7d0ce1a45a",
    "510ec79bd37d762415acbb7f3d57970eb676b61a",
    "02640c7c1bb8f008db1d366bd4381ab8a63f87b3",
    "fd7c74e9a52c92aaaad2b8796a371374ab67a6a3",
    "bae44b13d75d3a449128dbd85ca2cea92d5409b1",
    "dd40f781fef59757ca1148034eab095eb9cb73fd",
    "1e218dd0365b0333807c0b691ee4f4f4e1958bf9",
    "1c776ddf6b498da1202e73a89bfc77e66f0c7139",
    "a5ec8addc68e5308bf05643c516b4760ccdf78e6",
    "540fe5880f9bf0643e4adb8a3939836fb06cc26f",
    "3abd5e54dc37c795bdb98380263312368a36b1eb",
    "6164cf3dadf3371e927a5f5c6b582468bc76edd5",
    "a102134fc94574f1b4fcd4936263ec268e2a773a",
]

def read_tsv(path: Path) -> list[dict[str, str]]:
    lines = [line for line in path.read_text(encoding="utf-8").splitlines() if line]
    header = lines[0].removeprefix("# ").split("\t")
    return [dict(zip(header, line.split("\t"), strict=True)) for line in lines[1:]]


root = ET.parse(MANIFEST).getroot()
manifest_projects = root.findall("project")
removed_paths = [node.attrib.get("path") for node in root.findall("remove-project")]
expected_removed_paths = set(EXPECTED) | {"external/libcxx", "device/lineage/sepolicy"}
if len(removed_paths) != len(set(removed_paths)) or set(removed_paths) != expected_removed_paths:
    raise SystemExit("local manifest must remove each upstream platform path exactly once")
paths = [project.attrib["path"] for project in manifest_projects]
if len(paths) != len(set(paths)):
    raise SystemExit("manifest contains duplicate project paths")
projects = {project.attrib["path"]: project.attrib for project in manifest_projects}
project_nodes = {project.attrib["path"]: project for project in manifest_projects}

missing = sorted(set(EXPECTED) - set(projects))
if missing:
    raise SystemExit(f"manifest is missing published Halium pins: {missing}")
for path, (name, revision) in EXPECTED.items():
    project = projects[path]
    if project.get("remote") != "github":
        raise SystemExit(f"{path}: published project must use github remote")
    if project.get("name") != name:
        raise SystemExit(f"{path}: project name is not {name}")
    if project.get("revision") != revision or FULL_SHA.fullmatch(revision) is None:
        raise SystemExit(f"{path}: manifest is not pinned to published full SHA {revision}")
    if project.get("groups") != EXPECTED_GROUPS[path]:
        raise SystemExit(f"{path}: replacement project does not preserve upstream groups")

expected_links = {
    "build/make": [
        ("copyfile", "core/root.mk", "Makefile"),
        ("linkfile", "CleanSpec.mk", "build/CleanSpec.mk"),
        ("linkfile", "buildspec.mk.default", "build/buildspec.mk.default"),
        ("linkfile", "core", "build/core"),
        ("linkfile", "envsetup.sh", "build/envsetup.sh"),
        ("linkfile", "target", "build/target"),
        ("linkfile", "tools", "build/tools"),
    ],
    "build/soong": [
        ("linkfile", "root.bp", "Android.bp"),
        ("linkfile", "bootstrap.bash", "bootstrap.bash"),
    ],
}
for path, expected_children in expected_links.items():
    actual_children = [
        (child.tag, child.attrib.get("src"), child.attrib.get("dest"))
        for child in project_nodes[path]
    ]
    if actual_children != expected_children:
        raise SystemExit(f"{path}: replacement project does not preserve build root links")

patch_sources = [
    node.attrib
    for node in root.findall("extend-project")
    if node.attrib.get("path") == "hybris-patches"
]
if len(patch_sources) != 1:
    raise SystemExit("manifest must extend the existing hybris-patches source exactly once")
patch_source = patch_sources[0]
if patch_source.get("name") != "Halium/hybris-patches":
    raise SystemExit("hybris-patches source does not use the official Halium repository")
if patch_source.get("revision") != PATCHSET_SHA:
    raise SystemExit("hybris-patches source revision is not fixed to the audited patchset")

lock_rows = read_tsv(LOCK)
lock = {row["path"]: row for row in lock_rows}
if len(lock) != len(lock_rows) or set(lock) != set(EXPECTED):
    raise SystemExit("patchset lock must contain each published repository exactly once")
if [row["path"] for row in lock_rows] != sorted(EXPECTED):
    raise SystemExit("patchset lock repository paths are not sorted")
if sum(int(row["patch_count"]) for row in lock_rows) != 61:
    raise SystemExit("patchset lock must account for exactly 61 patches")

pin_rows = read_tsv(PINS)
pins = {row["path"]: row for row in pin_rows}
if len(pins) != len(pin_rows) or set(pins) != set(EXPECTED):
    raise SystemExit("published pin provenance must contain 14 unique repositories")
if [row["path"] for row in pin_rows] != sorted(EXPECTED):
    raise SystemExit("published pin provenance repository paths are not sorted")
for path, (name, published) in EXPECTED.items():
    row = pins[path]
    if row["name"] != name or row["published_head"] != published:
        raise SystemExit(f"{path}: provenance differs from manifest publication")
    if row["original_head"] != lock[path]["head"]:
        raise SystemExit(f"{path}: provenance differs from original patchset lock")
    if row["patch_count"] != lock[path]["patch_count"]:
        raise SystemExit(f"{path}: provenance patch count differs from lock")
    if path not in {"frameworks/base", "system/core"} and row["original_head"] != row["published_head"]:
        raise SystemExit(f"{path}: unexpected publication rewrite")

base = pins["frameworks/base"]
if base["original_head"] != FRAMEWORKS_BASE_ORIGINAL:
    raise SystemExit("frameworks/base original head is not preserved in provenance")
if base["published_head"] != EXPECTED["frameworks/base"][1]:
    raise SystemExit("frameworks/base snapshot publication head is incorrect")

core = pins["system/core"]
if core["original_head"] != SYSTEM_CORE_ORIGINAL:
    raise SystemExit("system/core original head is not preserved in provenance")
if core["published_head"] != EXPECTED["system/core"][1]:
    raise SystemExit("system/core filtered publication head is incorrect")

audit_rows = read_tsv(EVIDENCE / "system-core-filter-audit.tsv")
audit = {(row["kind"], row["key"]): row["value"] for row in audit_rows}
expected_audit = {
    ("source", "hybris_patches_revision"): PATCHSET_SHA,
    ("history", "original_head"): SYSTEM_CORE_ORIGINAL,
    ("history", "published_head"): EXPECTED["system/core"][1],
    ("tree", "original"): SYSTEM_CORE_TREE,
    ("tree", "published"): SYSTEM_CORE_TREE,
    ("removed_blob", "oid"): REMOVED_BLOB,
    ("removed_blob", "size"): "229696508",
    ("removed_blob", "path"): "libunwindstack/tests/files/offline/jit_debug_x86_32/libartd.so",
    ("commit_map", "sha256"): COMMIT_MAP_SHA256,
    ("commit_map", "bytes"): "4921767",
    ("commit_map", "lines"): "60022",
    ("patches", "count"): "17",
}
if audit != expected_audit:
    raise SystemExit("system/core filter audit metadata differs from the approved evidence")

base_evidence_hashes = {
    "final-tree-diff.txt": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    "github-large-object-verification.txt": "13d88971ab26daa62f94d18dba3fe25e8044f19706f45cba4094b15973718cd8",
    "github-push-result.txt": "923c6513c5f0e6a3f2bcc7b2abfff206aadf3c347112b434f2f2adb20ff272a3",
    "largest-reachable-blobs.txt": "bab9ef5eb0723466a4e79a5bdf178399ceb5113d6803d5b58dbdda1e0ff50510",
    "pack-estimate.txt": "a2dab677eea071ca6f6057eaff17b2e7093be8c9a7b5b492110821133fedbf06",
    "revisions.txt": "532be3c3a542cc34cd082b8719a817136b75f7d77a92d14b3d8614f1af1407c6",
    "patch-provenance.txt": "41072b4548322788765f03e8f485091a66cc1845068b4cc36831cf6a6afa3974",
    "remote-verification.txt": "9cb7bdc5929b1dd80a1a25006295002328da77ac535cc2655b9a5688bde20fbf",
    "snapshot-root.txt": "f7b4d0818a209e4fabd523038fca2862b149bbc4c1a5bff82973624392aa3bdd",
    "tree-verification.txt": "f3a02ac91565fc3bdd950c26178ae2b66eb29d06760152a8456ac483f687751b",
}
for filename, expected_hash in base_evidence_hashes.items():
    evidence_file = BASE_EVIDENCE / filename
    if not evidence_file.is_file():
        raise SystemExit(f"frameworks/base audit evidence is missing: {filename}")
    actual_hash = hashlib.sha256(evidence_file.read_bytes()).hexdigest()
    if actual_hash != expected_hash:
        raise SystemExit(f"frameworks/base audit evidence changed: {filename}")

base_mapping = read_tsv(BASE_EVIDENCE / "frameworks-base-commit-provenance.tsv")
expected_base_mapping = [
    {
        "role": "baseline_snapshot",
        "original_commit": FRAMEWORKS_BASE_ORIGINAL_BASE,
        "published_commit": FRAMEWORKS_BASE_SNAPSHOT,
        "tree": FRAMEWORKS_BASE_BASE_TREE,
        "patch_id": "-",
    },
    {
        "role": "halium_patch",
        "original_commit": FRAMEWORKS_BASE_ORIGINAL,
        "published_commit": EXPECTED["frameworks/base"][1],
        "tree": FRAMEWORKS_BASE_FINAL_TREE,
        "patch_id": FRAMEWORKS_BASE_PATCH_ID,
    },
]
if base_mapping != expected_base_mapping:
    raise SystemExit("frameworks/base two-commit publication mapping differs from audit")

provenance_file = EVIDENCE / "halium-provenance.tsv"
if hashlib.sha256(provenance_file.read_bytes()).hexdigest() != PROVENANCE_SHA256:
    raise SystemExit("system/core Halium provenance is not an exact copy of the audit evidence")
provenance = [
    dict(zip(("original_commit", "published_commit", "subject"), line.split("\t"), strict=True))
    for line in provenance_file.read_text(encoding="utf-8").splitlines()
    if line
]
integrity = read_tsv(EVIDENCE / "system-core-patch-integrity.tsv")
if len(provenance) != 17 or len(integrity) != 17:
    raise SystemExit("system/core evidence must contain all 17 Halium patches")
if [row["patch_id"] for row in integrity] != PATCH_IDS:
    raise SystemExit("system/core stable patch IDs changed during filtering")
for number, (mapping, item) in enumerate(zip(provenance, integrity, strict=True), start=1):
    if item["sequence"] != f"{number:02d}":
        raise SystemExit("system/core patch integrity sequence is not sorted")
    if item["original_commit"] != mapping["original_commit"]:
        raise SystemExit("system/core original commit mapping differs between evidence files")
    if item["published_commit"] != mapping["published_commit"]:
        raise SystemExit("system/core published commit mapping differs between evidence files")

print("Published Halium pin contract tests passed: 14 repositories, 61 ordered patches")
