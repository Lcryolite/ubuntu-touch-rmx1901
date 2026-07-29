#!/bin/bash -p
set -euo pipefail
PATH=/usr/bin:/bin
export PATH

if test "$#" -ne 3; then
  echo 'invalid compare argument count' >&2
  exit 10
fi
source_attempt_a="$1"
source_attempt_b="$2"
expected_tokens="$3"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
validator="$repo_root/scripts/validate-m1-attempt.sh"
safe_file="$repo_root/scripts/m1-safe-file.py"
safe_tree="$repo_root/scripts/m1-evidence-snapshot.py"
fixed_trust=/usr/local/libexec/rmx1901-m1-control/fixed-trust
trust_root=/var/lib/rmx1901-m1-control
source_registry="$trust_root/registry"
source_public_key="$trust_root/witness-ed25519.pub"
source_public_key_sha="$trust_root/witness-ed25519.sha256"
umask 077

if test -n "${M1_CAPTURE_WITNESS:-}" || test -n "${M1_WITNESS_PUBLIC_KEY:-}" || \
   test -n "${M1_RECEIPT_REGISTRY:-}" || test -n "${M1_READONLY_RUNNER:-}" || \
   test -n "${M1_RECEIPT_SIGNER:-}"; then
  echo 'caller-selectable witness trust bootstrap is forbidden' >&2
  exit 20
fi
"$fixed_trust" check || exit 20

