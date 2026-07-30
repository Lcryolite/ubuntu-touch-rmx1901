#!/usr/bin/env python3
"""Emit the hash-pinned, strict API30 closure for the core RMX1901 Wi-Fi HAL."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

NEEDED = re.compile(r"\(NEEDED\).*\[([^]]+)]")
SONAME = re.compile(r"\(SONAME\).*\[([^]]+)]")
BIONIC = {"libc.so", "libdl.so", "libm.so"}


def dynamic(path: Path) -> tuple[list[str], str | None]:
    text = subprocess.check_output(["readelf", "-dW", str(path)], text=True)
    needed = sorted({match.group(1) for line in text.splitlines() if (match := NEEDED.search(line))})
    sonames = [match.group(1) for line in text.splitlines() if (match := SONAME.search(line))]
    if len(sonames) > 1:
        raise SystemExit(f"multiple SONAME values: {path}")
    return needed, sonames[0] if sonames else None


def metadata(path: Path) -> tuple[str, str]:
    with path.open("rb") as stream:
        magic = stream.read(4)
    if magic != b"\x7fELF":
        return "not-elf", "not-elf"
    text = subprocess.check_output(["readelf", "-hW", str(path)], text=True)
    if "Class:                             ELF64" not in text or "Machine:                           AArch64" not in text:
        raise SystemExit(f"not an AArch64 ELF64 payload: {path}")
    return "ELF64", "AArch64"


def destination(relative: Path, elf_class: str) -> str:
    """Map every private payload to the service-only runtime layout.

    The Android linker only needs SONAME basenames in the service-local
    library directory.  Keeping all ABI providers there avoids bind-mounting
    any API30 file over global /system or /vendor paths.
    """
    if elf_class != "not-elf":
        if relative.parts[:3] == ("vendor", "bin", "hw"):
            return f"/userdata/rmx1901-hw/wifi/bin/hw/{relative.name}"
        return f"/userdata/rmx1901-hw/wifi/lib64/{relative.name}"
    return f"/userdata/rmx1901-hw/wifi/{relative.as_posix()}"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rui-root", type=Path, required=True)
    parser.add_argument("--product-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    rui, product = args.rui_root.resolve(), args.product_root.resolve()
    starts = [
        rui / "vendor/bin/hw/android.hardware.wifi@1.0-service",
        rui / "vendor/lib64/libwifi-hal-ctrl.so", rui / "vendor/lib64/libwifi-hal-qcom.so",
        rui / "vendor/lib64/libwifi-hal.so", rui / "vendor/lib64/libwpa_client.so",
        rui / "vendor/lib64/vendor.oplus.hardware.wifi.powersystem@1.0.so",
        product / "vendor/lib64/libcld80211.so",
        rui / "vendor/etc/init/android.hardware.wifi@1.0-service.rc",
        rui / "vendor/etc/vintf/manifest/android.hardware.wifi@1.0-service.xml",
    ]
    for path in starts:
        if not path.is_file():
            raise SystemExit(f"missing required core Wi-Fi payload: {path}")
    roots = [
        rui / "vendor/lib64", rui / "vendor/euclid/odm/lib64", product / "vendor/lib64",
        product / "system/lib64", product / "system/apex/com.android.vndk.current/lib64",
        product / "vendor/apex/com.android.vndk.current.on_vendor/lib64", product / "system/lib64/bootstrap",
    ]
    providers: dict[str, list[Path]] = {}
    for root in roots:
        for path in root.glob("*.so") if root.is_dir() else ():
            if path.is_file() and path.read_bytes()[:4] == b"\x7fELF":
                providers.setdefault(path.name, []).append(path)
    queue, selected = list(starts), {}
    while queue:
        path = queue.pop(0)
        if path.name in selected:
            continue
        selected[path.name] = path
        if metadata(path)[0] == "not-elf":
            continue
        for name in dynamic(path)[0]:
            if name not in BIONIC:
                try:
                    queue.append(providers[name][0])
                except KeyError as exc:
                    raise SystemExit(f"unresolved DT_NEEDED {name} required by {path}") from exc
    entries = []
    for _, path in sorted(selected.items(), key=lambda item: str(item[1])):
        root, release = (rui, "rmx1901-rui2-qssi-api30-f97fae29") if path.is_relative_to(rui) else (product, "halium11-api30-product-out-20260730")
        relative = path.relative_to(root)
        if metadata(path)[0] == "not-elf":
            needed, soname = [], None
        else:
            needed, soname = dynamic(path)
        elf_class, machine = metadata(path)
        entry = {"consumer": "RMX1901 core Wi-Fi HIDL service API30 private closure", "elf_class": elf_class,
                 "feature": "wifi", "machine": machine, "needed": needed,
                 "runtime_destination": destination(relative, elf_class),
                 "sha256": hashlib.file_digest(path.open("rb"), "sha256").hexdigest(), "soname": soname,
                 "source_path": f"/{relative}", "source_release": release}
        if path.name == "libwifi-hal.so":
            entry["required_symbols"] = ["WriteStringToFd"]
        entries.append(entry)
    manifest = {"allowed_system_libraries": {feature: ([] if feature != "wifi" else sorted(BIONIC)) for feature in ("audio", "bluetooth", "camera", "dsp", "wifi")},
                "complete": True, "entries": entries, "schema": "rmx1901-hardware-cohorts-v1",
                "source_roots": {"halium11-api30-product-out-20260730": str(product), "rmx1901-rui2-qssi-api30-f97fae29": str(rui)},
                "strict_features": ["wifi"]}
    if args.output.exists():
        raise SystemExit(f"refusing to overwrite existing output: {args.output}")
    args.output.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(f"entries={len(entries)} output={args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
