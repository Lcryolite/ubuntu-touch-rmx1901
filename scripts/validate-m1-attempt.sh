#!/bin/bash -p
set -euo pipefail
PATH=/usr/bin:/bin
export PATH

if test "$#" -ne 2; then
  echo 'invalid validator argument count' >&2
  exit 10
fi
attempt_dir="$1"
expected_tokens="$2"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
safe_file="$repo_root/scripts/m1-safe-file.py"
safe_tree="$repo_root/scripts/m1-evidence-snapshot.py"
fixed_trust=/usr/local/libexec/rmx1901-m1-control/fixed-trust
trust_root=/var/lib/rmx1901-m1-control
fixed_public_key="$trust_root/witness-ed25519.pub"
fixed_public_key_sha="$trust_root/witness-ed25519.sha256"
fixed_registry="$trust_root/registry"

if test -n "${M1_CAPTURE_WITNESS:-}" || test -n "${M1_WITNESS_PUBLIC_KEY:-}" || \
   test -n "${M1_RECEIPT_REGISTRY:-}" || test -n "${M1_READONLY_RUNNER:-}" || \
   test -n "${M1_RECEIPT_SIGNER:-}"; then
  echo 'caller-selectable witness trust bootstrap is forbidden' >&2
  exit 20
fi
"$fixed_trust" check || exit 20

snapshot_root="$(mktemp -d "${TMPDIR:-/tmp}/m1-validate-snapshot.XXXXXX")"
trap 'chmod -R u+w "$snapshot_root" 2>/dev/null || true; rm -rf -- "$snapshot_root"' EXIT
attempt_base="$(basename "$attempt_dir")"
[[ "$attempt_base" =~ ^[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
  echo 'M1 attempt basename is invalid' >&2; exit 20;
}
"$safe_tree" snapshot-tree "$attempt_dir" "$snapshot_root/$attempt_base" >/dev/null 2>&1 || {
  echo 'M1 attempt snapshot failed or contains an unsafe attempt entry' >&2; exit 20;
}
"$safe_file" snapshot "$expected_tokens" "$snapshot_root/expected.txt" - - >/dev/null 2>&1 || {
  echo 'M1 expected cmdline token snapshot failed' >&2; exit 10;
}
"$safe_file" snapshot "$fixed_public_key" "$snapshot_root/public.pem" - - >/dev/null 2>&1 || {
  echo 'trusted witness public key snapshot failed' >&2; exit 20;
}
"$safe_file" snapshot "$fixed_public_key_sha" "$snapshot_root/public.sha256" - - >/dev/null 2>&1 || {
  echo 'trusted witness public key fingerprint snapshot failed' >&2; exit 20;
}
/usr/bin/python3 - "$snapshot_root/public.pem" "$snapshot_root/public.sha256" <<'PY' || {
import hashlib, re, sys
raw = open(sys.argv[2], "r", encoding="ascii", newline="").read()
if not re.fullmatch(r"[0-9a-f]{64}\n", raw):
    raise SystemExit(1)
if hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest() != raw[:-1]:
    raise SystemExit(1)
PY
  echo 'fixed M1 public key fingerprint changed during snapshot' >&2; exit 20;
}
session="$(/usr/bin/python3 - "$snapshot_root/$attempt_base/capture-session.env" <<'PY'
import re, sys
try:
    raw = open(sys.argv[1], "r", encoding="ascii", newline="").read()
except (OSError, UnicodeError):
    raise SystemExit(1)
match = re.fullmatch(r"CAPTURE_DIRECTORY=[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9][A-Za-z0-9._-]*\nCAPTURE_SESSION=(m1-[0-9a-f]{32})\n", raw)
if not match:
    raise SystemExit(1)
print(match.group(1))
PY
)" || { echo 'capture session evidence is invalid' >&2; exit 20; }
mkdir -m 700 "$snapshot_root/registry" "$snapshot_root/registry/receipts"
for suffix in receipt sig; do
  "$safe_file" snapshot "$fixed_registry/receipts/$session.$suffix" \
    "$snapshot_root/registry/receipts/$session.$suffix" - - >/dev/null 2>&1 || {
      echo 'trusted witness receipt snapshot failed' >&2; exit 20;
    }
done

attempt_dir="$snapshot_root/$attempt_base"
expected_tokens="$snapshot_root/expected.txt"
receipt_registry="$snapshot_root/registry"
public_key="$snapshot_root/public.pem"

/usr/bin/python3 - "$attempt_dir" "$expected_tokens" "$receipt_registry" "$public_key" <<'PY'
import hashlib
import os
import re
import stat
import subprocess
import sys
from pathlib import Path

attempt = Path(sys.argv[1])
expected_path = Path(sys.argv[2])
registry = Path(sys.argv[3])
public_key = Path(sys.argv[4])


class GateError(Exception):
    def __init__(self, status, message, phase=None, reason=None):
        super().__init__(message)
        self.status = status
        self.message = message
        self.phase = phase
        self.reason = reason


def fail(status, message, phase=None, reason=None):
    raise GateError(status, message, phase, reason)


def is_plain_file(path):
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError:
        return False
    return stat.S_ISREG(mode)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_checksum_manifest(path, expected_names=None):
    if not is_plain_file(path):
        fail(20, f"missing checksum manifest: {path.name}")
    entries = {}
    raw = path.read_bytes()
    if not raw.endswith(b"\n"):
        fail(20, f"invalid checksum manifest: {path.name}")
    for raw_line in raw.splitlines():
        try:
            line = raw_line.decode("ascii")
        except UnicodeDecodeError:
            fail(20, f"invalid checksum manifest: {path.name}")
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._/-]*)", line)
        if not match:
            fail(20, f"invalid checksum manifest: {path.name}")
        digest, name = match.groups()
        if name in entries or name.startswith("/") or ".." in Path(name).parts:
            fail(20, f"invalid checksum manifest: {path.name}")
        entries[name] = digest
    if not entries:
        fail(20, f"empty checksum manifest: {path.name}")
    if expected_names is not None and set(entries) != set(expected_names):
        fail(20, f"checksum coverage mismatch: {path.name}")
    for name, digest in entries.items():
        target = attempt / name
        if not is_plain_file(target) or sha256(target) != digest:
            fail(20, f"checksum verification failed: {path.name}")
    return entries