die() { echo "$1" >&2; exit 20; }
test -d "$source_attempt_a" && test ! -L "$source_attempt_a" || die 'M1 attempt A is missing or unsafe'
test -d "$source_attempt_b" && test ! -L "$source_attempt_b" || die 'M1 attempt B is missing or unsafe'
base_a="$(basename "$source_attempt_a")"
base_b="$(basename "$source_attempt_b")"
[[ "$base_a" =~ ^[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'M1 attempt A basename is invalid'
[[ "$base_b" =~ ^[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'M1 attempt B basename is invalid'
test "$base_a" != "$base_b" || die 'M1 attempt basenames are not distinct'

# Snapshot every caller-owned input through an opened descriptor.  Validation
# and comparison consume only these private, read-only bytes; caller paths are
# never reopened after this boundary.
snapshot_root="$(mktemp -d "${TMPDIR:-/tmp}/m1-compare-snapshot.XXXXXX")"
trap 'chmod -R u+w "$snapshot_root" 2>/dev/null || true; rm -rf -- "$snapshot_root"' EXIT
attempt_a="$snapshot_root/$base_a"
attempt_b="$snapshot_root/$base_b"
"$safe_tree" snapshot-tree "$source_attempt_a" "$attempt_a" >/dev/null 2>&1 || die 'M1 attempt A descriptor snapshot failed'
"$safe_tree" snapshot-tree "$source_attempt_b" "$attempt_b" >/dev/null 2>&1 || die 'M1 attempt B descriptor snapshot failed'
mkdir -m 700 -p "$snapshot_root/trust/receipts"

session_from_snapshot() {
  local attempt="$1" session
  test -f "$attempt/capture-session.env" && test ! -L "$attempt/capture-session.env" || die 'capture session evidence is missing'
  session="$(sed -n 's/^CAPTURE_SESSION=//p' "$attempt/capture-session.env")"
  test "$(grep -c '^CAPTURE_SESSION=' "$attempt/capture-session.env")" -eq 1 || die 'capture session evidence is ambiguous'
  [[ "$session" =~ ^m1-[0-9a-f]{32}$ ]] || die 'capture session evidence is invalid'
  printf '%s\n' "$session"
}
session_a="$(session_from_snapshot "$attempt_a")"
session_b="$(session_from_snapshot "$attempt_b")"
test "$session_a" != "$session_b" || die 'capture sessions are not distinct'

test -f "$source_public_key" && test ! -L "$source_public_key" || die 'trusted capture receipt public key is unavailable'
"$safe_file" snapshot "$source_public_key" "$snapshot_root/trust/public.pem" - - >/dev/null 2>&1 || die 'public key descriptor snapshot failed'
"$safe_file" snapshot "$source_public_key_sha" "$snapshot_root/trust/public.sha256" - - >/dev/null 2>&1 || die 'public key fingerprint descriptor snapshot failed'
/usr/bin/python3 - "$snapshot_root/trust/public.pem" "$snapshot_root/trust/public.sha256" <<'PY' || die 'fixed M1 public key fingerprint changed during snapshot'
import hashlib, re, sys
raw = open(sys.argv[2], "r", encoding="ascii", newline="").read()
if not re.fullmatch(r"[0-9a-f]{64}\n", raw):
    raise SystemExit(1)
if hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest() != raw[:-1]:
    raise SystemExit(1)
PY
for session in "$session_a" "$session_b"; do
  for suffix in receipt sig; do
    source_receipt="$source_registry/receipts/$session.$suffix"
    test -f "$source_receipt" && test ! -L "$source_receipt" || die 'trusted capture receipt is missing or unsafe'
    "$safe_file" snapshot "$source_receipt" "$snapshot_root/trust/receipts/$session.$suffix" - - >/dev/null 2>&1 || die 'trusted capture receipt descriptor snapshot failed'
  done
done
"$safe_file" snapshot "$expected_tokens" "$snapshot_root/expected.txt" - - >/dev/null 2>&1 || {
  echo 'M1 expected cmdline token descriptor snapshot failed' >&2; exit 10;
}
expected_tokens="$snapshot_root/expected.txt"

# Preserve the validator's §17.2 status (notably 50 identity/partition and 60
# write/readback) instead of collapsing all failures into evidence status 20.
set +e
"$validator" "$attempt_a" "$expected_tokens" >"$snapshot_root/validation-a.env"
status_a=$?
set -e
test "$status_a" -eq 0 || exit "$status_a"
set +e
"$validator" "$attempt_b" "$expected_tokens" >"$snapshot_root/validation-b.env"
status_b=$?
set -e
test "$status_b" -eq 0 || exit "$status_b"

/usr/bin/python3 - "$attempt_a" "$attempt_b" "$snapshot_root/trust" "$snapshot_root/trust/public.pem" "$snapshot_root/validation-a.env" "$snapshot_root/validation-b.env" <<'PY'
import hashlib
import re
import subprocess
import sys
from pathlib import Path

a = Path(sys.argv[1])
b = Path(sys.argv[2])
registry = Path(sys.argv[3])
public_key = Path(sys.argv[4])
validation_a = Path(sys.argv[5])
validation_b = Path(sys.argv[6])


def die(message, status=20):
    print(message, file=sys.stderr)
    raise SystemExit(status)


def env(path):
    result = {}
    for line in path.read_text(encoding="ascii").splitlines():
        key, value = line.split("=", 1)
        result[key] = value
    return result


def same_file(relative, label=None, status=20):
    left = (a / relative).read_bytes()
    right = (b / relative).read_bytes()
    if left != right:
        die(label or f"M1 attempt evidence mismatch: {relative}", status)


def same_netdev():
    # Gadget, bond and dummy MAC addresses are generated anew on each boot.
    # Preserve interface names, ordering and link state while excluding only
    # six-octet Ethernet identities from the repeatability comparison.
    redact = lambda raw: re.sub(rb"(?i)(?:[0-9a-f]{2}:){5}[0-9a-f]{2}", b"<MAC>", raw)
    if redact((a / "runtime/netdev.txt").read_bytes()) != redact((b / "runtime/netdev.txt").read_bytes()):
        die("runtime evidence mismatch: runtime/netdev.txt")


meta_a = env(a / "attempt.env")
meta_b = env(b / "attempt.env")
session_a = env(a / "capture-session.env")
session_b = env(b / "capture-session.env")

if meta_a["ATTEMPT_ID"] == meta_b["ATTEMPT_ID"]:
    die("M1 attempts are not distinct: ATTEMPT_ID")
for key in ("CAPTURE_NONCE", "CAPTURE_TIMESTAMP"):
    if meta_a[key] == meta_b[key]:
        die(f"M1 attempts are not distinct: {key}")
if session_a["CAPTURE_SESSION"] == session_b["CAPTURE_SESSION"]:
    die("M1 attempts are not distinct: CAPTURE_SESSION")
boot_id_a = (a / "runtime/boot-id.txt").read_text(encoding="ascii").strip()
boot_id_b = (b / "runtime/boot-id.txt").read_text(encoding="ascii").strip()
if boot_id_a == boot_id_b:
    die("M1 attempts are not distinct kernel boots: BOOT_ID")

receipt_a_path = registry / "receipts" / f"{session_a['CAPTURE_SESSION']}.receipt"
receipt_b_path = registry / "receipts" / f"{session_b['CAPTURE_SESSION']}.receipt"
signature_a_path = registry / "receipts" / f"{session_a['CAPTURE_SESSION']}.sig"
signature_b_path = registry / "receipts" / f"{session_b['CAPTURE_SESSION']}.sig"

key_check = subprocess.run(
    ["/usr/bin/openssl", "pkey", "-pubin", "-in", str(public_key), "-text", "-noout"],
    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
)
if key_check.returncode != 0 or not key_check.stdout.startswith("ED25519 Public-Key:\n"):
    die("trusted capture receipt public key is not Ed25519")
for receipt_path, signature_path in (
    (receipt_a_path, signature_a_path), (receipt_b_path, signature_b_path),
):
    verified = subprocess.run(
        ["/usr/bin/openssl", "pkeyutl", "-verify", "-rawin", "-pubin", "-inkey", str(public_key),
         "-in", str(receipt_path), "-sigfile", str(signature_path)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    if verified.returncode != 0:
        die("trusted capture receipt signature is invalid")
receipt_a = env(receipt_a_path)
receipt_b = env(receipt_b_path)

def bind_receipt(receipt, attempt, metadata, session):
    wanted = {
        "RECEIPT_SCHEMA": "RMX1901-M1-SIGNED-RECEIPT-V1",
        "ATTEMPT_ID": metadata["ATTEMPT_ID"],
        "CAPTURE_DIRECTORY": session["CAPTURE_DIRECTORY"],
        "CAPTURE_SESSION": session["CAPTURE_SESSION"],
        "CAPTURE_NONCE": metadata["CAPTURE_NONCE"],
        "CAPTURE_TIMESTAMP": metadata["CAPTURE_TIMESTAMP"],
        "BOOT_ID": (attempt / "runtime/boot-id.txt").read_text(encoding="ascii").strip(),
        "CAPTURE_MANIFEST_SHA256": hashlib.sha256((attempt / "capture-SHA256SUMS").read_bytes()).hexdigest(),
    }
    if set(receipt) != set(wanted) | {"SIGNER_SEQUENCE", "SIGNER_PREVIOUS_SHA256"}:
        die("trusted capture receipt field coverage is invalid")
    for key, value in wanted.items():
        if receipt.get(key) != value:
            die(f"trusted capture receipt binding mismatch: {key}")

bind_receipt(receipt_a, a, meta_a, session_a)
bind_receipt(receipt_b, b, meta_b, session_b)
sequence_a = int(receipt_a["SIGNER_SEQUENCE"])
sequence_b = int(receipt_b["SIGNER_SEQUENCE"])
receipt_a_sha = hashlib.sha256(receipt_a_path.read_bytes()).hexdigest()
if sequence_b != sequence_a + 1 or receipt_b["SIGNER_PREVIOUS_SHA256"] != receipt_a_sha:
    die("signed capture receipts are not one direct host session chain")
if validation_a.read_bytes() != validation_b.read_bytes():
    die("validated M1 failure boundary evidence differs")

# Compare readback first so an individually valid predecessor change cannot be
# hidden behind the corresponding metadata change.
same_file("write-readback.env", "write-readback evidence mismatch", 60)
same_file("preflight.env", "preflight evidence mismatch", 50)

runtime_files = [
    "runtime/pid1-comm.txt", "runtime/pid1-exe.txt", "runtime/pid1-cmdline.txt",
    "runtime/mounts.txt", "runtime/journal.txt", "runtime/failed-units.txt",
    "runtime/configfs.txt", "runtime/systemd-confirmed.env",
]
for relative in runtime_files:
    same_file(relative, f"runtime evidence mismatch: {relative}")
same_netdev()

# Every non-session metadata field is an invariant across the two attempts.
for key in (
    "SPEC_VERSION", "UNIQUE_VARIABLE", "SOURCE_COMMIT", "INITRD_SHA256",
    "BOOT_SHA256", "TOOLCHAIN_SHA256", "SOURCE_TREE_SHA256", "SOURCE_DIRTY",
    "INPUT_SHA256", "OUTPUT_SHA256", "PREDECESSOR_SHA256",
):
    if meta_a[key] != meta_b[key]:
        status = 50 if key in ("INPUT_SHA256", "PREDECESSOR_SHA256") else 30
        die(f"metadata mismatch: {key}", status)

for relative in ("boot-unpack.txt", "proc-cmdline.txt"):
    same_file(relative, status=30)
for relative in ("handoff-events.log", "transport.env", "usb-state.env", "result.env"):
    same_file(relative)

print("M1_ATTEMPTS_EQUIVALENT=YES")
PY
