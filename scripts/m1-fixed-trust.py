#!/usr/bin/python3
"""Validate the fixed root-owned M1 witness trust bootstrap."""

import hashlib
import os
import re
import stat
import subprocess
import sys
from pathlib import Path


"""The persistent root is deliberately outside /run.

Receipt-chain continuity, seen boot IDs and the signing key must survive a
reboot.  There is no mutable /run projection for this control plane: the gate
and systemd execute the same immutable libexec witness directly.
"""

ROOT = Path("/var/lib/rmx1901-m1-control")
WITNESS = Path("/usr/local/libexec/rmx1901-m1-control/capture-witness")
WITNESS_SHA = ROOT / "capture-witness.sha256"
ADAPTER = Path("/usr/local/libexec/rmx1901-m1-control/runtime-adapter")
ADAPTER_SHA = ROOT / "runtime-adapter.sha256"
PRIVATE_KEY = ROOT / "witness-ed25519.pem"
PUBLIC_KEY = ROOT / "witness-ed25519.pub"
PUBLIC_KEY_SHA = ROOT / "witness-ed25519.sha256"
REGISTRY = ROOT / "registry"
RECEIPTS = REGISTRY / "receipts"
STATE = ROOT / "state"
INITIAL_NAMESPACE_MAP = ["0", "0", "4294967295"]


def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(20)


def ancestors(path):
    current = Path("/")
    yield current
    for part in path.parts[1:]:
        current /= part
        yield current


def trusted(path, kind, executable=False, exact_mode=None):
    if not path.is_absolute() or path != Path(os.path.normpath(path)):
        fail(f"fixed M1 trust path is invalid: {path}")
    for component in ancestors(path):
        try:
            value = component.lstat()
        except OSError:
            fail(f"fixed M1 trust path is unavailable: {path}")
        if stat.S_ISLNK(value.st_mode):
            fail(f"fixed M1 trust path contains a symlink: {component}")
        if value.st_uid != 0:
            fail(f"fixed M1 trust path is not UID 0 owned: {component}")
        if value.st_mode & 0o022:
            fail(f"fixed M1 trust path is group/world writable: {component}")
    value = path.lstat()
    if kind == "file" and not stat.S_ISREG(value.st_mode):
        fail(f"fixed M1 trust object is not a regular file: {path}")
    if kind == "directory" and not stat.S_ISDIR(value.st_mode):
        fail(f"fixed M1 trust object is not a directory: {path}")
    if executable and not value.st_mode & stat.S_IXUSR:
        fail(f"fixed M1 witness is not executable: {path}")
    if exact_mode is not None and stat.S_IMODE(value.st_mode) != exact_mode:
        fail(f"fixed M1 trust mode is invalid: {path}")


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def pinned(path, fingerprint):
    try:
        raw = fingerprint.read_text(encoding="ascii")
    except (OSError, UnicodeError):
        fail(f"fixed M1 fingerprint is unreadable: {fingerprint}")
    if not re.fullmatch(r"[0-9a-f]{64}\n", raw):
        fail(f"fixed M1 fingerprint is malformed: {fingerprint}")
    if digest(path) != raw[:-1]:
        fail(f"fixed M1 object fingerprint mismatch: {path}")


def require_initial_user_namespace():
    """Reject UID 0 manufactured by an unprivileged user namespace.

    Ownership checks alone are insufficient: a caller can map its ordinary
    host UID to namespace UID 0 and build a private, apparently root-owned
    /run.  The installed witness is trusted only in the initial full-range
    UID and GID mappings.
    """
    for name in ("uid_map", "gid_map"):
        path = Path("/proc/self") / name
        try:
            fields = path.read_text(encoding="ascii").split()
        except (OSError, UnicodeError):
            fail(f"fixed M1 trust cannot read current {name}")
        if fields != INITIAL_NAMESPACE_MAP:
            fail("fixed M1 trust bootstrap rejects a non-initial user namespace")


def main():
    if len(sys.argv) != 2 or sys.argv[1] != "check":
        fail("invalid fixed M1 trust validation command")
    require_initial_user_namespace()
    if os.geteuid() != 0:
        fail("fixed M1 trust bootstrap requires UID 0 control plane")
    trusted(ROOT, "directory", exact_mode=0o700)
    trusted(WITNESS, "file", executable=True, exact_mode=0o500)
    trusted(WITNESS_SHA, "file", exact_mode=0o400)
    trusted(ADAPTER, "file", executable=True, exact_mode=0o500)
    trusted(ADAPTER_SHA, "file", exact_mode=0o400)
    trusted(PRIVATE_KEY, "file", exact_mode=0o400)
    trusted(PUBLIC_KEY, "file", exact_mode=0o400)
    trusted(PUBLIC_KEY_SHA, "file", exact_mode=0o400)
    trusted(REGISTRY, "directory", exact_mode=0o700)
    trusted(RECEIPTS, "directory", exact_mode=0o700)
    trusted(STATE, "directory", exact_mode=0o700)
    pinned(WITNESS, WITNESS_SHA)
    pinned(ADAPTER, ADAPTER_SHA)
    pinned(PUBLIC_KEY, PUBLIC_KEY_SHA)
    key = subprocess.run(
        ["/usr/bin/openssl", "pkey", "-pubin", "-in", str(PUBLIC_KEY), "-text", "-noout"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
    )
    if key.returncode != 0 or not key.stdout.startswith("ED25519 Public-Key:\n"):
        fail("fixed M1 witness public key is not Ed25519")
    private = subprocess.run(
        ["/usr/bin/openssl", "pkey", "-in", str(PRIVATE_KEY), "-noout"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    if private.returncode != 0:
        fail("fixed M1 witness private key is invalid")
    derived = subprocess.run(
        ["/usr/bin/openssl", "pkey", "-in", str(PRIVATE_KEY), "-pubout"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    )
    if derived.returncode != 0 or derived.stdout != PUBLIC_KEY.read_bytes():
        fail("fixed M1 witness public and private keys do not match")


if __name__ == "__main__":
    main()
