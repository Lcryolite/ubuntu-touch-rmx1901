#!/usr/bin/python3
"""Stage the one locked M1 boot image into the root-owned control plane."""
import hashlib
import json
import os
import re
import stat
import sys
from pathlib import Path

ROOT = Path("/var/lib/rmx1901-m1-control")
CONFIG = ROOT / "m1-deployment-v1.json"
TARGET = ROOT / "m1-candidate.img"


def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(20)


def load_lock():
    try:
        data = json.loads(CONFIG.read_text(encoding="ascii"))
    except (OSError, ValueError):
        fail("M1 deployment lock is unreadable")
    keys = {"schema", "device", "serial", "product", "model", "target", "target_size", "target_major_minor", "predecessor_sha256", "candidate_sha256", "candidate_size"}
    if set(data) != keys or (data["schema"], data["device"], data["serial"], data["product"], data["model"], data["target"], data["target_size"], data["target_major_minor"], data["candidate_size"]) != ("rmx1901-m1-deployment-v1", "RMX1901", "7b0c1c49", "fox_RMX1901", "RMX1901", "/dev/block/sde10", 67108864, "8:4a", 67108864):
        fail("M1 deployment lock is invalid")
    if any(not isinstance(data[key], str) or not re.fullmatch(r"[0-9a-f]{64}", data[key]) for key in ("predecessor_sha256", "candidate_sha256")):
        fail("M1 deployment lock is invalid")
    return data


def stage(source):
    lock = load_lock()
    if os.geteuid() != 0 or TARGET.exists() or TARGET.is_symlink():
        fail("M1 candidate target is unavailable")
    try:
        before = source.lstat()
        fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError:
        fail("M1 candidate source is unavailable")
    try:
        opened = os.fstat(fd)
        if not stat.S_ISREG(opened.st_mode) or stat.S_ISLNK(before.st_mode) or opened.st_size != lock["candidate_size"]:
            fail("M1 candidate source is unsafe")
        target = os.open(TARGET, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o400)
        digest = hashlib.sha256()
        try:
            while True:
                block = os.read(fd, 1024 * 1024)
                if not block:
                    break
                digest.update(block)
                os.write(target, block)
            os.fsync(target)
        finally:
            os.close(target)
        after = source.lstat()
        if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) or digest.hexdigest() != lock["candidate_sha256"]:
            TARGET.unlink(missing_ok=True)
            fail("M1 candidate source changed or does not match lock")
    finally:
        os.close(fd)
    parent = os.open(ROOT, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        os.fsync(parent)
    finally:
        os.close(parent)


if __name__ == "__main__":
    if len(sys.argv) != 2 or not os.path.isabs(sys.argv[1]):
        fail("usage: stage-m1-candidate.py ABSOLUTE_CANDIDATE_IMAGE")
    os.environ.clear(); os.environ["PATH"] = "/usr/bin:/bin"; os.umask(0o077)
    stage(Path(sys.argv[1]))
