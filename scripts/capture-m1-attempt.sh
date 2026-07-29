#!/bin/bash -p
set -euo pipefail
PATH=/usr/bin:/bin
export PATH
umask 077

if test "$#" -ne 1; then
  echo 'invalid capture argument count' >&2
  exit 10
fi
attempt_dir="$1"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
safe_file="$repo_root/scripts/m1-safe-file.py"
safe_tree="$repo_root/scripts/m1-evidence-snapshot.py"
fixed_trust=/usr/local/libexec/rmx1901-m1-control/fixed-trust
trust_root=/var/lib/rmx1901-m1-control
witness=/usr/local/libexec/rmx1901-m1-control/capture-witness
witness_sha="$trust_root/capture-witness.sha256"
public_key_input="$trust_root/witness-ed25519.pub"
public_key_sha="$trust_root/witness-ed25519.sha256"
registry="$trust_root/registry"

fail_input() { echo "$1" >&2; exit 10; }
fail_evidence() { echo "$1" >&2; exit 20; }

test -n "${M1_CAPTURE_METADATA:-}" || fail_input 'M1 capture metadata is missing'
if test -n "${M1_CAPTURE_WITNESS:-}" || test -n "${M1_WITNESS_PUBLIC_KEY:-}" || \
   test -n "${M1_RECEIPT_REGISTRY:-}" || test -n "${M1_READONLY_RUNNER:-}" || \
   test -n "${M1_RECEIPT_SIGNER:-}"; then
  fail_evidence 'caller-selectable witness trust bootstrap is forbidden'
fi
test -x "$safe_file" && test -x "$safe_tree" && test -x "$fixed_trust" || fail_evidence 'M1 safe trust implementation is unavailable'
"$fixed_trust" check || exit 20

metadata_input="$M1_CAPTURE_METADATA"
test -f "$metadata_input" && test ! -L "$metadata_input" || fail_input 'M1 capture metadata is not a regular file'
test ! -e "$attempt_dir" || fail_input 'M1 attempt directory already exists'

