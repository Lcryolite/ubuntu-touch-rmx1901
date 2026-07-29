#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${HALIUM_ROOT:?set HALIUM_ROOT to the Halium 11 source tree}"

partition_size=67108864
provenance="$repo_root/artifacts/supply-chain/rmx1901-safe-initrd-arm64.provenance.json"
provenance_validator="$repo_root/scripts/validate-safe-halium-initrd-provenance.py"
cmdline_manifest="$repo_root/config/m1-cmdline-v1.json"
predecessor_lock="$repo_root/config/m1-predecessor-v1.json"
safe_file="$repo_root/scripts/m1-safe-file.py"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  die 'usage: verify-m1-predecessor-boot.sh PREDECESSOR-BOOT.IMG CANDIDATE-BOOT.IMG'
}

test "$#" -eq 2 || usage
predecessor="$1"
candidate="$2"

require_full_regular_image() {
  local label="$1" path="$2"
  test ! -L "$path" || die "$label must not be a symlink"
  test -f "$path" || die "$label must be a regular file"
  test "$(stat -c %F -- "$path")" = 'regular file' || die "$label must be a regular file"
  test "$(stat -c %s -- "$path")" -eq "$partition_size" || \
    die "$label must be exactly $partition_size bytes"
}

require_full_regular_image predecessor "$predecessor"
require_full_regular_image candidate "$candidate"
test -f "$provenance" && test -x "$provenance_validator" || \
  die 'safe initrd provenance inputs are missing'
test -f "$cmdline_manifest" || die 'M1 cmdline manifest is missing'
test -f "$predecessor_lock" || die 'M1 predecessor lock is missing'
test -x "$safe_file" || die 'M1 safe-file helper is missing'

mapfile -t locked_predecessor < <(python3 - "$predecessor_lock" "$partition_size" <<'PY'
import json
import pathlib
import re
import sys

data = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if set(data) != {"schema", "device", "boot_partition_size", "boot_sha256",
                 "kernel_payload_sha256"}:
    raise SystemExit("M1 predecessor lock has an invalid key set")
if (data["schema"], data["device"], data["boot_partition_size"]) != (
        "rmx1901-m1-predecessor-v1", "RMX1901", int(sys.argv[2])):
    raise SystemExit("M1 predecessor lock identity or geometry is invalid")
for key in ("boot_sha256", "kernel_payload_sha256"):
    if not isinstance(data[key], str) or not re.fullmatch(r"[0-9a-f]{64}", data[key]):
        raise SystemExit(f"M1 predecessor lock has an invalid {key}")
print(data["boot_sha256"])
print(data["kernel_payload_sha256"])
PY
)
test "${#locked_predecessor[@]}" -eq 2 || die 'M1 predecessor lock is invalid'
expected_predecessor_sha="${locked_predecessor[0]}"
expected_kernel_sha="${locked_predecessor[1]}"
test "$(sha256sum "$predecessor" | awk '{print $1}')" = "$expected_predecessor_sha" || \
  die 'predecessor SHA-256 does not match M1 lock'

if test -x "$HALIUM_ROOT/out/host/linux-x86/bin/unpack_bootimg"; then
  unpack_kind=exec
  unpack_tool="$HALIUM_ROOT/out/host/linux-x86/bin/unpack_bootimg"
elif test -f "$HALIUM_ROOT/system/tools/mkbootimg/unpack_bootimg.py"; then
  unpack_kind=python
  unpack_tool="$HALIUM_ROOT/system/tools/mkbootimg/unpack_bootimg.py"
else
  die 'Halium tree unpack_bootimg is unavailable'
fi
avbtool="$HALIUM_ROOT/out/host/linux-x86/bin/avbtool"
test -x "$avbtool" || die 'Halium tree avbtool is unavailable'

mapfile -t release < <(python3 "$provenance_validator" "$provenance")
test "${#release[@]}" -eq 6 || die 'safe initrd provenance is invalid'
expected_ramdisk_size="${release[2]}"
expected_ramdisk_sha="${release[3]}"
expected_source_commit="${release[5]}"

expected_cmdline="$(python3 - "$cmdline_manifest" "$partition_size" <<'PY'
import json
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
partition_size = int(sys.argv[2])
data = json.loads(path.read_text(encoding="utf-8"))
expected_keys = {
    "schema", "device", "boot_header_version", "boot_partition_size",
    "avb_algorithm", "additional_cmdline", "tokens",
}
if set(data) != expected_keys:
    raise SystemExit("M1 cmdline manifest has an invalid key set")
