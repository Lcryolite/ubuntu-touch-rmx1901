#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${HALIUM_ROOT:?set HALIUM_ROOT to the Halium 11 source tree}"

partition_size=67108864
provenance="$repo_root/artifacts/supply-chain/rmx1901-safe-initrd-arm64.provenance.json"
provenance_validator="$repo_root/scripts/validate-safe-halium-initrd-provenance.py"
cmdline_manifest="$repo_root/config/m1-cmdline-v1.json"
predecessor_lock="$repo_root/config/m1-predecessor-v1.json"
verifier="$repo_root/scripts/verify-m1-predecessor-boot.sh"
safe_file="$repo_root/scripts/m1-safe-file.py"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

test "$#" -eq 3 || \
  die 'usage: repack-m1-predecessor-boot.sh PREDECESSOR-BOOT.IMG RELEASED-INITRD OUTPUT-BOOT.IMG'
predecessor="$1"
released_initrd="$2"
output="$3"

require_regular_nonlink() {
  local label="$1" path="$2"
  test ! -L "$path" || die "$label must not be a symlink"
  test -f "$path" || die "$label must be a regular file"
  test "$(stat -c %F -- "$path")" = 'regular file' || die "$label must be a regular file"
}

require_regular_nonlink predecessor "$predecessor"
test "$(stat -c %s -- "$predecessor")" -eq "$partition_size" || \
  die "predecessor must be exactly $partition_size bytes"
require_regular_nonlink released-initrd "$released_initrd"
test ! -e "$output" && test ! -L "$output" || die 'output path already exists'
output_parent="$(dirname "$output")"
test -d "$output_parent" || die 'output parent directory does not exist'
test ! -L "$output_parent" || die 'output parent directory must not be a symlink'

test -f "$provenance" && test -x "$provenance_validator" || \
  die 'safe initrd provenance inputs are missing'
test -f "$cmdline_manifest" && test -f "$predecessor_lock" && \
  test -x "$verifier" && test -x "$safe_file" || \
  die 'M1 boot contract inputs are missing'

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

mapfile -t release < <(python3 "$provenance_validator" "$provenance")
test "${#release[@]}" -eq 6 || die 'safe initrd provenance is invalid'
test "$(stat -c %s "$released_initrd")" -eq "${release[2]}" || \
  die 'released initrd size does not match immutable provenance'
test "$(sha256sum "$released_initrd" | awk '{print $1}')" = "${release[3]}" || \
  die 'released initrd SHA-256 does not match immutable provenance'

expected_cmdline="$(python3 - "$cmdline_manifest" "$partition_size" <<'PY'
import json
import pathlib
import re
import sys

data = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if set(data) != {"schema", "device", "boot_header_version", "boot_partition_size",
                 "avb_algorithm", "additional_cmdline", "tokens"}:
    raise SystemExit("M1 cmdline manifest has an invalid key set")
if (data["schema"], data["device"], data["boot_header_version"],
        data["boot_partition_size"], data["avb_algorithm"],
        data["additional_cmdline"]) != (
        "rmx1901-m1-cmdline-v1", "RMX1901", 1, int(sys.argv[2]), "NONE", ""):
    raise SystemExit("M1 cmdline manifest contract is invalid")
tokens = data["tokens"]
if not isinstance(tokens, list) or not tokens or len(tokens) != len(set(tokens)):
    raise SystemExit("M1 cmdline token list is empty or contains duplicates")
if any(not isinstance(token, str) or not re.fullmatch(r"[!-~]+", token)
       for token in tokens):
    raise SystemExit("M1 cmdline token is not one printable ASCII word")
required = {"systempart=/dev/disk/by-partlabel/system",
            "systemd.unified_cgroup_hierarchy=0", "console=tty0",
            "rmx1901.debug_rndis=1"}
if not required.issubset(tokens):
    raise SystemExit("M1 cmdline is missing a required observation token")
cmdline = " ".join(tokens)
if len(cmdline.encode("ascii")) > 511:
    raise SystemExit("M1 main cmdline does not fit header v1 main field")