SAFE_VALUE = re.compile(r"[-A-Za-z0-9 ._/:=+,]*\Z")


def parse_env(path, keys, status=20, label=None):
    label = label or path.name
    if not is_plain_file(path):
        fail(status, f"missing evidence env: {label}")
    try:
        raw = path.read_text(encoding="ascii")
    except (UnicodeDecodeError, OSError):
        fail(status, f"invalid evidence env: {label}")
    if not raw.endswith("\n"):
        fail(status, f"invalid evidence env: {label}")
    data = {}
    order = []
    for line in raw.splitlines():
        if "=" not in line:
            fail(status, f"invalid evidence env: {label}")
        key, value = line.split("=", 1)
        if key not in keys or key in data or not SAFE_VALUE.fullmatch(value):
            fail(status, f"shell metacharacter or invalid field in {label}: {key}")
        data[key] = value
        order.append(key)
    if order != list(keys):
        fail(status, f"missing, extra or reordered field in {label}")
    return data


def one_line(path, label):
    if not is_plain_file(path):
        fail(20, f"missing runtime evidence: {label}")
    raw = path.read_bytes()
    if not raw.endswith(b"\n") or raw.count(b"\n") != 1 or b"\x00" in raw:
        fail(20, f"invalid runtime evidence: {label}")
    try:
        return raw[:-1].decode("utf-8")
    except UnicodeDecodeError:
        fail(20, f"invalid runtime evidence: {label}")


raw_files = [
    "attempt.env", "capture-session.env", "boot-unpack.txt", "proc-cmdline.txt",
    "handoff-events.log", "handoff-kmsg.log", "transport.env", "usb-state.env",
    "preflight.env", "write-readback.env", "runtime/pid1-comm.txt",
    "runtime/pid1-exe.txt", "runtime/pid1-cmdline.txt", "runtime/mounts.txt",
    "runtime/boot-id.txt", "runtime/journal.txt", "runtime/failed-units.txt", "runtime/configfs.txt",
    "runtime/netdev.txt", "runtime/systemd-confirmed.env", "result.env",
]