attempt_base="$(basename "$attempt_dir")"
[[ "$attempt_base" =~ ^[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail_input 'M1 attempt directory timestamp or id is invalid'
attempt_parent="$(dirname "$attempt_dir")"
test -d "$attempt_parent" && test ! -L "$attempt_parent" || fail_input 'M1 attempt parent directory is missing or unsafe'
attempt_parent="$(realpath -e "$attempt_parent")"
attempt_dir="$attempt_parent/$attempt_base"

scratch="$(mktemp -d "$attempt_parent/.m1-witness-capture.XXXXXX")"
cleanup() { chmod -R u+w "$scratch" 2>/dev/null || true; rm -rf -- "$scratch"; }
trap cleanup EXIT

"$safe_file" snapshot "$metadata_input" "$scratch/metadata.env" - - >/dev/null || fail_input 'M1 capture metadata snapshot failed'
"$safe_file" snapshot "$public_key_input" "$scratch/public.pem" - - >/dev/null || fail_evidence 'trusted witness public key snapshot failed'
"$safe_file" snapshot "$public_key_sha" "$scratch/public.sha256" - - >/dev/null || fail_evidence 'trusted witness public key fingerprint snapshot failed'
"$safe_file" snapshot "$witness" "$scratch/witness" - - >/dev/null || fail_evidence 'trusted capture witness snapshot failed'
"$safe_file" snapshot "$witness_sha" "$scratch/witness.sha256" - - >/dev/null || fail_evidence 'trusted capture witness fingerprint snapshot failed'
chmod 500 "$scratch/witness"

/usr/bin/python3 - "$scratch/public.pem" "$scratch/public.sha256" "$scratch/witness" "$scratch/witness.sha256" <<'PY' || fail_evidence 'fixed M1 trust fingerprint changed during snapshot'
import hashlib, re, sys
for value, pin in ((sys.argv[1], sys.argv[2]), (sys.argv[3], sys.argv[4])):
    raw = open(pin, "r", encoding="ascii", newline="").read()
    if not re.fullmatch(r"[0-9a-f]{64}\n", raw):
        raise SystemExit(1)
    digest = hashlib.sha256(open(value, "rb").read()).hexdigest()
    if digest != raw[:-1]:
        raise SystemExit(1)
PY

key_description="$(/usr/bin/openssl pkey -pubin -in "$scratch/public.pem" -text -noout 2>/dev/null)" || fail_evidence 'trusted witness public key is invalid'
printf '%s\n' "$key_description" | grep -Fxq 'ED25519 Public-Key:' || fail_evidence 'trusted witness public key is not Ed25519'

/usr/bin/python3 - "$scratch/metadata.env" "$attempt_base" <<'PY' || fail_input 'M1 capture metadata contains a shell metacharacter or invalid field'
import re, sys
path, directory = sys.argv[1:]
keys = [
    "SPEC_VERSION", "ATTEMPT_ID", "UNIQUE_VARIABLE", "SOURCE_COMMIT",
    "INITRD_SHA256", "BOOT_SHA256", "TOOLCHAIN_SHA256",
    "SOURCE_TREE_SHA256", "SOURCE_DIRTY", "INPUT_SHA256",
    "OUTPUT_SHA256", "PREDECESSOR_SHA256",
]
data = {}
safe = re.compile(r"[A-Za-z0-9][A-Za-z0-9 ._/:=+,-]*\Z")
with open(path, "r", encoding="ascii", newline="") as stream:
    lines = stream.readlines()
for raw in lines:
    if not raw.endswith("\n") or raw.count("\n") != 1 or "=" not in raw:
        raise SystemExit(1)
    key, value = raw[:-1].split("=", 1)
    if key not in keys or key in data or not safe.fullmatch(value):
        raise SystemExit(1)
    data[key] = value
if list(data) != keys or data["SPEC_VERSION"] != "RMX1901-M1-EVIDENCE-V1":
    raise SystemExit(1)
if directory.split("-", 1)[1] != data["ATTEMPT_ID"]:
    raise SystemExit(1)
if not re.fullmatch(r"[0-9a-f]{40}", data["SOURCE_COMMIT"]):
    raise SystemExit(1)
for key in ("INITRD_SHA256", "BOOT_SHA256", "TOOLCHAIN_SHA256", "SOURCE_TREE_SHA256", "INPUT_SHA256", "OUTPUT_SHA256", "PREDECESSOR_SHA256"):
    if not re.fullmatch(r"[0-9a-f]{64}", data[key]):
        raise SystemExit(1)
if data["SOURCE_DIRTY"] != "NO":
    raise SystemExit(1)
PY

mkdir -m 700 "$scratch/witness-output"
set +e
/usr/bin/env -i PATH=/usr/bin:/bin \
  "$scratch/witness" "$scratch/metadata.env" "$attempt_base" "$scratch/witness-output"
witness_status=$?
set -e
test "$witness_status" -eq 0 || fail_evidence 'trusted capture witness failed'

"$safe_tree" snapshot-tree "$scratch/witness-output" "$scratch/verified-bundle" || fail_evidence 'trusted witness bundle snapshot failed'
chmod 700 "$scratch/verified-bundle" "$scratch/verified-bundle/attempt" "$scratch/verified-bundle/attempt/runtime" 2>/dev/null || true

session="$(/usr/bin/python3 - "$scratch/verified-bundle" "$scratch/metadata.env" "$attempt_base" "$scratch/public.pem" <<'PY'
import hashlib, os, re, stat, subprocess, sys
from pathlib import Path

bundle = Path(sys.argv[1])
metadata_input = Path(sys.argv[2])
attempt_base = sys.argv[3]
public_key = Path(sys.argv[4])
attempt = bundle / "attempt"

def abort(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)

def plain(path):
    try:
        return stat.S_ISREG(path.lstat().st_mode)
    except OSError:
        return False

expected_raw = {
    "attempt.env", "capture-session.env", "boot-unpack.txt", "proc-cmdline.txt",
    "handoff-events.log", "handoff-kmsg.log", "transport.env", "usb-state.env",
    "preflight.env", "write-readback.env", "result.env",
    "runtime/pid1-comm.txt", "runtime/pid1-exe.txt", "runtime/pid1-cmdline.txt",
    "runtime/boot-id.txt", "runtime/mounts.txt", "runtime/journal.txt",
    "runtime/failed-units.txt", "runtime/configfs.txt", "runtime/netdev.txt",
    "runtime/systemd-confirmed.env",
}
expected_attempt = expected_raw | {"capture-SHA256SUMS", "SHA256SUMS"}
if sorted(path.name for path in bundle.iterdir()) != ["attempt", "receipt.env", "receipt.sig"]:
    abort("trusted witness bundle has missing or extra top-level entries")
if not attempt.is_dir() or attempt.is_symlink() or not plain(bundle / "receipt.env") or not plain(bundle / "receipt.sig"):
    abort("trusted witness bundle contains an unsafe top-level entry")
actual = set()
for path in attempt.rglob("*"):
    relative = str(path.relative_to(attempt))
    mode = path.lstat().st_mode
    if stat.S_ISDIR(mode):
        if relative != "runtime":
            abort(f"unsafe witness attempt directory: {relative}")
    elif stat.S_ISREG(mode):
        actual.add(relative)
    else:
        abort(f"unsafe witness attempt entry: {relative}")
if actual != expected_attempt:
    abort("trusted witness attempt file coverage mismatch")

def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()

def manifest(path, wanted):
    raw = path.read_bytes()
    if not raw.endswith(b"\n"):
        abort(f"invalid checksum manifest: {path.name}")
    entries = {}
    for line in raw.splitlines():
        try:
            match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._/-]*)", line.decode("ascii"))
        except UnicodeDecodeError:
            match = None
        if not match:
            abort(f"invalid checksum manifest: {path.name}")
        value, name = match.groups()
        if name in entries or ".." in Path(name).parts:
            abort(f"invalid checksum manifest: {path.name}")
        entries[name] = value
    if set(entries) != set(wanted):
        abort(f"checksum coverage mismatch: {path.name}")
    for name, value in entries.items():
        target = attempt / name
        if not plain(target) or digest(target) != value:
            abort(f"checksum verification failed: {path.name}")

manifest(attempt / "capture-SHA256SUMS", expected_raw)
manifest(attempt / "SHA256SUMS", expected_raw | {"capture-SHA256SUMS"})

metadata_raw = (attempt / "attempt.env").read_bytes()
input_raw = metadata_input.read_bytes()
if not metadata_raw.startswith(input_raw):
    abort("witness metadata does not preserve the trusted input snapshot")
tail = metadata_raw[len(input_raw):].decode("ascii", errors="strict").splitlines()
if len(tail) != 2:
    abort("witness metadata session fields are invalid")
nonce_match = re.fullmatch(r"CAPTURE_NONCE=([0-9a-f]{32})", tail[0])
time_match = re.fullmatch(r"CAPTURE_TIMESTAMP=([0-9]{8}T[0-9]{6}\.[0-9]{9}Z)", tail[1])
if not nonce_match or not time_match:
    abort("witness metadata session fields are invalid")
nonce, timestamp = nonce_match.group(1), time_match.group(1)

def strict_env(path, keys):
    raw = path.read_text(encoding="ascii")
    if not raw.endswith("\n"):
        abort(f"invalid env record: {path.name}")
    data = {}
    for line, key in zip(raw.splitlines(), keys):
        got, separator, value = line.partition("=")
        if not separator or got != key or key in data:
            abort(f"invalid env record: {path.name}")
        data[key] = value
    if len(data) != len(keys) or len(raw.splitlines()) != len(keys):
        abort(f"invalid env record: {path.name}")
    return data

session = strict_env(attempt / "capture-session.env", ["CAPTURE_DIRECTORY", "CAPTURE_SESSION"])
if session["CAPTURE_DIRECTORY"] != attempt_base or not re.fullmatch(r"m1-[0-9a-f]{32}", session["CAPTURE_SESSION"]):
    abort("witness capture session is invalid")
receipt_keys = [
    "RECEIPT_SCHEMA", "SIGNER_SEQUENCE", "SIGNER_PREVIOUS_SHA256",
    "ATTEMPT_ID", "CAPTURE_DIRECTORY", "CAPTURE_SESSION", "CAPTURE_NONCE",
    "CAPTURE_TIMESTAMP", "BOOT_ID", "CAPTURE_MANIFEST_SHA256",
]
receipt = strict_env(bundle / "receipt.env", receipt_keys)
if receipt["RECEIPT_SCHEMA"] != "RMX1901-M1-SIGNED-RECEIPT-V1":
    abort("trusted witness receipt schema is invalid")
if not re.fullmatch(r"[1-9][0-9]*", receipt["SIGNER_SEQUENCE"]):
    abort("trusted witness receipt sequence is invalid")
if receipt["SIGNER_PREVIOUS_SHA256"] != "GENESIS" and not re.fullmatch(r"[0-9a-f]{64}", receipt["SIGNER_PREVIOUS_SHA256"]):
    abort("trusted witness receipt predecessor is invalid")
boot_id_raw = (attempt / "runtime/boot-id.txt").read_bytes()
if not boot_id_raw.endswith(b"\n") or boot_id_raw.count(b"\n") != 1:
    abort("kernel boot identity is invalid")
boot_id = boot_id_raw[:-1].decode("ascii", errors="strict")
if not re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}", boot_id):
    abort("kernel boot identity is invalid")