print(cmdline)
PY
)" || die 'M1 cmdline manifest validation failed'

if test -x "$HALIUM_ROOT/out/host/linux-x86/bin/unpack_bootimg"; then
  unpack_kind=exec
  unpack_tool="$HALIUM_ROOT/out/host/linux-x86/bin/unpack_bootimg"
elif test -f "$HALIUM_ROOT/system/tools/mkbootimg/unpack_bootimg.py"; then
  unpack_kind=python
  unpack_tool="$HALIUM_ROOT/system/tools/mkbootimg/unpack_bootimg.py"
else
  die 'Halium tree unpack_bootimg is unavailable'
fi
if test -x "$HALIUM_ROOT/out/host/linux-x86/bin/mkbootimg"; then
  mkboot_kind=exec
  mkboot_tool="$HALIUM_ROOT/out/host/linux-x86/bin/mkbootimg"
elif test -f "$HALIUM_ROOT/system/tools/mkbootimg/mkbootimg.py"; then
  mkboot_kind=python
  mkboot_tool="$HALIUM_ROOT/system/tools/mkbootimg/mkbootimg.py"
else
  die 'Halium tree mkbootimg is unavailable'
fi
avbtool="$HALIUM_ROOT/out/host/linux-x86/bin/avbtool"
test -x "$avbtool" || die 'Halium tree avbtool is unavailable'

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/repack-m1-predecessor-boot.XXXXXX")"
chmod 700 "$tmp_root"
candidate_tmp="$tmp_root/candidate-build.img"
candidate_snapshot="$tmp_root/candidate-snapshot.img"
predecessor_snapshot="$tmp_root/predecessor.img"
initrd_snapshot="$tmp_root/released-initrd.img"
published_sha=
cleanup() {
  rm -rf -- "$tmp_root"
}
trap cleanup EXIT
mkdir -p "$tmp_root/predecessor"
"$safe_file" snapshot "$predecessor" "$predecessor_snapshot" \
  "$partition_size" "$expected_predecessor_sha" >/dev/null
"$safe_file" snapshot "$released_initrd" "$initrd_snapshot" \
  "${release[2]}" "${release[3]}" >/dev/null

test_replace_path() {
  local target="$1" replacement="$2"
  local staged="${target}.m1-test-replacement.$$"
  "$safe_file" snapshot "$replacement" "$staged" - - >/dev/null
  python3 - "$target" "$staged" <<'PY'
import os, sys
os.replace(sys.argv[2], sys.argv[1])
PY
}

hook_vars=(
  M1_REPACK_TEST_REPLACE_PREDECESSOR_WITH
  M1_REPACK_TEST_REPLACE_INITRD_WITH
  M1_REPACK_TEST_REPLACE_CANDIDATE_WITH
  M1_REPACK_TEST_CREATE_DESTINATION_FROM
  M1_REPACK_TEST_REPLACE_PUBLISHED_WITH
)
if test "${M1_REPACK_TEST_HOOKS:-0}" != 1; then
  for hook_var in "${hook_vars[@]}"; do
    test -z "${!hook_var:-}" || die 'M1 repack test hook supplied without explicit test mode'
  done
fi
if test "${M1_REPACK_TEST_HOOKS:-0}" = 1; then
  if test -n "${M1_REPACK_TEST_REPLACE_PREDECESSOR_WITH:-}"; then
    test_replace_path "$predecessor" "$M1_REPACK_TEST_REPLACE_PREDECESSOR_WITH"
  fi
  if test -n "${M1_REPACK_TEST_REPLACE_INITRD_WITH:-}"; then
    test_replace_path "$released_initrd" "$M1_REPACK_TEST_REPLACE_INITRD_WITH"
  fi
fi
"$safe_file" verify "$predecessor" "$partition_size" "$expected_predecessor_sha" >/dev/null
"$safe_file" verify "$released_initrd" "${release[2]}" "${release[3]}" >/dev/null

