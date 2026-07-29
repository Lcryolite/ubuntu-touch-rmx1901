#!/usr/bin/env python3
"""Black-box contract for root-owned M1 preboot profile sealing."""
import hashlib
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SOURCE = REPO / "scripts/m1-preboot-profile-generator.py"
TMP = Path(tempfile.mkdtemp(prefix="m1-preboot-profile.", dir=os.environ.get("TMPDIR", "/tmp")))


def put(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(data, encoding="ascii")
    path.chmod(0o400)


try:
    assert SOURCE.exists(), "production preboot profile generator is missing"
    root = TMP / "root"; inbox = root / "preboot-inbox"; inbox.mkdir(parents=True, mode=0o700)
    put(inbox / "profile.env", "PROFILE_SCHEMA=RMX1901-M1-PREBOOT-V1\nINPUT_SHA256=" + "8" * 64 + "\nPREDECESSOR_SHA256=" + "8" * 64 + "\nBOOT_SHA256=" + "3" * 64 + "\nOUTPUT_SHA256=" + "3" * 64 + "\n")
    put(inbox / "preflight.env", "ADB_STATE=recovery\nADB_SERIAL=7b0c1c49\nADB_PRODUCT=fox_RMX1901\nADB_MODEL=RMX1901\nADB_DEVICE=RMX1901\nUNLOCKED=YES\nBOOT_PATH=/dev/block/sde10\nBOOT_SIZE=67108864\nBOOT_MAJOR_MINOR=8:4a\nBATTERY_PERCENT=80\nSAFETY_GATE=PASS\n")
    put(inbox / "boot-unpack.txt", "boot image header version: 1\nadditional command line args: \ncommand line args: console=tty0 systempart=/dev/disk/by-partlabel/system systemd.unified_cgroup_hierarchy=0 rmx1901.debug_rndis=1\nkernel size: 8388608\nramdisk size: 3949319\n")
    put(inbox / "write-readback.env", "PREDECESSOR_SHA256=" + "8" * 64 + "\nDEVICE_READBACK_SHA256=" + "3" * 64 + "\nHOST_READBACK_SHA256=" + "3" * 64 + "\n")
    generator = TMP / "generator.py"
    generator.write_text(SOURCE.read_text().replace('ROOT = Path("/var/lib/rmx1901-m1-control")', f'ROOT = Path("{root}")'))
    generator.chmod(0o500)
    subprocess.run([str(generator), "seal"], check=True)
    profile = root / "preboot-profile"
    assert set(path.name for path in profile.iterdir()) == {"profile.env", "preflight.env", "boot-unpack.txt", "write-readback.env", "profile-SHA256SUMS"}
    assert "BOOT_SHA256=" + "3" * 64 in (profile / "profile.env").read_text()
    assert (profile / "profile-SHA256SUMS").read_text() == "".join(f"{hashlib.sha256((profile / name).read_bytes()).hexdigest()}  {name}\n" for name in sorted(("profile.env", "preflight.env", "boot-unpack.txt", "write-readback.env")))
    repeat = subprocess.run([str(generator), "seal"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert repeat.returncode == 20 and not inbox.exists()
    print("ok - root-owned preboot inbox seals exactly one checksum-bound profile")
finally:
    shutil.rmtree(TMP, ignore_errors=True)