if data["schema"] != "rmx1901-m1-cmdline-v1" or data["device"] != "RMX1901":
    raise SystemExit("M1 cmdline manifest identity is invalid")
if data["boot_header_version"] != 1 or data["boot_partition_size"] != partition_size:
    raise SystemExit("M1 cmdline manifest boot geometry is invalid")
if data["avb_algorithm"] != "NONE" or data["additional_cmdline"] != "":
    raise SystemExit("M1 cmdline manifest AVB/additional cmdline contract is invalid")
tokens = data["tokens"]
if not isinstance(tokens, list) or not tokens:
    raise SystemExit("M1 cmdline token list is empty")
for token in tokens:
    if not isinstance(token, str) or not re.fullmatch(r"[!-~]+", token):
        raise SystemExit("M1 cmdline token is not one printable ASCII word")
if len(tokens) != len(set(tokens)):
    raise SystemExit("M1 cmdline token list contains a duplicate")
required = {
    "systempart=/dev/disk/by-partlabel/system",
    "systemd.unified_cgroup_hierarchy=0",
    "console=tty0",
    "rmx1901.debug_rndis=1",
}
if not required.issubset(tokens):
    raise SystemExit("M1 cmdline is missing a required observation token")
cmdline = " ".join(tokens)
# Header v1 splits byte 512 onward into extra_cmdline.  Reserve one NUL byte
# so every declared token remains in the bootloader-visible main field.
if len(cmdline.encode("ascii")) > 511:
    raise SystemExit("M1 main cmdline does not fit header v1 main field")
print(cmdline)
PY
)" || die 'M1 cmdline manifest validation failed'
test -n "$expected_cmdline" || die 'M1 cmdline manifest produced an empty cmdline'

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/verify-m1-predecessor-boot.XXXXXX")"
trap 'rm -rf -- "$tmp_root"' EXIT
chmod 700 "$tmp_root"
mkdir -p "$tmp_root/predecessor" "$tmp_root/candidate"

# All validation consumes private descriptor-derived snapshots.  The helper
# rejects symlinks, identity/size changes during read, hash drift, and partial
# copies before these paths become authoritative.
"$safe_file" snapshot "$predecessor" "$tmp_root/predecessor/boot.img" \
  "$partition_size" "$expected_predecessor_sha" >/dev/null
candidate_snapshot_sha="$("$safe_file" snapshot "$candidate" \
  "$tmp_root/candidate/boot.img" "$partition_size" -)"
"$safe_file" verify "$predecessor" "$partition_size" "$expected_predecessor_sha" >/dev/null
"$safe_file" verify "$candidate" "$partition_size" "$candidate_snapshot_sha" >/dev/null

unpack_image() {
  local image="$1" out="$2" report="$3"
  if test "$unpack_kind" = exec; then
    "$unpack_tool" --boot_img "$image" --out "$out" >"$report"
  else
    python3 "$unpack_tool" --boot_img "$image" --out "$out" >"$report"
  fi
}

unpack_image "$tmp_root/predecessor/boot.img" "$tmp_root/predecessor" \
  "$tmp_root/predecessor-unpack.txt"
unpack_image "$tmp_root/candidate/boot.img" "$tmp_root/candidate" \
  "$tmp_root/candidate-unpack.txt"

python3 - "$tmp_root/predecessor-unpack.txt" "$tmp_root/candidate-unpack.txt" \
  "$expected_cmdline" <<'PY'
import pathlib
import sys

pre_path, candidate_path, expected_cmdline = sys.argv[1:]
labels = (
    "boot_magic", "kernel_size", "kernel load address", "ramdisk size",
    "ramdisk load address", "second bootloader size",
    "second bootloader load address", "kernel tags load address", "page size",
    "os version", "os patch level", "boot image header version", "product name",
    "command line args", "additional command line args", "recovery dtbo size",
    "recovery dtbo offset", "boot header size",
)

def parse(path):
    values = {}
    for line in pathlib.Path(path).read_text(encoding="utf-8").splitlines():
        if ": " not in line:
            raise SystemExit(f"invalid unpack report line: {line!r}")
        key, value = line.split(": ", 1)
        if key in values:
            raise SystemExit(f"duplicate unpack report field: {key}")
        values[key] = value
    if set(values) != set(labels):
        missing = sorted(set(labels) - set(values))
        extra = sorted(set(values) - set(labels))
        raise SystemExit(f"unexpected unpack fields: missing={missing} extra={extra}")
    return values