if test "$unpack_kind" = exec; then
  "$unpack_tool" --boot_img "$predecessor_snapshot" \
    --out "$tmp_root/predecessor" >"$tmp_root/predecessor-unpack.txt"
else
  python3 "$unpack_tool" --boot_img "$predecessor_snapshot" \
    --out "$tmp_root/predecessor" >"$tmp_root/predecessor-unpack.txt"
fi

report_value() {
  local label="$1" report="$tmp_root/predecessor-unpack.txt" count
  count="$(grep -c "^${label}: " "$report" || true)"
  test "$count" -eq 1 || die "predecessor unpack field is missing or duplicated: $label"
  sed -n "s/^${label}: //p" "$report"
}

test "$(report_value boot_magic)" = 'ANDROID!' || die 'predecessor boot magic is invalid'
test "$(report_value 'boot image header version')" = 1 || die 'M1 requires predecessor header v1'
kernel_address="$(report_value 'kernel load address')"
ramdisk_address="$(report_value 'ramdisk load address')"
second_size="$(report_value 'second bootloader size')"
second_address="$(report_value 'second bootloader load address')"
tags_address="$(report_value 'kernel tags load address')"
page_size="$(report_value 'page size')"
os_version="$(report_value 'os version')"
os_patch_level="$(report_value 'os patch level')"
product_name="$(report_value 'product name')"
recovery_dtbo_size="$(report_value 'recovery dtbo size')"

for address in "$kernel_address" "$ramdisk_address" "$second_address" "$tags_address"; do
  [[ "$address" =~ ^0x[0-9a-fA-F]+$ ]] || die 'predecessor contains an invalid load address'
done
[[ "$page_size" =~ ^[0-9]+$ ]] || die 'predecessor page size is invalid'
[[ "$second_size" =~ ^[0-9]+$ ]] || die 'predecessor second size is invalid'
[[ "$recovery_dtbo_size" =~ ^[0-9]+$ ]] || die 'predecessor recovery DTBO size is invalid'
test -f "$tmp_root/predecessor/kernel" || die 'predecessor unpack did not produce kernel'
test "$(sha256sum "$tmp_root/predecessor/kernel" | awk '{print $1}')" = "$expected_kernel_sha" || \
  die 'predecessor kernel payload SHA-256 does not match M1 lock'

"$avbtool" info_image --image "$predecessor_snapshot" \
  >"$tmp_root/predecessor-avb-info.txt" 2>&1 || \
  die 'locked predecessor AVB metadata is unreadable'
mapfile -t predecessor_avb < <(python3 - "$tmp_root/predecessor-avb-info.txt" \
  "$partition_size" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")

def one(pattern, name):
    values = re.findall(pattern, text, flags=re.MULTILINE)
    if len(values) != 1:
        raise SystemExit(f"predecessor AVB has invalid {name}")
    return values[0]

image_size = one(r"^Image size:\s+(\d+) bytes$", "image size")
if int(image_size) != int(sys.argv[2]):
    raise SystemExit("predecessor AVB image size is not the boot partition size")
if one(r"^Algorithm:\s+(\S+)$", "algorithm") != "NONE":
    raise SystemExit("predecessor AVB algorithm is not NONE")
if one(r"^\s+Hash Algorithm:\s+(\S+)$", "hash algorithm") != "sha256":
    raise SystemExit("predecessor AVB hash algorithm is not sha256")
if one(r"^\s+Partition Name:\s+(\S+)$", "partition name") != "boot":
    raise SystemExit("predecessor AVB partition name is not boot")
salt = one(r"^\s+Salt:\s+([0-9a-f]{64})$", "salt")
release = one(r"^Release String:\s+'([^'\n]+)'$", "release string")
rollback = one(r"^Rollback Index:\s+(\d+)$", "rollback index")
flags = one(r"^Flags:\s+(\d+)$", "VBMeta flags")
for value in (salt, release, rollback, flags):
    print(value)
PY
)
test "${#predecessor_avb[@]}" -eq 4 || die 'locked predecessor AVB contract is invalid'
avb_salt="${predecessor_avb[0]}"
avb_release="${predecessor_avb[1]}"
avb_rollback="${predecessor_avb[2]}"
avb_flags="${predecessor_avb[3]}"