try:
    if not attempt.is_dir() or attempt.is_symlink():
        fail(20, "M1 attempt directory is missing or unsafe")
    if not is_plain_file(expected_path):
        fail(10, "M1 expected cmdline token file is missing")
    if not registry.is_dir() or registry.is_symlink() or not (registry / "receipts").is_dir():
        fail(20, "trusted capture receipt registry is unavailable")
    if not is_plain_file(public_key):
        fail(20, "trusted capture receipt public key is unavailable")

    key_check = subprocess.run(
        ["/usr/bin/openssl", "pkey", "-pubin", "-in", str(public_key), "-text", "-noout"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
    )
    if key_check.returncode != 0:
        fail(20, "trusted capture receipt public key is invalid")
    if not key_check.stdout.startswith("ED25519 Public-Key:\n"):
        fail(20, "trusted capture receipt public key is not Ed25519")

    allowed_directories = {"runtime"}
    for path in attempt.rglob("*"):
        relative = str(path.relative_to(attempt))
        mode = path.lstat().st_mode
        if stat.S_ISDIR(mode):
            if relative not in allowed_directories:
                fail(20, f"unsafe attempt entry: {relative}")
        elif not stat.S_ISREG(mode):
            fail(20, f"unsafe attempt entry: {relative}")

    actual_files = sorted(
        str(path.relative_to(attempt))
        for path in attempt.rglob("*")
        if is_plain_file(path) and path.name != "SHA256SUMS"
    )
    parse_checksum_manifest(attempt / "SHA256SUMS", actual_files)
    parse_checksum_manifest(attempt / "capture-SHA256SUMS", raw_files)

    metadata_keys = [
        "SPEC_VERSION", "ATTEMPT_ID", "UNIQUE_VARIABLE", "SOURCE_COMMIT",
        "INITRD_SHA256", "BOOT_SHA256", "TOOLCHAIN_SHA256",
        "SOURCE_TREE_SHA256", "SOURCE_DIRTY", "INPUT_SHA256",
        "OUTPUT_SHA256", "PREDECESSOR_SHA256", "CAPTURE_NONCE",
        "CAPTURE_TIMESTAMP",
    ]
    metadata = parse_env(attempt / "attempt.env", metadata_keys)
    if metadata["SPEC_VERSION"] != "RMX1901-M1-EVIDENCE-V1":
        fail(20, "invalid M1 evidence spec version")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", metadata["ATTEMPT_ID"]):
        fail(20, "invalid M1 attempt id")
    if not re.fullmatch(r"[0-9a-f]{40}", metadata["SOURCE_COMMIT"]):
        fail(20, "invalid M1 source commit")
    for key in ("INITRD_SHA256", "BOOT_SHA256", "TOOLCHAIN_SHA256", "SOURCE_TREE_SHA256", "INPUT_SHA256", "OUTPUT_SHA256", "PREDECESSOR_SHA256"):
        if not re.fullmatch(r"[0-9a-f]{64}", metadata[key]):
            fail(20, f"invalid M1 metadata digest: {key}")
    if metadata["SOURCE_DIRTY"] != "NO":
        fail(20, "M1 source tree is dirty")
    if not re.fullmatch(r"[0-9a-f]{32}", metadata["CAPTURE_NONCE"]):
        fail(20, "invalid capture nonce")
    if not re.fullmatch(r"[0-9]{8}T[0-9]{6}\.[0-9]{9}Z", metadata["CAPTURE_TIMESTAMP"]):
        fail(20, "invalid capture timestamp")

    base_match = re.fullmatch(r"[0-9]{8}T[0-9]{6}Z-([A-Za-z0-9][A-Za-z0-9._-]*)", attempt.name)
    if not base_match or base_match.group(1) != metadata["ATTEMPT_ID"]:
        fail(20, "attempt directory does not bind metadata attempt id")

    session = parse_env(attempt / "capture-session.env", ["CAPTURE_DIRECTORY", "CAPTURE_SESSION"])
    if session["CAPTURE_DIRECTORY"] != attempt.name:
        fail(20, "trusted capture receipt does not bind attempt directory")
    if not re.fullmatch(r"m1-[0-9a-f]{32}", session["CAPTURE_SESSION"]):
        fail(20, "invalid capture session")

    receipt_path = registry / "receipts" / f"{session['CAPTURE_SESSION']}.receipt"
    signature_path = registry / "receipts" / f"{session['CAPTURE_SESSION']}.sig"
    if not is_plain_file(receipt_path) or not is_plain_file(signature_path):
        fail(20, "trusted capture receipt is missing")
    verify = subprocess.run(
        ["/usr/bin/openssl", "pkeyutl", "-verify", "-rawin", "-pubin", "-inkey", str(public_key),
         "-in", str(receipt_path), "-sigfile", str(signature_path)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    if verify.returncode != 0:
        fail(20, "trusted capture receipt signature is invalid")
    receipt = parse_env(receipt_path, [
        "RECEIPT_SCHEMA", "SIGNER_SEQUENCE", "SIGNER_PREVIOUS_SHA256",
        "ATTEMPT_ID", "CAPTURE_DIRECTORY", "CAPTURE_SESSION", "CAPTURE_NONCE",
        "CAPTURE_TIMESTAMP", "BOOT_ID", "CAPTURE_MANIFEST_SHA256",
    ], label="trusted capture receipt")
    if receipt["RECEIPT_SCHEMA"] != "RMX1901-M1-SIGNED-RECEIPT-V1":
        fail(20, "trusted capture receipt schema is invalid")
    if not re.fullmatch(r"[1-9][0-9]*", receipt["SIGNER_SEQUENCE"]):
        fail(20, "trusted capture receipt sequence is invalid")
    if receipt["SIGNER_PREVIOUS_SHA256"] != "GENESIS" and not re.fullmatch(r"[0-9a-f]{64}", receipt["SIGNER_PREVIOUS_SHA256"]):
        fail(20, "trusted capture receipt predecessor is invalid")
    boot_id = one_line(attempt / "runtime/boot-id.txt", "boot-id")
    if not re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}", boot_id):
        fail(20, "kernel boot identity is invalid")
    receipt_bindings = {
        "ATTEMPT_ID": metadata["ATTEMPT_ID"],
        "CAPTURE_DIRECTORY": attempt.name,
        "CAPTURE_SESSION": session["CAPTURE_SESSION"],
        "CAPTURE_NONCE": metadata["CAPTURE_NONCE"],
        "CAPTURE_TIMESTAMP": metadata["CAPTURE_TIMESTAMP"],
        "BOOT_ID": boot_id,
        "CAPTURE_MANIFEST_SHA256": sha256(attempt / "capture-SHA256SUMS"),
    }
    for key, wanted in receipt_bindings.items():
        if receipt[key] != wanted:
            fail(20, f"trusted capture receipt binding mismatch: {key}")
    result = parse_env(attempt / "result.env", ["RESULT", "FAILURE_PHASE", "REASON"])
    if result != {
        "RESULT": "PASS", "FAILURE_PHASE": "NONE",
        "REASON": "SIGNED_RAW_CAPTURE_COMPLETED",
    }:
        fail(20, "trusted witness raw capture result is invalid")

    transport = parse_env(attempt / "transport.env", [
        "TRANSPORT", "PRODUCT", "TCP22", "TCP23", "BANNER", "HOSTKEY", "AUTH",
        "PID1_COMM", "PID1_EXE", "PID1_CMDLINE",
    ], status=40)
    usb = parse_env(attempt / "usb-state.env", [
        "CLASSIFICATION", "VIDPID", "PRODUCT", "NETDEV", "IP", "TCP22", "TCP23",
    ], status=40)
    if transport["TRANSPORT"] not in ("panic", "diagnostic-ssh", "systemd-ssh"):
        fail(40, "unknown M1 transport")
    if usb["CLASSIFICATION"] != transport["TRANSPORT"]:
        fail(40, "transport classification mismatch")
    if usb["VIDPID"] != "18d1:d001":
        fail(40, "unknown USB VID:PID")
    for key in ("PRODUCT", "TCP22", "TCP23"):
        if usb[key] != transport[key]:
            fail(40, f"USB transport fact mismatch: {key}")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", usb["NETDEV"]):
        fail(40, "invalid USB netdev")
    if not re.fullmatch(r"(?:[0-9]{1,3}\.){3}[0-9]{1,3}", usb["IP"]):
        fail(40, "invalid USB IPv4")
    if transport["TRANSPORT"] == "panic":
        wanted = {
            "PRODUCT": "Failed to boot", "TCP22": "CLOSED", "TCP23": "OPEN",
            "BANNER": "NONE", "HOSTKEY": "NONE", "AUTH": "NONE",
            "PID1_COMM": "init", "PID1_EXE": "/bin/sh", "PID1_CMDLINE": "/bin/sh /init",
        }
    elif transport["TRANSPORT"] == "diagnostic-ssh":
        if transport["PRODUCT"] != "RMX1901 diagnostic bridge":
            fail(40, "diagnostic product is not RMX1901 diagnostic bridge")
        wanted = {"TCP22": "OPEN", "TCP23": "CLOSED", "AUTH": "PUBLICKEY_OK"}
        if not re.fullmatch(r"SSH-[^ ]+", transport["BANNER"]):
            fail(40, "diagnostic SSH banner is invalid")
        if not re.fullmatch(r"SHA256:[A-Za-z0-9+/=]+", transport["HOSTKEY"]):
            fail(40, "diagnostic SSH host key is invalid")
        if transport["PID1_COMM"] == "systemd" or not transport["PID1_COMM"] or transport["PID1_CMDLINE"] != "/bin/sh /init":
            fail(40, "diagnostic SSH PID 1 is not the initramfs shell")
    else:
        if transport["PRODUCT"] != "RMX1901 diagnostic bridge":
            fail(40, "systemd SSH product is not RMX1901 diagnostic bridge")
        wanted = {
            "TCP22": "OPEN", "TCP23": "CLOSED", "AUTH": "PUBLICKEY_OK",
            "PID1_COMM": "systemd", "PID1_EXE": "/usr/lib/systemd/systemd",
            "PID1_CMDLINE": "/usr/lib/systemd/systemd",
        }
        if not re.fullmatch(r"SSH-[^ ]+", transport["BANNER"]):
            fail(40, "systemd SSH banner is invalid")
        if not re.fullmatch(r"SHA256:[A-Za-z0-9+/=]+", transport["HOSTKEY"]):
            fail(40, "systemd SSH host key is invalid")
    for key, value in wanted.items():
        if transport[key] != value:
            fail(40, f"invalid transport fact: {key}")

    runtime_bindings = {
        "PID1_COMM": one_line(attempt / "runtime/pid1-comm.txt", "pid1-comm"),
        "PID1_EXE": one_line(attempt / "runtime/pid1-exe.txt", "pid1-exe"),
        "PID1_CMDLINE": one_line(attempt / "runtime/pid1-cmdline.txt", "pid1-cmdline"),
    }
    for key, value in runtime_bindings.items():
        if transport[key] != value:
            fail(40, f"transport does not bind runtime {key}")
    confirmation = parse_env(
        attempt / "runtime/systemd-confirmed.env", ["SYSTEMD_CONFIRMED"],
        status=40, label="systemd-confirmed",
    )
    wanted_confirmation = "YES" if transport["TRANSPORT"] == "systemd-ssh" else "NO"
    if confirmation["SYSTEMD_CONFIRMED"] != wanted_confirmation:
        fail(40, "SYSTEMD_CONFIRMED does not match classified PID 1 evidence")
    for name in ("mounts", "journal", "failed-units", "configfs", "netdev"):
        if not is_plain_file(attempt / f"runtime/{name}.txt") or (attempt / f"runtime/{name}.txt").stat().st_size == 0:
            fail(20, f"missing runtime evidence: {name}")

    preflight = parse_env(attempt / "preflight.env", [
        "ADB_STATE", "ADB_SERIAL", "ADB_PRODUCT", "ADB_MODEL", "ADB_DEVICE",
        "UNLOCKED", "BOOT_PATH", "BOOT_SIZE", "BOOT_MAJOR_MINOR",
        "BATTERY_PERCENT", "SAFETY_GATE",
    ], status=50)
    identity_wanted = {
        "ADB_STATE": "recovery", "ADB_SERIAL": "7b0c1c49",
        "ADB_PRODUCT": "fox_RMX1901", "ADB_MODEL": "RMX1901",
        "ADB_DEVICE": "RMX1901", "UNLOCKED": "YES",
    }
    for key, value in identity_wanted.items():
        if preflight[key] != value:
            fail(50, f"device identity mismatch: {key}", "PREFLIGHT", "DEVICE_IDENTITY_MISMATCH")
    partition_wanted = {
        "BOOT_PATH": "/dev/block/sde10", "BOOT_SIZE": "67108864",
        "BOOT_MAJOR_MINOR": "8:4a",
    }
    for key, value in partition_wanted.items():
        if preflight[key] != value:
            fail(50, f"boot partition mismatch: {key}", "PREFLIGHT", "BOOT_PARTITION_MISMATCH")
    try:
        battery = int(preflight["BATTERY_PERCENT"])
    except ValueError:
        fail(20, "invalid battery fact")
    if battery < 50 or battery > 100 or preflight["SAFETY_GATE"] != "PASS":
        fail(20, "recovery safety preflight failed", "PREFLIGHT", "SAFETY_GATE_FAILED")

    readback = parse_env(attempt / "write-readback.env", [
        "PREDECESSOR_SHA256", "DEVICE_READBACK_SHA256", "HOST_READBACK_SHA256",
    ], status=60)
    for key, value in readback.items():
        if not re.fullmatch(r"[0-9a-f]{64}", value):
            fail(60, f"write/readback digest is invalid: {key}", "WRITE_READBACK", "READBACK_INVALID")
    if metadata["PREDECESSOR_SHA256"] != readback["PREDECESSOR_SHA256"] or metadata["INPUT_SHA256"] != metadata["PREDECESSOR_SHA256"]:
        fail(60, "write/readback predecessor chain mismatch", "WRITE_READBACK", "PREDECESSOR_MISMATCH")
    if metadata["OUTPUT_SHA256"] != metadata["BOOT_SHA256"]:
        fail(30, "output digest does not bind boot artifact", "ARTIFACT", "OUTPUT_BOOT_MISMATCH")
    if not (readback["DEVICE_READBACK_SHA256"] == readback["HOST_READBACK_SHA256"] == metadata["BOOT_SHA256"]):
        fail(60, "write/readback hashes differ", "WRITE_READBACK", "READBACK_MISMATCH")

    boot_lines = (attempt / "boot-unpack.txt").read_text(encoding="ascii").splitlines()
    def unique_prefix(prefix):
        values = [line[len(prefix):] for line in boot_lines if line.startswith(prefix)]
        if len(values) != 1:
            fail(30, f"boot artifact field missing or duplicate: {prefix}")
        return values[0]
    if unique_prefix("boot image header version: ") != "1":
        fail(30, "boot header version is not v1")
    if unique_prefix("additional command line args:").strip():
        fail(30, "additional cmdline is not empty")
    boot_tokens = unique_prefix("command line args: ").split()
    for prefix in ("kernel size: ", "ramdisk size: "):
        if not re.fullmatch(r"[1-9][0-9]*", unique_prefix(prefix)):
            fail(30, f"invalid boot artifact size: {prefix}")

    expected_raw = expected_path.read_text(encoding="ascii")
    if not expected_raw.endswith("\n"):
        fail(10, "invalid expected cmdline token list")
    expected = expected_raw.splitlines()
    if not expected or any(not re.fullmatch(r"[^\s]+", token) or not SAFE_VALUE.fullmatch(token) for token in expected) or len(set(expected)) != len(expected):
        fail(10, "invalid expected cmdline token list")
    required_observation_tokens = {
        "systempart=/dev/disk/by-partlabel/system",
        "systemd.unified_cgroup_hierarchy=0",
        "console=tty0",
        "rmx1901.debug_rndis=1",
    }
    if not required_observation_tokens.issubset(expected):
        fail(30, "expected cmdline is missing a required observation token", "CMDLINE", "REQUIRED_TOKEN_MISSING")
    if boot_tokens != expected:
        fail(30, "boot unpack cmdline token array mismatch", "CMDLINE", "BOOT_CMDLINE_MISMATCH")
    proc_raw = one_line(attempt / "proc-cmdline.txt", "proc-cmdline")
    proc_tokens = proc_raw.split()
    # LK appends device-specific Android boot facts around the boot image's
    # main cmdline.  The ordered main array must survive unchanged, but those
    # bootloader-owned facts are not part of the signed boot header contract.
    cursor = 0
    for token in proc_tokens:
        if cursor < len(expected) and token == expected[cursor]:
            cursor += 1
    if cursor != len(expected):
        fail(30, "device cmdline is missing the ordered boot token array", "CMDLINE", "DEVICE_CMDLINE_MISMATCH")

    event_pattern = re.compile(r"RMX1901_HANDOFF sequence=[1-9][0-9]* stage=[A-Z_]+(?: [A-Za-z][A-Za-z0-9_]*=[A-Za-z0-9_.:/,+-]+)*$")
    kmsg_events = []
    for line in (attempt / "handoff-kmsg.log").read_text(encoding="utf-8").splitlines():
        if "RMX1901_HANDOFF" not in line:
            continue
        match = event_pattern.search(line)
        if not match:
            fail(20, "kmsg contains a malformed RMX1901 handoff event", "EVENTS", "MALFORMED_KMSG_EVENT")
        kmsg_events.append(match.group(0))
    handoff_raw = (attempt / "handoff-events.log").read_bytes()
    if not handoff_raw.endswith(b"\n"):
        fail(20, "handoff semantic proof: event log lacks terminal newline", "EVENTS", "MALFORMED_EVENT_LOG")
    try:
        handoff_lines = handoff_raw.decode("ascii").splitlines()
    except UnicodeDecodeError:
        fail(20, "handoff semantic proof: non-ASCII event", "EVENTS", "MALFORMED_EVENT_LOG")
    if handoff_lines != kmsg_events:
        fail(20, "tmpfs and kmsg handoff events differ", "EVENTS", "EVENT_SINK_MISMATCH")
    if not handoff_lines:
        fail(20, "handoff semantic proof: empty event log", "EVENTS", "EMPTY_EVENT_LOG")

    parsed_events = []
    for line_number, line in enumerate(handoff_lines, 1):
        match = re.fullmatch(r"RMX1901_HANDOFF sequence=([1-9][0-9]*) stage=([A-Z_]+)(?: (.*))?", line)
        if not match:
            fail(20, f"handoff semantic proof: malformed line {line_number}", "EVENTS", "MALFORMED_EVENT")
        sequence, stage, extras = int(match.group(1)), match.group(2), match.group(3) or ""
        if sequence != line_number:
            fail(20, "handoff semantic proof: non-consecutive sequence", "EVENTS", "NONCONSECUTIVE_EVENT")
        fields = {}
        for item in extras.split() if extras else []:
            if "=" not in item:
                fail(20, "handoff semantic proof: malformed field", "EVENTS", "MALFORMED_EVENT_FIELD")
            key, value = item.split("=", 1)
            if key in fields or not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", key) or not re.fullmatch(r"[A-Za-z0-9_.:/,+-]+", value):
                fail(20, "handoff semantic proof: unsafe or duplicate field", "EVENTS", "MALFORMED_EVENT_FIELD")
            fields[key] = value
        parsed_events.append((stage, fields))

    if len(parsed_events) >= 4 and parsed_events[2][0] == "ROOTFS_MOUNTED" and parsed_events[3][0] == "USERDATA_PROBED":
        fail(20, "event order conflicts with spec: ROOTFS_MOUNTED precedes causal USERDATA_PROBED", "EVENT_ORDER", "ROOTFS_BEFORE_USERDATA_CONFLICTS_WITH_SPEC_V1")

    expected_stages = [
        "CMDLINE_PARSED", "ROOT_DEVICE_RESOLVED", "USERDATA_PROBED",
        "ROOTFS_MOUNTED", "DEV_MOVE_BEGIN", "DEV_MOVE_DONE", "CONSOLE_OPEN",
        "RUN_MOVE_BEGIN", "RUN_MOVE_DONE", "HANDOFF_MARKER", "RUN_INIT_EXEC",
    ]
    terminal = False
    last_success = "NONE"
    first_failure = "NONE"
    failure_reason = "NONE"
    for index, (stage, fields) in enumerate(parsed_events, 1):
        if index > len(expected_stages):
            fail(20, "handoff semantic proof: too many stages", "EVENTS", "EXTRA_EVENT")
        expected_stage = expected_stages[index - 1]
        accepted = {expected_stage}
        if expected_stage == "CONSOLE_OPEN":
            accepted = {"CONSOLE_OPEN_OK", "CONSOLE_OPEN_FAILED"}
        elif expected_stage == "HANDOFF_MARKER":
            accepted = {"HANDOFF_MARKER_VISIBLE", "HANDOFF_MARKER_MISSING"}
        if stage not in accepted:
            fail(20, f"handoff semantic proof: expected {expected_stage}, got {stage}", "EVENTS", "EVENT_STAGE_MISMATCH")

        def exact_fields(wanted):
            if fields != wanted:
                fail(20, f"handoff semantic proof: {stage} fields invalid", "EVENTS", "EVENT_FIELD_PROOF_MISSING")

        if stage == "CMDLINE_PARSED":
            exact_fields({"systempart": "valid", "cgroup": "valid", "console": "valid", "diagnostic_rndis": "valid"})
        elif stage == "ROOT_DEVICE_RESOLVED":
            exact_fields({
                "root": "/dev/sda11", "root_mm": "8:b", "system": "/dev/sda11",
                "system_mm": "8:b", "userdata": "/dev/sda13", "userdata_mm": "8:d",
            })
        elif stage == "ROOTFS_MOUNTED":
            if set(fields) != {"requested_source", "source", "fstype", "options"} or fields["requested_source"] != "/dev/sda11" or fields["source"] != "/dev/sda11" or not re.fullmatch(r"[A-Za-z0-9_.+-]+", fields["fstype"]):
                fail(20, "handoff semantic proof: rootfs source/fstype missing", "EVENTS", "ROOTFS_PROOF_MISSING")
            options = fields["options"].split(":")
            if "ro" not in options or "rw" in options:
                fail(20, "handoff semantic proof: rootfs is not safely read-only", "EVENTS", "ROOTFS_OPTIONS_UNSAFE")
        elif stage == "USERDATA_PROBED":
            if set(fields) != {"path", "major_minor", "fstype", "readonly", "norecovery", "rw", "dmesg", "recovery_fsync", "unmounted", "result"}:
                fail(20, "handoff semantic proof: userdata proof fields missing", "EVENTS", "USERDATA_PROOF_MISSING")
            if fields != {
                "path": "/dev/sda13", "major_minor": "8:d", "fstype": "f2fs",
                "readonly": "yes", "norecovery": "yes", "rw": "absent",
                "dmesg": "readable", "recovery_fsync": "absent",
                "unmounted": "yes", "result": "safe",
            }:
                fail(20, "handoff semantic proof: F2FS safe probe not proven", "EVENTS", "USERDATA_PROBE_UNSAFE")
        elif stage in ("DEV_MOVE_BEGIN", "DEV_MOVE_DONE"):
            exact_fields({"rootmnt": "/root"})
        elif stage == "CONSOLE_OPEN_OK":
            exact_fields({"path": "/root/dev/console"})
        elif stage == "CONSOLE_OPEN_FAILED":
            if set(fields) != {"path", "open_status"} or fields["path"] != "/root/dev/console" or not re.fullmatch(r"[1-9][0-9]*", fields["open_status"]):
                fail(20, "handoff semantic proof: console failure status missing", "EVENTS", "CONSOLE_PROOF_MISSING")
            terminal = True
            last_success, first_failure, failure_reason = "DEV_MOVE_DONE", "CONSOLE_OPEN", "CONSOLE_OPEN_FAILED"
        elif stage == "RUN_MOVE_BEGIN":
            exact_fields({"from": "/run", "to": "/root/run"})
        elif stage == "RUN_MOVE_DONE":
            exact_fields({"path": "/root/run/rmx1901-handoff.events"})
        elif stage == "HANDOFF_MARKER_VISIBLE":
            exact_fields({"path": "/root/run/rmx1901-handoff.events"})
        elif stage == "HANDOFF_MARKER_MISSING":
            exact_fields({"path": "/root/run/rmx1901-handoff.events"})
            terminal = True
            last_success, first_failure, failure_reason = "RUN_MOVE_DONE", "HANDOFF_MARKER", "HANDOFF_MARKER_MISSING"
        elif stage == "RUN_INIT_EXEC":
            if set(fields) != {"init", "inode", "type"} or not fields["init"].startswith("/") or not re.fullmatch(r"[1-9][0-9]*", fields["inode"]) or not re.fullmatch(r"[A-Za-z0-9_-]+", fields["type"]):
                fail(20, "handoff semantic proof: run-init identity missing", "EVENTS", "RUN_INIT_PROOF_MISSING")

        if terminal and index != len(parsed_events):
            fail(20, "handoff semantic proof: terminal event has trailing data", "EVENTS", "TRAILING_EVENT")
        if not terminal:
            last_success = stage

    if not terminal and len(parsed_events) < len(expected_stages):
        first_failure = expected_stages[len(parsed_events)]
        failure_reason = "EVENT_SEQUENCE_STOPPED"

    print(f"LAST_SUCCESS_STAGE={last_success}")
    print(f"FIRST_FAILURE_BOUNDARY={first_failure}")
    print(f"FAILURE_REASON={failure_reason}")
    print("STAGE_ORDER_CONTRACT=SPEC_V1_USERDATA_BEFORE_ROOTFS")
    print(f"SYSTEMD_CONFIRMED={wanted_confirmation}")
    print("M1_ATTEMPT_EVIDENCE=VALID")

except GateError as error:
    print(error.message, file=sys.stderr)
    raise SystemExit(error.status)
PY
