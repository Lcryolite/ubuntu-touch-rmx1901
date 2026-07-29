#!/usr/bin/python3
"""The only M1 program allowed to write RMX1901's boot partition.

It consumes the root-owned deployment lock and staged candidate, makes the
Recovery/write/readback proof, then asks the fixed profile sealer to publish
that proof.  It deliberately does not reboot the handset: a sealed profile is
the required hand-off to the separately reviewed runtime witness.
"""
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import struct
from pathlib import Path

ROOT = Path("/var/lib/rmx1901-m1-control")
LOCK = ROOT / "m1-deployment-v1.json"
CANDIDATE = ROOT / "m1-candidate.img"
PREDECESSOR = ROOT / "m1-predecessor.img"
INBOX = ROOT / "preboot-inbox"
SEALER = "/usr/local/libexec/rmx1901-m1-control/seal-preboot-profile"
ADB = "/usr/bin/adb"
EXPECTED_CMDLINE = "console=ttyMSM0,115200n8 earlycon=msm_geni_serial,0xA90000 androidboot.hardware=qcom androidboot.console=ttyMSM0 msm_rtb.filter=0x237 ehci-hcd.park=3 lpm_levels.sleep_disabled=1 service_locator.enable=1 androidboot.configfs=true androidboot.usbcontroller=a600000.dwc3 swiotlb=1 loop.max_part=7 kpti=off printk.devkmsg=on androidboot.init_fatal_reboot_target=recovery systempart=/dev/disk/by-partlabel/system systemd.unified_cgroup_hierarchy=0 console=tty0 rmx1901.debug_rndis=1"

def fail(message):
    print("m1_boot_controller=fail", file=sys.stderr)
    print("error=" + message, file=sys.stderr)
    raise SystemExit(20)

def fixed_regular(path, mode):
    try:
        opened = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
        current, listed = os.fstat(opened), os.lstat(path)
    except OSError:
        fail("fixed root input is unavailable")
    if (not stat.S_ISREG(current.st_mode) or stat.S_ISLNK(listed.st_mode) or
            (current.st_dev, current.st_ino) != (listed.st_dev, listed.st_ino) or
            current.st_uid != 0 or stat.S_IMODE(current.st_mode) != mode):
        os.close(opened); fail("fixed root input is unsafe")
    return opened, current

def read_fixed(path, mode):
    fd, info = fixed_regular(path, mode)
    try:
        chunks = []
        while True:
            block = os.read(fd, 1024 * 1024)
            if not block: break
            chunks.append(block)
        return b"".join(chunks), info
    finally:
        os.close(fd)

def query(args, data=None):
    try:
        run = subprocess.run([ADB, "-s", "7b0c1c49", *args], input=data,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             check=True)
        return run.stdout.decode("ascii").replace("\r", "").strip()
    except Exception:
        fail("ADB fact query or transfer failed")

def device_hash():
    value = query(("shell", "sha256sum", "/dev/block/sde10")).split()
    if len(value) != 2 or value[1] != "/dev/block/sde10" or not re.fullmatch(r"[0-9a-f]{64}", value[0]):
        fail("device hash output is malformed")
    return value[0]

def boot_report(image):
    """Parse the v1 fields sealed into this attempt's preboot proof.

    Keeping this local parser deliberately small makes the root writer
    independent of a mutable unpack_bootimg checkout.  Every byte it reports
    is also protected by the staged candidate digest checked before entry.
    """
    if len(image) < 1648 or image[:8] != b"ANDROID!": fail("candidate boot header is invalid")
    kernel_size = struct.unpack_from("<I", image, 8)[0]
    ramdisk_size = struct.unpack_from("<I", image, 16)[0]
    header_version = struct.unpack_from("<I", image, 40)[0]
    main = image[64:576].split(b"\0", 1)[0]
    extra = image[608:1632].split(b"\0", 1)[0]
    try:
        main = main.decode("ascii"); extra = extra.decode("ascii")
    except UnicodeDecodeError:
        fail("candidate boot command line is invalid")
    if header_version != 1 or extra or main != EXPECTED_CMDLINE or not kernel_size or not ramdisk_size:
        fail("candidate boot header does not meet the M1 cmdline contract")
    return "boot image header version: 1\nadditional command line args: \ncommand line args: {}\nkernel size: {}\nramdisk size: {}\n".format(main, kernel_size, ramdisk_size)