pre = parse(pre_path)
candidate = parse(candidate_path)
if pre["boot_magic"] != "ANDROID!" or candidate["boot_magic"] != "ANDROID!":
    raise SystemExit("M1 boot magic is invalid")
if pre["boot image header version"] != "1" or candidate["boot image header version"] != "1":
    raise SystemExit("M1 requires boot header v1")
if candidate["additional command line args"] != "":
    raise SystemExit("M1 candidate additional cmdline is not empty")
if candidate["command line args"] != expected_cmdline:
    raise SystemExit("M1 candidate main cmdline does not equal the token manifest")

# These are the only Android boot-header fields that may change in M1.  The
# locked predecessor is the observed image whose header-v1 tail spilled into
# extra_cmdline; M1 deliberately moves those tokens into the main field and
# requires the candidate additional field to be empty.
allowed_changes = {"ramdisk size", "command line args", "additional command line args"}
for label in labels:
    if label not in allowed_changes and pre[label] != candidate[label]:
        raise SystemExit(f"M1 candidate changed predecessor header field {label!r}")
PY

test -f "$tmp_root/predecessor/kernel" && test -f "$tmp_root/candidate/kernel" || \
  die 'unpack did not produce both kernel payloads'
test "$(sha256sum "$tmp_root/predecessor/kernel" | awk '{print $1}')" = "$expected_kernel_sha" || \
  die 'predecessor kernel payload SHA-256 does not match M1 lock'
cmp -s "$tmp_root/predecessor/kernel" "$tmp_root/candidate/kernel" || \
  die 'M1 candidate kernel is not byte-identical to predecessor kernel'

for optional_payload in second recovery_dtbo; do
  predecessor_payload="$tmp_root/predecessor/$optional_payload"
  candidate_payload="$tmp_root/candidate/$optional_payload"
  if test -e "$predecessor_payload" || test -e "$candidate_payload"; then
    test -f "$predecessor_payload" && test -f "$candidate_payload" || \
      die "M1 candidate changed optional payload presence: $optional_payload"
    cmp -s "$predecessor_payload" "$candidate_payload" || \
      die "M1 candidate changed optional payload: $optional_payload"
  fi
done

candidate_ramdisk="$tmp_root/candidate/ramdisk"
test -f "$candidate_ramdisk" || die 'unpack did not produce candidate ramdisk'
test "$(stat -c %s "$candidate_ramdisk")" -eq "$expected_ramdisk_size" || \
  die 'M1 candidate ramdisk size does not match released provenance'
test "$(sha256sum "$candidate_ramdisk" | awk '{print $1}')" = "$expected_ramdisk_sha" || \
  die 'M1 candidate ramdisk SHA-256 does not match released provenance'

"$avbtool" verify_image --image "$tmp_root/predecessor/boot.img" \
  >"$tmp_root/predecessor-avb-verify.txt" 2>&1 || \
  die 'predecessor boot AVB verification failed'
"$avbtool" verify_image --image "$tmp_root/candidate/boot.img" \
  >"$tmp_root/candidate-avb-verify.txt" 2>&1 || \
  die 'M1 candidate boot AVB verification failed'
"$avbtool" info_image --image "$tmp_root/predecessor/boot.img" \
  >"$tmp_root/predecessor-avb-info.raw" 2>&1 || \
  die 'predecessor AVB metadata is unreadable'
"$avbtool" info_image --image "$tmp_root/candidate/boot.img" \
  >"$tmp_root/candidate-avb-info.raw" 2>&1 || \
  die 'M1 candidate AVB metadata is unreadable'
sed 's/[[:space:]]*$//' "$tmp_root/predecessor-avb-info.raw" \
  >"$tmp_root/predecessor-avb-info.txt"
sed 's/^[[:space:]]*//' "$tmp_root/candidate-avb-info.raw" \
  >"$tmp_root/candidate-avb-info.txt"

# Preserve every AVB field and descriptor from the locked predecessor.  The
# payload digest is the sole semantic value that must change when ramdisk and
# cmdline change; salt is intentionally preserved to make repacks reproducible.
python3 - "$tmp_root/predecessor-avb-info.raw" \
  "$tmp_root/candidate-avb-info.raw" \
  "$tmp_root/predecessor-unpack.txt" "$tmp_root/candidate-unpack.txt" <<'PY'
import pathlib
import re
import sys

def unpack_values(path):
    values = {}
    for line in pathlib.Path(path).read_text(encoding="utf-8").splitlines():
        key, value = line.split(": ", 1)
        values[key] = value
    return values