mkboot_args=(
  --kernel "$tmp_root/predecessor/kernel"
  --ramdisk "$initrd_snapshot"
  --cmdline "$expected_cmdline"
  --base 0
  --kernel_offset "$kernel_address"
  --ramdisk_offset "$ramdisk_address"
  --second_offset "$second_address"
  --tags_offset "$tags_address"
  --pagesize "$page_size"
  --board "$product_name"
  --os_version "$os_version"
  --os_patch_level "$os_patch_level"
  --header_version 1
  --output "$candidate_tmp"
)
if test "$second_size" -gt 0; then
  test -f "$tmp_root/predecessor/second" || die 'predecessor second payload is missing'
  mkboot_args+=(--second "$tmp_root/predecessor/second")
fi
if test "$recovery_dtbo_size" -gt 0; then
  test -f "$tmp_root/predecessor/recovery_dtbo" || die 'predecessor recovery DTBO is missing'
  mkboot_args+=(--recovery_dtbo "$tmp_root/predecessor/recovery_dtbo")
fi

if test "$mkboot_kind" = exec; then
  "$mkboot_tool" "${mkboot_args[@]}"
else
  python3 "$mkboot_tool" "${mkboot_args[@]}"
fi
"$avbtool" add_hash_footer --image "$candidate_tmp" --partition_name boot \
  --partition_size "$partition_size" --algorithm NONE --hash_algorithm sha256 \
  --salt "$avb_salt" --rollback_index "$avb_rollback" --flags "$avb_flags" \
  --internal_release_string "$avb_release"

candidate_sha="$("$safe_file" snapshot "$candidate_tmp" "$candidate_snapshot" \
  "$partition_size" -)"
HALIUM_ROOT="$HALIUM_ROOT" "$verifier" "$predecessor_snapshot" \
  "$candidate_snapshot" >/dev/null

if test "${M1_REPACK_TEST_HOOKS:-0}" = 1 && \
   test -n "${M1_REPACK_TEST_REPLACE_CANDIDATE_WITH:-}"; then
  test_replace_path "$candidate_snapshot" "$M1_REPACK_TEST_REPLACE_CANDIDATE_WITH"
fi
"$safe_file" verify "$candidate_snapshot" "$partition_size" "$candidate_sha" >/dev/null

if test "${M1_REPACK_TEST_HOOKS:-0}" = 1 && \
   test -n "${M1_REPACK_TEST_CREATE_DESTINATION_FROM:-}"; then
  "$safe_file" publish "$M1_REPACK_TEST_CREATE_DESTINATION_FROM" "$output" - - >/dev/null
fi
published_sha="$("$safe_file" publish "$candidate_snapshot" "$output" \
  "$partition_size" "$candidate_sha")"
test "$published_sha" = "$candidate_sha" || die 'published candidate SHA-256 changed'
if test "${M1_REPACK_TEST_HOOKS:-0}" = 1 && \
   test -n "${M1_REPACK_TEST_REPLACE_PUBLISHED_WITH:-}"; then
  test_replace_path "$output" "$M1_REPACK_TEST_REPLACE_PUBLISHED_WITH"
fi
"$safe_file" verify "$output" "$partition_size" "$candidate_sha" >/dev/null
HALIUM_ROOT="$HALIUM_ROOT" "$verifier" "$predecessor_snapshot" "$output" >/dev/null
"$safe_file" verify "$output" "$partition_size" "$candidate_sha" >/dev/null
printf 'm1_predecessor_repack=pass\n'
printf 'predecessor_sha256=%s\n' "$expected_predecessor_sha"
printf 'candidate_sha256=%s\n' "$candidate_sha"
printf 'kernel_sha256=%s\n' "$(sha256sum "$tmp_root/predecessor/kernel" | awk '{print $1}')"
printf 'ramdisk_sha256=%s\n' "${release[3]}"
printf 'ramdisk_source_commit=%s\n' "${release[5]}"
