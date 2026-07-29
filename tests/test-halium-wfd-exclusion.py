#!/usr/bin/env python3
"""Contract for excluding the incompatible QSSI 15 WFD stack from Halium."""

from __future__ import annotations

import os
import re
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(os.environ.get("HALIUM_ROOT", "/home/lknife/android/rmx1901-halium11"))
DEVICE = ROOT / "device/realme/RMX1901"
VENDOR = ROOT / "vendor/realme/RMX1901"
EXCLUSION_MARKER = "RMX1901_HALIUM_EXCLUDES_QSSI15_WFD"
WFD_DEVICE_COMMIT = "f3aa149c70944bb08fb0b83f74e9022bf1147104"
WFD_VENDOR_COMMIT = "a67bd6fe9f968991e342e26ec3ba6969f45b1e5c"


def top_level_blocks(text: str) -> list[str]:
    blocks: list[str] = []
    depth = 0
    start = 0
    for index, char in enumerate(text):
        if char == "{":
            if depth == 0:
                start = text.rfind("\n", 0, index) + 1
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                blocks.append(text[start : index + 1])
    return blocks


proprietary_lines = (DEVICE / "proprietary-files.txt").read_text().splitlines()
start = proprietary_lines.index(
    "# WiFi Display (system) - from LA.QSSI.15.0.r1-13300-qssi.0"
)
end = next(
    index
    for index in range(start + 1, len(proprietary_lines))
    if proprietary_lines[index].startswith("# WiFi Display (vendor)")
)
wfd_paths = [
    line.split("|", 1)[0].split(";", 1)[0]
    for line in proprietary_lines[start + 1 : end]
    if line and not line.startswith("#")
]
if len(wfd_paths) != 48 or len(wfd_paths[6:]) != 42:
    raise SystemExit("audited QSSI 15 WFD path cohort is no longer 48 entries / WFD42")

bp_blocks = top_level_blocks((VENDOR / "Android.bp").read_text())
cohort_modules: set[str] = set()
for path in wfd_paths[6:]:
    needle = f"proprietary/{path}"
    matching = [block for block in bp_blocks if needle in block]
    names = {
        match.group(1)
        for block in matching
        if (match := re.search(r'name:\s*"([^"]+)"', block))
    }
    if not names:
        raise SystemExit(f"WFD42 path has no generated module mapping: {path}")
    cohort_modules.update(names)

# Service/JAR and generated JNI install helper sit outside the 42 lib/APK paths.
cohort_modules.update(
    {
        "wfdservice",
        "WfdCommon",
        "WfdService",
        "system_ext_priv-app_WfdService_lib_arm64_libwfdnative_so",
        "libwfdservice_shim",
    }
)

script = r'''
set -eo pipefail
source build/envsetup.sh
lunch halium_RMX1901-userdebug >/dev/null
printf '%s\n' '__PACKAGES__'
get_build_var PRODUCT_PACKAGES
printf '%s\n' '__BOOT_JARS__'
get_build_var PRODUCT_BOOT_JARS
printf '%s\n' '__COPY_FILES__'
get_build_var PRODUCT_COPY_FILES
'''
dump = subprocess.check_output(
    ["bash", "-c", script], cwd=ROOT, text=True, stderr=subprocess.STDOUT
)
sections = re.split(r"^__(PACKAGES|BOOT_JARS|COPY_FILES)__\n", dump, flags=re.MULTILINE)
values = {sections[index]: sections[index + 1].strip().split() for index in range(1, len(sections), 2)}

present = sorted(cohort_modules.intersection(values["PACKAGES"]))
if present:
    raise SystemExit(f"Halium PRODUCT_PACKAGES still contains QSSI 15 WFD: {present}")
if "WfdCommon" in values["BOOT_JARS"]:
    raise SystemExit("Halium PRODUCT_BOOT_JARS still contains QSSI 15 WfdCommon")

system_wfd_copy_sources = set(wfd_paths[2:6])
present_copies = sorted(
    item for item in values["COPY_FILES"] if any(source in item for source in system_wfd_copy_sources)
)
if present_copies:
    raise SystemExit(f"Halium PRODUCT_COPY_FILES still contains QSSI 15 WFD: {present_copies}")

product_out = ROOT / "out/target/product/RMX1901"
installed_wfd_paths = [
    product_out / path if path.startswith("system/") else product_out / "system" / path
    for path in wfd_paths
]
installed_wfd_paths.extend(
    product_out / "system/system_ext" / libdir / "libwfdservice_shim.so"
    for libdir in ("lib", "lib64")
)
stale_artifacts = [str(path.relative_to(product_out)) for path in installed_wfd_paths if path.exists()]
if stale_artifacts:
    raise SystemExit(f"Halium product output still installs QSSI 15 WFD: {stale_artifacts}")

