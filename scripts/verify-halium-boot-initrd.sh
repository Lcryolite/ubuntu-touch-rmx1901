#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if test -n "${UNPACK_BOOTIMG_COMMAND:-}"; then
  echo "unpack_bootimg override is not supported" >&2
  exit 2
fi
: "${HALIUM_ROOT:?set HALIUM_ROOT}"
boot_image="${1:?usage: verify-halium-boot-initrd.sh HALIUM-BOOT.IMG}"
metadata="$repo_root/artifacts/supply-chain/rmx1901-safe-initrd-arm64.provenance.json"
validator="$repo_root/scripts/validate-safe-halium-initrd-provenance.py"
auditor="$repo_root/scripts/audit-safe-halium-initrd.sh"

test -s "$boot_image" || {
  echo "Halium boot image is missing or empty" >&2
  exit 1
}
mapfile -t expected < <(python3 "$validator" "$metadata")
test "${#expected[@]}" -eq 6 || {
  echo "Invalid RMX1901 safe initrd provenance" >&2
  exit 1
}

unpack_dir="$(mktemp -d "${TMPDIR:-/tmp}/verify-halium-boot.XXXXXX")"
trap 'rm -rf -- "$unpack_dir"' EXIT
unpack_report="$unpack_dir/unpack-output.txt"
if test -x "$HALIUM_ROOT/out/host/linux-x86/bin/unpack_bootimg"; then
  "$HALIUM_ROOT/out/host/linux-x86/bin/unpack_bootimg" \
    --boot_img "$boot_image" --out "$unpack_dir" >"$unpack_report"
elif test -f "$HALIUM_ROOT/system/tools/mkbootimg/unpack_bootimg.py"; then
  python3 "$HALIUM_ROOT/system/tools/mkbootimg/unpack_bootimg.py" \
    --boot_img "$boot_image" --out "$unpack_dir" >"$unpack_report"
else
  echo "No tree unpack_bootimg implementation is available" >&2
  exit 1
fi

require_unpack_value() {
  local label="$1"
  local expected_value="$2"
  test "$(grep -c "^${label}: " "$unpack_report" || true)" -eq 1 && \
      grep -Fxq "${label}: ${expected_value}" "$unpack_report" || {
    echo "Halium boot image has invalid unpacked ${label}" >&2
    exit 1
  }
}

require_unpack_value boot_magic 'ANDROID!'
require_unpack_value 'boot image header version' 1
require_unpack_value 'page size' 4096
require_unpack_value 'kernel load address' 0x8000
require_unpack_value 'ramdisk load address' 0x1000000
require_unpack_value 'kernel tags load address' 0x100
require_unpack_value 'second bootloader size' 0
require_unpack_value 'ramdisk size' "${expected[2]}"

ramdisk="$unpack_dir/ramdisk"
test -f "$ramdisk" || {
  echo "Halium boot image has no extracted ramdisk" >&2
  exit 1
}
actual_size="$(stat -c %s "$ramdisk")"
actual_sha="$(sha256sum "$ramdisk" | awk '{print $1}')"
test "$actual_size" -eq "${expected[2]}" || {
  echo "Halium boot ramdisk size does not match pinned safe initrd" >&2
  exit 1
}
test "$actual_sha" = "${expected[3]}" || {
  echo "Halium boot ramdisk SHA-256 does not match pinned safe initrd" >&2
  exit 1
}
"$auditor" "$ramdisk" >/dev/null

staged="$HALIUM_ROOT/device/realme/RMX1901/initramfs.gz"
test -f "$staged" || {
  echo "Staged RMX1901 safe initrd is missing" >&2
  exit 1
}
cmp "$ramdisk" "$staged" >/dev/null || {
  echo "Embedded Halium initrd is not byte-identical to the staged safe initrd" >&2
  exit 1
}
printf 'verified embedded RMX1901 safe initrd %s source %s\n' "$actual_sha" "${expected[5]}"
