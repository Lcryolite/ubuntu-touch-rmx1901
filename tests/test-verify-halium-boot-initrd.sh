#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
verifier="$repo_root/scripts/verify-halium-boot-initrd.sh"
safe_initrd="${SAFE_INITRD_FIXTURE:-/home/lknife/android/rmx1901-halium11-artifacts/initrd-91cad41-20260728T/a/initrd.img-touch-arm64-rmx1901-safe}"
old_initrd=/var/tmp/rmx1901-halium-initrd-cache/92015679-0bbac4577f3567aec935c958216de5d30c7355452ca56248d6728f4f2634bdb6-initrd.img-touch-arm64
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/verify-safe-boot-initrd-test.XXXXXX")"
trap 'rm -rf -- "$tmp_root"' EXIT
test -f "$safe_initrd"
test -f "$old_initrd"
safe_initrd_size="$(stat -c %s "$safe_initrd")"

boot="$tmp_root/halium-boot.img"
printf 'boot fixture\n' >"$boot"
unpacker="$tmp_root/unpack_bootimg"
cat >"$unpacker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
test "$1" = --boot_img
test "$2" = "$EXPECTED_BOOT"
test "$3" = --out
mkdir -p "$4"
cp -- "$UNPACK_RAMDISK" "$4/ramdisk"
printf '%s\n' \
  "boot_magic: ${UNPACK_BOOT_MAGIC:-ANDROID!}" \
  "kernel load address: ${UNPACK_KERNEL_LOAD:-0x8000}" \
  "ramdisk size: ${UNPACK_RAMDISK_SIZE:-$SAFE_INITRD_SIZE}" \
  "ramdisk load address: ${UNPACK_RAMDISK_LOAD:-0x1000000}" \
  "second bootloader size: ${UNPACK_SECOND_SIZE:-0}" \
  "kernel tags load address: ${UNPACK_TAGS_LOAD:-0x100}" \
  "page size: ${UNPACK_PAGE_SIZE:-4096}" \
  "boot image header version: ${UNPACK_HEADER_VERSION:-1}"
EOF
chmod +x "$unpacker"

set +e
EXPECTED_BOOT="$boot" UNPACK_RAMDISK="$safe_initrd" SAFE_INITRD_SIZE="$safe_initrd_size" \
HALIUM_VERIFY_TEST_HOOKS=1 UNPACK_BOOTIMG_COMMAND="$unpacker" \
  "$verifier" "$boot" >"$tmp_root/enabled-override-rejection.log" 2>&1
enabled_override_status=$?
set -e
test "$enabled_override_status" -eq 2
grep -Fx 'unpack_bootimg override is not supported' \
  "$tmp_root/enabled-override-rejection.log" >/dev/null

set +e
EXPECTED_BOOT="$boot" UNPACK_RAMDISK="$safe_initrd" SAFE_INITRD_SIZE="$safe_initrd_size" \
UNPACK_BOOTIMG_COMMAND="$unpacker" \
  "$verifier" "$boot" >"$tmp_root/override-rejection.log" 2>&1
override_status=$?
set -e
test "$override_status" -eq 2
grep -Fx 'unpack_bootimg override is not supported' \
  "$tmp_root/override-rejection.log" >/dev/null

halium_root="$tmp_root/halium"
mkdir -p "$halium_root/device/realme/RMX1901" \
  "$halium_root/out/host/linux-x86/bin"
cp -- "$safe_initrd" "$halium_root/device/realme/RMX1901/initramfs.gz"
cp -- "$unpacker" "$halium_root/out/host/linux-x86/bin/unpack_bootimg"
EXPECTED_BOOT="$boot" UNPACK_RAMDISK="$safe_initrd" SAFE_INITRD_SIZE="$safe_initrd_size" HALIUM_ROOT="$halium_root" \
  "$verifier" "$boot"