metadata = {}
for line in input_raw.decode("ascii").splitlines():
    key, value = line.split("=", 1)
    metadata[key] = value
wanted = {
    "ATTEMPT_ID": metadata["ATTEMPT_ID"], "CAPTURE_DIRECTORY": attempt_base,
    "CAPTURE_SESSION": session["CAPTURE_SESSION"], "CAPTURE_NONCE": nonce,
    "CAPTURE_TIMESTAMP": timestamp, "BOOT_ID": boot_id,
    "CAPTURE_MANIFEST_SHA256": digest(attempt / "capture-SHA256SUMS"),
}
for key, value in wanted.items():
    if receipt[key] != value:
        abort(f"trusted witness receipt binding mismatch: {key}")
verify = subprocess.run([
    "/usr/bin/openssl", "pkeyutl", "-verify", "-rawin", "-pubin", "-inkey", str(public_key),
    "-in", str(bundle / "receipt.env"), "-sigfile", str(bundle / "receipt.sig"),
], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
if verify.returncode != 0:
    abort("trusted witness receipt signature is invalid")

event = re.compile(rb"RMX1901_HANDOFF sequence=[1-9][0-9]* stage=[A-Z_]+(?: [A-Za-z][A-Za-z0-9_]*=[A-Za-z0-9_.:/,+-]+)*$")
handoff = (attempt / "handoff-events.log").read_bytes()
kmsg = (attempt / "handoff-kmsg.log").read_bytes()
if not handoff.endswith(b"\n") or not kmsg.endswith(b"\n"):
    abort("tmpfs and kmsg handoff events differ")
kmsg_events = []
for line in kmsg.splitlines():
    if b"RMX1901_HANDOFF" not in line:
        continue
    match = event.search(line)
    if not match:
        abort("kmsg contains a malformed RMX1901 handoff event")
    kmsg_events.append(match.group(0))
rebuilt = b"\n".join(kmsg_events) + (b"\n" if kmsg_events else b"")
if not handoff or handoff != rebuilt:
    abort("tmpfs and kmsg handoff events differ")
print(session["CAPTURE_SESSION"])
PY
)" || fail_evidence 'trusted witness bundle validation failed'

receipt_target="$registry/receipts/$session.receipt"
signature_target="$registry/receipts/$session.sig"
# The fixed root witness already published this exact receipt pair atomically
# before returning its bundle.  Re-publishing would always collide; verify the
# durable ledger copy instead, then publish only the caller-owned attempt.
test -f "$receipt_target" && test ! -L "$receipt_target" && test -f "$signature_target" && test ! -L "$signature_target" || fail_evidence 'trusted witness receipt ledger is unavailable'
/usr/bin/cmp -s "$scratch/verified-bundle/receipt.env" "$receipt_target" || fail_evidence 'trusted witness receipt ledger differs from verified bundle'
/usr/bin/cmp -s "$scratch/verified-bundle/receipt.sig" "$signature_target" || fail_evidence 'trusted witness signature ledger differs from verified bundle'
"$safe_tree" publish-tree "$scratch/verified-bundle/attempt" "$attempt_dir" || fail_evidence 'trusted witness attempt publication failed'

printf 'M1_CAPTURE_RECEIPT=%s\n' "$session"