def require_recovery(lock):
    rows = [line.split() for line in query(("devices",)).splitlines()[1:] if line.strip()]
    if rows != [[lock["serial"], "recovery"]]: fail("exactly one Recovery ADB transport is required")
    facts = (("get-serialno", lock["serial"]), ("shell", "getprop", "ro.product.name", lock["product"]),
             ("shell", "getprop", "ro.product.device", lock["device"]), ("shell", "getprop", "ro.product.model", lock["model"]),
             ("shell", "getprop", "ro.bootmode", "recovery"), ("shell", "getprop", "ro.boot.vbmeta.device_state", "unlocked"))
    for fact in facts:
        *command, wanted = fact
        if query(tuple(command)) != wanted: fail("Recovery device identity mismatch")
    target = query(("shell", "readlink", "-f", "/dev/block/by-name/boot"))
    if target != lock["target"] or query(("shell", "stat", "-Lc", "%t:%T", target)) != lock["target_major_minor"] or query(("shell", "blockdev", "--getsize64", target)) != str(lock["target_size"]):
        fail("boot block identity mismatch")
    battery = query(("shell", "cat", "/sys/class/power_supply/battery/capacity"))
    if not battery.isdigit() or not 50 <= int(battery) <= 100: fail("battery safety gate failed")
    return battery

def create_inbox(lock, battery, report):
    if INBOX.exists() or INBOX.is_symlink(): fail("M1 preboot inbox already exists")
    INBOX.mkdir(mode=0o700)
    contents = {
        "profile.env": "PROFILE_SCHEMA=RMX1901-M1-PREBOOT-V1\nINPUT_SHA256={0}\nPREDECESSOR_SHA256={0}\nBOOT_SHA256={1}\nOUTPUT_SHA256={1}\n".format(lock["predecessor_sha256"], lock["candidate_sha256"]),
        "preflight.env": "ADB_STATE=recovery\nADB_SERIAL=7b0c1c49\nADB_PRODUCT=fox_RMX1901\nADB_MODEL=RMX1901\nADB_DEVICE=RMX1901\nUNLOCKED=YES\nBOOT_PATH=/dev/block/sde10\nBOOT_SIZE=67108864\nBOOT_MAJOR_MINOR=8:4a\nBATTERY_PERCENT={0}\nSAFETY_GATE=PASS\n".format(battery),
        "boot-unpack.txt": report,
        "write-readback.env": "PREDECESSOR_SHA256={0}\nDEVICE_READBACK_SHA256={1}\nHOST_READBACK_SHA256={1}\n".format(lock["predecessor_sha256"], lock["candidate_sha256"]),
    }
    try:
        for name, text in contents.items():
            path = INBOX / name
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o400)
            os.write(fd, text.encode("ascii")); os.fsync(fd); os.close(fd)
        fd = os.open(INBOX, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC); os.fsync(fd); os.close(fd)
    except Exception:
        fail("cannot create fixed M1 preboot inbox")