# Every pinned unpacked boot-header field is an acceptance-gate input, not
# informational output that can drift while the embedded ramdisk remains safe.
header_rejection_failures=0
expect_header_rejection() {
  local field="$1"
  local bad_value="$2"
  set +e
  env EXPECTED_BOOT="$boot" UNPACK_RAMDISK="$safe_initrd" SAFE_INITRD_SIZE="$safe_initrd_size" HALIUM_ROOT="$halium_root" \
    "$field=$bad_value" "$verifier" "$boot" >/dev/null 2>&1
  local status=$?
  set -e
  if test "$status" -eq 0; then
    echo "Verifier accepted wrong unpack field: $field=$bad_value" >&2
    header_rejection_failures=$((header_rejection_failures + 1))
  fi
}
expect_header_rejection UNPACK_BOOT_MAGIC BROKEN
expect_header_rejection UNPACK_HEADER_VERSION 2
expect_header_rejection UNPACK_PAGE_SIZE 2048
expect_header_rejection UNPACK_KERNEL_LOAD 0x10000
expect_header_rejection UNPACK_RAMDISK_LOAD 0x2000000
expect_header_rejection UNPACK_TAGS_LOAD 0x200
expect_header_rejection UNPACK_SECOND_SIZE 1
expect_header_rejection UNPACK_RAMDISK_SIZE "$((safe_initrd_size - 1))"
test "$header_rejection_failures" -eq 0

# HALIUM_ROOT verification requires the staged safe initrd to exist.
mv -- "$halium_root/device/realme/RMX1901/initramfs.gz" \
  "$halium_root/device/realme/RMX1901/initramfs.saved"
set +e
EXPECTED_BOOT="$boot" UNPACK_RAMDISK="$safe_initrd" SAFE_INITRD_SIZE="$safe_initrd_size" HALIUM_ROOT="$halium_root" \
  "$verifier" "$boot" >/dev/null 2>&1
missing_staged_status=$?
set -e
test "$missing_staged_status" -ne 0
mv -- "$halium_root/device/realme/RMX1901/initramfs.saved" \
  "$halium_root/device/realme/RMX1901/initramfs.gz"

# A wrong ramdisk plus self-consistent caller metadata must still be rejected.
wrong_metadata="$tmp_root/wrong-metadata.json"
python3 - "$wrong_metadata" "$old_initrd" <<'PY'
import hashlib, json, pathlib, sys
p = pathlib.Path(sys.argv[2])
json.dump({"asset_size": p.stat().st_size, "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}, open(sys.argv[1], "w"))
PY
set +e
EXPECTED_BOOT="$boot" UNPACK_RAMDISK="$old_initrd" SAFE_INITRD_SIZE="$safe_initrd_size" HALIUM_ROOT="$halium_root" \
HALIUM_INITRD_METADATA="$wrong_metadata" \
  "$verifier" "$boot" >/dev/null 2>&1
wrong_status=$?
set -e
test "$wrong_status" -ne 0

# A staged ramdisk mismatch is rejected even when the embedded one is safe.
cp -- "$old_initrd" "$halium_root/device/realme/RMX1901/initramfs.gz"
set +e
EXPECTED_BOOT="$boot" UNPACK_RAMDISK="$safe_initrd" SAFE_INITRD_SIZE="$safe_initrd_size" HALIUM_ROOT="$halium_root" \
  "$verifier" "$boot" >/dev/null 2>&1
staged_status=$?
set -e
test "$staged_status" -ne 0

missing_unpacker="$tmp_root/missing-unpacker"
cat >"$missing_unpacker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$4"
EOF
chmod +x "$missing_unpacker"
missing_halium_root="$tmp_root/missing-halium"
mkdir -p "$missing_halium_root/out/host/linux-x86/bin" \
  "$missing_halium_root/device/realme/RMX1901"
cp -- "$missing_unpacker" "$missing_halium_root/out/host/linux-x86/bin/unpack_bootimg"
cp -- "$safe_initrd" "$missing_halium_root/device/realme/RMX1901/initramfs.gz"
set +e
HALIUM_ROOT="$missing_halium_root" "$verifier" "$boot" >/dev/null 2>&1
missing_status=$?
set -e
test "$missing_status" -ne 0

echo 'RMX1901 safe Halium boot initrd verification tests passed'