def derived_raw_size(path):
    values = unpack_values(path)
    page = int(values["page size"])
    sizes = [int(values["kernel_size"]), int(values["ramdisk size"]),
             int(values["second bootloader size"])]
    recovery_size = int(values["recovery dtbo size"])
    if recovery_size:
        sizes.append(recovery_size)
    return page + sum(((size + page - 1) // page) * page for size in sizes)

def one_number(lines, pattern, name):
    values = []
    for line in lines:
        match = re.fullmatch(pattern, line)
        if match:
            values.append(int(match.group(1)))
    if len(values) != 1:
        raise SystemExit(f"AVB info has invalid {name}")
    return values[0]

def normalize(path, expected_raw_size):
    text = pathlib.Path(path).read_text(encoding="utf-8")
    lines = [line.rstrip() for line in text.splitlines()]
    original_size = one_number(lines, r"Original image size:\s+(\d+) bytes", "original image size")
    vbmeta_offset = one_number(lines, r"VBMeta offset:\s+(\d+)", "VBMeta offset")
    descriptor_size = one_number(lines, r"\s+Image Size:\s+(\d+) bytes", "hash descriptor image size")
    if (original_size, vbmeta_offset, descriptor_size) != (
            expected_raw_size, expected_raw_size, expected_raw_size):
        raise SystemExit(
            "AVB payload size/offset fields do not equal derived Android boot size")
    digest_indexes = [i for i, line in enumerate(lines)
                      if re.fullmatch(r"\s+Digest:\s+[0-9a-f]{64}", line)]
    if len(digest_indexes) != 1:
        raise SystemExit("AVB info must contain exactly one hash digest")
    i = digest_indexes[0]
    lines[i] = re.sub(r"[0-9a-f]{64}$", "<PAYLOAD-DIGEST>", lines[i])
    for i, line in enumerate(lines):
        if re.fullmatch(r"Original image size:\s+\d+ bytes", line):
            lines[i] = "Original image size:      <DERIVED> bytes"
        elif re.fullmatch(r"VBMeta offset:\s+\d+", line):
            lines[i] = "VBMeta offset:            <DERIVED>"
        elif re.fullmatch(r"\s+Image Size:\s+\d+ bytes", line):
            indent = line[:len(line) - len(line.lstrip())]
            lines[i] = f"{indent}Image Size:            <DERIVED> bytes"
    return lines

predecessor = normalize(sys.argv[1], derived_raw_size(sys.argv[3]))
candidate = normalize(sys.argv[2], derived_raw_size(sys.argv[4]))
if predecessor != candidate:
    for index, (left, right) in enumerate(zip(predecessor, candidate), 1):
        if left != right:
            raise SystemExit(
                f"candidate AVB differs from predecessor at line {index}: "
                f"{left!r} != {right!r}")
    raise SystemExit("candidate AVB field/descriptor count differs from predecessor")
PY

require_avb_line() {
  local line="$1"
  test "$(grep -Fxc -- "$line" "$tmp_root/candidate-avb-info.txt" || true)" -eq 1 || \
    die "M1 candidate AVB metadata mismatch: $line"
}
require_avb_regex() {
  local regex="$1"
  test "$(grep -Exc -- "$regex" "$tmp_root/candidate-avb-info.txt" || true)" -eq 1 || \
    die "M1 candidate AVB metadata mismatch: $regex"
}

require_avb_line 'Footer version:           1.0'
require_avb_line "Image size:               $partition_size bytes"
require_avb_line 'Algorithm:                NONE'
require_avb_line 'Hash Algorithm:        sha256'
require_avb_line 'Partition Name:        boot'
require_avb_regex 'Salt:                  [0-9a-f]{64}'
require_avb_regex 'Digest:                [0-9a-f]{64}'

"$safe_file" verify "$predecessor" "$partition_size" "$expected_predecessor_sha" >/dev/null
"$safe_file" verify "$candidate" "$partition_size" "$candidate_snapshot_sha" >/dev/null
candidate_sha="$candidate_snapshot_sha"
printf 'm1_predecessor_boot_gate=pass\n'
printf 'predecessor_sha256=%s\n' "$expected_predecessor_sha"
printf 'candidate_sha256=%s\n' "$candidate_sha"
printf 'kernel_sha256=%s\n' "$(sha256sum "$tmp_root/candidate/kernel" | awk '{print $1}')"
printf 'ramdisk_sha256=%s\n' "$expected_ramdisk_sha"
printf 'ramdisk_source_commit=%s\n' "$expected_source_commit"
