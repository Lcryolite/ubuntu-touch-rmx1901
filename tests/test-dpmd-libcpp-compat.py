#!/usr/bin/env python3
"""Contract for the libc++ ABI required by the RMX1901 DPM prebuilts."""

from __future__ import annotations

import os
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path


PORT_ROOT = Path(__file__).resolve().parents[1]
ROOT = Path(os.environ.get("HALIUM_ROOT", "/home/lknife/android/rmx1901-halium11"))
SYMBOL = "_ZNSt3__122__libcpp_verbose_abortEPKcz"
LIBCXX_COMMIT = "17c9d2048cf121a25b75e0117332261a9dec9f24"
DPMD = ROOT / "vendor/realme/RMX1901/proprietary/system_ext/bin/dpmd"
VENDOR_BP = ROOT / "vendor/realme/RMX1901/Android.bp"
LIBCXX = ROOT / "external/libcxx"
BUILT_LIBCXX = {
    "arm64 intermediate": ROOT / "out/target/product/RMX1901/obj/SHARED_LIBRARIES/libc++_intermediates/libc++.so",
    "arm intermediate": ROOT / "out/target/product/RMX1901/obj_arm/SHARED_LIBRARIES/libc++_intermediates/libc++.so",
    "arm64 installed": ROOT / "out/target/product/RMX1901/system/lib64/libc++.so",
    "arm installed": ROOT / "out/target/product/RMX1901/system/lib/libc++.so",
    "arm64 vendor VNDK APEX": ROOT / "out/target/product/RMX1901/vendor/apex/com.android.vndk.current.on_vendor/lib64/libc++.so",
    "arm vendor VNDK APEX": ROOT / "out/target/product/RMX1901/vendor/apex/com.android.vndk.current.on_vendor/lib/libc++.so",
}


def command(*args: str) -> str:
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


def module_block(text: str, name: str) -> str:
    marker_at = text.find(f'name: "{name}"')
    if marker_at < 0:
        raise SystemExit(f"Android.bp is missing module {name}")
    start = text.rfind("{", 0, marker_at)
    depth = 0
    for index in range(start, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[start : index + 1]
    raise SystemExit(f"Android.bp module {name} is malformed")


dpmd_symbols = command("readelf", "--dyn-syms", "-W", str(DPMD))
symbol_lines = [line for line in dpmd_symbols.splitlines() if SYMBOL in line]
if symbol_lines:
    raise SystemExit("API30 dpmd unexpectedly retains the superseded verbose-abort import")

needed = command("readelf", "-d", str(DPMD))
if "Shared library: [libc++.so]" not in needed:
    raise SystemExit("dpmd does not load the platform libc++.so at runtime")

consumers = 0
providers = 0
for blob in (ROOT / "vendor/realme/RMX1901/proprietary").rglob("*"):
    if not blob.is_file():
        continue
    try:
        symbols = command("readelf", "--dyn-syms", "-W", str(blob))
    except subprocess.CalledProcessError:
        continue
    matching = [line for line in symbols.splitlines() if SYMBOL in line]
    consumers += any(" UND " in line for line in matching)
    providers += any(" UND " not in line for line in matching)
if (consumers, providers) != (37, 0):
    raise SystemExit(
        f"verbose-abort blob cohort changed: {consumers} consumers, {providers} providers"
    )

dpmd_module = module_block(VENDOR_BP.read_text(encoding="utf-8"), "dpmd")
for forbidden in ("allow_undefined_symbols", "check_elf_files: false"):
    if forbidden in dpmd_module:
        raise SystemExit(f"dpmd weakens ELF validation with {forbidden}")

implementation = LIBCXX / "src/verbose_abort.cpp"
if not implementation.is_file():
    raise SystemExit("Android 11 libc++ has no verbose-abort compatibility implementation")
source = implementation.read_text(encoding="utf-8")
for required in (
    "__libcpp_verbose_abort",
    "_LIBCPP_FUNC_VIS",
    "va_start",
    "vfprintf",
    "abort",
):
    if required not in source:
        raise SystemExit(f"verbose-abort compatibility implementation is missing {required}")

libcxx_module = module_block((LIBCXX / "Android.bp").read_text(encoding="utf-8"), "libc++_static")
if '"src/verbose_abort.cpp"' not in libcxx_module:
    raise SystemExit("libc++_static does not compile verbose_abort.cpp")

for arch, built_libcxx in BUILT_LIBCXX.items():
    if not built_libcxx.is_file():
        raise SystemExit(f"focused build has not produced {arch} platform libc++.so")
    built_symbols = command("readelf", "--dyn-syms", "-W", str(built_libcxx))
    providers = [
        line for line in built_symbols.splitlines() if SYMBOL in line and " UND " not in line
    ]
    if len(providers) != 1:
        raise SystemExit(
            f"built Android 11 {arch} libc++.so does not export the verbose-abort ABI"
        )

manifest = ET.parse(PORT_ROOT / "manifests/halium11-rmx1901.xml").getroot()
projects = {project.get("path"): project for project in manifest.findall("project")}
libcxx_project = projects.get("external/libcxx")
if libcxx_project is None:
    raise SystemExit("manifest does not replace external/libcxx with the compatibility fork")
if libcxx_project.get("name") != "Lcryolite/android_external_libcxx":
    raise SystemExit("manifest external/libcxx does not use the published compatibility fork")
if libcxx_project.get("revision") != LIBCXX_COMMIT:
    raise SystemExit("manifest external/libcxx is not pinned to the tested compatibility commit")
if libcxx_project.get("remote") != "github" or libcxx_project.get("groups") != "pdk":
    raise SystemExit("manifest external/libcxx does not preserve its remote/groups contract")
removed_libcxx = [
    node for node in manifest.findall("remove-project") if node.get("path") == "external/libcxx"
]
if len(removed_libcxx) != 1:
    raise SystemExit("manifest must remove the upstream external/libcxx exactly once")

provenance = (PORT_ROOT / "artifacts/product-audit/dpmd-libcpp-compat.md").read_text()
for fact in (
    "8f289a051a9917e998e813db8da01de6a519cacc7056338136a08f7093e92dd8",
    "ac862e9c1ae4f8f875dee312e6840d08",
    "45 consumers, 0 providers",
    "37 consumers, 0 providers",
    "7ed535a997d679dc32406969f708f2ea2430c46b17927f96ecd1f63fb3138c52",
    LIBCXX_COMMIT,
    "m -j8 dpmd",
):
    if fact not in provenance:
        raise SystemExit(f"dpmd libc++ provenance is missing {fact}")

print("dpmd libc++ compatibility contract tests passed")