required_display_modules = {
    "android.hardware.graphics.composer@2.3-service",
    "hwcomposer.qcom",
    "surfaceflinger",
    "vendor.display.color@1.0-service",
    "wfdhdcphalservice",
    "wfdvndservice",
    "wifidisplayhalservice",
}
missing_display_modules = sorted(required_display_modules - set(values["PACKAGES"]))
if missing_display_modules:
    raise SystemExit(f"Halium WFD filter removed required display/vendor services: {missing_display_modules}")

halium_product = (DEVICE / "halium_RMX1901.mk").read_text()
if f"{EXCLUSION_MARKER} := true" not in halium_product:
    raise SystemExit("WFD exclusion is not owned by the Halium product")
for ordinary_product_file in (DEVICE / "device.mk", DEVICE / "lineage_RMX1901.mk"):
    if EXCLUSION_MARKER in ordinary_product_file.read_text():
        raise SystemExit(f"WFD exclusion leaked into ordinary product logic: {ordinary_product_file}")
vendor_product = (VENDOR / "RMX1901-vendor.mk").read_text()
guard = "ifeq ($(TARGET_PRODUCT),halium_RMX1901)"
if vendor_product.count(guard) != 1:
    raise SystemExit("generated vendor WFD exclusion is not guarded exactly once for Halium")
ordinary_logic, exclusion = vendor_product.split(guard, 1)
if not exclusion.rstrip().endswith("endif"):
    raise SystemExit("Halium WFD exclusion guard does not end at EOF")


def make_list(text: str, variable: str) -> set[str]:
    match = re.search(
        rf"^{re.escape(variable)} := \\\n(?P<body>(?:    .+?(?: \\\n|\n))+)",
        text,
        flags=re.MULTILINE,
    )
    if match is None:
        raise SystemExit(f"missing Make list {variable}")
    return {
        line.strip().removesuffix("\\").strip()
        for line in match.group("body").splitlines()
        if line.strip()
    }


generated_modules = cohort_modules - {"libwfdservice_shim"}
if make_list(exclusion, "RMX1901_QSSI15_WFD_PACKAGES") != generated_modules:
    raise SystemExit("Halium vendor filter is not the exact generated WFD module set")
expected_copy_sources = {f"vendor/realme/RMX1901/proprietary/{path}" for path in wfd_paths[2:6]}
if make_list(exclusion, "RMX1901_QSSI15_WFD_COPY_SOURCES") != expected_copy_sources:
    raise SystemExit("Halium vendor filter is not the exact QSSI 15 WFD copy-file set")
for required_filter in (
    "PRODUCT_PACKAGES := $(filter-out $(RMX1901_QSSI15_WFD_PACKAGES),$(PRODUCT_PACKAGES))",
    "PRODUCT_BOOT_JARS := $(filter-out WfdCommon,$(PRODUCT_BOOT_JARS))",
    "PRODUCT_COPY_FILES := $(filter-out $(foreach source,$(RMX1901_QSSI15_WFD_COPY_SOURCES),$(source):%),$(PRODUCT_COPY_FILES))",
):
    if required_filter not in exclusion:
        raise SystemExit(f"Halium vendor exclusion is missing: {required_filter}")

# The ordinary product declarations remain present before the Halium-only
# filter; no source module or generated blob metadata is deleted.
for module in generated_modules:
    if module not in ordinary_logic:
        raise SystemExit(f"ordinary vendor product lost WFD module {module}")
for source in expected_copy_sources:
    if source not in ordinary_logic:
        raise SystemExit(f"ordinary vendor product lost WFD copy source {source}")
if "PRODUCT_BOOT_JARS += \\\n    WfdCommon" not in ordinary_logic:
    raise SystemExit("ordinary vendor product lost the WfdCommon boot jar")
if "libwfdservice_shim" in (DEVICE / "device.mk").read_text():
    raise SystemExit("obsolete WFD shim is still selected by the Halium device graph")

# The full lineage product cannot currently resolve in this Halium workspace
# because its unrelated non_ab_device.mk is absent. Evaluate the generated
# vendor product directly under an ordinary TARGET_PRODUCT to prove the guard's
# non-Halium branch preserves the original resolved declarations.
ordinary_makefile = f"""
TARGET_PRODUCT := lineage_RMX1901
TARGET_COPY_OUT_SYSTEM_EXT := system_ext
TARGET_COPY_OUT_VENDOR := vendor
TARGET_COPY_OUT_ODM := odm
TARGET_COPY_OUT_PRODUCT := product
include {VENDOR / 'RMX1901-vendor.mk'}
dump:
\t@printf '%s\\n' '__PACKAGES__' '$(PRODUCT_PACKAGES)'
\t@printf '%s\\n' '__BOOT_JARS__' '$(PRODUCT_BOOT_JARS)'
\t@printf '%s\\n' '__COPY_FILES__' '$(PRODUCT_COPY_FILES)'
"""
ordinary_dump = subprocess.check_output(
    ["make", "-s", "-f", "-", "dump"], input=ordinary_makefile, text=True
)
ordinary_sections = re.split(
    r"^__(PACKAGES|BOOT_JARS|COPY_FILES)__\n", ordinary_dump, flags=re.MULTILINE
)
ordinary_values = {
    ordinary_sections[index]: ordinary_sections[index + 1].strip().split()
    for index in range(1, len(ordinary_sections), 2)
}
ordinary_missing = sorted(generated_modules - set(ordinary_values["PACKAGES"]))
if ordinary_missing:
    raise SystemExit(f"ordinary TARGET_PRODUCT filters WFD modules: {ordinary_missing}")