def host_readback(lock):
    try:
        run = subprocess.run([ADB, "-s", lock["serial"], "exec-out", "cat", lock["target"]], stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    except Exception: fail("host-stream boot readback failed")
    return hashlib.sha256(run.stdout).hexdigest()

def restore_predecessor(lock, image):
    """Return the device to the exactly staged predecessor before failing."""
    require_recovery(lock)
    if query(("shell", "tee", "/dev/block/sde10 >/dev/null | wc -c"), image) != str(len(image)):
        fail("candidate readback failed and predecessor restoration was short")
    require_recovery(lock)
    if device_hash() != lock["predecessor_sha256"] or host_readback(lock) != lock["predecessor_sha256"]:
        fail("candidate readback failed and predecessor restoration did not verify")

def main():
    resume = sys.argv[1:] == ["--seal-existing-complete-write"]
    if (sys.argv[1:] not in ([], ["--seal-existing-complete-write"]) or os.geteuid() != 0): fail("root invocation requires no arguments or the fixed sealed-write recovery command")
    if any(name in os.environ for name in ("ADB", "PYTHONPATH", "PYTHONHOME", "LD_PRELOAD", "BASH_ENV", "ENV")): fail("dynamic caller environment is rejected")
    raw, _ = read_fixed(LOCK, 0o400)
    try: lock = json.loads(raw.decode("ascii"))
    except Exception: fail("deployment lock is malformed")
    required = {"schema","device","serial","product","model","target","target_size","target_major_minor","predecessor_sha256","candidate_sha256","candidate_size"}
    wanted = {"schema":"rmx1901-m1-deployment-v1","device":"RMX1901","serial":"7b0c1c49","product":"fox_RMX1901","model":"RMX1901","target":"/dev/block/sde10","target_size":67108864,"target_major_minor":"8:4a","predecessor_sha256":"c4d2b165855f6ec65fb1f606a349192fe254f9e98ad7d4c34d370bcbef08672f","candidate_sha256":"58abf0069b3c37f01779543932a2eee3bc894282778566d1a4f2b77c5e667aec","candidate_size":67108864}
    if set(lock) != required or lock != wanted: fail("deployment lock is not the reviewed M1 release")
    image, info = read_fixed(CANDIDATE, 0o400)
    if info.st_size != lock["candidate_size"] or hashlib.sha256(image).hexdigest() != lock["candidate_sha256"]: fail("staged candidate does not match release lock")
    predecessor, predecessor_info = read_fixed(PREDECESSOR, 0o400)
    if predecessor_info.st_size != lock["target_size"] or hashlib.sha256(predecessor).hexdigest() != lock["predecessor_sha256"]: fail("staged predecessor does not match release lock")
    report = boot_report(image)
    battery = require_recovery(lock)
    if resume:
        if device_hash() != lock["candidate_sha256"] or host_readback(lock) != lock["candidate_sha256"]:
            fail("existing boot is not the completely verified M1 candidate")
        create_inbox(lock, battery, report)
        try: subprocess.run([SEALER, "seal"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
        except Exception: fail("M1 preboot profile could not be sealed")
        print("m1_boot_controller=pass\npreboot_profile=sealed\nwrite_state=resumed-after-dual-readback\nreboot=not-requested")
        return
    if device_hash() != lock["predecessor_sha256"]: fail("boot predecessor hash mismatch")
    require_recovery(lock)
    write_count = query(("shell", "tee", "/dev/block/sde10 >/dev/null | wc -c"), image)
    require_recovery(lock)
    if write_count != str(len(image)) and (device_hash() != lock["candidate_sha256"] or host_readback(lock) != lock["candidate_sha256"]):
        restore_predecessor(lock, predecessor); fail("boot write count was invalid and dual readback failed; predecessor restored")
    if device_hash() != lock["candidate_sha256"]:
        restore_predecessor(lock, predecessor); fail("device-side boot readback hash mismatch; predecessor restored")
    if host_readback(lock) != lock["candidate_sha256"]:
        restore_predecessor(lock, predecessor); fail("host-stream boot readback hash mismatch; predecessor restored")
    create_inbox(lock, battery, report)
    try: subprocess.run([SEALER, "seal"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    except Exception: fail("M1 preboot profile could not be sealed")
    print("m1_boot_controller=pass\npreboot_profile=sealed\nreboot=not-requested")

if __name__ == "__main__": main()
