#!/usr/bin/env python3
import pathlib
import sys

required = {
    "CONFIG_ANDROID_BINDER_IPC=y",
    "CONFIG_SECURITY_APPARMOR=y",
    "CONFIG_CGROUPS=y",
    "CONFIG_BLK_DEV_LOOP=y",
    "CONFIG_CC_STACKPROTECTOR_STRONG=y",
    "CONFIG_FUSE_FS=y",
    "CONFIG_DEVTMPFS=y",
    "CONFIG_TMPFS=y",
    "CONFIG_EXT4_FS=y",
}
actual = set(pathlib.Path(sys.argv[1]).read_text().splitlines())
missing = sorted(required - actual)
forbidden = sorted(
    line
    for line in actual
    if line.startswith("CONFIG_")
    and any(token in line.lower() for token in ("resukisu", "sukisu", "kernelsu", "config_ksu="))
)
if missing or forbidden:
    if missing:
        print("\n".join(missing))
    for line in forbidden:
        print(f"forbidden kernel config: {line}")
    raise SystemExit(1)
print("kernel config requirements passed")