if "WfdCommon" not in ordinary_values["BOOT_JARS"]:
    raise SystemExit("ordinary TARGET_PRODUCT filters the WfdCommon boot jar")
ordinary_copy_sources = {item.split(":", 1)[0] for item in ordinary_values["COPY_FILES"]}
if not expected_copy_sources.issubset(ordinary_copy_sources):
    raise SystemExit("ordinary TARGET_PRODUCT filters QSSI 15 WFD copy files")

port_root = Path(__file__).resolve().parents[1]
mapping_file = port_root / "artifacts/product-audit/halium-qssi15-wfd-exclusion.tsv"
if not mapping_file.is_file():
    raise SystemExit("WFD exclusion has no path-to-module provenance")
mapping_lines = [line for line in mapping_file.read_text().splitlines() if line]
header = mapping_lines[0].removeprefix("# ").split("\t")
mapping_rows = [dict(zip(header, line.split("\t"), strict=True)) for line in mapping_lines[1:]]
if [row["path"] for row in mapping_rows] != wfd_paths:
    raise SystemExit("WFD exclusion provenance is not the exact ordered 48-path cohort")
if len({row["path"] for row in mapping_rows}) != 48:
    raise SystemExit("WFD exclusion provenance contains duplicate paths")
expected_leading_modules = ["WfdCommon", "wfdservice"] + ["COPY_FILE"] * 4
if [row["modules"] for row in mapping_rows[:6]] != expected_leading_modules:
    raise SystemExit("WFD exclusion provenance has wrong JAR/service/copy-file mapping")
for row in mapping_rows[6:]:
    expected_names = set()
    needle = f'proprietary/{row["path"]}'
    for block in bp_blocks:
        if needle in block and (match := re.search(r'name:\s*"([^"]+)"', block)):
            expected_names.add(match.group(1))
    if row["path"] == "system_ext/lib64/libwfdnative.so":
        expected_names.add("system_ext_priv-app_WfdService_lib_arm64_libwfdnative_so")
    if set(row["modules"].split(",")) != expected_names:
        raise SystemExit(f'WFD provenance module mapping changed: {row["path"]}')
expected_actions = [
    "filter package and boot jar",
    "filter package",
    *(["filter copy file"] * 4),
    *(["filter package"] * 22),
    "filter package and JNI install helper",
    *(["filter package"] * 19),
]
if [row["action"] for row in mapping_rows] != expected_actions:
    raise SystemExit("WFD exclusion provenance action mapping changed")

audit = (port_root / "artifacts/product-audit/halium-qssi15-wfd-exclusion.md").read_text()
for required_fact in (
    "Miracast",
    "non-boot-critical",
    "LA.QSSI.15.0.r1-13300-qssi.0",
    "backtrace@LIBC_T",
    "ProcessState15startThreadPoolEv@LIBBINDER",
    "42 paths",
    "28 modules",
    WFD_DEVICE_COMMIT,
    WFD_VENDOR_COMMIT,
):
    if required_fact not in audit:
        raise SystemExit(f"WFD exclusion audit is missing {required_fact}")

manifest = ET.parse(port_root / "manifests/halium11-rmx1901.xml").getroot()
projects = {node.get("path"): node for node in manifest.findall("project")}
expected_pins = {
    "device/realme/RMX1901": ("Lcryolite/device_realme_RMX1901", WFD_DEVICE_COMMIT),
    "vendor/realme/RMX1901": ("Lcryolite/1vendor_realme_RMX1901", WFD_VENDOR_COMMIT),
}
for path, (name, wfd_revision) in expected_pins.items():
    project = projects.get(path)
    if project is None:
        raise SystemExit(f"manifest lost WFD exclusion source {path}")
    if project.get("name") != name or project.get("remote") != "github":
        raise SystemExit(f"manifest has wrong WFD exclusion source identity for {path}")
    manifest_revision = project.get("revision", "")
    ancestry = subprocess.run(
        ["git", "-C", str(ROOT / path), "merge-base", "--is-ancestor", wfd_revision, manifest_revision]
    )
    if ancestry.returncode != 0:
        raise SystemExit(f"manifest pin does not contain tested WFD exclusion source {path}")

print(f"Halium WFD exclusion contract passed: {len(wfd_paths[6:])} paths, {len(cohort_modules)} modules")
