#!/usr/bin/python3
"""Seal one root-owned Recovery/write proof for an RMX1901 M1 attempt.

The writer/control service must populate INBOX before it transitions out of
Recovery.  This program accepts no path, serial, image, or digest from its
caller, and it never contacts or writes a device.
"""
import hashlib
import os
import re
import shutil
import stat
import sys
from pathlib import Path

ROOT = Path("/var/lib/rmx1901-m1-control")
INBOX = ROOT / "preboot-inbox"
PROFILE = ROOT / "preboot-profile"
FILES = ("profile.env", "preflight.env", "boot-unpack.txt", "write-readback.env")


def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(20)


def regular(path):
    try:
        value = path.lstat()
    except OSError:
        return False
    return stat.S_ISREG(value.st_mode) and not stat.S_ISLNK(value.st_mode) and stat.S_IMODE(value.st_mode) == 0o400


def parse_env(path, fields):
    if not regular(path):
        fail("M1 preboot input is missing or unsafe")
    data = {}
    try:
        lines = path.read_text(encoding="ascii").splitlines()
    except (OSError, UnicodeError):
        fail("M1 preboot input is invalid")
    for line in lines:
        if "=" not in line:
            fail("M1 preboot input is invalid")
        key, value = line.split("=", 1)
        if key not in fields or key in data or not re.fullmatch(r"[-A-Za-z0-9 ._/:=+,]*", value):
            fail("M1 preboot input is invalid")
        data[key] = value
    if tuple(data) != fields:
        fail("M1 preboot input is invalid")
    return data


def check_inbox():
    try:
        inbox = INBOX.lstat()
    except OSError:
        fail("M1 preboot inbox is unavailable")
    if not stat.S_ISDIR(inbox.st_mode) or stat.S_ISLNK(inbox.st_mode) or stat.S_IMODE(inbox.st_mode) != 0o700:
        fail("M1 preboot inbox is unsafe")
    if {entry.name for entry in INBOX.iterdir()} != set(FILES):
        fail("M1 preboot inbox has unexpected entries")
    profile = parse_env(INBOX / "profile.env", ("PROFILE_SCHEMA", "INPUT_SHA256", "PREDECESSOR_SHA256", "BOOT_SHA256", "OUTPUT_SHA256"))
    if profile["PROFILE_SCHEMA"] != "RMX1901-M1-PREBOOT-V1" or any(not re.fullmatch(r"[0-9a-f]{64}", profile[key]) for key in tuple(profile)[1:]):
        fail("M1 preboot hash binding is invalid")
    if profile["INPUT_SHA256"] != profile["PREDECESSOR_SHA256"] or profile["BOOT_SHA256"] != profile["OUTPUT_SHA256"]:
        fail("M1 preboot hash binding is invalid")
    preflight = parse_env(INBOX / "preflight.env", ("ADB_STATE", "ADB_SERIAL", "ADB_PRODUCT", "ADB_MODEL", "ADB_DEVICE", "UNLOCKED", "BOOT_PATH", "BOOT_SIZE", "BOOT_MAJOR_MINOR", "BATTERY_PERCENT", "SAFETY_GATE"))
    wanted = {"ADB_STATE":"recovery", "ADB_SERIAL":"7b0c1c49", "ADB_PRODUCT":"fox_RMX1901", "ADB_MODEL":"RMX1901", "ADB_DEVICE":"RMX1901", "UNLOCKED":"YES", "BOOT_PATH":"/dev/block/sde10", "BOOT_SIZE":"67108864", "BOOT_MAJOR_MINOR":"8:4a", "SAFETY_GATE":"PASS"}
    if any(preflight[key] != value for key, value in wanted.items()) or not preflight["BATTERY_PERCENT"].isdigit() or not 50 <= int(preflight["BATTERY_PERCENT"]) <= 100:
        fail("M1 preboot Recovery proof is invalid")
    readback = parse_env(INBOX / "write-readback.env", ("PREDECESSOR_SHA256", "DEVICE_READBACK_SHA256", "HOST_READBACK_SHA256"))
    if any(not re.fullmatch(r"[0-9a-f]{64}", value) for value in readback.values()) or readback["PREDECESSOR_SHA256"] != profile["PREDECESSOR_SHA256"] or readback["DEVICE_READBACK_SHA256"] != profile["BOOT_SHA256"] or readback["HOST_READBACK_SHA256"] != profile["BOOT_SHA256"]:
        fail("M1 preboot readback proof is invalid")
    if not re.fullmatch(r"boot image header version: 1\nadditional command line args: \ncommand line args: .+\nkernel size: [1-9][0-9]*\nramdisk size: [1-9][0-9]*\n", (INBOX / "boot-unpack.txt").read_text(encoding="ascii")):
        fail("M1 preboot boot-unpack proof is invalid")


def fsync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def seal():
    if PROFILE.exists() or PROFILE.is_symlink():
        fail("M1 preboot profile already exists")
    check_inbox()
    temporary = ROOT / "preboot-profile.new"
    if temporary.exists() or temporary.is_symlink():
        fail("M1 preboot profile transaction is incomplete")
    temporary.mkdir(mode=0o700)
    try:
        for name in FILES:
            source, target = INBOX / name, temporary / name
            target.write_bytes(source.read_bytes())
            target.chmod(0o400)
            with target.open("rb") as stream:
                os.fsync(stream.fileno())
        manifest = "".join(f"{hashlib.sha256((temporary / name).read_bytes()).hexdigest()}  {name}\n" for name in sorted(FILES))
        target = temporary / "profile-SHA256SUMS"
        target.write_text(manifest, encoding="ascii"); target.chmod(0o400)
        with target.open("rb") as stream:
            os.fsync(stream.fileno())
        fsync_directory(temporary)
        os.replace(temporary, PROFILE)
        fsync_directory(ROOT)
        shutil.rmtree(INBOX)
        fsync_directory(ROOT)
    except BaseException:
        shutil.rmtree(temporary, ignore_errors=True)
        raise


if __name__ == "__main__":
    if sys.argv[1:] != ["seal"]:
        fail("usage: m1-preboot-profile-generator.py seal")
    os.environ.clear(); os.environ["PATH"] = "/usr/bin:/bin"; os.umask(0o077)
    seal()
